import AppKit
import MarqueeCore

/// 一张钉图：本体窗口 + 控制条窗口，以及它们的状态。
///
/// ## 为什么是**两个**窗口
///
/// 鼠标穿透只能整窗生效（`ignoresMouseEvents`）。而"穿透开着时怎么关掉它"是个死结：
/// 窗口不接收任何鼠标事件，也就点不到自己身上那个开关。
/// 所以控制条必须是**另一个窗口**，它永远可交互 —— 那是唯一的出口。
///
/// ## 为什么状态在 Core
///
/// 缩放锚点、边界夹取、透明度档位全是纯逻辑，`PinState` 那份在 Core 里、有单测。
/// 这里只做"把状态贴到窗口上"和"把事件翻译成状态变化"。
@MainActor
final class PinController {

    private(set) var state: PinState
    private let image: CGImage

    private let imagePanel: PinPanel
    private let imageView: PinImageView
    private let stripPanel: PinStripPanel
    private let stripView: PinStripView

    /// 关掉之后通知外面（presenter 要把它从清单里摘掉）。
    var onClose: ((PinController) -> Void)?

    /// 钉图所在的屏。用它算控制条位置与拖拽夹取 ——
    /// 多屏时用 `NSScreen.main` 会让另一块屏上的钉图被夹到主屏里去。
    private var screen: NSScreen {
        NSScreen.screens.first { $0.frame.intersects(state.frame) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    init(image: CGImage, displaySize: CGSize, origin: CGPoint) {
        self.image = image
        let size = CGSize(width: max(1, displaySize.width), height: max(1, displaySize.height))
        var initial = PinState(baseSize: size, origin: origin)
        initial.clampInto(Self.screenFrame(containing: origin, size: size))
        self.state = initial

        imagePanel = PinPanel(frame: initial.frame)
        imageView = PinImageView(frame: CGRect(origin: .zero, size: size))
        stripPanel = PinStripPanel(frame: PinGeometry.stripFrame(pinFrame: initial.frame,
                                                                 screenFrame: Self.screenFrame(containing: origin, size: size)))
        stripView = PinStripView(frame: CGRect(origin: .zero, size: PinGeometry.stripSize))

        imagePanel.contentView = imageView
        stripPanel.contentView = stripView
        imageView.setImage(image, displaySize: size)

        wire()
        apply()
    }

    // MARK: 呈现 / 关闭

    func show() {
        // `orderFrontRegardless`：应用是 accessory（后台），普通 `orderFront`
        // 在前台应用还占着的时候可能排不到前面（与编辑器窗口同一个坑）。
        imagePanel.orderFrontRegardless()
        stripPanel.orderFrontRegardless()
        apply()
    }

    func close() {
        NotificationCenter.default.removeObserver(self,
                                                  name: NSWindow.didMoveNotification,
                                                  object: imagePanel)
        imagePanel.orderOut(nil)
        stripPanel.orderOut(nil)
        // 显式把内容拆掉：`orderOut` 只是不显示，窗口与它的视图还挂在控制器上 ——
        // "关闭后不留残留窗口"这条指的是它们要真的被释放。
        imagePanel.contentView = nil
        stripPanel.contentView = nil
        onClose?(self)
    }

    // MARK: 接线

    private func wire() {
        imageView.onScroll = { [weak self] delta in
            // 一格滚轮对应的倍率：`scrollingDeltaY` 在不同设备上量级差很多，
            // 所以只取**方向**，倍率用固定的一小步（`PinGeometry.zoomStep`）。
            guard let self, delta != 0 else { return }
            self.state.zoom(by: delta > 0 ? PinGeometry.zoomStep : 1 / PinGeometry.zoomStep,
                            screenFrame: self.screen.visibleFrame)
            self.apply()
        }

        stripView.onClickThrough = { [weak self] in
            guard let self else { return }
            self.state.toggleClickThrough()
            self.apply()
        }
        stripView.onOpacity = { [weak self] in
            guard let self else { return }
            self.state.cycleOpacity()
            self.apply()
        }
        stripView.onClose = { [weak self] in
            self?.close()
        }
        stripView.onDragBegin = { [weak self] in
            // 只在**按下那一刻**记一次起始位置（见 `onDragBegin` 的注释）
            guard let self else { return }
            self.dragStart = self.state.frame.origin
        }
        stripView.onDrag = { [weak self] delta in
            guard let self else { return }
            // 拖的是控制条，动的是钉图 —— 控制条跟着一起走（`apply()` 里重算它的位置）。
            // 用"起始位置 + 总位移"而不是"每帧累加"，避免累积误差。
            self.state.move(to: CGPoint(x: self.dragStart.x + delta.x,
                                        y: self.dragStart.y + delta.y),
                            screenFrame: self.screen.visibleFrame)
            self.apply()
        }

        // 直接拖图（没开穿透时）走的是 `isMovableByWindowBackground`，窗口自己动、
        // 我们的状态不知道 —— 所以要在窗口挪完之后把状态同步回来，
        // 否则下一次 `apply()` 会把它**弹回原处**（表现是"拖完松手它跳回去"）。
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: imagePanel,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.origin = self.imagePanel.frame.origin
                self.state.clampInto(self.screen.visibleFrame)
                self.imagePanel.setFrame(self.state.frame, display: true)
                self.applyStrip()
            }
        }
    }

    /// 拖拽开始时的位置（`onDragBegin` 里记一次，`onDrag` 里叠位移用）。
    private var dragStart: CGPoint = .zero

    // MARK: 把状态贴到窗口上

    private func apply() {
        imagePanel.setFrame(state.frame, display: true)
        imagePanel.alphaValue = state.opacity
        // ⚠️ 这一句是"鼠标穿透"的全部实现，也是它与控制条必须分成两个窗口的原因
        imagePanel.ignoresMouseEvents = state.isClickThrough
        applyStrip()
    }

    private func applyStrip() {
        stripPanel.setFrame(PinGeometry.stripFrame(pinFrame: state.frame,
                                                   screenFrame: screen.visibleFrame),
                            display: true)
        stripView.update(isClickThrough: state.isClickThrough, opacity: state.opacity)
        // 控制条**不**跟着变透明：它就是用来把图关掉的，跟着淡下去会先变得看不清
    }

    private static func screenFrame(containing point: CGPoint, size: CGSize) -> CGRect {
        let frame = CGRect(origin: point, size: size)
        return NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

/// 管着所有钉图。
///
/// 多张钉图**互不干扰**：每张有自己的一对窗口和自己的状态，这里只负责持有与收场。
@MainActor
public final class PinPresenter {

    private var pins: [PinController] = []

    public init() {}

    /// 当前有几张钉图（自检用）。
    public var count: Int { pins.count }

    /// 把一张图钉到屏幕上。
    ///
    /// - Parameter anchor: 原始选区（**Cocoa 全局点**）。给了就钉在**原位** ——
    ///   用户刚才盯着哪儿，图就出现在哪儿，不用再去找它。
    public func pin(_ image: CGImage, anchor: CGRect?) {
        let pointer = NSEvent.mouseLocation
        // 按**落地那块屏**的倍率换算：像素数除以倍率才是"看起来一样大"的点数。
        // 不除的话 2x 屏上钉出来只有一半大（`PinGeometry.displaySize` 有测试钉住）。
        let landing = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let displaySize = PinGeometry.displaySize(pixelSize: CGSize(width: image.width,
                                                                   height: image.height),
                                                  backingScale: landing.backingScaleFactor)
        let origin = anchor.map { CGPoint(x: $0.minX, y: $0.maxY - displaySize.height) }
            ?? CGPoint(x: landing.visibleFrame.minX + 80, y: landing.visibleFrame.maxY - displaySize.height - 80)

        let controller = PinController(image: image,
                                       displaySize: displaySize,
                                       origin: origin)
        controller.onClose = { [weak self] pin in
            self?.pins.removeAll { $0 === pin }
        }
        pins.append(controller)
        controller.show()
    }

    /// 收掉全部（应用退出 / 自检用）。
    public func closeAll() {
        for pin in pins { pin.close() }
        pins.removeAll()
    }
}

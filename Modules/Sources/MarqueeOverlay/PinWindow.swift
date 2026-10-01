import AppKit
import MarqueeCore

// MARK: - 面板

/// 钉图本体。**不抢焦点、不进 Dock、盖在普通窗口之上。**
///
/// `canBecomeKey = false` 是刻意的：钉图的用处是"当参照物"，一旦它会成为 key window，
/// 用户切回来时焦点会被它吸走一下 —— 而那正是钉图想避免的事。
final class PinPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        // `.canJoinAllSpaces`：钉图**跟着你切 Space**（当参照物时你要它在眼前，
        // 而不是"留在原来那个桌面"）。`.stationary` 让它不参与窗口循环。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
    }
}

/// 控制条面板。**始终可交互**，即使钉图本体正在穿透 —— 这是"穿透怎么关掉"的唯一出口。
final class PinStripPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 比钉图本体**高一层**：两个都在 `.floating` 时先后顺序要靠 `orderFront` 维持，
        // 而钉图一旦被挪动就会重新排序、把控制条压到下面。
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        // 拖动由视图自己处理（要同时挪钉图本体），不交给窗口
        isMovableByWindowBackground = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
    }
}

// MARK: - 图像视图

/// 只负责把那张图按当前大小画出来。
final class PinImageView: NSView {

    /// 滚轮缩放。传出去的是 `scrollingDeltaY` 的正负，不是像素数 ——
    /// 不同设备的滚轮一格差很多倍，按"格"来比按"像素"稳。
    var onScroll: ((CGFloat) -> Void)?

    private var cached: NSImage?

    func setImage(_ image: CGImage, displaySize: CGSize) {
        cached = NSImage(cgImage: image, size: displaySize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cached else { return }
        // `respectFlipped: true`：不写的话图会**上下颠倒**（AppKit 的 y 方向与
        // 位图的行序相反）。这是个不崩不报错、只让图反过来的坑。
        cached.draw(in: bounds,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue])

        // 一圈描边：白底的截图放在白底的窗口上时，没有它就是"什么都没出现"
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    /// 按在图上拖动 = 挪窗口（`isMovableByWindowBackground` 需要这一条为真）。
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - 控制条

/// 控制条的视觉常量。放在一处：背景由 `ChromeBackground` 造、前景在这里画，
/// 两边的圆角必须对得上，否则 26 上是圆角、15 上是方的。
enum PinStripStyle {
    static let cornerRadius: CGFloat = 7
}

/// 三个按钮：穿透 / 不透明度 / 关闭。整条还可以当**拖动把手**。
final class PinStripView: NSView, NSViewToolTipOwner {

    var onClickThrough: (() -> Void)?
    var onOpacity: (() -> Void)?
    var onClose: (() -> Void)?
    /// 从按下点算起的**总位移**（不是每帧增量）—— 由控制层叠加到起始位置上。
    var onDrag: ((CGPoint) -> Void)?
    /// 开始拖动。控制层在这一刻记下"起始位置"。
    ///
    /// ⚠️ 起始位置绝不能每帧重取：那样 `起始 + 总位移` 会变成"上一帧 + 总位移"，
    /// 拖动距离被**反复累加**，图会越拖越快（表现是"拖一下它飞出去"）。
    var onDragBegin: (() -> Void)?

    private var isClickThrough = false
    private var opacity: CGFloat = 1
    private var dragOrigin: CGPoint?

    private static let symbols = ["hand.raised", "hand.raised.slash"]

    func update(isClickThrough: Bool, opacity: CGFloat) {
        self.isClickThrough = isClickThrough
        self.opacity = opacity
        needsDisplay = true
    }

    private enum Button: CaseIterable {
        case clickThrough
        case opacity
        case close
    }

    private func frame(of button: Button) -> CGRect {
        let index = Button.allCases.firstIndex(of: button)!
        let step = PinGeometry.stripButtonSize + PinGeometry.stripItemGap
        return CGRect(x: PinGeometry.stripPadding + CGFloat(index) * step,
                      y: PinGeometry.stripPadding,
                      width: PinGeometry.stripButtonSize,
                      height: PinGeometry.stripButtonSize)
    }

    private func button(at point: CGPoint) -> Button? {
        Button.allCases.first { frame(of: $0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 深色底不在这里画（ticket 17）：它还挂在 `ChromeBackground` 造的那层材质上，
        // 那层是先加的子视图 —— 在这里再铺一层黑会把材质**整个盖掉**。
        for button in Button.allCases {
            let box = frame(of: button)
            switch button {
            case .clickThrough:
                // 穿透**开着**的时候才高亮：它是"异常状态"，要一眼看得出来，
                // 否则用户会以为鼠标坏了（点了什么都没反应）。
                if isClickThrough { highlight(box) }
                drawSymbol(isClickThrough ? Self.symbols[1] : Self.symbols[0],
                           in: box,
                           tint: isClickThrough ? .controlAccentColor : .white)
            case .opacity:
                drawOpacityGlyph(in: box)
            case .close:
                drawSymbol("xmark", in: box, tint: .white)
            }
        }
    }

    private func highlight(_ rect: CGRect) {
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    /// 用 SF Symbol 画图标。取不到时画一个小圆点 —— 绝不静默什么都不画
    /// （那样按钮看着是空的，用户会以为那个功能是坏的）。
    private func drawSymbol(_ name: String, in rect: CGRect, tint: NSColor) {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [tint])
            .applying(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            fallbackDot(in: rect, tint: tint)
            return
        }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2,
                              y: rect.midY - size.height / 2,
                              width: size.width,
                              height: size.height))
    }

    private func fallbackDot(in rect: CGRect, tint: NSColor) {
        tint.setFill()
        NSBezierPath(ovalIn: CGRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4)).fill()
    }

    /// 半透明：一个"左半边填实"的圆。自己画而不是找 SF Symbol ——
    /// 这类图标的名称在系统版本之间改过好几次（`circle.lefthalf.fill` → `.filled`），
    /// 而自己画一个圆永远不会失效。
    private func drawOpacityGlyph(in rect: CGRect) {
        let radius: CGFloat = 6.5
        let circle = CGRect(x: rect.midX - radius, y: rect.midY - radius,
                            width: radius * 2, height: radius * 2)
        NSColor.white.setStroke()
        let outline = NSBezierPath(ovalIn: circle)
        outline.lineWidth = 1.2
        outline.stroke()

        // 填充的多少直接对应当前透明度 —— 它同时是按钮**和读数**
        NSColor.white.setFill()
        let filled = NSBezierPath()
        filled.appendArc(withCenter: CGPoint(x: circle.midX, y: circle.midY),
                         radius: radius - 1.5,
                         startAngle: 90,
                         endAngle: 90 + 360 * opacity,
                         clockwise: false)
        filled.close()
        filled.fill()
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let button = button(at: point) else {
            // 按在空白处 = 开始拖动（整条就是把手）
            dragOrigin = NSEvent.mouseLocation
            onDragBegin?()
            return
        }
        switch button {
        case .clickThrough: onClickThrough?()
        case .opacity: onOpacity?()
        case .close: onClose?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragOrigin else { return }
        let now = NSEvent.mouseLocation
        onDrag?(CGPoint(x: now.x - start.x, y: now.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// 工具提示：**这是"这三个按钮是干什么的"唯一的说明**。
    /// 钉图上没有任何文字标签，而"按了才知道"对不可逆操作（关闭/穿透）来说太晚了。
    private var installedToolTips = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !installedToolTips else { return }
        installedToolTips = true
        for button in Button.allCases {
            addToolTip(frame(of: button), owner: self, userData: nil)
        }
    }

    func view(_ view: NSView,
              stringForToolTip tag: NSView.ToolTipTag,
              point: CGPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        switch button(at: point) {
        case .clickThrough:
            isClickThrough
                ? "鼠标穿透：开着（点击会落到下面的应用）。点一下关掉"
                : "鼠标穿透：关着。点开后点击会落到下面的应用"
        case .opacity:
            "不透明度：现在是 \(Int(opacity * 100))%。点一下换下一档"
        case .close:
            "关掉这张钉图"
        case nil:
            "拖动这里可以移动这张钉图"
        }
    }

    override func resetCursorRects() {
        // 按钮上用手指 —— 空白处保持箭头（拖动的反馈由"窗口跟着走"本身给出，
        // 而给整条再加一个 openHand 会和按钮的矩形重叠，谁生效取决于加入顺序，
        // 那是"有时候是手、有时候是箭头"这种说不清的表现）。
        for button in Button.allCases {
            addCursorRect(frame(of: button), cursor: .pointingHand)
        }
    }
}

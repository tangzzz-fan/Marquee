import AppKit
import MarqueeCore

/// 覆盖层要画的东西。由控制器算好、推给每个面板的视图。
///
/// 视图**不做任何几何判断**：它只负责把全局坐标转成自己窗口内的坐标然后画。
/// 选区的真相在控制器（以及 Core 的状态机）手里，多屏时才不会各画各的。
struct SelectionPresentation: Equatable {
    /// 当前选区，**Cocoa 全局坐标**；`nil` = 还没拉出选区
    var globalRect: CGRect?
    /// 尺寸读数（pt 与 px）
    var sizeText: String
    /// 左上角坐标读数
    var originText: String

    static let empty = SelectionPresentation(globalRect: nil, sizeText: "", originText: "")
}

@MainActor
protocol SelectionOverlayViewDelegate: AnyObject {
    func overlayView(_ view: SelectionOverlayView, beganDragAt globalPoint: CGPoint)
    func overlayView(_ view: SelectionOverlayView, draggedTo globalPoint: CGPoint)
    func overlayView(_ view: SelectionOverlayView, endedDragAt globalPoint: CGPoint)
    /// 方向键微调，`dx`/`dy` 只取 -1 / 0 / 1
    func overlayView(_ view: SelectionOverlayView, nudgeBy dx: CGFloat, dy: CGFloat)
    func overlayView(_ view: SelectionOverlayView, shiftChanged isDown: Bool)
    /// `⏎`：有选区则提交，无选区则整屏
    func overlayViewDidRequestCommit(_ view: SelectionOverlayView)
    /// 双击：整屏
    func overlayViewDidRequestWholeScreen(_ view: SelectionOverlayView)
    func overlayViewDidRequestCancel(_ view: SelectionOverlayView)
}

/// 单块屏上的蒙层视图。
///
/// **刻意不铺整屏截图当底图**（PRD 5.5 第 2 条）：只画变暗蒙层 + 选区镂空 + 描边。
/// 铺底图会引入色彩偏移、HDR 色调映射错误，还会"截屏套娃"。
final class SelectionOverlayView: NSView {

    weak var delegate: SelectionOverlayViewDelegate?

    var presentation: SelectionPresentation = .empty {
        didSet {
            guard presentation != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            delegate?.overlayViewDidRequestWholeScreen(self)
            return
        }
        delegate?.overlayView(self, beganDragAt: cocoaPoint(of: event))
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.overlayView(self, draggedTo: cocoaPoint(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.overlayView(self, endedDragAt: cocoaPoint(of: event))
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 0x35: // kVK_Escape
            delegate?.overlayViewDidRequestCancel(self)
        case 0x24, 0x4C: // kVK_Return / kVK_ANSI_KeypadEnter
            delegate?.overlayViewDidRequestCommit(self)
        case 0x7B: // ←
            delegate?.overlayView(self, nudgeBy: -1, dy: 0)
        case 0x7C: // →
            delegate?.overlayView(self, nudgeBy: 1, dy: 0)
        case 0x7D: // ↓ —— 注意 Cocoa 视图坐标 y 向上，"下"是 -1
            delegate?.overlayView(self, nudgeBy: 0, dy: -1)
        case 0x7E: // ↑
            delegate?.overlayView(self, nudgeBy: 0, dy: 1)
        default:
            NSSound.beep()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        delegate?.overlayView(self, shiftChanged: event.modifierFlags.contains(.shift))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let localSelection = presentation.globalRect.map { globalToLocal($0) }

        NSColor.black.withAlphaComponent(0.42).setFill()

        guard let localSelection, localSelection.width >= 1, localSelection.height >= 1 else {
            bounds.fill()
            return
        }

        // 选区镂空：外框 + 内框用 even-odd 填充规则挖洞，
        // 比"画四条边"更不容易在缩放/半像素位置露出缝
        let mask = NSBezierPath(rect: bounds)
        mask.append(NSBezierPath(rect: localSelection))
        mask.windingRule = .evenOdd
        mask.fill()

        let outline = NSBezierPath(rect: localSelection.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        drawReadout(in: localSelection)
    }

    private func drawReadout(in localSelection: CGRect) {
        let text = presentation.sizeText + "\n" + presentation.originText
        guard !presentation.sizeText.isEmpty else { return }

        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let textSize = attributed.size()
        let padding = NSSize(width: 8, height: 5)
        let boxSize = NSSize(width: textSize.width + padding.width * 2,
                             height: textSize.height + padding.height * 2)

        // 默认贴在选区左上角外侧；上下空间不够就翻到另一侧，再不够就贴进选区内部
        var origin = CGPoint(x: localSelection.minX, y: localSelection.maxY + 6)
        if origin.y + boxSize.height > bounds.maxY {
            origin.y = localSelection.minY - boxSize.height - 6
        }
        if origin.y < bounds.minY {
            origin.y = localSelection.minY + 6
        }
        if origin.x + boxSize.width > bounds.maxX {
            origin.x = bounds.maxX - boxSize.width - 6
        }
        if origin.x < bounds.minX {
            origin.x = bounds.minX + 6
        }

        let box = NSRect(origin: origin, size: boxSize)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        attributed.draw(at: NSPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }

    // MARK: - 坐标

    /// 事件 → Cocoa 全局坐标
    private func cocoaPoint(of event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let origin = window?.frame.origin ?? .zero
        return CGPoint(x: origin.x + local.x, y: origin.y + local.y)
    }

    /// Cocoa 全局坐标 → 本视图坐标
    private func globalToLocal(_ rect: CGRect) -> CGRect {
        let origin = window?.frame.origin ?? .zero
        return CGRect(x: rect.minX - origin.x,
                      y: rect.minY - origin.y,
                      width: rect.width,
                      height: rect.height)
    }
}

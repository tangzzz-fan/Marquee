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
    /// 悬停窗口，**Cocoa 全局坐标**；拖选区时为 `nil`
    var hoverRect: CGRect?
    var hoverLabel: String
    /// 系统窗口圆角的近似值。没有 API 给出真实圆角，10 点贴近近年 macOS 普通窗口
    var hoverCornerRadius: CGFloat

    static let empty = SelectionPresentation(globalRect: nil,
                                             sizeText: "",
                                             originText: "",
                                             hoverRect: nil,
                                             hoverLabel: "",
                                             hoverCornerRadius: 10)
}

@MainActor
protocol SelectionOverlayViewDelegate: AnyObject {
    func overlayView(_ view: SelectionOverlayView, beganDragAt globalPoint: CGPoint)
    func overlayView(_ view: SelectionOverlayView, draggedTo globalPoint: CGPoint)
    func overlayView(_ view: SelectionOverlayView, endedDragAt globalPoint: CGPoint, optionDown: Bool)
    func overlayView(_ view: SelectionOverlayView, movedTo globalPoint: CGPoint)
    /// 方向键微调，`dx`/`dy` 只取 -1 / 0 / 1
    func overlayView(_ view: SelectionOverlayView, nudgeBy dx: CGFloat, dy: CGFloat)
    func overlayView(_ view: SelectionOverlayView, shiftChanged isDown: Bool)
    func overlayView(_ view: SelectionOverlayView, optionChanged isDown: Bool)
    /// `⏎`：已落点则提交；悬停窗口则先锁定；否则整屏
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
        delegate?.overlayView(self, endedDragAt: cocoaPoint(of: event),
                              optionDown: event.modifierFlags.contains(.option))
    }

    override func mouseMoved(with event: NSEvent) {
        delegate?.overlayView(self, movedTo: cocoaPoint(of: event))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    // MARK: - 键盘

    override func cancelOperation(_ sender: Any?) {
        delegate?.overlayViewDidRequestCancel(self)
    }

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
        delegate?.overlayView(self, optionChanged: event.modifierFlags.contains(.option))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let localSelection = presentation.globalRect.map { globalToLocal($0) }
        let localHover = presentation.hoverRect.map { globalToLocal($0) }

        NSColor.black.withAlphaComponent(0.42).setFill()

        if let localSelection, localSelection.width >= 1, localSelection.height >= 1 {
            fillMask(punching: localSelection, cornerRadius: 0)
            stroke(localSelection, cornerRadius: 0, lineWidth: 1)
            drawReadout(in: localSelection, text: presentation.sizeText + "\n" + presentation.originText)
            return
        }

        if let localHover, localHover.width >= 1, localHover.height >= 1 {
            let radius = presentation.hoverCornerRadius
            fillMask(punching: localHover, cornerRadius: radius)
            stroke(localHover, cornerRadius: radius, lineWidth: 2)
            if !presentation.hoverLabel.isEmpty {
                drawReadout(in: localHover, text: presentation.hoverLabel)
            }
            return
        }

        bounds.fill()
    }

    private func fillMask(punching hole: CGRect, cornerRadius: CGFloat) {
        let mask = NSBezierPath(rect: bounds)
        mask.append(Self.roundedPath(hole, radius: cornerRadius))
        mask.windingRule = .evenOdd
        mask.fill()
    }

    private func stroke(_ rect: CGRect, cornerRadius: CGFloat, lineWidth: CGFloat) {
        let outline = Self.roundedPath(rect.insetBy(dx: 0.5, dy: 0.5), radius: max(0, cornerRadius - 0.5))
        outline.lineWidth = lineWidth
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        guard radius > 0 else { return NSBezierPath(rect: rect) }
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private func drawReadout(in localSelection: CGRect, text: String) {
        guard !text.isEmpty else { return }

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

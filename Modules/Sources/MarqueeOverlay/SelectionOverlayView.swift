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
    /// 长截图正在抓帧。此时读数换成进度与提示，描边加粗
    var isScrollCapturing: Bool = false
    /// 长截图进度（如「长截图 · 已拼 1200 px · 4 帧」）
    var scrollStatusText: String = ""
    /// 长截图操作提示（如「滚动到底后按 ⏎ 结束 · Esc 取消」）
    var scrollHintText: String = ""
    /// 长截图告警（如「已经滚到底了」「这一帧没对齐」），非空时用醒目色
    var scrollWarningText: String = ""
    /// 空状态提示的锚点（**Cocoa 全局坐标**，一般就是鼠标位置）
    ///
    /// 为什么要有它：长截图进入后还没选目标时，既没有选区也没有悬停窗口，
    /// 视图只能画一层蒙层 —— 用户看不出覆盖层在工作，会以为"拖不了"。
    /// 在光标旁挂一句提示，是最省事也最直接的"这里可以操作"信号。
    var hintAnchor: CGPoint?
    /// 空状态提示文字
    var hintText: String = ""
    /// 已落点时的操作提示（第三行读数）
    var actionHintText: String = ""
    /// 放大镜取色（ticket 10）。`nil` = 不显示。
    var magnifier: MagnifierPresentation?

    static let empty = SelectionPresentation(globalRect: nil,
                                             sizeText: "",
                                             originText: "",
                                             hoverRect: nil,
                                             hoverLabel: "",
                                             hoverCornerRadius: 10)

    /// 除放大镜之外的部分是否相等。用来判断"是不是只有放大镜在动"。
    func equalsIgnoringMagnifier(_ other: SelectionPresentation) -> Bool {
        var lhs = self
        var rhs = other
        lhs.magnifier = nil
        rhs.magnifier = nil
        return lhs == rhs
    }
}

/// 放大镜要画的东西。由控制器算好（几何全在 `MarqueeCore.MagnifierLayout`）。
struct MagnifierPresentation: Equatable {
    /// 最近邻放大后的小图
    var lensImage: CGImage?
    /// 放大镜盒子，**Cocoa 全局坐标**
    var boxRect: CGRect
    /// 取样像素在盒子里的落位（局部坐标的正方形边长）
    var sampleMarkerSize: CGFloat
    /// 采样像素的色值文本（第一行 HEX、第二行 rgb）
    var colorLines: [(text: String, color: NSColor)]
    /// 复制之后的反馈（如「已复制 #1A2B3C」）
    var statusText: String?

    /// `CGImage` 没有值相等，按**引用**比 —— 同一个引用就不必重画。
    /// 数组元素是元组（不合成 Equatable），所以只比文本。
    static func == (lhs: MagnifierPresentation, rhs: MagnifierPresentation) -> Bool {
        lhs.lensImage === rhs.lensImage
            && lhs.boxRect == rhs.boxRect
            && lhs.sampleMarkerSize == rhs.sampleMarkerSize
            && lhs.statusText == rhs.statusText
            && lhs.colorLines.map(\.text) == rhs.colorLines.map(\.text)
    }
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
    /// `⌘S`：与 `⏎` 同一套确认，但已落点时额外写入磁盘
    func overlayViewDidRequestSave(_ view: SelectionOverlayView)
    /// 双击：整屏
    func overlayViewDidRequestWholeScreen(_ view: SelectionOverlayView)
    /// `空格`：长截图里开始 / 停止**自动滚动**（ticket 12）。
    ///
    /// 为什么入口在覆盖层里而不是菜单：菜单栏已经 6 项（PRD 3.1 的上限）——
    /// 再加就得先合并。而自动滚动本来就只在"长截图进行中"有意义，
    /// 挂在那个状态自己的提示行里，比多一个随时可点但大部分时候点不动的菜单项更合理。
    func overlayViewDidToggleAutoScroll(_ view: SelectionOverlayView)
    func overlayViewDidRequestCancel(_ view: SelectionOverlayView)
}

/// 读数框的三种行色。集中放一处，免得各处硬编码颜色漂移。
enum ReadoutStyle {
    static let normal = NSColor.white
    static let warning = NSColor.systemOrange
    static let hint = NSColor.white.withAlphaComponent(0.75)
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
            // 只有放大镜在动时只重画它那一小块。
            //
            // 放大镜跟着光标走，鼠标一动就要重画；整屏重绘在 5K 屏上是实打实的开销，
            // 而验收项要求拖拽期间 120 fps 不掉帧。
            if presentation.equalsIgnoringMagnifier(oldValue),
               let old = oldValue.magnifier,
               let new = presentation.magnifier {
                setNeedsDisplay(dirtyRect(for: old).union(dirtyRect(for: new)))
            } else {
                needsDisplay = true
            }
        }
    }

    /// 放大镜占的脏区（局部坐标）。色值框贴在盒子上下、文字还可能很宽，保守地多扩一圈。
    private func dirtyRect(for magnifier: MagnifierPresentation) -> CGRect {
        globalToLocal(magnifier.boxRect)
            .insetBy(dx: -130, dy: -100)
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

    /// ⚠️ 这条路径**在生产里基本走不到**。
    ///
    /// 覆盖层的键盘由 `SelectionOverlayController.handleOverlayKeyDown` 经**应用级本地监听**
    /// 统一处理（原因见那里：面板是 `.nonactivatingPanel`，"视图 `keyDown` 能收到按键"
    /// 依赖它是 key window 且自己是 first responder —— 实测这条并不成立，
    /// `⏎` 就是因此在用户手里完全没反应）。
    ///
    /// 保留它是为了"万一本地监听没装上"时还有一条退路，**不是**主路径。
    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 0x35: // kVK_Escape
            delegate?.overlayViewDidRequestCancel(self)
        case 0x24, 0x4C: // kVK_Return / kVK_ANSI_KeypadEnter
            delegate?.overlayViewDidRequestCommit(self)
        case 0x01 where event.modifierFlags.contains(.command): // kVK_ANSI_S
            delegate?.overlayViewDidRequestSave(self)
        case 0x31: // kVK_Space —— 长截图：开始 / 停止自动滚动
            delegate?.overlayViewDidToggleAutoScroll(self)
        case 0x7B: // ←
            delegate?.overlayView(self, nudgeBy: -1, dy: 0)
        case 0x7C: // →
            delegate?.overlayView(self, nudgeBy: 1, dy: 0)
        case 0x7D: // ↓ —— 注意 Cocoa 视图坐标 y 向上，"下"是 -1
            delegate?.overlayView(self, nudgeBy: 0, dy: -1)
        case 0x7E: // ↑
            delegate?.overlayView(self, nudgeBy: 0, dy: 1)
        default:
            // 带 ⌘ / ⌃ 的组合放行给系统：⌘Tab、⌘`、⌘Space 这类是系统快捷键，
            // 覆盖层既不该吞掉它们，也没理由为它们哔一声（用户按 ⌘Tab 想换目标应用，
            // 结果是"叮"一下什么都不发生，那才是最费解的表现）。
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                super.keyDown(with: event)
            } else {
                NSSound.beep()
            }
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
        drawBase()
        if let magnifier = presentation.magnifier {
            drawMagnifier(magnifier)
        }
    }

    /// 蒙层与读数。放大镜不在这里画 —— 它要压在最上层。
    private func drawBase() {
        let localSelection = presentation.globalRect.map { globalToLocal($0) }
        let localHover = presentation.hoverRect.map { globalToLocal($0) }

        NSColor.black.withAlphaComponent(0.42).setFill()

        if let localSelection, localSelection.width >= 1, localSelection.height >= 1 {
            fillMask(punching: localSelection, cornerRadius: 0)
            stroke(localSelection,
                   cornerRadius: 0,
                   lineWidth: presentation.isScrollCapturing ? 2 : 1)
            drawReadout(in: localSelection, lines: readoutLines())
            return
        }

        if let localHover, localHover.width >= 1, localHover.height >= 1 {
            let radius = presentation.hoverCornerRadius
            fillMask(punching: localHover, cornerRadius: radius)
            stroke(localHover, cornerRadius: radius, lineWidth: 2)
            if !presentation.hoverLabel.isEmpty {
                drawReadout(in: localHover,
                            lines: [(presentation.hoverLabel, ReadoutStyle.normal)])
            }
            return
        }

        bounds.fill()
        if let anchor = presentation.hintAnchor, !presentation.hintText.isEmpty {
            drawHint(at: globalToLocal(anchor),
                     lines: [(presentation.hintText, ReadoutStyle.normal)])
        }
    }

    /// 放大镜画在**最上层**：它要盖住蒙层、选区描边和任何读数框。
    /// 用户盯着它看像素，被别的东西压住就没意义了。
    private func drawMagnifier(_ magnifier: MagnifierPresentation) {
        let box = globalToLocal(magnifier.boxRect)

        if let lens = magnifier.lensImage,
           let cgContext = NSGraphicsContext.current?.cgContext {
            cgContext.saveGState()
            // 这一步是 **1:1 直通拷贝**：放大图是 `采样边长 × zoom` 像素，盒子是
            // `采样边长 × zoom / scale` 点，落位还对过设备像素网格
            // （见 `MagnifierLayout.boxSide(sampledSide:…)` 与 `origin(cursor:placement:)`）。
            // 所以插值质量在这里**不该起作用** —— 写上 `.none` 是为了万一将来
            // 因为浮点误差真的错开半像素时，不要引入第二次平滑。
            // **真正的插值发生在 Core**（`PixelSampling.magnified` 的 `interpolation` 参数）：
            // 低倍数平滑、高倍数最近邻，那里才是"放大"发生的地方。
            cgContext.interpolationQuality = .none
            cgContext.draw(lens, in: box)
            cgContext.restoreGState()
        }

        // 取样像素的落位：盒子正中的一个小方块，就是"当前取的是哪个像素"
        let marker = CGRect(x: box.midX - magnifier.sampleMarkerSize / 2,
                            y: box.midY - magnifier.sampleMarkerSize / 2,
                            width: magnifier.sampleMarkerSize,
                            height: magnifier.sampleMarkerSize)

        // 十字线贯穿整个盒子，方便对齐周边像素
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: box.midX, y: box.minY))
        cross.line(to: CGPoint(x: box.midX, y: box.maxY))
        cross.move(to: CGPoint(x: box.minX, y: box.midY))
        cross.line(to: CGPoint(x: box.maxX, y: box.midY))
        cross.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        cross.stroke()

        // 中心像素框：外框 + 淡淡的填充，让它在一堆格子中间仍然一眼可见。
        //
        // 线宽固定 1 而不是 1.5：倍数降到 3 之后这个框只有 1~1.5 点见方
        // （`zoom / backingScale`），1.5 点的描边会把它糊成一坨圆点，反而看不出"是哪一格"。
        let markerPath = NSBezierPath(rect: marker)
        markerPath.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        markerPath.fill()
        NSColor.controlAccentColor.setStroke()
        markerPath.stroke()

        let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.85).setStroke()
        border.stroke()

        // 色值文本贴在盒子下方（Cocoa y 向上 → "下方"是更小的 y），放不下就翻到上方
        var lines = magnifier.colorLines
        if let status = magnifier.statusText {
            lines.append((status, ReadoutStyle.warning))
        }
        guard let textBox = makeBox(lines: lines) else { return }
        var origin = CGPoint(x: box.minX, y: box.minY - textBox.size.height - 4)
        if origin.y < bounds.minY { origin.y = box.maxY + 4 }
        draw(textBox, at: origin)
    }

    /// 长截图抓帧中显示进度与提示，否则显示尺寸/坐标读数。
    private func readoutLines() -> [(text: String, color: NSColor)] {
        guard presentation.isScrollCapturing else {
            var lines: [(text: String, color: NSColor)] = [(presentation.sizeText, ReadoutStyle.normal),
                                                           (presentation.originText, ReadoutStyle.normal)]
            if !presentation.actionHintText.isEmpty {
                lines.append((presentation.actionHintText, ReadoutStyle.hint))
            }
            return lines
        }
        var lines: [(text: String, color: NSColor)] = []
        if !presentation.scrollStatusText.isEmpty {
            lines.append((presentation.scrollStatusText, ReadoutStyle.normal))
        }
        if !presentation.scrollWarningText.isEmpty {
            lines.append((presentation.scrollWarningText, ReadoutStyle.warning))
        }
        if !presentation.scrollHintText.isEmpty {
            lines.append((presentation.scrollHintText, ReadoutStyle.hint))
        }
        return lines
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

    private func drawReadout(in localSelection: CGRect, lines: [(text: String, color: NSColor)]) {
        guard let box = makeBox(lines: lines) else { return }

        // 默认贴在选区左上角外侧；上下空间不够就翻到另一侧，再不够就贴进选区内部
        var origin = CGPoint(x: localSelection.minX, y: localSelection.maxY + 6)
        if origin.y + box.size.height > bounds.maxY {
            origin.y = localSelection.minY - box.size.height - 6
        }
        if origin.y < bounds.minY {
            origin.y = localSelection.minY + 6
        }
        draw(box, at: origin)
    }

    /// 在光标旁挂一句提示。
    ///
    /// 贴右下角、再夹进视图内 —— 提示框跑到屏幕外等于没提示。
    private func drawHint(at point: CGPoint, lines: [(text: String, color: NSColor)]) {
        guard let box = makeBox(lines: lines) else { return }
        let origin = CGPoint(x: point.x + 18, y: point.y - box.size.height - 12)
        draw(box, at: origin)
    }

    private func draw(_ box: (text: NSAttributedString, size: NSSize, padding: NSSize),
                      at origin: CGPoint) {
        let clamped = CGPoint(x: min(max(bounds.minX + 6, origin.x), bounds.maxX - box.size.width - 6),
                              y: min(max(bounds.minY + 6, origin.y), bounds.maxY - box.size.height - 6))
        let rect = NSRect(origin: clamped, size: box.size)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        box.text.draw(at: NSPoint(x: rect.minX + box.padding.width, y: rect.minY + box.padding.height))
    }

    /// 把若干行文本排成一个读数框：逐行上色（告警行用醒目色，否则用户看不出
    /// "到底了"和"还在滚"的差别），并算出框尺寸。
    private func makeBox(lines: [(text: String, color: NSColor)])
        -> (text: NSAttributedString, size: NSSize, padding: NSSize)? {
        let visible = lines.filter { !$0.text.isEmpty }
        guard !visible.isEmpty else { return nil }

        let attributed = NSMutableAttributedString()
        for (index, line) in visible.enumerated() {
            if index > 0 { attributed.append(NSAttributedString(string: "\n")) }
            attributed.append(NSAttributedString(string: line.text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: line.color,
            ]))
        }
        let padding = NSSize(width: 8, height: 5)
        let textSize = attributed.size()
        return (attributed,
                NSSize(width: textSize.width + padding.width * 2,
                       height: textSize.height + padding.height * 2),
                padding)
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

    private func globalToLocal(_ point: CGPoint) -> CGPoint {
        let origin = window?.frame.origin ?? .zero
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
}

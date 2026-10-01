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

    /// 浮动工具栏（ticket 20/21）。`nil` = 不显示 —— 还在拖拽、或者已经提交。
    var toolbar: OverlayToolbarPresentation?

    /// 就地标注的**坐标系原点**（Cocoa 全局点，即选区 / 窗口的左上角）。
    ///
    /// 标注本身存的是"相对原点的点坐标、y 向下"（`Annotation` 的约定），
    /// 视图只负责把它平移到原点上、再翻一次 y。这样覆盖层与导出
    /// 能用**同一份** `AnnotationDrawing`。
    var annotationOrigin: CGPoint?
    /// 就地标注（含正在画的那一笔草稿）。
    var annotations: [Annotation] = []

    /// 选中标注身上的控制点（**Cocoa 全局点**）。
    ///
    /// 与选区的控制点同一套画法与光标 —— 用户不该为"缩选区"和"缩标注"学两套手感。
    /// 但两者的坐标来源不同：选区控制点直接用 `globalRect`，标注控制点得从
    /// **选区局部点**换算过来（控制层做，那里才有 `annotationOrigin`）。
    var selectedAnnotationHandles: [AnnotationHandlePresentation] = []

    /// 被选中的标注的包围盒（**选区局部点**，与 `annotations` 同一坐标系）。
    ///
    /// 没有它的话，用户点完一个标注**看不出到底选中了没有** ——
    /// 而"选中了但没反应"与"没选中"在界面上完全一样。
    var selectedAnnotationFrames: [CGRect] = []

    /// 打码（马赛克 / 模糊）预览要用的底图。
    ///
    /// 覆盖层不铺整屏截图，所以这两类**拿不到底图就画不出来** —— 那时预览会跳过它们，
    /// 而导出仍然会应用（底图从真实采集里来）。这个差异必须让用户看见，
    /// 否则"导出图里有一块打码、预览里没有"会被当成灵异事件。
    var redactionBackdrop: RedactionBackdropPresentation?

    /// 是否画选区控制点（ticket 19）。选了标注工具时为 `false` ——
    /// 那时拖动是画标注，摆着控制点会让人以为能拖角。
    var showsSelectionHandles: Bool = false

    /// 吸附命中的提示线（**Cocoa 全局坐标**，各是一条贯穿全屏的线）。
    /// 没有提示线的话，用户只会觉得"这里有点顿"，说不上来在吸什么。
    var snapGuideVertical: CGFloat?
    var snapGuideHorizontal: CGFloat?

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

/// 打码预览的底图。
struct RedactionBackdropPresentation: Equatable {
    var image: CGImage?
    /// 底图每 1 个标注点对应多少像素（＝屏幕倍率）。传错只会让格子大小不对，不会崩。
    var scale: CGFloat = 1

    /// `CGImage` 没有值相等，按**引用**比 —— 同一个引用就不必重画。
    static func == (lhs: RedactionBackdropPresentation, rhs: RedactionBackdropPresentation) -> Bool {
        lhs.image === rhs.image && lhs.scale == rhs.scale
    }
}

/// 选中标注身上的一个控制点（ticket 22 收尾）。
///
/// 具名结构而不是元组：元组不能被 `Equatable` 合成，而 `SelectionPresentation` 是 `Equatable` 的
///（PITFALLS 71 踩过这一点）。
struct AnnotationHandlePresentation: Equatable {
    var handle: SelectionGeometry.Handle
    /// **Cocoa 全局点**
    var frame: CGRect
}

/// 浮动工具栏要画的东西（ticket 21/22）。
///
/// 几何**全部来自 `OverlayToolbar.layout()`** —— 视图自己不算任何一个坐标，
/// 否则"画出来的"与"点得到的"就会各走各的。
struct OverlayToolbarPresentation: Equatable {
    /// 工具条矩形，**Cocoa 全局坐标**
    var frame: CGRect
    /// 当前选中的工具（`nil` = 没在画标注）
    var activeTool: OverlayTool?
    /// 将要用的描边色
    var stroke: AnnotationColor
    /// 那三档尺寸**此刻代表哪一组值**：画图形时是线宽，画打码时是打码强度。
    ///
    /// 与编辑器同一套做法（同一排控件按上下文改不同的参数）。**不新增控件** ——
    /// 工具栏每多一格，整条就更宽，而它有一条"必须放得进 1024 点的屏"的硬约束。
    var sizeSlotValues: [CGFloat]
    /// 三档里当前选中的那一个（用**下标**而不是数值：两组值的数值范围不重叠，
    /// 拿数值比会一个都匹配不上，表现是"选中的那一档没有高亮"）。
    var sizeSlotIndex: Int
    /// 这三档**现在代表什么**（只影响画法：圆点 / 方块 / 字母 A）
    var sizeSlotMeaning: OverlaySizeMeaning
    /// 文字识别正在进行 —— 那一格换成"进行中"的样子并置灰。
    ///
    /// 不做这个的话，用户点了「识别文字」在界面上**看不到任何变化**
    /// （识别本身是异步的，首次还可能很久），看起来就是"点了没反应"。
    var isRecognizing: Bool
    var canUndo: Bool
    var canRedo: Bool
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
    /// 点在了浮动工具栏上（ticket 20）。坐标是 **Cocoa 全局点**，
    /// 由控制层用 `OverlayToolbar.button(at:in:)` 判断点的是哪个按钮 ——
    /// 视图只负责"这一下点在工具栏里"，不做语义判断。
    func overlayView(_ view: SelectionOverlayView, clickedToolbarAt globalPoint: CGPoint)

    // 文字输入框（ticket 22）。三条都来自那个真的 `NSTextField`：
    /// 框里的内容变了（每次击键）
    func overlayView(_ view: SelectionOverlayView, didChangeText text: String)
    /// 框里按了 `⏎`
    func overlayViewDidCommitText(_ view: SelectionOverlayView)
    /// 框里按了 `Esc`
    func overlayViewDidCancelText(_ view: SelectionOverlayView)

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
            // 控制点 / 选区变了就得重算光标区，否则"看着有控制点、拖起来却是十字"。
            // 标注身上那 8 个控制点同理 —— 漏掉它的话，刚选中一个标注时
            // 控制点画出来了，但把鼠标移上去还是十字（要等下一次别的变化才刷新）。
            if presentation.showsSelectionHandles != oldValue.showsSelectionHandles
                || presentation.globalRect != oldValue.globalRect
                || presentation.hoverRect != oldValue.hoverRect
                || presentation.selectedAnnotationHandles != oldValue.selectedAnnotationHandles {
                window?.invalidateCursorRects(for: self)
            }
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
            syncToolbarChrome()
        }
    }

    // MARK: - 工具条背景（ticket 17）

    /// 工具条的材质底。**必须是与前景并列的子视图**，不能挂在覆盖层自己身上 ——
    /// AppKit 里子视图永远画在父视图自己的 `draw` 之上（见 `ChromeForegroundView`）。
    private var toolbarChrome: NSView?
    /// 工具条的前景（描边 / 分隔线 / 图标）。
    private var toolbarForeground: ChromeForegroundView?

    /// 把工具条的两个子视图摆到当前位置。
    ///
    /// **不在 `draw` 里懒创建**：绘制过程中改视图树会让本次绘制作废，
    /// 表现是工具条第一次出现时闪一下。
    private func syncToolbarChrome() {
        guard let toolbar = presentation.toolbar else {
            toolbarChrome?.isHidden = true
            toolbarForeground?.isHidden = true
            return
        }

        if toolbarChrome == nil {
            let chrome = ChromeBackground.makeBackgroundView(cornerRadius: OverlayToolbar.cornerRadius)
            chrome.isHidden = true
            addSubview(chrome)
            toolbarChrome = chrome

            let foreground = ChromeForegroundView()
            foreground.isHidden = true
            // 前景自己不做几何判断：矩形就是它的 bounds，内部按工具条布局画。
            foreground.render = { [weak self] rect in self?.drawToolbarForeground(in: rect) }
            addSubview(foreground)
            toolbarForeground = foreground
        }

        let box = globalToLocal(toolbar.frame)
        toolbarChrome?.frame = box
        toolbarChrome?.isHidden = false
        toolbarForeground?.frame = box
        toolbarForeground?.isHidden = false
        toolbarForeground?.needsDisplay = true
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

        let point = cocoaPoint(of: event)
        // 工具栏优先于一切：点在它上面就是"按了个按钮"，**不能**落进拖拽逻辑 ——
        // 否则按住按钮挪一下就会把刚框好的选区改掉。
        //
        // 判据是"点在工具条的**整个矩形**里"而不是"点中了某一格"：
        // 格子之间有空隙，按在空隙上同样不该掉进拖拽（用户以为自己在按工具条）。
        if let toolbar = presentation.toolbar?.frame,
           OverlayToolbar.contains(point, in: toolbar) {
            delegate?.overlayView(self, clickedToolbarAt: point)
            return
        }

        if event.clickCount == 2 {
            delegate?.overlayViewDidRequestWholeScreen(self)
            return
        }
        delegate?.overlayView(self, beganDragAt: point)
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
        // 控制点上换成对应的缩放光标（ticket 19）。这是"这里能拖"的唯一提示 ——
        // 没有它，用户得先试一下才知道能不能拖角。
        // 选中标注身上的控制点（ticket 22 收尾）—— 同样是"这里能拖"的唯一提示。
        for item in presentation.selectedAnnotationHandles {
            addCursorRect(globalToLocal(item.frame), cursor: Self.cursor(for: item.handle))
        }

        guard presentation.showsSelectionHandles,
              let global = presentation.globalRect ?? presentation.hoverRect else { return }
        let local = globalToLocal(global)
        for handle in SelectionGeometry.Handle.allCases {
            addCursorRect(SelectionGeometry.handleFrame(handle, on: local),
                          cursor: Self.cursor(for: handle))
        }
    }

    private static func cursor(for handle: SelectionGeometry.Handle) -> NSCursor {
        switch handle {
        case .top: .frameResize(position: .top, directions: .all)
        case .bottom: .frameResize(position: .bottom, directions: .all)
        case .left: .frameResize(position: .left, directions: .all)
        case .right: .frameResize(position: .right, directions: .all)
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        }
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
            // 标注画在镂空**之后**：镂空是挖洞，标注要落在洞里那层图上
            drawAnnotations(clippingTo: localSelection)
            drawSnapGuides()
            drawReadout(in: localSelection, lines: readoutLines())
            if presentation.showsSelectionHandles {
                drawSelectionHandles(on: localSelection)
            }
            // 工具条**不在这里画**：它是两个子视图（背景 + 前景），
            // 由 `syncToolbarChrome()` 摆位。见那段注释。
            return
        }

        if let localHover, localHover.width >= 1, localHover.height >= 1 {
            let radius = presentation.hoverCornerRadius
            fillMask(punching: localHover, cornerRadius: radius)
            stroke(localHover, cornerRadius: radius, lineWidth: 2)
            // 窗口落点（单击某扇窗停住）同样能就地标注、同样能拖角，所以这两句也要
            drawAnnotations(clippingTo: localHover)
            drawSnapGuides()
            if !presentation.hoverLabel.isEmpty {
                drawReadout(in: localHover,
                            lines: [(presentation.hoverLabel, ReadoutStyle.normal)])
            }
            if presentation.showsSelectionHandles {
                drawSelectionHandles(on: localHover)
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

    // MARK: - 浮动工具栏（ticket 20/21）

    /// 画浮动工具栏的**前景**：描边、组间分隔线、图标。
    ///
    /// 背景（玻璃 / 材质）由 `toolbarChrome` 这个兄弟子视图负责，不在这里画 ——
    /// 在这里画的话会被那个子视图盖住（AppKit 的绘制顺序）。
    ///
    /// 所有坐标一律来自 `OverlayToolbar.layout()` —— **绘制与命中同一个来源**。
    /// 各画各的必然偏出去几个点，而那种偏差的表现是"按钮看着在这儿、点它没反应"，
    /// 极难联想到是布局算错了。
    private func drawToolbarForeground(in box: NSRect) {
        guard let state = presentation.toolbar else { return }
        let layout = OverlayToolbar.layout()

        let outline = Self.roundedPath(box.insetBy(dx: 0.5, dy: 0.5), radius: OverlayToolbar.cornerRadius)
        outline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.12).setStroke()
        outline.stroke()

        NSColor.white.withAlphaComponent(0.14).setFill()
        for separator in layout.separators {
            NSRect(x: box.minX + separator.minX,
                   y: box.minY + separator.minY,
                   width: separator.width,
                   height: separator.height).fill()
        }

        for item in layout.items {
            draw(toolbarItem: item.slot,
                 in: item.frame.offsetBy(dx: box.minX, dy: box.minY),
                 state: state)
        }
    }

    private func draw(toolbarItem slot: OverlayToolbar.Slot,
                      in rect: CGRect,
                      state: OverlayToolbarPresentation) {
        switch slot {
        case .tool(let tool):
            let active = state.activeTool == tool
            if active { highlight(rect) }
            drawSymbol(Self.symbol(for: tool),
                       in: rect,
                       tint: active ? .controlAccentColor : .white)
        case .color(let index):
            drawColorSwatch(AnnotationPalette.colors[index],
                            in: rect,
                            selected: state.stroke == AnnotationPalette.colors[index])
        case .lineWidth(let index):
            drawSizeSwatch(value: state.sizeSlotValues[index],
                           meaning: state.sizeSlotMeaning,
                           in: rect,
                           selected: state.sizeSlotIndex == index)
        case .ocr:
            drawSymbol(state.isRecognizing ? "hourglass" : "text.viewfinder",
                       in: rect,
                       tint: .white,
                       dimmed: state.isRecognizing)
        case .pin:
            drawSymbol("pin", in: rect, tint: .white)
        case .undo:
            drawSymbol("arrow.uturn.backward", in: rect, tint: .white, dimmed: !state.canUndo)
        case .redo:
            drawSymbol("arrow.uturn.forward", in: rect, tint: .white, dimmed: !state.canRedo)
        case .save:
            drawSymbol("square.and.arrow.down", in: rect, tint: .white)
        case .cancel:
            drawSymbol("xmark", in: rect, tint: .white)
        case .confirm:
            drawSymbol("checkmark", in: rect, tint: Self.confirmColor)
        }
    }

    private static let confirmColor = NSColor(red: 0.24, green: 0.82, blue: 0.42, alpha: 1)

    /// 图标名与编辑器**保持一致** —— 同一个功能在两处用不同图标，
    /// 用户会以为是两个不同的东西。
    private static func symbol(for tool: OverlayTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .mosaic: "checkerboard.rectangle"
        case .blur: "camera.filters"
        }
    }

    /// 选中态的底：一个比格子略小的圆角块。
    private func highlight(_ rect: CGRect) {
        NSColor.white.withAlphaComponent(0.18).setFill()
        Self.roundedPath(rect.insetBy(dx: -1, dy: -1), radius: 6).fill()
    }

    private func drawColorSwatch(_ color: AnnotationColor, in rect: CGRect, selected: Bool) {
        let side = rect.width * 0.68
        let circle = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let path = NSBezierPath(ovalIn: circle)
        NSColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha).setFill()
        path.fill()
        // 一圈描边不能省：白色的色块在深色工具条上没有边就糊成一团光
        path.lineWidth = selected ? 2 : 1
        (selected ? NSColor.white : NSColor.white.withAlphaComponent(0.35)).setStroke()
        path.stroke()
    }

    /// 尺寸档用**它本身的大小**表达 —— 写数字（2/4/8）既看不懂又占地方。
    ///
    /// 三组值的范围互相重叠（线宽 2–8、打码强度 4–16、字号 18–44 点），
    /// 光看大小分不清"现在调的是哪一组"，所以形状也不一样：
    /// 线宽＝圆点、打码强度＝方块、字号＝一个"字"。
    private func drawSizeSwatch(value: CGFloat,
                                meaning: OverlaySizeMeaning,
                                in rect: CGRect,
                                selected: Bool) {
        if selected { highlight(rect) }

        switch meaning {
        case .lineWidth, .redactionStrength:
            let side = min(rect.width - 4, 4 + value * 1.4)
            let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                             width: side, height: side)
            NSColor.white.setFill()
            if meaning == .redactionStrength {
                NSBezierPath(rect: box).fill()
            } else {
                NSBezierPath(ovalIn: box).fill()
            }
        case .fontSize:
            // 画一个"字"：用真正的字号缩小到格子能装下的尺寸。
            // 直接在 20 点的格子里画 44 点的字会糊成一团黑，所以按格高归一化，
            // 但**保留三档之间的相对大小** —— 用户要能一眼看出"这档更大"。
            let normalized = 9 + (value - AnnotationPalette.overlayFontSizes[0]) * 0.28
            let font = NSFont.systemFont(ofSize: max(9, min(rect.height - 6, normalized)),
                                         weight: .semibold)
            let text = "A" as NSString
            let size = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2),
                      withAttributes: [.font: font, .foregroundColor: NSColor.white])
        }
    }

    private func drawSymbol(_ symbol: String,
                            in rect: CGRect,
                            tint: NSColor,
                            dimmed: Bool = false) {
        // ⚠️ 模板图直接 `draw(in:)` **不会**用"当前颜色"着色 —— 必须把颜色放进配置里。
        // 否则图标全是黑的，在深色底上等于没画（而且不报错，只会让人以为图标名写错了）。
        let color = dimmed ? tint.withAlphaComponent(0.28) : tint
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
            .applying(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }

        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2,
                              y: rect.midY - size.height / 2,
                              width: size.width,
                              height: size.height))
    }

    // MARK: - 就地标注（ticket 21）

    /// 画就地标注。
    ///
    /// 坐标系：标注存的是"相对选区左上角、y 向下"的点（`Annotation` 的约定），
    /// 而 AppKit 视图是"原点左下、y 向上"。所以这里平移 + 翻一次 y，
    /// 之后就能**直接复用导出的那份绘制代码**（`AnnotationDrawing`）——
    /// 覆盖层里看到的与最终导出的因此不可能对不上。
    ///
    /// 裁剪到选区内：标注画到选区外面会落在变暗的蒙层上，看起来像"跑出去了"。
    private func drawAnnotations(clippingTo clip: CGRect) {
        guard let origin = presentation.annotationOrigin,
              !presentation.annotations.isEmpty,
              let cgContext = NSGraphicsContext.current?.cgContext else { return }

        let local = globalToLocal(origin)
        cgContext.saveGState()
        cgContext.clip(to: clip)
        cgContext.translateBy(x: local.x, y: local.y)
        cgContext.scaleBy(x: 1, y: -1)
        AnnotationDrawing.draw(presentation.annotations,
                               in: cgContext,
                               colorSpace: window?.colorSpace?.cgColorSpace
                                   ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                               source: presentation.redactionBackdrop?.image,
                               // 标注坐标是点、底图是像素 —— 这个倍率不传下去，
                               // 马赛克格子会小一半（而"格子小了点"只会被当成强度没调对）
                               sourceScale: presentation.redactionBackdrop?.scale ?? 1)

        // 选中框画在**同一个翻转后的坐标系**里，于是它跟着标注一起走，
        // 不用再算一次"标注坐标 → 视图坐标"（那种换算写两遍必然会有一遍写错）。
        let selected = presentation.selectedAnnotationFrames
        if !selected.isEmpty {
            cgContext.setStrokeColor(NSColor.controlAccentColor.cgColor)
            cgContext.setLineWidth(1)
            cgContext.setLineDash(phase: 0, lengths: [5, 3])
            for frame in selected {
                cgContext.stroke(frame.insetBy(dx: -3, dy: -3))
            }
            cgContext.setLineDash(phase: 0, lengths: [])
        }
        cgContext.restoreGState()

        // 控制点画在**视图坐标**里（不跟着上面那次翻转）：
        // 它们来自"全局 → 局部"的换算，本来就不在标注坐标系里，
        // 混进那个翻转过的上下文反而会多一层镜像要维护。
        drawAnnotationHandles()
    }

    // MARK: - 选区控制点与吸附提示（ticket 19）

    /// 画八个控制点。尺寸与命中区都取自 `SelectionGeometry` —— 各写一份的话，
    /// 会出现"小方块画在这儿、可拖的是旁边那一点"，而这种偏差肉眼几乎看不出来。
    private func drawSelectionHandles(on localSelection: CGRect) {
        let side = SelectionGeometry.handleVisualSide
        for handle in SelectionGeometry.Handle.allCases {
            let center = handle.center(on: localSelection)
            let box = CGRect(x: center.x - side / 2,
                             y: center.y - side / 2,
                             width: side,
                             height: side)
            let path = NSBezierPath(rect: box)
            // 白底 + 强调色描边：白底在深色蒙层上看得见，描边在浅色内容上也看得见
            NSColor.white.setFill()
            path.fill()
            path.lineWidth = 1
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    /// 画吸附提示线：一条贯穿屏幕的细线，标出"吸到了哪条边"。
    ///
    /// 没有它的话，用户只会觉得"拖到这里有点顿"，说不出在吸什么 ——
    /// 而"可感知"恰恰是吸附能不能用的关键。
    private func drawSnapGuides() {
        let vertical = presentation.snapGuideVertical.map { globalToLocal(CGPoint(x: $0, y: 0)).x }
        let horizontal = presentation.snapGuideHorizontal.map { globalToLocal(CGPoint(x: 0, y: $0)).y }
        guard vertical != nil || horizontal != nil else { return }

        let path = NSBezierPath()
        if let vertical {
            path.move(to: CGPoint(x: vertical, y: bounds.minY))
            path.line(to: CGPoint(x: vertical, y: bounds.maxY))
        }
        if let horizontal {
            path.move(to: CGPoint(x: bounds.minX, y: horizontal))
            path.line(to: CGPoint(x: bounds.maxX, y: horizontal))
        }
        path.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
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
        // 刻意用平的深色而不是材质：这是贴着选区的小读数，尺寸随内容变、位置跟着光标跑，
        // 做成视图既难对齐也不划算；系统自带的截图工具在同一位置也是平的深色小条。
        NSColor.black.withAlphaComponent(ChromeStyle.readoutAlpha).setFill()
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

    // MARK: - 文字输入框（ticket 22）

    /// 输入框尺寸与字号。
    ///
    /// **故意不跟标注的字号走**：它是一个**控件**，不是所见即所得的预览 ——
    /// 44 点的标注字号会做出一个 60 点高的白条糊在图上，反而看不清输入了什么
    /// （编辑器里那个输入框也是固定 13 点，同理）。真正的字号在提交后才生效。
    private static let textInputSize = CGSize(width: 240, height: 26)
    private static let textInputFontSize: CGFloat = 14

    /// 正在编辑时挂着的输入框。`nil` = 没有。
    private var textInput: NSTextField?

    /// 挂出输入框、把键盘焦点交给它。
    ///
    /// 用真的 `NSTextField` 而不是自绘：**中文输入法的候选窗、联想、光标全都要靠它**，
    /// 自己收 `keyDown` 就等于自己实现一遍输入法（那是个无底洞）。
    /// 前提是面板能成为 key window —— 已实测（2026-10-01）：
    /// `panel.isKeyWindow=true firstResponder=true`。这条探针还在 `present()` 里留着。
    func showTextInput(for annotation: Annotation, text: String) {
        let field = textInput ?? makeTextInput()
        textInput = field
        field.delegate = self
        field.stringValue = text
        field.frame = textInputFrame(for: annotation)

        if field.superview !== self {
            addSubview(field)
        }
        window?.makeFirstResponder(field)
        // 光标落到末尾：用户接着上一次的内容继续改（而不是每次都从头覆盖）
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    /// 把撤销 / 重做转给**输入框自己**。
    ///
    /// 编辑中的"撤销"该是"撤销我刚打的字"（与在框里按 `⌘Z` 走的是同一个 undo manager），
    /// 而不是去撤销整张图的标注 —— 后者会把用户刚敲的一整行连同上一笔标注一起收走。
    ///
    /// - Returns: 输入框还能撤（重做）时为 `true`；没在编辑或没得撤时为 `false`。
    func undoTextInput(redo: Bool) -> Bool {
        guard let manager = textInput?.currentEditor()?.undoManager else { return false }
        if redo {
            guard manager.canRedo else { return false }
            manager.redo()
            return true
        }
        guard manager.canUndo else { return false }
        manager.undo()
        return true
    }

    /// 画选中标注身上的 8 个控制点。样式与选区控制点**一致**（白底 + 强调色描边）。
    private func drawAnnotationHandles() {
        for item in presentation.selectedAnnotationHandles {
            let box = globalToLocal(item.frame)
            let path = NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// 输入框里当前的文本（没有输入框时为 `nil`）。
    var textInputText: String? { textInput?.stringValue }

    /// 收掉输入框，并把键盘焦点还给覆盖层自己。
    func hideTextInput() {
        guard let field = textInput else { return }
        // 先还焦点再拆视图：直接 `removeFromSuperview` 一个正在编辑的 `NSTextField`
        // 会让它的 field editor 留在一个已经不在视图树里的控件上。
        if window?.firstResponder === field.currentEditor() {
            window?.makeFirstResponder(self)
        }
        field.delegate = nil
        field.removeFromSuperview()
        textInput = nil
    }

    private func makeTextInput() -> NSTextField {
        let field = NSTextField(frame: CGRect(origin: .zero, size: Self.textInputSize))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .white
        field.textColor = .black
        field.font = .systemFont(ofSize: Self.textInputFontSize)
        field.placeholderString = "输入文字"
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.layer?.borderWidth = 2
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        // 不用 `NSTextField.lineBreakMode`：单行标注，换行会画到框外
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    /// 输入框该放哪（**视图坐标**）。
    ///
    /// 这是唯一一处"把标注坐标换回视图坐标"的地方：标注存的是**选区局部点**
    /// （原点＝选区视觉左上角、y 向下），而 `NSView` 的坐标是原点左下、y 向上。
    /// 换算错的表现是输入框跑到选区外面去 —— 而它看起来只是"点错位置了"。
    private func textInputFrame(for annotation: Annotation) -> CGRect {
        guard let origin = presentation.annotationOrigin else {
            return CGRect(origin: .zero, size: Self.textInputSize)
        }
        let box = annotation.frame.standardized
        let topLeft = globalToLocal(origin)
        let size = Self.textInputSize
        let wanted = CGRect(x: topLeft.x + box.minX,
                            y: topLeft.y - box.minY - size.height,
                            width: size.width,
                            height: size.height)

        // 夹进视图：点击靠近屏幕边缘时输入框会整个跑到屏幕外，
        // 而"看不见输入框"的表现与"点了没反应"一模一样。
        let limit = bounds.insetBy(dx: 4, dy: 4)
        return CGRect(x: min(max(limit.minX, wanted.minX), max(limit.minX, limit.maxX - size.width)),
                      y: min(max(limit.minY, wanted.minY), max(limit.minY, limit.maxY - size.height)),
                      width: size.width,
                      height: size.height)
    }
}

extension SelectionOverlayView: NSTextFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        delegate?.overlayView(self, didChangeText: field.stringValue)
    }

    /// `⏎` / `Esc` 走这里，而不是 `NSTextField` 的 target-action ——
    /// 用同一个入口收两个键，就不会出现"回车能提交、Esc 却漏了"这种事。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            delegate?.overlayViewDidCommitText(self)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.overlayViewDidCancelText(self)
            return true
        default:
            return false
        }
    }
}

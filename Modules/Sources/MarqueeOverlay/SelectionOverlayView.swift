import AppKit
import MarqueeCore

/// 覆盖层要画的东西。由控制器算好、推给每个面板的视图。
///
/// 视图**不做任何几何判断**：它只负责把全局坐标转成自己窗口内的坐标然后画。
/// 选区的真相在控制器（以及 Core 的状态机）手里，多屏时才不会各画各的。
struct SelectionPresentation: Equatable {
    /// 当前选区，**Cocoa 全局坐标**；`nil` = 还没拉出选区
    var globalRect: CGRect?
    /// 悬停窗口，**Cocoa 全局坐标**；拖选区时为 `nil`
    var hoverRect: CGRect?
    /// 系统窗口圆角的近似值。没有 API 给出真实圆角，10 点贴近近年 macOS 普通窗口
    var hoverCornerRadius: CGFloat
    /// 长截图正在抓帧。此时读数换成进度与提示，选区描边加粗
    var isScrollCapturing: Bool = false
    /// **读数框里要显示的行**，顺序即上下顺序。空数组 = 不画读数框。
    ///
    /// 三种内容共用一个框（设计稿 §08「读数框当唯一的发言人」）：
    /// 落点前说颜色、落点后说尺寸、长截图里说进度 —— 只换内容不换位置，
    /// 用户不需要学两个框。
    ///
    /// ⚠️ 原先这里是**六个平行的字符串字段**（`sizeText` / `originText` / `hoverLabel` /
    /// `actionHintText` / `scrollStatusText` / `scrollHintText` / `scrollWarningText`），
    /// 而"每一行是什么角色"由绘制方当场 `switch` 决定。那样顺序与角色都是隐式的 ——
    /// 改一个 `if` 的次序就换了层级，而没有任何东西会红。现在它们都是数据。
    var readout: [ReadoutLine] = []
    /// 空状态提示的锚点（**Cocoa 全局坐标**，一般就是鼠标位置）
    ///
    /// 为什么要有它：长截图进入后还没选目标时，既没有选区也没有悬停窗口，
    /// 视图只能画一层蒙层 —— 用户看不出覆盖层在工作，会以为"拖不了"。
    /// 在光标旁挂一句提示，是最省事也最直接的"这里可以操作"信号。
    var hintAnchor: CGPoint?
    /// 空状态提示文字
    var hintText: String = ""
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

    /// 鼠标该显示成什么样（ticket 26）。
    ///
    /// 几何在这里、**规则在 Core**（`OverlayCursor.kind(at:in:)`）：视图只负责
    /// 拿当前点问一次、然后把答案换成 `NSCursor`。
    ///
    /// 为什么不继续用 `resetCursorRects`：光标要按**标注自己的形状**判（箭头是斜的、
    /// 包围盒里大半是空白），而 cursor rect 只能表达矩形。近似成包围盒的结果是
    /// "箭头旁边的空白处也伸出一只可拖的手"，点下去却什么都没选中。
    var cursor: OverlayCursorContext = .empty

    /// 吸附命中的提示线（**Cocoa 全局坐标**，各是一条贯穿全屏的线）。
    /// 没有提示线的话，用户只会觉得"这里有点顿"，说不上来在吸什么。
    var snapGuideVertical: CGFloat?
    var snapGuideHorizontal: CGFloat?

    static let empty = SelectionPresentation(globalRect: nil,
                                             hoverRect: nil,
                                             hoverCornerRadius: 10)

    /// 除放大镜之外的部分是否相等。用来判断"是不是只有放大镜在动"。
    func equalsIgnoringMagnifier(_ other: SelectionPresentation) -> Bool {
        var lhs = self
        var rhs = other
        lhs.magnifier = nil
        rhs.magnifier = nil
        return lhs == rhs
    }

    /// 除工具条的悬停态之外，其余是否相等。用来判断"是不是只有鼠标在格子上扫"。
    ///
    /// ⚠️ 判据是**工具条那一整块**相等，不是"只把 `hoveredSlot` 抹掉"：
    /// 抹掉再比会把"工具条整体移动了位置"也算成"只有悬停变了" ——
    /// 那种情况下覆盖层自己也得重画（选区镂空的提示行位置跟着变），
    /// 而漏掉它的表现是"工具条移过去了、原地留了一条残影"。
    func equalsIgnoringToolbarHover(_ other: SelectionPresentation) -> Bool {
        guard var lhs = toolbar, var rhs = other.toolbar else { return false }
        lhs.hoveredSlot = nil
        rhs.hoveredSlot = nil
        var mine = self, theirs = other
        mine.toolbar = lhs
        theirs.toolbar = rhs
        return mine == theirs
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
    /// 工具条上展开的那个弹层（`nil` = 没展开）。
    ///
    /// 色板与尺寸**不再各占一格**：12 格把整条撑到 799 点，而参考的那条只有一排图标。
    /// 收进面板之后整条降到 ~545 点，也让工具格重新成为视觉重心。
    var palette: OverlayPalettePresentation?
    /// 升级卡片（`nil` = 没弹）。被挡住时**原地**弹在工具条旁边。
    var proCard: ProCardPresentation?
    /// 此刻**锁着的** Pro 能力。那几格的图标上会补一个小锁角标。
    ///
    /// 只说"哪些能力被挡"，不说"哪一格" —— 格与能力的对应在
    /// `OverlayToolbarSlot.proFeature` 里，视图按它查。两份映射必然分叉。
    var lockedFeatures: Set<ProFeature> = []

    /// 鼠标此刻压在**哪一格**上（`nil` = 不在任何格子上）。
    ///
    /// ## 为什么这个值要烘进 presentation 而不是让视图自己跟踪
    ///
    /// 因为它**不是一个纯粹的视觉状态**：它决定的是"这一下按下去会碰到什么"的预告，
    /// 而"哪一格在哪"这件事的真相在 `OverlayToolbar.layout()`（Core）手里。
    /// 视图自己拿 `bounds` 去推一遍的话，就会出现"高亮在这里、可点的是旁边那一格" ——
    /// 而那种偏差肉眼几乎看不出来（PITFALLS 里那条"绘制与命中必须同一来源"）。
    ///
    /// 控制层每次 `mouseMoved` 用 `OverlayToolbar.slot(at:in:)` 算一次推过来。
    var hoveredSlot: OverlayToolbarSlot?
}

/// 升级卡片要画什么。
///
/// 位置**从工具条的矩形算**（`ProCardLayout.frame`），与弹层同一个套路 ——
/// 卡片与工具条各算各的，必然出现"卡片飘在离工具条半格的地方"，
/// 而那种偏差看起来像是设计如此。
struct ProCardPresentation: Equatable {
    /// 卡片矩形，**Cocoa 全局坐标**
    var frame: CGRect
    /// 有哪两个按钮、分别是什么动作（标题与正文由视图按 `reason` 取）
    var content: ProCardContent
}

/// 工具条上展开的弹层要画什么。
struct OverlayPalettePresentation: Equatable {
    var kind: OverlayPalette
    /// 弹层矩形，**Cocoa 全局坐标**
    var frame: CGRect
    var stroke: AnnotationColor
    /// 三档尺寸此刻的数值与选中档（含义由 `sizeSlotMeaning` 决定）
    var sizeSlotValues: [CGFloat]
    var sizeSlotIndex: Int
    var sizeSlotMeaning: OverlaySizeMeaning
    /// 表情面板里当前选中的那一个（下标）
    var selectedEmojiIndex: Int
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
    var colorLines: [ReadoutLine]
    /// 复制之后的反馈（如「已复制 #1A2B3C」）
    var statusText: String?

    /// `CGImage` 没有值相等，按**引用**比 —— 同一个引用就不必重画。
    ///
    /// ⚠️ 这里从前还得**手工比一遍文字**（因为行是 `(String, NSColor)` 元组，
    /// 元组不合成 `Equatable`，而 `NSColor` 又没法比）。
    /// 换成 `ReadoutLine` 之后那一整段消失了：颜色不在数据里，文字本身可等。
    static func == (lhs: MagnifierPresentation, rhs: MagnifierPresentation) -> Bool {
        lhs.lensImage === rhs.lensImage
            && lhs.boxRect == rhs.boxRect
            && lhs.sampleMarkerSize == rhs.sampleMarkerSize
            && lhs.statusText == rhs.statusText
            && lhs.colorLines == rhs.colorLines
    }
}

@MainActor
protocol SelectionOverlayViewDelegate: AnyObject {
    func overlayView(_ view: SelectionOverlayView, beganDragAt globalPoint: CGPoint)
    func overlayView(_ view: SelectionOverlayView, draggedTo globalPoint: CGPoint)
    func overlayView(_ view: SelectionOverlayView, endedDragAt globalPoint: CGPoint, optionDown: Bool)
    func overlayView(_ view: SelectionOverlayView, movedTo globalPoint: CGPoint)
    /// 鼠标离开了这块屏。**悬停态必须一起清掉** ——
    /// "手不在了"这件事没有坐标可以表达，所以它得单独有一条消息。
    func overlayViewDidExit(_ view: SelectionOverlayView)
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
    /// 点在了展开的弹层上（色板/尺寸 或 表情）。坐标同样是 **Cocoa 全局点**，
    /// 语义判断（点到哪一格、是选色还是选尺寸）留给控制层。
    func overlayView(_ view: SelectionOverlayView, clickedPaletteAt globalPoint: CGPoint)
    /// 点在了升级卡片上（ticket 31）。坐标同样是 **Cocoa 全局点**，
    /// 语义判断（点到哪个按钮、点到空白该怎么办）留给控制层 ——
    /// 视图只回答"这一下点在卡片里"。
    func overlayView(_ view: SelectionOverlayView, clickedProCardAt globalPoint: CGPoint)

    // 文字输入框（ticket 22）。三条都来自那个真的 `NSTextField`：
    /// 框里的内容变了（每次击键）
    func overlayView(_ view: SelectionOverlayView, didChangeText text: String)
    /// 框里按了 `⏎`
    func overlayViewDidCommitText(_ view: SelectionOverlayView)
    /// 框里按了 `Esc`
    func overlayViewDidCancelText(_ view: SelectionOverlayView)

    func overlayViewDidRequestCancel(_ view: SelectionOverlayView)
}

/// 读数框的行色。
///
/// ⚠️ **这里不定义任何颜色** —— 它只是把 Core 的 `ReadoutRole` 翻成 `NSColor`。
/// 颜色值在 `ChromePalette.Overlay.Readout`（唯一来源），
/// 而"每一枚够不够亮""主副差几档"在 `OverlayReadoutTests` 里是可执行断言。
///
/// 以前这里是三个写死的 `NSColor`（`white` / `systemOrange` / `white 75%`），
/// 于是同一块屏幕上出现了**第二套颜色 + 第二把尺子**：
/// 稿子量的是 `#f8c20d`，代码给的是 `systemOrange`；
/// 稿子说提示行是白 64%，代码给的是 75%。两处都不会报错，只会"看着差点意思"。
enum ReadoutStyle {

    static func color(_ role: ReadoutRole) -> NSColor { role.color.nsColor }

    /// 主角行（尺寸 / 颜色 / 已拼高度）。
    static let primary = color(.primary)
    /// 副手行（位置、rgb、一句轻提示）。
    static let secondary = color(.secondary)
    /// 「此刻 `⌥` 会改变结果」那一行 —— 以及长截图的告警。
    ///
    /// 两者共用一枚是**有意的**：稿子里「不含阴影」与「已经滚到底了」用的是同一枚琥珀
    /// （`--c-warn`），含义也一致 —— 都是"注意，这一条会改变结果"。
    static let caution = color(.caution)
}

/// `RGB`（Core 的 sRGB 值）→ `NSColor`。**两条都不能省**：
///
/// · **alpha 要带上** —— 调色板里一半的颜色是半透明的（暗幕 32%、次要文字 64%、
///   格图标 82%、置灰 30%、小锁 55%…）。曾经这里写死 `alpha: 1`，
///   等于把「半透明」这个信息**在最后一步丢掉了** —— 画出来全是实心，
///   而画错的颜色不会报错，只会「看着差点意思」。
/// · **用 `srgbRed:` 而不是 `red:`** —— 后者是 deviceRGB，
///   而设计稿给的十六进制是 sRGB。
///
/// 放在 `RGB` 上而不是视图里，是因为**不止视图要用它**：
/// `ReadoutStyle` 那三个 `static let` 是全局初始化，走不了实例上的方法。
extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
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
            } else if !presentation.equalsIgnoringToolbarHover(oldValue) {
                needsDisplay = true
            }
            // ↑ 「只有悬停态在变」时**两件事都不做**：覆盖层自己的 `draw` 里
            //   没有任何一个像素依赖 `hoveredSlot`（工具条是两个子视图画的），
            //   而那条 513 × 40 的前景由下面这一句负责重画。
            //
            //   写 `needsDisplay = false` 是不对的：那会把上一帧还挂着的重绘请求一起取消掉。
            //   "什么都不做"才是这里准确的意思。
            syncToolbarChrome()
            // 内容变了光标也可能变（选区落点、弹出面板、选中标注…），而**鼠标可能一动没动** ——
            // 只靠 `mouseMoved` 更新的话，用户会看到"控制点出来了、光标还是十字"。
            applyCursor(at: NSEvent.mouseLocation)
        }
    }

    // MARK: - 工具条与弹层的背景（ticket 17 / 24）

    /// 工具条的材质底。**必须是与前景并列的子视图**，不能挂在覆盖层自己身上 ——
    /// AppKit 里子视图永远画在父视图自己的 `draw` 之上（见 `ChromeForegroundView`）。
    private var toolbarChrome: NSView?
    /// 工具条的前景（描边 / 分隔线 / 图标）。
    private var toolbarForeground: ChromeForegroundView?
    /// 弹层的材质底与前景。与工具条同一套做法。
    private var paletteChrome: NSView?
    private var paletteForeground: ChromeForegroundView?
    /// 升级卡片的材质底与前景。同上。
    private var proCardChrome: NSView?
    private var proCardForeground: ChromeForegroundView?

    /// 上一次同步过去的工具条 / 弹层内容（含位置）。
    ///
    /// ⚠️ 有它才有"只在**真的变了**的时候才让子视图重画"这条：
    /// `presentation` 的 `didSet` 里有一条快路径 —— "只有放大镜在动"时只重画光标周围一小块。
    /// 若在这里无条件 `needsDisplay = true`，那条快路径会被抵消：
    /// **鼠标每动一下都要把整条工具条重画一遍**（15 个图标）。那是可感的卡顿。
    private var syncedToolbar: OverlayToolbarPresentation?
    private var syncedPalette: OverlayPalettePresentation?
    private var syncedProCard: ProCardPresentation?

    /// 把工具条与弹层的子视图摆到当前位置。
    ///
    /// **不在 `draw` 里懒创建**：绘制过程中改视图树会让本次绘制作废，
    /// 表现是它第一次出现时闪一下。
    private func syncToolbarChrome() {
        guard let toolbar = presentation.toolbar else {
            // 收起时把这些标记清掉，下次出现才会重新同步一遍
            syncedToolbar = nil
            syncedPalette = nil
            syncedProCard = nil
            toolbarChrome?.isHidden = true
            toolbarForeground?.isHidden = true
            paletteChrome?.isHidden = true
            paletteForeground?.isHidden = true
            proCardChrome?.isHidden = true
            proCardForeground?.isHidden = true
            return
        }

        if syncedToolbar != toolbar {
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
            syncedToolbar = toolbar
        }

        syncProCardChrome(toolbar.proCard)

        guard let palette = toolbar.palette else {
            if syncedPalette != nil {
                syncedPalette = nil
                paletteChrome?.isHidden = true
                paletteForeground?.isHidden = true
            }
            return
        }

        guard syncedPalette != palette else { return }

        if paletteChrome == nil {
            let chrome = ChromeBackground.makeBackgroundView(cornerRadius: OverlayToolbar.cornerRadius)
            chrome.isHidden = true
            addSubview(chrome)
            paletteChrome = chrome

            let foreground = ChromeForegroundView()
            foreground.isHidden = true
            foreground.render = { [weak self] rect in self?.drawPaletteForeground(in: rect) }
            addSubview(foreground)
            paletteForeground = foreground
        }

        let paletteBox = globalToLocal(palette.frame)
        paletteChrome?.frame = paletteBox
        paletteChrome?.isHidden = false
        paletteForeground?.frame = paletteBox
        paletteForeground?.isHidden = false
        paletteForeground?.needsDisplay = true
        syncedPalette = palette
    }

    /// 摆放升级卡片的子视图。
    ///
    /// 与弹层同一套做法（材质底 + 前景两个**兄弟**视图），但它**单独抽成一个方法**：
    /// 弹层那段末尾有一句"没变就 `return`"的早退，卡片若挨着写在它后面会被一起跳过 ——
    /// 而"卡片有时候不出现"这种 bug 极难复现，正是 PITFALLS 里那类静默错。
    private func syncProCardChrome(_ card: ProCardPresentation?) {
        guard let card else {
            if syncedProCard != nil {
                syncedProCard = nil
                proCardChrome?.isHidden = true
                proCardForeground?.isHidden = true
            }
            return
        }
        guard syncedProCard != card else { return }

        if proCardChrome == nil {
            let chrome = ChromeBackground.makeBackgroundView(cornerRadius: OverlayToolbar.cornerRadius)
            chrome.isHidden = true
            addSubview(chrome)
            proCardChrome = chrome

            let foreground = ChromeForegroundView()
            foreground.isHidden = true
            foreground.render = { [weak self] rect in self?.drawProCardForeground(in: rect) }
            addSubview(foreground)
            proCardForeground = foreground
        }

        let box = globalToLocal(card.frame)
        proCardChrome?.frame = box
        proCardChrome?.isHidden = false
        proCardForeground?.frame = box
        proCardForeground?.isHidden = false
        proCardForeground?.needsDisplay = true
        syncedProCard = card
    }

    /// 放大镜占的脏区（局部坐标）。色值框贴在盒子上下、文字还可能很宽，保守地多扩一圈。
    private func dirtyRect(for magnifier: MagnifierPresentation) -> CGRect {        globalToLocal(magnifier.boxRect)
            .insetBy(dx: -130, dy: -100)
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)

        let point = cocoaPoint(of: event)
        // 升级卡片最优先：它是最晚弹出来的那一层。
        //
        // 而且它的矩形**整块吃掉点击**（不像工具条还要再判格子）—— 卡片里只有两个按钮，
        // 点在正文或空白处该做什么由控制层决定（现在是什么都不做，见
        // `overlayView(_:clickedProCardAt:)`）。这一条与"手抖一下不能变成买了"直接相关：
        // 判定放在视图里的话，以后加一个"点空白关掉卡片"就得同时改两处。
        if let card = presentation.toolbar?.proCard?.frame, card.contains(point) {
            delegate?.overlayView(self, clickedProCardAt: point)
            return
        }
        // 弹层次之：它压在工具条外侧，判定要排在工具条前面 ——
        // 反过来先判工具条的话，两者重叠的那几个点上会点到工具条。
        if let palette = presentation.toolbar?.palette?.frame, palette.contains(point) {
            delegate?.overlayView(self, clickedPaletteAt: point)
            return
        }
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
        let point = cocoaPoint(of: event)
        delegate?.overlayView(self, draggedTo: point)
        // ⚠️ 拖拽中**不会**有 `mouseMoved`（走的是这条），而拖拽恰恰是最需要光标反馈的时候：
        // 拖控制点时手型/箭头要一直跟着，松手前不能跳回十字。
        applyCursor(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.overlayView(self, endedDragAt: cocoaPoint(of: event),
                              optionDown: event.modifierFlags.contains(.option))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = cocoaPoint(of: event)
        delegate?.overlayView(self, movedTo: point)
        applyCursor(at: point)
    }

    /// 鼠标离开这块屏（走到别块屏、或者移出屏幕）。
    ///
    /// ⚠️ **必须有这一条**：悬停高亮是"手在这"的表示，而"手不在了"这件事
    /// **不会**由 `mouseMoved` 告诉任何人 —— 光标走了就再没有坐标可算。
    /// 少了它，被高亮的那一格会一直亮着，直到用户又把它扫一遍。
    override func mouseExited(with event: NSEvent) {
        delegate?.overlayViewDidExit(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `.mouseEnteredAndExited` 与 `.mouseMoved` **要一起给**：
        // 进入/离开是"手在不在"，移动是"手在哪儿"。只给后者的话，
        // 悬停态有"进去"没有"出来"（见 `mouseExited`）。
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved,
                                                 .mouseEnteredAndExited, .inVisibleRect],
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

    // MARK: - 光标（ticket 26）

    /// 上一次设上去的光标。
    ///
    /// 同一个值不重复 `set()`：鼠标移动是每帧都来的，每帧重设一次光标会让它**闪**，
    /// 而且这种闪烁看起来像是系统卡了一下。
    private var appliedCursor: OverlayCursorKind?

    /// 按当前位置更新光标。
    ///
    /// ⚠️ 这里**不能**退回 `resetCursorRects` 那套：规则里有一条是"压着某个标注"
    /// （要按标注自己的形状判），而 cursor rect 只能表达矩形 ——
    /// 近似成包围盒之后，斜箭头旁边的空白处也会伸出一只可拖的手，点下去却什么都没选中。
    ///
    /// - Parameter globalPoint: **Cocoa 全局点**。
    private func applyCursor(at globalPoint: CGPoint) {
        // 不在这块屏上就什么都不做：别的屏的视图会管。多屏时每块屏一个视图，
        // 而光标是系统级的 —— 不挡住的话会变成"最后刷新的一块屏说了算"。
        guard bounds.contains(globalToLocal(globalPoint)) else { return }

        var context = presentation.cursor
        // 输入框的矩形只有视图自己知道（它按内容与屏幕边缘夹过），补进来。
        // 少了它，光标会在输入框上显示成十字 —— 而那里是可以选字的。
        context.textField = textInput.map { localToGlobal($0.frame) }

        let kind = OverlayCursor.kind(at: globalPoint, in: context)
        guard kind != appliedCursor else { return }
        appliedCursor = kind
        Self.cursor(for: kind).set()
    }

    private static func cursor(for kind: OverlayCursorKind) -> NSCursor {
        switch kind {
        case .arrow: .arrow
        case .crosshair: .crosshair
        case .pointingHand: .pointingHand
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .iBeam: .iBeam
        case .resize(let handle): cursor(for: handle)
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

        // 暗幕：稿子给的是 **32%**（原来这里是 42%）。
        // 压低一档换来的是「选区外仍然看得见内容」—— 用户要一边看底下的页面一边框它。
        Self.nsColor(ChromePalette.Overlay.veil).setFill()

        if let localSelection, localSelection.width >= 1, localSelection.height >= 1 {
            fillMask(punching: localSelection, cornerRadius: 0)
            stroke(localSelection,
                   cornerRadius: 0,
                   coreWidth: presentation.isScrollCapturing ? 2 : 1)
            // 标注画在镂空**之后**：镂空是挖洞，标注要落在洞里那层图上
            drawAnnotations(clippingTo: localSelection)
            drawSnapGuides()
            drawReadout(in: localSelection, lines: presentation.readout)
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
            stroke(localHover, cornerRadius: radius, coreWidth: 2)
            // 窗口落点（单击某扇窗停住）同样能就地标注、同样能拖角，所以这两句也要
            drawAnnotations(clippingTo: localHover)
            drawSnapGuides()
            drawReadout(in: localHover, lines: presentation.readout)
            if presentation.showsSelectionHandles {
                drawSelectionHandles(on: localHover)
            }
            return
        }

        bounds.fill()
        if let anchor = presentation.hintAnchor, !presentation.hintText.isEmpty {
            drawHint(at: globalToLocal(anchor),
                     lines: [ReadoutLine(presentation.hintText, .primary)])
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

        // 十字线贯穿整个盒子，方便对齐周边像素。
        //
        // ⚠️ 这里**必须**是白芯黑边（稿子 §01 点名了放大镜准心）：放大镜压在任意屏幕内容上，
        // 而纯白 55% 那一条在一张浅色网页上会直接化掉（那是它原来那个值的问题）。
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: box.midX, y: box.minY))
        cross.line(to: CGPoint(x: box.midX, y: box.maxY))
        cross.move(to: CGPoint(x: box.minX, y: box.midY))
        cross.line(to: CGPoint(x: box.maxX, y: box.midY))
        overlayLine(cross, coreWidth: 1)

        // 中心像素框：淡淡的填充 + 白芯，让它在一堆格子中间仍然一眼可见。
        //
        // ⚠️ 它**不套黑边**，而这是有意的一处例外：这一格的实际边长是
        // `zoom / backingScale`（默认 3 / 2 = **1.5 点**，见 `sampleMarkerSize` 的算法）。
        // 3 点宽的白芯黑边会把这 1.5 点整格吃掉 —— 用户看到的会是一小块黑白格，
        // 而看不出"现在取的是哪一颗像素"。所以这里只保留白芯，靠它自己压住底。
        let markerPath = NSBezierPath(rect: marker)
        NSColor.white.withAlphaComponent(0.28).setFill()
        markerPath.fill()
        markerPath.lineWidth = ChromePalette.Overlay.strokeCoreWidth
        Self.nsColor(ChromePalette.Overlay.strokeCore).setStroke()
        markerPath.stroke()

        // 盒子外框：同样是白芯黑边。它压在内容边缘上，靠材质托不住。
        overlayLine(NSBezierPath(rect: box), coreWidth: 1)

        // 色值文本贴在盒子下方（Cocoa y 向上 → "下方"是更小的 y），放不下就翻到上方
        //
        // 这一条框**不透明**（`--c-panel`）：设计稿 §08 的原话是
        // 「放大镜自己带材质，所以它压在白底网页上也一样清 —— 它读的是『屏幕上的像素』，
        // 但它的字靠自己的底」。半透明的底会让"这几行读不读得出"取决于底下的内容。
        var lines = magnifier.colorLines
        if let status = magnifier.statusText {
            // 复制回执用**主角色**而不是琥珀：琥珀被限定为"这一条会改变结果"，
            // 而"已复制 #1A2B3C"只是告诉你刚才那一下成了 —— 用琥珀会把那枚颜色的含义稀释掉。
            lines.append(ReadoutLine(status, .primary))
        }
        guard let textBox = makeBox(lines: lines) else { return }
        var origin = CGPoint(x: box.minX, y: box.minY - textBox.size.height - 4)
        if origin.y < bounds.minY { origin.y = box.maxY + 4 }
        draw(textBox, at: origin)
    }

    private func fillMask(punching hole: CGRect, cornerRadius: CGFloat) {
        let mask = NSBezierPath(rect: bounds)
        mask.append(Self.roundedPath(hole, radius: cornerRadius))
        mask.windingRule = .evenOdd
        mask.fill()
    }

    // MARK: - 「白芯黑边」

    /// 画一条**画在别人内容之上**的线（稿子 §01）。
    ///
    /// 选区描边、控制点、吸附线、放大镜准心 —— 这四样都不能被材质托住：
    /// 它们压在屏幕上此刻是什么内容之上，而那个内容是什么颜色不由我们决定。
    ///
    /// ## 为什么要两遍
    ///
    /// 白芯在深色内容上跳得出来，但在纯白内容上会**整根消失**；
    /// 黑边反过来。两个凑一起才能同时通过两个极端 ——
    /// 用户看到的是"一条白线夹在黑线中间"。
    ///
    /// ⚠️ **顺序不能反**：先铺黑边（更宽）、再把白芯压上去。
    /// 反过来的话黑边会把白芯整根盖掉，而"线不见了"看起来像根本没画。
    ///
    /// ⚠️ **两遍 `stroke()` 而不是画两条平行线**：同一条路径上的两次描边天然同心，
    /// 而两条线在拐角处必然分叉（外圈那条要多绕一段）。
    private func overlayLine(_ path: NSBezierPath, coreWidth: CGFloat) {
        path.lineWidth = Self.totalOverlayWidth(coreWidth: coreWidth)
        Self.nsColor(ChromePalette.Overlay.strokeEdge).setStroke()
        path.stroke()

        path.lineWidth = coreWidth
        Self.nsColor(ChromePalette.Overlay.strokeCore).setStroke()
        path.stroke()
    }

    /// 一条白芯黑边的**总**宽度。
    static func totalOverlayWidth(coreWidth: CGFloat) -> CGFloat {
        coreWidth + ChromePalette.Overlay.strokeEdgeWidth * 2
    }

    /// 沿着矩形画一圈白芯黑边。
    ///
    /// 内缩量取**总宽的一半**（不是芯的一半）：`NSBezierPath` 的描边以路径为中心向两侧展开，
    /// 而这条线的可见范围是总宽 —— 按芯算的话外圈那 1 点会落到选区之外，
    /// 变成"描边往外糊出去一圈"（在贴边的选区上尤其明显）。
    private func stroke(_ rect: CGRect, cornerRadius: CGFloat, coreWidth: CGFloat) {
        let inset = Self.totalOverlayWidth(coreWidth: coreWidth) / 2
        let outline = Self.roundedPath(rect.insetBy(dx: inset, dy: inset),
                                       radius: max(0, cornerRadius - inset))
        overlayLine(outline, coreWidth: coreWidth)
    }

    /// 画一个「白芯黑边」的小方块（控制点）。
    ///
    /// 用的是**先铺一块更大的黑底、再把白芯压上去**，不是描边 ——
    /// 描边的黑环会同时落在方块内侧与外侧，内侧那半圈被白芯盖住倒无所谓，
    /// 但外侧那半圈会把足迹撑到 `芯 + 1`，而稿子给的是 `7 × 7`（`芯 5 + 黑边 1 × 2`）。
    private func drawOverlayHandle(in box: CGRect, cornerRadius: CGFloat) {
        let edge = SelectionGeometry.handleEdgeWidth
        Self.nsColor(ChromePalette.Overlay.strokeEdge).setFill()
        Self.roundedPath(box.insetBy(dx: -edge, dy: -edge), radius: cornerRadius + edge).fill()
        Self.nsColor(ChromePalette.Overlay.strokeCore).setFill()
        Self.roundedPath(box, radius: cornerRadius).fill()
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
        Self.nsColor(Self.theme.hairline).setStroke()
        outline.stroke()

        NSColor.white.withAlphaComponent(0.14).setFill()
        for separator in layout.separators {
            NSRect(x: box.minX + separator.minX,
                   y: box.minY + separator.minY,
                   width: separator.width,
                   height: separator.height).fill()
        }

        for item in layout.items {
            let itemRect = item.frame.offsetBy(dx: box.minX, dy: box.minY)
            draw(toolbarItem: item.slot, in: itemRect, state: state)
            // 小锁角标画在**图标之后** —— 它是压在上面那一层。
            if let feature = item.slot.proFeature, state.lockedFeatures.contains(feature) {
                drawLockBadge(in: itemRect)
            }
        }
    }

    private func draw(toolbarItem slot: OverlayToolbarSlot,
                      in rect: CGRect,
                      state: OverlayToolbarPresentation) {
        // 点不点亮**统一走 Core 那条规则**（可以在 Core 里单测）。
        //
        // 原先 `.style` 写的是"有弹层开着就亮"，而弹层有两个 ——
        // 于是打开**表情**面板时「样式」也一起亮了（用户报的第三个问题）。
        // 判据散在绘制回调里就没法单测，只有把两个面板都开一遍才看得出来。
        let lit = OverlayToolbarHighlight.isLit(slot,
                                                activeTool: state.activeTool,
                                                openPalette: state.palette?.kind)
        // 「能不能点」也走 Core：置灰的格子**不该有悬停反馈** ——
        // 一个跟着鼠标亮起来的灰格子，会让用户以为它其实能用（点了没反应 ⇒ 报"按钮坏了"）。
        // 而"谁才允许不可用"是产品决策（只有撤销/重做），不能靠绘制方自己判。
        let enabled = OverlayToolbarHighlight.isEnabled(slot,
                                                        canUndo: state.canUndo,
                                                        canRedo: state.canRedo)
        // ⚠️ 三种「底」互斥且有序，**谁也不冒充谁**（稿子 §07 那张六态表）：
        //   1. `fill`（填充蓝）= 当前生效的工具，全条只许一个；
        //   2. `pressedFill`（底白 16%）= 这个弹层正开着，属于「按下未复位」；
        //   3. `hoverFill`（底白 9%）= 鼠标在这，最轻的一档。
        // 悬停排在最后：已经"选中"或"按下"的格子再叠一层悬停，会让那两种状态看起来在闪。
        let hovered = enabled && !lit && state.hoveredSlot == slot
        if lit {
            // 样式格是**入口** —— 它亮只说明「我自己的弹层开着」，
            // 而不是「我是当前工具」（工具是「待用」，不是「在用」）。
            if case .style = slot {
                highlight(rect, fill: ChromePalette.Overlay.pressedFill)
            } else {
                highlight(rect, fill: Self.theme.fill)
            }
        } else if hovered {
            highlight(rect, fill: ChromePalette.Overlay.hoverFill)
        }

        // 图标颜色也跟着走三档：悬停时**升到 100%**（稿子："底白 9% + 图标 100%，12.9:1"）。
        // 只加底不升图标的话，悬停看起来像"这一格被选中了"而不是"鼠标在这"。
        let iconTint = (lit || hovered) ? Self.theme.label : Self.theme.icon

        switch slot {
        case .tool(let tool):
            // 默认 **82%**、亮起/悬停时 **100%**（稿子 §07）——
            // 一排 15 个纯白图标会糊成一片亮，压低一档之后「亮起来」才有地方可亮。
            drawSymbol(Self.symbol(for: tool), in: rect, tint: Self.nsColor(iconTint))
        case .style:
            // 展开时点亮：面板开着却看不出"是它开的"，用户会以为点空了
            drawSymbol("paintpalette", in: rect, tint: Self.nsColor(iconTint))
        case .ocr:
            // ⚠️ 识别进行中**只换图标、不置灰**。
            //
            // 稿子 §07 限定「置灰只属于撤销与重做」，而这里原先还额外 `dimmed: true` ——
            // 同一个意思（"现在忙"）用两处说，还破了那条"全工具条唯一允许变灰的地方"的约束。
            // 沙漏图标本身就是那个状态，它不需要再暗一档。
            drawSymbol(state.isRecognizing ? "hourglass" : "text.viewfinder",
                       in: rect,
                       tint: Self.nsColor(iconTint))
        case .pin:
            drawSymbol("pin", in: rect, tint: Self.nsColor(iconTint))
        case .undo:
            drawSymbol("arrow.uturn.backward", in: rect, tint: Self.nsColor(iconTint), dimmed: !enabled)
        case .redo:
            drawSymbol("arrow.uturn.forward", in: rect, tint: Self.nsColor(iconTint), dimmed: !enabled)
        case .save:
            drawSymbol("square.and.arrow.down", in: rect, tint: Self.nsColor(iconTint))
        case .cancel:
            // ⚠️ **红**，不是白。参考工具条里 ✗ 是红的、✓ 是绿的 ——
            // 这两个是"结束这次截图"的两种结果，一眼分得出才有意义。
            // 对比度是算过的（`ChromePalette` + 单测），不是挑个好看的颜色。
            drawSymbol("xmark", in: rect, tint: Self.nsColor(ChromePalette.Overlay.cancel))
        case .confirm:
            drawSymbol("checkmark", in: rect, tint: Self.nsColor(ChromePalette.Overlay.done))
        }
    }

    /// `RGB` → `NSColor`。实现见 `RGB.nsColor` 那段注释（alpha 与 sRGB 两条都不能省）。
    ///
    /// 这里只留一个转发：颜色换算**只有一份实现**，读数框那三个全局常量与视图里的绘制
    /// 走的是同一条路径 —— 两处各写一遍的话，将来改了 alpha 的规矩只会改到一处。
    static func nsColor(_ rgb: RGB) -> NSColor { rgb.nsColor }

    /// 覆盖层的调色板。**它永远深色** —— 它压在别人的内容上，
    /// 底下是什么颜色不由我们决定（这与编辑器「深色台面」的理由还不一样）。
    /// 所以这里不需要 `ChromePalette.resolved(isDark:)` —— 那个是给常规窗口用的。
    static var theme: ChromePalette.Theme { ChromePalette.dark }

    /// 图标名与编辑器**保持一致** —— 同一个功能在两处用不同图标，
    /// 用户会以为是两个不同的东西。
    private static func symbol(for tool: OverlayTool) -> String {
        switch tool {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .emoji: "face.smiling"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .mosaic: "checkerboard.rectangle"
        // ⚠️ **不能用 `textformat`** —— 它有中文本地化变体，中文环境下
        // 系统会自动换成 `textformat.zh`，而那个变体渲染出来是**两个字「格式」**，
        // 夹在一排图标里非常突兀（用户的原话就是"格式这个文字还在"）。
        // `t.square` 是"方框里的 T"，两种语言下都长一样，也正是参考工具条那一格的画法。
        case .text: "t.square"
        }
    }

    // MARK: - 弹层（色板/尺寸、表情）

    /// 画弹层的**前景**。背景（玻璃/材质）是与它并列的兄弟子视图 —— 同上一条注释。
    private func drawPaletteForeground(in box: NSRect) {
        guard let palette = presentation.toolbar?.palette else { return }
        let layout = OverlayToolbar.paletteLayout(palette.kind)

        let outline = Self.roundedPath(box.insetBy(dx: 0.5, dy: 0.5),
                                       radius: OverlayToolbar.cornerRadius)
        outline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.12).setStroke()
        outline.stroke()

        for entry in layout.items {
            let rect = entry.frame.offsetBy(dx: box.minX, dy: box.minY)
            switch entry.item {
            case .color(let index):
                drawColorSwatch(AnnotationPalette.colors[index],
                                in: rect,
                                selected: palette.stroke == AnnotationPalette.colors[index])
            case .lineWidth(let index):
                drawSizeSwatch(index: index,
                               count: palette.sizeSlotValues.count,
                               meaning: palette.sizeSlotMeaning,
                               in: rect,
                               selected: palette.sizeSlotIndex == index)
            case .emoji(let index):
                drawEmoji(AnnotationPalette.emojis[index],
                          in: rect,
                          selected: palette.selectedEmojiIndex == index)
            }
        }
    }

    // MARK: - 升级卡片（ticket 31）

    /// 画升级卡片的前景：描边、标题、正文、两个按钮。
    ///
    /// 几何**全部来自 `ProCardLayout.content(in:)`** —— 视图自己不算任何一个坐标，
    /// 否则"画出来的"与"点得到的"会各走各的（工具条在 ticket 22 踩过同一个坑：
    /// 两条规则各自都对，凑在一起才错）。
    private func drawProCardForeground(in box: NSRect) {
        guard let card = presentation.toolbar?.proCard else { return }
        // 画法在 `ProCardRenderer` —— 菜单入口那张独立面板用的是同一份。
        // 两处各写一遍的话，改一个错别字就会让同一张卡片长得不一样。
        ProCardRenderer.draw(card.content, in: box)
    }

    /// 表情用字符串直接画（系统自带 emoji 字体），不找图片资源。
    private func drawEmoji(_ emoji: String, in rect: CGRect, selected: Bool) {
        if selected {
            // ⚠️ 稿子**没给**「弹层里选中的那一枚表情」的规格 —— 保守用按下底（白 16%），
            // 不填蓝：填充蓝在稿子里被限定为「当前生效的工具」，而表情是**内容**不是工具。
            Self.nsColor(ChromePalette.Overlay.pressedFill).setFill()
            Self.roundedPath(rect.insetBy(dx: -1, dy: -1), radius: 6).fill()
        }
        let size = rect.height * 0.86
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
        ]
        let text = emoji as NSString
        let measured = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: rect.midX - measured.width / 2,
                              y: rect.midY - measured.height / 2),
                  withAttributes: attributes)
    }

    /// 格子亮起来时的底：一个比格子略大的圆角块。
    ///
    /// 底色由调用方给 —— 因为**「亮」有两种**（见调用处）：
    /// 填充蓝是「我正拿着这支笔」，底白 16% 是「那个面板开着」。
    /// 原先两者都画成「白 18%」，于是这两件事在颜色上分不开。
    private func highlight(_ rect: CGRect, fill: RGB) {
        Self.nsColor(fill).setFill()
        Self.roundedPath(rect.insetBy(dx: -1, dy: -1), radius: 6).fill()
    }

    /// 格子上那个**小锁角标**（ticket 31）。
    ///
    /// 它必须**常显**，不能等用户点了才出现：免费版里那两格点下去只弹卡片、不干活，
    /// 而外面若看不出区别，用户只会以为是自己点错了、或者 app 坏了。
    ///
    /// 画在右下角、刻意**压掉图标一角** —— 居中画会把图标本身糊住，
    /// 而那两个图标（识别文字 / 钉图）是用户认出这一格的唯一线索。
    private func drawLockBadge(in rect: CGRect) {
        let side = rect.width * 0.44
        let badge = CGRect(x: rect.maxX - side, y: rect.minY, width: side, height: side)
        // 小锁是 **白 55%**（对材质 5.10:1）—— 比次要文字还暗一档：
        // 它是附加信息，不该跟图标抢注意力，但它必须读得出来，
        // 因为它是「这一格点下去会弹卡片」的**唯一预告**。
        drawSymbol("lock.fill", in: badge, tint: Self.nsColor(ChromePalette.Overlay.lock))
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
    ///
    /// ⚠️ 大小按**档位序号**算，不按数值（见 `SizeSwatchGeometry`）：
    /// 按数值线性映射时打码那三档（4/8/16）会画成 9.6 / 15.2 / 16 ——
    /// 后两档看不出区别。编辑器那一份走的是同一个函数。
    private func drawSizeSwatch(index: Int,
                                count: Int,
                                meaning: OverlaySizeMeaning,
                                in rect: CGRect,
                                selected: Bool) {
        // 与弹层里选中的表情同一处理：**弹层内的选中**用按下底，不填蓝 ——
        // 填充蓝在稿子里被限定为「当前生效的工具」，而尺寸档是**参数**不是工具。
        if selected { highlight(rect, fill: ChromePalette.Overlay.pressedFill) }

        let side = min(rect.width, rect.height)
            * SizeSwatchGeometry.relativeSide(index: index, of: count)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                         width: side, height: side)
        switch SizeSwatchGeometry.shape(for: meaning) {
        case .circle:
            NSColor.white.setFill()
            NSBezierPath(ovalIn: box).fill()
        case .square:
            NSColor.white.setFill()
            NSBezierPath(rect: box).fill()
        case .letter:
            // 字母的"看起来多大"约等于字号，所以直接用算出来的边长当字号。
            // 这里**不再按格高二次归一化** —— 那样会把三档重新挤到一起，
            // 正是这一版要修掉的问题。
            let font = NSFont.systemFont(ofSize: max(8, side), weight: .semibold)
            let text = "A" as NSString
            let size = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2),
                      withAttributes: [.font: font, .foregroundColor: NSColor.white])
        }
    }

    /// 图标缓存。
    ///
    /// ⚠️ 这不是"提前优化"，是**一处实打实的卡顿来源**：
    /// `NSImage(systemSymbolName:)` + `withSymbolConfiguration` **每次调用都会新建一个图像**，
    /// 而工具条一帧要画 15 个 —— 鼠标一动就重建 15 个图像。
    ///
    /// 键里带上**外观**：动态色（`controlAccentColor`）解析出来的位图随外观变，
    /// 不区分就会在切换深浅色之后继续用旧位图（而那种错只在切完外观后才看得出来）。
    private static var symbolCache: [String: NSImage] = [:]

    private func drawSymbol(_ symbol: String,
                            in rect: CGRect,
                            tint: NSColor,
                            dimmed: Bool = false) {
        // ⚠️ 模板图直接 `draw(in:)` **不会**用"当前颜色"着色 —— 必须把颜色放进配置里。
        // 否则图标全是黑的，在深色底上等于没画（而且不报错，只会让人以为图标名写错了）。
        // 置灰走调色板那枚（白 30% / 2.58:1）—— 禁用态本来就是「不活跃」的样子，
        // 所以在正文级之下是**刻意的**，不是没调好。
        let color = dimmed ? Self.nsColor(Self.theme.disabled) : tint
        // `usingColorSpace` 而不是 `.redComponent`：后者对动态色（强调色）会**抛异常**。
        let resolved = color.usingColorSpace(.sRGB) ?? .white
        let key = "\(symbol)|\(dimmed)|\(effectiveAppearance.name.rawValue)|"
            + "\(resolved.redComponent),\(resolved.greenComponent),\(resolved.blueComponent),\(resolved.alphaComponent)"

        let image: NSImage
        if let cached = Self.symbolCache[key] {
            image = cached
        } else {
            let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
                // ⚠️ `.preferringMonochrome()` **不能省**。
                //
                // 不写它的时候，符号会按自己的**首选渲染模式**画：多色符号的第一层
                // 会被整片填满。表情那一格（`face.smiling`）因此变成一个**实心圆点** ——
                // 而它看起来只是"这个图标长得怪"，完全想不到是着色方式的问题。
                //
                // 我们本来就要"整格一种颜色"，所以单调渲染才是**意图**，
                // 不是降级。十个图标逐一对比过：除了 `face.smiling`，其余完全一样。
                .applying(.preferringMonochrome())
                .applying(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            guard let made = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            Self.symbolCache[key] = made
            image = made
        }

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
    ///
    /// 样式是**白芯黑边**（稿子 §02 原话：「7 × 7 白芯黑边 —— 压在浅底上不会『化掉』」）。
    /// 原先是"白底 + 强调色描边"，而强调色是**用户的系统强调色**：
    /// 有人把它设成浅蓝、有人设成黄，于是同一个控制点在不同机器上压在同一种内容上，
    /// 有时看得见、有时看不见 —— 那种 bug 只会被报成"有时候看不到控制点"。
    private func drawSelectionHandles(on localSelection: CGRect) {
        let side = SelectionGeometry.handleVisualSide
        for handle in SelectionGeometry.Handle.allCases {
            let center = handle.center(on: localSelection)
            drawOverlayHandle(in: CGRect(x: center.x - side / 2,
                                         y: center.y - side / 2,
                                         width: side,
                                         height: side),
                              cornerRadius: 0)
        }
    }

    /// 画吸附提示线：一条贯穿屏幕的细线，标出"吸到了哪条边"。
    ///
    /// 没有它的话，用户只会觉得"拖到这里有点顿"，说不出在吸什么 ——
    /// 而"可感知"恰恰是吸附能不能用的关键。
    ///
    /// 白芯黑边：这条线要横穿整块屏，压到的内容从深到浅都有，
    /// 单一颜色必然在某一段上消失（而"线断了一截"看起来像渲染 bug）。
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
        overlayLine(path, coreWidth: 1)
    }

    private func drawReadout(in localSelection: CGRect, lines: [ReadoutLine]) {
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
    ///
    /// ⚠️ 它**不要**读数框那个 132 × 44 的最小尺寸：那是"读数框只换内容不换大小"的前提，
    /// 而这句话是跟着光标跑的**一句话**（稿子 §01 管它叫「光标提示 高 26 pt」）。
    /// 给它套上读数框的尺寸，会在鼠标旁边永远挂着一块 132 × 44 的空壳。
    private func drawHint(at point: CGPoint, lines: [ReadoutLine]) {
        guard let box = makeBox(lines: lines, minimumSize: .zero) else { return }
        let origin = CGPoint(x: point.x + 18, y: point.y - box.size.height - 12)
        draw(box, at: origin)
    }

    private func draw(_ box: (text: NSAttributedString, size: NSSize, padding: NSSize),
                      at origin: CGPoint) {
        let clamped = CGPoint(x: min(max(bounds.minX + 6, origin.x), bounds.maxX - box.size.width - 6),
                              y: min(max(bounds.minY + 6, origin.y), bounds.maxY - box.size.height - 6))
        let rect = NSRect(origin: clamped, size: box.size)
        // ⚠️ **不透明材质**，不是"平的黑 72%"。
        //
        // 半透明的底会让"这几行读不读得出"取决于屏幕上此刻是什么：
        // 黑 72% 压在纯白内容上时，次要行有 5.02；压在纯黑内容上只剩 2.52 —— 连正文级都不到。
        // 而不透明度这件事在设计稿里是有答案的：§01 把「工具条 / 弹层 / **读数**」
        // 并列写在 `--c-panel` 那一行下面。
        //
        // 代价是它比"贴着一层薄纱"更像一块实心条 —— 但那正是 §04 那句
        // "工具条永远比它压着的东西暗一档"所换来的东西：数字对任何底都成立。
        Self.nsColor(ChromePalette.Overlay.Readout.backdrop).setFill()
        NSBezierPath(roundedRect: rect,
                     xRadius: OverlayReadout.cornerRadius,
                     yRadius: OverlayReadout.cornerRadius).fill()
        box.text.draw(at: NSPoint(x: rect.minX + box.padding.width, y: rect.minY + box.padding.height))
    }

    /// 把若干行文本排成一个读数框。
    ///
    /// 三件事一起定，**不能拆**：
    ///
    /// 1. **行色**：每一行按它自己的角色上色（`ReadoutRole`）——
    ///    告警/开关是琥珀、其余两句同色的话用户就得逐字读才知道哪行是结果。
    /// 2. **行阶**：第一行 13 点、其余 11 点（稿子：读数框 `13 / 11`）。
    /// 3. **框的最小尺寸**：读数框是 `132 × 44`。它是"同一块框只换内容"的物理前提 ——
    ///    框随内容跳大小的话，用户会以为换了一个读数框（而设计稿 §08 明确说
    ///    「用户不需要学两个框」）。
    ///
    /// - Parameter minimumSize: 传 `.zero` 就按内容自然大小（光标旁那句提示用这个）。
    private func makeBox(lines: [ReadoutLine],
                         minimumSize: CGSize = OverlayReadout.minimumSize)
        -> (text: NSAttributedString, size: NSSize, padding: NSSize)? {
        let visible = ReadoutLine.compact(lines)
        guard !visible.isEmpty else { return nil }

        let attributed = NSMutableAttributedString()
        for (index, line) in visible.enumerated() {
            if index > 0 { attributed.append(NSAttributedString(string: "\n")) }
            attributed.append(NSAttributedString(string: line.text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: index == 0 ? OverlayReadout.primaryFontSize : OverlayReadout.secondaryFontSize,
                    weight: .medium),
                .foregroundColor: ReadoutStyle.color(line.role),
            ]))
        }
        let padding = NSSize(width: OverlayReadout.textPadding.width,
                             height: OverlayReadout.textPadding.height)
        let textSize = attributed.size()
        return (attributed,
                NSSize(width: max(minimumSize.width, textSize.width + padding.width * 2),
                       height: max(minimumSize.height, textSize.height + padding.height * 2)),
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

    /// 本视图坐标 → Cocoa 全局坐标。光标规则吃的是全局点，输入框的矩形得换过去。
    private func localToGlobal(_ rect: CGRect) -> CGRect {
        let origin = window?.frame.origin ?? .zero
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: - 文字输入框（ticket 22）

    /// 输入框尺寸与字号。
    ///
    /// **故意不跟标注的字号走**：它是一个**控件**，不是所见即所得的预览 ——
    /// 44 点的标注字号会做出一个 60 点高的白条糊在图上，反而看不清输入了什么
    /// （编辑器里那个输入框也是固定 13 点，同理）。真正的字号在提交后才生效。
    /// 设计稿 §01 给的尺寸是 **240 × 32 pt / 13 pt**。
    private static let textInputSize = CGSize(width: 240, height: 32)
    private static let textInputFontSize: CGFloat = 13

    /// 「焦点环」的粗细（稿子 §01/§09：与引导页那个录制框**同一套**）。
    private static let textInputRingWidth: CGFloat = 3

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

    /// 画选中标注身上的 8 个控制点。样式与选区控制点**一致**（白芯黑边 + 同一个足迹）。
    ///
    /// 用户不该为"缩选区"和"缩标注"学两套手感 —— 而两处样式一旦分叉，
    /// 表现只是"这个好像比那个小一点"，没有任何东西会报错。
    /// 所以这里走的是同一个 `drawOverlayHandle`。
    private func drawAnnotationHandles() {
        for item in presentation.selectedAnnotationHandles {
            drawOverlayHandle(in: globalToLocal(item.frame), cornerRadius: 1.5)
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
        // 外壳深、里面是真系统输入框（稿子 §09 原话：「它不是一个『像输入框的标注』，它是输入框」）。
        //
        // ⚠️ 从"白底黑字"改成"深内底白字"是**功能性的**，不只是配色：
        // 白光条压在任意屏幕上内容之上时会自己发光，而覆盖层里**没有一块地方**是白的，
        // 只有它一个。与工具条 / 读数框一样，控件自己带底，才不会因为底下的内容而难看。
        field.backgroundColor = Self.nsColor(Self.theme.inset)
        field.textColor = Self.nsColor(Self.theme.label)
        field.font = .systemFont(ofSize: Self.textInputFontSize)
        // ⚠️ **没有占位句，这是刻意的**（稿子 §09）：
        // 「空框里没有占位句：光标在闪，就是『在这儿打字』。占位句在这个场景里是多余的 ——
        //  用户刚刚自己点了『文字』工具，他知道自己在干什么。」
        // 留着 placeholderString 会让空框里常显一行灰字，而它对用户零信息量。
        field.placeholderString = nil
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = OverlayReadout.cornerRadius
        // 3 pt 焦点环：与引导页那个录制框同一套。
        // 环画在**外侧**（borderWidth 默认居中于边缘），把 `layer?.masksToBounds` 留着关掉，
        // 否则那 1.5 点会被裁掉、环看起来只有 1.5 点粗。
        field.layer?.borderWidth = Self.textInputRingWidth
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

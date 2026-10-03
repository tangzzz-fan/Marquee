import CoreGraphics

/// 覆盖层上鼠标该显示成什么样。
///
/// ## 为什么要有这个类型
///
/// 之前覆盖层**整屏都是十字**：不管是指着工具条上的按钮、压着一个已经画好的标注，
/// 还是在选区里准备整体挪一下。十字本身没错，但它**只在"拉一个新选区"时**才是对的含义；
/// 其余场合它什么也没说，用户只能靠试。
///
/// ## 为什么放 Core
///
/// "哪个位置该显示哪种光标"是一条纯规则：给它一个点、一份按坐标摆好的上下文，
/// 答案就定了。放 Core 才能把这条规则脱机单测 —— 而它错了的样子
/// （"按钮上还是十字""能拖却看着不像能拖"）只有人盯着屏幕才看得出来。
public enum OverlayCursorKind: Equatable, Sendable {
    /// 默认指针。用在**这里什么也做不了**的地方。
    case arrow
    /// 十字。只在"可以拉 / 重画选区"和"正在画标注"时出现。
    case crosshair
    /// 手型。可以点的按钮。
    case pointingHand
    /// 张开的手。**按住就能拖**（移动整个选区 / 移动一个标注）。
    ///
    /// 与 `closedHand` 成对：按下之前是张开的手、按住之后是合上的手。
    /// 这是桌面系统里"这个东西可以拖"的通用说法，不需要额外的文字提示。
    case openHand
    /// 合上的手。正在拖。
    case closedHand
    /// 文本输入光标。
    case iBeam
    /// 缩放光标，方向与控制点一一对应。
    case resize(SelectionGeometry.Handle)
}

/// 光标规则要吃的那份上下文。
///
/// 里面全部是**已经算好的 Cocoa 全局点矩形** —— 判断规则不认识 AppKit，
/// 也不认识控制层那套状态机。谁把这些填进来（控制层），谁负责坐标正确。
public struct OverlayCursorContext: Equatable, Sendable {

    /// 一个**带方向**的命中区（控制点）。
    public struct HandleRegion: Equatable, Sendable {
        public var handle: SelectionGeometry.Handle
        /// **Cocoa 全局点**
        public var frame: CGRect

        public init(handle: SelectionGeometry.Handle, frame: CGRect) {
            self.handle = handle
            self.frame = frame
        }
    }

    /// 正在进行的拖拽。
    ///
    /// 拖拽期间光标**只看这个，不看位置** —— 否则"拖到选区外面"的那一瞬间
    /// 光标会跳回十字，而手还按着，看起来像操作被打断了。
    public enum Drag: Equatable, Sendable {
        case none
        /// 拉一个新选区 / 重画
        case selection
        case movingSelection
        case resizingSelection(SelectionGeometry.Handle)
        /// 画一笔标注（矩形 / 箭头 / 画笔 / 打码）
        case drawingAnnotation
        case movingAnnotation
        case resizingAnnotation(SelectionGeometry.Handle)
    }

    /// 正在拖什么
    public var drag: Drag = .none
    /// 选区已经**落点**（不再随鼠标拖拽变化）
    public var isSettled = false
    /// 长截图正在抓帧 —— 这时覆盖层只认 `⏎` / `Esc` / 空格，鼠标什么也做不了
    public var isScrollCapturing = false
    /// 可以标注的那块区域（**Cocoa 全局点**）。`nil` = 还没有画布。
    ///
    /// 落点前后它的含义不同：落点前是"正在拖的选区"（`nil`），
    /// 落点后是"已经定下来的选区 / 窗口矩形"。
    public var canvas: CGRect?
    public var selectionHandles: [HandleRegion] = []
    public var annotationHandles: [HandleRegion] = []
    /// 已有标注的包围盒（**Cocoa 全局点**）。
    public var annotationFrames: [CGRect] = []
    public var toolbar: CGRect?
    public var palette: CGRect?
    /// 升级卡片整块（**Cocoa 全局点**）。`nil` = 没弹。
    ///
    /// ⚠️ 卡片在本类型里**必须排在弹层与工具条之前**判 —— 它是最晚弹出来的那一层，
    /// 与 `mouseDown` 那条路的分派顺序一致。顺序不一致的表现是
    /// "光标说这里是按钮、点下去却在动工具条"。
    public var proCard: CGRect?
    /// 卡片上**两个按钮**的命中区（**Cocoa 全局点**）。
    ///
    /// 单独给这一条是为了让"卡片里只有这两个按钮能点"这件事**看得见**：
    /// 卡片的正文与空白处点了什么都不做，那里就该是普通箭头 ——
    /// 整张卡都给手型的话，用户会在正文上点几下然后说"这个卡片点不动"。
    public var proCardButtons: [CGRect] = []
    /// 正在编辑的文字输入框（**Cocoa 全局点**）。`nil` = 没在输入。
    public var textField: CGRect?
    /// 当前选中的标注工具。`nil` = 没选（那时拖拽是改几何 / 挪标注）。
    public var tool: OverlayTool?
    /// 此刻**点不动**的格子（撤销 / 重做 没得撤、识别正在进行）。
    ///
    /// 有它才能在"按钮灰着"和"按钮能点"之间给出不同的光标 ——
    /// 否则灰按钮上也伸出一只可点的手，那是在骗人。
    public var disabledSlots: Set<OverlayToolbarSlot> = []

    public init() {}

    /// 还没有任何信息的上下文：整屏十字（覆盖层刚出现的默认状态）。
    public static let empty = OverlayCursorContext()
}

/// 光标规则的**唯一来源**。
public enum OverlayCursor {

    /// 某个位置该显示哪种光标。
    ///
    /// 分派顺序与 `mouseDown` 那条路**一致**（卡片 → 弹层 → 工具条 → 控制点 → 画布）。
    /// 两者不一致的话，会出现"手型光标压在按钮上、点下去却在重画选区"这种
    /// 说不清哪里不对的状态。
    public static func kind(at point: CGPoint, in context: OverlayCursorContext) -> OverlayCursorKind {
        // ① 拖拽中：只看"在拖什么"
        if let dragging = kind(for: context.drag) { return dragging }

        // ② 升级卡片：**最晚弹出来的那一层**，必须排在弹层与工具条之前
        if let card = context.proCard, card.contains(point) {
            return context.proCardButtons.contains { $0.contains(point) } ? .pointingHand : .arrow
        }

        // ③ 浮在最上面的两块面板（弹层压在工具条外侧，必须先判）
        if let palette = context.palette, palette.contains(point) { return .pointingHand }
        if let toolbar = context.toolbar, toolbar.contains(point) {
            // 格与格之间的空隙仍是"面板"，但不给手型 —— 按下去什么都不发生
            guard let slot = OverlayToolbar.slot(at: point, in: toolbar),
                  !context.disabledSlots.contains(slot) else { return .arrow }
            return .pointingHand
        }

        // ④ 正在输入文字：除了输入框自己，别处**按一下就只是结束输入** —— 说实话
        if let field = context.textField {
            return field.contains(point) ? .iBeam : .arrow
        }

        // ⑤ 控制点。两个来源共用一条规则：拖选区与拖标注，手感本来就该一样
        for region in context.annotationHandles where region.frame.contains(point) {
            return .resize(region.handle)
        }
        for region in context.selectionHandles where region.frame.contains(point) {
            return .resize(region.handle)
        }

        // ⑥ 长截图抓帧期间鼠标没有语义
        if context.isScrollCapturing { return .arrow }

        // ⑦ 选了工具 = 在画东西。选区内是画布，选区外按下会被忽略
        if context.tool != nil {
            guard let canvas = context.canvas else { return .crosshair }
            return canvas.contains(point) ? .crosshair : .arrow
        }

        // ⑧ 没选工具 = 改已有的东西
        guard context.isSettled, let canvas = context.canvas else { return .crosshair }
        // 标注可能被拖到选区之外，所以先单独判一次
        if context.annotationFrames.contains(where: { $0.contains(point) }) { return .openHand }
        // 框内按住＝整体挪；框外按住＝重画一个新选区
        return canvas.contains(point) ? .openHand : .crosshair
    }

    /// 拖拽期间的光标。
    ///
    /// - Returns: `nil` = 这次拖拽不改变光标。
    public static func kind(for drag: OverlayCursorContext.Drag) -> OverlayCursorKind? {
        switch drag {
        case .none: nil
        case .selection, .drawingAnnotation: .crosshair
        case .movingSelection, .movingAnnotation: .closedHand
        case .resizingSelection(let handle), .resizingAnnotation(let handle): .resize(handle)
        }
    }
}

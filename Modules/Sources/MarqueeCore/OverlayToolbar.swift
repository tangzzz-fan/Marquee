import CoreGraphics

/// 覆盖层浮动工具栏上可以选中的标注工具。
///
/// 顺序即工具条上的顺序，与**编辑器工具栏一致** —— 同一个功能在两处用不同的图标/顺序，
/// 用户会以为是两个不同的东西。
public enum OverlayTool: String, CaseIterable, Sendable, Codable {
    /// 选择工具：点选已有标注、拖动移动、`Delete` 删除（"画完还能改"）。
    ///
    /// 它是**工具**而不是"自带的行为"：不选它的时候，拖动是改**选区**的几何
    /// （拖角改大小、框内拖动移动整框）。两件事都用拖动，靠工具区分才不会有歧义 ——
    /// 否则"按在框内"到底该挪标注还是挪选区，只能靠猜。
    case select
    case rectangle
    case ellipse
    case arrow
    case pen
    /// 文字：**点一下**放下输入点，再输入内容（不是拖一笔）。
    case text
    case mosaic
    case blur

    /// 绘制时对应的标注类型。`nil` = 这个工具不画东西（选择）。
    ///
    /// 做成可选而不是给 `.select` 硬塞一个 `AnnotationKind`：
    /// 后者会让"它到底能画出什么"这个问题有一个**看起来有答案**的答案。
    public var kind: AnnotationKind? {
        switch self {
        case .select: nil
        case .text: .text
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .pen: .pen
        case .mosaic: .mosaic
        case .blur: .blur
        }
    }

    /// 这个工具是否"画东西"。
    public var draws: Bool { kind != nil }

    /// 是否靠"一笔拖出来"成形。
    ///
    /// 只有 `.select`（不画东西）与 `.text`（点一下放下、再敲内容）不是。
    /// 让文字走 `beginStroke` 的话，用户按住鼠标拖一下就会得到一个
    /// "宽度等于拖拽距离"的空文字框 —— 而正文一个字都还没输。
    /// 所以这条判据是**必须的**，不是分类学上的洁癖。
    public var isStrokeBased: Bool { draws && self != .text }

    /// 是否需要**底图像素**才能预览。
    ///
    /// 覆盖层刻意不铺整屏截图，所以这两类的底图得从"冻结的整屏帧"里拼
    /// （`OverlayRedactionSource`）。拿不到时预览会跳过它们 ——
    /// 但**导出仍然会应用**，所以拿不到底图时必须让用户看得见这件事。
    public var needsBackdrop: Bool {
        switch self {
        case .mosaic, .blur: true
        case .select, .rectangle, .ellipse, .arrow, .pen, .text: false
        }
    }

    /// 选中这个工具时，工具条上那三档尺寸**代表什么**。
    ///
    /// 与编辑器同一套做法：只有一排控件，按当前上下文决定改的是哪个参数
    /// （**不新增控件** —— 工具条每多一格就更宽，而它有一条"必须放得进 1024 点的屏"的硬约束）。
    public var sizeMeaning: OverlaySizeMeaning {
        switch self {
        case .mosaic, .blur: .redactionStrength
        case .text: .fontSize
        case .select, .rectangle, .ellipse, .arrow, .pen: .lineWidth
        }
    }
}

/// 工具条上那三档尺寸**此刻代表哪一组值**。
///
/// 把"含义"做成一个枚举、而不是让各处自己 switch 工具，是因为它有三处用户：
/// 控制层（改哪个字段）、视图（画成圆点 / 方块 / 字号），以及测试。
/// 三处各自写一遍 `tool == .mosaic || tool == .blur` 的话，加第二类需要底图的工具时
/// 一定会漏掉一处 —— 而漏掉的表现是"某一档点了没反应"。
public enum OverlaySizeMeaning: String, CaseIterable, Sendable {
    /// 图形工具的线宽
    case lineWidth
    /// 打码强度（马赛克块边长 / 模糊半径）
    case redactionStrength
    /// 文字的字号
    case fontSize

    /// 这一组的值（点）。
    public var values: [CGFloat] {
        switch self {
        case .lineWidth: AnnotationPalette.lineWidths
        case .redactionStrength: AnnotationPalette.overlayRedactionStrengths
        case .fontSize: AnnotationPalette.overlayFontSizes
        }
    }

    /// 默认值。**必须落在 `values` 里**，否则一进来三档全不高亮
    /// （`AnnotationStyle.default` 的 36 是原图像素的数，落在覆盖层那三档之外）。
    public var defaultValue: CGFloat {
        switch self {
        case .lineWidth: AnnotationPalette.defaultLineWidth
        case .redactionStrength: AnnotationPalette.defaultRedactionStrength
        case .fontSize: AnnotationPalette.defaultOverlayFontSize
        }
    }
}

/// 覆盖层上那排浮动工具栏的**内容、几何与位置计算**。
///
/// ## 为什么放 Core
///
/// 位置计算要能单测 —— 贴边、翻面、跨屏这几种情况靠肉眼试不全，
/// 而一旦算错，表现是"工具栏跑出屏幕了"或"它盖住了选区"，
/// 用户只会说"那个条没了"，不会告诉你它跑到哪去了。
///
/// ## 单一来源（踩过一次）
///
/// 尺寸、每格的位置、分隔线的位置**全部由 `layout()` 一次算出**。
/// 之前这三样是分开推的：宽度按"间距在两组之间"算、按钮偏移按"间距在末尾"算，
/// 差 4 点，最后一个按钮探出右边一点。两条规则各自都对，凑在一起才错。
/// 现在只要 `layout()` 是对的，画出来的框和点得到的区域就**不可能**对不上。
public enum OverlayToolbar {

    // MARK: - 尺寸

    /// 工具 / 动作按钮的边长
    public static let buttonSize: CGFloat = 28
    /// 色板与线宽块的边长
    public static let swatchSize: CGFloat = 20
    /// 同类相邻两格之间的间距
    public static let itemGap: CGFloat = 4
    /// 分组边界的额外留白（分隔线两侧各一份）
    public static let groupGap: CGFloat = 9
    /// 工具条自身的内边距
    public static let padding: CGFloat = 6
    /// 工具条与选区之间的间距
    public static let gap: CGFloat = 10
    /// 夹取时与屏幕边缘留的余量
    public static let screenMargin: CGFloat = 8
    /// 分组分隔线的宽度
    public static let separatorWidth: CGFloat = 1
    /// 圆角
    public static let cornerRadius: CGFloat = 10

    // MARK: - 内容

    /// 工具条上的一格。
    public enum Slot: Hashable, Sendable {
        case tool(OverlayTool)
        case color(Int)
        case lineWidth(Int)
        /// 识别选区里的文字（ticket 23）
        ///
        /// 是**动作**不是工具：它不改文档、只产出一份文本，与编辑器里的做法一致
        /// （PRD 3.1 把 9 个工具位列满了，OCR 本来就不在其中）。
        case ocr
        /// 把这张图钉在屏幕上（ticket 14）。
        ///
        /// 与 OCR 同一类：动作，不占工具位。它**不改这张图**，只是多留一份在屏幕上。
        case pin
        case undo
        case redo
        case save
        case cancel
        case confirm

        /// 点这一格之后，**正在进行的文字输入还留着吗**。
        ///
        /// 留着的只有"纯改样式"的那几格（颜色 / 尺寸三档）与撤销重做 ——
        /// 那时用户想改的就是**正在打的那行字**。
        /// 其余（换工具、识别文字、保存 / 取消 / 完成）都该先把输入结算掉：
        /// 不结算的话，"切到矩形工具"会把半截文字**无声地丢掉**。
        ///
        /// ⚠️ 注意"结算"不等于"丢弃"：结算＝把已打的内容落成一个真的标注。
        /// 只有 `Esc` 才丢。
        public var preservesTextEditing: Bool {
            switch self {
            case .color, .lineWidth, .undo, .redo: true
            case .tool, .ocr, .pin, .save, .cancel, .confirm: false
            }
        }

        /// 分组序号。相邻两格分组不同 → 中间画一条分隔线。
        public var group: Int {
            switch self {
            case .tool: 0
            case .color: 1
            case .lineWidth: 2
            case .ocr, .pin: 3
            case .undo, .redo: 4
            case .save, .cancel, .confirm: 5
            }
        }

        /// 这一格是方形按钮还是小色块。
        var isSwatch: Bool {
            switch self {
            case .color, .lineWidth: true
            default: false
            }
        }

        /// 可点击的边长。
        ///
        /// 色块只有 20 点，直接当命中区偏小（手指/光标容易差一两像素）。
        /// 但**命中区与绘制区取同一个值**是这里的硬约束，所以不加"隐形的外扩" ——
        /// 外扩会让"看着没点到却点上了"，同样是错位，只是方向相反。
        var side: CGFloat { isSwatch ? swatchSize : buttonSize }
    }

    /// 工具条上的全部格子，从左到右。
    public static let slots: [Slot] =
        OverlayTool.allCases.map(Slot.tool)
        + AnnotationPalette.colors.indices.map(Slot.color)
        + AnnotationPalette.lineWidths.indices.map(Slot.lineWidth)
        + [.ocr, .pin]
        + [.undo, .redo]
        + [.save, .cancel, .confirm]

    // MARK: - 排布

    /// 一次算好的排布结果。
    public struct Layout: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public let slot: Slot
            /// 相对工具条**左下角**（与 AppKit 视图坐标一致）
            public let frame: CGRect
        }
        public let items: [Item]
        /// 分组分隔线，同样相对左下角
        public let separators: [CGRect]
        public let size: CGSize

        public func frame(of slot: Slot) -> CGRect? {
            items.first { $0.slot == slot }?.frame
        }
    }

    /// 工具条高（单行）。
    public static var height: CGFloat { buttonSize + padding * 2 }

    /// 走一遍排布。**尺寸也从这里出** —— 这就是"单一来源"。
    public static func layout() -> Layout {
        var items: [Layout.Item] = []
        var separators: [CGRect] = []
        var x = padding
        var previousGroup: Int?
        let lineHeight = height - padding * 2 - 12

        for (index, slot) in slots.enumerated() {
            if let previousGroup, previousGroup != slot.group {
                x += groupGap
                separators.append(CGRect(x: x, y: padding + 6, width: separatorWidth, height: lineHeight))
                x += groupGap + separatorWidth
            }
            let side = slot.side
            items.append(Layout.Item(slot: slot,
                                     frame: CGRect(x: x,
                                                   y: (height - side) / 2,
                                                   width: side,
                                                   height: side)))
            x += side
            if index < slots.count - 1 { x += itemGap }
            previousGroup = slot.group
        }

        return Layout(items: items,
                      separators: separators,
                      size: CGSize(width: x + padding, height: height))
    }

    /// 工具条尺寸（点）。
    public static var toolbarSize: CGSize { layout().size }

    // MARK: - 位置

    /// 算出工具栏该放在哪（**Cocoa 全局点**，y 向上）。
    ///
    /// 与读数框（`SelectionOverlayView.drawReadout`）同一套思路：
    /// 优先贴在选区**下方**；下方空间不够就翻到上方；最后统一夹进屏幕可见区。
    ///
    /// ⚠️ **夹取必须最后做**。先夹再翻会得到"翻上去之后又被夹回屏幕外"这种组合 ——
    /// 两个规则各自都对，顺序一错结果就错，而且只在贴边的选区上出现。
    public static func frame(for selection: CGRect,
                             screenFrame: CGRect,
                             gap: CGFloat = gap) -> CGRect {
        let size = toolbarSize
        let box = selection.standardized
        let screen = screenFrame.standardized

        // ① 优先：选区正下方，左对齐
        var origin = CGPoint(x: box.minX, y: box.minY - gap - size.height)
        // ② 下方放不下 → 翻到上方
        if origin.y < screen.minY {
            origin.y = box.maxY + gap
        }
        // ③ 最后统一夹进屏幕（水平竖直都要）
        //
        // 屏幕比工具栏还小时（外接小屏、可见区被 Dock 压得很矮），
        // `maxX`/`maxY` 会算成比 `minX`/`minY` 更小的值 —— 用 `max` 兜住，
        // 那样至少保证"左上角在屏幕内、尺寸不变"，而不是算出个反向矩形。
        let minX = screen.minX + screenMargin
        let maxX = max(minX, screen.maxX - screenMargin - size.width)
        let minY = screen.minY + screenMargin
        let maxY = max(minY, screen.maxY - screenMargin - size.height)
        origin.x = min(max(minX, origin.x), maxX)
        origin.y = min(max(minY, origin.y), maxY)

        return CGRect(origin: origin, size: size)
    }

    /// 某一格的命中区域（Cocoa 全局点）。
    public static func hitFrame(of slot: Slot, in toolbar: CGRect) -> CGRect? {
        guard let local = layout().frame(of: slot) else { return nil }
        return local.offsetBy(dx: toolbar.minX, dy: toolbar.minY)
    }

    /// 点在哪个格子上（`nil` = 不在任何格子上）。
    ///
    /// 顺序遍历即可（格子互不重叠）。用 `layout()` 而不是写死若干 `if`，
    /// 这样以后加一个工具不必再改这里。
    public static func slot(at point: CGPoint, in toolbar: CGRect) -> Slot? {
        let local = CGPoint(x: point.x - toolbar.minX, y: point.y - toolbar.minY)
        return layout().items.first { $0.frame.contains(local) }?.slot
    }

    /// 点在不在工具条的**任意位置**上（含格与格之间的空隙）。
    ///
    /// 与 `slot(at:)` 分开是因为用途不同：判断"这一下该不该被当成按了按钮"要看整体，
    /// 判断"按的是哪个按钮"才看格子。只有前者会导致在空隙上按下时，
    /// 那一按会掉进"拖拽重画选区"的逻辑里 —— 用户以为自己在按工具条。
    public static func contains(_ point: CGPoint, in toolbar: CGRect) -> Bool {
        toolbar.contains(point)
    }
}

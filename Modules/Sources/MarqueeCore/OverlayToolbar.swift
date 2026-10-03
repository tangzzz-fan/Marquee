import CoreGraphics

/// 覆盖层浮动工具栏上可以选中的标注工具。
///
/// 顺序即工具条上的顺序。**刻意与编辑器工具栏不同**（编辑器保留「选择」「模糊」）：
/// 覆盖层上多一格就多一份宽度，而它有一条"整条必须放得进 1024 点的屏"的硬约束。
/// 两边共同的判据是"同一个功能用同一个图标"，不是"格子数一样"。
public enum OverlayTool: String, CaseIterable, Sendable, Codable {
    case rectangle
    case ellipse
    /// 表情贴纸。
    ///
    /// 产出的**仍然是 `.text` 标注**（内容是那个 emoji、字号走字号档），
    /// 所以绘制/导出/缩放/移动全部复用现成路径，一行新渲染分支都不用加。
    /// 它只解决"怎么选到那个 emoji"—— 那是交互问题，不是模型问题。
    case emoji
    case arrow
    case pen
    /// 打码。**只有一格**（马赛克）。模糊仍然能被渲染、导出、编辑，
    /// 只是覆盖层不再给它一个入口 —— 长截图那条编辑器路径上它还在。
    case mosaic
    /// 文字：**点一下**放下输入点，再输入内容（不是拖一笔）。
    case text

    /// 落笔方式。
    public enum Placement: String, Sendable {
        /// 拖一笔成形（矩形 / 椭圆 / 箭头 / 画笔 / 打码）
        case stroke
        /// 点一下放下输入点，再敲内容（文字）
        case pointInput
        /// 点一下直接落一个现成的标注（表情 —— 内容在选工具时就定好了）
        case stamp
    }

    public var placement: Placement {
        switch self {
        case .rectangle, .ellipse, .arrow, .pen, .mosaic: .stroke
        case .text: .pointInput
        case .emoji: .stamp
        }
    }

    /// 绘制时对应的标注类型。
    public var kind: AnnotationKind {
        switch self {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .pen: .pen
        case .mosaic: .mosaic
        case .emoji, .text: .text
        }
    }

    /// 这个工具是否"拖一笔"成形。
    ///
    /// 让文字/表情走 `beginStroke` 的话，用户按住鼠标拖一下就会得到一个
    /// "宽度等于拖拽距离"的空文字框 —— 而正文一个字都还没输。
    /// 所以这条判据是**必须的**，不是分类学上的洁癖。
    public var isStrokeBased: Bool { placement == .stroke }

    /// 是否需要**底图像素**才能预览。
    ///
    /// 覆盖层刻意不铺整屏截图，所以打码的底图得从"冻结的整屏帧"里拼
    /// （`OverlayRedactionSource`）。拿不到时预览会跳过它 ——
    /// 但**导出仍然会应用**，所以拿不到底图时必须让用户看得见这件事。
    public var needsBackdrop: Bool { self == .mosaic }

    /// 选中这个工具时，三档尺寸**代表什么**。
    public var sizeMeaning: OverlaySizeMeaning {
        switch self {
        case .mosaic: .redactionStrength
        case .text, .emoji: .fontSize
        case .rectangle, .ellipse, .arrow, .pen: .lineWidth
        }
    }
}

/// 工具条上那三档尺寸**此刻代表哪一组值**。
///
/// 把"含义"做成一个枚举、而不是让各处自己 switch 工具，是因为它有三处用户：
/// 控制层（改哪个字段）、视图（画成圆点 / 方块 / 字号），以及测试。
/// 三处各自写一遍判断的话，加一类含义时一定会漏掉一处 ——
/// 而漏掉的表现是"某一档点了没反应"。
public enum OverlaySizeMeaning: String, CaseIterable, Sendable {
    /// 图形工具的线宽
    case lineWidth
    /// 打码强度（马赛克块边长 / 模糊半径）
    case redactionStrength
    /// 文字与表情的字号
    case fontSize

    /// 覆盖层里的这一组值（**点**）。
    public var values: [CGFloat] {
        switch self {
        case .lineWidth: AnnotationPalette.overlayLineWidths
        case .redactionStrength: AnnotationPalette.overlayRedactionStrengths
        case .fontSize: AnnotationPalette.overlayFontSizes
        }
    }

    /// 编辑器里的这一组值（**原图像素**）。
    ///
    /// ⚠️ **与 `values` 不是同一组数，也不是换算关系** —— 它们是两套数的**根**：
    /// 覆盖层的数字描述"屏幕上的笔"，编辑器的数字描述"图里的笔"。
    /// 同一个 4（点）在 2x 屏上就是 8（原图像素）。
    /// 所以两组都要有，而不是让编辑器去乘一个 scale —— 乘出来的数不在档位上，
    /// 表现是"点一下尺寸芯片，当前档不亮"。
    public var editorValues: [CGFloat] {
        switch self {
        case .lineWidth: AnnotationPalette.editorLineWidths
        case .redactionStrength: AnnotationPalette.editorRedactionStrengths
        case .fontSize: AnnotationPalette.editorFontSizes
        }
    }

    /// 编辑器里的默认值。**同样必须落在 `editorValues` 里**（理由见 `defaultValue`）。
    public var editorDefaultValue: CGFloat {
        switch self {
        case .lineWidth: AnnotationPalette.defaultEditorLineWidth
        case .redactionStrength: AnnotationPalette.defaultEditorRedactionStrength
        case .fontSize: AnnotationPalette.defaultEditorFontSize
        }
    }

    /// 默认值。**必须落在 `values` 里**，否则一进来三档全不高亮。
    public var defaultValue: CGFloat {
        switch self {
        case .lineWidth: AnnotationPalette.defaultLineWidth
        case .redactionStrength: AnnotationPalette.defaultRedactionStrength
        case .fontSize: AnnotationPalette.defaultOverlayFontSize
        }
    }
}

// 工具条上的「确认 / 取消」两个强调色原先定义在这里（`OverlayAccent`），
// 2026-10-03 并入 `ChromePalette.Overlay` 的 `done` / `cancel`。
//
// ⚠️ 合并的理由不是"代码整洁"，而是**两个值本来就不一样**：
//
//   · 原来 `cancel` = `#FA5447`，对**工具条材质** `#313131` 只有 **3.98** —— 达不到正文级；
//   · 设计稿量出来的是 `#FF6B60`（**4.66:1**）。
//
// 而原来那条对比度测试用的是更暗的 `chromeBackdrop`（`#1C1C1C`，5.21:1）所以它过了。
// **尺子选错，结论就跟着错** —— 而"这块颜色到底坐在什么底上"本来是有确切答案的：
// 它就坐在工具条材质上。现在对比度一律对它实际所在的材质算（`ChromePalette.dark.panel`）。
//
// 一并消失的还有 `OverlayAccent.RGB` 与它自带的 `relativeLuminance` / `contrast`
// —— 那是**第二套颜色类型 + 第二把尺子**。两套并存时，改了其中一套的另一半不会跟着变。

/// 工具条上的一格。
public enum OverlayToolbarSlot: Hashable, Sendable {
    case tool(OverlayTool)
    /// 打开「样式」面板（色板 ×6 + 尺寸 ×3）。
    ///
    /// **它们不再各占一格**：12 格色板/尺寸把工具条撑到 799 点，
    /// 而参考的那条只有一排纯图标。收进面板后工具条降到 ~545 点。
    case style
    /// 识别选区里的文字（ticket 23）。是**动作**不是工具。
    case ocr
    /// 把这张图钉在屏幕上（ticket 14）。同样是动作。
    case pin
    case undo
    case redo
    case save
    case cancel
    case confirm

    /// 点这一格之后，**正在进行的文字输入还留着吗**。
    ///
    /// ⚠️ 「结算」不等于「丢弃」：结算＝把已打的内容落成一个真的标注。只有 `Esc` 才丢。
    public var preservesTextEditing: Bool {
        switch self {
        case .undo, .redo, .style: true
        case .tool, .ocr, .pin, .save, .cancel, .confirm: false
        }
    }

    /// 分组序号。相邻两格分组不同 → 中间画一条分隔线。
    ///
    /// 分组照着参考那条排：**绘制 | 智能 | 动作**。多出来的一组是我们自己的「样式」
    /// （参考把颜色与线宽放在子菜单里，我们收进面板，入口需要一格）。
    public var group: Int {
        switch self {
        case .tool: 0
        case .style: 1
        case .ocr: 2
        case .undo, .redo, .save, .pin, .cancel, .confirm: 3
        }
    }

    /// 这一格是某个 Pro 能力的**入口**吗。`nil` = 免费格。
    ///
    /// 这是「工具栏 / 菜单上的入口 → `ProFeature`」的**唯一一份**映射。
    /// 界面不许自己去拼：将来把某一项放开成免费，改的应该是这一处，
    /// 而不是散在几个视图里的 `if`。
    ///
    /// 刻意写成穷尽 `switch` 而不是 `default: nil`：加了新格子却不表态，
    /// 编译就过不去 —— 而 `default` 会让新格子**悄悄变成免费**，
    /// 那正是"少收一次"里最难发现的一种。
    public var proFeature: ProFeature? {
        switch self {
        case .ocr: .textRecognition
        case .pin: .pin
        case .tool, .style, .undo, .redo, .save, .cancel, .confirm: nil
        }
    }

    /// 可点击的边长。
    var side: CGFloat { OverlayToolbar.buttonSize }
}

/// 工具条上那两个**弹层**里的一格。
public enum OverlayPaletteItem: Hashable, Sendable {
    case color(Int)
    case lineWidth(Int)
    case emoji(Int)
}

/// 弹层有哪几个。
public enum OverlayPalette: String, CaseIterable, Sendable {
    /// 色板 ×6 + 尺寸 ×3（由「样式」格打开）
    case style
    /// 常用表情（选中「表情」工具时自动打开）
    case emoji
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
public enum OverlayToolbar {

    // MARK: - 尺寸

    /// 工具 / 动作按钮的边长
    public static let buttonSize: CGFloat = 28
    /// 色块 / 尺寸块 / 表情块的边长
    public static let swatchSize: CGFloat = 20
    /// 弹层里表情格的边长（emoji 比色块需要更大才认得出）
    public static let emojiSize: CGFloat = 24
    /// 同类相邻两格之间的间距
    public static let itemGap: CGFloat = 4
    /// 弹层里同类相邻两格之间的间距
    public static let paletteGap: CGFloat = 6
    /// 分组边界的额外留白（分隔线两侧各一份）
    public static let groupGap: CGFloat = 9
    /// 工具条自身的内边距
    public static let padding: CGFloat = 6
    /// 工具条与选区之间的间距
    public static let gap: CGFloat = 10
    /// 弹层与它依附的控件之间的间距
    public static let paletteGapFromAnchor: CGFloat = 8
    /// 夹取时与屏幕边缘留的余量
    public static let screenMargin: CGFloat = 8
    /// 分组分隔线的宽度
    public static let separatorWidth: CGFloat = 1
    /// 圆角
    public static let cornerRadius: CGFloat = 10
    /// 弹层里色板占几列
    public static let paletteColumns = 6
    /// 弹层里表情占几列
    public static let emojiColumns = 8

    // MARK: - 内容

    /// 工具条上的全部格子，从左到右。
    public static let slots: [OverlayToolbarSlot] =
        OverlayTool.allCases.map(OverlayToolbarSlot.tool)
        + [.style]
        + [.ocr]
        + [.undo, .redo, .save, .pin, .cancel, .confirm]

    /// 某个弹层里的全部格子。
    public static func paletteItems(_ palette: OverlayPalette) -> [OverlayPaletteItem] {
        switch palette {
        case .style:
            AnnotationPalette.colors.indices.map(OverlayPaletteItem.color)
                + (0..<AnnotationPalette.overlaySizeSlotCount).map(OverlayPaletteItem.lineWidth)
        case .emoji:
            AnnotationPalette.emojis.indices.map(OverlayPaletteItem.emoji)
        }
    }

    // MARK: - 排布

    /// 一次算好的排布结果。
    public struct Layout: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public let slot: OverlayToolbarSlot
            /// 相对工具条**左下角**（与 AppKit 视图坐标一致）
            public let frame: CGRect
        }
        public let items: [Item]
        /// 分组分隔线，同样相对左下角
        public let separators: [CGRect]
        public let size: CGSize

        public func frame(of slot: OverlayToolbarSlot) -> CGRect? {
            items.first { $0.slot == slot }?.frame
        }
    }

    /// 工具条高（单行）。
    public static var height: CGFloat { buttonSize + padding * 2 }

    // MARK: - 提示行（稿子 §03 / §10）

    /// 提示行的高（点）。稿子 §01 的表：「提示行 513 × 22 pt」。
    public static let hintLineHeight: CGFloat = 22

    /// 提示行里那行字的字号。稿子 §01：11。
    public static let hintLineFontSize: CGFloat = 11

    /// 提示行与工具条之间的间隙 —— **必须是 0**。
    ///
    /// 稿子 §03 的原话：「工具条与提示行共材质、无间隙，圆角只在提示行的底部 ——
    /// 它们是**一个东西**，不是『工具条 + 一条通知』。」
    ///
    /// 留一个常量而不是在各处写死 `0`，是为了让"这里本来可以有个缝"这件事有个可改的地方；
    /// 而真正要紧的是它**被断言钉住**了（见 `OverlayToolbarTests.hintLineMetricsMatchSpec`）：
    /// 有缝就不是一个东西了。
    public static let hintLineGap: CGFloat = 0

    /// 工具条 + 提示行一起摆位的结果。
    public struct PanelFrames: Equatable, Sendable {
        public let toolbar: CGRect
        /// 没有提示行时为 `nil`
        public let hintLine: CGRect?
    }

    /// 工具条与提示行**一起**摆在选区外侧（**Cocoa 全局点**）。
    ///
    /// ## 为什么必须整体摆位
    ///
    /// 直觉的写法是"先按 `frame(for:)` 摆好工具条，再在它下面挂一行 22 点的提示行"。
    /// 那在**贴屏底的选区**上会当场错：`frame(for:)` 只保证**工具条自己**在屏幕内，
    /// 于是它的下边可能正好压在屏幕下缘 —— 再往下挂一行就出屏了。
    ///
    /// 更糟的是"翻面"那条路：工具条翻到选区**上方**之后，在它下面挂一行，
    /// 那一行会落在**工具条与选区之间** —— 把用户正要截的东西盖住。
    ///
    /// 所以这里是**先把 62 点（或 40 点）高的整块摆好，再切成两段**：
    /// 靠近选区的那段是工具条，外侧那段是提示行。
    ///
    /// ## 与 `frame(for:)` 的关系
    ///
    /// `frame(for:)` 就是本函数 `showingHint: false` 的那个特例 —— 它转发过来，
    /// 于是"贴边 / 翻面 / 夹取"这三条规则**只有一份**。
    public static func panelFrames(for selection: CGRect,
                                   screenFrame: CGRect,
                                   showingHint: Bool,
                                   gap: CGFloat = gap) -> PanelFrames {
        let size = toolbarSize
        let blockHeight = size.height + (showingHint ? hintLineHeight + hintLineGap : 0)
        let box = selection.standardized
        let screen = screenFrame.standardized

        // ① 优先：选区正下方，左对齐
        var origin = CGPoint(x: box.minX, y: box.minY - gap - blockHeight)
        // 「够不够放」要按**整块**判：这才是整体摆位的意义所在
        let fitsBelow = origin.y >= screen.minY
        // ② 下方放不下 → 翻到上方
        if !fitsBelow {
            origin.y = box.maxY + gap
        }
        // ③ 最后统一夹进屏幕（水平竖直都要）
        //
        // 屏幕比整块还小时（外接小屏、可见区被 Dock 压得很矮），
        // `maxX`/`maxY` 会算成比 `minX`/`minY` 更小的值 —— 用 `max` 兜住，
        // 那样至少保证"左上角在屏幕内、尺寸不变"，而不是算出个反向矩形。
        let minX = screen.minX + screenMargin
        let maxX = max(minX, screen.maxX - screenMargin - size.width)
        let minY = screen.minY + screenMargin
        let maxY = max(minY, screen.maxY - screenMargin - blockHeight)
        origin.x = min(max(minX, origin.x), maxX)
        origin.y = min(max(minY, origin.y), maxY)

        guard showingHint else {
            return PanelFrames(toolbar: CGRect(origin: origin, size: size), hintLine: nil)
        }

        // 切两段：靠选区的那段是工具条，外侧那段是提示行。
        //
        // ⚠️ 用**夹取之前**那条判据（`fitsBelow`）决定切的顺序，不是"看现在的高度关系"——
        // 夹取之后整块可能被推到屏幕里，那时它下面那侧已经不代表"外侧"了。
        let hintSize = CGSize(width: size.width, height: hintLineHeight)
        if fitsBelow {
            // 整块在选区下方 ⇒ 工具条在上（靠近选区）、提示行在下
            return PanelFrames(
                toolbar: CGRect(x: origin.x,
                                y: origin.y + hintLineHeight + hintLineGap,
                                width: size.width, height: size.height),
                hintLine: CGRect(origin: origin, size: hintSize))
        }
        // 整块在选区上方 ⇒ 工具条在下（靠近选区）、提示行在上
        return PanelFrames(
            toolbar: CGRect(origin: origin, size: size),
            hintLine: CGRect(x: origin.x,
                             y: origin.y + size.height + hintLineGap,
                             width: hintSize.width, height: hintSize.height))
    }

    /// 工具条 + 提示行合起来那块**面板**的矩形。
    ///
    /// 零间隙时它就是两者的并集 —— 也就是说"圆角只在提示行的底部"这句话，
    /// 画出来正好等于**一整块圆角矩形**（工具条上圆角 + 中间方 + 提示行下圆角）。
    /// 视图只需要给这一块铺一次材质，不必去分别遮罩两个角的圆。
    public static func panelFrame(toolbar: CGRect, hintLine: CGRect?) -> CGRect {
        guard let hintLine else { return toolbar }
        return toolbar.union(hintLine)
    }

    /// 一块面板该用多大的圆角。
    ///
    /// ## 为什么不能一律 10
    ///
    /// 同一块面板有三种高度：40（② 只有工具条）、62（工具条 + 提示行）、
    /// **22（③ 只有提示行 —— 那时工具条不出现，见 `OverlayHintLinePresentation`）**。
    ///
    /// 10 点的圆角放在 40 与 62 上是"圆角"；放到 22 高的条上，上下两个圆角一合，
    /// 它就成了一个**胶囊** —— 而胶囊读起来像一颗徽章，不像一条说明。
    ///
    /// 判据用**三分之一**而不是"高度的一半减几"：这条线上 40 与 62 都得拿到完整的 10
    /// （它们才是常态），只有真的矮到放不下时才收 —— `40/3 > 10`、`62/3 > 10`，
    /// 所以那两个值一个都不变。
    public static func panelCornerRadius(panelHeight: CGFloat) -> CGFloat {
        min(cornerRadius, panelHeight / 3)
    }

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

    // MARK: - 弹层排布

    /// 一个弹层里各格的位置（相对弹层左下角）。
    public struct PaletteLayout: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public let item: OverlayPaletteItem
            public let frame: CGRect
        }
        public let items: [Item]
        public let size: CGSize

        public func frame(of item: OverlayPaletteItem) -> CGRect? {
            items.first { $0.item == item }?.frame
        }
    }

    /// 弹层里每格多大。
    static func paletteSide(_ palette: OverlayPalette) -> CGFloat {
        palette == .emoji ? emojiSize : swatchSize
    }

    /// 弹层排布。
    ///
    /// 「样式」是两行（上排色板、下排尺寸）—— 一行放 9 格会把弹层撑得很宽，
    /// 而它是要贴在工具条边上的，太宽反而盖住选区。
    public static func paletteLayout(_ palette: OverlayPalette) -> PaletteLayout {
        let side = paletteSide(palette)
        let items = paletteItems(palette)
        let columns = palette == .emoji ? emojiColumns : paletteColumns
        var result: [PaletteLayout.Item] = []
        // 从**上往下**排：AppKit 的 y 向上，所以起始 y 是总高减去一行
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let contentHeight = CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * paletteGap
        let contentWidth = CGFloat(columns) * side + CGFloat(columns - 1) * paletteGap

        for (index, item) in items.enumerated() {
            let column = index % columns
            let row = index / columns
            result.append(PaletteLayout.Item(
                item: item,
                frame: CGRect(x: padding + CGFloat(column) * (side + paletteGap),
                              y: padding + CGFloat(rows - 1 - row) * (side + paletteGap),
                              width: side,
                              height: side)))
        }

        return PaletteLayout(items: result,
                             size: CGSize(width: contentWidth + padding * 2,
                                          height: contentHeight + padding * 2))
    }

    /// 弹层贴在**谁**身上。用来算它该往哪边弹。
    public static func paletteAnchor(_ palette: OverlayPalette,
                                     toolbar: CGRect) -> CGRect {
        switch palette {
        case .style:
            return hitFrame(of: .style, in: toolbar) ?? toolbar
        case .emoji:
            return hitFrame(of: .tool(.emoji), in: toolbar) ?? toolbar
        }
    }

    /// 弹层位置（**Cocoa 全局点**）。
    ///
    /// 优先弹在工具条**外侧**（远离选区那一侧），放不下再翻到内侧，最后夹进屏幕。
    /// 与 `frame(for:)` 同一个套路：**夹取必须最后做**。
    public static func paletteFrame(_ palette: OverlayPalette,
                                    toolbar: CGRect,
                                    screenFrame: CGRect,
                                    gap: CGFloat = paletteGapFromAnchor) -> CGRect {
        let size = paletteLayout(palette).size
        let screen = screenFrame.standardized
        let anchor = paletteAnchor(palette, toolbar: toolbar)

        // 工具条在选区下方时，"外侧"是下边；但工具条也可能被翻到选区上方 ——
        // 判据用"哪边离屏幕边缘更远"更稳：往外弹总是往空间大的那侧。
        let below = anchor.minY - gap - size.height
        let above = anchor.maxY + gap
        var origin = CGPoint(x: anchor.minX, y: below)
        let roomBelow = below - screen.minY
        let roomAbove = screen.maxY - above
        if roomBelow < 0, roomAbove > roomBelow {
            origin.y = above
        }

        // 最后统一夹进屏幕，水平竖直都要（同 `frame(for:)`）
        let minX = screen.minX + screenMargin
        let maxX = max(minX, screen.maxX - screenMargin - size.width)
        let minY = screen.minY + screenMargin
        let maxY = max(minY, screen.maxY - screenMargin - size.height)
        origin.x = min(max(minX, origin.x), maxX)
        origin.y = min(max(minY, origin.y), maxY)

        return CGRect(origin: origin, size: size)
    }

    /// 点在弹层的哪一格上（`nil` = 不在任何格子上）。
    public static func paletteItem(at point: CGPoint,
                                   in palette: CGRect,
                                   kind: OverlayPalette) -> OverlayPaletteItem? {
        let local = CGPoint(x: point.x - palette.minX, y: point.y - palette.minY)
        return paletteLayout(kind).items.first { $0.frame.contains(local) }?.item
    }

    // MARK: - 位置

    /// 算出工具栏该放在哪（**Cocoa 全局点**，y 向上）。
    ///
    /// ⚠️ **规则只有一份**：它是 `panelFrames(showingHint: false)` 的特例。
    /// 原先这里那三段（贴边 / 翻面 / 夹取）是独立写的一份，加提示行时必然要写第二份 ——
    /// 而两份规则各自都对、凑在一起才错的那种坑，本文件开头已经踩过一次。
    ///
    /// ⚠️ **夹取必须最后做**。先夹再翻会得到"翻上去之后又被夹回屏幕外"这种组合 ——
    /// 两个规则各自都对，顺序一错结果就错，而且只在贴边的选区上出现。
    public static func frame(for selection: CGRect,
                             screenFrame: CGRect,
                             gap: CGFloat = gap) -> CGRect {
        panelFrames(for: selection, screenFrame: screenFrame, showingHint: false, gap: gap).toolbar
    }

    /// 某一格的命中区域（Cocoa 全局点）。
    public static func hitFrame(of slot: OverlayToolbarSlot, in toolbar: CGRect) -> CGRect? {
        guard let local = layout().frame(of: slot) else { return nil }
        return local.offsetBy(dx: toolbar.minX, dy: toolbar.minY)
    }

    /// 点在哪个格子上（`nil` = 不在任何格子上）。
    ///
    /// 顺序遍历即可（格子互不重叠）。用 `layout()` 而不是写死若干 `if`，
    /// 这样以后加一个工具不必再改这里。
    public static func slot(at point: CGPoint, in toolbar: CGRect) -> OverlayToolbarSlot? {
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

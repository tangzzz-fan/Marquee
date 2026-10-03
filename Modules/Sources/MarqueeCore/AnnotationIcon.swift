import Foundation

/// 标注与编辑器要用的**图标名** —— 全项目唯一一份。
///
/// ## 为什么必须唯一
///
/// 设计稿 §01 把这条列成了编辑器的**验收第一条**：「同一个功能在两处用同一个图标。
/// 覆盖层有『文字』工具，编辑器也有 —— 图标不同，用户会以为是两个东西。」
///
/// 而"两处各写一遍字符串"正是这条最容易破的方式：它们**不会**报错，
/// 只会在某一次改动里悄悄分叉，然后用户看到两个长得不一样的「文字」。
/// 所以两个工具枚举都从这里取，`AnnotationEditorTool` 与 `OverlayTool` 各自的
/// `switch` 只负责把"工具"翻译成"标注类型"，剩下的名字只有一处。
///
/// ## 两条踩过的坑
///
/// 1. ⚠️ **不能用 `textformat`** —— 它有中文本地化变体：中文环境下系统会换成
///    `textformat.zh`，而那个变体渲染出来是**两个字「格式」**，夹在一排图标里非常突兀
///    （用户的原话是"格式这个文字还在"）。`t.square` 是"方框里的 T"，
///    两种语言下都长一样。见 `docs/PITFALLS.md` 28。
/// 2. **多色符号要 `.preferringMonochrome()`**（那条规矩在 `ChromeSymbol` 里）——
///    否则多色符号的第一层会被整片填充，`face.smiling` 会变成一个实心圆点。
public enum AnnotationIcon {

    // MARK: - 一种标注类型长什么样

    /// 标注类型 → SF Symbol 名。**编辑器的八个工具与覆盖层的七个工具共用这一份。**
    ///
    /// ⚠️ 两个换过的名字，都是**对着稿子比出来的**（2026-10-04）：
    ///
    /// | 工具 | 原先 | 现在 | 为什么换 |
    /// | --- | --- | --- | --- |
    /// | 画笔 | `pencil.tip` | `pencil` | `pencil.tip` 只画**笔尖那一段**，渲染出来是一个楔形；稿子画的是一整支笔 |
    /// | 模糊 | `camera.filters` | `drop` | `camera.filters` 是两个交叠的圆（像"合并"）；稿子画的是**水滴** |
    ///
    /// 这种错不会崩也不会报错，只是"图标看着不像那个功能"——
    /// 而用户说不出哪里不对，只会觉得这个 app 有点糙。
    public static func symbol(for kind: AnnotationKind) -> String {
        switch kind {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil"
        case .text: "t.square"
        case .mosaic: "checkerboard.rectangle"
        case .blur: "drop"
        }
    }

    /// **Pro 能力 → 卡片上那一枚图标**（稿子 §02 的「① 图标槽」）。
    ///
    /// 这一槽证明"这张卡在回答你刚才的动作" —— 广告没有这一槽，因为它不关心你点了什么。
    /// 所以它必须是**用户刚点的那个功能**（也就是工具条上那一格里那枚），
    /// 而不是一枚笼统的锁或星星。
    ///
    /// ⚠️ 与工具条**同源**：识别文字与钉图直接复用 `recognizeText` / `pin` ——
    /// 用户在格子上看到什么，卡片上就是什么。另外两枚是这一槽独有的
    /// （滚动截屏与最近截图在工具条上没有格子）。
    public static func symbol(for feature: ProFeature) -> String {
        switch feature {
        case .scrollCapture: "scroll"
        case .textRecognition: recognizeText
        case .pin: pin
        case .unlimitedHistory: "photo.stack"
        }
    }

    // MARK: - 编辑器

    /// 编辑器工具 → 图标名。多出来的那一个（选择）覆盖层没有。
    ///
    /// ⚠️ 这里**一个 case 一个 case 地写**，而不是
    /// `symbol(for: tool.annotationKind ?? .rectangle)` ——
    /// `??` 那个兜底会把"这个工具没有对应类型"（`.select`）**悄悄变成 rectangle**：
    /// 图标错成一个矩形，而它看起来只是"这个图标不对"。穷尽的 `switch` 则保证
    /// 将来加一个工具时**编译就过不去**，而不是等用户看见。
    public static func symbol(for tool: AnnotationEditorTool) -> String {
        switch tool {
        case .select: select
        case .rectangle: symbol(for: AnnotationKind.rectangle)
        case .ellipse: symbol(for: AnnotationKind.ellipse)
        case .arrow: symbol(for: AnnotationKind.arrow)
        case .pen: symbol(for: AnnotationKind.pen)
        case .text: symbol(for: AnnotationKind.text)
        case .mosaic: symbol(for: AnnotationKind.mosaic)
        case .blur: symbol(for: AnnotationKind.blur)
        }
    }

    // MARK: - 覆盖层

    /// 覆盖层工具 → 图标名。
    ///
    /// 只有「表情」是覆盖层独有的：它与「文字」产出的**是同一种标注**（`.text`），
    /// 但它们是两个工具 —— 一个是"写一行字"，一个是"贴一个表情"。
    /// 所以这一格必须单独给：走类型表的话两格会长得一模一样。
    public static func symbol(for tool: OverlayTool) -> String {
        switch tool {
        case .emoji: emoji
        case .rectangle, .ellipse, .arrow, .pen, .mosaic, .text:
            symbol(for: tool.kind)
        }
    }

    // MARK: - 只在一处出现的那些

    /// 选择（没拿工具时的那只手）。覆盖层没有这个工具 —— 它是"没选工具"的默认状态。
    public static let select = "cursorarrow"
    /// 裁切。**新画的**（覆盖层没有）—— 它是"改画布"的工具，不是"画东西"的。
    public static let crop = "crop"
    /// 表情（覆盖层独有）。
    public static let emoji = "face.smiling"

    // MARK: - 动作格（两处逐字同一枚）

    public static let undo = "arrow.uturn.backward"
    public static let redo = "arrow.uturn.forward"
    public static let save = "square.and.arrow.down"
    /// 取消。**编辑器里它是珊瑚红**（放弃这次编辑并关闭，不产出）。
    public static let cancel = "xmark"
    /// 完成。**编辑器里它是绿**（复制到剪贴板并关闭）。
    public static let confirm = "checkmark"
    /// 识别文字。**卡片的图标槽也用它**（同一个功能同一枚）。
    public static let recognizeText = "text.viewfinder"
    /// 识别进行中（同一格换图标，不是换格）。
    public static let recognizing = "hourglass"
    /// 缩放的 − / + 。稿子 §04 那一组写的就是「− 34% +」——
    /// **不用放大镜**：这一格紧挨着一个百分数，朴素加减号读起来是"调数值"，
    /// 而放大镜会让人以为点下去是"进入查看模式"。
    /// 预设弹层里「从几开始」那一对 ± 用的也是这两枚（同一个动作同一个符号）。
    public static let zoomIn = "plus"
    public static let zoomOut = "minus"
    /// Pro 小锁（9 × 9，白 55%）。
    public static let lock = "lock.fill"
    /// 钉图。**卡片的图标槽也用它**。
    public static let pin = "pin"
    /// 文字预设置层里那两段的小图标。
    public static let presetText = "text.alignleft"
    public static let presetCounter = "list.number"
}

import Foundation

/// 按一次 `Esc`，该退掉哪一层。
///
/// ## 为什么要有这个类型
///
/// 项目里有**两个**界面各自处理 `Esc`：覆盖层（框选那会儿）与编辑器窗口。
/// 它们曾经不是同一件事 —— 覆盖层是「退一层，到底就取消」，
/// 编辑器却是「完成并复制」（把 `Esc` 当成 `✓` 用了）。
///
/// 这带来的问题是**同一个键在两个地方性格相反**：用户在覆盖层里养成
/// "`Esc` = 我反悔了"的肌肉记忆，进编辑器后按同一个键，做的却是
/// "把图写进剪贴板" —— 一个**不可逆**的动作。
/// 与 macOS 的约定也相反：系统里 `Esc` 就是 Cancel，`⏎` 才是默认按钮。
///
/// ## 现在的规则（两个界面共用）
///
/// ```
/// Esc = 退一层，到底 = 取消        ⏎ = 确认
/// ```
///
/// **`Esc` 永远不产出任何东西** —— 这句话是这一整块的要害。
/// 一个"退出键"要是顺手写了剪贴板或落了盘，用户下次就不敢按它了。
///
/// ## 层级顺序为什么是这个顺序
///
/// 从**最浅**的一层往深了退。判据是"用户刚才做了哪件事"：
/// 越晚发生的事，越该先被退掉 —— 这是所有人的第一直觉。
///
/// 覆盖层那边是同一套语义（见 `SelectionOverlayController.handleEscape`），
/// 只是它的状态更多（自动滚动、卡片、弹层），层级表更长。
/// **两边的层数不同是有意的** —— 交互模型本来就不一样；
/// 统一的是"性格"，不是"层数"。
public enum EscapeStep: Equatable, Sendable {

    /// 正在输入文字 → 丢掉这半截输入（已经落成标注的那些**不动**）。
    ///
    /// 排最前：输入框是最浅、最晚出现的一层，
    /// 而且此时用户的注意力就在那个框里。
    case cancelTextEditing

    /// 有正在进行的拖拽/裁剪 → 退回**按下那一刻**那一版。
    ///
    /// 不是"删掉这个标注"，是"当我没拖过"。
    case cancelGesture

    /// 选了工具 → 退出工具。
    ///
    /// ⚠️ 这一档**必须有**：少了它，用户画完几个箭头想退出画标注模式，
    /// 一下 `Esc` 就直接把整个界面收掉了 —— 而那张图可能已经很难再复现。
    case leaveTool

    /// 选中了标注 → 取消选中（标注本身留着）。
    case clearSelection

    /// 到底了 → 收掉整个界面。
    ///
    /// ⚠️ **这一层做什么，由「底」决定 —— 这是全梯子唯一的例外，而且它必须例外。**
    ///
    /// 两个界面退到底时，「底下压着什么」是**相反**的：
    ///
    /// | | 底 | 退到底该做什么 | 为什么 |
    /// | --- | --- | --- | --- |
    /// | 覆盖层 | **还没有东西**（一次截图刚被叫起来） | 取消，不留痕 | 什么都没产出 ⇒「没有」就是零损失 |
    /// | 编辑器 | **已经有东西**（拼好的长图 + 用户刚画的标注） | 完成并复制并关闭 | 已经产出 ⇒「带走」才是零损失 |
    ///
    /// **硬把它统一成一个字面动作，会让一边变危险**：
    /// 覆盖层的 `Esc` 变成"完成"就没有退路；编辑器的 `Esc` 变成"取消"，
    /// 则是**按一下丢掉几分钟的活**。
    ///
    /// ⇒ 所以这里统一的是**规则**（退最里面那一层、退无可退时朝"不丢东西"的方向退），
    /// **不是字面**。
    ///
    /// ⚠️ 编辑器的"丢弃"由 `✗` 单独承担 —— 它必须**用手点**，
    /// 不能让人顺着下意识按出来。
    ///
    /// （这一条是被设计稿推翻后修正的：最初把 `.dismiss` 实现成"关闭＝丢弃"，
    /// 理由是"退出键不该做不可逆的事"。那个判据**把「产出」和「销毁」混为一谈** ——
    /// 两者都不可逆，但方向相反。真正该守的是"不丢东西"，不是"不写东西"。）
    case dismiss
}

/// 编辑器的可退层级 —— 纯粹为了回答"这一次 `Esc` 退哪一层"。
///
/// 做成一个入参化的值类型而不是去读视图状态，是为了**能脱机单测**：
/// "层叠时的优先级"这类错不会崩、不会报错，只会让用户觉得
/// "我按了 `Esc`，退掉的东西不对" —— 那种错靠肉眼试不全。
public struct EditorEscapeState: Equatable, Sendable {

    /// 正在编辑某个文字的输入框。
    public var isEditingText: Bool
    /// 裁剪框正开着（还没确认）。
    public var isCropping: Bool
    /// 当前工具。
    public var tool: AnnotationEditorTool
    /// 选中的标注。
    public var selection: Set<UUID>

    public init(isEditingText: Bool = false,
                isCropping: Bool = false,
                tool: AnnotationEditorTool = .select,
                selection: Set<UUID> = []) {
        self.isEditingText = isEditingText
        self.isCropping = isCropping
        self.tool = tool
        self.selection = selection
    }

    /// 这一次 `Esc` 该退哪一层。
    ///
    /// 顺序即判据，**不可随意调换**：从最浅的一层往深了退。
    public func escapeStep() -> EscapeStep {
        if isEditingText { return .cancelTextEditing }
        if isCropping { return .cancelGesture }
        if tool != .select { return .leaveTool }
        if !selection.isEmpty { return .clearSelection }
        return .dismiss
    }
}

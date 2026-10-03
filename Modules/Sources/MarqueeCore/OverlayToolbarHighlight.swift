/// 工具条上某一格**此刻该不该点亮**。
///
/// ## 为什么单独抽出来
///
/// 原先绘制代码里写的是「有弹层开着就点亮『样式』格」—— 而弹层有**两个**
/// （样式、表情），于是**打开表情面板时「样式」也跟着亮**。
/// 用户的原话是「点击 emoji 时，此时画板按钮也高亮了，不对」。
///
/// 这类错的形态很温和：不崩、不报错，只是多亮一格 ——
/// 而它只有把两个面板都开一遍才看得出来。所以判据要写成一条能单测的规则，
/// 而不是散在绘制回调里的 `if`。
public enum OverlayToolbarHighlight {

    /// 该不该点亮。
    ///
    /// - Parameters:
    ///   - activeTool: 当前选中的工具（`nil` = 没选）
    ///   - openPalette: 当前展开的弹层（`nil` = 没展开）
    public static func isLit(_ slot: OverlayToolbarSlot,
                             activeTool: OverlayTool?,
                             openPalette: OverlayPalette?) -> Bool {
        switch slot {
        case .tool(let tool):
            // 只认「自己是不是当前工具」。表情面板开着与表情工具被选中**是两件事**，
            // 只是恰好同时发生（选中表情工具就会打开面板）——
            // 将来若允许"选着画笔的同时开着色板"，这里也不会跟着错。
            activeTool == tool

        case .style:
            // ⚠️ **只认 `.style`**。写成 `openPalette != nil` 就是那个 bug。
            openPalette == .style

        case .ocr, .pin, .undo, .redo, .save, .cancel, .confirm:
            // 这几个是**动作**：点完就执行，没有"被选中"的持续状态。
            // 给它们点亮会让人以为"现在处在撤销模式"。
            false
        }
    }

    /// 这一格**此刻能不能点**。
    ///
    /// ## 为什么单独有一条
    ///
    /// 因为「不能点」与「悬停要亮」互斥：一个置灰的格子跟着鼠标一起亮起来，
    /// 会让用户以为它其实能用（点了没反应 ⇒ 报"按钮坏了"）。
    ///
    /// ## 谁才允许是"不可用"
    ///
    /// 设计稿 §07 的原话：「置灰只属于动作里的撤销与重做，且只在『当前确实没有可撤的东西』时
    /// 出现 —— **全工具条唯一允许变灰的地方**。」
    ///
    /// 所以这里是一个**穷尽的** `switch`：将来加一格时，不表态就编译不过。
    /// 尤其注意两类**看起来像"不可用"其实不是**的：
    ///
    /// - **Pro 那两格**（识别文字 / 钉图）：免费版里点了只弹卡片，但**永远不许变灰** ——
    ///   变灰就点不动，而"点得动"正是用户看到那张解释卡片的唯一途径。
    /// - **识别进行中**：那是一个"忙"的状态，已经由**换成沙漏图标**表达了。
    ///   再把它变灰是同一个意思说两遍，还破了上面那条"唯一允许变灰"的约束。
    public static func isEnabled(_ slot: OverlayToolbarSlot,
                                 canUndo: Bool,
                                 canRedo: Bool) -> Bool {
        switch slot {
        case .undo: canUndo
        case .redo: canRedo
        case .tool, .style, .ocr, .pin, .save, .cancel, .confirm: true
        }
    }
}

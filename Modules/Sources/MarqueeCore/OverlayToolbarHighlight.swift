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
}

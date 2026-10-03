import Testing
@testable import MarqueeCore

/// 工具条上哪一格该亮。
@Suite("工具条点亮")
struct OverlayToolbarHighlightTests {

    private func lit(_ slot: OverlayToolbarSlot,
                     tool: OverlayTool? = nil,
                     palette: OverlayPalette? = nil) -> Bool {
        OverlayToolbarHighlight.isLit(slot, activeTool: tool, openPalette: palette)
    }

    /// 用户报的那条：点 emoji 时「样式」也跟着亮了。
    @Test("打开表情面板时，**只有表情格**该亮 —— 「样式」不能跟着亮")
    func emojiPaletteDoesNotLightTheStyleSlot() {
        #expect(lit(.tool(.emoji), tool: .emoji, palette: .emoji))
        #expect(!lit(.style, tool: .emoji, palette: .emoji),
                "表情面板开着时样式格亮了 —— 用户会以为颜色面板也开着")
    }

    @Test("打开样式面板时，只有样式格该亮")
    func stylePaletteLightsOnlyItself() {
        #expect(lit(.style, palette: .style))
        #expect(!lit(.tool(.emoji), palette: .style), "没选表情工具，它不该亮")
        #expect(!lit(.tool(.rectangle), palette: .style))
    }

    @Test("选中某个工具时只有它自己亮")
    func onlyTheActiveToolIsLit() {
        #expect(lit(.tool(.rectangle), tool: .rectangle))
        #expect(!lit(.tool(.ellipse), tool: .rectangle))
        #expect(!lit(.style, tool: .rectangle), "选了工具、没开弹层，样式格不该亮")
    }

    @Test("动作格永远不亮 —— 它们是动作，不是状态")
    func actionSlotsNeverLightUp() {
        // 点亮等于在说"现在处在撤销模式"，而"撤销"点一下就用掉了。
        for slot in [OverlayToolbarSlot.ocr, .pin, .undo, .redo, .save, .cancel, .confirm] {
            #expect(!lit(slot, tool: .rectangle, palette: .style), "\(slot) 不该亮")
            #expect(!lit(slot, tool: .emoji, palette: .emoji), "\(slot) 不该亮")
        }
    }

    @Test("什么都没选、什么弹层都没开时，整条都不亮")
    func nothingLitWhenIdle() {
        for slot in OverlayToolbar.slots {
            #expect(!lit(slot), "\(slot) 在空闲状态下亮了")
        }
    }

    @Test("弹层开着但工具没选中时（理论上到不了）也不亮工具格")
    func paletteWithoutToolLightsNothingButTheStyleSlot() {
        // 用 `.style` 之外的那一个弹层做输入：表情弹层若在没选表情工具时打开，
        // 工具格不该亮 —— "面板开着"和"工具被选中"是两件事。
        #expect(!lit(.tool(.emoji), palette: .emoji))
        #expect(!lit(.tool(.text), palette: .emoji))
    }

    // MARK: - 可点 / 不可点

    private func enabled(_ slot: OverlayToolbarSlot,
                         canUndo: Bool = true,
                         canRedo: Bool = true) -> Bool {
        OverlayToolbarHighlight.isEnabled(slot, canUndo: canUndo, canRedo: canRedo)
    }

    @Test("「不可用」只属于撤销与重做 —— 而且只在自己真的没得撤时")
    func onlyUndoRedoCanBeDisabled() {
        // 稿子 §07：「置灰只属于动作里的撤销与重做……**全工具条唯一允许变灰的地方**」。
        for slot in OverlayToolbar.slots where slot != .undo && slot != .redo {
            #expect(enabled(slot, canUndo: false, canRedo: false),
                    "\(slot) 在「什么都没得撤」时也必须是可点的")
        }
        #expect(!enabled(.undo, canUndo: false), "没得撤 → 撤销置灰")
        #expect(!enabled(.redo, canRedo: false), "没得重做 → 重做置灰")
        // 而且两者互相独立：有得撤不代表有得重做
        #expect(enabled(.undo, canUndo: true, canRedo: false))
        #expect(enabled(.redo, canUndo: false, canRedo: true))
    }

    @Test("Pro 那两格永远可点 —— 变灰了就点不动，也就永远看不到那张解释的卡片")
    func proSlotsAreNeverDisabled() {
        // 这一条单独立出来，因为它是**产品决策**而不是实现细节：
        // 免费版里「识别文字」「钉图」点了只弹卡片、不干活，而用户必须点得动。
        for slot in [OverlayToolbarSlot.ocr, .pin] {
            #expect(enabled(slot, canUndo: false, canRedo: false),
                    "\(slot) 被置灰了 —— 用户再也没有途径知道为什么用不了")
        }
    }
}

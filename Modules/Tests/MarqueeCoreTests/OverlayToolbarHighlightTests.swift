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
}

import Testing
import Foundation
@testable import MarqueeCore

/// `Esc` 梯子：退哪一层。
///
/// 这类错**不会崩、不会报错**，只会让用户觉得"我按了 `Esc`，退掉的东西不对" ——
/// 所以断言要写清楚**为什么**是这一层，而不是只写"等于某个枚举值"。
@Suite("Esc 梯子")
struct EscapeLadderTests {

    // MARK: - 逐层

    @Test("正在输入文字 → 只丢这半截输入")
    func editingTextGoesFirst() {
        let state = EditorEscapeState(isEditingText: true)
        #expect(state.escapeStep() == .cancelTextEditing)
    }

    @Test("裁剪框开着 → 取消裁剪")
    func croppingCancels() {
        let state = EditorEscapeState(isCropping: true)
        #expect(state.escapeStep() == .cancelGesture)
    }

    @Test("选了工具 → 退出工具（不是退出界面）")
    func leavesToolBeforeDismissing() {
        let state = EditorEscapeState(tool: .arrow)
        // ⚠️ 这一条守的是"画了几个箭头想退出标注模式，一下 Esc 全没"
        #expect(state.escapeStep() == .leaveTool)
    }

    @Test("选中了标注 → 取消选中，标注留着")
    func clearsSelection() {
        let state = EditorEscapeState(selection: [UUID()])
        #expect(state.escapeStep() == .clearSelection)
    }

    @Test("什么都没开着 → 才是关掉界面")
    func bareStateDismisses() {
        let state = EditorEscapeState()
        #expect(state.escapeStep() == .dismiss)
    }

    // MARK: - 层叠时的优先级（顺序错了就退错层）

    @Test("全都有时，退的是最浅那层：输入")
    func deepestStackStillLeavesTextFirst() {
        let state = EditorEscapeState(isEditingText: true,
                                      isCropping: true,
                                      tool: .mosaic,
                                      selection: [UUID(), UUID()])
        #expect(state.escapeStep() == .cancelTextEditing)
    }

    @Test("裁剪 + 工具 + 选中：裁剪优先于工具")
    func croppingBeatsTool() {
        let state = EditorEscapeState(isCropping: true,
                                      tool: .rectangle,
                                      selection: [UUID()])
        #expect(state.escapeStep() == .cancelGesture)
    }

    @Test("工具 + 选中：先退工具，再谈选中")
    func toolBeatsSelection() {
        let state = EditorEscapeState(tool: .pen, selection: [UUID()])
        // 用户按下 `Esc` 时想的是"我不画了"，不是"我不选这个矩形了"
        #expect(state.escapeStep() == .leaveTool)
    }

    @Test("选中非空即算作一层，哪怕只有一个")
    func singleSelectionCounts() {
        #expect(EditorEscapeState(selection: [UUID()]).escapeStep() == .clearSelection)
        #expect(EditorEscapeState(selection: []).escapeStep() == .dismiss)
    }

    // MARK: - 头号规则：到底 = 取消，不是产出

    @Test("到底这一步是 dismiss —— 至于做什么，交给调用方（两个底是反的）")
    func bottomIsDismiss() {
        let state = EditorEscapeState()
        let step = state.escapeStep()
        // 梯子只回答"退到哪一层"，**不回答那一层做什么** —— 后者由「底」决定：
        //   覆盖层的底是"还没有东西" ⇒ 退到底＝取消（不留痕）
        //   编辑器的底是"已经有东西" ⇒ 退到底＝带走
        // 硬统一字面会让一边变危险（编辑器的 `Esc` 变成"取消"＝按一下丢掉几分钟的活）。
        //
        // 这条挡住的是"跳过所有层直接退出"那类错：一旦 `Esc` 不再先退最里面那一层，
        // 用户画到一半按一下就连人带活一起没了。
        #expect(step == .dismiss)
        #expect(step != .cancelTextEditing)
        #expect(step != .cancelGesture)
    }

    @Test("退完最后一层之后的下一次 `Esc`：状态已清空，仍然到底")
    func idempotentAtBottom() {
        // 退到位之后再按 `Esc`，不该"退到更浅的层"或者卡住 —— 它是幂等的。
        let cleared = EditorEscapeState(tool: .select, selection: [])
        #expect(cleared.escapeStep() == .dismiss)
        #expect(cleared.escapeStep() == .dismiss)
    }
}

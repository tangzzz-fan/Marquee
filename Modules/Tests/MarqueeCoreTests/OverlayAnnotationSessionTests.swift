import CoreGraphics
import Foundation
import MarqueeCore
import Testing

/// 覆盖层里"就地画标注"的状态机（ticket 21）。
///
/// 这些用例的价值在于：**误点、反向拖拽、撤销往返**这几类问题，
/// 靠手工点击几乎不可能稳定复现（尤其"1×1 的脏点"这种，得先放大才看得见）。
@Suite("覆盖层标注会话")
struct OverlayAnnotationSessionTests {

    private func session() -> OverlayAnnotationSession {
        var session = OverlayAnnotationSession()
        // 只改这两项。**不要整个换掉 style** —— 那样会把打码强度换回 `AnnotationStyle`
        // 的默认值（12），而那不是工具条三档里的任何一个，于是"没有任何一档高亮"。
        session.style.stroke = .red
        session.style.lineWidth = 4
        return session
    }

    /// 确保当前用的是这个工具（**不是** toggle —— 已经是它了就保持）
    private func use(_ session: inout OverlayAnnotationSession, _ tool: OverlayTool) {
        if session.tool != tool { session.toggle(tool: tool) }
    }

    /// 完整画一笔：落笔 → 拖 → 收笔
    @discardableResult
    private func draw(_ session: inout OverlayAnnotationSession,
                      _ tool: OverlayTool,
                      from start: CGPoint,
                      to end: CGPoint) -> Bool {
        use(&session, tool)
        session.beginStroke(at: start)
        session.updateStroke(to: end)
        return session.endStroke(at: end)
    }

    // MARK: - 工具选择

    @Test("再点一次同一个工具 = 取消选中（画完想改选区不该先去别处点一下）")
    func togglingSameToolDeselects() {
        var subject = session()

        subject.toggle(tool: .rectangle)
        #expect(subject.tool == .rectangle)
        #expect(subject.isDrawing)

        subject.toggle(tool: .rectangle)
        #expect(subject.tool == nil)
        #expect(!subject.isDrawing)
    }

    @Test("换工具时，正在画的那一笔会被丢掉（否则会留下一个半成品）")
    func switchingToolDropsDraft() {
        var subject = session()

        subject.toggle(tool: .rectangle)
        subject.beginStroke(at: CGPoint(x: 0, y: 0))
        subject.updateStroke(to: CGPoint(x: 50, y: 50))
        #expect(subject.draft != nil)

        subject.toggle(tool: .ellipse)

        #expect(subject.draft == nil)
        #expect(subject.annotations.isEmpty)
        #expect(subject.tool == .ellipse)
    }

    // MARK: - 画

    @Test("矩形：从左上拖到右下")
    func rectangleForward() {
        var subject = session()

        let committed = draw(&subject, .rectangle, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 70))

        #expect(committed)

        #expect(subject.annotations.count == 1)
        #expect(subject.annotations[0].kind == .rectangle)
        #expect(subject.annotations[0].frame == CGRect(x: 10, y: 20, width: 50, height: 50))
    }

    @Test("矩形：反向拖（右下往左上）也要得到同样的框 —— 不该出现负尺寸")
    func rectangleBackward() {
        var subject = session()

        draw(&subject, .rectangle, from: CGPoint(x: 60, y: 70), to: CGPoint(x: 10, y: 20))

        let frame = subject.annotations[0].frame.standardized
        #expect(frame == CGRect(x: 10, y: 20, width: 50, height: 50))
        #expect(frame.width > 0 && frame.height > 0, "负尺寸的框在描边路径上画不出来")
    }

    @Test("箭头：两个端点 + 包围盒")
    func arrow() {
        var subject = session()

        draw(&subject, .arrow, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 50))

        let annotation = subject.annotations[0]
        #expect(annotation.kind == .arrow)
        #expect(annotation.path == [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 50)])
        #expect(annotation.frame == CGRect(x: 10, y: 10, width: 30, height: 40))
    }

    @Test("画笔：路径点全留下，且太密的点会被去重")
    func pen() {
        var subject = session()

        subject.toggle(tool: .pen)
        subject.beginStroke(at: CGPoint(x: 0, y: 0))
        for x in 0..<60 {
            // 每步 0.2 点 —— 远小于去重阈值 1.5
            subject.updateStroke(to: CGPoint(x: CGFloat(x) * 0.2, y: 0))
        }
        subject.updateStroke(to: CGPoint(x: 100, y: 0))
        subject.endStroke(at: CGPoint(x: 100, y: 0))

        let path = subject.annotations[0].path
        #expect(path.first == CGPoint(x: 0, y: 0))
        #expect(path.last == CGPoint(x: 100, y: 0))
        #expect(path.count < 15, "60 个几乎重合的点应当被去重，实际 \(path.count) 个")
    }

    // MARK: - 最小尺寸（误点不该留下脏点）

    @Test("一次误点：按下就松开，不留任何东西")
    func strayClickLeavesNothing() {
        var subject = session()

        subject.toggle(tool: .rectangle)
        subject.beginStroke(at: CGPoint(x: 100, y: 100))
        let committed = subject.endStroke(at: CGPoint(x: 100, y: 100))

        #expect(!committed)
        #expect(subject.annotations.isEmpty)
        #expect(subject.draft == nil)
    }

    @Test("手抖 2 点也不留（阈值 3 点）")
    func tinyStrokeLeavesNothing() {
        var subject = session()

        let committed = draw(&subject, .ellipse, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 100))

        #expect(!committed)
        #expect(subject.annotations.isEmpty)
    }

    @Test("刚好够 3 点就留下")
    func strokeAtThresholdIsKept() {
        var subject = session()

        let committed = draw(&subject, .rectangle, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 3, y: 3))

        #expect(committed)
        #expect(subject.annotations.count == 1)
    }

    @Test("没选工具时落笔是空操作（拖拽仍然属于『重画选区』）")
    func noToolNoStroke() {
        var subject = session()

        let began = subject.beginStroke(at: CGPoint(x: 0, y: 0))

        #expect(!began)
        #expect(subject.draft == nil)
        let ended = subject.endStroke(at: CGPoint(x: 40, y: 40))

        #expect(ended == false)
    }

    // MARK: - 撤销 / 重做

    @Test("撤销一步回到上一版，重做再往前一步")
    func undoRedo() {
        var subject = session()
        subject.toggle(tool: .rectangle)

        draw(&subject, .rectangle, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 20))
        draw(&subject, .rectangle, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60))
        #expect(subject.annotations.count == 2)

        let undone = subject.undo()

        #expect(undone)
        #expect(subject.annotations.count == 1)
        #expect(subject.canRedo)

        let redone = subject.redo()

        #expect(redone)
        #expect(subject.annotations.count == 2)
    }

    @Test("撤销空了就不再撤销（按钮该置灰）")
    func undoStopsAtEmpty() {
        var subject = session()

        #expect(!subject.canUndo)
        let undone = subject.undo()

        #expect(!undone)
        #expect(subject.annotations.isEmpty)
    }

    @Test("撤销之后画新的一笔，重做栈应当被清掉")
    func newStrokeClearsRedoStack() {
        var subject = session()
        subject.toggle(tool: .rectangle)

        draw(&subject, .rectangle, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 20))
        subject.undo()
        #expect(subject.canRedo)

        draw(&subject, .rectangle, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 80, y: 80))

        #expect(!subject.canRedo, "分叉之后旧的重做分支没有意义了")
        #expect(subject.annotations.count == 1)
    }

    @Test("撤销不进『正在画』的那一笔 —— 草稿不算数")
    func undoIgnoresDraft() {
        var subject = session()
        subject.toggle(tool: .pen)
        subject.beginStroke(at: CGPoint(x: 0, y: 0))
        subject.updateStroke(to: CGPoint(x: 50, y: 50))

        #expect(!subject.canUndo, "还没收笔，没什么可撤销的")
        #expect(subject.draft != nil)
    }

    // MARK: - 渲染

    @Test("草稿也参与渲染 —— 拖着的时候必须看得见框在跟着走")
    func draftIsVisible() {
        var subject = session()
        subject.toggle(tool: .rectangle)
        subject.beginStroke(at: CGPoint(x: 0, y: 0))
        subject.updateStroke(to: CGPoint(x: 30, y: 30))

        #expect(subject.visibleAnnotations.count == 1)
        #expect(subject.visibleAnnotations[0].id == subject.draft?.id)
    }

    @Test("标注的 zIndex 递增，后画的盖在上面")
    func zIndexIncreases() {
        var subject = session()
        subject.toggle(tool: .rectangle)

        draw(&subject, .rectangle, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 20))
        draw(&subject, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))

        #expect(subject.annotations[0].zIndex < subject.annotations[1].zIndex)
    }

    @Test("样式跟着会话走：改颜色后画的笔用新颜色，已画的不动")
    func styleAppliesToNewStrokesOnly() {
        var subject = session()
        subject.toggle(tool: .rectangle)

        draw(&subject, .rectangle, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 20))
        subject.style.stroke = AnnotationColor(red: 0, green: 0.5, blue: 1)
        draw(&subject, .rectangle, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60))

        #expect(subject.annotations[0].style.stroke == .red)
        #expect(subject.annotations[1].style.stroke == AnnotationColor(red: 0, green: 0.5, blue: 1))
    }

    // MARK: - 打码（ticket 22）

    @Test("马赛克与矩形同构：一笔拖出一个框")
    func mosaicIsRectLike() {
        var subject = session()

        draw(&subject, .mosaic, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))

        #expect(subject.annotations.count == 1)
        #expect(subject.annotations[0].kind == .mosaic)
        #expect(subject.annotations[0].frame == CGRect(x: 10, y: 10, width: 50, height: 30))
    }

    @Test("马赛克的反向拖拽同样成立（与矩形同一条路径）")
    func mosaicHandlesBackwardDrag() {
        var subject = session()

        draw(&subject, .mosaic, from: CGPoint(x: 60, y: 40), to: CGPoint(x: 10, y: 10))

        let frame = subject.annotations[0].frame.standardized
        #expect(frame == CGRect(x: 10, y: 10, width: 50, height: 30))
    }

    @Test("马赛克的一笔太短也一样丢弃")
    func mosaicTooSmallIsDiscarded() {
        var subject = session()

        let committed = draw(&subject, .mosaic, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 2, y: 2))
        #expect(!committed)
        #expect(subject.annotations.isEmpty)
    }

    // MARK: - 选择 / 移动 / 删除（"画完还能改"）

    /// 造一个已有若干标注的会话
    private func sessionWithShapes() -> OverlayAnnotationSession {
        var subject = session()
        subject.toggle(tool: .rectangle)
        subject.beginStroke(at: CGPoint(x: 10, y: 10))
        subject.endStroke(at: CGPoint(x: 50, y: 40))          // 第一个：10,10–50,40
        subject.beginStroke(at: CGPoint(x: 100, y: 100))
        subject.endStroke(at: CGPoint(x: 160, y: 150))        // 第二个：100,100–160,150
        subject.clearTool()
        return subject
    }

    @Test("点在一个标注上就选中它")
    func clickingSelects() {
        var subject = sessionWithShapes()
        subject.clearTool()

        let hit = subject.select(at: CGPoint(x: 30, y: 25))

        #expect(hit)
        #expect(subject.selectedAnnotations.count == 1)
    }

    @Test("点在空白处清空选择")
    func clickingEmptyClearsSelection() {
        var subject = sessionWithShapes()
        subject.clearTool()
        subject.select(at: CGPoint(x: 30, y: 25))
        #expect(!subject.selectedAnnotations.isEmpty)

        let hit = subject.select(at: CGPoint(x: 300, y: 300))
        #expect(!hit)
        #expect(subject.selectedAnnotations.isEmpty)
    }

    @Test("重叠时选**后画的**那个（它与显示顺序一致 —— 看到谁在上面就选中谁）")
    func laterShapeWinsWhenOverlapping() {
        var subject = session()
        subject.toggle(tool: .rectangle)
        subject.beginStroke(at: CGPoint(x: 0, y: 0))
        subject.endStroke(at: CGPoint(x: 100, y: 100))
        subject.beginStroke(at: CGPoint(x: 20, y: 20))
        subject.endStroke(at: CGPoint(x: 80, y: 80))     // 后画，盖在上面
        subject.clearTool()
        subject.clearTool()

        subject.select(at: CGPoint(x: 50, y: 50))

        #expect(subject.selectedAnnotations.first?.frame == CGRect(x: 20, y: 20, width: 60, height: 60))
    }

    @Test("拖动移动整框：位置跟着走、尺寸不变")
    func draggingMovesWithoutResizing() {
        var subject = sessionWithShapes()
        let original = subject.annotations[0].frame
        subject.clearTool()

        subject.beginMove(at: CGPoint(x: 30, y: 25))
        subject.updateMove(to: CGPoint(x: 60, y: 55))
        let moved = subject.endMove(at: CGPoint(x: 60, y: 55))

        #expect(moved)
        #expect(subject.annotations[0].frame == original.offsetBy(dx: 30, dy: 30))
        #expect(subject.annotations[0].frame.size == original.size)
    }

    @Test("没动过就不算一步改动 —— 点一下不该进撤销栈")
    func clickWithoutMovingIsNotUndoable() {
        var subject = sessionWithShapes()
        subject.clearTool()
        let before = subject.canUndo

        subject.beginMove(at: CGPoint(x: 30, y: 25))
        let moved = subject.endMove(at: CGPoint(x: 30, y: 25))

        #expect(!moved)
        #expect(subject.canUndo == before, "点一下不该产生一步可撤销的改动")
    }

    @Test("拖动之后撤销，回到按下前的位置")
    func undoingAMoveRestoresPosition() {
        var subject = sessionWithShapes()
        let original = subject.annotations[0].frame
        subject.clearTool()

        subject.beginMove(at: CGPoint(x: 30, y: 25))
        subject.endMove(at: CGPoint(x: 80, y: 75))
        #expect(subject.annotations[0].frame != original)

        subject.undo()

        #expect(subject.annotations[0].frame == original)
    }

    @Test("镜像：拖动用的基准是**按下那一刻**，不是上一帧")
    func moveUsesTheAnchorNotThePreviousFrame() {
        var subject = sessionWithShapes()
        let original = subject.annotations[0].frame
        subject.clearTool()

        subject.beginMove(at: CGPoint(x: 30, y: 25))
        subject.updateMove(to: CGPoint(x: 130, y: 125))
        subject.updateMove(to: CGPoint(x: 40, y: 35))        // 往回拖
        subject.endMove(at: CGPoint(x: 40, y: 35))

        // 用上一帧当基准的话，这里会得到 30+100-70 = 60 这种累积误差
        #expect(subject.annotations[0].frame == original.offsetBy(dx: 10, dy: 10))
    }

    @Test("Delete 删掉选中的那个")
    func deleteRemovesSelection() {
        var subject = sessionWithShapes()
        subject.clearTool()
        subject.select(at: CGPoint(x: 30, y: 25))

        let deleted = subject.deleteSelected()

        #expect(deleted)
        #expect(subject.annotations.count == 1)
        #expect(subject.selectedAnnotations.isEmpty)
    }

    @Test("没选中任何东西时 Delete 是空操作（不该把整张图清掉）")
    func deleteWithoutSelectionDoesNothing() {
        var subject = sessionWithShapes()

        let deleted = subject.deleteSelected()

        #expect(!deleted)
        #expect(subject.annotations.count == 2)
    }

    @Test("撤销把**刚画的那个**收走时，选中集合里不能留下幽灵 id")
    func undoingADrawLeavesNoGhostSelection() {
        // ⚠️ 这条与"删掉再撤销"不是同一件事：`deleteSelected` 自己会清空选中集合，
        // 所以那条路径**无论如何都不会有幽灵** —— 只有"撤销一步绘制"才会：
        // 撤销恢复的是**上一版数组**，而当前选中的那个在新版里根本不存在。
        // 残留的幽灵 id 的表现是"Delete 按下去什么都没发生"，且完全看不出原因。
        var subject = session()
        subject.toggle(tool: .rectangle)
        subject.beginStroke(at: CGPoint(x: 10, y: 10))
        subject.endStroke(at: CGPoint(x: 50, y: 40))
        subject.beginStroke(at: CGPoint(x: 100, y: 100))
        subject.endStroke(at: CGPoint(x: 160, y: 150))     // 后画的那个
        subject.clearTool()

        subject.clearTool()
        subject.select(at: CGPoint(x: 130, y: 125))        // 选中后画的那个
        #expect(subject.selectedAnnotations.count == 1)
        let ghost = subject.selection.first!

        subject.undo()                                     // 把它收回去

        #expect(subject.annotations.count == 1)
        // ⚠️ 断言的是**不变量本身**（选中集合只装存在的 id），不是某个可见症状：
        // 目前的几处 `guard` 恰好把幽灵的后果挡住了（`deleteSelected` 会因为
        // "一个都没删掉"而提前返回），所以**任何症状型断言都会是空跑**。
        // 留着它是因为后面任何一处"信任这个集合"的新代码都会踩到它。
        #expect(!subject.selection.contains(ghost))

        let deleted = subject.deleteSelected()
        #expect(!deleted)
        #expect(subject.annotations.count == 1)
    }

    @Test("删掉再撤销：标注回来，且选中集合是干净的")
    func undoingADeleteRestoresAndClearsSelection() {
        var subject = sessionWithShapes()
        subject.clearTool()
        subject.select(at: CGPoint(x: 30, y: 25))
        subject.deleteSelected()

        subject.undo()

        #expect(subject.annotations.count == 2)
        #expect(subject.selectedAnnotations.isEmpty)
    }

    @Test("切换工具会清掉选择 —— 否则旧的高亮会挂在画面上")
    func switchingToolClearsSelection() {
        var subject = sessionWithShapes()
        subject.clearTool()
        subject.select(at: CGPoint(x: 30, y: 25))
        #expect(!subject.selectedAnnotations.isEmpty)

        subject.toggle(tool: .pen)

        #expect(subject.selectedAnnotations.isEmpty)
    }

    @Test("`isDrawing` 与「没选工具」不是一回事 —— 没选工具时不画东西")
    func idleSessionIsNotDrawing() {
        var subject = session()
        subject.clearTool()

        #expect(subject.tool == nil)
        #expect(!subject.isDrawing, "把「没选工具」也算成画，用户点选时会画出新图形")
        #expect(subject.isSelecting, "没选工具＝改已有标注 / 改选区几何")

        subject.toggle(tool: .pen)
        #expect(subject.isDrawing)
        #expect(!subject.isSelecting)
    }

    @Test("没选工具时 beginStroke 是空操作")
    func idleSessionCannotDraw() {
        var subject = session()
        subject.clearTool()

        let began = subject.beginStroke(at: CGPoint(x: 10, y: 10))

        #expect(!began)
        #expect(subject.draft == nil)
    }

    @Test("`usesRedaction` 只在打码时为真 —— 控制层靠它决定要不要准备底图")
    func usesRedactionOnlyForBackdropTools() {
        var subject = session()
        #expect(!subject.usesRedaction, "没选工具时不需要底图")

        subject.toggle(tool: .rectangle)
        #expect(!subject.usesRedaction)

        subject.toggle(tool: .mosaic)
        #expect(subject.usesRedaction)

        // 换到**另一个**工具才算"离开打码" —— `toggle` 同一个工具是关掉它，
        // 那样第二条断言就永远测不到"从打码切走"这条路（曾经就是这么写错的）。
        subject.toggle(tool: .pen)
        #expect(!subject.usesRedaction)
    }

    // MARK: - 按下的归属（ticket 25 的回归）

    @Test("**没有画布**时，按下绝不能归「改已有标注」—— 否则拉不出新选区")
    func pressIsNeverForAnnotationEditingWithoutCanvas() {
        // ⚠️ 回归测试。上一版的判据只看 `isSelecting`（＝"没选任何工具"），
        // 而**没选工具正是默认状态** —— 于是每一次按下都被"改已有标注"接走：
        // `dragMode` 被占成"画一笔"，可草稿根本没开始。
        // 现象是**拖着鼠标，选区和标注什么也不出现** —— 与"功能没做"长得一模一样。
        var subject = session()
        subject.clearTool()

        #expect(subject.isSelecting, "前提：没选工具时确实处于「改已有标注」模式")
        #expect(!subject.takesPressForAnnotationEditing(local: nil),
                "没有画布时，按下的唯一含义是「拉一个新选区」")
    }

    @Test("按下归属：命中标注才归「改已有标注」，空白与「选了工具」都不归")
    func pressOwnership() {
        var subject = session()
        subject.clearTool()
        #expect(!subject.takesPressForAnnotationEditing(local: CGPoint(x: 10, y: 10)),
                "画布上还什么都没有")

        _ = draw(&subject, .rectangle, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
        subject.clearTool()

        #expect(subject.takesPressForAnnotationEditing(local: CGPoint(x: 50, y: 50)), "按在框里")
        #expect(!subject.takesPressForAnnotationEditing(local: CGPoint(x: 500, y: 500)), "按在空白")

        subject.toggle(tool: .rectangle)
        #expect(!subject.takesPressForAnnotationEditing(local: CGPoint(x: 50, y: 50)),
                "选了工具时，按在标注上是要**画**，不是要拖它")
    }

    // MARK: - 表情贴纸（ticket 24）

    @Test("表情落点：点一下就有一个，且产出的就是文字标注（复用现成路径）")
    func emojiStampsATextAnnotation() {
        var subject = session()
        subject.toggle(tool: .emoji)

        let placed = subject.stampEmoji("🎯", at: CGPoint(x: 40, y: 40))

        #expect(placed)
        #expect(subject.annotations.count == 1)
        #expect(subject.annotations.first?.kind == .text,
                "表情就是文字标注 —— 不该为它新开一条渲染分支")
        #expect(subject.annotations.first?.text == "🎯")
        #expect(subject.canUndo, "落一个也要能撤销")
    }

    @Test("空表情、或当前不是表情工具时，什么都不落")
    func emojiStampsNothingWhenItShouldNot() {
        var subject = session()
        subject.toggle(tool: .emoji)
        let emptyStamp = subject.stampEmoji("", at: CGPoint(x: 10, y: 10))
        #expect(!emptyStamp)

        subject.clearTool()
        let wrongToolStamp = subject.stampEmoji("🎯", at: CGPoint(x: 10, y: 10))
        #expect(!wrongToolStamp)
        // 在图上留一个看不见也删不掉的东西，比"点了没反应"更糟
        #expect(subject.annotations.isEmpty)
    }

    @Test("默认打码强度取三档的中间一个 —— 不能一进来是个数组外的值（那样没有一档高亮）")
    func defaultRedactionStrengthIsOneOfTheSlots() {
        let subject = OverlayAnnotationSession()
        #expect(subject.style.effectStrength == AnnotationPalette.overlayRedactionStrengths[1])
        #expect(subject.style.lineWidth == AnnotationPalette.overlayLineWidths[1])
    }

    // MARK: - 文字输入（ticket 22）

    /// 选好文字工具、在 `point` 落下一个待输入的文字
    private func typingSession(at point: CGPoint = CGPoint(x: 40, y: 60)) -> OverlayAnnotationSession {
        var subject = session()
        subject.toggle(tool: .text)
        subject.beginText(at: point)
        return subject
    }

    @Test("没选文字工具时落不下文字 —— 否则任何工具点到哪儿都会冒出一个空文字框")
    func beginTextNeedsTheTextTool() {
        var subject = session()
        subject.toggle(tool: .rectangle)

        let started = subject.beginText(at: CGPoint(x: 10, y: 10))

        #expect(started == nil)
        #expect(!subject.isEditingText)
    }

    @Test("刚落下的文字是「待输入」状态：还没进标注数组，但**已经看得见**")
    func pendingTextIsVisibleButNotCommitted() {
        let subject = typingSession()

        #expect(subject.isEditingText)
        #expect(subject.annotations.isEmpty, "还没提交，不该进数组（撤销栈也不该动）")
        #expect(!subject.isEmpty, "但它必须被画出来 —— 否则用户点完什么都看不见")
        #expect(subject.visibleAnnotations.count == 1)
        #expect(subject.visibleAnnotations.first?.kind == .text)
    }

    @Test("空内容的框也点得到 —— 宽度为 0 的框既看不见也点不中")
    func emptyTextStillHasAHitTarget() {
        let subject = typingSession()
        let frame = subject.visibleAnnotations[0].frame

        #expect(frame.width > 0)
        #expect(frame.height > 0)
    }

    @Test("输入内容时框跟着量出来 —— 导出与命中都按这个框算")
    func typingGrowsTheFrame() {
        var subject = typingSession()
        let before = subject.visibleAnnotations[0].frame

        subject.updateText("一段比较长的中文")

        let after = subject.visibleAnnotations[0].frame
        #expect(after.width > before.width)
        #expect(subject.visibleAnnotations[0].text == "一段比较长的中文")
        #expect(after.origin == before.origin, "文字是往右长的，锚点不动")
    }

    @Test("提交：内容进数组、可撤销、待输入状态清掉")
    func committingAddsAnUndoableAnnotation() {
        var subject = typingSession()

        let committed = subject.commitText("你好")

        #expect(committed)
        #expect(!subject.isEditingText)
        #expect(subject.annotations.count == 1)
        #expect(subject.annotations[0].text == "你好")
        #expect(subject.canUndo)

        subject.undo()
        #expect(subject.annotations.isEmpty)
    }

    @Test("空内容提交 = 什么都不留下（也不该在撤销栈里插一步空改动）")
    func committingEmptyTextLeavesNothing() {
        var subject = typingSession()
        let couldUndoBefore = subject.canUndo

        let committed = subject.commitText("")

        #expect(!committed)
        #expect(subject.annotations.isEmpty)
        #expect(!subject.isEditingText)
        #expect(subject.canUndo == couldUndoBefore, "空提交不该产生一步可撤销的改动")
    }

    @Test("取消输入：内容丢掉，撤销栈不受影响")
    func cancelTextDropsEverything() {
        var subject = typingSession()
        subject.updateText("打了一半")

        subject.cancelText()

        #expect(!subject.isEditingText)
        #expect(subject.annotations.isEmpty)
        #expect(subject.visibleAnnotations.isEmpty)
        #expect(!subject.canUndo)
    }

    @Test("没有待输入的文字时，提交 / 取消都是空操作（不该凭空造一个空文字）")
    func committingWithoutPendingTextIsANoOp() {
        var subject = session()

        let committed = subject.commitText("你好")

        #expect(!committed)
        #expect(subject.annotations.isEmpty)
    }

    @Test("换工具会收起待输入的文字 —— 否则它会挂在那儿，谁也提交不了")
    func switchingToolCancelsPendingText() {
        var subject = typingSession()

        subject.toggle(tool: .rectangle)

        #expect(!subject.isEditingText)
        #expect(subject.visibleAnnotations.isEmpty)
    }

    @Test("文字工具不能靠「拖一笔」落下 —— 那会得到一个宽度等于拖拽距离的空框")
    func textToolCannotBeDrawnAsAStroke() {
        var subject = session()
        subject.toggle(tool: .text)

        let began = subject.beginStroke(at: CGPoint(x: 10, y: 10))

        #expect(!began)
        #expect(subject.draft == nil)
    }

    @Test("尺寸档的含义跟着工具走（会话上的那一份）")
    func sizeMeaningFollowsTool() {
        var subject = session()
        #expect(subject.sizeMeaning == .lineWidth, "没选工具时按线宽算")

        subject.toggle(tool: .mosaic)
        #expect(subject.sizeMeaning == .redactionStrength)

        subject.toggle(tool: .text)
        #expect(subject.sizeMeaning == .fontSize)
    }

    @Test("默认字号必须落在字号档里 —— 否则一进文字工具就没有任何一档高亮")
    func defaultFontSizeLandsOnASlot() {
        let subject = OverlayAnnotationSession()
        #expect(AnnotationPalette.overlayFontSizes.contains(subject.style.fontSize))
    }

    // MARK: - 拖控制点缩放标注（ticket 22 收尾）

    /// 选中第一个矩形（10,10–50,40，标注坐标系 y 向下）
    private func selectedShapeSession() -> OverlayAnnotationSession {
        var subject = sessionWithShapes()
        subject.clearTool()
        subject.select(at: CGPoint(x: 30, y: 25))
        return subject
    }

    private func handleRects(_ subject: OverlayAnnotationSession)
        -> [SelectionGeometry.Handle: CGRect] {
        Dictionary(uniqueKeysWithValues: subject.selectedHandles.map { ($0.handle, $0.frame) })
    }

    private func mid(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    @Test("控制点按**标注的坐标系**摆（原点左上、y 向下）—— 拖「左上角」动的必须是视觉左上角")
    func handlePositionsUseTheAnnotationCoordinateSpace() {
        // ⚠️ 这条是整个缩放里最容易悄悄错的一处：`SelectionGeometry.Handle` 是按
        // **Cocoa 约定**命名的（`.top` = `maxY`，y 向上），而标注是 y 向下。
        // 直接把标注的框喂进去，用户拖"上边"动的会是**下边** ——
        // 不崩、不报错，只在拖到极限或锁比例时才显得怪。
        let subject = selectedShapeSession()
        let handles = handleRects(subject)

        let topLeft = mid(handles[.topLeft]!)
        let bottomRight = mid(handles[.bottomRight]!)
        #expect(topLeft == CGPoint(x: 10, y: 10), "视觉左上角就是原点那一角")
        #expect(bottomRight == CGPoint(x: 50, y: 40))
        #expect(mid(handles[.top]!) == CGPoint(x: 30, y: 10), "上边中点该在 y 小的那一侧")
        #expect(mid(handles[.left]!) == CGPoint(x: 10, y: 25))
    }

    @Test("没选中 / 选中多个时不摆控制点 —— 「缩哪一个」没有明确答案")
    func handlesRequireExactlyOneSelection() {
        var subject = sessionWithShapes()
        subject.clearTool()
        #expect(subject.selectedHandles.isEmpty, "没选中任何东西")

        subject.select(at: CGPoint(x: 30, y: 25))
        #expect(subject.selectedHandles.count == SelectionGeometry.Handle.allCases.count)
    }

    @Test("拖左上角：右下角**不动**，左上角跟着走")
    func draggingTopLeftKeepsTheOppositeCorner() {
        var subject = selectedShapeSession()

        subject.beginResize(at: CGPoint(x: 10, y: 10))
        subject.updateResize(to: CGPoint(x: 20, y: 22))
        let changed = subject.endResize(to: CGPoint(x: 20, y: 22))

        let frame = subject.annotations[0].frame
        #expect(changed)
        #expect(frame.minX == 20)
        #expect(frame.minY == 22)
        #expect(frame.maxX == 50, "对边（右）必须纹丝不动")
        #expect(frame.maxY == 40, "对边（下）必须纹丝不动")
    }

    @Test("拖上边中点：只有上边动，下边与左右都不动")
    func draggingTopEdgeMovesOnlyThatEdge() {
        var subject = selectedShapeSession()

        subject.beginResize(at: CGPoint(x: 30, y: 10))
        subject.endResize(to: CGPoint(x: 30, y: 15))

        let frame = subject.annotations[0].frame
        #expect(frame.minY == 15)
        #expect(frame.maxY == 40)
        #expect(frame.minX == 10)
        #expect(frame.maxX == 50)
    }

    @Test("拖过头缩到最小就**停住**，不翻转")
    func resizeStopsRatherThanFlipping() {
        var subject = selectedShapeSession()

        // 左上角一路拖到右下角外面去
        subject.beginResize(at: CGPoint(x: 10, y: 10))
        subject.endResize(to: CGPoint(x: 200, y: 200))

        let frame = subject.annotations[0].frame
        // 翻转的话，左上角会跑到 (200,200)、框整体跳到另一边 ——
        // 而用户以为自己只是拖到了极限。
        #expect(frame.width == SelectionGeometry.minimumSide)
        #expect(frame.height == SelectionGeometry.minimumSide)
        #expect(frame.maxX == 50)
        #expect(frame.maxY == 40)
    }

    @Test("拖动的基准是**按下那一刻那一版**，不是上一帧（否则误差累积）")
    func resizeUsesTheAnchorNotThePreviousFrame() {
        var subject = selectedShapeSession()

        subject.beginResize(at: CGPoint(x: 10, y: 10))
        subject.updateResize(to: CGPoint(x: 0, y: 0))
        subject.updateResize(to: CGPoint(x: 20, y: 20))       // 再拖回来一点
        subject.endResize(to: CGPoint(x: 20, y: 20))

        let frame = subject.annotations[0].frame
        // 按上一帧累加的话，这里会得到 50-10-... 之类的漂移值
        #expect(frame.minX == 20)
        #expect(frame.minY == 20)
        #expect(frame.maxX == 50)
        #expect(frame.maxY == 40)
    }

    @Test("`⇧` 锁宽高比：拖角时两个方向一起变")
    func shiftLocksTheAspectRatio() {
        var subject = selectedShapeSession()          // 40 × 30
        subject.isShiftDown = true

        subject.beginResize(at: CGPoint(x: 10, y: 10))
        subject.endResize(to: CGPoint(x: 10, y: 10 - 30))   // 只往上拖 30

        let frame = subject.annotations[0].frame
        let ratio = frame.width / frame.height
        #expect(abs(ratio - 40.0 / 30.0) < 0.01, "比例必须锁住，实际 \(ratio)")
        #expect(frame.maxX == 50)
        #expect(frame.maxY == 40)
    }

    @Test("缩放之后撤销，回到按下前的大小")
    func undoingAResizeRestoresTheSize() {
        var subject = selectedShapeSession()
        let original = subject.annotations[0].frame

        subject.beginResize(at: CGPoint(x: 10, y: 10))
        subject.endResize(to: CGPoint(x: 20, y: 20))
        #expect(subject.annotations[0].frame != original)

        subject.undo()

        #expect(subject.annotations[0].frame == original)
    }

    @Test("拖回原处不算一步改动（不该进撤销栈）")
    func resizingBackToTheOriginalIsNotUndoable() {
        var subject = selectedShapeSession()
        let original = subject.annotations[0].frame
        let couldUndoBefore = subject.canUndo

        subject.beginResize(at: CGPoint(x: 10, y: 10))
        subject.updateResize(to: CGPoint(x: 20, y: 20))
        let changed = subject.endResize(to: CGPoint(x: 10, y: 10))

        #expect(!changed)
        #expect(subject.annotations[0].frame == original)
        #expect(subject.canUndo == couldUndoBefore)
    }

    @Test("拖到一半按 `Esc`：退回按下时那一版")
    func cancellingAResizeRestoresTheAnchor() {
        var subject = selectedShapeSession()
        let original = subject.annotations[0].frame

        subject.beginResize(at: CGPoint(x: 10, y: 10))
        subject.updateResize(to: CGPoint(x: 30, y: 30))
        #expect(subject.annotations[0].frame != original)

        subject.cancelResize()

        #expect(subject.annotations[0].frame == original)
        #expect(!subject.isResizingAnnotations)
    }

    @Test("不在控制点上按下就**不开始缩放** —— 否则点哪儿都在改大小")
    func pressingOutsideHandlesDoesNotResize() {
        var subject = selectedShapeSession()

        let began = subject.beginResize(at: CGPoint(x: 30, y: 25))   // 框正中

        #expect(!began)
        #expect(!subject.isResizingAnnotations)
    }

    @Test("缩放箭头：路径跟着一起缩（只改框的话，线还留在原地）")
    func resizingAnArrowScalesItsPath() {
        var subject = session()
        subject.toggle(tool: .arrow)
        subject.beginStroke(at: CGPoint(x: 0, y: 0))
        subject.endStroke(at: CGPoint(x: 40, y: 40))
        subject.clearTool()
        subject.clearTool()
        subject.select(at: CGPoint(x: 20, y: 20))

        subject.beginResize(at: CGPoint(x: 40, y: 40))     // 右下角
        subject.endResize(to: CGPoint(x: 80, y: 80))

        let arrow = subject.annotations[0]
        #expect(arrow.path[1] == CGPoint(x: 80, y: 80), "终点必须跟着走")
        #expect(arrow.path[0] == CGPoint(x: 0, y: 0), "起点是对角，不动")
    }

    @Test("缩放文字：改的是字号（拖它就是在把字放大）")
    func resizingTextChangesItsFontSize() {
        var subject = session()
        subject.style.fontSize = 20
        subject.toggle(tool: .text)
        subject.beginText(at: CGPoint(x: 0, y: 0))
        subject.commitText("两倍")
        subject.clearTool()
        subject.clearTool()

        let before = subject.annotations[0]
        subject.select(at: CGPoint(x: before.frame.midX, y: before.frame.midY))
        // 把下边往下拖一倍
        subject.beginResize(at: CGPoint(x: before.frame.midX, y: before.frame.maxY))
        subject.endResize(to: CGPoint(x: before.frame.midX, y: before.frame.maxY * 2))

        #expect(subject.annotations[0].style.fontSize > before.style.fontSize,
                "字号没变大——拖文字就白拖了")
    }

    @Test("改字号之后输入的文字用新字号 —— 用户先在工具条上挑字号再落字")
    func fontSizeAppliesToTheNewText() {
        var subject = session()
        subject.style.fontSize = AnnotationPalette.overlayFontSizes[2]
        subject.toggle(tool: .text)
        subject.beginText(at: CGPoint(x: 0, y: 0))
        subject.updateText("大号字")
        subject.commitText("大号字")

        #expect(subject.annotations[0].style.fontSize == AnnotationPalette.overlayFontSizes[2])
        #expect(subject.annotations[0].frame.height > AnnotationText.lineHeight(
            fontSize: AnnotationPalette.overlayFontSizes[0]))
    }
}

/// 点 → 像素的换算（提交那一刻才做）。
@Suite("就地标注的坐标换算")
struct InlineAnnotationsTests {

    @Test("2 倍屏：位置与线宽一起放大 —— 只放大位置会让导出的线细成一半")
    func scalesEverything() {
        let annotation = Annotation(kind: .rectangle,
                                    frame: CGRect(x: 10, y: 20, width: 30, height: 40),
                                    style: AnnotationStyle(stroke: .red, lineWidth: 4, fontSize: 36, effectStrength: 12),
                                    zIndex: 0)
        let inline = InlineAnnotations(annotations: [annotation],
                                       pointSize: CGSize(width: 400, height: 300))

        let scaled = inline.scaled(toPixelSize: CGSize(width: 800, height: 600))

        #expect(scaled[0].frame == CGRect(x: 20, y: 40, width: 60, height: 80))
        #expect(scaled[0].style.lineWidth == 8)
        #expect(scaled[0].style.fontSize == 72)
        #expect(scaled[0].style.effectStrength == 24)
    }

    @Test("路径点跟着一起放大（箭头与画笔的线不能留在原地）")
    func scalesPath() {
        let annotation = Annotation(kind: .arrow,
                                    frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                    style: .default,
                                    zIndex: 0,
                                    path: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)])
        let inline = InlineAnnotations(annotations: [annotation],
                                       pointSize: CGSize(width: 100, height: 100))

        let scaled = inline.scaled(toPixelSize: CGSize(width: 300, height: 300))

        #expect(scaled[0].path == [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)])
    }

    @Test("倍率为 1 时原样返回（不产生浮点误差）")
    func identityWhenScaleIsOne() {
        let annotation = Annotation(kind: .rectangle,
                                    frame: CGRect(x: 10, y: 20, width: 30, height: 40),
                                    zIndex: 0)
        let inline = InlineAnnotations(annotations: [annotation],
                                       pointSize: CGSize(width: 100, height: 100))

        #expect(inline.scaled(toPixelSize: CGSize(width: 100, height: 100)) == [annotation])
    }

    @Test("点尺寸为 0 时不除零，原样返回")
    func survivesZeroPointSize() {
        let annotation = Annotation(kind: .rectangle, frame: CGRect(x: 1, y: 2, width: 3, height: 4), zIndex: 0)
        let inline = InlineAnnotations(annotations: [annotation], pointSize: .zero)

        #expect(inline.scaled(toPixelSize: CGSize(width: 100, height: 100)) == [annotation])
    }

    @Test("空标注就是空")
    func emptyIsEmpty() {
        #expect(InlineAnnotations(pointSize: CGSize(width: 10, height: 10)).isEmpty)
    }
}

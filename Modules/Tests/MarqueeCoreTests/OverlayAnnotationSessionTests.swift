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
        session.style = AnnotationStyle(stroke: .red, lineWidth: 4)
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

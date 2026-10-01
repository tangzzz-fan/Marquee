import CoreGraphics
import Testing
@testable import MarqueeCore

/// 「哪个位置该显示哪种光标」这条规则。
///
/// 它错了的样子**不崩不报错**：按钮上还是十字、能拖的地方看着不像能拖 ——
/// 只有人盯着屏幕才发现。所以规则本身要能被单测钉住。
@Suite("覆盖层光标")
struct OverlayCursorTests {

    // 一块 1024×768 的屏，选区和工具条都摆在上面。
    private let selection = CGRect(x: 300, y: 300, width: 400, height: 260)
    private let toolbar = CGRect(x: 300, y: 260, width: 545, height: 40)
    private let palette = CGRect(x: 300, y: 220, width: 200, height: 60)

    private func context(tool: OverlayTool? = nil,
                         settled: Bool = true,
                         scrollCapturing: Bool = false,
                         canvas: CGRect? = nil,
                         selectionHandles: Bool = false,
                         annotationFrames: [CGRect] = [],
                         annotationHandles: [OverlayCursorContext.HandleRegion] = [],
                         toolbar bar: CGRect? = nil,
                         palette panel: CGRect? = nil,
                         disabled: Set<OverlayToolbarSlot> = [],
                         drag: OverlayCursorContext.Drag = .none) -> OverlayCursorContext {
        var context = OverlayCursorContext()
        context.drag = drag
        context.isSettled = settled
        context.isScrollCapturing = scrollCapturing
        context.canvas = canvas ?? (settled ? selection : nil)
        context.tool = tool
        context.toolbar = bar
        context.palette = panel
        context.annotationFrames = annotationFrames
        context.annotationHandles = annotationHandles
        context.disabledSlots = disabled
        if selectionHandles {
            context.selectionHandles = SelectionGeometry.Handle.allCases.map {
                OverlayCursorContext.HandleRegion(handle: $0,
                                                  frame: SelectionGeometry.handleFrame($0, on: selection))
            }
        }
        return context
    }

    private func kind(_ point: CGPoint, _ context: OverlayCursorContext) -> OverlayCursorKind {
        OverlayCursor.kind(at: point, in: context)
    }

    // MARK: - 用户报的那条

    @Test("落点之后，选区内部不再是十字 —— 那里按住可以整体挪")
    func settledInteriorIsNotCrosshair() {
        let inside = CGPoint(x: selection.midX, y: selection.midY)
        #expect(kind(inside, context()) == .openHand,
                "整块选区都是十字，用户根本看不出「这里能拖」")
    }

    @Test("只有「还没落点」和「选区之外」才是十字")
    func crosshairOnlyWhereItMeansSomething() {
        let inside = CGPoint(x: selection.midX, y: selection.midY)
        let outside = CGPoint(x: 60, y: 700)

        #expect(kind(inside, context(settled: false)) == .crosshair, "还没落点：整屏都在拉选区")
        #expect(kind(outside, context(settled: false)) == .crosshair)
        #expect(kind(outside, context()) == .crosshair, "已落点：框外按下去会重画一个新选区")
    }

    @Test("工具条上是手型，不是十字 —— 这是最显眼的一处")
    func toolbarShowsPointingHand() {
        let onRectangle = OverlayToolbar.hitFrame(of: .tool(.rectangle), in: toolbar)!
        let onConfirm = OverlayToolbar.hitFrame(of: .confirm, in: toolbar)!
        #expect(kind(CGPoint(x: onRectangle.midX, y: onRectangle.midY), context(toolbar: toolbar)) == .pointingHand)
        #expect(kind(CGPoint(x: onConfirm.midX, y: onConfirm.midY), context(toolbar: toolbar)) == .pointingHand)
    }

    @Test("灰掉的撤销/重做不给手型 —— 那是在骗人")
    func disabledSlotsDoNotLookClickable() {
        let undo = OverlayToolbar.hitFrame(of: .undo, in: toolbar)!
        let point = CGPoint(x: undo.midX, y: undo.midY)

        #expect(kind(point, context(toolbar: toolbar, disabled: [.undo])) == .arrow)
        #expect(kind(point, context(toolbar: toolbar)) == .pointingHand, "能撤的时候是真能点")
    }

    @Test("弹层压在工具条外侧 —— 重叠的那几个点上必须是弹层说了算")
    func paletteBeatsToolbar() {
        // 故意让两者重叠（现实中贴得近时会有几个点重合）
        let overlapped = toolbar
        let point = CGPoint(x: overlapped.midX, y: overlapped.midY)
        #expect(kind(point, context(toolbar: toolbar, palette: overlapped)) == .pointingHand)
    }

    @Test("控制点上给方向箭头，且**角优先于边**（与命中测试同一顺序）")
    func handlesShowDirectionalResize() {
        #expect(kind(SelectionGeometry.Handle.topLeft.center(on: selection),
                     context(selectionHandles: true)) == .resize(.topLeft))
        #expect(kind(SelectionGeometry.Handle.right.center(on: selection),
                     context(selectionHandles: true)) == .resize(.right))
        // 没画控制点时，角内侧那一点点不该是缩放光标（选了工具就不画控制点）。
        // ⚠️ 取的是角**内侧 4 点**而不是角本身：角正好落在 `maxY` 那条边上，
        // 而 `CGRect.contains` 对 `maxY` 上的点返回假 —— 拿角当样本会得到"框外"的答案。
        #expect(kind(CGPoint(x: selection.minX + 4, y: selection.maxY - 4), context()) == .openHand)
    }

    @Test("选了工具：选区内是十字（画笔），选区外是箭头（按下去没反应）")
    func drawingToolSplitsInsideOutside() {
        let inside = CGPoint(x: selection.midX, y: selection.midY)
        let outside = CGPoint(x: 60, y: 700)
        let selected = context(tool: .rectangle)

        #expect(kind(inside, selected) == .crosshair)
        #expect(kind(outside, selected) == .arrow,
                "选区外落笔会被忽略，给十字等于说「这里能画」")
    }

    @Test("长截图抓帧期间鼠标没有语义 —— 一律箭头")
    func scrollCaptureIsInert() {
        let inside = CGPoint(x: selection.midX, y: selection.midY)
        #expect(kind(inside, context(scrollCapturing: true)) == .arrow)
    }

    @Test("正在输入文字：输入框上是 I 形，别处是箭头（那一下只会结束输入）")
    func textEditing() {
        let field = CGRect(x: 320, y: 320, width: 240, height: 26)
        var subject = context(tool: .text)
        subject.textField = field

        #expect(kind(CGPoint(x: field.midX, y: field.midY), subject) == .iBeam)
        #expect(kind(CGPoint(x: selection.midX, y: selection.maxY - 4), subject) == .arrow)
        // 工具条仍然能点（点了会先结算输入）—— 别被"输入中"整块盖掉
        let onConfirm = OverlayToolbar.hitFrame(of: .confirm, in: toolbar)!
        var withBar = subject
        withBar.toolbar = toolbar
        #expect(kind(CGPoint(x: onConfirm.midX, y: onConfirm.midY), withBar) == .pointingHand)
    }

    @Test("压在标注上是张开的手 —— 即使它被拖到了选区外面")
    func annotationFramesBeatSelection() {
        let stray = CGRect(x: 40, y: 600, width: 80, height: 60)
        let point = CGPoint(x: stray.midX, y: stray.midY)
        #expect(kind(point, context(annotationFrames: [stray])) == .openHand)
        #expect(kind(point, context()) == .crosshair)
    }

    @Test("标注自己的控制点优先于它自己的身体")
    func annotationHandlesBeatItsFrame() {
        let stray = CGRect(x: 40, y: 600, width: 80, height: 60)
        let corner = SelectionGeometry.Handle.bottomRight.center(on: stray)
        var subject = context(annotationFrames: [stray])
        subject.annotationHandles = [OverlayCursorContext.HandleRegion(handle: .bottomRight,
                                                                       frame: SelectionGeometry.handleFrame(.bottomRight, on: stray))]
        #expect(kind(corner, subject) == .resize(.bottomRight))
    }

    // MARK: - 拖拽期间

    @Test("拖拽期间光标只看「在拖什么」，不看位置 —— 否则拖到框外会跳回十字")
    func dragIgnoresPosition() {
        #expect(OverlayCursor.kind(for: .selection) == .crosshair)
        #expect(OverlayCursor.kind(for: .drawingAnnotation) == .crosshair)
        #expect(OverlayCursor.kind(for: .movingSelection) == .closedHand)
        #expect(OverlayCursor.kind(for: .movingAnnotation) == .closedHand)
        #expect(OverlayCursor.kind(for: .resizingSelection(.left)) == .resize(.left))
        #expect(OverlayCursor.kind(for: .resizingAnnotation(.topRight)) == .resize(.topRight))
        #expect(OverlayCursor.kind(for: .none) == nil, "没在拖就不该改变光标")
    }

    @Test("拖拽中的光标压过一切 —— 连工具条也不给手型")
    func dragBeatsEverything() {
        let onConfirm = OverlayToolbar.hitFrame(of: .confirm, in: toolbar)!
        let point = CGPoint(x: onConfirm.midX, y: onConfirm.midY)
        var subject = context(toolbar: toolbar, drag: .movingSelection)
        #expect(kind(point, subject) == .closedHand)

        subject.drag = .none
        #expect(kind(point, subject) == .pointingHand, "松手之后要回到手型")
    }

    // MARK: - 覆盖层刚出现

    @Test("空白上下文＝整屏十字（覆盖层刚唤起的默认状态）")
    func emptyContextIsCrosshair() {
        let everywhere = [CGPoint(x: 5, y: 5), CGPoint(x: 500, y: 400), CGPoint(x: 1010, y: 760)]
        for point in everywhere {
            #expect(kind(point, .empty) == .crosshair)
        }
    }
}

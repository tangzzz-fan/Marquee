import CoreGraphics
import Testing
@testable import MarqueeCore

@Suite("选区会话：拖拽与归一化")
struct SelectionSessionDragTests {

    @Test("四个拖拽方向都归一化成左上角 + 正宽高")
    func normalizesAllDirections() {
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)),
            (CGPoint(x: 110, y: 10), CGPoint(x: 10, y: 60)),
            (CGPoint(x: 10, y: 60), CGPoint(x: 110, y: 10)),
            (CGPoint(x: 110, y: 60), CGPoint(x: 10, y: 10)),
        ]
        for (anchor, current) in cases {
            var session = SelectionSession()
            session.beginDrag(at: anchor)
            session.updateDrag(to: current)
            let settled = session.endDrag(at: current)
            #expect(settled)
            #expect(session.rect == CGRect(x: 10, y: 10, width: 100, height: 50),
                    "从 \(anchor) 拖到 \(current) 应得到同一个矩形")
        }
    }

    @Test("拖拽过程中就能拿到实时矩形（用于实时读数）")
    func liveRectWhileDragging() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 0, y: 0))
        session.updateDrag(to: CGPoint(x: 40, y: 30))
        #expect(session.isDragging)
        #expect(session.rect == CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    @Test("零面积松手：不产生选区，回到等拖拽状态（误点一下不该交出 0×0 空图）")
    func zeroAreaDoesNotSettle() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 50, y: 50))
        let settled = session.endDrag(at: CGPoint(x: 50, y: 50))
        #expect(settled == false)
        #expect(session.rect == nil)
        #expect(session.isSettled == false)
        #expect(session.phase == .awaitingDrag)
    }

    @Test("小于 1 点的选区同样不成立")
    func subPointSelectionRejected() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 10, y: 10))
        let settled = session.endDrag(at: CGPoint(x: 10.5, y: 10.5))
        #expect(settled == false)
        #expect(session.rect == nil)
    }

    @Test("松手落点吸附到整点，让输出尺寸稳定")
    func endDragSnapsToWholePoints() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 10.2, y: 10.7))
        let settled = session.endDrag(at: CGPoint(x: 110.6, y: 60.4))
        #expect(settled)
        #expect(session.rect == CGRect(x: 10, y: 11, width: 101, height: 49))
    }

    @Test("cancel 之后没有选区，且不能再拖")
    func cancelClearsSelection() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 0, y: 0))
        session.updateDrag(to: CGPoint(x: 50, y: 50))
        session.cancel()

        #expect(session.isCancelled)
        #expect(session.rect == nil)

        session.beginDrag(at: CGPoint(x: 0, y: 0))
        #expect(session.isCancelled, "取消后不该复活")
        #expect(session.rect == nil)
    }
}

@Suite("选区会话：⇧ 锁定正方形")
struct SelectionSessionSquareTests {

    @Test("横向拖得更远时，按横向边长补成正方形")
    func squareUsesLargerHorizontalDelta() throws {
        var session = SelectionSession()
        session.setShiftDown(true)
        session.beginDrag(at: CGPoint(x: 100, y: 100))
        session.updateDrag(to: CGPoint(x: 300, y: 150))
        let rect = try #require(session.rect)
        #expect(rect.width == 200)
        #expect(rect.height == 200)
    }

    @Test("纵向拖得更远时，按纵向边长补成正方形")
    func squareUsesLargerVerticalDelta() {
        var session = SelectionSession()
        session.setShiftDown(true)
        session.beginDrag(at: CGPoint(x: 100, y: 100))
        session.updateDrag(to: CGPoint(x: 150, y: 300))
        #expect(session.rect?.width == 200)
        #expect(session.rect?.height == 200)
    }

    @Test("往左上拖也保持正方形，且方向不翻转")
    func squarePreservesDirection() {
        var session = SelectionSession()
        session.setShiftDown(true)
        session.beginDrag(at: CGPoint(x: 300, y: 300))
        session.updateDrag(to: CGPoint(x: 100, y: 250))

        let rect = session.rect
        #expect(rect?.width == 200)
        #expect(rect?.height == 200)
        // 往左上拖 → 左上角在 (100, 100)
        #expect(rect?.minX == 100)
        #expect(rect?.minY == 100)
    }

    @Test("拖拽中按/放 ⇧ 立即改变形状，不等下一次鼠标移动")
    func shiftTakesEffectImmediately() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 0, y: 0))
        session.updateDrag(to: CGPoint(x: 200, y: 50))
        #expect(session.rect?.height == 50)

        session.setShiftDown(true)
        #expect(session.rect?.height == 200, "按下 ⇧ 后应立刻变正方形")

        session.setShiftDown(false)
        #expect(session.rect?.height == 50)
    }
}

@Suite("选区会话：方向键精修")
struct SelectionSessionNudgeTests {

    @Test("已落点后可平移")
    func nudgesSettledSelection() {
        var session = SelectionSession()
        session.settle(rect: CGRect(x: 100, y: 100, width: 200, height: 100))
        let moved = session.nudge(dx: 1, dy: -1)
        #expect(moved)
        #expect(session.rect == CGRect(x: 101, y: 99, width: 200, height: 100))
    }

    @Test("精修**不**吸附到整点 —— 否则 2x 屏上的 ±1 像素步长（0.5 点）会被吃掉")
    func nudgeIsSubPointAware() {
        var session = SelectionSession()
        session.settle(rect: CGRect(x: 100, y: 100, width: 200, height: 100))
        let moved = session.nudge(dx: 0.5, dy: 0)
        #expect(moved)
        #expect(session.rect?.minX == 100.5)
        #expect(session.isRefined)
    }

    @Test("还没落点时方向键无效")
    func nudgeRequiresSettled() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 0, y: 0))
        session.updateDrag(to: CGPoint(x: 50, y: 50))
        let moved = session.nudge(dx: 1, dy: 0)
        #expect(moved == false)

        session.cancel()
        let movedAfterCancel = session.nudge(dx: 1, dy: 0)
        #expect(movedAfterCancel == false)
    }

    @Test("精修只改位置不改尺寸")
    func nudgeKeepsSize() {
        var session = SelectionSession()
        session.settle(rect: CGRect(x: 0, y: 0, width: 300, height: 200))
        for _ in 0..<10 { _ = session.nudge(dx: -10, dy: 10) }
        #expect(session.rect?.width == 300)
        #expect(session.rect?.height == 200)
    }
}

@Suite("选区会话：窗口落点与 ⏎ 意图")
struct SelectionSessionWindowSettleTests {

    private let window = WindowInfo(windowID: 7,
                                    frame: CGRect(x: 10, y: 20, width: 400, height: 300),
                                    layer: 0,
                                    ownerPID: 100,
                                    ownerName: "Safari",
                                    title: "Start",
                                    alpha: 1)
    private let cocoaRect = CGRect(x: 10, y: 500, width: 400, height: 300)

    @Test("锁定窗口后停住，不自动提交")
    func settleWindowLocksWithoutCommit() {
        var session = SelectionSession()
        session.settleWindow(window, cocoaRect: cocoaRect)
        #expect(session.isSettled)
        #expect(session.settledWindow == window)
        #expect(session.rect == cocoaRect)
        #expect(session.commitAction(hasHoveredWindow: true) == .commitWindow)
    }

    @Test("悬停窗口时第一次 ⏎ 是落点，不是整屏、也不是立刻截窗")
    func enterWhileHoveringSettles() {
        let session = SelectionSession()
        #expect(session.commitAction(hasHoveredWindow: true) == .settleHoveredWindow)
        #expect(session.commitAction(hasHoveredWindow: false) == .commitWholeScreen)
    }

    @Test("拖选区落点后 ⏎ 提交的是区域，不是窗口")
    func settledRegionCommitsRegion() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 0, y: 0))
        _ = session.endDrag(at: CGPoint(x: 80, y: 40))
        #expect(session.settledWindow == nil)
        #expect(session.commitAction(hasHoveredWindow: true) == .commitRegion)
    }

    @Test("窗口落点后再微调 → 变成普通选区")
    func nudgeDropsWindowTarget() {
        var session = SelectionSession()
        session.settleWindow(window, cocoaRect: cocoaRect)
        let moved = session.nudge(dx: 1, dy: 0)
        #expect(moved)
        #expect(session.settledWindow == nil)
        #expect(session.commitAction(hasHoveredWindow: false) == .commitRegion)
    }

    @Test("重新拖选区会丢掉已锁定的窗口")
    func beginDragClearsSettledWindow() {
        var session = SelectionSession()
        session.settleWindow(window, cocoaRect: cocoaRect)
        session.beginDrag(at: CGPoint(x: 0, y: 0))
        #expect(session.settledWindow == nil)
        #expect(session.isDragging)
    }
}

@Suite("选区会话：放大镜的可见相位")
struct SelectionSessionMagnifierVisibilityTests {

    @Test("悬停与拖拽中显示 —— 那时正在瞄准")
    func visibleWhileAiming() {
        var session = SelectionSession()
        #expect(session.showsMagnifier, "刚出现蒙层、还没动手时就要看得见（否则不知道有这东西）")

        session.beginDrag(at: CGPoint(x: 100, y: 100))
        session.updateDrag(to: CGPoint(x: 300, y: 200))
        #expect(session.showsMagnifier)
    }

    /// 这是本次修正的核心：**选区一确定，放大镜就收起**。
    /// 它是用来"对准"的，不是用来"看"的；留在屏幕上只会挡住刚框定的内容。
    /// 系统截图工具与微信截图都是这个行为，PRD F4 的原话也是「**选区时**显示」。
    @Test("落点之后收起 —— 区域与窗口都一样")
    func hiddenAfterSettling() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 100, y: 100))
        session.updateDrag(to: CGPoint(x: 300, y: 200))
        let settled = session.endDrag(at: CGPoint(x: 300, y: 200))
        #expect(settled)
        #expect(session.showsMagnifier == false, "区域落点后不该再显示放大镜")

        var locked = SelectionSession()
        locked.settleWindow(WindowInfo(windowID: 7,
                                       frame: CGRect(x: 10, y: 20, width: 400, height: 300),
                                       layer: 0,
                                       ownerPID: 100,
                                       ownerName: "Safari",
                                       title: "Start",
                                       alpha: 1),
                            cocoaRect: CGRect(x: 10, y: 500, width: 400, height: 300))
        #expect(locked.showsMagnifier == false, "锁定窗口后同理")

        var whole = SelectionSession()
        whole.settle(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(whole.showsMagnifier == false)
    }

    @Test("取消之后不显示（覆盖层正在拆掉）")
    func hiddenAfterCancel() {
        var session = SelectionSession()
        session.cancel()
        #expect(session.showsMagnifier == false)
    }

    @Test("方向键微调之后仍然不显示 —— 微调是在看尺寸读数，不是重新瞄准")
    func stillHiddenWhileNudging() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 100, y: 100))
        session.updateDrag(to: CGPoint(x: 300, y: 200))
        _ = session.endDrag(at: CGPoint(x: 300, y: 200))
        _ = session.nudge(dx: 1, dy: 0)
        #expect(session.showsMagnifier == false)
    }

    @Test("落点后重新拖（重新瞄准）→ 又显示")
    func visibleAgainOnReaim() {
        var session = SelectionSession()
        session.beginDrag(at: CGPoint(x: 100, y: 100))
        session.updateDrag(to: CGPoint(x: 300, y: 200))
        _ = session.endDrag(at: CGPoint(x: 300, y: 200))
        #expect(session.showsMagnifier == false)

        session.beginDrag(at: CGPoint(x: 50, y: 50))
        #expect(session.showsMagnifier)
    }
}

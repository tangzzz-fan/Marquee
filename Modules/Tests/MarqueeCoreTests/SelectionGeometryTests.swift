import CoreGraphics
import Foundation
import MarqueeCore
import Testing

/// 选区的几何编辑（ticket 19）。
///
/// 这些规则靠肉眼试不全：「对边固定」只在拖到极限时才看得出问题，
/// 「最小尺寸该停住而不是翻转」要故意拖过头才撞得到，吸附更是得拿标尺量。
@Suite("选区几何编辑")
struct SelectionGeometryTests {

    /// 一个 400×300 的框（Cocoa 坐标，y 向上）
    private let box = CGRect(x: 100, y: 100, width: 400, height: 300)

    // MARK: - 控制点命中

    @Test("八个控制点都在自己的中心上认得出")
    func everyHandleHitsAtItsCenter() {
        for handle in SelectionGeometry.Handle.allCases {
            let center = handle.center(on: box)
            #expect(SelectionGeometry.handle(at: center, in: box) == handle,
                    "\(handle) 在 \(center) 上没认出来")
        }
    }

    @Test("`top` 在 **maxY** 一侧 —— Cocoa 的 y 向上，写反了会让『拖上边』变成『拖下边』")
    func topIsMaxY() {
        #expect(SelectionGeometry.Handle.top.center(on: box).y == box.maxY)
        #expect(SelectionGeometry.Handle.bottom.center(on: box).y == box.minY)
        #expect(SelectionGeometry.Handle.left.center(on: box).x == box.minX)
    }

    @Test("离开控制点超过命中半径就不认（不能整条边都算）")
    func farFromHandleIsNil() {
        // ⚠️ 别拿「上边中点」当"边上一点" —— 那就是 top 控制点本身。
        // 取一个真在边上、但离角与边中点都够远的点。
        let onTopEdge = CGPoint(x: box.minX + 50, y: box.maxY)
        #expect(SelectionGeometry.handle(at: onTopEdge, in: box) == nil)

        // 框正中央当然也不是
        #expect(SelectionGeometry.handle(at: CGPoint(x: box.midX, y: box.midY), in: box) == nil)
    }

    @Test("框很小、角与边的命中区重叠时，**角优先**")
    func cornerWinsOverEdgeWhenOverlapping() {
        let small = CGRect(x: 0, y: 0, width: 20, height: 20)
        // x=5 同时落在 topLeft（[−6,6]）与 top（[4,16]）的命中区里
        let point = CGPoint(x: 5, y: 20)

        #expect(SelectionGeometry.handleFrame(.topLeft, on: small).contains(point))
        #expect(SelectionGeometry.handleFrame(.top, on: small).contains(point))
        #expect(SelectionGeometry.handle(at: point, in: small) == .topLeft)
    }

    @Test("命中区边长是半径的两倍（绘制与命中用同一个来源）")
    func handleFrameUsesRadius() {
        let frame = SelectionGeometry.handleFrame(.topLeft, on: box)
        #expect(frame.width == SelectionGeometry.handleHitRadius * 2)
        #expect(SelectionGeometry.handleVisualSide < SelectionGeometry.handleHitRadius * 2,
                "画出来的方块应当比命中区小，否则太抢眼")
    }

    // MARK: - 缩放：对边固定

    @Test("拖右下角：左上角**纹丝不动**")
    func resizingBottomRightKeepsTopLeft() {
        let result = SelectionGeometry.resized(box, handle: .bottomRight,
                                               to: CGPoint(x: 600, y: 80))

        #expect(result.minX == box.minX)
        #expect(result.maxY == box.maxY)
        #expect(result.maxX == 600)
        #expect(result.minY == 80)
    }

    @Test("拖上边：下边与左右都不动 —— 只有 maxY 变")
    func resizingTopOnlyMovesMaxY() {
        let result = SelectionGeometry.resized(box, handle: .top, to: CGPoint(x: 999, y: 500))

        #expect(result.minX == box.minX)
        #expect(result.maxX == box.maxX)
        #expect(result.minY == box.minY)
        #expect(result.maxY == 500)
    }

    @Test("拖左边：右边与上下都不动")
    func resizingLeftOnlyMovesMinX() {
        let result = SelectionGeometry.resized(box, handle: .left, to: CGPoint(x: 250, y: 0))

        #expect(result.minX == 250)
        #expect(result.maxX == box.maxX)
        #expect(result.minY == box.minY)
        #expect(result.maxY == box.maxY)
    }

    // MARK: - 缩放：最小尺寸

    @Test("拖过头（把右边拖到左边之外）时**停住不翻转**")
    func shrinkingPastMinimumStopsInsteadOfFlipping() {
        let result = SelectionGeometry.resized(box, handle: .right,
                                               to: CGPoint(x: box.minX - 200, y: box.midY))

        #expect(result.width == SelectionGeometry.minimumSide,
                "应当停在最小边长，而不是翻面变成 200 宽")
        #expect(result.minX == box.minX, "固定边不能被挪")
    }

    @Test("从左边拖过头同理，且固定的右边不动")
    func shrinkingFromLeftKeepsRightEdge() {
        let result = SelectionGeometry.resized(box, handle: .left,
                                               to: CGPoint(x: box.maxX + 300, y: box.midY))

        #expect(result.width == SelectionGeometry.minimumSide)
        #expect(result.maxX == box.maxX)
    }

    @Test("竖直方向也一样")
    func shrinkingVerticallyStops() {
        let collapsed = SelectionGeometry.resized(box, handle: .top,
                                                  to: CGPoint(x: box.midX, y: box.minY - 500))
        #expect(collapsed.height == SelectionGeometry.minimumSide)
        #expect(collapsed.minY == box.minY)
    }

    // MARK: - ⇧ 锁比例

    @Test("锁比例拖角：宽高比保持不变")
    func aspectLockKeepsRatio() {
        let result = SelectionGeometry.resized(box, handle: .bottomRight,
                                               to: CGPoint(x: 700, y: 120),
                                               aspect: box.width / box.height)

        let ratio = result.width / result.height
        #expect(abs(ratio - box.width / box.height) < 0.0001,
                "比例跑了：\(ratio)")
    }

    @Test("锁比例时取**位移较大的那一轴** —— 只看横向的话，往下拖得再多框也纹丝不动")
    func aspectLockFollowsTheDominantAxis() {
        let aspect = box.width / box.height   // 4:3

        // 主要往下拖（dy 远大于 dx）
        let vertical = SelectionGeometry.resized(box, handle: .bottomRight,
                                                 to: CGPoint(x: box.maxX + 5, y: box.minY - 150),
                                                 aspect: aspect)
        #expect(vertical.height > 150, "往下拖了 150 点，框应当跟着长高")

        // 主要往右拖。**固定的是左上角**，所以位移 200 点 → 宽度 400+200
        let horizontal = SelectionGeometry.resized(box, handle: .bottomRight,
                                                   to: CGPoint(x: box.maxX + 200, y: box.minY - 5),
                                                   aspect: aspect)
        #expect(abs(horizontal.width - (box.width + 200)) < 0.001)
    }

    @Test("锁比例时固定的是**对角**，不是左上角")
    func aspectLockAnchorsTheOppositeCorner() {
        let result = SelectionGeometry.resized(box, handle: .topLeft,
                                               to: CGPoint(x: 50, y: 500),
                                               aspect: box.width / box.height)

        #expect(abs(result.maxX - box.maxX) < 0.001, "右下角应当固定")
        #expect(abs(result.minY - box.minY) < 0.001)
    }

    @Test("锁比例 + 缩到极小：比例仍然守着")
    func aspectLockStillRespectsMinimum() {
        let aspect = box.width / box.height
        let result = SelectionGeometry.resized(box, handle: .bottomRight,
                                               to: CGPoint(x: box.minX, y: box.maxY),
                                               aspect: aspect)

        #expect(result.width >= SelectionGeometry.minimumSide - 0.001)
        #expect(abs(result.width / result.height - aspect) < 0.0001)
    }

    // MARK: - 吸附

    @Test("阈值内吸上，阈值外不吸")
    func snapsOnlyWithinThreshold() {
        let targets = SelectionGeometry.SnapTargets(verticalLines: [1000])
        // 让 **maxX** 落在吸附线附近（minX 离得很远，不会抢）
        let near = CGRect(x: 1000 - 200 + (SelectionGeometry.snapThreshold - 1), y: 0,
                          width: 200, height: 100)
        let far = CGRect(x: 1000 - 200 - (SelectionGeometry.snapThreshold + 1), y: 0,
                         width: 200, height: 100)

        let snappedNear = SelectionGeometry.snapped(near, edges: .all, targets: targets)
        let snappedFar = SelectionGeometry.snapped(far, edges: .all, targets: targets)

        #expect(snappedNear.rect.maxX == 1000)
        #expect(snappedNear.rect.width == near.width, "整框平移，尺寸不变（不是拉伸）")
        #expect(snappedNear.verticalLine == 1000)
        #expect(snappedFar.rect.maxX == far.maxX)
        #expect(snappedFar.verticalLine == nil)
    }

    @Test("移动整框时吸附是**平移**，尺寸一点不变")
    func movingSnapsByTranslation() {
        let targets = SelectionGeometry.SnapTargets(verticalLines: [1000])
        let rect = CGRect(x: 1000 - 3 - 200, y: 50, width: 200, height: 100)

        let result = SelectionGeometry.snapped(rect, edges: .all, targets: targets)

        #expect(result.rect.width == rect.width)
        #expect(result.rect.height == rect.height)
        #expect(result.rect.maxX == 1000)
    }

    @Test("拖控制点吸附时**只有那条边动**，固定边不能被吸走")
    func resizingSnapsOnlyTheMovingEdge() {
        let targets = SelectionGeometry.SnapTargets(verticalLines: [1000])
        let rect = CGRect(x: 500, y: 0, width: 497, height: 100)   // maxX = 997，离 1000 差 3

        let result = SelectionGeometry.snapped(rect,
                                               edges: SelectionGeometry.Handle.right.movingEdges,
                                               targets: targets)

        #expect(result.rect.maxX == 1000)
        #expect(result.rect.minX == 500, "固定边被吸走了")
    }

    @Test("在阈值外拖动时能离开吸附位 —— 吸附不能是『粘住不放』")
    func snappingIsNotSticky() {
        let targets = SelectionGeometry.SnapTargets(verticalLines: [1000])
        // 先吸上
        let onSnap = SelectionGeometry.snapped(CGRect(x: 798, y: 0, width: 200, height: 100),
                                              edges: .all, targets: targets)
        #expect(onSnap.rect.maxX == 1000)

        // 再往右拖 20 点（超过阈值）就该离开
        let moved = SelectionGeometry.snapped(CGRect(x: 818, y: 0, width: 200, height: 100),
                                              edges: .all, targets: targets)
        #expect(moved.verticalLine == nil)
        #expect(moved.rect.maxX == 1018)
    }

    @Test("两条边都吸得到时只取**最接近的一条** —— 各吸各的会把框拉变形")
    func onlyTheClosestLineWins() {
        // 竖线在 1000 与 1004；框跨在中间，两条边各差 2 点
        let targets = SelectionGeometry.SnapTargets(verticalLines: [1000, 1004])
        let rect = CGRect(x: 1002, y: 0, width: 2, height: 100)

        let result = SelectionGeometry.snapped(rect, edges: .all, targets: targets)

        #expect(result.rect.width == 2, "尺寸被拉变了：\(result.rect)")
    }

    @Test("从矩形收集吸附线时**只收边、不收中线**")
    func targetsUseEdgesOnly() {
        let targets = SelectionGeometry.SnapTargets.edges(of: [CGRect(x: 10, y: 20, width: 100, height: 40)])

        #expect(targets.verticalLines.sorted() == [10, 110])
        #expect(targets.horizontalLines.sorted() == [20, 60])
        #expect(!targets.verticalLines.contains(60), "中线不该进去 —— 那会在不该吸的地方吸住")
    }

    @Test("吸附线来自屏幕与窗口，两者都能吸")
    func targetsFromScreenAndWindows() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = CGRect(x: 300, y: 200, width: 600, height: 400)
        let targets = SelectionGeometry.SnapTargets.edges(of: [screen, window])

        // 拖到离窗口左边 3 点的地方
        let rect = CGRect(x: 303, y: 500, width: 100, height: 80)
        let result = SelectionGeometry.snapped(rect, edges: .all, targets: targets)

        #expect(result.rect.minX == 300)
    }

    // MARK: - 控制点的画法（白芯黑边）

    @Test("控制点的整体足迹是稿子给的 7 × 7 —— 白芯 5 + 两侧各 1 点黑边")
    func handleFootprintMatchesSpec() {
        // 稿子 §02 原话：「8 个控制点：四角 + 四边中点，**7 × 7 白芯黑边** ——
        // 压在浅底上不会『化掉』」。
        //
        // 这条钉的是**加法本身**：改了白芯大小而不动黑边，控制点之间就会开始互相咬
        // （相邻两个的黑色外圈叠在一起），而那种错看起来只是"控制点有点糊"。
        #expect(SelectionGeometry.handleVisualFootprint
                    == SelectionGeometry.handleVisualSide + SelectionGeometry.handleEdgeWidth * 2)
        #expect(SelectionGeometry.handleVisualFootprint == 7,
                "整体足迹是 7 点（白芯 5 + 黑边 1 × 2），改了要说一声")

        // 黑边必须细于白芯：反过来的话白芯只剩一条缝，控制点看起来是一坨黑方块。
        #expect(SelectionGeometry.handleEdgeWidth < SelectionGeometry.handleVisualSide)

        // 而**命中区仍然要大一圈** —— 画的小、摸的大，是这类控件的通行做法；
        // 拿足迹去当命中半径的话，用户会觉得"这个角特别难拖"。
        #expect(SelectionGeometry.handleHitRadius > SelectionGeometry.handleVisualFootprint / 2)
    }
}

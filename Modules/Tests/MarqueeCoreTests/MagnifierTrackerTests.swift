import CoreGraphics
import Foundation
import Testing
@testable import MarqueeCore

@Suite("放大镜跟随判定")
struct MagnifierTrackerTests {

    private let settings = MagnifierLayout.Settings.default
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("第一次登记必须重采，不能报 idle")
    func firstUpdateResamples() {
        var tracker = MagnifierTracker()
        let update = tracker.update(cursor: CGPoint(x: 400, y: 400),
                                    center: PixelCoordinate(x: 100, y: 100),
                                    displayID: 1,
                                    settings: settings,
                                    screenBounds: screen)
        guard case .resample(let box, let center) = update else {
            Issue.record("首帧应当是 resample，实际 \(update)")
            return
        }
        #expect(center == PixelCoordinate(x: 100, y: 100))
        #expect(box.size == settings.boxSize)
    }

    @Test("同一像素 + 同一光标 = idle")
    func identicalInputIsIdle() {
        var tracker = MagnifierTracker()
        _ = tracker.update(cursor: CGPoint(x: 400, y: 400),
                           center: PixelCoordinate(x: 100, y: 100),
                           displayID: 1, settings: settings, screenBounds: screen)
        let again = tracker.update(cursor: CGPoint(x: 400, y: 400),
                                   center: PixelCoordinate(x: 100, y: 100),
                                   displayID: 1, settings: settings, screenBounds: screen)
        #expect(again == .idle)
    }

    /// 这条就是「放大镜不跟随鼠标」那个缺陷的回归。
    ///
    /// 曾经的实现把"取样像素没变"直接当成了"什么都不用做"，于是光标动、像素没动时
    /// 整个更新被跳过 —— 盒子留在原地。判定必须区分开这两件事。
    @Test("取样像素没变但光标动了 → moved（盒子必须跟着走）")
    func cursorMoveWithSamePixelIsNotIdle() {
        var tracker = MagnifierTracker()
        let first = tracker.update(cursor: CGPoint(x: 400, y: 400),
                                   center: PixelCoordinate(x: 100, y: 100),
                                   displayID: 1, settings: settings, screenBounds: screen)
        guard case .resample(let firstBox, _) = first else {
            Issue.record("首帧应当是 resample")
            return
        }

        let moved = tracker.update(cursor: CGPoint(x: 460, y: 400),
                                   center: PixelCoordinate(x: 100, y: 100),
                                   displayID: 1, settings: settings, screenBounds: screen)
        guard case .moved(let box) = moved else {
            Issue.record("光标移动后应当是 moved，实际 \(moved) —— 这正是「原地不动」的形态")
            return
        }
        #expect(box != firstBox, "盒子没有跟着光标移动")
        // 复用小图的前提是"没重采"，所以 moved 里不该带新的取样像素
        #expect(box.origin == MagnifierLayout.origin(cursor: CGPoint(x: 460, y: 400),
                                                     settings: settings,
                                                     screenBounds: screen))
        #expect(tracker.lastSample == PixelCoordinate(x: 100, y: 100), "moved 不该改写取样点")
    }

    @Test("取样像素变了 → resample，并记住新取样点")
    func pixelChangeResamples() {
        var tracker = MagnifierTracker()
        _ = tracker.update(cursor: CGPoint(x: 400, y: 400),
                           center: PixelCoordinate(x: 100, y: 100),
                           displayID: 1, settings: settings, screenBounds: screen)

        let update = tracker.update(cursor: CGPoint(x: 401, y: 400),
                                    center: PixelCoordinate(x: 102, y: 100),
                                    displayID: 1, settings: settings, screenBounds: screen)
        guard case .resample(_, let center) = update else {
            Issue.record("取样像素变了应当 resample，实际 \(update)")
            return
        }
        #expect(center == PixelCoordinate(x: 102, y: 100))
        #expect(tracker.lastSample == PixelCoordinate(x: 102, y: 100))
    }

    @Test("换到另一块屏必须重采 —— 同一个像素坐标在两块屏上是两个地方")
    func displayChangeResamples() {
        var tracker = MagnifierTracker()
        _ = tracker.update(cursor: CGPoint(x: 400, y: 400),
                           center: PixelCoordinate(x: 100, y: 100),
                           displayID: 1, settings: settings, screenBounds: screen)

        // 坐标完全相同，只有屏不同：仍必须重采，否则会拿上一块屏的小图当这一屏的
        let update = tracker.update(cursor: CGPoint(x: 400, y: 400),
                                    center: PixelCoordinate(x: 100, y: 100),
                                    displayID: 2, settings: settings, screenBounds: screen)
        guard case .resample = update else {
            Issue.record("跨屏应当 resample，实际 \(update)")
            return
        }
    }

    @Test("reset 之后回到「首帧」状态")
    func resetForgetsEverything() {
        var tracker = MagnifierTracker()
        _ = tracker.update(cursor: CGPoint(x: 400, y: 400),
                           center: PixelCoordinate(x: 100, y: 100),
                           displayID: 1, settings: settings, screenBounds: screen)
        tracker.reset()

        #expect(tracker.lastSample == nil)
        #expect(tracker.lastBox == nil)
        #expect(tracker.lastDisplayID == nil)

        let update = tracker.update(cursor: CGPoint(x: 400, y: 400),
                                    center: PixelCoordinate(x: 100, y: 100),
                                    displayID: 1, settings: settings, screenBounds: screen)
        guard case .resample = update else {
            Issue.record("reset 后应当 resample，实际 \(update)")
            return
        }
    }

    @Test("贴边时 moved 的盒子仍然被夹在屏内")
    func movedBoxStaysOnScreen() {
        var tracker = MagnifierTracker()
        _ = tracker.update(cursor: CGPoint(x: 400, y: 400),
                           center: PixelCoordinate(x: 100, y: 100),
                           displayID: 1, settings: settings, screenBounds: screen)

        let update = tracker.update(cursor: CGPoint(x: 1438, y: 898),
                                    center: PixelCoordinate(x: 100, y: 100),
                                    displayID: 1, settings: settings, screenBounds: screen)
        guard case .moved(let box) = update else {
            Issue.record("应当是 moved，实际 \(update)")
            return
        }
        #expect(screen.contains(box))
    }

    @Test("连着两次相同登记：第一次 moved、第二次 idle（说明状态确实记住了）")
    func secondIdenticalMoveIsIdle() {
        var tracker = MagnifierTracker()
        _ = tracker.update(cursor: CGPoint(x: 400, y: 400),
                           center: PixelCoordinate(x: 100, y: 100),
                           displayID: 1, settings: settings, screenBounds: screen)

        let cursor = CGPoint(x: 460, y: 400)
        let center = PixelCoordinate(x: 100, y: 100)
        let first = tracker.update(cursor: cursor, center: center,
                                   displayID: 1, settings: settings, screenBounds: screen)
        guard case .moved = first else {
            Issue.record("第一次应当是 moved，实际 \(first)")
            return
        }
        let second = tracker.update(cursor: cursor, center: center,
                                    displayID: 1, settings: settings, screenBounds: screen)
        #expect(second == .idle)
    }
}

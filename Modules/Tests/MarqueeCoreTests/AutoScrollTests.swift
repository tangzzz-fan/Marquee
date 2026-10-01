import CoreGraphics
import Foundation
import MarqueeCore
import MarqueeTestSupport
import Testing

/// 自动滚动的**编排**（ticket 12）。
///
/// 这里断言的全是"什么时候滚、什么时候等、什么时候收工"，不碰真实系统：
/// 真正把事件送进别的应用、以及真实页面的吸顶与惯性，属于人工验收项（见 ticket 12 清单）。
///
/// 之所以值得测得这么细：自动滚动是一条**没有反馈回路**的链路 ——
/// 它自己发事件、自己抓帧、自己决定停。一旦节奏错了（滚太急拍到糊帧、
/// 或永远等不到"停稳"而死循环），用户在屏幕上只看到"卡住了"或"长图是糊的"，
/// 看不出是哪一步的问题。
///
/// 驱动约定：**一次 `step()` 只做一件事** —— 探测一拍、抓一帧、或发一次滚动，
/// 然后把新的阶段交出来。所以下面的用例是"一步一步推"着看的。
@MainActor
@Suite("自动滚动")
struct AutoScrollTests {

    // MARK: - 起步

    @Test("起步：先发一次向下的滚动，幅度按选区高度的比例算")
    func startsByEmittingScroll() async {
        let harness = makeHarness()
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])

        let status = await harness.driver.start()

        #expect(harness.emitter.emitted.count == 1)
        #expect(abs(harness.emitter.emitted[0] - 260) < 1e-9, "400 点高的选区 × 0.65")
        #expect(status.stage == .settling(step: 1, frames: 0))
    }

    @Test("起步前先把指针对准选区中心：滚轮事件是发给**指针下**的窗口的")
    func aimsPointerAtSelectionBeforeScrolling() async {
        let harness = makeHarness()
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])

        _ = await harness.driver.start()

        #expect(harness.emitter.targets == [CGPoint(x: 260, y: 300)])
    }

    @Test("没有辅助功能授权：一步都不发，把原因交回宿主")
    func refusesWithoutPostEventPermission() async {
        let harness = makeHarness(postEventPermission: .denied)
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])

        let status = await harness.driver.start()

        #expect(status.stage == .finished(.needsPermission))
        #expect(harness.emitter.emitted.isEmpty, "没授权就不该往别的应用注入任何事件")
        #expect(harness.emitter.targets.isEmpty, "连指针都不该动")
    }

    // MARK: - 等停稳

    @Test("刚发完滚动不立刻抓帧：惯性还没停，这时候拍到的帧是糊的")
    func waitsForSettleBeforeCapturing() async {
        // 前两拍画面还在动，之后才停
        let harness = makeHarness(shifts: [.shift(300), .shift(180), .shift(0), .shift(0)],
                                  policy: settlePolicy(minimumFramesBeforeSettle: 1, settledFrames: 2))
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        _ = await harness.driver.start()

        let moving = await harness.driver.step()
        #expect(moving.stage == .settling(step: 1, frames: 1), "还在滚就抓帧只会拍到运动模糊")

        let stillMoving = await harness.driver.step()
        #expect(stillMoving.stage == .settling(step: 1, frames: 2))

        let oneQuietFrame = await harness.driver.step()
        #expect(oneQuietFrame.stage == .settling(step: 1, frames: 3),
                "只安静一拍还不够 —— 惯性回弹时位移会短暂归零")

        let settled = await harness.driver.step()
        #expect(settled.stage == .capturing(step: 1), "连续两拍没动 → 可以拍正式帧了")
    }

    @Test("画面一直在动（页面在无限加载）：等待有上限，不会死等")
    func givesUpWaitingAfterMaximumFrames() async {
        // 每一拍都报很大的位移，永远"没停"
        let harness = makeHarness(shifts: Array(repeating: .shift(300), count: 40),
                                  policy: settlePolicy(minimumFramesBeforeSettle: 1,
                                                       settledFrames: 2,
                                                       maximumFramesPerStep: 3))
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        _ = await harness.driver.start()

        _ = await harness.driver.step()
        _ = await harness.driver.step()
        let status = await harness.driver.step()

        #expect(status.stage == .capturing(step: 1), "等满上限仍要拍一帧，否则整场空转")
    }

    // MARK: - 推进与收工

    @Test("抓到的帧带来新内容：接着发下一次滚动")
    func continuesAfterNewContent() async {
        let harness = makeHarness(shifts: [.shift(0), .shift(300)],
                                  policy: settlePolicy(minimumFramesBeforeSettle: 0, settledFrames: 1))
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        _ = await harness.driver.start()

        let ready = await harness.driver.step()
        #expect(ready.stage == .capturing(step: 1), "停稳了就该抓帧")

        let status = await harness.driver.step()
        #expect(status.stage == .settling(step: 2, frames: 0))
        #expect(harness.emitter.emitted.count == 2, "有新内容就继续滚")
        #expect(status.capture.canvasHeight == viewHeight + 300)
    }

    @Test("连续几步都没有新内容：判定到底，自动收工")
    func stopsWhenBottomReached() async {
        // 第一步拿到 300 行新内容，之后一直没动
        let harness = makeHarness(shifts: [.shift(0), .shift(300)],
                                  policy: settlePolicy(minimumFramesBeforeSettle: 0,
                                                       settledFrames: 1,
                                                       stationaryStepsBeforeBottom: 2))
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        _ = await harness.driver.start()

        var seen: [AutoScrollDriver.Stage] = []
        var status = await harness.driver.step()
        while !status.isFinished && seen.count < 12 {
            seen.append(status.stage)
            status = await harness.driver.step()
        }

        #expect(status.stage == .finished(.atBottom))
        #expect(seen.contains(.settling(step: 3, frames: 0)),
                "沉一拍还不够 —— 刚没动就判死会把「加载中的空档」误当到底")
        #expect(harness.emitter.emitted.count == 3, "判定到底之后不该再发事件")
    }

    @Test("步数熔断：页面滚不完也不能永远滚下去")
    func stopsAtStepLimit() async {
        let harness = makeHarness(shifts: Array(repeating: .shift(300), count: 20),
                                  policy: settlePolicy(minimumFramesBeforeSettle: 0,
                                                       settledFrames: 1,
                                                       maximumFramesPerStep: 1,
                                                       maximumSteps: 2))
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        _ = await harness.driver.start()

        var status = await harness.driver.step()
        var spins = 0
        while !status.isFinished && spins < 12 {
            status = await harness.driver.step()
            spins += 1
        }

        #expect(status.stage == .finished(.tooLong))
    }

    @Test("长图撞到高度上限：跟着收工，不继续滚")
    func stopsAtCanvasLimit() async {
        let harness = makeHarness(shifts: Array(repeating: .shift(300), count: 10),
                                  settings: .init(maximumCanvasHeight: viewHeight + 400),
                                  policy: settlePolicy(minimumFramesBeforeSettle: 0,
                                                       settledFrames: 1,
                                                       maximumFramesPerStep: 1))
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        _ = await harness.driver.start()

        var status = await harness.driver.step()
        var spins = 0
        while !status.isFinished && spins < 12 {
            status = await harness.driver.step()
            spins += 1
        }

        #expect(status.stage == .finished(.atLimit))
    }

    @Test("采不到画面：连续失败后收工，而不是一直空转等停稳")
    func stallsWhenProbingKeepsFailing() async {
        let harness = makeHarness(shifts: Array(repeating: .failure(.failed("装置失手")), count: 20),
                                  policy: settlePolicy(minimumFramesBeforeSettle: 0, settledFrames: 1))
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        _ = await harness.driver.start()

        var status = await harness.driver.step()
        var spins = 0
        while !status.isFinished && spins < 12 {
            status = await harness.driver.step()
            spins += 1
        }

        guard case .finished(.stalled) = status.stage else {
            Issue.record("期望 stalled 收工，实际 \(status.stage)")
            return
        }
    }

    @Test("收工之后继续拍：原样返回，不再发事件、不再抓帧")
    func staysFinishedOnceDone() async {
        let harness = makeHarness(postEventPermission: .denied)
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        _ = await harness.driver.start()

        let status = await harness.driver.step()

        #expect(status.stage == .finished(.needsPermission))
        #expect(harness.capturer.callCount == 1, "只有起步那一帧基线，之后再没抓过")
    }

    // MARK: - 装置

    private let region = CGRect(x: 100, y: 100, width: 320, height: 400)
    private var viewHeight: Int { 400 }

    /// 把"等停稳"压到一两拍，好让测试一眼看清状态迁移。
    private func settlePolicy(minimumFramesBeforeSettle: Int,
                              settledFrames: Int,
                              maximumFramesPerStep: Int = 6,
                              stationaryStepsBeforeBottom: Int = 2,
                              maximumSteps: Int = 10) -> AutoScrollPolicy {
        AutoScrollPolicy(stepFraction: 0.65,
                         minimumFramesBeforeSettle: minimumFramesBeforeSettle,
                         settledFrames: settledFrames,
                         maximumFramesPerStep: maximumFramesPerStep,
                         stationaryStepsBeforeBottom: stationaryStepsBeforeBottom,
                         maximumSteps: maximumSteps,
                         probeFailuresBeforeStall: 3)
    }

    private func makeHarness(permission: ScreenRecordingPermission = .granted,
                             postEventPermission: PostEventPermission = .granted,
                             shifts: [ScriptedStep] = [],
                             settings: ScrollCaptureSession.Settings = .init(),
                             policy: AutoScrollPolicy = .default) -> Harness {
        let page = SyntheticPage(width: 320, height: 4000)
        let capturer = ScrollingPageCapturer(page: page,
                                             viewHeight: viewHeight,
                                             offsets: stride(from: 0, to: 3000, by: 300).map { $0 })
        let registrar = ScriptedRegistrar(steps: shifts)
        let clipboard = FakeClipboard()
        let emitter = FakeScrollWheelEmitter()
        let session = ScrollCaptureSession(permission: FakePermissionProbe(status: permission),
                                           capturer: capturer,
                                           registrar: registrar,
                                           clipboard: clipboard,
                                           clock: FakeClock(),
                                           settings: settings)
        let driver = AutoScrollDriver(session: session,
                                      emitter: emitter,
                                      permission: FakePostEventPermission(status: postEventPermission),
                                      policy: policy)
        return Harness(session: session,
                       driver: driver,
                       capturer: capturer,
                       emitter: emitter,
                       clipboard: clipboard)
    }

    private struct Harness {
        let session: ScrollCaptureSession
        let driver: AutoScrollDriver
        let capturer: ScrollingPageCapturer
        let emitter: FakeScrollWheelEmitter
        let clipboard: FakeClipboard
    }
}

// MARK: - 替身

/// 记录"发了多远、把指针指向了哪里"的滚动事件替身。
final class FakeScrollWheelEmitter: ScrollWheelEmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPixels: [Double] = []
    private var storedTargets: [CGPoint] = []

    var emitted: [Double] { withLocked(lock) { storedPixels } }
    var targets: [CGPoint] { withLocked(lock) { storedTargets } }

    func begin(targeting point: CGPoint) async {
        withLocked(lock) { storedTargets.append(point) }
    }

    func emitScrollDown(points: Double) async {
        withLocked(lock) { storedPixels.append(points) }
    }
}

/// 可控的"事件发送"权限替身。真实 TCC 状态摆布不了，所以它必须能被注入。
final class FakePostEventPermission: PostEventPermissionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: PostEventPermission

    init(status: PostEventPermission) {
        storedStatus = status
    }

    func currentPostEventPermission() -> PostEventPermission {
        withLocked(lock) { storedStatus }
    }

    func requestPostEventPermission() -> Bool {
        withLocked(lock) {
            storedStatus = .granted
            return true
        }
    }
}

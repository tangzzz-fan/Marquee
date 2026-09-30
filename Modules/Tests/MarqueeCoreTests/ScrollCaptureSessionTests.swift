import CoreGraphics
import Foundation
import MarqueeCore
import MarqueeTestSupport
import Testing

/// 滚动截屏会话的状态迁移（ticket 11）。
///
/// 会话被设计成"被逐帧驱动"，正是为了能在没有屏幕、没有时钟的环境下断言这些迁移。
/// 覆盖层那层的窗口行为测不了，所以能测的部分必须测透。
@MainActor
@Suite("滚动截屏会话")
struct ScrollCaptureSessionTests {

    // MARK: - 起步

    @Test("权限没给：直接返回权限分支，不抓帧")
    func blockedWithoutPermission() async {
        let harness = makeHarness(permission: .denied)

        let result = await harness.session.begin(selection: region, displays: [TestDisplays.retina])

        #expect(result == .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false))
        #expect(harness.capturer.callCount == 0)
    }

    @Test("区域不落在任何屏上：明确失败，而不是默默取整屏")
    func failsWhenRegionMissesEveryDisplay() async {
        let harness = makeHarness()

        let result = await harness.session.begin(selection: CGRect(x: 9000, y: 9000, width: 200, height: 200),
                                                 displays: [TestDisplays.retina])

        guard case .failed(let failure) = result else {
            Issue.record("期望失败，实际 \(result)")
            return
        }
        #expect(failure.message.contains("太小") || failure.message.contains("显示器"))
    }

    @Test("起步就抓到基线帧，长图高度 = 一屏")
    func beginCapturesBaseline() async {
        let harness = makeHarness()

        let result = await harness.session.begin(selection: region, displays: [TestDisplays.retina])

        guard case .started(let progress) = result else {
            Issue.record("期望起步成功，实际 \(result)")
            return
        }
        #expect(progress.phase == .capturing)
        #expect(progress.frameCount == 1)
        #expect(progress.canvasHeight == viewHeight)
        #expect(harness.capturer.callCount == 1)
    }

    // MARK: - 逐帧

    @Test("正常滚动：每帧按位移追加，高度与累计位移一致")
    func appendsFrames() async {
        let harness = makeHarness(shifts: [.shift(300), .shift(300)])
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])

        let first = await harness.session.captureFrame()
        #expect(first.phase == .capturing)
        #expect(first.canvasHeight == viewHeight + 300)

        let second = await harness.session.captureFrame()
        #expect(second.phase == .capturing)
        #expect(second.canvasHeight == viewHeight + 600)
        #expect(second.frameCount == 3)
        #expect(second.accumulatedRows == 600)
    }

    @Test("连续几帧没动 = 滚到底：停止追加并提示，而不是一直等")
    func stopsAtBottom() async {
        let harness = makeHarness(shifts: [.shift(0), .shift(0.2), .shift(0)])
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        await harness.session.captureFrame()

        var progress = await harness.session.captureFrame()
        #expect(progress.phase == .capturing, "只静止一帧时还不该停下来")
        #expect(progress.warning != nil)

        progress = await harness.session.captureFrame()
        #expect(progress.phase == .atBottom)
        #expect(progress.warning?.contains("滚到底") == true)
        #expect(progress.frameCount == 1, "静止帧不该被追加")

        // 到底之后再调用，不应继续产生新状态
        let after = await harness.session.captureFrame()
        #expect(after.phase == .atBottom)
        #expect(after.frameCount == 1)
    }

    @Test("滚动幅度过大（与前帧几乎不重叠）：连续几次后停下来提示，但不丢已拼内容")
    func stallsOnNoOverlap() async {
        let policy = ScrollRegistrationPolicy()
        let maximum = Double(viewHeight - policy.minimumOverlapRows)
        let harness = makeHarness(shifts: [.shift(maximum + 20),
                                           .shift(maximum + 20),
                                           .shift(maximum + 20)])
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])

        var progress = await harness.session.captureFrame()
        #expect(progress.phase == .capturing, "偶尔一次失手不该直接判死")
        #expect(progress.warning?.contains("重叠") == true)

        _ = await harness.session.captureFrame()
        progress = await harness.session.captureFrame()

        guard case .stalled(let reason) = progress.phase else {
            Issue.record("期望 stalled，实际 \(progress.phase)")
            return
        }
        #expect(reason.contains("重叠"))
        #expect(progress.canvasHeight == viewHeight, "已拼的部分要留在长图里")
    }

    @Test("画面尺寸变了：立刻停止拼接 —— 继续拼会得到错位长图")
    func stallsWhenPixelSizeChanges() async {
        let harness = makeHarness(shifts: [.shift(300)])
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        harness.capturer.forceSize(CGSize(width: 400, height: 500))

        let progress = await harness.session.captureFrame()

        guard case .stalled(let reason) = progress.phase else {
            Issue.record("期望 stalled，实际 \(progress.phase)")
            return
        }
        #expect(reason.contains("尺寸"))
    }

    @Test("到达高度上限：停止追加并提示")
    func stopsAtHeightLimit() async {
        let harness = makeHarness(shifts: [.shift(300), .shift(300), .shift(300)],
                                  settings: .init(maximumCanvasHeight: viewHeight + 400))
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])

        _ = await harness.session.captureFrame()
        let progress = await harness.session.captureFrame()

        #expect(progress.phase == .atLimit)
        #expect(progress.warning?.contains("上限") == true)
        #expect(progress.frameCount == 2)
    }

    // MARK: - 收场

    @Test("结束：长图进剪贴板，尺寸等于累计出来的高度")
    func finishWritesLongImageToClipboard() async {
        let harness = makeHarness(shifts: [.shift(300), .shift(300)])
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        await harness.session.captureFrame()
        await harness.session.captureFrame()

        let outcome = await harness.session.finish()

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(metrics.pixelSize.height == CGFloat(viewHeight + 600))
        #expect(harness.clipboard.written.count == 1)
        #expect(harness.session.progress.phase == .finished)
        #expect(harness.session.progress.stitchMilliseconds != nil)
    }

    @Test("已经滚到底之后再结束：仍然交出可用的长图")
    func finishAfterBottomKeepsContent() async {
        let harness = makeHarness(shifts: [.shift(300), .shift(0), .shift(0), .shift(0)])
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        await harness.session.captureFrame()
        await harness.session.captureFrame()
        await harness.session.captureFrame()
        _ = await harness.session.captureFrame()
        #expect(harness.session.progress.phase == .atBottom)

        let outcome = await harness.session.finish()

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望仍然能交出长图，实际 \(outcome)")
            return
        }
        #expect(metrics.pixelSize.height == CGFloat(viewHeight + 300))
    }

    @Test("取消之后结束：明确失败，不产出半成品")
    func cancelledProducesNothing() async {
        let harness = makeHarness(shifts: [.shift(300)])
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        await harness.session.captureFrame()

        harness.session.cancel()
        let outcome = await harness.session.finish()

        guard case .failed(let failure) = outcome else {
            Issue.record("期望失败，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("取消"))
        #expect(harness.clipboard.written.isEmpty)
    }

    @Test("抓帧失败：先容忍，连续失败才停下 —— 一次抖动不该结束整次长截图")
    func toleratesSingleCaptureFailure() async {
        let harness = makeHarness(shifts: [.shift(300), .shift(300)])
        _ = await harness.session.begin(selection: region, displays: [TestDisplays.retina])
        harness.capturer.setFailure(StubCaptureError(message: "临时失败"))

        let first = await harness.session.captureFrame()
        #expect(first.phase == .capturing)
        #expect(first.warning?.contains("抓帧失败") == true)

        harness.capturer.setFailure(nil)
        let second = await harness.session.captureFrame()
        #expect(second.phase == .capturing)
        #expect(second.canvasHeight == viewHeight + 300)
    }

    // MARK: - 装置

    private let region = CGRect(x: 100, y: 100, width: 320, height: 400)
    private var viewHeight: Int { 400 }

    private func makeHarness(permission: ScreenRecordingPermission = .granted,
                             shifts: [ScriptedStep] = [],
                             settings: ScrollCaptureSession.Settings = .init()) -> Harness {
        let page = SyntheticPage(width: 320, height: 4000)
        let capturer = ScrollingPageCapturer(page: page,
                                            viewHeight: viewHeight,
                                            offsets: stride(from: 0, to: 3000, by: 300).map { $0 })
        let registrar = ScriptedRegistrar(steps: shifts)
        let clipboard = FakeClipboard()
        let session = ScrollCaptureSession(permission: FakePermissionProbe(status: permission),
                                          capturer: capturer,
                                          registrar: registrar,
                                          clipboard: clipboard,
                                          clock: FakeClock(),
                                          settings: settings)
        return Harness(session: session, capturer: capturer, registrar: registrar, clipboard: clipboard)
    }

    private struct Harness {
        let session: ScrollCaptureSession
        let capturer: ScrollingPageCapturer
        let registrar: ScriptedRegistrar
        let clipboard: FakeClipboard
    }
}

// MARK: - 替身

/// 配准脚本中的一步。
enum ScriptedStep: Sendable {
    case shift(Double, confidence: Double = 1)
    case failure(ScrollRegistrationFailure)
}

/// 按脚本返回位移的配准替身。脚本用尽后一律返回"没动"。
final class ScriptedRegistrar: ScrollFrameRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [ScriptedStep]
    private var index = 0

    init(steps: [ScriptedStep]) {
        self.steps = steps
    }

    var callCount: Int {
        withLocked(lock) { index }
    }

    func register(previous: CGImage, current: CGImage) async throws -> ScrollShift {
        // 加解锁必须收在同步闭包里：`NSLock.lock()` 在 async 上下文里被标为不可用
        let step = withLocked(lock) { () -> ScriptedStep? in
            let value: ScriptedStep? = index < steps.count ? steps[index] : nil
            index += 1
            return value
        }

        switch step {
        case .shift(let rows, let confidence):
            return ScrollShift(rows: rows, confidence: confidence)
        case .failure(let failure):
            throw failure
        case nil:
            return ScrollShift(rows: 0)
        }
    }
}

/// 采集替身这一次该做什么。抽成显式枚举是为了把"决定"与"取图"分开：
/// 状态读取必须在同步闭包里完成（锁），取图可以在闭包外做。
private enum ScrollingCaptureStep {
    case failure(StubCaptureError)
    case forcedSize(CGSize)
    case offset(Int)
}

/// 逐次返回合成长页不同位置的采集替身。
final class ScrollingPageCapturer: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let page: SyntheticPage
    private let viewHeight: Int
    private let offsets: [Int]
    private var calls = 0
    private var failure: StubCaptureError?
    private var forcedSize: CGSize?

    init(page: SyntheticPage, viewHeight: Int, offsets: [Int]) {
        self.page = page
        self.viewHeight = viewHeight
        self.offsets = offsets
    }

    var callCount: Int {
        withLocked(lock) { calls }
    }

    func setFailure(_ error: StubCaptureError?) {
        withLocked(lock) { failure = error }
    }

    func forceSize(_ size: CGSize?) {
        withLocked(lock) { forcedSize = size }
    }

    func captureRegion(_ rect: CGRect, on display: DisplayGeometry) async throws -> CapturedImage {
        let step = withLocked(lock) { () -> ScrollingCaptureStep in
            let index = calls
            calls += 1
            if let failure { return .failure(failure) }
            if let forcedSize { return .forcedSize(forcedSize) }
            return .offset(offsets[min(index, offsets.count - 1)])
        }

        switch step {
        case .failure(let error):
            throw error
        case .forcedSize(let size):
            let image = TestImage.solid(width: Int(size.width),
                                        height: Int(size.height),
                                        red: 0.5, green: 0.5, blue: 0.5)
            return CapturedImage(image: image, displayID: display.displayID, backingScale: 1)
        case .offset(let offset):
            guard let frame = page.frame(offsetY: offset, viewHeight: viewHeight) else {
                throw StubCaptureError(message: "合成页越界：offset \(offset)")
            }
            return CapturedImage(image: frame, displayID: display.displayID, backingScale: display.backingScale)
        }
    }

    func captureFullScreen(_ display: DisplayGeometry) async throws -> CapturedImage {
        throw StubCaptureError(message: "长截图不该走整屏采集")
    }

    func captureWindow(_ window: WindowInfo,
                       includeShadow: Bool,
                       backingScale: CGFloat) async throws -> CapturedImage {
        throw StubCaptureError(message: "长截图不该走窗口采集")
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MarqueeCore

// MARK: - 测试替身

/// 可控的权限探针。真实 TCC 状态无法在测试里摆布，这正是把它抽成协议的原因。
private final class FakePermissionProbe: ScreenRecordingPermissionProbing, @unchecked Sendable {
    var status: ScreenRecordingPermission
    var grantsOnRequest: Bool
    private(set) var requestCount = 0

    init(status: ScreenRecordingPermission, grantsOnRequest: Bool = false) {
        self.status = status
        self.grantsOnRequest = grantsOnRequest
    }

    func currentPermission() -> ScreenRecordingPermission { status }

    func requestPermission() -> Bool {
        requestCount += 1
        return grantsOnRequest
    }
}

/// 测试用的采集错误。
///
/// 刻意不用 `MarqueeCapture.CaptureError`：Core 的测试不该依赖实现模块
/// （`MarqueeCoreTests` 只依赖 `MarqueeCore`）。这条路径要验证的是
/// "采集抛错时流程怎么呈现"，用哪个错误类型不重要。
private struct StubCaptureError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 采集器替身：记录被调用次数，返回一张指定尺寸的图或抛错。
private actor FakeCapturer: ScreenCapturing {
    private let result: Result<CapturedImage, StubCaptureError>
    private(set) var fullScreenCallCount = 0

    init(result: Result<CapturedImage, StubCaptureError>) {
        self.result = result
    }

    func captureFullScreen(_ display: DisplayGeometry) async throws -> CapturedImage {
        fullScreenCallCount += 1
        return try result.get()
    }

    func captureRegion(_ rect: CGRect, on display: DisplayGeometry) async throws -> CapturedImage {
        throw StubCaptureError(message: "ticket 03 才实现")
    }

    func callCount() -> Int { fullScreenCallCount }
}

private final class FakeClipboard: ClipboardWriting, @unchecked Sendable {
    private(set) var written: [Data] = []
    func writePNG(_ data: Data) { written.append(data) }
}

private struct FakeDisplays: DisplayLocating {
    let display: DisplayGeometry?
    func displayUnderPointer() -> DisplayGeometry? { display }
}

/// 每次调用返回一个递增的假时间，让耗时断言可复现。
///
/// 步长取 0.125 秒（= 1/8，二进制可精确表示）而不是 0.02：
/// 0.02 不是精确的二进制小数，`(100.02 - 100.00) * 1000` 会得到 19.999999999996，
/// 断言相等就会假报失败。
private final class FakeClock: MonotonicClock, @unchecked Sendable {
    private var value: Double
    private let step: Double

    init(start: Double = 100, step: Double = 0.125) {
        self.value = start
        self.step = step
    }

    func now() -> Double {
        defer { value += step }
        return value
    }
}

// MARK: - 工具

private func makeImage(width: Int = 8, height: Int = 6) -> CGImage {
    let context = CGContext(data: nil,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

private let retinaDisplay = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                           backingScale: 2,
                                           displayID: 1)

@MainActor
private func makeFlow(permission: ScreenRecordingPermission,
                      grantsOnRequest: Bool = false,
                      captureResult: Result<CapturedImage, StubCaptureError>,
                      display: DisplayGeometry? = retinaDisplay)
    -> (flow: FullScreenCaptureFlow, probe: FakePermissionProbe, capturer: FakeCapturer, clipboard: FakeClipboard) {
    let probe = FakePermissionProbe(status: permission, grantsOnRequest: grantsOnRequest)
    let capturer = FakeCapturer(result: captureResult)
    let clipboard = FakeClipboard()
    let flow = FullScreenCaptureFlow(permission: probe,
                                     capturer: capturer,
                                     clipboard: clipboard,
                                     displays: FakeDisplays(display: display),
                                     clock: FakeClock())
    return (flow, probe, capturer, clipboard)
}

// MARK: - 用例

@Suite("全屏截图流程：权限门")
@MainActor
struct FullScreenCaptureFlowPermissionTests {

    @Test("未授权且从没问过 → 弹系统框；用户同意后继续采集并复制")
    func notDeterminedThenGranted() async {
        let image = makeImage()
        let harness = makeFlow(permission: .notDetermined,
                               grantsOnRequest: true,
                               captureResult: .success(CapturedImage(image: image,
                                                                     displayID: 1,
                                                                     backingScale: 2)))

        let outcome = await harness.flow.capture()

        #expect(harness.probe.requestCount == 1)
        #expect(await harness.capturer.callCount() == 1)
        #expect(harness.clipboard.written.count == 1)
        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(metrics.pixelSize == CGSize(width: 8, height: 6))
    }

    @Test("未授权且用户拒绝 → 引导去系统设置，且**不**尝试采集")
    func notDeterminedThenDenied() async {
        let harness = makeFlow(permission: .notDetermined,
                               grantsOnRequest: false,
                               captureResult: .success(CapturedImage(image: makeImage(),
                                                                     displayID: 1,
                                                                     backingScale: 2)))

        let outcome = await harness.flow.capture()

        #expect(outcome == .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false))
        #expect(await harness.capturer.callCount() == 0)
        #expect(harness.clipboard.written.isEmpty)
    }

    @Test("已被拒绝 → 连系统框都不弹，直接引导；不采集、不写剪贴板")
    func deniedNeverPromptsAndNeverCaptures() async {
        let harness = makeFlow(permission: .denied,
                               captureResult: .success(CapturedImage(image: makeImage(),
                                                                     displayID: 1,
                                                                     backingScale: 2)))

        let outcome = await harness.flow.capture()

        #expect(outcome == .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false))
        #expect(harness.probe.requestCount == 0, "被拒绝过的进程再请求也不会弹框，不该浪费这一次调用")
        #expect(await harness.capturer.callCount() == 0)
        #expect(harness.clipboard.written.isEmpty)
    }

    @Test("权限没过时不能静默：必须有明确结果，且剪贴板保持原样")
    func permissionFailureIsNeverSilent() async {
        for status in [ScreenRecordingPermission.denied, .notDetermined] {
            let harness = makeFlow(permission: status,
                                   grantsOnRequest: false,
                                   captureResult: .success(CapturedImage(image: makeImage(),
                                                                         displayID: 1,
                                                                         backingScale: 2)))
            let outcome = await harness.flow.capture()
            guard case .permissionBlocked = outcome else {
                Issue.record("状态 \(status) 下应返回 permissionBlocked，实际 \(outcome)")
                continue
            }
            #expect(harness.clipboard.written.isEmpty)
        }
    }
}

@Suite("全屏截图流程：采集与输出")
@MainActor
struct FullScreenCaptureFlowCaptureTests {

    @Test("已授权 → 一次采集、一次写剪贴板，写入的是原始 PNG 数据")
    func grantedWritesPNG() async throws {
        let image = makeImage(width: 12, height: 10)
        let harness = makeFlow(permission: .granted,
                               captureResult: .success(CapturedImage(image: image,
                                                                     displayID: 1,
                                                                     backingScale: 2)))

        let outcome = await harness.flow.capture()

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(await harness.capturer.callCount() == 1)

        // 写入的必须是 PNG（魔数校验），而不是 NSImage 往返出来的 TIFF
        let png = try #require(harness.clipboard.written.first)
        #expect(png.count == metrics.pngByteCount)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(metrics.pixelSize == CGSize(width: 12, height: 10))
    }

    @Test("耗时按注入时钟计算（性能预算 150 ms 的判定依据）")
    func elapsedUsesInjectedClock() async {
        let harness = makeFlow(permission: .granted,
                               captureResult: .success(CapturedImage(image: makeImage(),
                                                                     displayID: 1,
                                                                     backingScale: 2)))
        let outcome = await harness.flow.capture()

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        // 假时钟：开始读数 100.000，结束读数 100.125 → 125 ms
        #expect(metrics.elapsedMilliseconds == 125)
    }

    @Test("找不到鼠标所在显示器 → 明确失败，不采集")
    func missingDisplayFails() async {
        let harness = makeFlow(permission: .granted,
                               captureResult: .success(CapturedImage(image: makeImage(),
                                                                     displayID: 1,
                                                                     backingScale: 2)),
                               display: nil)

        let outcome = await harness.flow.capture()

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("显示器"))
        #expect(await harness.capturer.callCount() == 0)
    }

    @Test("刚授权就采集失败 → 提示重启应用（SPIKE A5：授权需重启进程生效）")
    func failedRightAfterGrantingSuggestsRestart() async {
        let harness = makeFlow(permission: .notDetermined,
                               grantsOnRequest: true,
                               captureResult: .failure(StubCaptureError(message: "屏幕采集失败")))

        let outcome = await harness.flow.capture()

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("重新打开"))
    }

    @Test("已授权后采集失败 → 报真实错误，不提「重启」")
    func failureWithExistingPermissionReportsRealError() async {
        let harness = makeFlow(permission: .granted,
                               captureResult: .failure(StubCaptureError(message: "ticket 03 才实现")))

        let outcome = await harness.flow.capture()

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("ticket 03"))
        #expect(!failure.message.contains("重新打开"))
    }
}

@Suite("图像编码")
struct ImageEncodingTests {

    @Test("CGImage → PNG 数据可解码回原尺寸（防止 Retina 退化）")
    func pngRoundTripKeepsPixelSize() throws {
        let image = makeImage(width: 200, height: 120)
        let data = try #require(ImageEncoding.pngData(from: image))

        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 200)
        #expect(decoded.height == 120)
    }
}

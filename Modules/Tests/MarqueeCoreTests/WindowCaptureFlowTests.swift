import CoreGraphics
import Foundation
import Testing
@testable import MarqueeCore

@MainActor
private func makeWindowHarness(permission: ScreenRecordingPermission = .granted,
                               grantsOnRequest: Bool = false,
                               failure: StubCaptureError? = nil)
    -> (flow: WindowCaptureFlow,
        probe: FakePermissionProbe,
        capturer: RecordingCapturer,
        clipboard: FakeClipboard) {
    let probe = FakePermissionProbe(status: permission, grantsOnRequest: grantsOnRequest)
    let capturer = RecordingCapturer(failure: failure)
    let clipboard = FakeClipboard()
    let flow = WindowCaptureFlow(permission: probe,
                                 capturer: capturer,
                                 clipboard: clipboard,
                                 clock: FakeClock())
    return (flow, probe, capturer, clipboard)
}

private let sampleWindow = WindowInfo(windowID: 42,
                                      frame: CGRect(x: 100, y: 80, width: 400, height: 300),
                                      layer: 0,
                                      ownerPID: 100,
                                      ownerName: "Notes",
                                      title: "Shopping",
                                      alpha: 1)

@Suite("窗口截图流程")
@MainActor
struct WindowCaptureFlowTests {

    @Test("单击 → 独立窗口，带系统阴影，不含挡住它的其他窗口")
    func clickCapturesIsolatedWindowWithShadow() async throws {
        let harness = makeWindowHarness()

        let outcome = await harness.flow.capture(window: sampleWindow,
                                                 style: .isolatedWindow(includeShadow: true),
                                                 displays: [TestDisplays.retina])

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(metrics.pixelSize == CGSize(width: 800, height: 600))

        let calls = await harness.capturer.windowCalls
        #expect(calls.count == 1)
        #expect(calls[0].windowID == 42)
        #expect(calls[0].includeShadow == true)
        #expect(calls[0].backingScale == 2)
        #expect(await harness.capturer.regionCalls.isEmpty, "点窗口不应走区域采集：那是拖选区的事")

        let png = try #require(harness.clipboard.written.first)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test("⌥ 单击 → 只截这一扇窗，不含挡住它的其他窗口")
    func optionClickIsolatesWindow() async {
        let harness = makeWindowHarness()

        let outcome = await harness.flow.capture(window: sampleWindow,
                                                 style: .isolatedWindow(includeShadow: false),
                                                 displays: [TestDisplays.retina])

        guard case .copiedToClipboard = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(await harness.capturer.regionCalls.isEmpty)
        let calls = await harness.capturer.windowCalls
        #expect(calls.count == 1)
        #expect(calls[0].windowID == 42)
        #expect(calls[0].includeShadow == false)
    }

    @Test("跨屏窗口：backing scale 取交集里最大的")
    func mixedDPIUsesMaxScale() async {
        let harness = makeWindowHarness()
        let spanning = WindowInfo(windowID: 7,
                                  frame: CGRect(x: 1300, y: 0, width: 300, height: 200),
                                  layer: 0,
                                  ownerPID: 1,
                                  ownerName: "App",
                                  title: nil,
                                  alpha: 1)

        _ = await harness.flow.capture(window: spanning,
                                       style: .isolatedWindow(includeShadow: true),
                                       displays: [TestDisplays.retina, TestDisplays.plainRight])

        let calls = await harness.capturer.windowCalls
        #expect(calls.first?.backingScale == 2)
    }

    @Test("未授权 → 不采集、不写剪贴板")
    func permissionBlocked() async {
        let harness = makeWindowHarness(permission: .denied)

        let outcome = await harness.flow.capture(window: sampleWindow,
                                                 style: .isolatedWindow(includeShadow: true),
                                                 displays: [TestDisplays.retina])

        #expect(outcome == .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false))
        #expect(await harness.capturer.regionCalls.isEmpty)
        #expect(await harness.capturer.windowCalls.isEmpty)
        #expect(harness.clipboard.written.isEmpty)
    }

    @Test("刚授权就失败 → 提示重启")
    func failureRightAfterGrantingSuggestsRestart() async {
        let harness = makeWindowHarness(permission: .notDetermined,
                                        grantsOnRequest: true,
                                        failure: StubCaptureError(message: "窗口已关闭"))

        let outcome = await harness.flow.capture(window: sampleWindow,
                                                 style: .isolatedWindow(includeShadow: false),
                                                 displays: [TestDisplays.retina])

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("重新打开"))
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MarqueeCore

// MARK: - 装置自检 / 拼接

@Suite("图像拼接：装置自检")
struct ImageCompositingTests {

    @Test("单切片铺满 → 直接复用原图，不重绘（最常见的单屏路径不该付质量代价）")
    func singleFullSliceReusesImage() throws {
        let image = TestImage.solid(width: 8, height: 8, red: 0.5, green: 0.5, blue: 0.5)
        let composed = try #require(ImageCompositing.compose(
            outputSize: CGSize(width: 8, height: 8),
            slices: [ImageSlice(image: image, target: CGRect(x: 0, y: 0, width: 8, height: 8))]
        ))
        #expect(composed === image)
    }

    @Test("横向拼接：左右位置正确，且**上下方向不翻转**")
    func horizontalComposeKeepsOrientation() throws {
        let left = TestImage.fourQuadrants()
        let right = TestImage.solid(width: 2, height: 2, red: 0, green: 1, blue: 1) // 青

        let composed = try #require(ImageCompositing.compose(
            outputSize: CGSize(width: 4, height: 2),
            slices: [
                ImageSlice(image: left, target: CGRect(x: 0, y: 0, width: 2, height: 2)),
                ImageSlice(image: right, target: CGRect(x: 2, y: 0, width: 2, height: 2)),
            ]
        ))

        #expect(composed.width == 4)
        #expect(composed.height == 2)

        // 左上仍是红、左下仍是蓝 —— 如果 CGContext 的 y 忘了翻，这两条会互换
        #expect(TestImage.matches(TestImage.pixel(composed, x: 0, y: 0), red: 1, green: 0, blue: 0))
        #expect(TestImage.matches(TestImage.pixel(composed, x: 0, y: 1), red: 0, green: 0, blue: 1))
        #expect(TestImage.matches(TestImage.pixel(composed, x: 1, y: 0), red: 0, green: 1, blue: 0))
        #expect(TestImage.matches(TestImage.pixel(composed, x: 3, y: 1), red: 0, green: 1, blue: 1))
    }

    @Test("纵向拼接：上片在上、下片在下（落位翻错就在这里露馅）")
    func verticalComposeRespectsTopDownOrder() throws {
        let top = TestImage.solid(width: 2, height: 2, red: 1, green: 0, blue: 0)
        let bottom = TestImage.solid(width: 2, height: 2, red: 0, green: 0, blue: 1)

        let composed = try #require(ImageCompositing.compose(
            outputSize: CGSize(width: 2, height: 4),
            slices: [
                ImageSlice(image: top, target: CGRect(x: 0, y: 0, width: 2, height: 2)),
                ImageSlice(image: bottom, target: CGRect(x: 0, y: 2, width: 2, height: 2)),
            ]
        ))

        #expect(TestImage.matches(TestImage.pixel(composed, x: 0, y: 0), red: 1, green: 0, blue: 0))
        #expect(TestImage.matches(TestImage.pixel(composed, x: 1, y: 1), red: 1, green: 0, blue: 0))
        #expect(TestImage.matches(TestImage.pixel(composed, x: 0, y: 2), red: 0, green: 0, blue: 1))
        #expect(TestImage.matches(TestImage.pixel(composed, x: 1, y: 3), red: 0, green: 0, blue: 1))
    }

    @Test("没有切片 / 尺寸非法 → nil，而不是给一张空图")
    func invalidInputsReturnNil() {
        #expect(ImageCompositing.compose(outputSize: CGSize(width: 10, height: 10), slices: []) == nil)
        #expect(ImageCompositing.compose(outputSize: .zero,
                                         slices: [ImageSlice(image: TestImage.fourQuadrants(),
                                                             target: .zero)]) == nil)
    }
}

// MARK: - 全屏流程

@MainActor
private func makeFullScreenHarness(permission: ScreenRecordingPermission,
                                   grantsOnRequest: Bool = false,
                                   failure: StubCaptureError? = nil,
                                   displays: [DisplayGeometry] = [TestDisplays.retina])
    -> (flow: FullScreenCaptureFlow,
        probe: FakePermissionProbe,
        capturer: RecordingCapturer,
        clipboard: FakeClipboard) {
    let probe = FakePermissionProbe(status: permission, grantsOnRequest: grantsOnRequest)
    let capturer = RecordingCapturer(failure: failure)
    let clipboard = FakeClipboard()
    let flow = FullScreenCaptureFlow(permission: probe,
                                     capturer: capturer,
                                     clipboard: clipboard,
                                     displays: FakeDisplays(all: displays),
                                     clock: FakeClock())
    return (flow, probe, capturer, clipboard)
}

@Suite("全屏截图流程：权限门")
@MainActor
struct FullScreenCaptureFlowPermissionTests {

    @Test("未授权且从没问过 → 弹系统框；用户同意后继续采集并复制")
    func notDeterminedThenGranted() async {
        let harness = makeFullScreenHarness(permission: .notDetermined, grantsOnRequest: true)

        let outcome = await harness.flow.capture()

        #expect(harness.probe.requestCount == 1)
        #expect(await harness.capturer.fullScreenCalls.count == 1)
        #expect(harness.clipboard.written.count == 1)
        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(metrics.pixelSize == TestDisplays.retina.pixelSize)
    }

    @Test("未授权且用户拒绝 → 引导去系统设置，且**不**尝试采集")
    func notDeterminedThenDenied() async {
        let harness = makeFullScreenHarness(permission: .notDetermined, grantsOnRequest: false)

        let outcome = await harness.flow.capture()

        #expect(outcome == .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false))
        #expect(await harness.capturer.fullScreenCalls.isEmpty)
        #expect(harness.clipboard.written.isEmpty)
    }

    @Test("已被拒绝 → 连系统框都不弹，直接引导；不采集、不写剪贴板")
    func deniedNeverPromptsAndNeverCaptures() async {
        let harness = makeFullScreenHarness(permission: .denied)

        let outcome = await harness.flow.capture()

        #expect(outcome == .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false))
        #expect(harness.probe.requestCount == 0, "被拒绝过的进程再请求也不会弹框，不该浪费这一次调用")
        #expect(await harness.capturer.fullScreenCalls.isEmpty)
        #expect(harness.clipboard.written.isEmpty)
    }

    @Test("权限没过时不能静默：必须有明确结果，且剪贴板保持原样")
    func permissionFailureIsNeverSilent() async {
        for status in [ScreenRecordingPermission.denied, .notDetermined] {
            let harness = makeFullScreenHarness(permission: status, grantsOnRequest: false)
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
        let harness = makeFullScreenHarness(permission: .granted)

        let outcome = await harness.flow.capture()

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(await harness.capturer.fullScreenCalls.count == 1)

        // 写入的必须是 PNG（魔数校验），而不是 NSImage 往返出来的 TIFF
        let png = try #require(harness.clipboard.written.first)
        #expect(png.count == metrics.pngByteCount)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        // Retina 下必须是物理像素，不是点数
        #expect(metrics.pixelSize == CGSize(width: 2880, height: 1800))
    }

    @Test("耗时按注入时钟计算（性能预算 150 ms 的判定依据）")
    func elapsedUsesInjectedClock() async {
        let harness = makeFullScreenHarness(permission: .granted)
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
        let harness = makeFullScreenHarness(permission: .granted, displays: [])

        let outcome = await harness.flow.capture()

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("显示器"))
        #expect(await harness.capturer.fullScreenCalls.isEmpty)
    }

    @Test("刚授权就采集失败 → 提示重启应用（SPIKE A5：授权需重启进程生效）")
    func failedRightAfterGrantingSuggestsRestart() async {
        let harness = makeFullScreenHarness(permission: .notDetermined,
                                            grantsOnRequest: true,
                                            failure: StubCaptureError(message: "屏幕采集失败"))

        let outcome = await harness.flow.capture()

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("重新打开"))
    }

    @Test("已授权后采集失败 → 报真实错误，不提「重启」")
    func failureWithExistingPermissionReportsRealError() async {
        let harness = makeFullScreenHarness(permission: .granted,
                                            failure: StubCaptureError(message: "显示器被拔了"))

        let outcome = await harness.flow.capture()

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("显示器被拔了"))
        #expect(!failure.message.contains("重新打开"))
    }
}

// MARK: - 区域流程

@MainActor
private func makeRegionHarness(permission: ScreenRecordingPermission = .granted,
                               grantsOnRequest: Bool = false,
                               failure: StubCaptureError? = nil)
    -> (flow: RegionCaptureFlow,
        probe: FakePermissionProbe,
        capturer: RecordingCapturer,
        clipboard: FakeClipboard) {
    let probe = FakePermissionProbe(status: permission, grantsOnRequest: grantsOnRequest)
    let capturer = RecordingCapturer(failure: failure)
    let clipboard = FakeClipboard()
    let flow = RegionCaptureFlow(permission: probe,
                                 capturer: capturer,
                                 clipboard: clipboard,
                                 clock: FakeClock())
    return (flow, probe, capturer, clipboard)
}

@Suite("区域截图流程")
@MainActor
struct RegionCaptureFlowTests {

    @Test("单屏选区：只调一次采集，输出像素 = 点 × scale")
    func singleDisplaySelection() async throws {
        let harness = makeRegionHarness()
        let selection = CGRect(x: 100, y: 200, width: 300, height: 150)

        let outcome = await harness.flow.capture(selection: selection, displays: [TestDisplays.retina])

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(metrics.pixelSize == CGSize(width: 600, height: 300))

        let calls = await harness.capturer.regionCalls
        #expect(calls.count == 1)
        #expect(calls[0].rect == selection)
        #expect(calls[0].displayID == TestDisplays.retina.displayID)

        let png = try #require(harness.clipboard.written.first)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test("跨屏选区：逐屏取片，输出尺寸取参与屏里最大的 scale")
    func crossDisplaySelection() async {
        let harness = makeRegionHarness()
        let displays = [TestDisplays.retina, TestDisplays.plainRight]
        // 从 2x 主屏拖到 1x 右屏
        let selection = CGRect(x: 1300, y: 200, width: 340, height: 300)

        let outcome = await harness.flow.capture(selection: selection, displays: displays)

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(metrics.pixelSize == CGSize(width: 680, height: 600))

        let calls = await harness.capturer.regionCalls
        #expect(calls.count == 2, "两块屏各取一片")
        #expect(Set(calls.map(\.displayID)) == [1, 2])
        // 每片拿到的都是"该屏与选区的交集"，而不是整个选区
        #expect(calls.first { $0.displayID == 1 }?.rect == CGRect(x: 1300, y: 200, width: 140, height: 300))
        #expect(calls.first { $0.displayID == 2 }?.rect == CGRect(x: 1440, y: 200, width: 200, height: 300))
    }

    @Test("未授权 → 不采集、不写剪贴板，返回权限分支")
    func permissionBlocked() async {
        let harness = makeRegionHarness(permission: .denied)

        let outcome = await harness.flow.capture(selection: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                 displays: [TestDisplays.retina])

        #expect(outcome == .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false))
        #expect(await harness.capturer.regionCalls.isEmpty)
        #expect(harness.clipboard.written.isEmpty)
    }

    @Test("零面积选区 → 明确失败，不采集")
    func emptySelectionFails() async {
        let harness = makeRegionHarness()

        let outcome = await harness.flow.capture(selection: CGRect(x: 10, y: 10, width: 0, height: 50),
                                                 displays: [TestDisplays.retina])

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("太小"))
        #expect(await harness.capturer.regionCalls.isEmpty)
    }

    @Test("选区完全在屏外 → 明确失败，不采集")
    func offScreenSelectionFails() async {
        let harness = makeRegionHarness()

        let outcome = await harness.flow.capture(selection: CGRect(x: 9000, y: 9000, width: 100, height: 100),
                                                 displays: [TestDisplays.retina])

        guard case .failed = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(await harness.capturer.regionCalls.isEmpty)
    }

    @Test("采集抛错 → 报错误信息，剪贴板保持不变")
    func captureFailureIsReported() async {
        let harness = makeRegionHarness(failure: StubCaptureError(message: "权限不足"))

        let outcome = await harness.flow.capture(selection: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                 displays: [TestDisplays.retina])

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("权限不足"))
        #expect(harness.clipboard.written.isEmpty)
    }

    @Test("刚授权就失败 → 提示重启应用")
    func failureRightAfterGrantingSuggestsRestart() async {
        let harness = makeRegionHarness(permission: .notDetermined,
                                        grantsOnRequest: true,
                                        failure: StubCaptureError(message: "屏幕采集失败"))

        let outcome = await harness.flow.capture(selection: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                 displays: [TestDisplays.retina])

        guard case .failed(let failure) = outcome else {
            Issue.record("期望 failed，实际 \(outcome)")
            return
        }
        #expect(failure.message.contains("重新打开"))
    }

    @Test("耗时按注入时钟计算")
    func elapsedUsesInjectedClock() async {
        let harness = makeRegionHarness()

        let outcome = await harness.flow.capture(selection: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                 displays: [TestDisplays.retina])

        guard case .copiedToClipboard(let metrics) = outcome else {
            Issue.record("期望复制成功，实际 \(outcome)")
            return
        }
        #expect(metrics.elapsedMilliseconds == 125)
    }
}

// MARK: - 图像编码

@Suite("图像编码")
struct ImageEncodingTests {

    @Test("CGImage → PNG 数据可解码回原尺寸（防止 Retina 退化）")
    func pngRoundTripKeepsPixelSize() throws {
        let image = TestImage.solid(width: 200, height: 120, red: 0.2, green: 0.4, blue: 0.6)
        let data = try #require(ImageEncoding.pngData(from: image))

        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 200)
        #expect(decoded.height == 120)
    }
}

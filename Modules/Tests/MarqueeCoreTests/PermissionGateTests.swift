import Testing
@testable import MarqueeCore

@Suite("权限门：状态 → 该走哪条分支")
struct PermissionGateTests {

    @Test("已授权 → 直接采集")
    func grantedProceeds() {
        #expect(CaptureGate.decision(for: .granted) == .proceed)
    }

    @Test("从未询问过 → 弹系统请求框")
    func notDeterminedRequests() {
        #expect(CaptureGate.decision(for: .notDetermined) == .requestSystemPrompt)
    }

    @Test("已被拒绝 → 只能引导去系统设置，不能再弹框")
    func deniedGuidesToSettings() {
        // 这是最关键的一条：CGRequestScreenCaptureAccess 对被拒绝过的进程不会再弹任何东西，
        // 所以这里必须走"说明 + 跳系统设置"，否则用户看到的就是"按了没反应"
        #expect(CaptureGate.decision(for: .denied) == .guideToSystemSettings)
    }

    @Test("三种状态映射到三条互不相同的分支")
    func allStatesAreDistinct() {
        let decisions = [ScreenRecordingPermission.granted, .notDetermined, .denied]
            .map(CaptureGate.decision(for:))
        #expect(Set(decisions.map(\.self)).count == 3)
    }
}

@Suite("权限门执行：同一进程不能反复弹系统框")
@MainActor
struct CaptureGateRunnerPromptOnceTests {

    @Test("用户拒绝后再次过门 → 不再调 requestPermission")
    func doesNotRePromptAfterDenial() async {
        let probe = FakePermissionProbe(status: .notDetermined, grantsOnRequest: false)

        let first = await CaptureGateRunner.run(probe)
        #expect(first == .blocked(.guideToSystemSettings))
        #expect(probe.requestCount == 1)
        #expect(probe.status == .denied)

        let second = await CaptureGateRunner.run(probe)
        #expect(second == .blocked(.guideToSystemSettings))
        #expect(probe.requestCount == 1, "同一进程已经问过，快捷键再按下也不该再弹系统框")
    }

    @Test("用户同意后再次过门 → 直接放行，不再请求")
    func doesNotRePromptAfterGrant() async {
        let probe = FakePermissionProbe(status: .notDetermined, grantsOnRequest: true)

        let first = await CaptureGateRunner.run(probe)
        #expect(first == .proceed(grantedJustNow: true))
        #expect(probe.requestCount == 1)
        #expect(probe.status == .granted)

        let second = await CaptureGateRunner.run(probe)
        #expect(second == .proceed(grantedJustNow: false))
        #expect(probe.requestCount == 1)
    }
}

@Suite("快捷键注册结果映射")
struct HotKeyRegistrationOutcomeTests {

    @Test("OSStatus = 0 → 注册成功")
    func success() {
        #expect(HotKeyRegistrationOutcome.from(status: 0) == .registered)
    }

    @Test("-9878 是 eventHotKeyExistsErr，映射为「已被占用」而不是通用失败")
    func conflict() {
        #expect(HotKeyRegistrationOutcome.hotKeyExistsStatus == -9878)
        #expect(HotKeyRegistrationOutcome.from(status: -9878) == .conflict)
    }

    @Test("其他错误码带上原始状态值")
    func otherFailure() {
        #expect(HotKeyRegistrationOutcome.from(status: -50) == .failed(status: -50))
    }
}

@Suite("系统设置深链")
struct SystemSettingsLinkTests {

    @Test("屏幕录制面板的深链指向 Privacy_ScreenCapture 锚点")
    func screenRecordingDeepLink() {
        let url = SystemSettingsLink.screenRecording
        #expect(url.scheme == "x-apple.systempreferences")
        #expect(url.absoluteString.contains(SystemSettingsLink.screenRecordingAnchor))
    }
}

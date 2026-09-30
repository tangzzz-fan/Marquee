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

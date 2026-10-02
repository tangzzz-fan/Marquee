import Foundation
import Testing

@testable import MarqueeCore

/// 首次启动引导的判据（ticket 34）。
///
/// 只有"该不该弹"这一条进了 Core —— 窗口长什么样是 App 层的事。
/// 但这一条必须在这里：它决定**自检命令会不会被一个要人点的窗口挂住**，
/// 而那种故障看起来是"命令没反应"，跟引导窗口八竿子打不着。
@Suite("首次启动引导")
struct OnboardingTests {

    @Test("走完过就不再弹")
    func completedNeverPresents() {
        #expect(!OnboardingGate.shouldPresent(hasCompleted: true, arguments: []))
        // 就算参数里没有自检开关，也不该再弹
        #expect(!OnboardingGate.shouldPresent(hasCompleted: true, arguments: ["/path/to/Marquee"]))
    }

    @Test("没走完、普通启动 → 弹")
    func freshLaunchPresents() {
        #expect(OnboardingGate.shouldPresent(hasCompleted: false, arguments: ["/path/to/Marquee"]))
    }

    @Test("带 -marquee 开关的自检运行一律不弹 —— 否则命令会挂住等人点")
    func selfCheckRunsNeverPresent() {
        // 这三个入口都是脚本从终端调的（见 `MarqueeAppDelegate`）。
        for flag in ["-marqueeEntitlement", "-marqueeRequestPermission", "-marqueeDemoEditor"] {
            #expect(!OnboardingGate.shouldPresent(hasCompleted: false, arguments: ["/path", flag]),
                    "\(flag) 会被引导挡住")
        }
        // 开关也可能是 `-marqueeEntitlement purchase` 这种带参数的形态
        #expect(!OnboardingGate.shouldPresent(hasCompleted: false,
                                              arguments: ["/path", "-marqueeEntitlement", "purchase"]))
    }

    @Test("状态读写落在自己的键上，不碰偏好那组")
    func stateRoundTrip() throws {
        let suite = "marquee-onboarding-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = OnboardingState(defaults: defaults)

        // 默认没走过 —— 它是 `bool(forKey:)`，缺键就是 false
        #expect(!state.hasCompleted)

        state.hasCompleted = true
        #expect(state.hasCompleted)

        // 换一个实例读同一份 defaults：说明它真的落盘了，不是内存里的假象
        #expect(OnboardingState(defaults: defaults).hasCompleted)

        state.hasCompleted = false
        #expect(!state.hasCompleted)
    }

    @Test("引导的键与偏好的键不重名（将来加「恢复默认」不会误伤）")
    func keysAreDistinct() {
        let onboarding = OnboardingState.completedKey
        let prefKeys = [UserDefaultsPreferencesStore.soundKey,
                        UserDefaultsPreferencesStore.launchAtLoginKey,
                        UserDefaultsPreferencesStore.cursorKey,
                        UserDefaultsPreferencesStore.shadowKey,
                        UserDefaultsPreferencesStore.delayKey]
        #expect(!prefKeys.contains(onboarding))
        #expect(onboarding.hasPrefix("onboarding."))
    }
}

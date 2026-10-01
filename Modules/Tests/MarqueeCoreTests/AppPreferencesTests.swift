import Foundation
import Testing
@testable import MarqueeCore

/// 偏好设置的模型与落盘（ticket 15）。
@Suite("偏好设置")
struct AppPreferencesTests {

    /// 每个用例一个独立域，互不干扰 —— 用 `.standard` 的话用例之间会互相看见对方写进去的值，
    /// 而那种耦合的表现是"单独跑绿、一起跑红"。
    private func freshDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    // MARK: - 默认值

    @Test("全新安装时的默认值：音效开、不自启、不含光标、带阴影、无延时")
    func defaultsForAFreshInstall() {
        let store = UserDefaultsPreferencesStore(defaults: freshDefaults())
        let general = store.general()
        let capture = store.capture()

        #expect(general.playSound)
        #expect(!general.launchAtLogin)
        #expect(!capture.includeCursor, "指针会挡在内容上，默认不该带")
        #expect(capture.includeShadow)
        #expect(capture.delaySeconds == 0)
    }

    @Test("**没存过**的布尔项要取默认值，不能被当成 false")
    func missingBooleanFallsBackToTheDefault() {
        // ⚠️ 这条钉的是 `defaults.bool(forKey:)` 那个陷阱：它在 key 不存在时返回 `false`，
        // 而 `false` 与"用户关掉了"无法区分 —— 于是"默认打开"的项会变成默认关闭，
        // 而且**只在全新安装时**表现出来（开发机上早就被写过了）。
        let store = UserDefaultsPreferencesStore(defaults: freshDefaults())

        #expect(store.general().playSound, "全新安装时它必须是开的")
        #expect(store.capture().includeShadow, "同上")
    }

    @Test("存进去的 `false` 与「没存过」要能区分开")
    func explicitFalseIsNotTheSameAsMissing() {
        let defaults = freshDefaults()
        let store = UserDefaultsPreferencesStore(defaults: defaults)

        store.save(GeneralPreferences(playSound: false))

        #expect(store.general().playSound == false, "用户明确关掉的项不该被默认值顶回去")
    }

    // MARK: - 往返

    @Test("写进去能原样读回来")
    func roundTrip() {
        let store = UserDefaultsPreferencesStore(defaults: freshDefaults())

        store.save(GeneralPreferences(playSound: false, launchAtLogin: true))
        store.save(CapturePreferences(includeCursor: true, includeShadow: false, delaySeconds: 5))

        #expect(store.general() == GeneralPreferences(playSound: false, launchAtLogin: true))
        #expect(store.capture() == CapturePreferences(includeCursor: true,
                                                     includeShadow: false,
                                                     delaySeconds: 5))
    }

    // MARK: - 延时的合法性

    @Test("非法延时会被夹回默认值 —— 否则按一下快捷键要等十几分钟")
    func illegalDelayFallsBack() {
        // 存了 999 秒的话，用户按快捷键要等 16 分钟才看到覆盖层 ——
        // 那与"应用卡死了"完全一样。存储层必须兜住。
        let defaults = freshDefaults()
        defaults.set(999, forKey: UserDefaultsPreferencesStore.delayKey)
        defaults.set(-5, forKey: "capture.delaySeconds.other")
        let store = UserDefaultsPreferencesStore(defaults: defaults)

        #expect(store.capture().delaySeconds == 0)
        #expect(CapturePreferences(delaySeconds: 999).delaySeconds == 0)
        #expect(CapturePreferences(delaySeconds: -1).delaySeconds == 0)
    }

    @Test("合法档位原样保留，且档位表里只有它能出现的值")
    func legalDelaysSurvive() {
        for option in CapturePreferences.delayOptions {
            #expect(CapturePreferences(delaySeconds: option).delaySeconds == option)
        }
        #expect(CapturePreferences.delayOptions == [0, 3, 5, 10])
        #expect(CapturePreferences.normalize(3) == 3)
    }

    // MARK: - 输出设置（ticket 05 的 key，界面在 15）

    @Test("输出设置写进去能原样读回来")
    func outputRoundTrip() {
        let store = UserDefaultsOutputStore(defaults: freshDefaults())
        let directory = URL(fileURLWithPath: "/tmp/marquee-test", isDirectory: true)

        store.save(OutputSettings(directory: directory,
                                  format: .jpeg,
                                  quality: 0.7,
                                  nameTemplate: "截图-{n}"))

        let read = store.settings()
        #expect(read.directory.path == directory.path)
        #expect(read.format == .jpeg)
        #expect(abs(read.quality - 0.7) < 0.001)
        #expect(read.nameTemplate == "截图-{n}")
    }

    @Test("质量越界会被夹进 0…1 —— 存了个 3.0 的话它会一路传到编码器里")
    func qualityIsClamped() {
        let store = UserDefaultsOutputStore(defaults: freshDefaults())

        store.save(OutputSettings(directory: OutputSettings.desktopDirectory(), quality: 3))

        #expect(store.settings().quality == 1)
    }

    // MARK: - 页面清单

    @Test("偏好窗口**正好四页** —— 这是「功能简洁」的硬约束")
    func exactlyFourPages() {
        // 这条看着像废话，但它守的是一条**产品约束**：页数一多，
        // "设置里到底在哪"就变成一件要翻的事。加第五页必须先改这条测试。
        #expect(SettingsPage.allCases.count == 4)
        #expect(Set(SettingsPage.allCases.map(\.rawValue)) == ["general", "capture", "output", "shortcuts"])
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import MarqueeCore

@Suite("放大镜的默认尺寸与调参覆盖")
struct MagnifierSettingsTests {

    private func makeDefaults() -> UserDefaults {
        // 独立 suite：不碰开发机上的真实偏好
        let name = "com.tango.Marquee.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - 默认值

    /// 这组数是用户实测后定的：12 点采样 × 8 倍 = 每个源像素 4 点见方，
    /// 看到的是"像素格子"而不是"放大的内容"。
    @Test("默认尺寸：采样区够大、倍数够低，盒子约 120 点")
    func defaultsAreContentReadable() {
        let settings = MagnifierLayout.Settings.default
        #expect(settings.samplePoints == 40)
        #expect(settings.zoom == 3)
        #expect(settings.boxSide == 120)
        #expect(settings.gap == 22)
    }

    @Test("倍数取整：盒子边长 = 采样边长 × 倍数，否则最近邻下格子大小会不均")
    func zoomIsIntegral() {
        #expect(MagnifierLayout.Settings(samplePoints: 30, zoom: 2.4).zoom == 2)
        #expect(MagnifierLayout.Settings(samplePoints: 30, zoom: 2.6).zoom == 3)
        // 下界 1：0 或负数会让盒子退化成一条线
        #expect(MagnifierLayout.Settings(zoom: 0).zoom == 1)
        #expect(MagnifierLayout.Settings(zoom: -5).zoom == 1)
    }

    // MARK: - 覆盖

    @Test("没写过偏好 → 用默认值")
    func emptyDefaultsFallBack() {
        let store = MagnifierSettingsStore(defaults: makeDefaults())
        #expect(store.load() == .default)
    }

    @Test("写过 → 按写的来（`-float` 与 `-int` 都要认）")
    func overridesAreApplied() {
        let defaults = makeDefaults()
        defaults.set(32.0, forKey: MagnifierSettingsStore.samplePointsKey)
        defaults.set(4, forKey: MagnifierSettingsStore.zoomKey)
        defaults.set(30.0, forKey: MagnifierSettingsStore.gapKey)

        let settings = MagnifierSettingsStore(defaults: defaults).load()
        #expect(settings.samplePoints == 32)
        #expect(settings.zoom == 4)
        #expect(settings.gap == 30)
        #expect(settings.boxSide == 128)
    }

    @Test("只写一项时，其余仍是默认值")
    func partialOverride() {
        let defaults = makeDefaults()
        defaults.set(5.0, forKey: MagnifierSettingsStore.zoomKey)

        let settings = MagnifierSettingsStore(defaults: defaults).load()
        #expect(settings.zoom == 5)
        #expect(settings.samplePoints == MagnifierLayout.Settings.default.samplePoints)
        #expect(settings.gap == MagnifierLayout.Settings.default.gap)
    }

    /// 越界不能直接生效：`lens.samplePoints = 10000` 会让放大镜铺满整块屏，
    /// 而这类错误只在用户唤起覆盖层时才暴露 —— 那时他正在截屏。
    @Test("越界被夹进范围")
    func outOfRangeIsClamped() {
        let defaults = makeDefaults()
        defaults.set(100_000.0, forKey: MagnifierSettingsStore.samplePointsKey)
        defaults.set(0.2, forKey: MagnifierSettingsStore.zoomKey)
        defaults.set(-40.0, forKey: MagnifierSettingsStore.gapKey)

        let settings = MagnifierSettingsStore(defaults: defaults).load()
        #expect(settings.samplePoints == MagnifierSettingsStore.samplePointsRange.upperBound)
        #expect(settings.zoom == 1, "倍数下界是 1（夹到 0.2 会让盒子退化成一条线）")
        #expect(settings.gap == MagnifierSettingsStore.gapRange.lowerBound)
    }

    @Test("写进来的不是数字 → 当作没写，用默认值，而不是当成 0")
    func nonNumericIsIgnored() {
        let defaults = makeDefaults()
        defaults.set("很大", forKey: MagnifierSettingsStore.zoomKey)
        defaults.set(["a", "b"], forKey: MagnifierSettingsStore.samplePointsKey)

        let settings = MagnifierSettingsStore(defaults: defaults).load()
        #expect(settings == .default)
    }

    @Test("三个键互不干扰，也不与快捷键/输出偏好撞名")
    func keysAreDistinct() {
        let keys = [MagnifierSettingsStore.samplePointsKey,
                    MagnifierSettingsStore.zoomKey,
                    MagnifierSettingsStore.gapKey]
        #expect(Set(keys).count == keys.count)
        #expect(!keys.contains(UserDefaultsShortcutStore.storageKey))
    }
}

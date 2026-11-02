import Foundation
import Testing

@testable import MarqueeCore

/// 功能体验（2026-11-02）。
///
/// 一套「每项 Pro 能力各自 3 天」的窗口，与整包 7 天试用是两件事：
/// 那个走 0 价 IAP、由 Apple 记账；这个纯本地、从第一次使用那一刻开始。
///
/// 这一套测试**不认识 UserDefaults 以外的东西** —— 不碰 StoreKit、不碰界面。
@Suite("功能体验（每项 3 天）")
struct FeatureTrialTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    private func days(_ count: Double) -> Date {
        origin.addingTimeInterval(count * TrialPolicy.secondsPerDay)
    }

    private func ledger(startedAt start: Date? = nil,
                        for feature: ProFeature = .pin) -> FeatureTrialLedger {
        var ledger = FeatureTrialLedger()
        if let start { ledger.markFirstUse(feature, at: start) }
        return ledger
    }

    // MARK: - 窗口

    @Test("没开始过 → notStarted")
    func notStarted() {
        #expect(ledger().state(of: .pin, at: origin) == .notStarted)
    }

    @Test("开始 1 天后还剩 2 天")
    func activeWithTwoDaysLeft() {
        #expect(ledger(startedAt: origin).state(of: .pin, at: days(1)) == .active(daysLeft: 2))
    }

    @Test("剩 0.2 天也说 1 天，不提前宣布结束")
    func lastPartialDayCounts() {
        // 与 7 天试用同一条规则：剩 0.2 天时说「还有 0 天」等于提前宣布结束。
        #expect(ledger(startedAt: origin).state(of: .pin, at: days(2.8)) == .active(daysLeft: 1))
    }

    @Test("满 3 天整才结束")
    func endsExactlyAtThreeDays() {
        #expect(ledger(startedAt: origin).state(of: .pin, at: days(3)) == .ended)
        #expect(ledger(startedAt: origin).state(of: .pin, at: days(2.999)) == .active(daysLeft: 1))
    }

    @Test("系统时间往回拨，天数夹到 3 —— 不出现「还有 9 天」")
    func clockRollbackClamps() {
        // `Int(Double)` 对超范围的数是陷阱（直接崩），而 remaining 来自两个系统时间的差。
        #expect(ledger(startedAt: origin).state(of: .pin, at: days(-6)) == .active(daysLeft: 3))
    }

    @Test("时长参数写 0 → 夹到 1，不允许「一用就结束」")
    func zeroDurationClampsToOne() {
        #expect(FeatureTrialPolicy(durationDays: 0).durationDays == 1)
        #expect(FeatureTrialPolicy().durationDays == 3)
    }

    // MARK: - 分项

    @Test("每项独立：开始了钉图，识别文字仍是未开始")
    func featuresAreIndependent() {
        let ledger = ledger(startedAt: origin, for: .pin)
        #expect(ledger.state(of: .pin, at: days(1)) == .active(daysLeft: 2))
        #expect(ledger.state(of: .textRecognition, at: days(1)) == .notStarted)
        #expect(ledger.state(of: .scrollCapture, at: days(1)) == .notStarted)
    }

    @Test("「不限历史」不参与体验 —— 它不是入口，用户感知不到「体验开始了」")
    func unlimitedHistoryHasNoTrial() {
        // 它问 ledger 只会得到 `.ended`，于是免费版永远是 5 张。
        // 这是刻意的：让一个「数量上限」去谈体验，用户只会觉得"怎么突然能存更多了"。
        #expect(ledger(startedAt: origin, for: .unlimitedHistory)
            .state(of: .unlimitedHistory, at: origin) == .ended)
        #expect(!ProFeature.unlimitedHistory.supportsFeatureTrial)
        #expect(ProFeature.pin.supportsFeatureTrial)
    }

    @Test("重复标记不覆盖第一次的时刻 —— 否则每次再用一次就续期 3 天")
    func markIsIdempotent() {
        var ledger = FeatureTrialLedger()
        ledger.markFirstUse(.pin, at: origin)
        ledger.markFirstUse(.pin, at: days(2))

        // 若第二次把起点改到 days(2)，这里会变成 active；那样「永久免费」只需每月点一次。
        #expect(ledger.state(of: .pin, at: days(3)) == .ended)
    }

    // MARK: - 存储

    private func makeStore() -> (UserDefaultsFeatureTrialStore, UserDefaults) {
        let name = "com.tango.marquee.tests.featureTrial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (UserDefaultsFeatureTrialStore(defaults: defaults), defaults)
    }

    @Test("账本读写往返")
    func roundTrip() {
        let (store, _) = makeStore()
        var ledger = FeatureTrialLedger()
        ledger.markFirstUse(.pin, at: origin)
        ledger.markFirstUse(.textRecognition, at: days(1))

        store.save(ledger)
        #expect(store.load() == ledger)
    }

    @Test("从来没存过 → 空账本，而不是崩溃或「全部已结束」")
    func emptyIsEmptyLedger() {
        let (store, _) = makeStore()
        #expect(store.load() == FeatureTrialLedger())
        #expect(store.load().state(of: .pin, at: origin) == .notStarted)
    }

    @Test("盘上数据写坏了 → 空账本，不崩")
    func corruptedDataYieldsEmptyLedger() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not json".utf8), forKey: "pro.featureTrial")
        #expect(store.load() == FeatureTrialLedger())
    }

    @Test("认不出的项名被忽略，其余项照常读回来")
    func unknownFeatureNameIgnored() {
        let (store, defaults) = makeStore()
        let raw = #"{"firstUsedAt":{"pin":1760000000,"someFutureFeature":1760000000}}"#
        defaults.set(Data(raw.utf8), forKey: "pro.featureTrial")

        let loaded = store.load()
        #expect(loaded.state(of: .pin, at: origin) == .active(daysLeft: 3),
                "同一时刻开始，剩满 3 天")
        #expect(loaded.state(of: .textRecognition, at: origin) == .notStarted)
    }

    @Test("内存实现与落盘实现一致（存储是接缝，两个实现不能分叉）")
    func inMemoryMatchesDisk() {
        let memory = InMemoryFeatureTrialStore()
        #expect(memory.load() == FeatureTrialLedger())

        var ledger = FeatureTrialLedger()
        ledger.markFirstUse(.pin, at: origin)
        memory.save(ledger)
        #expect(memory.load() == ledger)
    }
}

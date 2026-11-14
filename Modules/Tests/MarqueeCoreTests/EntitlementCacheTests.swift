import Foundation
import Testing

@testable import MarqueeCore

/// 权益缓存（ticket 31）。
///
/// 用独立的 suite 名，不碰 `UserDefaults.standard` —— 那会把开发机上的真实权益写坏。
@Suite("权益缓存（ticket 31）")
struct EntitlementCacheTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeCache() -> (UserDefaultsEntitlementCache, UserDefaults) {
        let name = "com.tango.marquee.tests.entitlement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (UserDefaultsEntitlementCache(defaults: defaults), defaults)
    }

    private func inputs(hasPurchase: Bool = true,
                        purchasedAt: Date? = nil,
                        revocation: RevocationReason? = nil,
                        trialStartedAt: Date? = nil,
                        hasUsedTrial: Bool = false) -> EntitlementInputs {
        EntitlementInputs(hasPurchase: hasPurchase,
                          purchasedAt: purchasedAt ?? (hasPurchase ? origin : nil),
                          revocation: revocation,
                          trialStartedAt: trialStartedAt,
                          hasUsedTrial: hasUsedTrial,
                          now: origin)
    }

    @Test("存进去能原样读回来（每个字段都要对）")
    func roundTrip() {
        let (cache, _) = makeCache()
        cache.save(inputs(hasPurchase: true, trialStartedAt: origin, hasUsedTrial: true))

        let loaded = cache.load()
        #expect(loaded?.hasPurchase == true)
        #expect(loaded?.purchasedAt == origin)
        #expect(loaded?.hasUsedTrial == true)
        #expect(loaded?.trialStartedAt == origin)
        #expect(loaded?.isResolved == true)
    }

    @Test("「还没查」**不允许**被缓存 —— 存了它下次开机就成了「查过、什么都没有」")
    func pendingIsNeverCached() {
        let (cache, _) = makeCache()
        cache.save(EntitlementInputs.pending(now: origin))

        #expect(cache.load() == nil,
                "把 unknown 存成「已查」会让付费用户在启动瞬间被当成免费")
    }

    @Test("撤销要能存下来 —— 否则退款后重开又变成 Pro 了")
    func revocationRoundTrips() {
        let (cache, _) = makeCache()
        cache.save(inputs(hasPurchase: false, revocation: .storeRevoked))

        #expect(cache.load()?.revocation == .storeRevoked)
        #expect(cache.load()?.hasPurchase == false)
    }

    @Test("读回来的 `now` 是**读的那一刻**，不是写的那一刻")
    func nowIsRefreshedOnLoad() {
        let (cache, _) = makeCache()
        cache.save(inputs(hasPurchase: true, trialStartedAt: origin, hasUsedTrial: true))

        let loaded = cache.load()
        // 存的时候 now = origin（过去）。若原样读回来，试用天数会按旧时间算 ——
        // 一个几天没开过 app 的人会看到"试用还有 7 天"。
        let loadedNow = try? #require(loaded?.now)
        #expect(loadedNow != nil && loadedNow! > origin)
    }

    @Test("clear 之后读不到")
    func clearRemovesIt() {
        let (cache, _) = makeCache()
        cache.save(inputs(hasPurchase: true))
        #expect(cache.load() != nil)

        cache.clear()
        #expect(cache.load() == nil)
    }

    @Test("从来没存过 → nil（而不是一份「什么都没有」的假输入）")
    func emptyIsNil() {
        let (cache, _) = makeCache()
        #expect(cache.load() == nil)
    }

    @Test("磁盘上认不出的撤销原因 → 当成「没有撤销」，不是「被撤销」")
    func unknownRevocationFailsOpen() {
        let (cache, defaults) = makeCache()
        // 直接往盘上写一个将来才有的 rawValue，模拟降级 / 手改
        // ⚠️ 这份手写 JSON 必须**带齐所有非可选字段**（`hasUsedTrial`）。
        // 第一版漏了它，于是解码失败、`load()` 返回 nil ——
        // 而下面那条 `loaded?.revocation == nil` 会**空跑通过**（对 nil 求 `?.` 就是 nil）。
        // 所以先断言"确实读出来了"，再断言读出来的内容。
        let raw = #"{"hasPurchase":true,"hasUsedTrial":false,"revocation":"somethingFromTheFuture"}"#
        defaults.set(Data(raw.utf8), forKey: "pro.entitlementCache")

        let loaded = cache.load()
        #expect(loaded != nil, "解码应当成功；返回 nil 会让下面两条断言变成空跑")
        #expect(loaded?.revocation == nil, "认不出就当被撤销，会把付费用户锁在外面")
        #expect(loaded?.hasPurchase == true)
    }

    // MARK: - 老付费用户的字段（ticket 35）

    @Test("legacy 购买日要能存下来 —— 否则老付费用户每次重启都要等商店")
    func legacyPurchaseDateRoundTrips() {
        let (cache, _) = makeCache()
        var value = inputs(hasPurchase: false)
        value.legacyPaidPurchaseAt = origin
        cache.save(value)

        let loaded = cache.load()
        #expect(loaded != nil, "先证明确实读出来了，再断言内容（PITFALLS 128）")
        #expect(loaded?.legacyPaidPurchaseAt == origin)
        #expect(LicenseResolver.resolve(loaded!).entitlement == .pro(purchasedAt: origin),
                "读回来就要能立刻判成 Pro —— 这才是缓存的意义")
    }

    @Test("**旧格式缓存仍能解码** —— 1.1.0 写下的那份里没有新字段")
    func oldFormatWithoutLegacyFieldStillDecodes() {
        let (cache, defaults) = makeCache()
        // 这是 1.1.0 真实写下的形状：五个字段，没有 legacyPaidPurchaseAt。
        // ⚠️ 新字段若是**非可选**，这份 JSON 会整体解码失败 ⇒ load() 返回 nil ⇒
        // 所有老用户的缓存一夜之间失效（而它不报错，只是"启动闪一下锁"）。
        let raw = #"{"hasPurchase":true,"purchasedAt":779000000,"hasUsedTrial":false}"#
        defaults.set(Data(raw.utf8), forKey: "pro.entitlementCache")

        let loaded = cache.load()
        #expect(loaded != nil, "旧缓存必须仍能读出来；返回 nil 会让下面的断言空跑")
        #expect(loaded?.hasPurchase == true)
        #expect(loaded?.legacyPaidPurchaseAt == nil, "没有这个字段就是「不知道」，不是任何结论")
    }

    @Test("旧格式 + 没有购买 → 仍是免费，新字段不许把免费用户变成 Pro")
    func oldFormatFreeUserStaysFree() {
        let (cache, defaults) = makeCache()
        let raw = #"{"hasPurchase":false,"hasUsedTrial":false}"#
        defaults.set(Data(raw.utf8), forKey: "pro.entitlementCache")

        let loaded = cache.load()
        #expect(loaded != nil)
        #expect(loaded?.legacyPaidPurchaseAt == nil)
        #expect(LicenseResolver.resolve(loaded!).entitlement == .free)
    }

    @Test("内存实现与落盘实现行为一致（缓存是接缝，两个实现不能分叉）")
    func inMemoryMatchesDisk() {
        let memory = InMemoryEntitlementCache()
        #expect(memory.load() == nil)

        memory.save(inputs(hasPurchase: true))
        #expect(memory.load()?.hasPurchase == true)

        memory.save(EntitlementInputs.pending(now: origin))
        #expect(memory.load()?.hasPurchase == true, "unknown 同样不允许覆盖掉已知状态")

        memory.clear()
        #expect(memory.load() == nil)
    }

    @Test("两个实现对 legacy 字段也一致（ticket 35）")
    func bothImplementationsCarryLegacyField() {
        var value = inputs(hasPurchase: false)
        value.legacyPaidPurchaseAt = origin

        let memory = InMemoryEntitlementCache()
        memory.save(value)
        let (disk, _) = makeCache()
        disk.save(value)

        #expect(memory.load()?.legacyPaidPurchaseAt == disk.load()?.legacyPaidPurchaseAt)
        #expect(memory.load()?.legacyPaidPurchaseAt == origin)
    }
}

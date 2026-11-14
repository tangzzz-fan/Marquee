import Foundation
import Testing

@testable import MarqueeCore

// MARK: - 替身

/// 假的 app transaction 读取器：可控返回值 / 错误 / 挂起，并记录调用次数。
///
/// ## 为什么它必须能"挂住"
///
/// 「app transaction 不许拖累 IAP 那条路」与「启动不等网络」都是**时序**规则。
/// 用一个即答的替身，无论实现有没有 await，断言都会通过（PITFALLS 132）。
private final class FakeAppPurchaseReader: AppPurchaseReading, @unchecked Sendable {

    struct Boom: Error {}

    private let lock = NSLock()
    private var _record: AppPurchaseRecord?
    private var _error: Error?
    private var _calls = 0
    private var _gate: LegacyGate?

    var record: AppPurchaseRecord? {
        get { lock.withLock { _record } }
        set { lock.withLock { _record = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    var gate: LegacyGate? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func fetchAppPurchase() async throws -> AppPurchaseRecord {
        lock.withLock { _calls += 1 }
        if let gate { await gate.wait() }
        if let error { throw error }
        guard let record else { throw Boom() }
        return record
    }
}

/// 闸门（与 `EntitlementCoordinatorTests` 里那个同构；那个是 private，跨文件用不了）。
private final class LegacyGate: @unchecked Sendable {

    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func open() { continuation.finish() }
}

private final class LegacyFakeReader: StorefrontReading, @unchecked Sendable {

    struct Boom: Error {}

    private let lock = NSLock()
    private var _records: [PurchaseRecord] = []
    private var _error: Error?
    private var _calls = 0

    var records: [PurchaseRecord] {
        get { lock.withLock { _records } }
        set { lock.withLock { _records = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func fetchRecords() async throws -> [PurchaseRecord] {
        lock.withLock { _calls += 1 }
        if let error { throw error }
        return records
    }
}

private final class LegacyFakePurchaser: ProductPurchasing, @unchecked Sendable {

    private let lock = NSLock()
    private var _next: PurchaseOutcome = .failed

    var next: PurchaseOutcome {
        get { lock.withLock { _next } }
        set { lock.withLock { _next = newValue } }
    }

    func displayPrice(for productIdentifier: String) async -> String? { "¥36.00" }
    func purchase(_ productIdentifier: String) async -> PurchaseOutcome { next }
    func restore() async throws {}
}

// MARK: - 测试

/// 老付费用户的编排（ticket 35）。
///
/// ## 这一套盯的那条最贵的规则
///
/// **「取不到 app transaction」不等于「他不是老付费用户」。**
///
/// `AppTransaction.shared` 在非商店构建里会失败、首次取还可能弹一次 Apple ID 登录。
/// 把失败当成 `nil` 并写进缓存，一个老用户在断网那次启动之后就被**永久降级**了 ——
/// 与 PITFALLS 126（「商店里没有」只有真的问过才算证据）同型。
@MainActor
@Suite("老付费用户的编排（ticket 35）")
struct LegacyEntitlementCoordinatorTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    private func legacyRecord(version: String = "1.1", verified: Bool = true) -> AppPurchaseRecord {
        AppPurchaseRecord(originalAppVersion: version,
                          originalPurchaseDate: origin,
                          isVerified: verified)
    }

    private func proRecord() -> PurchaseRecord {
        PurchaseRecord(productIdentifier: StoreCatalog.proProductIdentifier, purchaseDate: origin)
    }

    private func make(cached: EntitlementInputs? = nil)
        -> (EntitlementCoordinator, LegacyFakeReader, FakeAppPurchaseReader, InMemoryEntitlementCache) {
        let cache = InMemoryEntitlementCache(cached)
        let reader = LegacyFakeReader()
        let appReader = FakeAppPurchaseReader()
        let stamp = origin
        let coordinator = EntitlementCoordinator(cache: cache,
                                                reader: reader,
                                                purchaser: LegacyFakePurchaser(),
                                                appPurchaseReader: appReader,
                                                now: { stamp })
        return (coordinator, reader, appReader, cache)
    }

    private func cachedFree() -> EntitlementInputs {
        EntitlementInputs(hasPurchase: false, now: origin)
    }

    private func cachedLegacy() -> EntitlementInputs {
        var value = cachedFree()
        value.legacyPaidPurchaseAt = origin
        return value
    }

    // MARK: - 认出来

    @Test("商店里没有 IAP 交易，但 app 本体买过 → **Pro**（这就是老付费用户）")
    func legacyUserIsUnlockedEvenWithNoIAP() async {
        let (coordinator, reader, appReader, cache) = make(cached: cachedFree())
        coordinator.primeFromCache()
        reader.records = []                     // Transaction.all 里没有 IAP
        appReader.record = legacyRecord()

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin),
                "这是本票要救的那批人：付过 ¥36，却被要求再付一次")
        #expect(coordinator.snapshot.allowsProFeatures)
        #expect(cache.load()?.legacyPaidPurchaseAt == origin, "要落缓存，下次启动不等网络")
    }

    @Test("**头号断言**：缓存里有购买 + 商店没有 IAP → 不许判成 purchaseNotFound")
    func legacyBeatsPurchaseNotFoundThroughCoordinator() async {
        // 真实处境：老用户在 1.1.0 里缓存过 hasPurchase（或本轮之后缓存了 legacy），
        // 而商店的 Transaction.all 永远是空的 ⇒ Mapper 会给 .purchaseNotFound。
        var cached = cachedFree()
        cached.hasPurchase = true
        cached.purchasedAt = origin
        let (coordinator, reader, appReader, _) = make(cached: cached)
        coordinator.primeFromCache()
        reader.records = []
        appReader.record = legacyRecord()

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))
        #expect(coordinator.snapshot.entitlement != .revoked(.purchaseNotFound),
                "判成撤销比不认 legacy 还糟：界面会说「购买已撤销」")
    }

    @Test("转免费之后才下载的人 → 仍是免费（不许白送 Pro）")
    func newUserIsNotLegacy() async {
        let (coordinator, reader, appReader, _) = make(cached: cachedFree())
        coordinator.primeFromCache()
        reader.records = []
        appReader.record = legacyRecord(version: "2.0")

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .free)
        #expect(coordinator.snapshot.blockedReason == .neverPurchased)
    }

    @Test("未校验的 app transaction → 不解锁（规则在 Core，不在适配器）")
    func unverifiedAppTransactionDoesNotUnlock() async {
        let (coordinator, reader, appReader, _) = make(cached: cachedFree())
        coordinator.primeFromCache()
        reader.records = []
        appReader.record = legacyRecord(verified: false)

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .free,
                "未校验的收据可以伪造 —— 适配器如实记下来，由 Core 判它不算数")
    }

    // MARK: - 取不到 ≠ 不是

    @Test("**取不到 app transaction 时保留已知 legacy** —— 断网不能把老用户降级")
    func failedAppPurchaseKeepsKnownLegacy() async {
        let (coordinator, reader, appReader, cache) = make(cached: cachedLegacy())
        coordinator.primeFromCache()
        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin), "先按缓存就是 Pro")

        reader.records = []
        appReader.error = FakeAppPurchaseReader.Boom()

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin),
                "把「取不到」当成「不是老用户」，一次断网就把他永久降级了")
        #expect(cache.load()?.legacyPaidPurchaseAt == origin, "也不许把 nil 写进缓存")
    }

    @Test("先认出来、后一轮取不到 → 仍是 Pro（跨轮次保留）")
    func legacySurvivesLaterFailure() async {
        let (coordinator, reader, appReader, _) = make(cached: nil)
        coordinator.primeFromCache()
        reader.records = []
        appReader.record = legacyRecord()
        await coordinator.verifyWithStore()
        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))

        appReader.error = FakeAppPurchaseReader.Boom()
        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))
    }

    @Test("取到了「不是老用户」→ 要**清掉**已知 legacy（这是证据，不是失败）")
    func confirmedNotLegacyClearsIt() async {
        let (coordinator, reader, appReader, cache) = make(cached: cachedLegacy())
        coordinator.primeFromCache()
        reader.records = []
        appReader.record = legacyRecord(version: "2.0")

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .free)
        #expect(cache.load()?.legacyPaidPurchaseAt == nil,
                "「确认不是」与「不知道」必须分得开 —— 前者要落盘，后者要保留")
    }

    // MARK: - 两条路互不拖累

    @Test("app transaction 失败**不影响** IAP 那条路 —— 买了 IAP 的人照样解锁")
    func appPurchaseFailureDoesNotBlockIAP() async {
        let (coordinator, reader, appReader, _) = make(cached: nil)
        coordinator.primeFromCache()
        reader.records = [proRecord()]
        appReader.error = FakeAppPurchaseReader.Boom()

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))
        #expect(coordinator.verification == .succeeded(at: origin),
                "IAP 那轮问成功了就是成功 —— app transaction 是另一件事")
    }

    @Test("IAP 那轮失败 → 判定保持不变（旧规则不许被新代码放宽）")
    func storefrontFailureStillKeepsEverything() async {
        let (coordinator, reader, appReader, _) = make(cached: cachedLegacy())
        coordinator.primeFromCache()
        reader.error = LegacyFakeReader.Boom()
        appReader.record = legacyRecord()

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))
        #expect(coordinator.verification == .failed)
    }

    @Test("启动**不等** app transaction —— 缓存里的 legacy 立刻生效")
    func startDoesNotWaitForAppTransaction() async {
        let (coordinator, _, appReader, _) = make(cached: cachedLegacy())
        let gate = LegacyGate()
        appReader.gate = gate
        appReader.record = legacyRecord()

        let task = coordinator.start()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin),
                "启动等 app transaction ＝ 首次取可能弹 Apple ID 登录，那就是干等")
        gate.open()
        await task.value
    }

    @Test("没有 legacy 也没有缓存时，启动仍是 unknown 且放行")
    func noCacheStillUnknown() {
        let (coordinator, _, _, _) = make(cached: nil)
        coordinator.primeFromCache()

        #expect(coordinator.snapshot.entitlement == .unknown)
        #expect(coordinator.snapshot.allowsProFeatures)
    }

    // MARK: - 与试用 / 恢复的交互

    @Test("legacy 用户不能开始试用")
    func legacyUserCannotStartTrial() async {
        let (coordinator, reader, appReader, _) = make(cached: cachedFree())
        coordinator.primeFromCache()
        reader.records = []
        appReader.record = legacyRecord()

        await coordinator.verifyWithStore()

        #expect(!coordinator.canStartTrial, "他已经付过钱了，不该看到「7 天免费试用」")
    }

    @Test("legacy 用户点「恢复购买」→ 报「有可恢复项」，不是「什么都没有」")
    func restoreReportsRestoredForLegacy() async {
        let (coordinator, reader, appReader, _) = make(cached: cachedFree())
        coordinator.primeFromCache()
        reader.records = []
        appReader.record = legacyRecord()

        let outcome = await coordinator.restorePurchases()

        #expect(outcome == .restored,
                "对老付费用户说「这个账号下没有购买」是一句假话 —— 他买的是 app 本体")
    }

    @Test("默认不注入 appPurchaseReader 时行为与今天一致（既有构造点不破）")
    func defaultReaderKeepsExistingBehaviour() async {
        let cache = InMemoryEntitlementCache()
        let reader = LegacyFakeReader()
        reader.records = [proRecord()]
        let stamp = origin
        let coordinator = EntitlementCoordinator(cache: cache,
                                                reader: reader,
                                                purchaser: LegacyFakePurchaser(),
                                                now: { stamp })
        coordinator.primeFromCache()
        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))
    }

    @Test("购买成功那条路也带上 legacy —— 不许把已知事实丢掉")
    func purchaseKeepsLegacyFact() async {
        let (coordinator, reader, appReader, _) = make(cached: cachedFree())
        coordinator.primeFromCache()
        reader.records = []
        appReader.record = legacyRecord()
        await coordinator.verifyWithStore()

        // 之后商店那轮开始失败，但用户又买了一次 IAP（走 merge，不重问商店）
        reader.error = LegacyFakeReader.Boom()
        let purchaser = LegacyFakePurchaser()
        purchaser.next = .purchased(proRecord())
        let stamp = origin
        let second = EntitlementCoordinator(cache: InMemoryEntitlementCache(cachedLegacy()),
                                           reader: reader,
                                           purchaser: purchaser,
                                           appPurchaseReader: appReader,
                                           now: { stamp })
        second.primeFromCache()
        _ = await second.purchasePro()

        #expect(second.snapshot.entitlement == .pro(purchasedAt: origin))
    }
}
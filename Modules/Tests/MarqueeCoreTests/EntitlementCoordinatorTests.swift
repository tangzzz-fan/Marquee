import Foundation
import Testing

@testable import MarqueeCore

// MARK: - 测试替身

/// 一个可以**挂住**的闸门：用来制造"商店还没回话"的那段时间。
///
/// 这是本套测试的关键装置 —— "启动不等网络"这条规则只有在
/// **网络确实还没回话**的时候才测得出来。用一个立刻返回的假 reader，
/// 那条断言就变成空跑了（无论实现是不是等网络，结果都一样）。
private final class Gate: @unchecked Sendable {

    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    /// 等闸门开。已经开过就直接过。
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func open() { continuation.finish() }
}

/// 假商店：可控的返回值 / 错误 / 挂起，并记录被调用次数。
private final class FakeReader: StorefrontReading, @unchecked Sendable {

    struct Boom: Error {}

    private let lock = NSLock()
    private var _records: [PurchaseRecord] = []
    private var _error: Error?
    private var _calls = 0
    private var _gate: Gate?

    var records: [PurchaseRecord] {
        get { lock.withLock { _records } }
        set { lock.withLock { _records = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    /// 换了它，`fetchRecords` 就会卡在这儿 —— 用来模拟"还没回话"。
    var gate: Gate? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    /// 被调用的次数。用来断言"没有重复打商店"。
    var calls: Int { lock.withLock { _calls } }

    func fetchRecords() async throws -> [PurchaseRecord] {
        lock.withLock { _calls += 1 }
        if let gate { await gate.wait() }
        if let error { throw error }
        return records
    }
}

/// 假收银台。
private final class FakePurchaser: ProductPurchasing, @unchecked Sendable {

    struct Boom: Error {}

    private let lock = NSLock()
    private var _next: PurchaseOutcome = .failed
    private var _restoreError: Error?
    private var _restoreCalls = 0
    private var _askedIDs: [String] = []

    var next: PurchaseOutcome {
        get { lock.withLock { _next } }
        set { lock.withLock { _next = newValue } }
    }

    /// 恢复这一步要抛什么。`nil` = 成功。
    ///
    /// 用 `Error?` 而不是 `Bool`：**抛什么决定了界面说什么话**
    ///（取消 / 连不上 / 其它），只有能选具体错误才测得出这一层。
    var restoreError: Error? {
        get { lock.withLock { _restoreError } }
        set { lock.withLock { _restoreError = newValue } }
    }

    var restoreCalls: Int { lock.withLock { _restoreCalls } }

    /// 被请求过购买的商品 id（顺序）。
    var askedIDs: [String] { lock.withLock { _askedIDs } }

    func displayPrice(for productIdentifier: String) async -> String? { "¥36.00" }

    func purchase(_ productIdentifier: String) async -> PurchaseOutcome {
        lock.withLock { _askedIDs.append(productIdentifier) }
        return next
    }

    func restore() async throws {
        let error = lock.withLock {
            _restoreCalls += 1
            return _restoreError
        }
        if let error { throw error }
    }
}

// MARK: - 测试

/// 权益的启动编排（ticket 31 第二批）。
///
/// 这套测试盯的是**时序**而不是判定 —— 判定在 `EntitlementTests` 里。
/// 时序错的表现通常不是崩，而是"某类用户在某些时刻看到错的东西"，
/// 所以每一条都对应一个具体的用户处境。
@MainActor
@Suite("权益编排（ticket 31）")
struct EntitlementCoordinatorTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    private func proRecord(at date: Date? = nil) -> PurchaseRecord {
        PurchaseRecord(productIdentifier: StoreCatalog.proProductIdentifier,
                       purchaseDate: date ?? origin)
    }

    private func trialRecord(at date: Date? = nil) -> PurchaseRecord {
        PurchaseRecord(productIdentifier: StoreCatalog.trialProductIdentifier,
                       purchaseDate: date ?? origin)
    }

    /// 构造一套：缓存（可空）+ 假商店 + 假收银台。
    private func make(cached: EntitlementInputs? = nil)
        -> (EntitlementCoordinator, FakeReader, FakePurchaser, InMemoryEntitlementCache) {
        let cache = InMemoryEntitlementCache(cached)
        let reader = FakeReader()
        let purchaser = FakePurchaser()
        // ⚠️ 不能直接写 `{ self.origin }`：`@MainActor` 类型的属性是隔离的，
        // 而 `@Sendable` 闭包不能捕它。先取成局部常量再捕。
        let stamp = origin
        let coordinator = EntitlementCoordinator(cache: cache,
                                                reader: reader,
                                                purchaser: purchaser,
                                                now: { stamp })
        return (coordinator, reader, purchaser, cache)
    }

    private func cached(hasPurchase: Bool = true,
                        revocation: RevocationReason? = nil,
                        trialStartedAt: Date? = nil,
                        hasUsedTrial: Bool = false) -> EntitlementInputs {
        EntitlementInputs(hasPurchase: hasPurchase,
                          purchasedAt: hasPurchase ? origin : nil,
                          revocation: revocation,
                          trialStartedAt: trialStartedAt,
                          hasUsedTrial: hasUsedTrial,
                          now: origin)
    }

    // MARK: - 启动

    @Test("启动**不等网络**：商店还挂着，缓存里的 Pro 就已经生效了")
    func startDoesNotWaitForTheStore() async {
        let (coordinator, reader, _, _) = make(cached: cached())
        let gate = Gate()
        reader.gate = gate              // 商店永远不回话

        let task = coordinator.start()

        // 关键断言：此刻商店**还没回话**，但判定已经是 Pro 了。
        // 若实现里先 await 了商店，这里会看到 .unknown。
        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin),
                "启动时不能等商店 —— 那就是「断网时付费用户被锁在外面」")
        #expect(coordinator.verification == .notYetAttempted)

        gate.open()
        await task.value
        #expect(coordinator.verification == .succeeded(at: origin))
    }

    @Test("没有缓存 → 保持 unknown 且**放行**，不判成免费")
    func noCacheStaysUnknown() {
        let (coordinator, _, _, _) = make(cached: nil)

        coordinator.primeFromCache()

        #expect(coordinator.snapshot.entitlement == .unknown)
        #expect(coordinator.snapshot.allowsProFeatures,
                "判成免费会让付过费的人在启动瞬间看到一个锁")
    }

    @Test("缓存里是被撤销 → 启动就知道被撤销（不用等网络）")
    func cachedRevocationIsUsedImmediately() {
        let (coordinator, _, _, _) = make(cached: cached(hasPurchase: false, revocation: .storeRevoked))

        coordinator.primeFromCache()

        #expect(coordinator.snapshot.entitlement == .revoked(.storeRevoked))
        #expect(!coordinator.snapshot.allowsProFeatures)
    }

    // MARK: - 核实失败

    @Test("核实失败**不改动**当前判定 —— 断网不能把 Pro 降级")
    func failedVerificationKeepsPro() async {
        let (coordinator, reader, _, _) = make(cached: cached())
        coordinator.primeFromCache()
        reader.error = FakeReader.Boom()

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin),
                "把「问不到商店」当成「没有购买」，就是离线锁死付费用户")
        #expect(coordinator.verification == .failed)
    }

    @Test("核实失败**不写缓存** —— 不许把猜测伪装成事实")
    func failedVerificationDoesNotTouchCache() async {
        let (coordinator, reader, _, cache) = make(cached: cached())
        coordinator.primeFromCache()
        let before = cache.load()
        reader.error = FakeReader.Boom()

        await coordinator.verifyWithStore()

        // ⚠️ 不能直接比 `load() == before`：`load()` 会把 `now` 刷成"读的那一刻"，
        // 两次调用必然差几微秒，于是那条断言**永远为假**（好在它也是反向的，
        // 写反了就会变成"永远为真"）。比的是**事实本身**。
        #expect(sameFacts(cache.load(), before))
    }

    /// 比"关键事实"，忽略 `now`（它每次读都会被刷新，见上）。
    private func sameFacts(_ lhs: EntitlementInputs?, _ rhs: EntitlementInputs?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let l?, let r?):
            return l.isResolved == r.isResolved
                && l.hasPurchase == r.hasPurchase
                && l.purchasedAt == r.purchasedAt
                && l.revocation == r.revocation
                && l.trialStartedAt == r.trialStartedAt
                && l.hasUsedTrial == r.hasUsedTrial
        default: return false
        }
    }

    @Test("没有缓存 + 核实失败 → 仍是 unknown（放行）；之后成功核实就生效")
    func retryAfterFailureWorks() async {
        let (coordinator, reader, _, _) = make(cached: nil)
        coordinator.primeFromCache()
        reader.error = FakeReader.Boom()
        await coordinator.verifyWithStore()
        #expect(coordinator.snapshot.entitlement == .unknown, "失败不是终局")
        #expect(coordinator.snapshot.allowsProFeatures)

        reader.error = nil
        reader.records = [proRecord()]
        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))
    }

    // MARK: - 核实成功

    @Test("核实成功 → 按商店的事实改判，并写进缓存")
    func successfulVerificationUpdatesAndCaches() async {
        let (coordinator, reader, _, cache) = make(cached: nil)
        coordinator.primeFromCache()
        reader.records = [proRecord()]

        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))
        #expect(cache.load()?.hasPurchase == true, "下次启动要靠它立刻出判定")
        #expect(cache.load()?.isResolved == true)
    }

    @Test("**撤销可以被撤销**：核实到撤销 → 被挡；撤销字段没了 → 又恢复 Pro")
    func revocationAndRestorationAcrossVerifications() async {
        let (coordinator, reader, _, _) = make(cached: nil)
        coordinator.primeFromCache()

        reader.records = [proRecord()]
        await coordinator.verifyWithStore()
        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))

        reader.records = [PurchaseRecord(productIdentifier: StoreCatalog.proProductIdentifier,
                                         purchaseDate: origin,
                                         revocationDate: origin.addingTimeInterval(600))]
        await coordinator.verifyWithStore()
        #expect(coordinator.snapshot.entitlement == .revoked(.storeRevoked))

        // Apple 文档：退款被撤回后，交易上的撤销字段会被移除、访问要恢复。
        // 这条断言就是在拦"把曾经被撤销记成永久状态"的那种实现。
        reader.records = [proRecord()]
        await coordinator.verifyWithStore()
        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin),
                "撤销被撤回之后必须恢复 —— 不许记成永久拉黑")
    }

    @Test("判定没变时**不通知**（避免界面被无意义地重绘）")
    func noCallbackWhenNothingChanged() async {
        let (coordinator, reader, _, _) = make(cached: cached())
        var notifications = 0
        coordinator.onChange = { _ in notifications += 1 }

        coordinator.primeFromCache()
        #expect(notifications == 1)

        reader.records = [proRecord()]
        await coordinator.verifyWithStore()
        #expect(notifications == 1, "结果一样就不该再通知一次")

        reader.records = []
        await coordinator.verifyWithStore()
        #expect(notifications == 2, "真的变了才通知")
    }

    @Test("两轮核实同时发起时，**只打一次商店**，第二个调用等第一个")
    func concurrentVerificationsShareOneRequest() async {
        let (coordinator, reader, _, _) = make(cached: nil)
        let gate = Gate()
        reader.gate = gate
        reader.records = [proRecord()]

        async let first: Void = coordinator.verifyWithStore()
        async let second: Void = coordinator.verifyWithStore()
        // 让两个都进入挂起状态
        await Task.yield()
        gate.open()
        _ = await (first, second)

        #expect(reader.calls == 1, "重复打商店有真实代价：两个回应乱序到达时，旧结果会盖掉新结果")
        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin))
    }

    // MARK: - 购买

    @Test("购买成功 → **立刻**解锁，且不再问商店")
    func purchaseUnlocksImmediately() async {
        let (coordinator, reader, purchaser, cache) = make(cached: nil)
        coordinator.primeFromCache()
        let callsBefore = reader.calls
        purchaser.next = .purchased(proRecord())

        let outcome = await coordinator.purchasePro()

        #expect(outcome.didPurchase)
        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: origin),
                "刚点完购买界面没变，是最容易被当成「没买上」的一刻")
        #expect(reader.calls == callsBefore, "手里已经拿到那条交易了，不该再往返一次")
        #expect(cache.load()?.hasPurchase == true)
        #expect(purchaser.askedIDs == [StoreCatalog.proProductIdentifier])
    }

    @Test("用户取消 / 待批准 / 商品缺失 / 出错 —— **四种都不改动状态**")
    func nonPurchasesChangeNothing() async {
        for outcome in [PurchaseOutcome.cancelledByUser, .pending, .unavailable, .failed] {
            let (coordinator, _, purchaser, _) = make(cached: nil)
            coordinator.primeFromCache()
            purchaser.next = outcome

            let returned = await coordinator.purchasePro()

            #expect(returned == outcome)
            #expect(coordinator.snapshot.entitlement == .unknown,
                    "\(outcome) 不该改动状态 —— 尤其 .pending：家长可能马上就去拒绝")
        }
    }

    @Test("**未校验的交易会被丢弃** —— 哪怕它自称买过")
    func unverifiedPurchaseIsDiscarded() async {
        let (coordinator, _, purchaser, cache) = make(cached: nil)
        coordinator.primeFromCache()
        purchaser.next = .purchased(PurchaseRecord(productIdentifier: StoreCatalog.proProductIdentifier,
                                                   purchaseDate: origin,
                                                   isVerified: false))

        let outcome = await coordinator.purchasePro()

        #expect(outcome.didPurchase, "对收银台来说它确实返回了「买成了」")
        #expect(coordinator.snapshot.entitlement == .unknown,
                "但未校验的交易可以伪造，绝不能拿来解锁")
        #expect(cache.load() == nil, "也不许写进缓存")
    }

    @Test("买过的缓存让**下次启动**直接就是 Pro（不必等商店）")
    func purchasePersistsForNextLaunch() async {
        let (first, _, purchaser, cache) = make(cached: nil)
        first.primeFromCache()
        purchaser.next = .purchased(proRecord())
        _ = await first.purchasePro()

        // 模拟下一次启动：新的编排、同一份缓存，商店挂了
        let reader = FakeReader()
        reader.error = FakeReader.Boom()
        let stamp = origin
        let second = EntitlementCoordinator(cache: cache,
                                            reader: reader,
                                            purchaser: FakePurchaser(),
                                            now: { stamp })
        second.primeFromCache()
        #expect(second.snapshot.entitlement == .pro(purchasedAt: origin))
    }

    // MARK: - 试用

    @Test("开始试用 → 走的是那个 **0 价商品**，立刻变成 trial(7 天)")
    func trialGoesThroughZeroPriceProduct() async {
        let (coordinator, _, purchaser, _) = make(cached: nil)
        coordinator.primeFromCache()
        purchaser.next = .purchased(trialRecord())

        let outcome = await coordinator.startTrial()

        #expect(outcome.didPurchase)
        #expect(purchaser.askedIDs == [StoreCatalog.trialProductIdentifier],
                "试用必须是独立商品：它的时间戳才是起点，用「购买时间减 7 天」不是同一件事")
        #expect(coordinator.snapshot.entitlement == .trial(daysLeft: TrialPolicy.durationDays))
        #expect(coordinator.snapshot.allowsProFeatures)
    }

    @Test("试用过之后 `canStartTrial` 为假；还没查到时为真（乐观）")
    func canStartTrialFollowsFacts() async {
        let (fresh, _, _, _) = make(cached: nil)
        fresh.primeFromCache()
        #expect(fresh.canStartTrial, "还没查到就该放行 —— 判成假会让新用户看到一个点不了的入口")

        let (used, reader, _, _) = make(cached: nil)
        used.primeFromCache()
        reader.records = [trialRecord(at: origin)]
        await used.verifyWithStore()
        #expect(!used.canStartTrial)
    }

    // MARK: - 恢复购买

    @Test("恢复购买：有可恢复项 / 什么都没有 / 恢复本身失败 —— 三种要分得开")
    func restoreOutcomes() async {
        let (coordinator, reader, purchaser, _) = make(cached: nil)
        coordinator.primeFromCache()
        reader.records = [proRecord()]

        let restored = await coordinator.restorePurchases()
        #expect(restored == .restored)
        #expect(purchaser.restoreCalls == 1)

        reader.records = []
        let nothing = await coordinator.restorePurchases()
        #expect(nothing == .nothingToRestore)

        let callsBeforeFailure = reader.calls
        purchaser.restoreError = FakePurchaser.Boom()
        let failed = await coordinator.restorePurchases()
        #expect(failed == .failed,
                "用户主动点的动作，失败必须如实回报 —— 悄悄失败等于骗他「确实没有记录」")
        #expect(reader.calls == callsBeforeFailure, "恢复这一步就失败了，不该再去问商店")
    }

    // MARK: - 恢复失败的分档（2026-10-04 用户报回来的那条）

    /// 用户原话：「恢复购买后取消，提示网络失败，但是我的网络是好的」。
    ///
    /// 根因是 `AppStore.sync()` **在用户按取消时也会抛错**，而编排把所有抛出来的错
    /// 都归成"失败"，界面又只有一句"检查网络后重试" —— 于是网络正常的人被派去查网。
    @Test("用户取消恢复 → 单独一档，**不是**失败、也不是网络问题")
    func restoreCancelledByUser() async {
        let (coordinator, reader, purchaser, _) = make(cached: nil)
        coordinator.primeFromCache()
        let before = coordinator.snapshot.entitlement
        purchaser.restoreError = StorefrontRestoreFailure.cancelledByUser

        let outcome = await coordinator.restorePurchases()

        #expect(outcome == .cancelledByUser, "他自己按的取消 —— 报成失败会让下一步变成「再试一次」")
        #expect(outcome != .networkFailed)
        #expect(outcome != .failed)
        #expect(reader.calls == 0, "取消什么都没发生，不该再去问一次商店")
        // ⚠️ 断言"没变"，不是"等于 free"：还没核实过时判定就是 `.unknown`（按放行处理）。
        // 写成 `.free` 会把"取消不乱动状态"这条错测成"取消会把状态清成免费"。
        #expect(coordinator.snapshot.entitlement == before, "取消不改动判定")
    }

    @Test("连不上商店 → 只有这一档配说「检查网络」")
    func restoreNetworkFailure() async {
        let (coordinator, _, purchaser, _) = make(cached: nil)
        coordinator.primeFromCache()
        purchaser.restoreError = StorefrontRestoreFailure.network

        let outcome = await coordinator.restorePurchases()

        #expect(outcome == .networkFailed)
    }

    @Test("其它失败 → 只说「失败」，**不许**冒充网络问题")
    func restoreOtherFailure() async {
        let (coordinator, _, purchaser, _) = make(cached: nil)
        coordinator.primeFromCache()

        let errors: [Error] = [StorefrontRestoreFailure.other,
                               UnavailableStorefront.StoreUnavailable()]
        for error in errors {
            purchaser.restoreError = error
            let outcome = await coordinator.restorePurchases()
            #expect(outcome == .failed,
                    "认不出来的原因一律「稍后再试」—— 猜成网络就是让用户去修一个没坏的东西")
            #expect(outcome != .networkFailed)
        }
    }

    @Test("三档失败互不相同 —— 混成一档，界面就必然对其中一种说错话")
    func restoreFailureReasonsAreDistinct() async {
        let (coordinator, _, purchaser, _) = make(cached: nil)
        coordinator.primeFromCache()

        purchaser.restoreError = StorefrontRestoreFailure.cancelledByUser
        let cancelled = await coordinator.restorePurchases()
        purchaser.restoreError = StorefrontRestoreFailure.network
        let network = await coordinator.restorePurchases()
        purchaser.restoreError = StorefrontRestoreFailure.other
        let other = await coordinator.restorePurchases()

        #expect(cancelled != network)
        #expect(network != other)
        #expect(cancelled != other)
        #expect(cancelled == .cancelledByUser)
        #expect(network == .networkFailed)
        #expect(other == .failed)
    }

    @Test("价格文案来自商店，不是我们拼的")
    func priceComesFromStore() async {
        let (coordinator, _, _, _) = make()
        let price = await coordinator.displayPrice()
        #expect(price == "¥36.00")
    }
}

// MARK: - 兜底实现

/// 商店整块不可用时的兜底（给"还没接上 StoreKit"的构建用）。
@MainActor
@Suite("商店不可用时的兜底")
struct UnavailableStorefrontTests {

    @Test("取交易会抛错 —— 绝**不**返回空数组")
    func fetchThrowsInsteadOfReturningEmpty() async {
        let storefront = UnavailableStorefront()
        await #expect(throws: UnavailableStorefront.StoreUnavailable.self) {
            _ = try await storefront.fetchRecords()
        }
    }

    @Test("商店不可用时，编排会走「核实失败」那条路 —— 缓存里的 Pro 保住")
    func coordinatorSurvivesMissingStore() async {
        let fixed = Date(timeIntervalSince1970: 1_760_000_000)
        let cache = InMemoryEntitlementCache(EntitlementInputs(hasPurchase: true,
                                                              purchasedAt: fixed,
                                                              now: fixed))
        let stamp = fixed
        let coordinator = EntitlementCoordinator(cache: cache,
                                                reader: UnavailableStorefront(),
                                                purchaser: UnavailableStorefront(),
                                                now: { stamp })
        coordinator.primeFromCache()
        await coordinator.verifyWithStore()

        #expect(coordinator.snapshot.entitlement == .pro(purchasedAt: fixed),
                "商店整块缺失也不能把付过费的人锁在外面")
        #expect(coordinator.verification == .failed)
    }
}

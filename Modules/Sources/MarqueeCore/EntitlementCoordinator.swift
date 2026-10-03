import Foundation
import os

/// 权益的启动编排（ticket 31 第二批）。
///
/// ## 它解决的问题
///
/// 启动时**不能等商店回话**：那等于"断网时付费用户被锁在外面"。
/// 正确的顺序是三段：
///
/// 1. `primeFromCache()` —— 同步读本地缓存，**立刻**出判定（这一步不等任何 IO）；
/// 2. 界面按这份判定渲染（缓存里是 Pro 就是 Pro，没有锁）；
/// 3. `verifyWithStore()` —— 后台问一次商店，**变了才改**。
///
/// `start()` 把 1 与 3 串起来，返回后台核实那个 `Task` 供调用方 await（或不管它）。
///
/// ## 三条不许违背的规则（每条都有测试钉住）
///
/// 1. **核实失败不改动当前判定。** 断网、商店报错、还没查完 —— 都不是"购买没了"。
///    这里如果"保守地"降级成免费，就会把付过费的人锁在外面，而那种 bug
///    只在没网的时候出现，测试环境几乎碰不到。
/// 2. **没有缓存时保持 `.unknown`**（放行），不判成免费。付过费的人在启动那一刻
///    先看到一个锁，是本设计里最不能接受的一类错。
/// 3. **只有真的问过商店之后才写缓存。** 把"还没查"或"查失败"写进去，
///    下次开机读回来就成了"查过了、什么都没有"—— 一个伪装成事实的猜测。
///
/// ## 为什么缓存的是**输入**而不是判定结果
///
/// 见 `EntitlementCache`。判定规则还会改（ticket 31 就改过一次 `RevocationReason`），
/// 存事实则规则怎么改都能重算。
///
/// `@MainActor`：它是**驱动界面的**状态持有者（快照要能直接贴到 UI 上）。
/// 判定本身仍全在 `LicenseResolver` 那个纯函数里，这里只做时序与去重。
@MainActor
public final class EntitlementCoordinator {

    /// 与商店核对的结果。**与权益状态分开** —— 界面不需要它，但排障时它是第一手信息
    /// （"看不到 Pro"到底是"商店说没有"还是"压根没连上商店"，看这一行就知道）。
    public enum Verification: Equatable, Sendable {
        /// 还没试过（启动瞬间）。
        case notYetAttempted
        /// 问过了。带核对时刻。
        case succeeded(at: Date)
        /// 试过但失败了（断网、商店报错）。**此时判定保持上一次的值。**
        case failed
    }

    /// 恢复购买的结果。
    ///
    /// 五档而不是三档，因为**界面要对每一档说不同的话**：
    /// 把"用户自己按了取消"混进"失败"，得到的就是那句让网络正常的人去查网络的提示
    ///（2026-10-04 用户实际报回来的就是这样一条）。
    public enum RestoreOutcome: Equatable, Sendable {
        /// 恢复到了东西（买断或试用）。
        case restored
        /// 恢复成功、但这个账号名下确实什么都没有。
        case nothingToRestore
        /// 用户在系统弹框上按了取消。**不是错误** —— 不该报红、不该说"失败"。
        case cancelledByUser
        /// 连不上商店。**只有这一档配说"检查网络"。**
        case networkFailed
        /// 其它失败（商店报错、账号问题…）。说"稍后再试"，不许猜原因。
        case failed
    }

    // MARK: - 对外状态

    /// 当前判定。界面**只读这一个东西**。
    public private(set) var snapshot: EntitlementSnapshot

    /// 与商店核对的状态。
    public private(set) var verification: Verification = .notYetAttempted

    /// 判定有变化时回调（主线程）。初始化时不回调。
    ///
    /// **只有真的变了才调** —— 每轮核实都无脑回调的话，界面会在每次启动
    /// 或每次恢复购买时重绘一遍、甚至把用户正在看的弹层重建。
    public var onChange: ((EntitlementSnapshot) -> Void)?

    // MARK: - 依赖

    private let cache: EntitlementCaching
    private let reader: StorefrontReading
    private let purchaser: ProductPurchasing
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: AppIdentity().logSubsystem, category: "entitlement")

    // MARK: - 内部状态

    /// 商店最近一次告诉我们的**全部**交易（含已撤销）。
    /// 购买成功后要往里追加，这样"刚买的那笔"能立刻参与判定，不用再问一次商店。
    private var lastRecords: [PurchaseRecord] = []

    /// 我们**已知**"曾经有过有效购买"。核实时作为 `cachedHadPurchase` 传下去，
    /// 用来区分"商店明确说被撤销了"与"商店压根没提这笔"。
    private var knownHadPurchase = false

    /// 正在进行的核实。第二次调用**等它**而不是再打一次商店。
    private var inFlightVerification: Task<Void, Never>?

    public init(cache: EntitlementCaching,
                reader: StorefrontReading,
                purchaser: ProductPurchasing,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.reader = reader
        self.purchaser = purchaser
        self.now = now
        // 初始就是"还没查"。**不回调** —— 调用方刚构造完，本来就该自己读一次 `snapshot`。
        // 用 `resolve` 生成而不是手搓一份：unknown 那份快照里的每一项
        // （包括"能不能试用"这一位该是乐观的**真**）只有一个出处。
        self.snapshot = LicenseResolver.resolve(.pending(now: now()))
    }

    // MARK: - 启动

    /// 启动：先读缓存立刻出判定，再在后台向商店核实。
    ///
    /// 返回后台那个 `Task`。**调用方可以不管它** —— 这正是"启动不等网络"的写法：
    /// 不 await 就等于"判定已经好了、核实慢慢来"。
    @discardableResult
    public func start() -> Task<Void, Never> {
        primeFromCache()
        return Task { await self.verifyWithStore() }
    }

    /// 第 1 步：读缓存、**同步**出判定。
    public func primeFromCache() {
        guard let cached = cache.load() else {
            // 没有缓存 ⇒ **保持 unknown**（放行）。
            // 这里若判成免费，付过费的人（第一次跑新版本、或刚清过缓存）
            // 会在启动瞬间看到一个锁 —— 而它看起来只是"启动闪了一下"。
            logger.info("权益：没有缓存，保持 unknown（放行）")
            publish(LicenseResolver.resolve(.pending(now: now())))
            return
        }

        knownHadPurchase = cached.hasPurchase
        let resolved = LicenseResolver.resolve(cached)
        logger.info("权益：按缓存判定 → \(String(describing: resolved.entitlement), privacy: .public)")
        publish(resolved)
    }

    /// 第 3 步：向商店核实一轮。**失败什么都不做。**
    public func verifyWithStore() async {
        if let existing = inFlightVerification {
            // 已经有一轮在跑：等它，不要重复打商店。
            // 重复打不只是浪费 —— 两个回应乱序到达时，后到的旧结果会覆盖新结果。
            await existing.value
            return
        }
        let task = Task { await self.performVerification() }
        inFlightVerification = task
        await task.value
        inFlightVerification = nil
    }

    private func performVerification() async {
        do {
            let records = try await reader.fetchRecords()
            let stamp = now()
            verification = .succeeded(at: stamp)
            lastRecords = records
            logger.info("权益：商店核实成功，\(records.count, privacy: .public) 条交易")
            apply(inputs(from: records))
        } catch {
            // ⚠️ 失败**什么都不做**。
            //
            // 这里最容易写错的是"保守地"降级成免费 —— 那正好是最危险的方向：
            // 断网、商店抽风、还没查完，都会被当成"这个人没买"，
            // 于是付过费的人在没网时被锁在外面。而这类 bug 只在离线时出现。
            verification = .failed
            logger.warning("权益：商店核实失败，保留当前判定（\(String(describing: self.snapshot.entitlement), privacy: .public)）")
        }
    }

    // MARK: - 购买

    /// 买断商品。
    public func purchasePro() async -> PurchaseOutcome {
        await purchase(StoreCatalog.proProductIdentifier)
    }

    /// 开始试用。
    ///
    /// 走的是那个 **0 价非消耗型 IAP** —— 试用的起点就是它的交易时间戳，
    /// 于是"试用一次"这件事由 Apple 记账，不用我们自己防重。
    public func startTrial() async -> PurchaseOutcome {
        await purchase(StoreCatalog.trialProductIdentifier)
    }

    public func purchase(_ productIdentifier: String) async -> PurchaseOutcome {
        let outcome = await purchaser.purchase(productIdentifier)
        switch outcome {
        case .purchased(let record):
            // 立刻用这条交易重算 —— **不再问一次商店**。
            // `Transaction.all` 可能有几百毫秒的往返，而"刚点完购买、界面还没变"
            // 是最容易被当成"没买上"的一刻（然后用户会再点一次）。
            merge(record)
            logger.info("权益：购买成功 → \(String(describing: self.snapshot.entitlement), privacy: .public)")
        case .cancelledByUser:
            logger.info("权益：用户取消了购买")
        case .pending:
            // 什么都不做。等 `Transaction.updates` 把结果送回来。
            logger.info("权益：购买待批准（不改动状态）")
        case .unavailable:
            // 我们这边的问题（商品没建 / 没审核过 / bundle id 对不上），
            // 与 `.failed` 分开记，否则排障会先去怀疑网络。
            logger.error("权益：商店里没有商品 \(productIdentifier, privacy: .public) —— 检查 App Store Connect 与 bundle id")
        case .failed:
            logger.warning("权益：购买失败（可重试）")
        }
        return outcome
    }

    /// 恢复购买。**失败要如实回报** —— 这是用户主动发起的动作，
    /// 悄悄失败等于骗他"恢复过了，确实没有记录"。
    ///
    /// ⚠️ **原因不许猜。** 原先这里把所有抛出来的错都归成 `.failed`，而界面只有
    /// 一句"检查网络后重试" —— 于是"用户按了取消"（`AppStore.sync()` 也会抛错）
    /// 被报成了网络故障。现在按 `StorefrontRestoreFailure` 的三档分开映射；
    /// 认不出来的错误落 `.failed`（说"稍后再试"），**绝不**冒充网络问题。
    public func restorePurchases() async -> RestoreOutcome {
        do {
            try await purchaser.restore()
        } catch StorefrontRestoreFailure.cancelledByUser {
            // 用户自己按的取消：**不改动任何状态**，界面也不该报红。
            logger.info("权益：用户在系统弹框上取消了恢复购买")
            return .cancelledByUser
        } catch StorefrontRestoreFailure.network {
            logger.warning("权益：恢复购买失败 —— 连不上商店")
            return .networkFailed
        } catch {
            // 含 `StorefrontRestoreFailure.other` 与适配器漏出来的任何未分类错误。
            // 一律按"未知原因"处理：`String(describing:)` 会把原始错误记进日志，
            // 于是下一次报障可以直接从日志里看出到底是哪一类。
            logger.warning("权益：恢复购买失败（未分类）\(String(describing: error), privacy: .public)")
            return .failed
        }
        await verifyWithStore()
        let restored = snapshot.entitlement.isPurchased || snapshot.entitlement.isTrialActive
        logger.info("权益：恢复完成，\(restored ? "有可恢复项" : "账号下没有购买", privacy: .public)")
        return restored ? .restored : .nothingToRestore
    }

    /// 当前店面的价格文案（界面直接用，不许自己拼价格）。
    public func displayPrice(for productIdentifier: String = StoreCatalog.proProductIdentifier) async -> String? {
        await purchaser.displayPrice(for: productIdentifier)
    }

    // MARK: - 查询

    /// 还能不能开始试用。
    ///
    /// 直接读判定里的那一位 —— 不再自己持一份输入重算。
    /// **两个来源必然分叉**：卡片按 `snapshot` 渲染、按钮按另一个判据决定能不能点，
    /// 只要有一次刷新只更新了其中一个，就会出现"按钮亮着、点下去没反应"。
    ///
    /// 还没查到时是**真**（乐观，这一位由 `resolve` 决定）：非消耗型商品不能在同一个
    /// 账号下买两次，Apple 那边本来就拦得住重复试用；而判成假会让刚装上的新用户
    /// 看到一个点不了的试用入口。
    public var canStartTrial: Bool { snapshot.canStartTrial }

    /// 现在是不是买断用户。
    public var isPro: Bool { snapshot.entitlement.isPurchased }

    // MARK: - 内部

    /// 把"刚买到的那条交易"并进已知事实里重算。
    private func merge(_ record: PurchaseRecord) {
        guard record.isVerified else {
            // 未校验的交易不能进已知事实 —— 它可能来自伪造的收据。
            // 这一句是兜底：`PurchaseOutcome.purchased` 的文档已经保证了这一点，
            // 但"保证"和"检查"是两件事，而这里的代价是把付费功能送出去。
            logger.error("权益：收到未校验的交易，丢弃")
            return
        }
        lastRecords.append(record)
        apply(inputs(from: lastRecords))
    }

    private func inputs(from records: [PurchaseRecord]) -> EntitlementInputs {
        StorefrontMapper.inputs(from: StorefrontSnapshot(records: records,
                                                         cachedHadPurchase: knownHadPurchase,
                                                         now: now()))
    }

    /// 落地一份输入：**先记账、再写缓存、最后通知**。
    ///
    /// 只从"真的拿到了商店事实"的两条路进来（核实成功 / 购买成功）——
    /// 于是缓存里永远不会出现"还没查"或"查失败"的推测。
    private func apply(_ inputs: EntitlementInputs) {
        knownHadPurchase = knownHadPurchase || inputs.hasPurchase
        cache.save(inputs)
        publish(LicenseResolver.resolve(inputs))
    }

    /// 值真的变了才通知。
    private func publish(_ next: EntitlementSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }
}

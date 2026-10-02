import Foundation
import MarqueeCore
import os
import StoreKit

/// StoreKit 2 的适配器（ticket 31 第二批）。
///
/// 它只做一件事：把 StoreKit 的类型翻译成 Core 的 `PurchaseRecord`。
/// **所有判断都在 Core**（`StorefrontMapper` / `LicenseResolver`），
/// 因为那是唯一能在没有 App Store 连接的环境里被钉住的地方 ——
/// 而这一层里的每一行都只有真机沙盒才验得到。
///
/// 于是这里的纪律只有一条：**不许在这里做任何判断**。
/// 未校验的交易也要如实记下来（带 `isVerified: false`），
/// 让"未校验一律不算数"那条规则留在 Core 那一处 —— 在这里提前过滤掉，
/// 就等于把同一条规则写了两遍，而两处迟早会分叉。
public actor StoreKitStorefront: StorefrontReading, ProductPurchasing {

    private let logger = Logger(subsystem: AppIdentity().logSubsystem, category: "store")
    private var updatesTask: Task<Void, Never>?

    public init() {}

    // MARK: - 读取商店事实

    /// 取回本 app 的全部交易。
    ///
    /// ## 为什么是 `Transaction.all` 而不是 `currentEntitlements`
    ///
    /// `currentEntitlements` **已经把已撤销的排除掉了** —— 只看它，
    /// 就分不清"从来没有过"与"有过、后来被撤了"，而这两种情况给用户的话术
    /// 完全不同（"了解一下 Pro" vs "这笔购买已被撤销"）。
    ///
    /// `Transaction.all` 会带上撤销信息，代价是它返回**历史全量**
    /// （换过几次 Apple ID 的话可能有几十条），所以 Core 那边的映射要按
    /// 商品 id 筛。这个代价是值得的：撤销这件事必须看得见。
    public func fetchRecords() async throws -> [PurchaseRecord] {
        var records: [PurchaseRecord] = []
        for await result in Transaction.all {
            switch result {
            case .verified(let transaction):
                records.append(Self.record(from: transaction, isVerified: true))
            case .unverified(let transaction, let error):
                // 未校验的**照样记下来**（但标 false），不在这里丢。
                //
                // 判断"什么算数"是 Core 的事：在这里 `continue` 就等于
                // 把那条规则挪进一个只有真机才跑得到的地方，
                // 而它一旦被改坏（比如有人"顺手"改成放行），没有任何测试会发现。
                // 记下来之后，`StorefrontMapper` 里那条 `filter(\.isVerified)` 就是唯一落点。
                logger.warning("商店：有一条未校验的交易 \(transaction.productID, privacy: .public)（\(String(describing: error), privacy: .public)）")
                records.append(Self.record(from: transaction, isVerified: false))
            }
        }
        return records
    }

    // MARK: - 监听交易更新

    /// 开始监听 `Transaction.updates`。
    ///
    /// ## ⚠️ 必须在**启动时**就调用
    ///
    /// 这个序列送的是**发生在 app 之外**的事：退款、家庭共享被移除、
    /// 家长批准了一笔待批准的购买。如果只在打开购买界面时才监听，
    /// 那么"用户在 app 没开的时候退了款"就永远不会被发现 ——
    /// 表现是**退款了还解锁着**。
    ///
    /// - Parameter onChange: 收到变更时的回调（调用方通常会再来一轮 `verifyWithStore`）。
    public func startObservingUpdates(_ onChange: @escaping @Sendable () async -> Void) {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handle(update: result)
                await onChange()
            }
        }
    }

    private func handle(update result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            // ⚠️ 收到的交易**必须 finish**，否则它会一直被重发。
            await transaction.finish()
            logger.info("商店：交易更新 \(transaction.productID, privacy: .public)")
        case .unverified(let transaction, let error):
            // 校验失败的一律不算数，也**不 finish**（Apple 的样例做法）——
            // finish 等于承认它处理完了，而其实我们什么都没接受。
            logger.error("商店：未校验的交易更新 \(transaction.productID, privacy: .public)（\(String(describing: error), privacy: .public)）")
        }
    }

    // MARK: - 价格

    public func displayPrice(for productIdentifier: String) async -> String? {
        guard let product = await product(identifier: productIdentifier) else { return nil }
        // `displayPrice` 是**已经本地化好**的文案（含货币与当地格式）。
        // 界面必须用它 —— 自己拼 `¥36` 会在每个非中国区店面里错。
        return product.displayPrice
    }

    // MARK: - 购买

    public func purchase(_ productIdentifier: String) async -> PurchaseOutcome {
        guard let product = await product(identifier: productIdentifier) else {
            // 商店里没有这个 id。这是**我们这边**的问题（商品没建、还没审核过、
            // 或者 bundle id 与 App Store Connect 里的 app 对不上 —— Apple TN3186），
            // 所以与网络错误分开报，否则排障会先去怀疑用户的网。
            logger.error("商店：取不到商品 \(productIdentifier, privacy: .public) —— 检查 App Store Connect 与 bundle id")
            return .unavailable
        }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    // 非消耗型也要 finish，否则这笔交易会一直挂在队列里。
                    await transaction.finish()
                    return .purchased(Self.record(from: transaction, isVerified: true))
                case .unverified:
                    // 校验没通过 —— **不能算成功**（可能被伪造），
                    // 但也别谎报"购买失败"：用户确实付了钱。
                    // 归到"待定"最贴近事实：真正的结果会由 `Transaction.updates` 送回来。
                    logger.error("商店：购买的交易未通过校验 \(productIdentifier, privacy: .public)")
                    return .pending
                }
            case .userCancelled:
                return .cancelledByUser
            case .pending:
                // 家人共享的"购买前询问"、或银行的额外验证。**既不是成功也不是失败。**
                return .pending
            @unknown default:
                // 将来 StoreKit 加新结果时不要崩，也不要猜 —— 归到"待定"，等 updates。
                return .pending
            }
        } catch {
            logger.warning("商店：购买出错 \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    // MARK: - 恢复

    /// 恢复购买。
    ///
    /// `AppStore.sync()` 会要求用户**登录 Apple ID**（可能弹系统提示）——
    /// 这是 Apple 的既定行为，不是我们能绕的。所以它只该在用户主动点了
    /// "恢复购买"时调用，不能放在启动路径上。
    public func restore() async throws {
        try await AppStore.sync()
    }

    // MARK: - 内部

    private func product(identifier: String) async -> Product? {
        do {
            return try await Product.products(for: [identifier]).first
        } catch {
            logger.warning("商店：查询商品失败 \(identifier, privacy: .public)（\(String(describing: error), privacy: .public)）")
            return nil
        }
    }

    private static func record(from transaction: Transaction, isVerified: Bool) -> PurchaseRecord {
        PurchaseRecord(productIdentifier: transaction.productID,
                       purchaseDate: transaction.purchaseDate,
                       revocationDate: transaction.revocationDate,
                       isVerified: isVerified)
    }
}

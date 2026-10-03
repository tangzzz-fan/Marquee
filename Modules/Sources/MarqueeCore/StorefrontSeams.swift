import Foundation

// MARK: - 读取商店事实（接缝）

/// 向商店要一轮交易事实（ticket 31）。
///
/// 实现在 `MarqueeStore`（StoreKit），协议在 Core —— 于是**编排那一半**
/// 可以脱离 App Store 连接被完整测到。这与 `CaptureHistoryWriting`、
/// `EntitlementCaching` 是同一条做法。
///
/// ## ⚠️ 拿不到就 **throw**，绝不许返回空数组
///
/// 空数组在这里的含义是**「这个人没有购买」**（见 `StorefrontMapper` 的调用前提）。
/// 查询失败时（断网、商店报错、还没查完）恰好也拿不到东西 ——
/// 如果实现图省事 `return []`，就等于**把付过费的人在断网时锁在外面**。
///
/// 那是本设计里最严重的一类错，比"少收一次"严重得多 ——
/// 与 `LicenseResolver` 里"`unknown` 必须放行"是同一条原则的两处落点。
public protocol StorefrontReading: Sendable {

    /// 取回本 app 的全部交易，**包含已撤销的那些**。
    ///
    /// 必须包含已撤销的：只看"当前有效"的那些，就**分不清
    /// "从来没有过"与"有过、后来被撤了"** —— 而这两种情况给用户的话术完全不同
    /// （"了解一下 Pro" vs "这笔购买已被撤销"）。
    /// StoreKit 侧的落点是 `Transaction.all`，不是 `Transaction.currentEntitlements`。
    func fetchRecords() async throws -> [PurchaseRecord]
}

// MARK: - 购买（接缝）

/// 一次购买尝试的结果。
///
/// 分五档不是洁癖：**界面要对每一档说不同的话**，而糊成
/// "成功 / 失败"两档必然会说错其中一种。
public enum PurchaseOutcome: Equatable, Sendable {

    /// 买成了。带上那条交易 —— 调用方**不必再问一次商店**就能立刻解锁。
    ///
    /// 这一步很重要：`Product.products` / `Transaction.all` 都可能有几百毫秒的往返，
    /// 而"刚点完购买、界面还没变"是最容易被当成"没买上"的一刻。
    /// `PurchaseRecord` 只在**校验通过**（`VerificationResult.verified`）时才会出现 ——
    /// 未校验的交易不能进这一档，否则等于把付费功能送给会伪造收据的人。
    case purchased(PurchaseRecord)

    /// 用户自己取消了。**什么都不该发生** —— 不弹错、不改状态。
    case cancelledByUser

    /// 待批准（家人共享的"购买前询问"，或银行的额外验证）。
    ///
    /// ⚠️ **既不是失败也不是成功。** 当成失败会告诉用户"购买失败"、
    /// 而他刚刚才点了同意；当成成功会立刻解锁、而家长可能马上去拒绝。
    /// 正确做法是**什么都不做**，等 `Transaction.updates` 把结果送回来。
    case pending

    /// 商店里**没有这个商品**。
    ///
    /// 这是**我们这边的问题**（商品没建、还没审核通过、或者 bundle id 与
    /// App Store Connect 里的 app 对不上），不是用户环境的问题 ——
    /// 所以日志里必须与 `.failed` 分开，否则排障时会先去怀疑网络。
    case unavailable

    /// 试了一把但出错了（网络断了、商店不可用、请求被拒）。
    ///
    /// 与 `.pending` 的区别是"这次尝试结束了"，与 `.cancelledByUser` 的区别是
    /// "不是用户的选择" —— 界面该给一句"稍后再试"，而不是装作没发生。
    case failed

    /// 这一档算不算"拿到了东西"。
    ///
    /// 只有 `.purchased` 为真 —— 其余四档都不许改动任何状态。
    /// 做成属性而不是让每个调用方自己 `if case`：那种写法一定会在某一处
    /// 把 `.pending` 当成成功。
    public var didPurchase: Bool {
        if case .purchased = self { return true }
        return false
    }
}

/// 发起购买 / 恢复购买（接缝）。
public protocol ProductPurchasing: Sendable {

    /// 该商品在**用户当前店面**的价格文案（已本地化，含货币符号）。
    ///
    /// ⚠️ 界面**必须**用它，不许自己拼 `¥36` —— 每个店面的价格与货币都不同，
    /// 写死的价格一定会与 App Store 实际扣款对不上（低价商品在各国差异更大）。
    /// 取不到（商品缺失、商店不可用）返回 `nil`，界面该退化成不显示价格。
    func displayPrice(for productIdentifier: String) async -> String?

    /// 发起购买。实现里**不许抛错给调用方** —— 所有失败都要落进 `PurchaseOutcome`，
    /// 否则每个调用点都要写一遍 `do/catch`，而那种重复一定会有一处漏掉、
    /// 表现为"点购买什么也没发生"。
    func purchase(_ productIdentifier: String) async -> PurchaseOutcome

    /// 恢复购买（Guideline 要求必须提供）。失败要 throw —— 这是**用户主动发起**的动作，
    /// 悄悄失败等于骗他"恢复过了、确实没有购买记录"。
    ///
    /// ⚠️ 抛出的必须是 `StorefrontRestoreFailure`：**用户取消**与**真的出错**是两件事，
    /// 而 `AppStore.sync()` 两种情况都会抛错。只有适配器知道平台错误码长什么样，
    /// 所以翻译那一半（错误码 → 这一档语义）必须在适配器里做完。
    func restore() async throws
}

/// 恢复购买这一步失败的原因。
///
/// ## 为什么必须分档
///
/// `AppStore.sync()` 在**用户自己按了取消**时也会抛错（它会弹一次 Apple ID 登录 /
/// 确认框）。把这一档报成"网络失败"，会让一个网络完全正常的人去重启路由器 ——
/// 而真正的原因是他刚刚按下的那一下。
///
/// 平台错误码 → 这一档语义的**翻译在适配器**（`MarqueeStore.StoreKitStorefront`），
/// **"哪一档配说什么话"在 Core**（`EntitlementCoordinator.RestoreOutcome`）。
/// 这条分工与 `PurchaseOutcome` 完全一致：适配器翻译事实，Core 决定态度。
public enum StorefrontRestoreFailure: Error, Equatable, Sendable {

    /// 用户在系统弹的那个登录/确认框上按了取消。**不是错误**。
    case cancelledByUser

    /// 真的连不上商店（断网、商店不可达）。**只有这一档配说"检查网络"。**
    case network

    /// 其它（商店报错、账号或系统问题）。界面该说"稍后再试"，
    /// ⚠️ **不许**顺手猜成网络 —— 猜错的方向是让用户去修一个没坏的东西。
    case other
}

/// 商店里没有这条商品时的空实现，给"还没接上 StoreKit"的构建用。
///
/// 存在的意义是让**编排那一半在没有商店的环境里也能跑起来**：
/// 它的 `fetchRecords` 抛错 ⇒ 编排会走"核实失败"那条路 ⇒ 保留缓存判定。
/// 于是即便商店整块缺失，付过费的人也不会被锁在外面。
public struct UnavailableStorefront: StorefrontReading, ProductPurchasing {

    public init() {}

    public struct StoreUnavailable: Error {}

    public func fetchRecords() async throws -> [PurchaseRecord] {
        throw StoreUnavailable()
    }

    public func displayPrice(for productIdentifier: String) async -> String? { nil }

    public func purchase(_ productIdentifier: String) async -> PurchaseOutcome { .unavailable }

    public func restore() async throws { throw StorefrontRestoreFailure.other }
}

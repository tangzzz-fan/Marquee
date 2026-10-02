import Foundation

// MARK: - 商品

/// 商店里的商品（ticket 31）。
///
/// 买断制只有**两个**商品：一个真正收费的，一个 0 价的试用。
/// 后者的做法出自 App Review 3.1.1 原文 —— 非订阅式 app 可以用
/// "价格档 0 的非消耗型 IAP"提供一个限期免费试用（命名遵循 `XX 天试用`）。
public enum StoreCatalog {

    /// 买断商品。¥36，非消耗型。
    public static let proProductIdentifier = "com.tango.Marquee.pro"

    /// 试用商品：**0 价非消耗型 IAP**，交易时间戳就是试用起点。
    ///
    /// 单开一个商品而不是"用购买时间减 7 天"：后者的起点是**第一次购买**，
    /// 而试用必须发生在购买之前 —— 两者不是一件事。
    public static let trialProductIdentifier = "com.tango.Marquee.pro.trial"

    /// 需要向商店查询的商品。
    public static var allProductIdentifiers: [String] {
        [proProductIdentifier, trialProductIdentifier]
    }
}

// MARK: - 交易

/// 一条交易里我们**真正要用**的字段。
///
/// 刻意不直接用 StoreKit 的 `Transaction`：那样"哪些字段算数"这条规则就绑在
/// **只有真机才跑得起来**的类型上，脱机测不了。这里只留四个字段 ——
/// 少到能一眼看完，又足够喂假数据把规则钉住。
public struct PurchaseRecord: Equatable, Sendable {

    public var productIdentifier: String
    public var purchaseDate: Date
    /// 非 `nil` = 这笔交易**被撤销了**（退款，或从家人共享被移出）。
    public var revocationDate: Date?
    /// 签名校验是否通过。
    ///
    /// ⚠️ **`false` 的一律不算数。** 未校验的交易是可以被伪造的，
    /// 把 `unverified` "宽容地当作通过"是这类代码里最典型的一处致命错误 ——
    /// 它不报错、不崩溃，只是把付费功能送给了会伪造收据的人。
    public var isVerified: Bool

    public init(productIdentifier: String,
                purchaseDate: Date,
                revocationDate: Date? = nil,
                isVerified: Bool = true) {
        self.productIdentifier = productIdentifier
        self.purchaseDate = purchaseDate
        self.revocationDate = revocationDate
        self.isVerified = isVerified
    }

    /// 还没被撤销 —— 也就是"仍然有效"。
    public var isLive: Bool { revocationDate == nil }
}

// MARK: - 商店的事实

/// 向商店问过一轮之后拿到的**事实**（还没判成状态）。
public struct StorefrontSnapshot: Equatable, Sendable {

    /// 从商店拿到的交易，**包含已撤销的那些**。
    ///
    /// 为什么必须包含已撤销的：`Transaction.currentEntitlements` 已经把撤销过的排除掉了，
    /// 只看它会**分不清"从来没有过"与"有过、后来被撤了"** ——
    /// 而这两种情况给用户的话术完全不同。已撤销的交易要从 `Transaction.all` 里捞。
    public var records: [PurchaseRecord]

    /// 我们自己的缓存里曾经出现过有效购买。
    ///
    /// 用来区分「商店明确说这笔被撤了」与「商店压根没提这笔交易」——
    /// 后者最可能是换了 Apple ID 或收据丢了，而不是退款。
    public var cachedHadPurchase: Bool

    /// "现在"由外部传进来，不在内部读时钟 —— 否则判定没法测。
    public var now: Date

    public init(records: [PurchaseRecord] = [],
                cachedHadPurchase: Bool = false,
                now: Date) {
        self.records = records
        self.cachedHadPurchase = cachedHadPurchase
        self.now = now
    }
}

// MARK: - 映射

/// 把商店的事实判成状态机的输入。**全是纯函数。**
///
/// ## 调用前提（这一条写粗一点）
///
/// **只在"真的问过商店、并且拿到了回应"之后调用。**
///
/// 查询失败时（断网、商店报错、还没查完）`records` 恰好也是空的，而"空"在这里的含义是
/// **"这个人没有购买"** —— 于是会把付过费的人锁在外面。
/// 那是本设计里最严重的一类错（见 `LicenseResolver` 里"`unknown` 必须放行"同一条原则），
/// 比少收一次严重得多。
///
/// 所以查询失败时**不要调用这里**，直接用缓存里的那份输入：
/// 商店问不到 ≠ 用户的购买没了。
public enum StorefrontMapper {

    /// 判定顺序：有效购买 > 被撤销 > 商店里没有但我们缓存过 > 什么都没发生。
    ///
    /// 这个顺序不是随手排的：**有效购买压过撤销**，因为"退款之后又买了一次"是真实存在的，
    /// 而那时应该解锁（`Transaction.all` 里会同时留着那条旧的和这条新的）。
    public static func inputs(from snapshot: StorefrontSnapshot) -> EntitlementInputs {

        // ⚠️ 第一步就把未校验的丢掉。后面所有判断都建立在"这些记录是真的"之上，
        // 事后补一句 `if isVerified` 一定会漏掉某个分支。
        let verified = snapshot.records.filter(\.isVerified)

        let pro = verified.filter { $0.productIdentifier == StoreCatalog.proProductIdentifier }
        let livePro = pro.first(where: \.isLive)
        let revokedPro = pro.first { !$0.isLive }

        // 试用：**含已撤销的** —— 0 价试用退款了也算用过。
        // 只看有效交易的话，退一次款就能白拿第二次试用。
        let trialDates = verified
            .filter { $0.productIdentifier == StoreCatalog.trialProductIdentifier }
            .map(\.purchaseDate)

        var revocation: RevocationReason?
        if livePro == nil {
            if revokedPro != nil {
                // 商店明确说：这笔被撤了
                revocation = .storeRevoked
            } else if pro.isEmpty, snapshot.cachedHadPurchase {
                // 商店压根没提这笔交易，但我们记得有过
                revocation = .purchaseNotFound
            }
        }

        return EntitlementInputs(hasPurchase: livePro != nil,
                                 purchasedAt: livePro?.purchaseDate,
                                 revocation: revocation,
                                 trialStartedAt: trialDates.min(),
                                 hasUsedTrial: !trialDates.isEmpty,
                                 now: snapshot.now)
    }
}

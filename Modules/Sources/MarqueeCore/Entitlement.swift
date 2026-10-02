import Foundation

// MARK: - 能力

/// 受 Pro 许可控制的能力（ticket 30）。
///
/// ## 为什么这里**只有标识、没有文案**
///
/// 名字是给代码读的，标题是给用户看的。中文标题写进 Core 会被本地化扫描拦下来
/// （要么包 `L10n.t`、要么得出豁免理由）—— 而更根本的理由是：
/// **边界会调、文案会改，这两件事不该互相牵着。**
/// 标题在界面层取，用那里已经有的文案。
///
/// ## 为什么只有四项
///
/// 只登记**现在真的存在**的能力。"批量处理 / 水印 / JPEG 质量 / 模板"这类还没做的东西
/// 一律不进来 —— 把一个不存在的功能写成"锁着的"，界面上就会出现一个
/// **点了什么都不会发生的 Pro 入口**，那比不做还糟：用户会以为是自己没买对。
public enum ProFeature: String, CaseIterable, Sendable {
    /// 滚动截屏（长截图）。竞品普遍做不好的那个，也是本产品最硬的差异点。
    case scrollCapture
    /// 识别文字（OCR）。
    case textRecognition
    /// 钉图。
    case pin
    /// 最近截图不设上限（免费版保留最近若干张）。
    case unlimitedHistory

    /// 这一项是否需要 Pro。**边界就在这里** —— 唯一的落点。
    ///
    /// 现在四项全部需要 Pro，写法上像是一句废话；但它是刻意的：
    /// 将来要把某一项放开（比如"识别文字对所有人免费"），改动就是这一行。
    /// 而 `switch` 是**穷尽**的 —— 加了新能力却不做决定，编译就过不去。
    public var requiresPro: Bool {
        switch self {
        case .scrollCapture, .textRecognition, .pin, .unlimitedHistory: true
        }
    }
}

// MARK: - 试用

/// 试用规则。
public enum TrialPolicy {

    /// 试用时长。**7 天**。
    ///
    /// 这个数字会同时出现在三个地方：StoreKit 的商品名（`7 天试用`）、
    /// 升级界面的文案、以及这里的天数计算。所以它只有一个来源 —— 改了这里，
    /// 另外两处也应该跟着改（商品名改不了，那是 App Store Connect 里的既有商品，
    /// 所以**改动天数等于换一个商品**，不是改个常量那么简单）。
    public static let durationDays = 7

    public static var duration: TimeInterval { Double(durationDays) * Self.secondsPerDay }

    /// 一天是 86400 秒 —— 刻意**不**用 `Calendar` 的"自然日"。
    ///
    /// 用自然日的话，用户在 23:59 开始试用、00:01 就被告知"只剩 5 天"，
    /// 那种"我明明刚点完"的感觉最伤人。按**经过的秒数**算，至少是诚实的。
    public static let secondsPerDay: TimeInterval = 86_400
}

// MARK: - 阻断原因

/// 权益"没了"的原因。
///
/// ## ⚠️ 这里只有**两档**，而它原本有三档（2026-10-03 修正）
///
/// 上一版写的是 `refunded` / `familySharingRevoked` / `purchaseNotFound`。
/// 查过 StoreKit 的文档之后发现**前两个根本区分不出来**：
///
/// - StoreKit 2 的 `Transaction.revocationReason` 只有 **`.developerIssue` / `.other`** 两档；
/// - Apple 的 App Store Server Notifications 文档说得更直白：
///   「For Family Sharing transactions, the revocation reason value is **0** if the customer
///   leaves the family group or the owner stops sharing.」
///   —— 也就是说**退款**与**被移出家人共享**落在同一档里。
///
/// 假装能分开的代价很具体：给用户看一句**很确定、但可能是错的**解释
/// （对一个只是被家人移出共享的人说"你退款了"）。
/// 所以合并成 `.storeRevoked`，文案也照实说"退款，或从家人共享中移出"。
public enum RevocationReason: String, CaseIterable, Sendable {
    /// 商店说这笔交易**被撤销了** —— 退款，或从家人共享里被移出。
    ///
    /// ⚠️ 撤销**可以被撤销**：Apple 文档写明退款撤回后交易上的撤销字段会被移除、
    /// 访问权限要恢复。所以这一档**绝不能当成永久状态** ——
    /// 每次核实都重算，字段没了就该恢复 Pro（见 `StorefrontMapper`）。
    case storeRevoked
    /// 商店那儿**什么都没有**，但我们**自己缓存过**"已经是 Pro"。
    ///
    /// 与 `.storeRevoked` 的区别是「商店明确说它被撤了」vs「商店压根没提这笔交易」——
    /// 后者的典型原因是换了 Apple ID、换了店面、或收据丢了。
    case purchaseNotFound
}

/// 为什么被挡住 —— **给提示文案用的**，与"权益状态"分开。
///
/// 分开的理由是文案不同：`从未购买` 应该说"了解一下 Pro"，
/// `试用已结束` 应该说"试用结束了，继续用请购买"，
/// `已撤销` 要说清是哪一种（退款和别人关掉共享，用户的第一反应完全不一样 ——
/// 前者他会想"我什么时候退款了"，后者他会想"是不是我家人动了设置"）。
public enum BlockedReason: Equatable, Sendable {
    case neverPurchased
    case trialEnded
    case revoked(RevocationReason)
}

// MARK: - 判定结果

/// 能不能用某个 Pro 能力。
public enum ProAccess: Equatable, Sendable {
    case allowed
    case blocked(BlockedReason)

    public var isAllowed: Bool { self == .allowed }

    public var blockedReason: BlockedReason? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }
}

// MARK: - 权益状态

/// 用户当前的权益状态。
///
/// 买断制（非消耗型 IAP）⇒ **没有"过期"这一档**。付一次就是永久，
/// 唯一的"失去"是撤销（退款 / 家庭共享被移除 / 收据丢了）。
/// 订阅那套 `expiresAt` / `inGrace` 在这里是**多余的状态**，而不存在的状态
/// 一旦写进枚举，就会有人去处理它、并因此写出永远走不到的分支。
public enum Entitlement: Equatable, Sendable {
    /// **还没查**（启动瞬间、StoreKit 还没回话）。
    ///
    /// 这一档不能省。省掉它，启动那一刻就只剩"没查到 = 免费"，
    /// 于是**付过费的人会先看到一个锁**，几十毫秒后才解锁 ——
    /// "我买过啊" 是最伤人的一类 bug，而它看起来只是"启动闪了一下"。
    case unknown
    case free
    case trial(daysLeft: Int)
    case pro(purchasedAt: Date)
    case revoked(RevocationReason)

    /// 是不是"已购买"。**试用不算** —— 试用期的用户还没付钱，
    /// 界面上不该出现"已购买"这种说法。
    public var isPurchased: Bool {
        if case .pro = self { return true }
        return false
    }

    public var isTrialActive: Bool {
        if case .trial = self { return true }
        return false
    }
}

// MARK: - 输入

/// 状态机的输入。**全部是值**，所以可以脱机单测、也可以喂假数据。
///
/// 这些东西在真实运行里来自 StoreKit（`Transaction.currentEntitlements` 等），
/// 但状态机本身**不认识 StoreKit** —— 那是 ticket 31 的事。
/// 把"取值"和"判定"分开，判定这一半才能在没有 App Store 连接的环境里被钉住。
public struct EntitlementInputs: Equatable, Sendable {

    /// StoreKit 是否**已经回过话**。
    ///
    /// `false` = 还不知道（启动瞬间）。这一位不能省：
    /// 没有它，"还没查"与"查过了、什么都没有"会变成同一份输入，
    /// 于是启动那一刻只能判成免费 —— 而付过费的人会先看到一个锁。
    public var isResolved: Bool
    /// 有效期内、校验通过的购买交易存在。
    public var hasPurchase: Bool
    /// 购买时间（拿不到就是 `nil`，用"现在"兜底）。
    public var purchasedAt: Date?
    /// 撤销原因。`nil` = 没有被撤销。
    public var revocation: RevocationReason?
    /// 试用开始时间（来自那个 0 价非消耗型 IAP 的交易）。
    public var trialStartedAt: Date?
    /// 试用**是否用过**。一旦用过就不能再来一次 —— 这是"一次试用"的落点。
    public var hasUsedTrial: Bool
    /// "现在"由外部传进来，不在内部读 `Date()` —— 否则天数计算没法测。
    public var now: Date

    public init(isResolved: Bool = true,
                hasPurchase: Bool = false,
                purchasedAt: Date? = nil,
                revocation: RevocationReason? = nil,
                trialStartedAt: Date? = nil,
                hasUsedTrial: Bool = false,
                now: Date) {
        self.isResolved = isResolved
        self.hasPurchase = hasPurchase
        self.purchasedAt = purchasedAt
        self.revocation = revocation
        self.trialStartedAt = trialStartedAt
        self.hasUsedTrial = hasUsedTrial
        self.now = now
    }

    /// 启动时、还没拿到 StoreKit 回话的那一版输入。
    public static func pending(now: Date) -> EntitlementInputs {
        EntitlementInputs(isResolved: false, now: now)
    }
}

// MARK: - 快照

/// 判定结果：状态 + 若被挡住则给出原因 + 还能不能开始试用。
///
/// 把三者放一个类型里，是为了**只有一个来源**：界面要么整份拿去渲染，
/// 要么整份丢掉重取。分成两个函数算的话，"状态说能用、原因说被挡"
/// 这种自相矛盾迟早会出现，而它表现为"按钮亮了、点下去弹出购买页"。
public struct EntitlementSnapshot: Equatable, Sendable {

    public let entitlement: Entitlement
    public let blockedReason: BlockedReason?

    /// 现在还能不能**开始**试用。
    ///
    /// 它是**判定的一部分**，所以和上面两个字段一起算出来 —— 卡片上
    /// "7 天免费试用"与"直接购买"这两条路才不会各算各的（各算各的迟早打架：
    /// 按钮说能试用，点下去什么也没发生）。
    ///
    /// ⚠️ **不能由 `blockedReason` 反推。** `.neverPurchased` 那一档里混着一种边角输入：
    /// `hasUsedTrial = true` 但 `trialStartedAt = nil`（收据里缺开始时间戳，
    /// `resolve` 的条件就落不下去）。它是"从未购买"却**不能**再试用 ——
    /// 照着原因去推按钮，就会给用户一个点了没反应的"7 天免费试用"。
    public let canStartTrial: Bool

    public init(entitlement: Entitlement,
                blockedReason: BlockedReason?,
                canStartTrial: Bool) {
        self.entitlement = entitlement
        self.blockedReason = blockedReason
        self.canStartTrial = canStartTrial
    }

    public var access: ProAccess {
        blockedReason.map(ProAccess.blocked) ?? .allowed
    }

    /// 能用 Pro 能力吗。
    ///
    /// ⚠️ **`.unknown` 放行**（乐观）。方向是"宁可少收一次，不可错拦一次"：
    /// 启动瞬间判成免费、让付过费的人看到锁，比"授权还没查完就用了 200 毫秒"
    /// 严重得多 —— 前者用户会来投诉，后者没人会注意到。
    public var allowsProFeatures: Bool { blockedReason == nil }

    /// 免费版的历史保留张数。`nil` = 无上限（Pro）。
    public func historyLimit(free: Int = ProLimits.default.freeHistoryLimit) -> Int? {
        allowsProFeatures ? nil : free
    }

    /// 这一项该不该显示成"锁着"。
    ///
    /// 与 `access` 同源 —— 界面别自己去拼判据（自己拼的版本会漏掉
    /// "`.unknown` 放行"这类规则，表现就是启动瞬间闪一个锁）。
    public func access(to feature: ProFeature) -> ProAccess {
        feature.requiresPro ? access : .allowed
    }
}

// MARK: - 免费额度

/// 免费版的额度。
public struct ProLimits: Equatable, Sendable {

    /// 免费版保留的最近截图张数。
    ///
    /// 现状是仓库 20 / 面板 12（ticket 16）。免费档收到 5 ——
    /// **够用**（"刚才那张"几乎总在最近几张里），但连续截十几张时会有感觉。
    /// 这种"够用但不够舒服"正是该卖的位置：卖规模，不卖可用性。
    public var freeHistoryLimit: Int

    public init(freeHistoryLimit: Int = 5) {
        // 夹到至少 1：0 会让"保留最近 0 张"，也就是**把用户的历史全删了** ——
        // 一个额度参数写错就能造成数据丢失，所以这里必须有下限。
        self.freeHistoryLimit = max(1, freeHistoryLimit)
    }

    public static let `default` = ProLimits()
}

// MARK: - 状态机

/// 把输入判成状态。**全是纯函数** —— 不读时钟、不碰 StoreKit、不碰磁盘。
public enum LicenseResolver {

    /// 判定的**顺序就是它的语义**（每一档都在下面的测试里有对应条目）：
    ///
    /// 0. 还没查 → `.unknown`，**放行**。
    /// 1. 撤销 → `.revoked`。撤销比"有购买"更晚发生，也更权威 ——
    ///    退款之后收据可能还在缓存里躺一会儿。
    /// 2. 有购买 → `.pro`，**永不过期**（买断）。
    /// 3. 试用进行中 → `.trial(daysLeft:)`。
    /// 4. 其它 → `.free`。
    public static func resolve(_ inputs: EntitlementInputs) -> EntitlementSnapshot {
        // 「能不能开始试用」与「现在处于哪一档」是同一次判定的两个面，
        // 在这里一次算清 —— 界面拿到的是完整结果，不用自己再补一次判断。
        let trialAvailable = canStartTrial(inputs)

        guard inputs.isResolved else {
            return EntitlementSnapshot(entitlement: .unknown,
                                       blockedReason: nil,
                                       canStartTrial: trialAvailable)
        }

        if let reason = inputs.revocation {
            return EntitlementSnapshot(entitlement: .revoked(reason),
                                       blockedReason: .revoked(reason),
                                       canStartTrial: trialAvailable)
        }

        if inputs.hasPurchase {
            let state = Entitlement.pro(purchasedAt: inputs.purchasedAt ?? inputs.now)
            return EntitlementSnapshot(entitlement: state,
                                       blockedReason: nil,
                                       canStartTrial: trialAvailable)
        }

        if inputs.hasUsedTrial, let start = inputs.trialStartedAt {
            let remaining = TrialPolicy.duration - inputs.now.timeIntervalSince(start)
            if remaining > 0 {
                let state = Entitlement.trial(daysLeft: daysLeft(from: remaining))
                return EntitlementSnapshot(entitlement: state,
                                           blockedReason: nil,
                                           canStartTrial: trialAvailable)
            }
            return EntitlementSnapshot(entitlement: .free,
                                       blockedReason: .trialEnded,
                                       canStartTrial: trialAvailable)
        }

        return EntitlementSnapshot(entitlement: .free,
                                   blockedReason: .neverPurchased,
                                   canStartTrial: trialAvailable)
    }

    /// 剩余天数。
    ///
    /// 下限**不需要在这里夹**：调用点保证了 `remaining > 0`，而 `ceil` 对任何正数
    /// 都不小于 1 —— 所以"剩 0.2 天"报的是 1 天，不是 0 天。
    ///
    /// ⚠️ 我原本在这里写了个 `max(1, …)` 并配了段"很重要"的注释。
    /// 变异验证时把它删掉，**测试没有一条变红** —— 因为那个夹取是**死代码**。
    /// 教训：变异不变红时先问一句「这个变异是不是**等价**的」；
    /// 等价就意味着那段代码没人用，该删，而不是"再补一条用例"。
    ///
    /// 先夹再转是必要的：`Int(Double)` 对超范围的数是**陷阱**（直接崩），
    /// 而 `remaining` 来自"现在 − 试用开始"，系统时间设到很远的未来时它会非常大。
    /// 夹到试用时长之后，结果必然落在 `1...durationDays`。
    static func daysLeft(from remaining: TimeInterval) -> Int {
        let clamped = min(remaining, TrialPolicy.duration)
        return Int(ceil(clamped / TrialPolicy.secondsPerDay))
    }

    /// 还能不能开始试用。三个条件缺一不可。
    public static func canStartTrial(_ inputs: EntitlementInputs) -> Bool {
        !inputs.hasUsedTrial && !inputs.hasPurchase && inputs.revocation == nil
    }
}

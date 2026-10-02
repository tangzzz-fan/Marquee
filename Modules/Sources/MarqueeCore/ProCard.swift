import Foundation

// MARK: - 卡片上的动作

/// 升级卡片上能点的动作。
///
/// 它是**语义**，不是按钮标题：标题在界面层取（中文写进 Core 会被本地化扫描拦下来），
/// 更根本的理由是——**判据会调、文案会改，这两件事不该互相牵着**。
public enum ProCardAction: String, CaseIterable, Sendable {
    /// 开始 7 天免费试用（那个 0 价非消耗型 IAP）。
    case startTrial
    /// 了解 Pro —— 打开购买入口。
    case purchase
    /// 恢复购买。App Review 要求可恢复，所以每张卡片上都留得到它。
    case restore
}

// MARK: - 卡片内容

/// 被挡住时那张卡片的**内容**（不含一个字的文案）。
///
/// ## 为什么把"内容"与"文案"分成两层
///
/// 文案要进本地化目录、要改很多轮；而"这张卡片该有哪两个按钮"是**判据**，
/// 会被测试钉住。混在一起的话，改一个错别字就得动测试，
/// 于是测试会被人嫌烦、然后被改松 —— 那才是最贵的。
public struct ProCardContent: Equatable, Sendable {

    /// 点的是**哪个入口** —— 它决定标题。
    ///
    /// 有它才能说"识别文字是 Pro 能力"，而不是笼统的"这是 Pro 能力"。
    /// 用户被挡下来时最想知道的两件事是"我点了什么"和"为什么不行"，
    /// 前者只有入口知道。
    public let feature: ProFeature
    /// 为什么被挡住 —— 决定正文讲的是哪一件事。
    public let reason: BlockedReason
    /// 最显眼的那个动作。
    public let primary: ProCardAction
    /// 次按钮。**允许与 `primary` 相同**（只有一条路可走时）。
    public let secondary: ProCardAction

    public init(feature: ProFeature,
                reason: BlockedReason,
                primary: ProCardAction,
                secondary: ProCardAction) {
        self.feature = feature
        self.reason = reason
        self.primary = primary
        self.secondary = secondary
    }
}

// MARK: - 判据

/// 卡片内容怎么定 —— **纯函数**，所以整套规则能脱机单测。
///
/// ## 它守的是哪条产品规则
///
/// 「**只在入口处挡，不在流程中间挡。**」界面上只有三处会走到这里
/// （菜单「滚动截屏」、工具栏「识别文字」「钉图」），它们共用这一个判据：
/// 点下去**之前**先问一句"他能不能用"；不能用就**原地**弹卡片，
/// 而不是进到流程里再失败 —— 后者会让用户白白框一次选区，然后才知道要付费。
///
/// ## 关掉卡片不许丢任何东西
///
/// 卡片只说明、只给按钮，**不碰选区、不碰标注**。用户关掉它之后
/// 可以接着用免费能力把这次截图做完（见 `docs/MAS-AND-MONETIZATION.md`）。
public enum ProCard {

    /// 为当前判定生成卡片。**不被挡时返回 `nil`** —— 没有卡片可弹。
    ///
    /// 返回 `nil` 恰好就是"这一下该放行"，所以调用方**不需要另外再判一次**
    /// （见 `OverlayToolbarController.allowProEntry` 与 `CaptureCoordinator`）——
    /// 两处各判一次的话，"这一项放开了但卡片照弹"这类不一致迟早会出现。
    public static func content(for snapshot: EntitlementSnapshot,
                               feature: ProFeature) -> ProCardContent? {
        // ⚠️ 先看**这一项现在收不收钱**，再看用户是什么状态。
        //
        // 顺序反过来的话，将来把某一项放开成免费（改 `ProFeature.requiresPro` 那一行），
        // 免费用户点它照样会弹出一张"这是 Pro 能力"的卡片 ——
        // 而 `snapshot.access(to:)` 那边明明已经放行了。
        guard feature.requiresPro else { return nil }
        guard let reason = snapshot.blockedReason else { return nil }

        switch reason {
        case .neverPurchased:
            // 还能试用 ⇒ 主按钮给**试用**：这是唯一一条"不花钱就能用上"的路，
            // 也是转化率最高的一步。已经用过 ⇒ 直接给购买 ——
            // 摆一个点不动的"7 天免费试用"，比不给还糟。
            return snapshot.canStartTrial
                ? ProCardContent(feature: feature, reason: reason,
                                 primary: .startTrial, secondary: .purchase)
                : ProCardContent(feature: feature, reason: reason,
                                 primary: .purchase, secondary: .restore)

        case .trialEnded:
            // 试用已经用掉了，再给"试用"就是骗人。但「恢复购买」要留着 ——
            // 换过机器、换过 Apple ID 的人，他的购买可能就在这个账号名下。
            return ProCardContent(feature: feature, reason: reason,
                                  primary: .purchase, secondary: .restore)

        case .revoked:
            // ⚠️ 这一档**最可能的原因不是他退了款**：换了 Apple ID、换了设备，
            // 或者家人把共享关掉了（StoreKit 把那几种情况的撤销原因都归到同一档）。
            // 所以先让他「恢复购买」，别一上来就叫他再买一次 ——
            // 对一个只是被移出家庭组的人说"重新购买"，是最容易招差评的一句话。
            return ProCardContent(feature: feature, reason: reason,
                                  primary: .restore, secondary: .purchase)
        }
    }
}

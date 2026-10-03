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

    /// 这一下要不要**把整个屏幕让出去**（打开另一个窗口 / 系统购买面板）。
    ///
    /// ## 为什么它是卡片自己的性质，而不是调用方那边的 if
    ///
    /// 三个动作里有一个（`restore`）是**原地就能完成**的：成功了当场解锁、
    /// 失败了当场给一行回执。另外两个做不到 —— 它们要开窗口：
    ///
    /// | 动作 | 要什么 |
    /// | --- | --- |
    /// | `purchase` | 偏好设置窗口（价格与当前状态都在那一页上） |
    /// | `startTrial` | StoreKit 的购买面板（**系统**开的，我们放不了它的位置） |
    /// | `restore` | 什么都不要 |
    ///
    /// ⇒ 覆盖层必须在开窗口**之前**退场。覆盖层是 `.screenSaver` 层的非激活面板，
    /// 整屏压在所有普通窗口之上：不退场的话，新开的窗口在用户眼里**根本没出现**，
    /// 他只会说"这个卡片点不动"（2026-10-04 用户报的原话）。
    public var needsAnotherWindow: Bool {
        switch self {
        case .purchase, .startTrial: true
        case .restore: false
        }
    }
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

    // MARK: - 正文该说哪一句

    /// 卡片正文有**四句话**，对应四种"为什么被挡住"。
    ///
    /// ⚠️ 这个枚举存在的理由：**"哪一句"是判据，"那句话是什么"是文案。**
    /// 两者分开之后，"从未购买但试用已用过"这一档到底该说"试用 7 天"还是
    /// "试用已结束"就能在 Core 里被断言 —— 而它错了的样子是
    /// **对着一个已经用过试用的人说"可以试用 7 天"**（一句明确的假话）。
    ///
    /// 判据只看两件事：`reason`，以及**主按钮给的是不是试用** ——
    /// 后者才是"这一档是说试用还是说结束"的真正依据（同一个 `.neverPurchased`
    /// 在能试用与不能试用时是两个不同的状态）。
    public enum BodyVariant: Equatable, Sendable {
        /// 「试用 7 天，结束后自动回到免费版」
        case trial
        /// 「试用已结束，免费版仍可截图与标注」
        case trialEnded
        /// 「购买已撤销，可点恢复购买重新获取」
        case revokedByStore
        /// 「这个账号下找不到这笔购买」
        case purchaseNotFound
    }

    /// 这一张卡片的正文该说哪一句。
    public static func bodyVariant(for content: ProCardContent) -> BodyVariant {
        switch content.reason {
        case .neverPurchased:
            // ⚠️ 看的是**主按钮**，不是 reason 本身：`.neverPurchased` 里
            // 既可能是"还没试过"，也可能是"试用已经用掉了"。
            return content.primary == .startTrial ? .trial : .trialEnded
        case .trialEnded:
            return .trialEnded
        case .revoked(let cause):
            switch cause {
            case .storeRevoked: return .revokedByStore
            case .purchaseNotFound: return .purchaseNotFound
            }
        }
    }
}

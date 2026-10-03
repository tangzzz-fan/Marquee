import AppKit
import MarqueeCore

/// 「刚才那一下」的回执：**一个地方决定说哪句话**，各处只负责它的颜色与去向。
///
/// ## 为什么要有它
///
/// 同一件事现在有**两个界面**要说：
///
/// - 偏好设置里那行常驻的结果（点「恢复购买」的地方）；
/// - 覆盖层的提示行（卡片上点「恢复购买」的地方 —— 那个动作原地完成，
///   卡片收掉之后结果只剩这一行能说）。
///
/// 两处各写一份的话，"用户按的取消该说中性的话、不该报红"这类判断
/// 必然只修一处 —— 而另一处会把取消说成失败（2026-10-04 就是这么踩的，
/// 见 PITFALLS 180）。
///
/// ⚠️ **颜色不在这里**：同一个"失败"，在偏好页是危险红、在覆盖层里是琥珀
///（提示行只有三档角色）。那是各表面自己的事。
struct ProFeedback {

    /// 这一句是什么性质 —— 决定颜色，**不决定措辞**。
    enum Kind {
        /// 成了。
        case success
        /// 没有变化，也**不是错**：用户取消、账号下没有可恢复的。
        case neutral
        /// 没成。
        case failure
    }

    var kind: Kind
    var text: String

    /// 恢复购买的结果该怎么说。
    ///
    /// 五档**每一档都有话**：这个动作是用户主动点的，悄悄失败等于骗他
    /// "恢复过了、确实没有记录"。
    static func restore(_ outcome: EntitlementCoordinator.RestoreOutcome) -> ProFeedback {
        switch outcome {
        case .restored:
            ProFeedback(kind: .success, text: L10n.t("已恢复购买 ✓"))
        case .nothingToRestore:
            ProFeedback(kind: .neutral, text: L10n.t("这个账号下没有可恢复的购买"))
        case .cancelledByUser:
            // 他自己按的取消：不说"失败"、不报红
            ProFeedback(kind: .neutral, text: L10n.t("已取消，没有改动"))
        case .networkFailed:
            // **只有这一档配说"检查网络"**（PITFALLS 180）
            ProFeedback(kind: .failure, text: L10n.t("恢复失败 · 检查网络后重试"))
        case .failed:
            ProFeedback(kind: .failure, text: L10n.t("恢复失败 · 请稍后再试"))
        }
    }
}

extension ProFeedback.Kind {

    /// 覆盖层提示行那一侧的颜色。它只有三档角色（`ReadoutRole`），
    /// 而偏好页用的是自己的 `success / label2 / danger` —— 两个表面各映射各的。
    var readoutRole: ReadoutRole {
        switch self {
        case .success: .primary
        case .neutral: .secondary
        case .failure: .caution
        }
    }
}

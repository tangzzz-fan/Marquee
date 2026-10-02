import Foundation
import Testing

@testable import MarqueeCore

/// 升级卡片的内容规则（ticket 31 界面收尾）。
///
/// 和 `EntitlementTests` 一样，这一套**不认识 StoreKit、也不认识 AppKit**：
/// "这张卡片该有哪两个按钮"是判据，钉在这里；按钮长什么样、文案怎么写，在界面层。
///
/// 这些判据值得单测，是因为它们**看着像废话、写错了却很难发现** ——
/// 一个点不动的"7 天免费试用"按钮，用手点一次才知道它是死的。
@Suite("升级卡片的内容规则")
struct ProCardTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    private func days(_ count: Double) -> Date {
        origin.addingTimeInterval(count * TrialPolicy.secondsPerDay)
    }

    // MARK: - 不该有卡片的时候

    @Test("能用 Pro 的时候没有卡片可弹")
    func noCardWhenAllowed() {
        let cases: [(String, EntitlementInputs)] = [
            ("还没查（放行）", .pending(now: origin)),
            ("已购买", EntitlementInputs(hasPurchase: true, purchasedAt: origin, now: origin)),
            ("试用中", EntitlementInputs(trialStartedAt: origin, hasUsedTrial: true, now: days(1))),
        ]
        for (label, inputs) in cases {
            let snapshot = LicenseResolver.resolve(inputs)
            #expect(ProCard.content(for: snapshot, feature: .textRecognition) == nil, "\(label) 不该弹升级卡片")
        }
    }

    // MARK: - 从未购买

    @Test("从未购买、还能试用 → 主按钮是试用")
    func neverPurchasedOffersTrial() {
        let snapshot = LicenseResolver.resolve(EntitlementInputs(now: origin))
        let card = ProCard.content(for: snapshot, feature: .textRecognition)

        #expect(card?.feature == .textRecognition, "入口要跟着带上卡片 —— 标题靠它")
        #expect(card?.reason == .neverPurchased)
        #expect(card?.primary == .startTrial)
        #expect(card?.secondary == .purchase)
    }

    @Test("从未购买、但试用已经用掉 → 主按钮必须是购买，不能摆一个点不动的试用")
    func neverPurchasedWithoutTrialOffersPurchase() {
        // 边角输入：收据说用过试用，却没有开始时间戳（`trialStartedAt == nil`）。
        // `resolve` 因此落不进"试用中"那一档，判成 `.neverPurchased` ——
        // **但这个人不能再试用了。**
        //
        // 这条用例钉的就是"**不能照着 `blockedReason` 反推按钮**"：
        // 照原因推出来的是 `startTrial`，而那个按钮点下去什么都不会发生。
        let inputs = EntitlementInputs(trialStartedAt: nil, hasUsedTrial: true, now: origin)
        let snapshot = LicenseResolver.resolve(inputs)

        #expect(snapshot.blockedReason == .neverPurchased)
        #expect(!snapshot.canStartTrial)

        let card = ProCard.content(for: snapshot, feature: .textRecognition)
        #expect(card?.primary == .purchase, "给试用按钮也点不动")
        #expect(card?.secondary == .restore)
    }

    // MARK: - 试用结束

    @Test("试用到期 → 主按钮是购买，但「恢复购买」要留着")
    func trialEndedOffersPurchase() {
        let snapshot = LicenseResolver.resolve(
            EntitlementInputs(trialStartedAt: origin, hasUsedTrial: true, now: days(8)))
        let card = ProCard.content(for: snapshot, feature: .textRecognition)

        #expect(snapshot.blockedReason == .trialEnded)
        #expect(card?.primary == .purchase)
        #expect(card?.secondary == .restore, "换过机器的人，购买可能就在这个账号名下")
    }

    // MARK: - 被撤销

    @Test("被撤销 → 主按钮是「恢复购买」，不是「再买一次」")
    func revokedPrefersRestore() {
        for reason in RevocationReason.allCases {
            let inputs = EntitlementInputs(hasPurchase: true,
                                           purchasedAt: origin,
                                           revocation: reason,
                                           now: days(30))
            let snapshot = LicenseResolver.resolve(inputs)
            let card = ProCard.content(for: snapshot, feature: .textRecognition)

            #expect(snapshot.blockedReason == .revoked(reason))
            #expect(card?.primary == .restore,
                    "这一档最常见的原因是换了 Apple ID / 换了设备，先让他恢复")
            #expect(card?.secondary == .purchase)
        }
    }

    // MARK: - 判定里带出来的 canStartTrial

    @Test("`canStartTrial` 跟着判定一起出来：乐观起步，买过或试用过就是「否」")
    func canStartTrialTravelsWithTheSnapshot() {
        // 这一位以前是 `EntitlementCoordinator` 自己按 `lastInputs` 重算的 ——
        // 于是"卡片按 snapshot 渲染、按钮按另一个判据决定能不能点"，
        // 两个来源迟早分叉。现在它只从 `resolve` 出。
        let cases: [(String, EntitlementInputs, Bool)] = [
            ("还没查（乐观）", .pending(now: origin), true),
            ("从未购买", EntitlementInputs(now: origin), true),
            ("已购买", EntitlementInputs(hasPurchase: true, purchasedAt: origin, now: origin), false),
            ("试用中", EntitlementInputs(trialStartedAt: origin, hasUsedTrial: true, now: days(1)), false),
            ("试用到期", EntitlementInputs(trialStartedAt: origin, hasUsedTrial: true, now: days(8)), false),
            ("已撤销", EntitlementInputs(hasPurchase: true, revocation: .storeRevoked, now: days(30)), false),
        ]
        for (label, inputs, expected) in cases {
            #expect(LicenseResolver.resolve(inputs).canStartTrial == expected, "\(label)")
        }
    }

    // MARK: - 穷尽性

    @Test("卡片的存在与「这一项能不能用」**必须一致** —— 不许两处各判一次")
    func cardPresenceMatchesAccess() {
        // 界面弹不弹卡片，用的是 `ProCard.content != nil`；
        // 而"放不放行"用的是 `snapshot.access(to:)`。这两个判据一旦分叉，就会出现
        // "点下去弹了卡片、可它其实该放行"（或反过来：不弹卡片也不干活）。
        //
        // ⚠️ 现在四项能力全都要钱，所以这条与实现**暂时等价** —— 它守的是
        // 将来把某一项放开成免费的那一天：那时 `requiresPro` 变 false，
        // `access(to:)` 放行，而若 `ProCard.content` 忘了先看 `requiresPro`，
        // 免费用户点它照样会弹出一张"这是 Pro 能力"的卡片。
        // 所以那行守卫**删掉也不会让任何测试变红** —— 它是防御，不是死代码。
        let cases: [EntitlementInputs] = [
            .pending(now: origin),
            EntitlementInputs(now: origin),
            EntitlementInputs(hasPurchase: true, purchasedAt: origin, now: origin),
            EntitlementInputs(trialStartedAt: origin, hasUsedTrial: true, now: days(1)),
            EntitlementInputs(trialStartedAt: origin, hasUsedTrial: true, now: days(8)),
            EntitlementInputs(hasPurchase: true, revocation: .storeRevoked, now: days(30)),
        ]
        for inputs in cases {
            let snapshot = LicenseResolver.resolve(inputs)
            for feature in ProFeature.allCases {
                let shouldBlock = !snapshot.access(to: feature).isAllowed
                let hasCard = ProCard.content(for: snapshot, feature: feature) != nil
                #expect(hasCard == shouldBlock,
                        "\(feature.rawValue) 在 \(snapshot.entitlement) 下两处判据分叉了")
            }
        }
    }

    @Test("三档被挡的原因，各自都能生成卡片")
    func everyBlockedReasonHasACard() {
        // `switch` 是穷尽的，将来加第四档编译就过不去 —— 这条防的是
        // "加了档位、也加了分支，但那条分支 `return nil`"。
        let blocked: [EntitlementInputs] = [
            EntitlementInputs(now: origin),
            EntitlementInputs(trialStartedAt: origin, hasUsedTrial: true, now: days(8)),
            EntitlementInputs(hasPurchase: true, revocation: .storeRevoked, now: days(30)),
        ]
        for inputs in blocked {
            let snapshot = LicenseResolver.resolve(inputs)
            #expect(ProCard.content(for: snapshot, feature: .textRecognition) != nil)
        }
    }
}

import Foundation
import Testing

@testable import MarqueeCore

/// 许可状态机（ticket 30）。
///
/// 这一套测试**不认识 StoreKit** —— 那正是把判定做成纯函数的目的：
/// 没有 App Store 连接、没有沙盒账号的机器上也能把规则钉住。
@Suite("许可状态机（ticket 30）")
struct EntitlementTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    private func days(_ count: Double) -> Date {
        origin.addingTimeInterval(count * TrialPolicy.secondsPerDay)
    }

    private func purchased(_ now: Date) -> EntitlementInputs {
        EntitlementInputs(hasPurchase: true, purchasedAt: origin, now: now)
    }

    private func trial(since start: Date, at now: Date) -> EntitlementInputs {
        EntitlementInputs(trialStartedAt: start, hasUsedTrial: true, now: now)
    }

    // MARK: - 「还没查」不是「免费」

    @Test("StoreKit 还没回话时是 unknown，而且**放行**")
    func pendingIsOptimistic() {
        let snapshot = LicenseResolver.resolve(.pending(now: origin))

        #expect(snapshot.entitlement == .unknown)
        // 这一条是整份状态机的头号判据。方向是"宁可少收一次，不可错拦一次"：
        // 判成免费会让付过费的人在启动那一刻看到一个锁 ——
        // 而"我买过啊"是最伤人的一类 bug，它看起来只是"启动闪了一下"。
        #expect(snapshot.allowsProFeatures, "还没查就当成免费，付过费的人会先看到锁")
        #expect(snapshot.blockedReason == nil)
    }

    @Test("查过了但什么都没有 → 免费，原因是「从未购买」")
    func resolvedButEmptyIsFree() {
        let snapshot = LicenseResolver.resolve(EntitlementInputs(now: origin))

        #expect(snapshot.entitlement == .free)
        #expect(snapshot.blockedReason == .neverPurchased)
        #expect(!snapshot.allowsProFeatures)
    }

    // MARK: - 买断

    @Test("有购买就是 Pro，而且**永不过期**")
    func purchaseNeverExpires() {
        // 买断制的要害：一年后、十年后都还得是 Pro。
        // 一旦有人"顺手"给它加个过期时间，付费用户会在某天突然解锁不了。
        for later in [days(1), days(365), days(3_650)] {
            let snapshot = LicenseResolver.resolve(purchased(later))
            #expect(snapshot.entitlement == .pro(purchasedAt: origin))
            #expect(snapshot.allowsProFeatures)
            #expect(snapshot.blockedReason == nil)
        }
    }

    @Test("拿不到购买时间时用「现在」兜底，不能崩也不能变成免费")
    func purchaseWithoutTimestamp() {
        let inputs = EntitlementInputs(hasPurchase: true, purchasedAt: nil, now: origin)
        let snapshot = LicenseResolver.resolve(inputs)

        #expect(snapshot.entitlement == .pro(purchasedAt: origin))
        #expect(snapshot.allowsProFeatures)
    }

    // MARK: - 撤销（买断制唯一的「失去」）

    @Test("撤销优先于「有购买」—— 退款后缓存里那条交易还可能躺一会儿")
    func revocationBeatsPurchase() {
        let inputs = EntitlementInputs(hasPurchase: true,
                                       purchasedAt: origin,
                                       revocation: .storeRevoked,
                                       now: days(30))
        let snapshot = LicenseResolver.resolve(inputs)

        #expect(snapshot.entitlement == .revoked(.storeRevoked))
        #expect(snapshot.blockedReason == .revoked(.storeRevoked))
        #expect(!snapshot.allowsProFeatures)
    }

    @Test("撤销只有两档，且它们的 rawValue 不撞")
    func revocationReasonsStayDistinct() {
        // ⚠️ 原先有三档（refunded / familySharingRevoked / purchaseNotFound）。
        // 2026-10-03 查证 StoreKit 之后合并成两档：`revocationReason` 只有
        // `.developerIssue` / `.other`，**退款与"被移出家人共享"落在同一档里**，
        // 假装能分开就等于给用户一句很确定但可能错的话。见 `RevocationReason` 的注释。
        let reasons: [RevocationReason] = [.storeRevoked, .purchaseNotFound]
        let got = reasons.map { reason in
            LicenseResolver.resolve(EntitlementInputs(revocation: reason, now: origin)).blockedReason
        }
        #expect(got == reasons.map(BlockedReason.revoked),
                "「商店说被撤了」与「商店里没有」是两件事，给的话术不一样")
        #expect(Set(reasons.map(\.rawValue)).count == reasons.count, "rawValue 撞了")
    }

    // MARK: - 试用

    @Test("试用第 1 天报 7 天，第 6 天报 1 天")
    func trialDaysLeft() {
        let start = origin
        #expect(LicenseResolver.resolve(trial(since: start, at: start)).entitlement == .trial(daysLeft: 7))
        #expect(LicenseResolver.resolve(trial(since: start, at: days(1))).entitlement == .trial(daysLeft: 6))
        #expect(LicenseResolver.resolve(trial(since: start, at: days(6))).entitlement == .trial(daysLeft: 1))
        #expect(LicenseResolver.resolve(trial(since: start, at: start)).allowsProFeatures)
    }

    @Test("满 7 天就结束 —— 边界是「剩 0」而不是「剩负」")
    func trialEndsExactlyAtDuration() {
        let justBefore = LicenseResolver.resolve(trial(since: origin, at: days(7).addingTimeInterval(-1)))
        #expect(justBefore.entitlement == .trial(daysLeft: 1), "还差 1 秒就报 1 天，不能说结束")

        let exactly = LicenseResolver.resolve(trial(since: origin, at: days(7)))
        #expect(exactly.entitlement == .free)
        #expect(exactly.blockedReason == .trialEnded)

        let past = LicenseResolver.resolve(trial(since: origin, at: days(30)))
        #expect(past.entitlement == .free)
        #expect(past.blockedReason == .trialEnded)
    }

    @Test("「试用结束」与「从未购买」是两个原因 —— 提示语不一样")
    func trialEndedDiffersFromNeverPurchased() {
        let afterTrial = LicenseResolver.resolve(trial(since: origin, at: days(10))).blockedReason
        let never = LicenseResolver.resolve(EntitlementInputs(now: origin)).blockedReason
        #expect(afterTrial == .trialEnded)
        #expect(never == .neverPurchased)
    }

    @Test("剩不到 1 天也报 1 天，不报 0 —— 那时还能用")
    func partialDayStillCounts() {
        let snapshot = LicenseResolver.resolve(trial(since: origin, at: days(6.8)))
        #expect(snapshot.entitlement == .trial(daysLeft: 1), "剩 0.2 天时说「还有 0 天」等于提前宣布结束")
    }

    @Test("系统时间被往回拨，也不能报出比试用期更长的天数")
    func clockSkewIsClamped() {
        // 装系统 / 改时区 / 手动改钟都会让 now 早于试用开始。
        // 不夹的话界面会出现"还有 9 天"，而我们从来没有 9 天的试用。
        let snapshot = LicenseResolver.resolve(trial(since: days(5), at: origin))
        #expect(snapshot.entitlement == .trial(daysLeft: TrialPolicy.durationDays))
    }

    @Test("「一天」是 86400 秒 —— 用自然日会让 23:59 开始试用的人两分钟后少一天")
    func dayLengthIsFixed() {
        #expect(TrialPolicy.duration == 7 * 86_400)

        // 剩 2 天整 → 2；多一秒 → 3
        let twoDays = LicenseResolver.resolve(trial(since: origin, at: days(5)))
        #expect(twoDays.entitlement == .trial(daysLeft: 2))
        let twoDaysPlus = LicenseResolver.resolve(trial(since: origin, at: days(5).addingTimeInterval(-1)))
        #expect(twoDaysPlus.entitlement == .trial(daysLeft: 3))
    }

    @Test("用过试用就不再开始第二次；已购买 / 已撤销也不行")
    func canStartTrial() {
        #expect(LicenseResolver.canStartTrial(EntitlementInputs(now: origin)))

        let used = trial(since: origin, at: days(10))
        #expect(!LicenseResolver.canStartTrial(used), "试用只能一次")
        #expect(!LicenseResolver.canStartTrial(purchased(origin)), "已经买了不需要试用")
        #expect(!LicenseResolver.canStartTrial(
            EntitlementInputs(revocation: .storeRevoked, now: origin)), "退款后不该白拿一次试用")
    }

    @Test("试用结束了也不能再开始一次")
    func trialIsSingleShot() {
        let ended = trial(since: origin, at: days(10))
        #expect(!LicenseResolver.canStartTrial(ended))
    }

    // MARK: - 免费额度

    @Test("免费版保留最近 5 张；Pro 与「还没查」都不设限")
    func historyLimit() {
        #expect(LicenseResolver.resolve(EntitlementInputs(now: origin)).historyLimit() == 5)
        #expect(LicenseResolver.resolve(purchased(origin)).historyLimit() == nil)
        #expect(LicenseResolver.resolve(trial(since: origin, at: origin)).historyLimit() == nil,
                "试用期是完整的 Pro，历史不该被截")
        // 「还没查」也必须不设限 —— 否则启动瞬间会**把老用户的历史删掉**，
        // 那是这一整套里唯一会真正丢数据的操作。
        #expect(LicenseResolver.resolve(.pending(now: origin)).historyLimit() == nil,
                "还没查就按免费版裁剪，等于启动时删掉付费用户的历史")
    }

    @Test("额度参数写 0 会被夹到 1 —— 「保留最近 0 张」就是删光用户的历史")
    func limitsAreClamped() {
        #expect(ProLimits(freeHistoryLimit: 0).freeHistoryLimit == 1)
        #expect(ProLimits(freeHistoryLimit: -3).freeHistoryLimit == 1)
        #expect(ProLimits(freeHistoryLimit: 12).freeHistoryLimit == 12)
    }

    // MARK: - 边界只在一处

    @Test("四项能力目前都归 Pro，且 access 与 allowsProFeatures 同源")
    func accessFollowsTheSingleSource() {
        let free = LicenseResolver.resolve(EntitlementInputs(now: origin))
        let pro = LicenseResolver.resolve(purchased(origin))
        let pending = LicenseResolver.resolve(.pending(now: origin))

        for feature in ProFeature.allCases {
            #expect(feature.requiresPro)
            #expect(!free.access(to: feature).isAllowed)
            #expect(pro.access(to: feature).isAllowed)
            // 「还没查」放行这一条必须同时体现在**每一项**能力上，
            // 而不是只在总开关上 —— 界面是按 feature 问的。
            #expect(pending.access(to: feature).isAllowed, "\(feature.rawValue) 在还没查时被锁了")
            #expect(free.access(to: feature).blockedReason == .neverPurchased)
        }

        #expect(free.access(to: .scrollCapture) == free.access,
                "两者必须同源，界面别自己去拼判据")
    }

    @Test("被挡住的原因与「总开关」一致")
    func blockedReasonMatchesGate() {
        let revoked = LicenseResolver.resolve(EntitlementInputs(revocation: .storeRevoked, now: origin))
        #expect(revoked.access(to: .pin).blockedReason == .revoked(.storeRevoked))
        #expect(!revoked.allowsProFeatures)
    }
}

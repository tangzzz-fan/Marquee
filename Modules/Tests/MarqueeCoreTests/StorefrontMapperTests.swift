import Foundation
import Testing

@testable import MarqueeCore

/// 商店事实 → 状态机输入（ticket 31）。
///
/// 这一套是 ticket 31 里**唯一能脱机测**的那一半，而它恰好是错得最贵的那一半：
/// 判错"这个人有没有买"会直接决定要不要给他上锁。
@Suite("商店映射（ticket 31）")
struct StorefrontMapperTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)
    private let pro = StoreCatalog.proProductIdentifier
    private let trial = StoreCatalog.trialProductIdentifier

    private func record(_ productID: String,
                        at date: Date,
                        revoked: Date? = nil,
                        verified: Bool = true) -> PurchaseRecord {
        PurchaseRecord(productIdentifier: productID,
                       purchaseDate: date,
                       revocationDate: revoked,
                       isVerified: verified)
    }

    private func snapshot(_ records: [PurchaseRecord],
                          cachedHadPurchase: Bool = false) -> StorefrontSnapshot {
        StorefrontSnapshot(records: records, cachedHadPurchase: cachedHadPurchase, now: origin)
    }

    // MARK: - 未校验的交易

    @Test("未校验的交易**一律不算数** —— 哪怕它是唯一的购买")
    func unverifiedNeverCounts() {
        let inputs = StorefrontMapper.inputs(from: snapshot([record(pro, at: origin, verified: false)]))

        #expect(!inputs.hasPurchase, "把 unverified 当作通过，等于把付费功能送给会伪造收据的人")
        #expect(inputs.revocation == nil, "未校验的交易连撤销判断都不该参与")
    }

    @Test("一条未校验、一条已校验 → 只认已校验那条")
    func verifiedWinsWhenBothPresent() {
        let inputs = StorefrontMapper.inputs(from: snapshot([
            record(pro, at: origin, verified: false),
            record(pro, at: origin.addingTimeInterval(60), verified: true),
        ]))

        #expect(inputs.hasPurchase)
        #expect(inputs.purchasedAt == origin.addingTimeInterval(60))
    }

    @Test("未校验的试用交易不消耗试用资格")
    func unverifiedTrialDoesNotCount() {
        let inputs = StorefrontMapper.inputs(from: snapshot([record(trial, at: origin, verified: false)]))
        #expect(!inputs.hasUsedTrial)
    }

    // MARK: - 有效购买

    @Test("有效购买 → hasPurchase，且没有撤销")
    func livePurchase() {
        let inputs = StorefrontMapper.inputs(from: snapshot([record(pro, at: origin)]))

        #expect(inputs.hasPurchase)
        #expect(inputs.purchasedAt == origin)
        #expect(inputs.revocation == nil)
        #expect(inputs.isResolved, "问过商店之后必须标记成「已查」，否则放行逻辑会一直兜着")
        #expect(LicenseResolver.resolve(inputs).allowsProFeatures)
    }

    @Test("别的商品的交易被忽略")
    func unrelatedProductsIgnored() {
        let inputs = StorefrontMapper.inputs(from: snapshot([
            record("com.tango.marquee.something-else", at: origin),
        ]))

        #expect(!inputs.hasPurchase)
        #expect(inputs.revocation == nil)
    }

    // MARK: - 撤销

    @Test("被撤销的购买 → .storeRevoked，且不再解锁")
    func revokedPurchase() {
        let inputs = StorefrontMapper.inputs(from: snapshot([
            record(pro, at: origin, revoked: origin.addingTimeInterval(86_400)),
        ]))

        #expect(!inputs.hasPurchase)
        #expect(inputs.revocation == .storeRevoked)
        #expect(!LicenseResolver.resolve(inputs).allowsProFeatures)
    }

    @Test("**撤销可以被撤销** —— 撤销字段没了就要恢复 Pro")
    func revocationIsReversible() {
        // Apple 文档：退款被撤回后，交易上的撤销字段会被移除、访问权限要恢复。
        // 所以同一笔交易在两个时刻会给出不同答案，而**判定必须跟着变** ——
        // 任何"一旦撤销就永久记一笔"的实现都会在这里失败。
        let revoked = StorefrontMapper.inputs(from: snapshot([
            record(pro, at: origin, revoked: origin.addingTimeInterval(60)),
        ]))
        let restored = StorefrontMapper.inputs(from: snapshot([record(pro, at: origin)]))

        #expect(revoked.revocation == .storeRevoked)
        #expect(restored.revocation == nil)
        #expect(restored.hasPurchase)
        #expect(LicenseResolver.resolve(restored).allowsProFeatures)
    }

    @Test("退款后又买了一次（一条撤销 + 一条有效）→ 仍然是 Pro")
    func rebuyAfterRefund() {
        let inputs = StorefrontMapper.inputs(from: snapshot([
            record(pro, at: origin, revoked: origin.addingTimeInterval(60)),
            record(pro, at: origin.addingTimeInterval(120)),
        ]))

        #expect(inputs.hasPurchase, "有效购买要压过旧的那条撤销记录")
        #expect(inputs.revocation == nil)
        #expect(inputs.purchasedAt == origin.addingTimeInterval(120))
    }

    @Test("商店里没有、但我们缓存过买过 → .purchaseNotFound（不是「从没买过」）")
    func purchaseNotFoundWhenCacheRemembers() {
        let inputs = StorefrontMapper.inputs(from: snapshot([], cachedHadPurchase: true))

        #expect(!inputs.hasPurchase)
        #expect(inputs.revocation == .purchaseNotFound)
    }

    @Test("商店里没有、缓存也没买过 → **不算撤销**（那是真正的「从没买过」）")
    func neverPurchasedIsNotRevocation() {
        let inputs = StorefrontMapper.inputs(from: snapshot([], cachedHadPurchase: false))

        #expect(inputs.revocation == nil)
        // 状态机自己会给出 `.neverPurchased`，映射层不该抢这个判断
        #expect(LicenseResolver.resolve(inputs).blockedReason == .neverPurchased)
    }

    @Test("撤销优先于「商店里没有」—— 商店明说被撤了，就别猜成收据丢了")
    func storeRevokedBeatsPurchaseNotFound() {
        let inputs = StorefrontMapper.inputs(from: snapshot(
            [record(pro, at: origin, revoked: origin.addingTimeInterval(60))],
            cachedHadPurchase: true))

        #expect(inputs.revocation == .storeRevoked)
    }

    // MARK: - 试用

    @Test("0 价试用交易 → hasUsedTrial，起点取**最早**那条")
    func trialRecords() {
        let inputs = StorefrontMapper.inputs(from: snapshot([
            record(trial, at: origin.addingTimeInterval(600)),
            record(trial, at: origin),
        ]))

        #expect(inputs.hasUsedTrial)
        #expect(inputs.trialStartedAt == origin, "取最早 = 起点，取最晚等于凭空延长试用")
    }

    @Test("**被撤销的试用交易也算用过** —— 退一次款不能白拿第二次试用")
    func revokedTrialStillCounts() {
        let inputs = StorefrontMapper.inputs(from: snapshot([
            record(trial, at: origin, revoked: origin.addingTimeInterval(60)),
        ]))

        #expect(inputs.hasUsedTrial)
        #expect(inputs.trialStartedAt == origin)
        #expect(!LicenseResolver.canStartTrial(inputs), "退过一次款就拿回试用资格，是白拿")
    }

    @Test("只有买断、没有试用交易 → 没试用过")
    func purchaseWithoutTrial() {
        let inputs = StorefrontMapper.inputs(from: snapshot([record(pro, at: origin)]))
        #expect(!inputs.hasUsedTrial)
        #expect(inputs.trialStartedAt == nil)
    }
}

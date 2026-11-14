import Foundation
import Testing

@testable import MarqueeCore

/// app 本体的购买事实（ticket 35）。
///
/// ## 这一套盯的是哪件事
///
/// app 从「付费下载」改成「免费 + 内购」之后，**已经花 ¥36 买过 app 的人**
/// 在 `Transaction.all` 里是**空的** —— 那里面只有 IAP 交易。
/// 照旧判就会把他锁在 Pro 外面，还给他看一句「升级到 Pro · ¥36」。
///
/// Apple 为此准备了 `AppTransaction.originalAppVersion`。这一套测的是
/// **拿到那个字符串之后怎么判**，全部脱机 —— 取值那一半只有真机跑得到。
@Suite("app 本体购买（ticket 35）")
struct AppPurchaseTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    private func purchase(version: String,
                          at date: Date? = nil,
                          verified: Bool = true) -> AppPurchaseRecord {
        AppPurchaseRecord(originalAppVersion: version,
                          originalPurchaseDate: date ?? origin,
                          isVerified: verified)
    }

    // MARK: - 版本比较

    /// ⚠️ Apple 官方 macOS 样例用的是 `originalMajorVersion < "2"` —— **字符串比较**。
    /// `"10" < "2"` 为真，于是到 10.x 时会把**新用户误判成老付费用户**（白送 Pro）。
    /// 这一组就是拦那种实现的。
    @Test("版本比较按**数值**，不是字符串 —— 10.0 不小于 2.0")
    func versionComparisonIsNumeric() {
        let cases: [(lhs: String, rhs: String, expected: Bool)] = [
            ("1.0", "2.0", true),
            ("1.1", "2.0", true),
            ("1.9.9", "2.0", true),
            ("1.99", "2.0", true),
            ("2.0", "2.0", false),
            ("2.0.0", "2.0", false),
            ("2.0.1", "2.0", false),
            ("2.1", "2.0", false),
            ("10.0", "2.0", false),
            ("3", "2.0", false),
            ("1", "2.0", true),
        ]
        for item in cases {
            #expect(AppVersion.isOrderedBefore(item.lhs, item.rhs) == item.expected,
                    "\(item.lhs) < \(item.rhs) 应当是 \(item.expected)")
        }
    }

    @Test("缺位补零：1 与 1.0.0 是同一个版本")
    func missingComponentsAreZero() {
        #expect(AppVersion.isOrderedBefore("1", "1.0.0") == false)
        #expect(AppVersion.isOrderedBefore("1.0.0", "1") == false)
        #expect(AppVersion.isOrderedBefore("1", "1.0.1") == true)
    }

    @Test("读不懂的版本 → nil，**不许**猜成「更老」")
    func unparsableVersionIsUnknown() {
        for version in ["", "abc", "1.x", ".1", "1..0", "  ", "v1.0", "1.0-beta"] {
            #expect(AppVersion.isOrderedBefore(version, "2.0") == nil,
                    "\(version) 解析失败当成「更老」＝ 把一个读不懂的字符串当成付费凭证")
        }
    }

    @Test("右侧读不懂时同样是 nil —— 分界常量写错也不许乱判")
    func unparsableBoundaryIsUnknown() {
        #expect(AppVersion.isOrderedBefore("1.0", "") == nil)
        #expect(AppVersion.isOrderedBefore("1.0", "two") == nil)
    }

    // MARK: - 分界常量

    @Test("分界常量是 2.0，且转免费那一版的营销版本号不小于它")
    func boundaryMatchesTheReleaseThatGoesFree() {
        #expect(BusinessModelChange.appVersion == "2.0")
        // 这一条把「常量」与「真的要发的那一版」连起来：常量改了却忘了抬版本号，
        // 会让**所有**老用户都判不出来（而它不报错，只是 everyone 变免费）。
        #expect(AppVersion.isOrderedBefore("2.0.0", BusinessModelChange.appVersion) == false)
    }

    /// `project.yml` 里的 `MARKETING_VERSION` 与分界常量**必须一致**。
    ///
    /// ## 为什么这条测试值钱（PITFALLS 134）
    ///
    /// 那两处是**两份独立的事实**：一个在 YAML 里、一个在 Swift 里，编译器不会替我们连。
    /// 而它们脱钩的两个方向都很贵：
    ///
    /// - 常量比发出去的版本**大**（比如常量写 3.0、实际发 2.0）⇒ 所有老用户都判不出来 ⇒
    ///   **每一个付过 ¥36 的人都被要求再付一次**；
    /// - 常量比发出去的版本**小** ⇒ 转免费之后下载的人被判成老用户 ⇒ 白送 Pro。
    ///
    /// 两个方向都不报错。真机沙盒也验不了这件事（沙盒里 `originalAppVersion` 恒为 `1.0`）。
    @Test("`project.yml` 的 MARKETING_VERSION 与分界常量一致")
    func marketingVersionMatchesTheBoundaryConstant() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MarqueeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // 仓库根
        let yaml = try String(contentsOf: root.appendingPathComponent("project.yml"),
                             encoding: .utf8)

        // 只取 `MARKETING_VERSION: "x"` 那一行。不引 YAML 解析器：
        // 为了一个字段引一整棵依赖，比这行正则在别处出错的风险更大。
        // 但必须**先证明真的读到了**，否则下面那句断言会对 nil 空跑通过（PITFALLS 128）。
        let value = yaml
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("MARKETING_VERSION:") else { return nil }
                return trimmed
                    .replacingOccurrences(of: "MARKETING_VERSION:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            .first

        let version = try #require(value, "project.yml 里没找到 MARKETING_VERSION —— 解析失败会让下面空跑")
        #expect(version == BusinessModelChange.appVersion,
                "两处脱钩：project.yml 发的是 \(version)，而判定用的分界是 \(BusinessModelChange.appVersion)")
    }

    // MARK: - 映射：谁是老付费用户

    @Test("转免费之前买过 app → 认作老付费用户，日期是**原始购买日**")
    func paidBeforeTheChangeIsLegacy() {
        for version in ["1.0", "1.1"] {
            let date = AppPurchaseMapper.legacyPaidPurchaseAt(from: purchase(version: version))
            #expect(date == origin,
                    "用 now 兜底会让老用户看到「今天购买」——一句可验证的假话")
        }
    }

    @Test("转免费之后才下载 → **不是**老付费用户")
    func downloadedAfterTheChangeIsNotLegacy() {
        for version in ["2.0", "2.0.0", "2.1", "10.0"] {
            #expect(AppPurchaseMapper.legacyPaidPurchaseAt(from: purchase(version: version)) == nil,
                    "\(version) 是转免费之后的版本，不该白送 Pro")
        }
    }

    @Test("未校验的 app transaction **一律不算数**")
    func unverifiedIsNeverLegacy() {
        #expect(AppPurchaseMapper.legacyPaidPurchaseAt(from: purchase(version: "1.0",
                                                                       verified: false)) == nil,
                "未校验的收据可以伪造 —— 与 IAP 那条 filter(\\.isVerified) 同一条规则")
    }

    @Test("读不懂的版本 → 不认作老用户（保守方向：让他走 IAP）")
    func unparsableVersionIsNotLegacy() {
        #expect(AppPurchaseMapper.legacyPaidPurchaseAt(from: purchase(version: "garbage")) == nil)
    }

    @Test("沙盒里 originalAppVersion 恒为 1.0 ⇒ 沙盒账号一律判成老用户")
    func sandboxAlwaysLooksLegacy() {
        // Apple 文档原文：In the sandbox testing environment, the originalAppVersion
        // value is always `1.0`. 这不是 bug，而是这条路**能在沙盒里验**的原因。
        #expect(AppPurchaseMapper.legacyPaidPurchaseAt(from: purchase(version: "1.0")) == origin)
    }
}

// MARK: - 判定：legacy 在状态机里的位置

/// legacy 与撤销、IAP、试用之间的**顺序**（ticket 35）。
///
/// 顺序就是语义。这一套里最贵的一条是「legacy 压过 purchaseNotFound」——
/// 写错的后果不是少收一次钱，而是**让一个已经付过 ¥36 的人再付一次**。
@Suite("legacy 判定顺序（ticket 35）")
struct LegacyEntitlementTests {

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)
    private let later = Date(timeIntervalSince1970: 1_760_000_000 + 86_400 * 30)

    private func legacy(_ inputs: EntitlementInputs) -> EntitlementInputs {
        var value = inputs
        value.legacyPaidPurchaseAt = origin
        return value
    }

    @Test("**头号断言**：legacy 压过 purchaseNotFound —— 商店没有 IAP 交易不代表他没付过钱")
    func legacyBeatsPurchaseNotFound() {
        // 这正是老付费用户的真实输入：Transaction.all 是空的（app 本体的购买不在里面），
        // 而我们缓存过"有购买" ⇒ StorefrontMapper 会给出 .purchaseNotFound。
        let inputs = legacy(EntitlementInputs(hasPurchase: false,
                                              revocation: .purchaseNotFound,
                                              now: later))

        let snapshot = LicenseResolver.resolve(inputs)

        #expect(snapshot.entitlement == .pro(purchasedAt: origin),
                "判成 revoked 比不认 legacy 还糟：界面会说「购买已撤销」并要他再买一次")
        #expect(snapshot.allowsProFeatures)
        #expect(snapshot.blockedReason == nil)
    }

    @Test("legacy 压过 storeRevoked —— app 本体的购买与 IAP 的退款是**两笔交易**")
    func legacyBeatsStoreRevoked() {
        // 用户退了 Pro 的 IAP，不该丢掉他当初买 app 得来的权益。
        let inputs = legacy(EntitlementInputs(hasPurchase: false,
                                              revocation: .storeRevoked,
                                              now: later))

        let snapshot = LicenseResolver.resolve(inputs)

        #expect(snapshot.entitlement == .pro(purchasedAt: origin))
        #expect(snapshot.allowsProFeatures)
    }

    @Test("legacy 的购买日是**原始购买日**，不是「现在」")
    func legacyUsesOriginalPurchaseDate() {
        let snapshot = LicenseResolver.resolve(legacy(EntitlementInputs(now: later)))

        #expect(snapshot.entitlement == .pro(purchasedAt: origin))
        #expect(snapshot.entitlement.isPurchased, "界面上应当是「已购买」，不是试用")
    }

    @Test("legacy 用户**不能**开始试用 —— 他已经付过钱了")
    func legacyCannotStartTrial() {
        let snapshot = LicenseResolver.resolve(legacy(EntitlementInputs(now: later)))

        #expect(!snapshot.canStartTrial,
                "给付过钱的人显示「7 天免费试用」，他会去买一个自己已有的东西")
        #expect(!snapshot.entitlement.allowsUpgradePurchase, "按钮该是「已购买」")
    }

    @Test("legacy **永不过期** —— 十年后仍是 Pro")
    func legacyNeverExpires() {
        for years in [1.0, 10.0] {
            let now = origin.addingTimeInterval(86_400 * 365 * years)
            var inputs = EntitlementInputs(now: now)
            inputs.legacyPaidPurchaseAt = origin
            #expect(LicenseResolver.resolve(inputs).entitlement == .pro(purchasedAt: origin))
        }
    }

    @Test("还没查时 legacy 不改变 unknown —— 放行规则不受影响")
    func pendingStaysUnknownEvenWithLegacy() {
        var inputs = EntitlementInputs.pending(now: origin)
        inputs.legacyPaidPurchaseAt = origin

        let snapshot = LicenseResolver.resolve(inputs)

        #expect(snapshot.entitlement == .unknown)
        #expect(snapshot.allowsProFeatures)
    }

    @Test("没有 legacy 时，撤销仍然压过一切 —— 新判据不许放宽旧规则")
    func withoutLegacyRevocationStillWins() {
        for reason in RevocationReason.allCases {
            let inputs = EntitlementInputs(hasPurchase: true,
                                           purchasedAt: origin,
                                           revocation: reason,
                                           now: later)
            let snapshot = LicenseResolver.resolve(inputs)
            #expect(snapshot.entitlement == .revoked(reason))
            #expect(!snapshot.allowsProFeatures)
        }
    }

    @Test("没有 legacy 时，免费用户仍是免费 —— 新字段默认值不许改变现状")
    func withoutLegacyNothingChanges() {
        let snapshot = LicenseResolver.resolve(EntitlementInputs(now: later))

        #expect(snapshot.entitlement == .free)
        #expect(snapshot.blockedReason == .neverPurchased)
        #expect(snapshot.canStartTrial)
    }

    @Test("legacy 与 IAP 同时存在 → 用 **IAP** 的购买日（那是更晚、更具体的一笔）")
    func iapDateWinsWhenBothExist() {
        var inputs = EntitlementInputs(hasPurchase: true, purchasedAt: later, now: later)
        inputs.legacyPaidPurchaseAt = origin

        let snapshot = LicenseResolver.resolve(inputs)

        #expect(snapshot.entitlement == .pro(purchasedAt: later))
    }

    @Test("四项 Pro 能力对 legacy 用户全部放行")
    func legacyUnlocksEveryProFeature() {
        let snapshot = LicenseResolver.resolve(legacy(EntitlementInputs(now: later)))

        for feature in ProFeature.allCases {
            #expect(snapshot.access(to: feature).isAllowed, "\(feature) 应当对老付费用户放行")
        }
        #expect(snapshot.historyLimit() == nil, "最近截图也该不设上限")
    }
}
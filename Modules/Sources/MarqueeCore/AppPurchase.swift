import Foundation

// MARK: - app 本体的购买事实

/// **app 本体**（不是内购）的那一次购买（ticket 35）。
///
/// ## 为什么需要它 —— 一个只有真实用户才会撞上的洞
///
/// app 从「付费下载」改成「免费 + 内购」之后，**已经花钱买过 app 的人**在
/// `Transaction.all` 里是**空的**：那个序列只含内购交易，不含 app 本体的购买。
/// 照旧判就会把他锁在 Pro 外面，还给他看一句「升级到 Pro · ¥36」——
/// **让他为同一个东西付第二次钱**。
///
/// Apple 为此准备了 `AppTransaction`（见《Supporting business model changes by
/// using the app transaction》）。这里只留判定真正要用的三个字段 ——
/// 与 `PurchaseRecord` 同一条做法：**不直接用 StoreKit 的类型**，
/// 否则"哪些字段算数"这条规则就绑在只有真机才跑得起来的东西上。
public struct AppPurchaseRecord: Equatable, Sendable {

    /// 用户**最初**买到的那一版。
    ///
    /// ⚠️ macOS 上它是 `CFBundleShortVersionString`（营销版本号，如 `1.1`），
    /// **不是** build 号 —— iOS 才是 `CFBundleVersion`。Apple 文档原文写明了这个差别。
    /// 拿 build 号的规则去比 macOS 的值，会把所有人都判错。
    ///
    /// 它**不随升级改变**：这正是"最初买的是哪一版"能被问出来的原因。
    public var originalAppVersion: String

    /// 最初那次购买的时间。界面上「已购买 · 某日」用的就是它。
    public var originalPurchaseDate: Date

    /// 签名校验是否通过。
    ///
    /// ⚠️ `false` 一律不算数 —— 与 `PurchaseRecord.isVerified` 同一条规则。
    /// 未校验的收据可以伪造，"宽容地当作通过"会把付费功能送给会伪造的人。
    public var isVerified: Bool

    public init(originalAppVersion: String,
                originalPurchaseDate: Date,
                isVerified: Bool = true) {
        self.originalAppVersion = originalAppVersion
        self.originalPurchaseDate = originalPurchaseDate
        self.isVerified = isVerified
    }
}

// MARK: - 商业模式的分界线

/// 「哪一版开始改成免费 + 内购」。
public enum BusinessModelChange {

    /// 转免费那一版的营销版本号。
    ///
    /// ## 这个数字为什么是 2.0
    ///
    /// 1.0 轨道已关闭、1.1 已上架（付费下载）。转免费必须发一版新的 ⇒ **2.0.0**。
    /// 早于它的 `originalAppVersion`（`1.0` / `1.1`）就是**付过钱的老用户**。
    ///
    /// ⚠️ 改这个常量必须同时改 `project.yml` 的 `MARKETING_VERSION` ——
    /// 两者脱钩的后果是**所有老用户都判不出来**，而它不报错，只是 everyone 变免费。
    /// 有一条测试把两者连起来（`boundaryMatchesTheReleaseThatGoesFree`）。
    ///
    /// ⚠️ 沙盒环境里 `originalAppVersion` **恒为 `1.0`**（Apple 文档原文）⇒
    /// 沙盒账号一律被判成老用户。这**不是 bug**，而是这条路能在沙盒里验的原因。
    public static let appVersion = "2.0"
}

// MARK: - 版本比较

/// 营销版本号的大小比较。
///
/// ## 为什么不直接用字符串比
///
/// Apple 官方 macOS 样例里写的是 `originalMajorVersion < newBusinessModelMajorVersion`
/// —— **字符串比较**。`"10" < "2"` 为真，于是到了 10.x，
/// **新用户会被误判成老付费用户**（白送 Pro）。样例只演示思路，那一句不能照抄。
public enum AppVersion {

    /// `lhs` 是否**严格早于** `rhs`。
    ///
    /// 返回 `nil` = **读不懂**（任一侧解析失败）。
    ///
    /// ⚠️ 读不懂**不许**猜成"更老"：那等于把一个解析失败的字符串当成付费凭证。
    /// 方向是保守的 —— 宁可让他走内购那条路，也不白送。
    ///
    /// 缺位补零：`1` 与 `1.0.0` 是同一个版本。
    public static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool? {
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// 切成数字段。**任何一段不是纯数字就整体作废。**
    ///
    /// 不用 `Int(...)` 的宽容解析：`Int(" 1")` 是 nil 但 `Int("+1")` 是 1，
    /// 而 `1.0-beta` 这种形状不该被"尽力解析"成 1.0 —— 那不是 Apple 会给的值，
    /// 出现了就说明我们对这个字段的理解错了，此时**不作判断**比猜一个更安全。
    private static func components(_ version: String) -> [Int]? {
        guard !version.isEmpty else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }
}

private extension Character {
    /// 只认 ASCII 的 0-9。
    ///
    /// `isNumber` 会放行全角数字与其它书写系统的数字 —— 那些不该出现在版本号里，
    /// 而 `Int("１")` 恰好也能解析成功，于是"看起来严格"的检查其实漏了一类输入。
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - 映射

/// app 本体的购买事实 → 「是不是老付费用户」。**纯函数。**
///
/// 判断放在这里的理由与 `StorefrontMapper` 完全一致：适配器只翻译事实，
/// **规则留在能脱机单测的那一侧**（PITFALLS 130）。
/// 让适配器直接返回一个 `isLegacyPaidUser: Bool` 就等于把这条规则挪进只有真机才跑得到的地方。
public enum AppPurchaseMapper {

    /// 老付费用户的**原始购买日**；`nil` = 不是（或读不懂）。
    ///
    /// ## 为什么返回日期而不是布尔
    ///
    /// `.pro(purchasedAt:)` 需要一个日期，界面会显示它。用"现在"兜底会让一个
    /// 2026 年买的人看到「今天购买」——**一句可验证的假话**。
    /// 而缓存也该存**事实**（原始购买日）而不是结论，规则改了还能重算。
    ///
    /// ⚠️ 这里的 `nil` 只表示「**取到了**、但不足以认作老用户」。
    /// 「**没取到**」是另一件事，由 `EntitlementCoordinator` 处理（保留已知值）——
    /// 两者混成一档，一次断网就能把老用户永久降级（PITFALLS 126 同型）。
    public static func legacyPaidPurchaseAt(from record: AppPurchaseRecord) -> Date? {
        guard record.isVerified else { return nil }
        guard AppVersion.isOrderedBefore(record.originalAppVersion,
                                         BusinessModelChange.appVersion) == true else { return nil }
        return record.originalPurchaseDate
    }
}
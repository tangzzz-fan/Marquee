import Foundation

/// 权益的本地缓存（ticket 31）。
///
/// ## 为什么必须有
///
/// 启动时**不能等商店回话**：那等于"断网时付费用户被锁在外面"。
/// 正确的顺序是：读缓存 → **立刻**按缓存判定（`isResolved = true`）→ 后台再核实 →
/// 有变化才改。这与 `LicenseResolver` 里"`unknown` 必须放行"是同一条原则。
///
/// ## 为什么缓存的是**输入**，不是判定结果
///
/// 判定规则还会改（比如 ticket 31 就把 `RevocationReason` 从三档改成了两档）。
/// 存结果的话，改一次规则就得指望"用户下次联网时被刷新到"，而某些用户可能半年不联网。
/// 存的若是**事实**（商店说了什么），规则怎么改都能重算出来。
///
/// ## 缓存的作用域
///
/// 落到 `UserDefaults.standard`，而它的域**就是 bundle id** ——
/// 于是开发版与正式版各存各的（这正是 ticket 31 第 0 步把两个 id 分开的收益之一）。
public protocol EntitlementCaching: Sendable {
    func load() -> EntitlementInputs?
    func save(_ inputs: EntitlementInputs)
    func clear()
}

/// 内存实现：给测试与预览用。
public final class InMemoryEntitlementCache: EntitlementCaching, @unchecked Sendable {

    private var stored: EntitlementInputs?
    private let lock = NSLock()

    public init(_ initial: EntitlementInputs? = nil) { stored = initial }

    public func load() -> EntitlementInputs? {
        lock.lock(); defer { lock.unlock() }
        guard var value = stored else { return nil }
        // 与落盘实现保持一致：`now` 永远是**读的那一刻**，不是写的那一刻。
        value.now = Date()
        return value
    }

    public func save(_ inputs: EntitlementInputs) {
        lock.lock(); defer { lock.unlock() }
        // 与落盘实现**同一条规则**：不许缓存「还没查」。
        // 两个实现分叉过一次（这里原来是无条件覆盖），是测试把差异抓出来的 ——
        // 而"内存里对、盘上不对"这种分叉只会在真机上现形。
        guard inputs.isResolved else { return }
        stored = inputs
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}

/// 落盘实现。
public struct UserDefaultsEntitlementCache: EntitlementCaching, @unchecked Sendable {

    /// 存成一个 JSON `Data` 而不是散着几个 key：
    /// 将来加字段（比如试用商品 id 变了）时，旧数据会**整体解析失败**并退回"没有缓存"，
    /// 而不是"一半新一半旧"那种更难查的状态。
    private static let storageKey = "pro.entitlementCache"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> EntitlementInputs? {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        return stored.inputs(now: Date())
    }

    public func save(_ inputs: EntitlementInputs) {
        // ⚠️「还没查」**不允许**被缓存。
        // 存了它，下次开机读回来就是 `isResolved = true` ——
        // 于是"其实还不知道"被伪装成了"查过了、什么都没有"，
        // 付费用户会在启动瞬间被当成免费（而 `.unknown` 的放行规则正是为避免这个）。
        guard inputs.isResolved else { return }
        guard let data = try? JSONEncoder().encode(Stored(inputs)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// 落盘形状。**刻意与 `EntitlementInputs` 分开**：
    /// 那个类型是内存里的值，这个是磁盘上的契约，两者生命周期不一样
    /// （磁盘契约改了就要考虑兼容，内存类型随便改）。
    private struct Stored: Codable {
        var hasPurchase: Bool
        var purchasedAt: Date?
        var revocation: String?
        var trialStartedAt: Date?
        var hasUsedTrial: Bool

        init(_ inputs: EntitlementInputs) {
            hasPurchase = inputs.hasPurchase
            purchasedAt = inputs.purchasedAt
            revocation = inputs.revocation?.rawValue
            trialStartedAt = inputs.trialStartedAt
            hasUsedTrial = inputs.hasUsedTrial
        }

        func inputs(now: Date) -> EntitlementInputs {
            EntitlementInputs(isResolved: true,
                              hasPurchase: hasPurchase,
                              purchasedAt: purchasedAt,
                              // 认不出来的 rawValue 当成"没有撤销"而不是"被撤销"：
                              // 宁可少收一次，不可错拦一次。
                              revocation: revocation.flatMap(RevocationReason.init(rawValue:)),
                              trialStartedAt: trialStartedAt,
                              hasUsedTrial: hasUsedTrial,
                              now: now)
        }
    }
}

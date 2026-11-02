import Foundation

// MARK: - 哪些项参与

extension ProFeature {

    /// 这一项参不参与「每项 3 天体验」。
    ///
    /// ## 为什么不是四项都参与
    ///
    /// 体验的起点是**用户第一次使用的那一刻**。前三项都有明确入口（菜单项 / 工具条两格），
    /// 点下去就是他自己的动作；而「最近截图不限量」是**数量上限**，没有入口 ——
    /// 用户截到第 6 张时才发现能存更多，他不会认为「我开始体验了」，
    /// 只会觉得「怎么突然变化了」。
    ///
    /// 所以它不参与：免费版永远是 5 张。`FeatureTrialLedger` 问它会得到 `.ended`。
    ///
    /// `switch` 是穷尽的 —— 将来加新能力却不做这个决定，编译就过不去。
    public var supportsFeatureTrial: Bool {
        switch self {
        case .scrollCapture, .textRecognition, .pin: true
        case .unlimitedHistory: false
        }
    }
}

// MARK: - 时长

/// 每项体验的时长。
///
/// 与 `TrialPolicy`（整包 7 天试用）是**两件事**，不要合并：那个走 0 价 IAP、
/// 由 Apple 记账，起点是交易时间；这个纯本地，起点是用户第一次使用那一刻。
public struct FeatureTrialPolicy: Equatable, Sendable {

    /// 时长（天）。**下限夹到 1** —— 写 0 会让「一用就结束」，
    /// 那等于把功能关掉，却长得像一个 bug。与 `ProLimits` 同一条理由。
    public var durationDays: Int

    public init(durationDays: Int = 3) {
        self.durationDays = max(1, durationDays)
    }

    public var duration: TimeInterval { Double(durationDays) * TrialPolicy.secondsPerDay }

    public static let `default` = FeatureTrialPolicy()
}

// MARK: - 状态

/// 某一项此刻处在体验的哪一段。
public enum FeatureTrialState: Equatable, Sendable {
    /// 还没用过。**这一刻就是起点** —— 入口放行并记账。
    case notStarted
    case active(daysLeft: Int)
    /// 窗口已过。**不参与体验的能力永远落这一档**（见 `state(of:at:)`）。
    case ended
}

// MARK: - 账本

/// 每项能力各自一条记录：**第一次被使用**的时刻。
///
/// ## 为什么记时刻，不记「还剩几次」
///
/// 次数制要回答「什么算用掉一次」—— 点进覆盖层又 `Esc` 算不算？
/// 答错的代价是用户觉得被坑，而答对需要把埋点铺到每条流程的末尾。
/// 记时刻没有这个问题：窗口一旦打开就是 3 天，用户自己决定怎么用。
///
/// ## 为什么不记「已经结束」
///
/// 与 `EntitlementCache` 同一条：存**事实**（什么时候开始的），
/// 不存结论（还剩几天）。规则改了，旧数据能重算；存结论就只能等它自然过期。
public struct FeatureTrialLedger: Equatable, Sendable {

    public private(set) var firstUsedAt: [ProFeature: Date]

    private let policy: FeatureTrialPolicy

    public init(policy: FeatureTrialPolicy = .default,
                firstUsedAt: [ProFeature: Date] = [:]) {
        self.policy = policy
        self.firstUsedAt = firstUsedAt
    }

    public var isEmpty: Bool { firstUsedAt.isEmpty }

    /// 这一项此刻能不能用。
    ///
    /// - 不参与体验的能力 → `.ended`。这是**故意**的：`unlimitedHistory` 没有入口，
    ///   用户截到第 6 张时不会知道自己「开始体验了」；让它去谈体验只会变成
    ///   「怎么突然能存更多了」。于是它永远落 `.ended`，免费版永远是 5 张。
    /// - 时间被往回拨时 `remaining` 会大于整个时长，**先夹再转**：
    ///   `Int(Double)` 对超范围的值是陷阱（直接崩）。
    public func state(of feature: ProFeature, at now: Date) -> FeatureTrialState {
        guard feature.supportsFeatureTrial else { return .ended }
        guard let start = firstUsedAt[feature] else { return .notStarted }

        let remaining = policy.duration - now.timeIntervalSince(start)
        guard remaining > 0 else { return .ended }
        return .active(daysLeft: Self.daysLeft(from: remaining, limit: policy.duration))
    }

    /// 记下第一次使用。**已经记过就不动** —— 否则用户每用一次就续期 3 天，
    /// 等于永久免费，而它看起来只是「账本更新了一下」。
    public mutating func markFirstUse(_ feature: ProFeature, at now: Date) {
        guard feature.supportsFeatureTrial else { return }
        guard firstUsedAt[feature] == nil else { return }
        firstUsedAt[feature] = now
    }

    /// 剩余天数，向上取整。
    ///
    /// 与 `LicenseResolver` 里那条同源（都是 `ceil`）：剩 0.2 天报 1 天，
    /// 说「还有 0 天」等于提前宣布结束。
    static func daysLeft(from remaining: TimeInterval, limit: TimeInterval) -> Int {
        let clamped = min(remaining, limit)
        return Int(ceil(clamped / TrialPolicy.secondsPerDay))
    }
}

// MARK: - 存储

/// 账本的落点。与 `EntitlementCaching` 同一条接缝形状：协议在 Core，实现可换。
public protocol FeatureTrialStoring: Sendable {
    func load() -> FeatureTrialLedger
    func save(_ ledger: FeatureTrialLedger)
}

/// 落盘实现。`UserDefaults.standard` 的域就是 bundle id，
/// 于是开发版与正式版各存各的。
public struct UserDefaultsFeatureTrialStore: FeatureTrialStoring, @unchecked Sendable {

    private static let storageKey = "pro.featureTrial"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> FeatureTrialLedger {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return FeatureTrialLedger()
        }
        var firstUsedAt: [ProFeature: Date] = [:]
        for (name, seconds) in stored.firstUsedAt {
            guard let feature = ProFeature(rawValue: name) else { continue }
            firstUsedAt[feature] = Date(timeIntervalSince1970: seconds)
        }
        return FeatureTrialLedger(firstUsedAt: firstUsedAt)
    }

    public func save(_ ledger: FeatureTrialLedger) {
        var firstUsedAt: [String: Double] = [:]
        for (feature, date) in ledger.firstUsedAt {
            firstUsedAt[feature.rawValue] = date.timeIntervalSince1970
        }
        guard let data = try? JSONEncoder().encode(Stored(firstUsedAt: firstUsedAt)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// 落盘形状。时刻存 1970 起的秒数（不是 `Date` 默认的 2001 纪元）——
    /// 那个数字换一个工具读就不认识了，而排障时总要有人去翻它。
    private struct Stored: Codable {
        var firstUsedAt: [String: Double]
    }
}

/// 内存实现：给测试与预览用。
public final class InMemoryFeatureTrialStore: FeatureTrialStoring, @unchecked Sendable {

    private var stored: FeatureTrialLedger
    private let lock = NSLock()

    public init(_ initial: FeatureTrialLedger = FeatureTrialLedger()) {
        stored = initial
    }

    public func load() -> FeatureTrialLedger {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ ledger: FeatureTrialLedger) {
        lock.lock(); defer { lock.unlock() }
        stored = ledger
    }
}

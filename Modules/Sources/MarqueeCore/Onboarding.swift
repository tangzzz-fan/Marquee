import Foundation

/// 「第一次安装启动」的引导（ticket 34）。
///
/// ## 它要补的是哪一句话
///
/// 这个 app **没有主窗口** —— 装完之后它只是菜单栏上的一个图标。
/// 第一次用的人面对的是一个"什么都没发生"的桌面，而唯一的入口是一个
/// **默认快捷键**（`⌃Q`）。引导就是补上"它是什么、怎么触发、键在哪改"的地方。
///
/// ## 为什么状态不放进 `GeneralPreferences`
///
/// 那一份是用户能在设置里改的**偏好**，而这是"走过一次就不再出现"的
/// **一次性状态**。混在一起的代价很具体：将来给通用页加个「恢复默认」，
/// 就会把它一并清掉、引导再弹一次 —— 而用户会觉得"这软件怎么老弹这个"。
public enum OnboardingGate {

    /// 这次启动该不该弹引导。
    ///
    /// ⚠️ **带 `-marquee` 开关的自检运行一律不弹。** 那些入口
    /// （`-marqueeEntitlement`、`-marqueeRequestPermission`）是脚本从终端调的，
    /// 弹一个要人点的窗口会让它们**永远等不到退出** —— 而验权限、跑内购自检时
    /// 正是这么调的。这一条不写出来的话，表现是"自检命令挂住不动"，
    /// 而没人会去怀疑引导窗口。
    public static func shouldPresent(hasCompleted: Bool,
                                     arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard !hasCompleted else { return false }
        return !arguments.contains { $0.hasPrefix("-marquee") }
    }
}

/// 引导状态的读写。
///
/// 与 `UserDefaultsPreferencesStore` 同一个套路（键是常量、读写直连 `UserDefaults`），
/// 但**刻意不并进那一份**：理由见 `OnboardingGate` 的文档。
public struct OnboardingState: @unchecked Sendable {

    /// 键。与偏好那一组分开命名（`onboarding.` 前缀），一眼能看出它不是偏好。
    public static let completedKey = "onboarding.completed"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasCompleted: Bool {
        get { defaults.bool(forKey: Self.completedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.completedKey) }
    }
}

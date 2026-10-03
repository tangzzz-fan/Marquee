import Foundation

/// 自动滚动能不能用。
///
/// ## 为什么要单独一个类型
///
/// 「能不能自动滚动」的两个来源**互不相干**：**沙盒**（App Store 版根本做不到）
/// 与**授权**（用户还没在辅助功能里勾上）。它们必须给出**完全不同**的话：
///
/// | 原因 | 该说的话 |
/// | --- | --- |
/// | 沙盒 | "这个版本不提供该能力" —— 让他别再找了 |
/// | 没授权 | "去系统设置 → 隐私与安全性 → 辅助功能勾一下" —— 给他一条能走通的路 |
///
/// **说反了，就是把用户送去做一件注定没用的事**：沙盒里那个权限勾上也没用，
/// 而他会以为是"权限没生效"，转去怀疑系统。
///
/// 判据放 Core（不放在覆盖层里）的理由与 `LicenseResolver` 同一条：
/// 这是纯函数，能脱机把四种组合都跑一遍；而它在真机上要造出"沙盒"这个条件
/// 才能测一次。
public enum AutoScrollGate: Equatable, Sendable {

    /// 可以（尝试）开始自动滚动。
    case allowed
    /// 沙盒里做不到 —— **连问都不要问**。
    case unavailableInSandbox
    /// 能问，但用户还没授权。调用方应当去申请一次；申请失败再取文案。
    case needsPermission

    /// 判据。
    ///
    /// ⚠️ **沙盒优先**。顺序反过来的话（先问授权）会先弹一个"去系统设置勾一下"
    /// 的提示 —— 而那件事在沙盒里做了也没用。
    public static func evaluate(isSandboxed: Bool, permissionGranted: Bool) -> AutoScrollGate {
        if isSandboxed { return .unavailableInSandbox }
        if !permissionGranted { return .needsPermission }
        return .allowed
    }

    /// 被挡住时该说的那句话；`allowed` 时是 `nil`。
    ///
    /// 两句都保留"手动模式照旧可用"那一半 —— 自动滚动从来不是"没有它就不能用"，
    /// 不写明的话用户会以为整条长截图链路坏了。
    public static func blockedMessage(for gate: AutoScrollGate) -> String? {
        switch gate {
        case .allowed:
            return nil

        case .unavailableInSandbox:
            // ⚠️ **不许提「辅助功能」授权** —— 提了就是骗人。
            return L10n.t("这个版本不提供自动滚动：沙盒不允许代替你操作别的应用。")
                + L10n.t("自己滚一样能拼长图 —— 手动模式没受影响")

        case .needsPermission:
            return L10n.t("自动滚动需要「辅助功能」授权（系统设置 → 隐私与安全性 → 辅助功能）。")
                + L10n.t("也可以自己滚 —— 手动模式一样能拼长图")
        }
    }
}

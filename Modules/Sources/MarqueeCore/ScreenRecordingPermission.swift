import Foundation

// MARK: - 屏幕录制权限

/// 屏幕录制（TCC）授权状态。
///
/// 这里比 `CGPreflightScreenCaptureAccess()` 的布尔返回值多了一档。
/// `.denied` 可以是进程内记忆（「这次已经问过系统」），**不能**写到 UserDefaults：
/// 签名身份一变 TCC 重置而标记还在，会把用户永久锁死（2026-09-30 实测踩到）。
public enum ScreenRecordingPermission: Equatable, Sendable {
    /// 已授权，可以直接采集
    case granted
    /// 已明确被拒绝，或本进程已经问过系统、再问也不会再弹框。
    /// 真实探针在「本次进程已经 `requestPermission()` 过、preflight 仍为 false」时给出这一档。
    case denied
    /// 尚未确定 —— 应当去走一次系统授权流程
    case notDetermined
}

/// 权限探针。抽成协议是为了让"权限状态 → 走哪条分支"这件事能脱离真实 TCC 单测。
public protocol ScreenRecordingPermissionProbing: Sendable {
    /// 当前权限状态，**不**弹任何系统框
    func currentPermission() -> ScreenRecordingPermission

    /// 触发系统授权流程，返回结束后是否已获得授权。
    ///
    /// ⚠️ 实现必须同时满足：
    ///
    /// 1. **真的碰一次采集 API**。macOS 只在应用调用采集 API 时才把它登记进
    ///    「系统设置 → 隐私与安全性 → 屏幕录制」列表。只要不碰，列表里就永远没有这个应用 ——
    ///    用户翻遍系统设置也找不到可勾选的行，于是**永远授权不了**（2026-09-30 实测踩到）。
    ///    碰一次 `SCShareableContent` 枚举就够了；**不要**在这里再截一帧，
    ///    `SCScreenshotManager.captureImage` 会再弹一张系统授权框。
    /// 2. 调 `CGRequestScreenCaptureAccess()` 拿到权威结论。被拒绝过的进程调用它不会弹框、
    ///    直接返回 false。
    /// 3. **同一进程只走一次系统弹框**。`requestPermission()` 返回 false 之后，
    ///    `currentPermission()` 不得再报 `.notDetermined`，否则每次按快捷键都会
    ///    再进这一支、再弹系统框（macOS 15+ 上 `CGPreflightScreenCaptureAccess()`
    ///    在重启前会一直是 false，即使用户已经去系统设置里勾过）。
    ///    这是进程内记忆，**不要**写到 UserDefaults —— 签名身份一变会把人永久锁死。
    ///
    /// 因为要碰异步的采集 API，这个方法是 `async` 的。
    @discardableResult
    func requestPermission() async -> Bool
}

// MARK: - 权限门

/// 按下快捷键之后该走哪条路。
public enum CaptureGateDecision: Hashable, Sendable {
    /// 放行，直接采集
    case proceed
    /// 弹一次系统请求框（仅"从未询问过"时才有意义）
    case requestSystemPrompt
    /// 系统不会再弹框了，只能给用户说明 + 跳到系统设置
    case guideToSystemSettings
}

/// 权限门：把权限状态翻译成动作。
///
/// 单独抽成无状态函数的理由：这是 ticket 02 里**唯一**能自动化验证的关键判定，
/// 也是最容易被写成"权限不对时静默返回"的地方。
/// 见 `.scratch/issues/2026-09-30-marquee-mvp/02-fullscreen-to-clipboard.md` 的验收标准。
public enum CaptureGate {
    public static func decision(for permission: ScreenRecordingPermission) -> CaptureGateDecision {
        switch permission {
        case .granted: .proceed
        case .notDetermined: .requestSystemPrompt
        case .denied: .guideToSystemSettings
        }
    }
}

// MARK: - 全局快捷键注册结果

/// 快捷键注册结果。
///
/// 单独建模而不是直接抛 `OSStatus`：`-9878` 这种数字对上层毫无意义，
/// 而"被别的应用占了"是一个需要**给用户提示**的独立分支。
public enum HotKeyRegistrationOutcome: Equatable, Sendable {
    case registered
    /// 该组合已被占用（`eventHotKeyExistsErr`）
    case conflict
    case failed(status: Int32)
}

extension HotKeyRegistrationOutcome {
    /// Carbon `eventHotKeyExistsErr` 的数值。
    ///
    /// 写死常量而不是 `import Carbon`：Core 层不引入平台头文件。
    /// 数值由 `docs/SPIKE-PLAN.md` G2 实测确认（重复注册返回 -9878）。
    public static let hotKeyExistsStatus: Int32 = -9878

    /// 把 Carbon 的 `OSStatus` 翻译成语义结果。
    public static func from(status: Int32) -> HotKeyRegistrationOutcome {
        if status == 0 { return .registered }
        if status == hotKeyExistsStatus { return .conflict }
        return .failed(status: status)
    }
}

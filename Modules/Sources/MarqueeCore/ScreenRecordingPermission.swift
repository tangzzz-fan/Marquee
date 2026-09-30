import Foundation

// MARK: - 屏幕录制权限

/// 屏幕录制（TCC）授权状态。
///
/// 注意这里比 `CGPreflightScreenCaptureAccess()` 的布尔返回值多了一档：
/// 系统 API 只能回答"现在有没有权限"，**无法区分「从没问过」和「已被拒绝」**。
/// 而这两者的正确处理完全相反 ——
/// 前者可以调 `CGRequestScreenCaptureAccess()` 弹系统框，后者再弹一次也不会出现任何东西。
/// 所以 `MarqueeCapture.SystemScreenRecordingPermission` 自己持久化一个
/// "我们主动请求过" 的标记，把布尔补成三态。
public enum ScreenRecordingPermission: Equatable, Sendable {
    /// 已授权，可以直接采集
    case granted
    /// 用户在系统设置里关掉了（或曾经拒绝过）—— 只能引导去系统设置手动打开
    case denied
    /// 从未询问过 —— 可以弹系统请求框
    case notDetermined
}

/// 权限探针。抽成协议是为了让"权限状态 → 走哪条分支"这件事能脱离真实 TCC 单测。
public protocol ScreenRecordingPermissionProbing: Sendable {
    /// 当前权限状态，**不**弹任何系统框
    func currentPermission() -> ScreenRecordingPermission

    /// 主动请求权限（会弹系统框；仅 `.notDetermined` 时有意义）。
    ///
    /// 返回请求结束后是否已获得授权。注意：此调用会**阻塞**到用户做出选择，
    /// 调用方必须放到主线程之外。
    @discardableResult
    func requestPermission() -> Bool
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

import Foundation

/// 系统设置的深链。
public enum SystemSettingsLink {

    /// 「隐私与安全性 → 屏幕录制」面板。
    ///
    /// 这是 Apple 未公开但长期稳定支持的 `x-apple.systempreferences:` scheme。
    /// 退化路径：`openURL` 失败时只能退到打开系统设置首页（见 App 层的 `PermissionPrompt`）。
    public static let screenRecording = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    /// 面板锚点，测试用（改 URL 时不必跟着改断言）
    public static let screenRecordingAnchor = "Privacy_ScreenCapture"
}

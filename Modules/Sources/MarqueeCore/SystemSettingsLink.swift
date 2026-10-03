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

    /// 「通用 → 登录项」面板。
    ///
    /// 开机自启注册失败时那个「打开登录项设置」按钮要用它 ——
    /// 界面上只写"去看系统设置"是不够的：用户得**跟着一句话找三级菜单**，
    /// 而那正是他被卡住的地方。给一个能直接点开的入口，他才知道下一步做什么。
    public static let loginItems = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!

    /// 面板锚点，测试用。
    public static let loginItemsAnchor = "LoginItems"
}

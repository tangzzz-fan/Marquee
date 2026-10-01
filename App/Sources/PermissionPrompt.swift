import AppKit
import MarqueeCore

/// 面向用户的提示。
///
/// 存在的唯一理由：权限这条路径**必须**有反馈。
/// PRD 3.1 要求"0 个模式弹窗"，指的是交互过程中不要弹窗；
/// 而"权限没给，所以什么也没发生"是另一回事 —— 那是最糟的失败形态。
/// 这里只在出错/缺权限时出现，正常截图路径一个弹窗都没有。
@MainActor
enum PermissionPrompt {

    /// 屏幕录制权限缺席时的说明 + 一键跳转。
    ///
    /// 除了跳系统设置，还给一个「在 Finder 中显示」：**系统设置里没有 Marquee 这一行**是真实会发生的情况
    /// （macOS 只在应用调用过采集 API 后才把它登记进列表），此时用户需要手动把 app 添加进去。
    /// 从 DerivedData 里翻出这个路径对人是件苦差事，直接替他打开省事得多。
    static func presentPermissionGuidance(grantedJustNow: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.t("Marquee 需要「屏幕录制」权限")
        // 两段说明各写成**一条** `L10n.t`，而不是多行 `"""` 字面量：
        // 多行字面量的 key 会带上首尾换行与缩进，读 catalog 时根本认不出那是哪一句。
        // 顺带去掉原先写在字面量里的 `**` —— 那是 Markdown 的加粗，`NSAlert` 不认，
        // 会**原样显示两个星号**给用户看。
        alert.informativeText = grantedJustNow
            ? L10n.t("权限已经勾选，但 macOS 要求应用重启后才生效。\n请退出 Marquee（菜单栏图标 → 退出 Marquee）再重新打开。")
            : L10n.t("请到「系统设置 → 隐私与安全性 → 屏幕录制」里勾选 Marquee，然后退出并重新打开应用。\n\n如果列表里找不到 Marquee：点「在 Finder 中显示」，把打开的 Marquee 拖进列表（或点列表下方的「+」选中它）。")
        alert.addButton(withTitle: L10n.t("打开系统设置"))
        alert.addButton(withTitle: L10n.t("在 Finder 中显示"))
        alert.addButton(withTitle: L10n.t("稍后"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(SystemSettingsLink.screenRecording)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default:
            break
        }
    }

    /// 采集链路失败（非权限原因）。
    static func presentFailure(_ failure: CaptureFailure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("截图没有完成")
        alert.informativeText = failure.message
        alert.addButton(withTitle: L10n.t("好"))
        alert.runModal()
    }

    /// 快捷键注册失败（启动时或改键时都走这里）。
    static func presentShortcutFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("快捷键没有生效")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("好"))
        alert.runModal()
    }
}

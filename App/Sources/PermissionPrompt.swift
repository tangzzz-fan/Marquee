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
    static func presentPermissionGuidance(grantedJustNow: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Marquee 需要「屏幕录制」权限"
        alert.informativeText = grantedJustNow
            ? """
              权限已经勾选，但 macOS 要求应用**重启后**才生效。
              请退出 Marquee（菜单栏图标 → 退出 Marquee）再重新打开。
              """
            : """
              请到「系统设置 → 隐私与安全性 → 屏幕录制」里勾选 Marquee，然后退出并重新打开应用。

              如果列表里**找不到 Marquee**：点列表下方的「+」，把正在运行的 Marquee 添加进去。
              """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(SystemSettingsLink.screenRecording)
        }
    }

    /// 采集链路失败（非权限原因）。
    static func presentFailure(_ failure: CaptureFailure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图没有完成"
        alert.informativeText = failure.message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 快捷键注册失败（启动时或改键时都走这里）。
    static func presentShortcutFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "快捷键没有生效"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

import AppKit
import MarqueeCapture
import MarqueeCore
import MarqueeSettings
import os

/// 把「全局快捷键 → 权限门 → 采集 → 剪贴板」这条链路装配起来，并负责用户反馈。
///
/// 这是宿主层的职责（PRD 5.2：宿主负责模块装配与权限引导）。
/// 所有判定逻辑都在 `MarqueeCore.FullScreenCaptureFlow` 里，这里只做接线与呈现。
@MainActor
final class CaptureCoordinator {

    /// 快捷键变更后通知外部（菜单里显示的组合要跟着变）
    var onShortcutChanged: ((KeyCombo) -> Void)?

    private let logger = Logger(subsystem: "dev.tango.Marquee", category: "capture")

    private let flow: FullScreenCaptureFlow

    /// `lazy` 而不是 `let`：快捷键的 handler 要回调 `self`，
    /// 而 `self` 在 `init` 里还不能用。`lazy` 允许闭包直接捕获 `self`。
    private lazy var shortcut = ShortcutService(
        store: UserDefaultsShortcutStore(),
        registrar: CarbonGlobalHotKey(),
        handler: { [weak self] in self?.performCapture() }
    )

    private var preferencesWindow: ShortcutPreferencesWindowController?

    init() {
        flow = FullScreenCaptureFlow(permission: SystemScreenRecordingPermission(),
                                    capturer: ScreenCaptureKitCapturer(),
                                    clipboard: SystemClipboard(),
                                    displays: SystemDisplayLocator())
    }

    /// 启动：注册全局快捷键（用已存偏好；没存过则用默认 ⌃⌘A）。
    func start() {
        let result = shortcut.activate()
        // 把**实际生效**的组合推给菜单：用户可能早就改过键，菜单不能一直显示默认值
        onShortcutChanged?(shortcut.current)

        switch result {
        case .applied(let combo):
            // 成功也记一条：用户反馈"按了没反应"时，第一件要确认的就是当时注册的是哪个键
            logger.info("全局快捷键已注册：\(combo.displayString, privacy: .public)")
        default:
            let message = result.failureMessage ?? "未知原因"
            logger.error("快捷键注册失败：\(message, privacy: .public)")
            PermissionPrompt.presentShortcutFailure(message)
        }
    }

    /// 执行一次全屏截图。
    func performCapture() {
        Task { [weak self] in
            guard let self else { return }
            self.handle(await self.flow.capture())
        }
    }

    func showShortcutPreferences() {
        let controller: ShortcutPreferencesWindowController
        if let existing = preferencesWindow {
            controller = existing
        } else {
            let created = ShortcutPreferencesWindowController(service: shortcut)
            created.onShortcutChanged = { [weak self] combo in
                self?.onShortcutChanged?(combo)
            }
            preferencesWindow = created
            controller = created
        }
        controller.present()
    }

    // MARK: - 私有

    private func handle(_ outcome: CaptureOutcome) {
        switch outcome {
        case .copiedToClipboard(let metrics):
            // 正常路径**不弹任何东西**：截图工具弹确认框是最招人烦的设计。
            // 耗时与像素尺寸落到系统日志，性能预算（≤150 ms）靠它做回归。
            let summary = """
            全屏截图完成：\(Int(metrics.pixelSize.width))×\(Int(metrics.pixelSize.height)) px，\
            \(metrics.pngByteCount) 字节，耗时 \(metrics.elapsedMilliseconds) ms
            """
            logger.info("\(summary, privacy: .public)")

        case .permissionBlocked(_, let grantedJustNow):
            PermissionPrompt.presentPermissionGuidance(grantedJustNow: grantedJustNow)

        case .failed(let failure):
            logger.error("截图失败：\(failure.message, privacy: .public)")
            PermissionPrompt.presentFailure(failure)
        }
    }
}

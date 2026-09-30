import AppKit
import CoreGraphics
import MarqueeCapture
import MarqueeCore
import MarqueeEditor
import MarqueeOverlay
import MarqueeSettings
import Security
import os

/// 把「全局快捷键 → 权限门 → 采集 → 剪贴板」这条链路装配起来，并负责用户反馈。
///
/// 这是宿主层的职责（PRD 5.2：宿主负责模块装配与权限引导）。
/// 所有判定逻辑都在 `MarqueeCore` 与 `MarqueeOverlay` 里，这里只做接线与呈现。
@MainActor
final class CaptureCoordinator {

    /// 快捷键变更后通知外部（菜单里显示的组合要跟着变）
    var onShortcutChanged: ((KeyCombo) -> Void)?

    private let logger = Logger(subsystem: "dev.tango.Marquee", category: "capture")

    private let permission = SystemScreenRecordingPermission()
    private let capturer = ScreenCaptureKitCapturer()
    private let clipboard = SystemClipboard()
    private let displays = SystemDisplayLocator()
    private let outputStore = UserDefaultsOutputStore()

    private lazy var selectionFlow = RegionCaptureFlow(permission: permission,
                                                       capturer: capturer,
                                                       clipboard: clipboard)
    private lazy var fullScreenFlow = FullScreenCaptureFlow(permission: permission,
                                                            capturer: capturer,
                                                            clipboard: clipboard,
                                                            displays: displays)
    private lazy var windowFlow = WindowCaptureFlow(permission: permission,
                                                    capturer: capturer,
                                                    clipboard: clipboard)
    private let windowLister = ScreenCaptureKitWindowLister()

    /// `lazy` 而不是 `let`：快捷键的 handler 要回调 `self`，
    /// 而 `self` 在 `init` 里还不能用。`lazy` 允许闭包直接捕获 `self`。
    private lazy var shortcut = ShortcutService(
        store: UserDefaultsShortcutStore(),
        registrar: CarbonGlobalHotKey(),
        handler: { [weak self] in self?.performCapture() }
    )

    private let editor = AnnotationEditorPresenter()
    private var overlay: SelectionOverlayController?
    private var preferencesWindow: ShortcutPreferencesWindowController?
    /// 防止预检期间连按快捷键叠出两层覆盖层
    private var isPreflighting = false
    /// 本次运行内是否刚授予过权限 —— 用于把"请重启应用"的提示说准
    private var grantedThisSession = false
    /// 启动时注册快捷键的结果（诊断用）
    private(set) var activationResult: ShortcutChangeResult = .applied(ShortcutService.defaultCombo)

    init() {}

    /// 启动：注册全局快捷键（用已存偏好；没存过则用默认 `⌃Q`）。
    func start() {
        let result = shortcut.activate()
        activationResult = result
        // 把**实际生效**的组合推给菜单：用户可能早就改过键，菜单不能一直显示默认值
        onShortcutChanged?(shortcut.current)

        // 启动只**记录**权限状态，不弹任何东西。
        // 理由：PRD B9 说"启动即检测"，但启动就弹系统授权框是很讨人厌的行为；
        // 而且这条日志是排查"为什么每次都在要权限"的第一手证据（配合稳定签名一起看）。
        logger.info("屏幕录制权限状态：\(String(describing: self.permission.currentPermission()), privacy: .public)")

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

    /// 开始截屏。
    ///
    /// 菜单「截屏」与全局快捷键都走这里。顺序**必须是先过权限门、再出蒙层**（PRD 5.4）：
    /// - 没权限时直接给说明，屏幕上不会出现一层盖住一切、却又截不了的变暗蒙层
    /// - 也不会出现"系统授权框叠在我们自己的蒙层上"这种吓人的组合
    func performCapture() {
        guard overlay?.isPresented != true, !isPreflighting else { return }
        isPreflighting = true

        // 没权限时这一按会引出系统授权框（以及"把 Marquee 登记进屏幕录制列表"那一步）。
        // 我们是 accessory 应用，先激活自己，免得框被压在别的应用后面用户根本看不见。
        if permission.currentPermission() != .granted {
            NSApp.activate()
        }

        Task { [weak self] in
            guard let self else { return }
            let gate = await CaptureGateRunner.run(self.permission)
            self.isPreflighting = false

            switch gate {
            case .blocked(let decision):
                self.logger.error("截屏被权限挡下：\(String(describing: decision), privacy: .public)")
                PermissionPrompt.presentPermissionGuidance(grantedJustNow: self.grantedThisSession)
            case .proceed(let grantedJustNow):
                self.grantedThisSession = self.grantedThisSession || grantedJustNow
                if self.grantedThisSession {
                    // ScreenCaptureKit 在「刚勾选授权」的同一个进程里还不可用。
                    // 继续弹出覆盖层再采集，会再触发一次系统授权框，并且必然失败。
                    PermissionPrompt.presentPermissionGuidance(grantedJustNow: true)
                    return
                }
                self.presentOverlay()
            }
        }
    }

    func presentOverlay() {
        guard overlay?.isPresented != true else { return }

        let controller = SelectionOverlayController(
            regionFlow: selectionFlow,
            fullScreenFlow: fullScreenFlow,
            windowFlow: windowFlow,
            windowLister: windowLister,
            displays: displays,
            onFinish: { [weak self] outcome in
                self?.handleOverlayFinish(outcome)
            },
            makeSaveRequest: { [weak self] window in
                self?.makeSaveRequest(for: window) ?? CaptureSaveRequest(
                    settings: OutputSettings(directory: OutputSettings.desktopDirectory()),
                    capturedAt: Date(),
                    sequence: 1,
                    applicationName: window?.ownerName ?? "",
                    windowTitle: window?.title ?? ""
                )
            }
        )
        overlay = controller
        controller.present()
    }

    /// 截图已经进了剪贴板。编辑器里 `Esc` 会把带标注的成品再写回去。
    func presentEditor(image: CGImage) {
        editor.present(image: image) { [weak self] png in
            self?.clipboard.writePNG(png)
            self?.logger.info("标注已复制到剪贴板：\(png.count) 字节")
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

    /// 排障用的一页状态。
    ///
    /// 为什么要做成命令行可读的报告：这类问题的两个关键信息（权限状态、快捷键到底注册上没有）
    /// 都发生在用户那边、发生在我们看不见的地方 —— 而这两件事**都不是必然报错的**
    /// （权限被拒只是返回 false，非独占注册永远返回成功）。
    /// 让用户跑一条命令把状态贴过来，比来回猜快得多。
    func diagnosticsReport() -> String {
        let registration = activationResult.failureMessage ?? "注册成功"
        return """
        Marquee 诊断
          运行位置        : \(Bundle.main.bundleURL.path)
          屏幕录制权限    : \(Self.describe(permission.currentPermission()))
          preflight 原始值: \(CGPreflightScreenCaptureAccess() ? "true" : "false")
          当前快捷键      : \(shortcut.current.displayString)
          本次注册结果    : \(registration)
          注册器返回      : \(String(describing: shortcut.lastRegistration))
          构建签名        : \(Self.signingSummary())
        """
    }

    private static func describe(_ permission: ScreenRecordingPermission) -> String {
        switch permission {
        case .granted: "已授权"
        case .denied: "已被拒绝（系统不会再弹框，需去系统设置手动打开）"
        case .notDetermined: "从未询问过"
        }
    }

    /// 版本与签名身份 —— 排查"权限为什么留不住"时必须看这个：
    /// ad-hoc 签名每次构建都换身份，TCC 就只能每次重新问
    private static func signingSummary() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "未知" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "未知" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return "未知" }
        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String ?? "?"
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? "无（ad-hoc）"
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return "id=\(identifier) team=\(team) 证书数=\(certificates.count)"
    }

    // MARK: - 私有

    private func handleOverlayFinish(_ outcome: SelectionOverlayController.Outcome) {
        overlay = nil
        switch outcome {
        case .cancelled:
            logger.info("选区已取消")
        case .completed(let capture):
            handle(capture)
        }
    }

    private func handle(_ outcome: CaptureOutcome) {
        switch outcome {
        case .copiedToClipboard(let metrics):
            // 正常复制不弹窗。落盘失败才说一声，因为图已经在剪贴板里，不能装成整次失败。
            if let saved = metrics.savedFilePath {
                if let used = metrics.savedSequence {
                    outputStore.advanceSequence(to: used)
                }
                logger.info("已保存：\(saved, privacy: .public)")
            }
            if let message = metrics.saveFailureMessage {
                logger.error("保存失败：\(message, privacy: .public)")
                PermissionPrompt.presentFailure(CaptureFailure(message: message))
            }
            let summary = """
            截图完成：\(Int(metrics.pixelSize.width))×\(Int(metrics.pixelSize.height)) px，\
            \(metrics.pngByteCount) 字节，耗时 \(metrics.elapsedMilliseconds) ms
            """
            logger.info("\(summary, privacy: .public)")
            if let image = metrics.image {
                presentEditor(image: image)
            }

        case .permissionBlocked(_, let grantedJustNow):
            // 预检时刚授权过 → 这里的失败几乎一定是"权限需要重启进程才生效"，
            // 提示要把重启说出来，否则用户会以为是应用坏了
            PermissionPrompt.presentPermissionGuidance(grantedJustNow: grantedJustNow || grantedThisSession)

        case .failed(let failure):
            logger.error("截图失败：\(failure.message, privacy: .public)")
            PermissionPrompt.presentFailure(failure)
        }
    }

    private func makeSaveRequest(for window: WindowInfo?) -> CaptureSaveRequest {
        CaptureSaveRequest(
            settings: outputStore.settings(),
            capturedAt: Date(),
            sequence: outputStore.consumeSequence(),
            applicationName: window?.ownerName ?? "",
            windowTitle: window?.title ?? ""
        )
    }
}

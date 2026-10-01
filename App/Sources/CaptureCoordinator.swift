import AppKit
import CoreGraphics
import MarqueeCapture
import MarqueeCore
import MarqueeEditor
import MarqueeHistory
import MarqueeOverlay
import MarqueeSettings
import Security
import ServiceManagement
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
    /// 用户偏好（ticket 15）。采集器与倒计时都**每次现读**它 ——
    /// 缓存一份的话"改了偏好没反应"只能靠重启，而界面上看不出任何提示。
    private let preferences = UserDefaultsPreferencesStore()
    /// 采集器。光标是否入图由偏好决定，且**每次抓帧现读**（见 `ScreenCaptureKitCapturer`）。
    private lazy var capturer = ScreenCaptureKitCapturer(
        includesCursor: { [preferences] in preferences.capture().includeCursor }
    )
    private let clipboard = SystemClipboard()
    private let displays = SystemDisplayLocator()
    private let outputStore = UserDefaultsOutputStore()
    private let magnifierSettings = MagnifierSettingsStore()
    /// 自动滚动的授权探针（ticket 12）。**按需**使用：
    /// 只有用户在长截图里按了空格才会问一次，拒绝了就退回手动滚动。
    private let postEventPermission = SystemPostEventPermission()

    private lazy var selectionFlow = RegionCaptureFlow(permission: permission,
                                                       capturer: capturer,
                                                       clipboard: clipboard,
                                                       history: history)
    private lazy var fullScreenFlow = FullScreenCaptureFlow(permission: permission,
                                                            capturer: capturer,
                                                            clipboard: clipboard,
                                                            history: history,
                                                            displays: displays)
    private lazy var windowFlow = WindowCaptureFlow(permission: permission,
                                                    capturer: capturer,
                                                    clipboard: clipboard,
                                                    history: history)
    private let windowLister = ScreenCaptureKitWindowLister()

    /// `lazy` 而不是 `let`：快捷键的 handler 要回调 `self`，
    /// 而 `self` 在 `init` 里还不能用。`lazy` 允许闭包直接捕获 `self`。
    private lazy var shortcut = ShortcutService(
        store: UserDefaultsShortcutStore(),
        registrar: CarbonGlobalHotKey(),
        handler: { [weak self] in self?.performCapture() }
    )

    /// OCR 识别器（ticket 13）。编辑器与启动预热**共用同一个** ——
    /// 预热热的正是它之后要用的那份模型。
    private let textRecognizer = VisionTextRecognizer()
    private lazy var ocrPreheater = TextRecognitionPreheater(recognizer: textRecognizer)
    private lazy var editor = AnnotationEditorPresenter(recognizer: textRecognizer)
    /// 钉图（ticket 14）。持有所有钉住的窗口 —— 多张钉图互不干扰。
    private let pins = PinPresenter()
    private var overlay: SelectionOverlayController?
    private var preferencesWindow: PreferencesWindowController?
    /// 延时截图的倒计时（ticket 15）。
    private let countdown = CountdownHUD()
    /// 最近截图（ticket 16）。采集链路往里记，菜单面板从里读。
    private let history = CaptureHistoryStore()
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

        // OCR 预热（ticket 13）。
        //
        // 首次调用要 **25 秒**（Vision 模型未缓存，见 R10），缓存后才几百毫秒。
        // 不预热的话，用户第一次点「识别文字」会盯着一个几十秒不动的界面 ——
        // 那与卡死没有区别，而且他不会再点第二次。所以这件事必须发生在启动时。
        // 它是后台任务，不挡任何东西；失败也只是记下状态（真到用户点识别时会自己再走一遍）。
        ocrPreheater.startIfNeeded()

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
        guard overlay?.isPresented != true, !isPreflighting else {
            // 用户"按了没反应"时，这一条能立刻区分"请求被自己挡下"与"根本没收到请求"
            logger.info("忽略这次截屏请求（覆盖层已在或正在预检）")
            return
        }
        isPreflighting = true
        logger.info("截屏请求：屏幕录制权限 = \(String(describing: self.permission.currentPermission()), privacy: .public)")

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
                    self.logger.info("权限是这次刚给的：只提示重启，不继续采集")
                    // ScreenCaptureKit 在「刚勾选授权」的同一个进程里还不可用。
                    // 继续弹出覆盖层再采集，会再触发一次系统授权框，并且必然失败。
                    PermissionPrompt.presentPermissionGuidance(grantedJustNow: true)
                    return
                }
                self.logger.info("权限放行，呈现覆盖层")
                self.presentOverlay()
            }
        }
    }

    /// 呈现覆盖层。**延时截图的那几秒在这里**（ticket 15）。
    ///
    /// 延时放在"覆盖层出现**之前**"是刻意的：覆盖层一旦出现就会吃掉所有鼠标事件，
    /// 那时候再等几秒，用户反而什么都摆不了（要截的往往是"需要先摆出来的东西"）。
    func presentOverlay(mode: SelectionOverlayController.Mode = .singleShot) {
        let delay = preferences.capture().delaySeconds
        guard delay > 0 else {
            presentOverlayNow(mode: mode)
            return
        }
        logger.info("延时截图：\(delay, privacy: .public) 秒后出现选择框")
        countdown.run(seconds: delay) { [weak self] in
            self?.presentOverlayNow(mode: mode)
        }
    }

    private func presentOverlayNow(mode: SelectionOverlayController.Mode) {
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
            },
            // 直接捕获依赖而不是 `[weak self]`：会话工厂在覆盖层呈现时才被调用，
            // 而覆盖层本身由 self 持有 —— 写 `weak` 只会多出一个永远走不到的 nil 分支。
            makeScrollSession: { [permission = self.permission,
                                  clipboard = self.clipboard] in
                ScrollCaptureSession(permission: permission,
                                     // ⚠️ 长截图**显式不带光标**：它要连抓几十帧，
                                     // 带的话每一帧都盖一个指针，拼出来的长图上有好几只手。
                                     capturer: ScreenCaptureKitCapturer(includesCursor: { false }),
                                     registrar: VisionScrollRegistrar(),
                                     clipboard: clipboard)
            },
            // 自动滚动（ticket 12）：合成滚轮事件的"手" + 它的授权探针。
            //
            // ⚠️ 这是本项目唯一需要「辅助功能」授权的功能 —— 往别的进程注入事件
            // 属于辅助功能授权范围，绕不过去。所以它**只在用户按空格时**才申请：
            // 截图、标注、手动长截图都不需要它，拒绝了也不影响那些。
            makeScrollWheelEmitter: { CGEventScrollWheelEmitter() },
            postEventPermission: postEventPermission,
            // 放大镜取色（ticket 10）：用现成的采集器取一屏像素，覆盖层期间冻结着用。
            // 取不到就只是不显示放大镜，绝不影响选区与采集。
            lensProvider: CapturerLensProvider(capturer: capturer),
            // 文字识别（ticket 23）：**与编辑器共用同一个识别器** ——
            // 预热只热一份模型；两个入口各建一个的话，第二次用还要重新付那 25 秒。
            textRecognizer: textRecognizer,
            clipboard: clipboard
        )
        // 尺寸每次呈现都重读：这三个数只能靠眼睛调，改完不该还要重启应用。
        // 界面在 ticket 15；现在用 `defaults write dev.tango.Marquee lens.zoom …` 调。
        controller.lensSettings = magnifierSettings.load()
        // 窗口截图带不带阴影的**默认值**来自偏好（ticket 15）；
        // 覆盖层里按 `⌥` 仍然是"临时反过来"（PRD F4），两者不冲突。
        controller.windowShadowDefault = preferences.capture().includeShadow
        overlay = controller
        controller.present(mode: mode)
        logger.info("覆盖层已呈现（mode=\(String(describing: mode), privacy: .public)）")
    }

    /// 菜单「滚动截屏」入口（ticket 11：手动滚动长截图）。
    func performScrollCapture() {
        presentOverlay(mode: .scrollCapture)
    }

    /// 截图已经进了剪贴板。编辑器里 `Esc` 会把带标注的成品再写回去。
    func presentEditor(image: CGImage, seed: [Annotation] = []) {
        // 先记一条再开窗：用户说"编辑器窗口没出来"时，第一件要确认的是
        // **我们到底有没有走到这一步** —— 这与"点了没反应先验入口通不通"是同一条教训，
        // 否则会在窗口呈现那一层白查很久（实际根本没走到那里）。
        logger.info("打开编辑器：\(image.width)×\(image.height) px，预置标注 \(seed.count) 个")
        editor.present(image: image, seed: seed) { [weak self] png in
            self?.clipboard.writePNG(png)
            self?.logger.info("标注已复制到剪贴板：\(png.count) 字节")
        } onSave: { [weak self] rendered in
            self?.saveFromEditor(rendered)
        }
    }

    /// 编辑器里按「保存到磁盘」（或 `⌘S`）：按输出设置落盘。
    ///
    /// 与覆盖层那条保存路径**共用同一个归档器**（`ScreenshotArchiver`）与同一个序号源 ——
    /// 各走一套的话，序号会撞名，而"同名文件太多"的兜底会把名字往后推、
    /// 表现成"保存出来的名字中间跳号"。
    private func saveFromEditor(_ image: CGImage) {
        let request = makeSaveRequest(for: nil)
        switch ScreenshotArchiver.write(image, request: request) {
        case .success(let result):
            outputStore.advanceSequence(to: result.sequenceUsed)
            logger.info("编辑器保存到磁盘：\(result.url.path, privacy: .public)")
        case .failure(let failure):
            logger.error("编辑器保存失败：\(failure.message, privacy: .public)")
            PermissionPrompt.presentFailure(CaptureFailure(message: failure.message))
        }
    }

    func showPreferences() {
        let controller: PreferencesWindowController
        if let existing = preferencesWindow {
            controller = existing
        } else {
            let created = PreferencesWindowController(shortcut: shortcut,
                                                      preferences: preferences,
                                                      output: outputStore)
            created.onShortcutChanged = { [weak self] combo in
                self?.onShortcutChanged?(combo)
            }
            created.onPreferencesChanged = { [weak self] in
                self?.applyLaunchAtLoginIfNeeded()
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
          构建时间        : \(Self.buildTimestamp())
          屏幕录制权限    : \(Self.describe(permission.currentPermission()))
          preflight 原始值: \(CGPreflightScreenCaptureAccess() ? "true" : "false")
          当前快捷键      : \(shortcut.current.displayString)
          本次注册结果    : \(registration)
          注册器返回      : \(String(describing: shortcut.lastRegistration))
          OCR 预热        : \(Self.describe(ocrPreheater.state))
          构建签名        : \(Self.signingSummary())
        """
    }

    /// 产物自身的修改时间。
    ///
    /// 排障时第一个要回答的问题是"**我跑的到底是不是刚才那个构建**" ——
    /// 界面类问题尤其如此：功能明明写了却"看不到"，十有八九是跑在旧产物上。
    /// 放在诊断报告里，用户跑一条命令就能自证。
    private static func buildTimestamp() -> String {
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date else { return "未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 预热状态也要能一眼看到：它坏了不会报错，只会让第一次识别变得很慢。
    private static func describe(_ state: TextRecognitionPreheater.State) -> String {
        switch state {
        case .idle: "尚未开始"
        case .warming: "进行中（首次可能要几十秒）"
        case .ready: "已完成"
        case .failed(let reason): "失败：\(reason)（不影响使用，首次识别会慢）"
        }
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
        case .completed(let capture, let after, let anchor):
            handle(capture, after: after, anchor: anchor)
        }
    }

    /// - Parameter after: 采集完成后还要做什么（编辑器 / 钉图 / 什么都不做）。
    ///
    ///   普通截图从 ticket 20 起**就地完成**（空集）—— 用户要的"不阻断"就是这条：
    ///   拖完选区按 `⏎` 直接得到图，不弹任何窗口。
    ///   长截图要编辑器；工具栏上的「钉图」要钉在屏幕上。
    /// - Parameter anchor: 原始选区（Cocoa 全局点）。钉图据它**钉在原位**。
    private func handle(_ outcome: CaptureOutcome, after: SelectionOverlayController.AfterCapture, anchor: CGRect?) {
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
            if preferences.general().playSound {
                CaptureFeedback.playSuccess()
            }
            if let image = metrics.image {
                // 钉图**先做**：它是"多留一份"，与后面开不开窗口无关。
                // 两者可以同时发生（以后若加"钉住并进编辑器"，这里不用改）。
                if after.contains(.pin) {
                    pins.pin(image, anchor: anchor)
                    logger.info("已钉在屏幕上，当前共 \(self.pins.count) 张")
                }
                if after.contains(.openEditor) {
                    presentEditor(image: image)
                } else if !after.contains(.pin) {
                    logger.info("就地完成：不开编辑器窗口（ticket 20 起普通截图不再弹窗口）")
                }
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

    /// 把"开机自启"这个偏好落到系统里（`SMAppService`）。
    ///
    /// **失败了必须说清楚并把开关拨回去**：界面上显示"已开启"而系统登录项里没有，
    /// 用户只能靠重启去发现 —— 那是最难查的一类不一致。
    /// 开发构建（未签名 / 未公证）注册失败是**正常现象**，提示里要把这一点说出来，
    /// 否则会被当成"这个功能坏了"。
    // MARK: - 最近截图（ticket 16）

    /// 造那层面板。菜单每次打开都会重建内容（`viewWillAppear` 里重读磁盘），
    /// 所以"刚截的那张"一定在列表最上面。
    func makeRecentPanelController() -> NSViewController {
        RecentCapturesPanelController(store: history, actions: .init(
            onCopy: { [weak self] entry in self?.copyHistory(entry) },
            onEdit: { [weak self] entry in self?.editHistory(entry) },
            onDelete: { [weak self] entry in
                self?.history.delete(entry.id)
                self?.logger.info("历史：删掉一条")
            }
        ))
    }

    /// 把历史里的图放回剪贴板。
    ///
    /// **重新栅格化一遍**（原图 + 标注），而不是存一份拍平后的副本：
    /// ① 磁盘上少一份冗余；② 走的是导出那条完全相同的代码路径，
    /// 于是"从历史复制出来的"与"当时按 ⏎ 得到的"在结构上就是同一张图。
    private func copyHistory(_ entry: CaptureHistoryEntry) {
        guard let snapshot = history.snapshot(for: entry) else {
            logger.error("历史：取不回这一条（文件可能被外部删了）")
            PermissionPrompt.presentFailure(CaptureFailure(message: "这张图的文件已经不在了（可能被清理过）"))
            return
        }
        let document = AnnotationDocument(pixelSize: snapshot.originalSize,
                                          annotations: snapshot.annotations)
        guard let rendered = AnnotationRasterizer.image(document: document, source: snapshot.original),
              let png = ImageEncoding.pngData(from: rendered) else {
            logger.error("历史：重新合成失败")
            PermissionPrompt.presentFailure(CaptureFailure(message: "这张图没能重新合成出来"))
            return
        }
        clipboard.writePNG(png)
        logger.info("历史：已复制到剪贴板（\(png.count) 字节）")
    }

    /// 从历史重新进编辑器。**喂的是原图 + 标注**，所以原有的标注仍可选中、可撤。
    private func editHistory(_ entry: CaptureHistoryEntry) {
        guard let snapshot = history.snapshot(for: entry) else {
            PermissionPrompt.presentFailure(CaptureFailure(message: "这张图的文件已经不在了（可能被清理过）"))
            return
        }
        presentEditor(image: snapshot.original, seed: snapshot.annotations)
    }

    private func applyLaunchAtLoginIfNeeded() {
        let wanted = preferences.general().launchAtLogin
        let service = SMAppService.mainApp
        do {
            if wanted {
                guard service.status != .enabled else {
                    preferencesWindow?.reportLaunchAtLogin(failure: nil)
                    return
                }
                try service.register()
            } else if service.status == .enabled {
                try service.unregister()
            }
            logger.info("登录项已同步（想要的：\(wanted, privacy: .public)）")
            preferencesWindow?.reportLaunchAtLogin(failure: nil)
        } catch {
            logger.error("登录项设置失败：\(error.localizedDescription, privacy: .public)")
            preferencesWindow?.reportLaunchAtLogin(
                failure: "系统没有接受这个设置（\(error.localizedDescription)）。开发构建通常是签名问题，正式安装包不受影响。"
            )
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

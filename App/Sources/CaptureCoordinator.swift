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

    private let logger = Logger(subsystem: AppIdentity().logSubsystem, category: "capture")

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
    private lazy var editor = AnnotationEditorPresenter(
        recognizer: textRecognizer,
        // 工具条的材质底由**宿主**注入（稿子 ⑩ §07：`.ebar` 进玻璃族）。
        // 编辑器不认识 `ChromeBackground`（模块依赖方向），而"浮件的底怎么造"
        // 必须只有一份实现 —— 包括那条看不见的规则：「降低透明度」打开时退回实色。
        background: { ChromeBackground.makeBackgroundView(cornerRadius: $0) })
    /// 钉图（ticket 14）。持有所有钉住的窗口 —— 多张钉图互不干扰。
    private let pins = PinPresenter()
    private var overlay: SelectionOverlayController?
    private var preferencesWindow: PreferencesWindowController?
    /// 菜单入口被挡住时弹的那张卡片（ticket 31）。**必须持着** ——
    /// 它是个 `NSPanel`，没有强引用的话会被 ARC 当场回收，用户什么也看不到。
    private var proCardPanel: ProCardPanel?
    /// 首次启动的引导（ticket 34）。同上，必须持着 —— `NSWindow` 没有强引用会被回收。
    private var onboardingWindow: OnboardingWindowController?
    /// 延时截图的倒计时（ticket 15）。
    private let countdown = CountdownHUD()
    /// 最近截图（ticket 16）。采集链路往里记，菜单面板从里读。
    private let history = CaptureHistoryStore()    /// 防止预检期间连按快捷键叠出两层覆盖层
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

        // 免费版只留 5 张（ticket 31）。与其它界面走同一条路：**订阅 snapshot**，
        // 不自己另判一次"是不是 Pro" —— 判据一旦有两份，必然有一处忘了跟着改。
        // `historyLimit()` 返回 nil 就是"不淘汰"。
        ProEntitlement.shared.observe { [weak self] snapshot in
            self?.history.limit = snapshot.historyLimit()
            // ⚠️ **覆盖层也要跟着变**（2026-10-04 补）。
            //
            // 缺这一句的时候有一条很具体的坏体验：在覆盖层里点「恢复购买」，
            // 恢复**成功了**，而格子上的锁还在 —— 用户以为没成功，又点一次。
            //
            // 为什么要 `async`：判定可能在后台线程上完成（StoreKit 的回调），
            // 而覆盖层是主线程的东西。多绕一次主队列是这里最便宜的正确做法。
            DispatchQueue.main.async {
                self?.overlay?.entitlementsChanged()
            }
        }

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
            let message = result.failureMessage ?? L10n.t("未知原因")
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
                    settings: OutputSettings(directory: OutputSettings.defaultOutputDirectory()),
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
        // 权益（ticket 31）：**宿主注入**。覆盖层自己不持有权益状态 ——
        // 各持一份就会冒出"购买之后设置页解锁了、这个窗口还锁着"。
        // 没注入时覆盖层一律放行（见 `proEntitlement` 的文档），
        // 所以"忘了接"的后果是**该锁的没锁**，而不是"什么都点不动"。
        controller.proEntitlement = { ProEntitlement.shared.snapshot }
        // 价格同样是**宿主注入**的：覆盖层不认识 StoreKit，也就无从知道
        // "完整版要多少钱"（见 `ProEntitlement.priceText`）。
        controller.proPriceText = { ProEntitlement.shared.priceText }
        controller.onProCardAction = { [weak self] action in
            self?.handleProCardAction(action)
        }
        overlay = controller
        controller.present(mode: mode)
        logger.info("覆盖层已呈现（mode=\(String(describing: mode), privacy: .public)）")
    }

    /// 升级卡片上点了某个动作（ticket 31）。
    ///
    /// 三个动作都是**异步**的，而卡片在覆盖层里已经**同步**收掉了。
    /// 于是用户看到的顺序永远是"点了 → 卡片消失 → 系统购买面板 / 设置窗口出现"。
    private func handleProCardAction(_ action: ProCardAction) {
        let entitlement = ProEntitlement.shared
        switch action {
        case .startTrial:
            Task { _ = await entitlement.startTrial() }
        case .restore:
            // ⚠️ **结果不能丢**。这个动作是原地完成的：卡片收掉了、覆盖层还留着，
            // 而另外两个动作会开窗口（用户看得见那扇窗）—— 只有它什么都不弹。
            // 结果全落在提示行那一句上；少了它就是"点了没反应"。
            Task { [weak self] in
                let outcome = await entitlement.restorePurchases()
                let feedback = ProFeedback.restore(outcome)
                self?.overlay?.showTransientNotice(feedback.text, role: feedback.kind.readoutRole)
            }
        case .purchase:
            // ⚠️「了解 Pro」**不直接发起购买**。扣款是不可逆的动作，
            // 得让用户先看见价格与自己的当前状态 —— 所以打开**通用页**，
            // 那块状态区（含「升级到 Pro」与「恢复购买」）就在页面底部。
            showPreferences(page: .general)
        }
    }

    /// 菜单「滚动截屏」入口（ticket 11：手动滚动长截图）。
    ///
    /// 被挡住时**不进入覆盖层**（ticket 31）—— 这是三个 Pro 入口里唯一一个
    /// "人还没进覆盖层就被挡住"的，所以它的卡片是个独立窗口（见 `ProCardPanel`）。
    ///
    /// 判据用的是 `ProCard.content` 而非自己拼一个：返回 nil 就是"该放行"，
    /// 与覆盖层里那条走的是**同一个函数**。
    func performScrollCapture() {
        let snapshot = ProEntitlement.shared.snapshot
        if let card = ProCard.content(for: snapshot, feature: .scrollCapture) {
            presentProCard(card)
            logger.info("滚动截屏被挡：弹出升级卡片")
            return
        }
        presentOverlay(mode: .scrollCapture)
    }

    /// 在鼠标下方弹那张卡片。**同时只留一张** —— 连点两次菜单项不该叠出两张。
    private func presentProCard(_ content: ProCardContent) {
        proCardPanel?.dismiss()
        let panel = ProCardPanel(content: content, near: NSEvent.mouseLocation) { [weak self] action in
            self?.handleProCardAction(action)
        }
        proCardPanel = panel
        panel.present()
    }

    /// 截图已经进了剪贴板。编辑器里 `Esc` 会把带标注的成品再写回去。
    /// 「设计稿 vs 实装」的对照材料（**只在 `-marqueeSmokeCompliance` 那条路用**）。
    func renderComplianceSheet(into directory: URL) -> [String] {
        ComplianceSheet.render(shortcut: shortcut,
                               preferences: preferences,
                               output: outputStore,
                               currentPermission: { [permission] in permission.currentPermission() },
                               into: directory)
    }

    /// 覆盖层**实机照片**（**只在 `-marqueeSmokeOverlayShot` 那条路用**）。
    ///
    /// ## 为什么非得"实机拍"不可
    ///
    /// 因为 `NSVisualEffectView` / `NSGlassEffectView` 都要**真实窗口**才有东西可糊 ——
    /// 任何 `ImageRenderer` / `cacheDisplay` 都拍不出玻璃（PITFALLS 187）。
    /// 而"这一层玻璃到底像不像玻璃、白字压在白色网页上还读不读得出"
    /// 恰恰是**只有看才能判断**的那类事：它不崩不报错，只是不对。
    ///
    /// 所以这条路是：**真把覆盖层摆出来** → 走真实的三段委托拖一个选区 →
    /// 用采集器抓一次屏。代价是它**需要屏幕录制授权**，而授权只有人能点。
    ///
    /// - Returns: 结论文本（成功时含落盘路径）。**失败也要有话说** ——
    ///   没有权限时最容易发生的事是"什么都没生成，也没人说为什么"。
    ///
    // L10N-EXEMPT-START: `-marqueeSmokeOverlayShot` 的控制台报告（也落一份到 reports/）。
    // 它是**给我看的**：告诉开发者下一步点哪里、以及抓屏为什么失败。
    // 进 catalog 反而更糟 —— 那些"怎么点授权"的步骤句是操作说明，不是界面文案，
    // 而且它们的读者只有一个人（贴回来给我看的那一位）。
    func captureOverlayShot(into directory: URL) async -> String {
        guard permission.currentPermission() == .granted else {
            // 路径用**运行期的真实值**，不是占位符 —— 这份文本的目的就是让人复制粘贴。
            let app = Bundle.main.bundleURL.path
            return """
            覆盖层实机照片：**需要屏幕录制授权**，当前是「\(Self.describe(permission.currentPermission()))」。

            这一步只有你能做（系统不允许程序自己点那个开关）。**在你自己的终端里**跑：

              open -a "\(app)" --args -marqueeRequestPermission

            ⚠️ 必须用 `open -a`，别直接 exec 那个可执行文件：
            TCC 会把这次访问算在**父进程（终端）**头上，于是登记进「屏幕录制」列表的
            是终端而不是 Marquee —— 那正是"列表里根本找不到 Marquee"的一种成因。

            弹框里点「打开系统设置」→ 隐私与安全性 → 屏幕录制 → 勾上 Marquee。
            勾完**不必手工重启**：再跑一次下面这条就会新起一个进程。

              open -a "\(app)" --args -marqueeSmokeOverlayShot

            ⚠️ 跑完如果**什么反应都没有**，先看 `reports/launch-arguments.txt`：
            没有这个文件 = 命令行参数根本没送到应用（`open --args` 在某些终端里会**静默丢参**，
            本机实测：被沙箱包裹的 shell 里三种写法都丢）。换一个终端再试。
            """
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return "覆盖层实机照片：没找到可用的屏幕"
        }
        guard let display = displays.displayUnderPointer() else {
            return "覆盖层实机照片：没找到鼠标所在的显示器"
        }

        performCapture()
        // 让覆盖层落位、素材层建起来（`makeBackgroundView` 是子视图，摆位完才出现）。
        try? await Task.sleep(for: .seconds(0.8))

        // 拖一个**占屏幕中间、四周留足内容**的选区：这样才能同时看到
        // "玻璃压在白 / 深 / 彩三种内容上"—— 那正是这一层唯一的考卷。
        let frame = screen.frame
        let insetX = frame.width * 0.22
        let insetY = frame.height * 0.22
        let dragged = overlay?.debugSimulateSelection(
            from: CGPoint(x: frame.minX + insetX, y: frame.minY + insetY),
            to: CGPoint(x: frame.maxX - insetX, y: frame.maxY - insetY)) ?? false
        try? await Task.sleep(for: .seconds(0.8))

        guard let captured = try? await capturer.captureFullScreen(display) else {
            return "覆盖层实机照片：拖出选区=\(dragged)，但抓屏失败（权限刚勾上时系统可能还要一会儿才放行）"
        }
        guard let png = ImageEncoding.pngData(from: captured.image) else {
            return "覆盖层实机照片：抓到图了，但 PNG 编码失败"
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("overlay-shot.png")
        try? png.write(to: url)
        return """
        覆盖层实机照片：\(url.path)
          尺寸 \(captured.image.width) × \(captured.image.height)（物理像素）
          拖出选区：\(dragged ? "成功" : "失败（起笔点不在任何一块屏上）")
        """
    }
    // L10N-EXEMPT-END

    /// IAP 审核截图（**只在 `-marqueeSmokeReview` 那条路用**）。
    ///
    /// 与上面那条同一个理由：ASC 要 1280 × 800，而对照材料是"窗口多大拍多大"。
    /// 两张分别对应两个商品（买断看在偏好页的入口、试用看在覆盖层卡片上的入口）。
    func renderReviewShots(into directory: URL) -> [String] {
        ReviewShots.render(shortcut: shortcut,
                           preferences: preferences,
                           output: outputStore,
                           into: directory)
    }

    /// App Store 的 **app 截图**（**只在 `-marqueeSmokeAppShots` 那条路用**）。
    ///
    /// 与上面那条的区别：那条是**内购的审核截图**（1280 × 800，指出购买入口），
    /// 这条是**产品本身的商店截图**（2880 × 1800，展示它长什么样、能干什么）。
    func renderAppShots(into directory: URL) -> [String] {
        AppShots.render(shortcut: shortcut,
                        preferences: preferences,
                        output: outputStore,
                        editor: editor,
                        into: directory)
    }

    /// 编辑器的版面快照（**只在 `-marqueeSmokeEditor` 那条路用**）。
    ///
    /// 与 `-marqueeDiagnostics` 同一类：这类"看起来对不对"的东西没法进单测，
    /// 而它一旦错，是每个用户都会看到的。渲成 PNG 落在报告目录里，看一眼就有结论。
    func renderEditorChromeSnapshots(into directory: URL) -> [String] {
        editor.renderChromeSnapshots(image: Self.smokeImage(0), into: directory)
    }

    /// - Parameter segments: 长截图拼了几段。只有长截图那条路知道 ——
    ///   普通截图（就地标注）与两个自检入口都传 `nil`，状态行就不说这一句。
    ///   见 `EditorChrome.leading`：编一个数比不说更糟。
    func presentEditor(image: CGImage, seed: [Annotation] = [], segments: Int? = nil) {
        // 先记一条再开窗：用户说"编辑器窗口没出来"时，第一件要确认的是
        // **我们到底有没有走到这一步** —— 这与"点了没反应先验入口通不通"是同一条教训，
        // 否则会在窗口呈现那一层白查很久（实际根本没走到那里）。
        // `-` = 不知道（普通截图没有这个概念）。日志里不写中文，免得被文案扫描扫进来。
        logger.info("打开编辑器：\(image.width)×\(image.height) px，预置标注 \(seed.count) 个，拼接段数 \(segments.map(String.init) ?? "-", privacy: .public)")
        editor.present(image: image, seed: seed, segments: segments) { [weak self] png in
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

    /// 首次启动的引导（ticket 34）。
    ///
    /// **幂等**：走过一次（或用户直接把窗口叉掉）就再也不弹。
    /// 判据在 Core（`OnboardingGate`）—— 它要挡住"自检运行被一个要人点的窗口挂住"
    /// 那件事，而那种故障看起来是"命令没反应"，跟引导八竿子打不着。
    func presentOnboardingIfNeeded() {
        let state = OnboardingState()
        guard OnboardingGate.shouldPresent(hasCompleted: state.hasCompleted) else { return }

        let controller = OnboardingWindowController(
            shortcut: shortcut,
            currentPermission: { [weak self] in
                self?.permission.currentPermission() ?? .notDetermined
            },
            onShortcutChanged: { [weak self] combo in
                // 与偏好页改键走**同一个出口**：菜单上显示的组合只有这一条路会更新。
                self?.onShortcutChanged?(combo)
            }
        )
        controller.onFinish = { [weak self] in
            // 收尾只有一处（`windowWillClose`）—— 走完和叉掉走的是同一段。
            state.hasCompleted = true
            self?.onboardingWindow = nil
        }
        onboardingWindow = controller
        controller.present()
    }

    /// 应用每次被激活时，重读一遍引导页上的权限状态。
    ///
    /// ⚠️ **必须真的有一条这样的路径。** 引导上写的权限状态，用户会去
    /// 「系统设置 → 隐私与安全性 → 屏幕录制」把它勾上，然后切回 Marquee ——
    /// 如果不重读，他看到的是"我明明勾了，它还说没有"，
    /// 而下一步他会去怀疑是 Marquee 坏了、或者去重新授权一遍。
    ///
    /// 原先只在构造时读一次，也就是说**那句"每次切回都会重读"是句空话**。
    /// 放在 app delegate 的 `applicationDidBecomeActive` 里调：窗口那一层
    /// 收不到"应用被激活"，只有 delegate 收得到。
    func refreshOnboardingPermission() {
        onboardingWindow?.refreshPermissionStatus()
    }

    /// `page` 给了就切到那一页；不给则停在用户上次看的那一页（菜单「设置…」走这条）。
    func showPreferences(page: SettingsPage? = nil) {
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
        controller.present(page: page)
    }

    /// 排障用的一页状态。
    ///
    /// 为什么要做成命令行可读的报告：这类问题的两个关键信息（权限状态、快捷键到底注册上没有）
    /// 都发生在用户那边、发生在我们看不见的地方 —— 而这两件事**都不是必然报错的**
    /// （权限被拒只是返回 false，非独占注册永远返回成功）。
    /// 让用户跑一条命令把状态贴过来，比来回猜快得多。
    // L10N-EXEMPT-START: `-marqueeDiagnostics` 打印到控制台的报告，用户贴回来给我看，翻译了反而看不懂
    func diagnosticsReport() -> String {
        let registration = activationResult.failureMessage ?? "注册成功"
        return """
        Marquee 诊断
          运行位置        : \(Bundle.main.bundleURL.path)
          沙盒            : \(AppIdentity().isSandboxed ? "是（App Store 版）" : "否")
          进程家目录      : \(NSHomeDirectory())
          真实家目录      : \(AppIdentity.realHomeDirectory().path)
          默认落盘        : \(OutputSettings.defaultOutputDirectory().path)
          历史仓库        : \(CaptureHistoryStore.defaultDirectory().path)
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

    // L10N-EXEMPT-END
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
    // L10N-EXEMPT-START: 截图完成后的日志摘要
            let summary = """
            截图完成：\(Int(metrics.pixelSize.width))×\(Int(metrics.pixelSize.height)) px，\
            \(metrics.pngByteCount) 字节，耗时 \(metrics.elapsedMilliseconds) ms
            """
    // L10N-EXEMPT-END
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
                    // 段数只对长截图有意义 —— 从采集度量里带过去（普通截图那里是 nil）。
                    presentEditor(image: image, segments: metrics.stitchedSegments)
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
        RecentCapturesPanelController(
            store: history,
            actions: .init(
                onCopy: { [weak self] entry in self?.copyHistory(entry) },
                onEdit: { [weak self] entry in self?.editHistory(entry) },
                onDelete: { [weak self] entry in
                    // 用户的这一下**文件进废纸篓**（见 `CaptureHistoryStore.delete`），
                    // 所以面板里不留撤销条、不留灰行 —— 撤销权交给系统。
                    self?.history.delete(entry.id)
                    self?.logger.info("历史：删掉一条（文件已移入废纸篓）")
                }
            ),
            // 空态那句里的键位。**每次现问**，不是构造时快照 ——
            // 用户可能正是在面板开着的时候去偏好里改了键。
            currentShortcut: { [weak self] in self?.shortcut.current ?? KeyCombo.fullScreenCapture },
            // 「升级到 Pro」升起的那张卡片。与覆盖层、菜单里那两处走**同一个判据**
            //（`ProCard.content` 返回 nil 就是"这一格不该出现"）。
            upgradeCard: {
                ProCard.content(for: ProEntitlement.shared.snapshot, feature: .unlimitedHistory)
            },
            onUpgradeAction: { [weak self] action in self?.handleProCardAction(action) }
        )
    }

    // L10N-EXEMPT-START: `-marqueeSmokeRecent` 的报告 —— 贴回来给我看的诊断文字，
    // 翻译了反而看不懂（与 `-marqueeDiagnostics` 那份同一类）。
    // MARK: - 最近截图面板的冒烟（`-marqueeSmokeRecent`）

    /// 把面板搭出来、**量一遍每个子视图的矩形**，把报告交出去。
    ///
    /// ## 为什么这一块需要冒烟而不是单测
    ///
    /// Core 那一半（`RecentPanel`）已经单测钉住了：四段宽度之和、面板总高、徽章不出行……
    /// 但"把那些数字摆成真的视图"这一步只能在**运行期**验证：
    ///
    /// - 约束冲突（面板高度、列表高度、底部那一行的三段）**不会崩**，
    ///   它只是让某个视图位置不对 —— 而控制台那行 "Unable to simultaneously satisfy
    ///   constraints" 在应用日志里，开发机上很容易被别的输出冲掉；
    /// - 模糊布局（`hasAmbiguousLayout`）同理：看起来"差不多对"，实际由引擎随手定一个解。
    ///
    /// 所以这个入口找一个**临时历史**造 3 条（其中一条带标注，两行文字都要出现），
    /// 把面板搭起来，然后把"算出来的"与"排出来的"并排写进报告。
    /// 与 `-marqueeSmokeOverlay` / `-marqueeDemoEditor` 同一个理由：
    /// 这条路径要靠眼睛和真机，而它一旦坏是每个用户都会撞上的。
    func recentPanelSmokeReport() -> String {
        var lines: [String] = ["最近截图面板冒烟"]
        lines.append(contentsOf: measurePanel(rows: 3, title: "三行（免费版）", expectsFooter: true))
        lines.append(contentsOf: measurePanel(rows: 0, title: "空态（免费版）", expectsFooter: true))
        lines.append(contentsOf: measurePanel(rows: 12, title: "满 12 行（免费版）", expectsFooter: true))
        return lines.joined(separator: "\n")
    }

    /// 造一个有 n 条的临时历史，把面板搭起来，量一遍。
    private func measurePanel(rows: Int, title: String, expectsFooter: Bool) -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-smoke-recent-\(UUID().uuidString)", isDirectory: true)
        // 上限给够，否则 12 条那一次会被淘汰掉 —— 量出来的就不是"满 12 行"。
        let store = CaptureHistoryStore(directory: directory, limit: max(rows, 1))
        let annotation = Annotation(kind: .rectangle,
                                    frame: CGRect(x: 5, y: 6, width: 10, height: 8),
                                    zIndex: 0)
        for index in 0..<rows {
            _ = store.record(original: Self.smokeImage(index % 4),
                             originalPNG: nil,
                             annotations: index % 3 == 0 ? [annotation] : [],
                             at: Date().addingTimeInterval(TimeInterval(-index * 3600)))
        }

        let controller = RecentCapturesPanelController(
            store: store,
            actions: .init(onCopy: { _ in }, onEdit: { _ in }, onDelete: { _ in }),
            currentShortcut: { self.shortcut.current },
            upgradeCard: { ProCardContent(feature: .unlimitedHistory,
                                          reason: .neverPurchased,
                                          primary: .purchase,
                                          secondary: .restore) },
            onUpgradeAction: { _ in })
        _ = controller.view
        controller.reload()
        controller.view.layoutSubtreeIfNeeded()

        var lines: [String] = []
        let expected = RecentPanel.panelHeight(rowCount: rows, showsFooter: expectsFooter)
        let actual = controller.view.fittingSize
        let ok = abs(actual.height - expected) < 0.5 && abs(actual.width - RecentPanel.width) < 0.5
        lines.append("")
        lines.append("── \(title) ──")
        lines.append("  面板          : \(actual.width) × \(actual.height)  "
                        + "期望 \(RecentPanel.width) × \(expected)  \(ok ? "✅" : "❌")")
        lines.append("  模糊布局      : \(Self.ambiguousViews(in: controller.view))")

        let rowViews = Self.allSubviews(of: controller.view).compactMap { $0 as? ChromeRecentRow }
        lines.append("  行数          : \(rowViews.count)（期望 \(rows)） "
                        + "\(rowViews.count == rows ? "✅" : "❌")")
        for row in rowViews.prefix(2) {
            lines.append(contentsOf: Self.compare(row).map { "  " + $0 })
        }
        // 底部那一行：**只有免费版才有**，而且那三段排在一条基线上。
        // 这里把它逐件量出来 —— 那段话是"免费版只留 5 张 · [升级到 Pro] 可保留全部"。
        if let footerBar = controller.view.subviews.first?.subviews.last,
           let row = Self.allSubviews(of: footerBar).first(where: { $0 is NSStackView }) as? NSStackView {
            let pieces = row.arrangedSubviews.map { piece in
                let text = (piece as? NSTextField)?.stringValue
                    ?? (piece as? ChromeTextButton)?.title ?? ""
                // 打印**对齐矩形**而不是 frame：`NSStackView` 是按对齐矩形摆的，
                // 而 `NSTextField` 的对齐矩形比 frame 大一圈（AppKit 给焦点环留的余量）。
                // 看 frame 会以为"句首被推左了 2 点"，看对齐矩形才知道它正好落在内边距上。
                return "\(text)\(Self.rect(piece.alignmentRect(forFrame: piece.frame)))"
            }
            lines.append("  底部那一行    : 底 \(footerBar.isHidden ? "隐藏" : "显示")"
                            + "  高 \(String(format: "%.0f", footerBar.frame.height))"
                            + "  三段 \(pieces.joined(separator: " "))")
        }
        try? FileManager.default.removeItem(at: directory)
        return lines
    }

    /// 把"算出来的"与"排出来的"逐项比一遍。
    ///
    /// 单测能钉住算式，钉不住"视图有没有照它摆"—— 这一步中间隔着 Auto Layout，
    /// 而它错起来的样子只是"某个东西偏了几点"。
    private static func compare(_ row: ChromeRecentRow) -> [String] {
        let buttons = allSubviews(of: row).compactMap { $0 as? ChromeTextButton }
        let layout = RecentPanel.rowLayout(in: row.bounds,
                                           actionWidths: buttons.map(\.intrinsicContentSize.width))
        let thumbnail = allSubviews(of: row).compactMap { $0 as? ChromeThumbnailButton }.first
        var lines: [String] = []
        func check(_ name: String, _ actual: CGRect?, _ expected: CGRect, tolerance: CGFloat = 0.5) {
            guard let actual else {
                lines.append("\(name)：**没找到这个视图** ❌")
                return
            }
            let same = abs(actual.minX - expected.minX) <= tolerance
                && abs(actual.minY - expected.minY) <= tolerance
                && abs(actual.width - expected.width) <= tolerance
                && abs(actual.height - expected.height) <= tolerance
            lines.append("\(name)：\(rect(actual)) 期望 \(rect(expected)) \(same ? "✅" : "❌")")
        }
        check("缩略图", thumbnail?.frame, layout.thumbnail)
        // 动作由 Core 从右往左给，视图里两个按钮的顺序是 [编辑, 删除] —— 反着配。
        for (index, button) in buttons.enumerated() {
            let rect = layout.actions[layout.actions.count - 1 - index]
            check(button.title.isEmpty ? "动作" : button.title, button.frame, rect)
        }
        if let thumbnail {
            check("徽章(相对缩略图)", RecentPanel.copyBadgeInThumbnail,
                  RecentPanel.copyBadgeInThumbnail)
            let badge = RecentPanel.copyBadgeInThumbnail
            lines.append("  徽章外扩      : 角外 "
                            + String(format: "(%.0f, %.0f)",
                                     badge.maxX - RecentPanel.thumbnailSize.width,
                                     badge.maxY - RecentPanel.thumbnailSize.height)
                            + " 点（稿子：右上角各 \(Int(RecentPanel.copyBadgeOffset))）")
        }
        return lines
    }

    private static func rect(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f,%.0f×%.0f)", r.minX, r.minY, r.width, r.height)
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        var out: [NSView] = []
        for child in view.subviews {
            out.append(child)
            out.append(contentsOf: allSubviews(of: child))
        }
        return out
    }

    /// 造一张纯色小图（不依赖屏幕采集 —— 冒烟不该要求屏幕录制权限）。
    private static func smokeImage(_ index: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let width = 400 + index * 40
        let context = CGContext(data: nil, width: width, height: 300,
                                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let shade = 0.2 + Double(index) * 0.2
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [shade, shade, 0.8, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 300))
        return context.makeImage()!
    }

    /// 有模糊布局的视图 —— 它意味着"位置由引擎随手定"，而看起来往往是"差不多对"。
    private static func ambiguousViews(in view: NSView) -> String {
        let found = allSubviews(of: view).filter(\.hasAmbiguousLayout).map { "\(type(of: $0))" }
        return found.isEmpty ? "无" : found.joined(separator: ", ")
    }
    // L10N-EXEMPT-END

    /// 把历史里的图放回剪贴板。
    ///
    /// **重新栅格化一遍**（原图 + 标注），而不是存一份拍平后的副本：
    /// ① 磁盘上少一份冗余；② 走的是导出那条完全相同的代码路径，
    /// 于是"从历史复制出来的"与"当时按 ⏎ 得到的"在结构上就是同一张图。
    private func copyHistory(_ entry: CaptureHistoryEntry) {
        guard let snapshot = history.snapshot(for: entry) else {
            logger.error("历史：取不回这一条（文件可能被外部删了）")
            PermissionPrompt.presentFailure(CaptureFailure(message: L10n.t("这张图的文件已经不在了（可能被清理过）")))
            return
        }
        let document = AnnotationDocument(pixelSize: snapshot.originalSize,
                                          annotations: snapshot.annotations)
        guard let rendered = AnnotationRasterizer.image(document: document, source: snapshot.original),
              let png = ImageEncoding.pngData(from: rendered) else {
            logger.error("历史：重新合成失败")
            PermissionPrompt.presentFailure(CaptureFailure(message: L10n.t("这张图没能重新合成出来")))
            return
        }
        clipboard.writePNG(png)
        logger.info("历史：已复制到剪贴板（\(png.count) 字节）")
    }

    /// 从历史重新进编辑器。**喂的是原图 + 标注**，所以原有的标注仍可选中、可撤。
    private func editHistory(_ entry: CaptureHistoryEntry) {
        guard let snapshot = history.snapshot(for: entry) else {
            PermissionPrompt.presentFailure(CaptureFailure(message: L10n.t("这张图的文件已经不在了（可能被清理过）")))
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
                failure: L10n.t("系统没有接受这个设置（\(error.localizedDescription)）。开发构建通常是签名问题，正式安装包不受影响。")
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

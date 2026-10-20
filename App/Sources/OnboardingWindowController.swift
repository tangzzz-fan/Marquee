import AppKit
import MarqueeCore

/// 首次启动的引导（ticket 34）。
///
/// ## 为什么需要它
///
/// 这个 app **没有主窗口** —— 装完之后它只是菜单栏上的一个图标，而唯一的入口
/// 是一个默认快捷键（`⌃Q`）。第一次用的人面对的是一个"什么都没发生"的桌面，
/// 他能看到的只有"我装了个东西，但它在哪"。
///
/// ## 为什么是**一页**（原先是三步）
///
/// 原先拆成「它是什么 / 挑一个键 / 权限」三步。三步的代价是**每步都要点一次继续**，
/// 而它真正要说的只有三句话 —— 摊成三页，用户要多点两次才能开始用，
/// 换来的只是每页更空。
///
/// 现在一页说完，**没有「上一步 / 继续」**：看完直接按「开始使用」。
/// 四件事一件不少 —— 它在菜单栏、键在这儿就能改、**图存哪儿也在这儿定**、还差什么权限。
///
/// ## 为什么「保存位置」要问在这里
///
/// 这个 app 的日常截图**只进剪贴板**，落盘是 `⌘S` 才发生的事 —— 也就是说，
/// 第一次 `⌘S` 时用户才知道"还要选个文件夹"。那是个**最差的时机**：
/// 他正急着把图存下来，却被一个面板拦住。
///
/// 更要紧的是审核那一条：Apple 按 2.4.5(i) 打回时给的原话是
/// 「让用户通过标准的 Open/Save 面板选择默认位置」。引导页正是**第一件**事，
/// 用户在这里选一次，后面每一张 `⌘S` 都不必再问（security-scoped 书签记住它）。
///
/// ⚠️ 但它**不是必答题**：没选也能「开始使用」，那一格显示「未选择 · 第一次保存时选」，
/// 第一次 `⌘S` 时再问。引导页拦着人不让走，比没问过更糟。
///
/// ## 文案原则：能删就删
///
/// 引导页没人会读完。所以每一句都要回答一个问题，答不上就删：
///
/// - **它是什么 / 在哪** → 标题（一句话）
/// - **怎么用** → 副标题（一句话）
/// - **能干什么** → 一行名词，**不带解释**（细节留给菜单栏，那儿本来就有）
/// - **键怎么改** → 控件本身（能操作就不用说明）
/// - **还差什么** → 权限行（状态 + 一个按钮）
///
/// 原先六行「能力 —— 说明」的表被整段砍掉：那是**产品介绍**，不是引导。
/// 引导只需要让人能**开始用**，剩下的他自己会点。
///
/// 关窗口也算跳过（状态照样记下，下次不再弹）。
@MainActor
final class OnboardingWindowController: NSWindowController {

    /// 引导结束（走完或跳过）。宿主据此落状态。
    var onFinish: (() -> Void)?

    // MARK: - 依赖

    private let shortcut: ShortcutService
    private let onShortcutChanged: (KeyCombo) -> Void
    private let currentPermission: () -> ScreenRecordingPermission
    /// 保存位置那一格要读写它：**与偏好页同一个存储**，两处改的是同一件事。
    private let output: UserDefaultsOutputStore

    // MARK: - 控件

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let featureLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private let recorder: ShortcutRecorderView
    private let shortcutStatus = NSTextField(labelWithString: "")
    /// 路径文本本身。走 `byTruncatingMiddle` —— 路径最有信息量的两头是
    /// 开头的盘符/家目录与结尾的文件夹名，从尾巴截会把后者切掉。
    private let directoryLabel = NSTextField(labelWithString: "")
    private let chooseDirectoryButton = NSButton()
    private let permissionStatus = NSTextField(labelWithString: "")
    private let openSettingsButton = NSButton()
    private let startButton = NSButton()

    init(shortcut: ShortcutService,
         output: UserDefaultsOutputStore,
         currentPermission: @escaping () -> ScreenRecordingPermission,
         onShortcutChanged: @escaping (KeyCombo) -> Void) {
        self.shortcut = shortcut
        self.output = output
        self.currentPermission = currentPermission
        self.onShortcutChanged = onShortcutChanged
        recorder = ShortcutRecorderView(combo: shortcut.current)

        // 高度从 336 加到 368：多了一行「保存位置」，而那一行**不能挤**掉底部的
        // 权限行与「开始使用」—— 让弹性占位缩到 0 的代价是英文界面下开始换行/压字。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 368),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.t("欢迎使用 Marquee") + AppIdentity().developmentTitleSuffix
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        recorder.onRecord = { [weak self] combo in self?.apply(combo) }
        // 与偏好页同一个动作、同一个理由：录制期间不挂起全局注册的话，
        // 用户按下自己正用的那颗键会被 Carbon 吃掉（录制器收不到 + 真的截屏）。
        recorder.onRecordingChanged = { [weak self] isRecording in
            guard let self else { return }
            if isRecording {
                self.shortcut.suspendForRecording()
            } else {
                self.shortcut.resumeAfterRecording()
            }
        }
        window.delegate = self

        build()
        refreshPermissionStatus()
        refreshDirectory()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController 只支持代码创建")
    }

    /// 呈现。与设置窗口同一个坑（PITFALLS 54）：Marquee 是 `.accessory` 应用，
    /// `makeKeyAndOrderFront` 依赖应用已激活。
    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    // MARK: - 骨架

    private func build() {
        guard let window else { return }

        titleLabel.stringValue = L10n.t("Marquee 就在菜单栏")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.stringValue = L10n.t("按一下快捷键，屏幕冻住，框出要截的地方。")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        // 只给名词，不给解释 —— 说明留给菜单栏，那儿本来就有。
        featureLabel.stringValue = L10n.t("截图 · 标注 · 滚动截屏 · 识别文字 · 钉图")
        featureLabel.font = .systemFont(ofSize: 12)
        featureLabel.textColor = .tertiaryLabelColor

        keyLabel.stringValue = L10n.t("截屏快捷键")
        keyLabel.font = .systemFont(ofSize: 12)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.alignment = .right
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        // 与键那一行**同一套排版**（右对齐标签 + 右侧控件）。
        // 两行的标签等宽，左边缘才对得齐 —— 这不是装饰，是"这两件事属于同一类设置"
        // 唯一的视觉线索；宽度各写一个数就会错开，而错开之后看着像两个不相干的区块。
        let directoryCaption = NSTextField(labelWithString: L10n.t("保存位置"))
        directoryCaption.font = .systemFont(ofSize: 12)
        directoryCaption.textColor = .secondaryLabelColor
        directoryCaption.alignment = .right
        directoryCaption.translatesAutoresizingMaskIntoConstraints = false

        // ⚠️ 宽度**按文字量**，不写死 84：中文「截屏快捷键」84 点够，
        // 英文「Capture shortcut」不够 —— 写死就变成英文界面下被截成
        // 「Capture shortc」，而这一页的图是要上传商店的（2026-10-20 在英文版
        // 商店截图上撞见）。两行取同一个宽度才对齐，所以取两者的最大值；
        // 下限留给 84，免得中文下录制框左移、把已定的版面挪位。
        let captionWidth = max(84,
                               keyLabel.intrinsicContentSize.width + 2,
                               directoryCaption.intrinsicContentSize.width + 2)
        NSLayoutConstraint.activate([
            keyLabel.widthAnchor.constraint(equalToConstant: captionWidth),
            directoryCaption.widthAnchor.constraint(equalToConstant: captionWidth),
        ])

        directoryLabel.font = .systemFont(ofSize: 12)
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        // 可压缩：窗宽只有 440，路径几乎总比留给它的空间长。
        // 不许截断的话它会**把「选择…」顶出窗口**，而那颗按钮是这一行唯一的出口。
        directoryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chooseDirectoryButton.title = L10n.t("选择…")
        chooseDirectoryButton.bezelStyle = .rounded
        chooseDirectoryButton.controlSize = .small
        chooseDirectoryButton.target = self
        chooseDirectoryButton.action = #selector(chooseDirectory)
        chooseDirectoryButton.setContentHuggingPriority(.required, for: .horizontal)

        // 改键的反馈（成功 / 冲突）。空着时它只是一条看不见的窄行，
        // 不占地方也不动布局 —— 所以不必做成"有事才插进来"。
        shortcutStatus.font = .systemFont(ofSize: 11)
        shortcutStatus.textColor = .secondaryLabelColor
        shortcutStatus.maximumNumberOfLines = 2
        shortcutStatus.lineBreakMode = .byWordWrapping
        shortcutStatus.preferredMaxLayoutWidth = 384

        permissionStatus.font = .systemFont(ofSize: 13, weight: .medium)

        openSettingsButton.title = L10n.t("打开系统设置")
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSystemSettings)

        startButton.title = L10n.t("开始使用")
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startUsing)

        let header = NSStackView(views: [titleLabel, subtitleLabel, featureLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8

        let keyRow = NSStackView(views: [keyLabel, recorder])
        keyRow.orientation = .horizontal
        keyRow.alignment = .centerY
        keyRow.spacing = 12

        let directoryRow = NSStackView(views: [directoryCaption, directoryLabel, chooseDirectoryButton])
        directoryRow.orientation = .horizontal
        directoryRow.alignment = .centerY
        directoryRow.spacing = 12

        let permissionRow = NSStackView(views: [permissionStatus, NSView(), openSettingsButton])
        permissionRow.orientation = .horizontal
        permissionRow.alignment = .centerY
        permissionRow.spacing = 12

        let actionRow = NSStackView(views: [NSView(), startButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY

        // 中间那个空 `NSView` 是弹性占位：它把权限行与按钮压到底部，
        // 上半部分保持紧凑。与原先 footer 里那个横向占位同一个做法。
        let root = NSStackView(views: [header, keyRow, shortcutStatus, directoryRow,
                                       NSView(), permissionRow, actionRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 22, right: 28)
        root.setCustomSpacing(20, after: header)
        root.setCustomSpacing(6, after: keyRow)
        // 只留 8：中间那行状态**空着时也占一整行高度**（它是个固定高度的标签），
        // 再叠上 16 就会让「保存位置」离开快捷键行一截 —— 而这两行是**同一组设置**，
        // 分开看就成了两个不相干的区块。
        root.setCustomSpacing(8, after: shortcutStatus)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)

        // 每一行都钉到"根宽度减去左右内边距"：不然行会缩到内容的自然宽度，
        // 弹性占位就没有可撑开的空间了。
        let rows = [header, keyRow, shortcutStatus, directoryRow, permissionRow, actionRow]
        NSLayoutConstraint.activate(
            [
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ]
            + rows.map { $0.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56) }
        )
        window.contentView = content
    }

    // MARK: - 收尾

    /// 唯一一条出口。**这里不调 `onFinish`** —— `close()` 会触发 `windowWillClose`，
    /// 那才是唯一的收尾点。两处各调一次的话状态会被写两遍，
    /// 而且将来有人往其中一个里加了动作，它就会执行两次。
    @objc private func startUsing() {
        close()
    }

    // MARK: - 改键

    /// 与偏好页**同一套**逻辑（`PreferencesWindowController.apply`）——
    /// 两处各写一遍的话，"改键失败要回滚显示"这类细节必然只修一处。
    private func apply(_ combo: KeyCombo) {
        let result = shortcut.change(to: combo)
        if let message = result.failureMessage {
            shortcutStatus.stringValue = message
            shortcutStatus.textColor = .systemRed
            recorder.update(combo: shortcut.current)
            window?.makeFirstResponder(recorder)
        } else {
            shortcutStatus.stringValue = L10n.t("已生效：\(combo.displayString)")
            shortcutStatus.textColor = .secondaryLabelColor
            onShortcutChanged(combo)
        }
    }

    // MARK: - 保存位置

    /// 面板选完（或用户在别处改过）之后，把这一格重读一遍。
    ///
    /// 文案来自 `OutputSettings.directorySummary`（Core）—— 与偏好页**同一个来源**。
    /// 这一格不自己拼"未选择"那句话：两处各写一遍，改文案时只会改一处，
    /// 于是同一个状态在两个窗口里说法不同。
    private func refreshDirectory() {
        let chosen = output.settings().directory
        directoryLabel.stringValue = output.settings().directorySummary
        // 路径被中段截断时，完整路径还得看得见 —— 悬停提示是唯一不占宽度的去处。
        directoryLabel.toolTip = chosen?.path
    }

    /// 选一个保存位置。**必须是标准面板**：Apple 认可的位置来源只有这一个
    /// （2.4.5(i) 的原话是 "using standard Open/Save dialogs"）。
    ///
    /// 与偏好页那一处是同一个动作、同一个存储入口 —— 它写路径 + security-scoped 书签，
    /// 少了书签，沙盒构建下次启动就写不进去了（见 `UserDefaultsOutputStore.saveDirectory`）。
    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = output.settings().directory ?? OutputSettings.savePanelStartDirectory()
        panel.prompt = L10n.t("选这个文件夹")
        // 取消 = 什么都不改。**不许**拿"没选"去覆盖已经选过的那个目录。
        guard panel.runModal() == .OK, let url = panel.url else { return }
        output.saveDirectory(url, bookmark: OutputSettings.securityScopedBookmark(for: url))
        refreshDirectory()
    }

    // MARK: - 权限

    /// 权限可能在**别的窗口里**被改掉（用户在系统设置里勾完再切回来），
    /// 所以每次切回本应用都重读一次状态 —— 只查一次的话，用户会看到
    /// "我明明勾了，它还说没有"。
    ///
    /// 状态与按钮**同一条判据**：已授权就把按钮藏起来，别让一个已经做完的动作
    /// 还立在那儿等人点。
    func refreshPermissionStatus() {
        switch currentPermission() {
        case .granted:
            permissionStatus.stringValue = L10n.t("屏幕录制：已授权")
            permissionStatus.textColor = .systemGreen
            openSettingsButton.isHidden = true
        case .notDetermined, .denied:
            permissionStatus.stringValue = L10n.t("屏幕录制：还没授权")
            permissionStatus.textColor = .systemOrange
            openSettingsButton.isHidden = false
        }
    }

    @objc private func openSystemSettings() {
        NSWorkspace.shared.open(SystemSettingsLink.screenRecording)
    }
}

// MARK: - 关窗口也算跳过

extension OnboardingWindowController: NSWindowDelegate {

    /// 用户直接点红叉 = 跳过。**状态照样记下** —— 不记的话下次启动还会弹，
    /// 而"我明明关过它"是最容易让人对一个 app 起反感的一类细节。
    func windowWillClose(_ notification: Notification) {
        onFinish?()
    }
}

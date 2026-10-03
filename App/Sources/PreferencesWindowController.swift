import AppKit
import MarqueeCore

/// 偏好设置窗口：**正好四页**（PRD 3.1 的硬约束）。
///
/// ## 没有「确定 / 应用」按钮
///
/// 改一下**立刻生效、立刻落盘**。这类工具的偏好项都是一眼能看出效果的小开关，
/// 而"改完忘了点应用"是这类窗口最经典的坑。
///
/// 而"我怎么知道刚才那一下生效了"这个问题由两样东西回答（稿子 §03 / §04）：
///
/// 1. **窗底常驻一行字**「所有更改会立刻生效并自动保存」—— 它是这一整页的总回执；
/// 2. **每一项自己的回执**：开关当场动、分段当场换档、**说明句跟着改写**。
///    延时与质量这两项改了当场看不出效果（要等下一次按快捷键 / 下一次存盘），
///    所以它们的回执**全押在说明句上** —— 见 `ChromeRow.setSubtitle` 的两处调用。
///
/// ## 两处刻意的"不达标"
///
/// - **开机自启失败时界面必须等于系统里的真实状态**：关闭开关 + 琥珀行 + 一个能直接
///   点开的去处（`SystemSettingsLink.loginItems`）。指示一个方向不算数 ——
///   用户卡住的地方正是"跟着一句话找三级菜单"。
/// - **恢复购买点了就一定有回话**（五种结果常驻，不自动消失）。用户主动点的动作，
///   悄悄失败等于骗他。而且**回话要说准原因**：只有真的连不上才提网络，
///   用户自己按的取消既不报红也不说"失败"。
@MainActor
final class PreferencesWindowController: NSWindowController {

    /// 快捷键变更且已生效
    var onShortcutChanged: ((KeyCombo) -> Void)?
    /// 通用 / 截屏页改动后通知宿主（它要据此调整采集器与登录项）
    var onPreferencesChanged: (() -> Void)?

    private let shortcut: ShortcutService
    private let preferences: UserDefaultsPreferencesStore
    private let output: UserDefaultsOutputStore

    private let tabBar = ChromeTabBar()
    private let container = NSView()
    private let footer = NSTextField(labelWithString: "")
    private var pages: [SettingsPage: NSView] = [:]
    private var currentPage: SettingsPage = .general

    // 通用
    private let soundSwitch = ChromeSwitch()
    private let launchSwitch = ChromeSwitch()
    private lazy var launchRow = ChromeRow(title: L10n.t("开机时自动启动"),
                                           subtitle: L10n.t("Marquee 常驻菜单栏，开机就有"),
                                           control: launchSwitch)
    // 通用页底部的 Pro 状态区（ticket 31）
    private let proStatusLabel = NSTextField(labelWithString: "")
    private let proOutcomeLabel = NSTextField(labelWithString: "")
    /// 「升级到 Pro」—— 稿子偏好稿里的**唯一色块**（蓝实心、在左）。
    private let proActionButton = ChromeFilledButton()
    /// 「恢复购买」—— 稿子里它是**纯文字**（无底无框，在色块的右边）。
    private let proRestoreButton = ChromeTextButton()
    private let proPanel = ChromePanel()

    // 截屏
    private let cursorSwitch = ChromeSwitch()
    private let shadowSwitch = ChromeSwitch()
    private let delaySegmented = ChromeSegmented()
    private lazy var delayRow = ChromeRow(title: L10n.t("延时截图"),
                                          subtitle: L10n.t("按下快捷键后立刻出现覆盖层"),
                                          control: delaySegmented)

    // 输出
    private let directoryLabel = NSTextField(labelWithString: "")
    private let formatSegmented = ChromeSegmented()
    private let qualitySlider = ChromeSlider()
    private lazy var qualityRow = ChromeRow(title: L10n.t("质量"),
                                            subtitle: "",
                                            control: qualitySlider)
    private let templateField = NSTextField()

    // 快捷键
    private let recorder: ShortcutRecorderView
    private let shortcutStatus = NSTextField(labelWithString: "")

    init(shortcut: ShortcutService,
         preferences: UserDefaultsPreferencesStore,
         output: UserDefaultsOutputStore) {
        self.shortcut = shortcut
        self.preferences = preferences
        self.output = output
        recorder = ShortcutRecorderView(combo: shortcut.current)

        // 440 宽是稿子给的（§03 的示意窗就是 440）。高度按**最高的一页**定
        //（输出页：4 行 + 变量行），否则切到那一页会看到内容被压扁。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 430),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.t("Marquee 设置") + AppIdentity().developmentTitleSuffix
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        buildShell()
        recorder.onRecord = { [weak self] combo in self?.apply(combo) }
        // 录制期间挂起全局快捷键：不挂起的话，用户按下的**当前那颗键**
        // 会被 Carbon 在系统层面吃掉 —— 录制器收不到，反而真的开始截屏。
        recorder.onRecordingChanged = { [weak self] isRecording in
            guard let self else { return }
            if isRecording {
                self.shortcut.suspendForRecording()
            } else {
                self.shortcut.resumeAfterRecording()
            }
        }
        loadAll()
        // 权益一变就刷新状态区（ticket 31）。注册时会**立刻回调一次当前值**，
        // 所以不必在 `loadAll` 里再手写一遍初始渲染 —— 那两处迟早会不一致。
        ProEntitlement.shared.observe { [weak self] snapshot in
            self?.applyProSnapshot(snapshot)
        }
    }

    /// 打开设置并切到某一页。「了解 Pro」那条路要用 —— 状态区在通用页。
    ///
    /// 内部走 `present(page:)` 而不是自己摆一遍窗口：那个方法里有 `.accessory` 应用
    /// 必须的 `orderFrontRegardless()`（PITFALLS 54），自己写一遍必漏。
    func show(page: SettingsPage) {
        present(page: page)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreferencesWindowController 只支持代码创建")
    }

    // MARK: - 展示

    /// Pro 状态区那一块在**窗口内容坐标**里的矩形（y 向上，原点在内容左下角）。
    ///
    /// 给 `ReviewShots` 画审核截图的标注框用（"购买入口在这里"）。
    /// **为什么是运行期算的而不是源码里估的**：布局一改，估的坐标会**静静地**
    /// 指到别处 —— 而那张图会被原样上传给审核，谁也不会在开发机上发现。
    var proPanelFrameInContent: CGRect? {
        guard let content = window?.contentView, proPanel.superview != nil else { return nil }
        content.layoutSubtreeIfNeeded()
        return proPanel.convert(proPanel.bounds, to: content)
    }

    /// 呈现窗口。`page` 给了就切到那一页 —— 从「了解 Pro」进来时要直接落到通用页
    /// （状态区在那儿），而不是用户上次停在的那一页。
    func present(page: SettingsPage? = nil) {
        loadAll()
        select(page ?? currentPage)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 与编辑器窗口同一个坑：Marquee 是 `.accessory` 应用，
        // `makeKeyAndOrderFront` 依赖应用已激活（PITFALLS 54）。
        window?.orderFrontRegardless()
    }

    // MARK: - 外壳

    /// 标签条上的四格。
    ///
    /// ⚠️ 图标一律用**语言无关**的（见 `ChromeTabBar` 那段）：SF Symbol 里有一批
    /// 会自动本地化，中文环境下会渲染成汉字。
    private static let tabs: [ChromeTabBar.Tab] = [
        .init(symbol: "gearshape", title: L10n.t("通用")),
        .init(symbol: "camera", title: L10n.t("截屏")),
        .init(symbol: "folder", title: L10n.t("输出")),
        .init(symbol: "keyboard", title: L10n.t("快捷键")),
    ]

    private func buildShell() {
        guard let window else { return }

        tabBar.tabs = Self.tabs
        tabBar.selectedIndex = 0
        tabBar.onChange = { [weak self] in
            guard let self else { return }
            let index = min(tabBar.selectedIndex, SettingsPage.allCases.count - 1)
            select(SettingsPage.allCases[index])
        }

        // 窗底那行字：它是"没有应用按钮"这件事的**总回执**。
        // 少了它，"改完就这么算了？"这个疑问没有地方被回答。
        footer.stringValue = L10n.t("所有更改会立刻生效并自动保存")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = ChromePalette.Theme.current.label2.nsColor

        for view in [tabBar, container, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(view)
        }
        guard let content = window.contentView else { return }

        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            // 标签条在标题栏下方 8 点；行区的第一行从窗顶往下 **88 点**开始
            //（稿子 §03：「所有页的第一行都从同一条基线开始……翻页时眼睛不用重新找起点」）。
            tabBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                             constant: -margin),

            container.topAnchor.constraint(equalTo: content.topAnchor, constant: 68),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            footer.topAnchor.constraint(greaterThanOrEqualTo: container.bottomAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        pages = [
            .general: makeGeneralPage(),
            .capture: makeCapturePage(),
            .output: makeOutputPage(),
            .shortcuts: makeShortcutsPage(),
        ]
        select(.general)
    }

    /// 切到某一页。**对照材料也用它**（`ComplianceSheet` 要把四页各渲一张）——
    /// 那条路与真机的点标签走的是**同一份代码**，专门另开一条就分叉了。
    func select(_ page: SettingsPage) {
        currentPage = page
        tabBar.selectedIndex = SettingsPage.allCases.firstIndex(of: page) ?? 0
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let view = pages[page] else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    // MARK: - 四页

    private func makeGeneralPage() -> NSView {
        bind(soundSwitch, label: L10n.t("截图后播放提示音")) { [weak self] in
            self?.generalChanged()
        }
        bind(launchSwitch, label: L10n.t("开机时自动启动")) { [weak self] in
            self?.launchChanged()
        }
        // 这一行会有第三行（注册失败时），所以先把位置留出来
        launchRow.installNoticeRow()

        let proPanel = makeProPanel()
        let general = page([
            ChromeRow(title: L10n.t("截图后播放提示音"),
                      subtitle: L10n.t("截成功时播一声系统音效 · 关掉适合连着截很多张的时候"),
                      control: soundSwitch),
            ChromeSeparator(),
            launchRow,
            ChromeSeparator(),
            proPanel,
        ])
        // ⚠️ 面板要**铺满整列宽**（与上面每一行一样）。它自己撑不开 ——
        // `NSStackView` 的 `.width` 对齐对它不生效（面板内部那几条"内容贴着边"的约束
        // 给出了一个更小、更硬的宽度），实测下来它会缩到内容宽并**贴到右边**。
        // 钉 `equalTo: general.widthAnchor` 而不是写一个 400 那样的数：
        // 那个数要与窗宽、边距三处同源，而这一条自己就是"与整列同宽"的意思。
        proPanel.widthAnchor.constraint(equalTo: general.widthAnchor).isActive = true
        return general
    }

    /// 通用页底部的 Pro 状态区（ticket 31）。
    ///
    /// **刻意不新增第 5 页** —— PRD 3.1 定了"首选项 ≤ 4 页"，多一页的收益远小于
    /// 破坏一条已写进产品文档的约束（`SettingsPage` 那个枚举与守着它的测试都在拦着，
    /// 那份摩擦是刻意的）。状态区接在通用页最底下，信息密度也刚好。
    private func makeProPanel() -> NSView {
        proStatusLabel.font = .systemFont(ofSize: 12)
        proStatusLabel.lineBreakMode = .byTruncatingTail
        proStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        // 稿子偏好稿 §C：状态句在上，按钮行在它下面 ——
        // 「升级到 Pro」是**唯一色块**（蓝实心、在左），「恢复购买」是**纯文字**（在右）。
        // 之前是两颗系统圆角按钮并排在状态句右边：主次靠"哪个有底"说不清，
        // 与稿子「一个色块 + 一个文字按钮」正好相反。
        proRestoreButton.title = L10n.t("恢复购买")
        proRestoreButton.emphasis = .quiet
        proRestoreButton.onActivate = { [weak self] in self?.proRestoreTapped() }

        proActionButton.title = L10n.t("升级到 Pro")
        proActionButton.onActivate = { [weak self] in self?.proActionTapped() }

        let buttons = NSStackView(views: [proActionButton, proRestoreButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = ProCardLayout.buttonGap
        buttons.spacing = 8

        // 稿子是**两行**：状态句一行，按钮行在它下面（都不居中、都贴左）。
        // 之前把三个挤在一行，于是状态句长一点就会把按钮挤出面板。
        proStatusLabel.font = .systemFont(ofSize: 12)
        let body = NSStackView(views: [proStatusLabel, buttons])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12

        // 「刚才那一下」的回执行（常驻）。它在**按钮下方** ——
        // 属于刚才那一下，不属于上面那句整句状态（稿子 §04）。
        // **两个动作共用这一行**：升级到 Pro 与恢复购买结果同源，
        // 各开一行的话两句话会同时在屏幕上互相打架。
        proOutcomeLabel.font = .systemFont(ofSize: 11)
        proOutcomeLabel.stringValue = ""
        // 允许折成两行：开发版那条"商店里没有这个商品"的提示比其余几句长
        //（它要给出可执行的下一步）。不折的话它会撑着面板往右长。
        // 折行宽度与行数上限都取自 Core —— 有一条断言在按同一个数量这些文案。
        proOutcomeLabel.maximumNumberOfLines = ChromeControl.proPanelOutcomeLineLimit
        proOutcomeLabel.lineBreakMode = .byWordWrapping
        proOutcomeLabel.preferredMaxLayoutWidth = ChromeControl.proPanelTextWidth

        proPanel.setContent([body, proOutcomeLabel])
        proPanel.translatesAutoresizingMaskIntoConstraints = false
        return proPanel
    }

    private func makeCapturePage() -> NSView {
        bind(cursorSwitch, label: L10n.t("截图里包含鼠标指针")) { [weak self] in
            self?.captureChanged()
        }
        bind(shadowSwitch, label: L10n.t("窗口截图带阴影")) { [weak self] in
            self?.captureChanged()
        }

        delaySegmented.titles = CapturePreferences.delayOptions.map {
            $0 == 0 ? L10n.t("不延时") : L10n.t("\($0) 秒")
        }
        delaySegmented.onChange = { [weak self] in self?.captureChanged() }

        return page([
            ChromeRow(title: L10n.t("截图里包含鼠标指针"),
                      subtitle: L10n.t("光标会画在图上 · 它常正好压在你要截的内容上"),
                      control: cursorSwitch),
            ChromeSeparator(),
            ChromeRow(title: L10n.t("窗口截图带阴影"),
                      subtitle: L10n.t("用系统的窗口阴影 · 在覆盖层里按住 ⌥ 可临时反转这一项"),
                      control: shadowSwitch),
            ChromeSeparator(),
            delayRow,
        ])
    }

    private func makeOutputPage() -> NSView {
        directoryLabel.font = .systemFont(ofSize: 12)
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false

        let chooseButton = NSButton(title: L10n.t("选择…"),
                                    target: self, action: #selector(chooseDirectory))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small

        let directoryRow = NSStackView(views: [directoryLabel, chooseButton])
        directoryRow.orientation = .horizontal
        directoryRow.spacing = 8

        // 格式名**不本地化**，直接从模型取（`PNG` / `JPEG` / `HEIC` 在中文界面里
        // 也是这三个字母）—— 自己再写一遍就多了一份会与模型分叉的事实。
        formatSegmented.titles = ImageFileFormat.allCases.map(\.displayName)
        formatSegmented.onChange = { [weak self] in self?.outputChanged() }

        qualitySlider.readout = "80%"
        qualitySlider.onChange = { [weak self] in self?.outputChanged() }

        templateField.target = self
        templateField.action = #selector(outputChanged)
        templateField.placeholderString = FileNameTemplate.defaultTemplate
        templateField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        templateField.translatesAutoresizingMaskIntoConstraints = false
        templateField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        return page([
            ChromeRow(title: L10n.t("保存位置"),
                      subtitle: L10n.t("只有按 ⌘S 或点覆盖层里的「保存」才写盘 · 日常截图直接进剪贴板"),
                      control: directoryRow),
            ChromeSeparator(),
            ChromeRow(title: L10n.t("图片格式"),
                      subtitle: L10n.t("PNG 无损 · JPEG / HEIC 有损"),
                      control: formatSegmented),
            ChromeSeparator(),
            qualityRow,
            ChromeSeparator(),
            ChromeRow(title: L10n.t("文件名模板"),
                      subtitle: L10n.t("每一份存盘文件的名字"),
                      control: templateField),
            makeVariableRow(),
        ])
    }

    /// 变量行。稿子 §01：「36 变量行」，稿子 §03：「`可用变量 · 点一下插到模板光标处`」——
    /// 五个 chip **可点**，点一下插到模板光标处。
    ///
    /// ⚠️ 常驻而不是折叠起来：没人记得住变量名，而"记不住"的表现是
    /// **用户直接放弃用模板**，不是"他去翻文档"。
    private func makeVariableRow() -> NSView {
        let caption = NSTextField(labelWithString: L10n.t("可用变量 · 点一下插到模板光标处"))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = ChromePalette.Theme.current.label2.nsColor

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.spacing = 6
        for token in FileNameTemplate.availableTokens {
            let button = NSButton(title: token, target: self, action: #selector(insertToken(_:)))
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            chips.addArrangedSubview(button)
        }

        let stack = NSStackView(views: [caption, chips])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        return stack
    }

    private func makeShortcutsPage() -> NSView {
        shortcutStatus.font = .systemFont(ofSize: 11)
        shortcutStatus.maximumNumberOfLines = 2
        shortcutStatus.lineBreakMode = .byWordWrapping
        shortcutStatus.preferredMaxLayoutWidth = 400
        shortcutStatus.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: L10n.t("恢复默认"), target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .rounded
        reset.controlSize = .small

        let hint = NSTextField(labelWithString:
            L10n.t("Marquee 不在前台也能触发 · 任何时候按它，屏幕就定住"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = ChromePalette.Theme.current.label2.nsColor
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 400

        // 录制器整件搬到这里（与引导页那个是同一个控件、同一套尺寸）。
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 400).isActive = true

        return page([
            ChromeRow(title: L10n.t("全屏截图"),
                      subtitle: L10n.t("随时可截 · 全局生效"),
                      control: reset),
            ChromeSeparator(),
            recorder,
            // 三种反馈（录制中 / 冲突 / 已改）**都只用这一条状态槽说话** ——
            // 不在窗口里另开一行错误提示（稿子 §04）。
            shortcutStatus,
            hint,
        ])
    }

    // MARK: - 控件工厂

    /// 一页：若干行**上下叠着，铺满整列宽**。
    ///
    /// ⚠️ `alignment` 必须是 `.width` 而不是 `.leading`：行是"一行标题 + 右侧一个控件"
    /// 的布局，靠 `leading` 对齐的话每行只有自己的内在宽度，
    /// 于是右侧那列控件会**各对各的左边**，整页看起来像没对齐过。
    /// 稿子 §03 那句"所有页的第一行都从同一条基线开始"要的正是这种整齐。
    private func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        return stack
    }

    /// 把开关接到它的写盘路径上。
    ///
    /// 用闭包而不是 `Selector`：`ChromeSwitch` 是自绘的，**不是 `NSControl`**，
    /// 没有 target-action 那一套。硬套的话就得自己造一个 `NSControl` 的子类假装是，
    /// 而那个假身份只为了省一次闭包 —— 不划算。
    private func bind(_ control: ChromeSwitch, label: String, _ handler: @escaping () -> Void) {
        control.label = label
        control.onChange = handler
    }

    // MARK: - 读写

    private func loadAll() {
        let general = preferences.general()
        soundSwitch.isOn = general.playSound
        launchSwitch.isOn = general.launchAtLogin
        launchRow.setNotice("")

        let capture = preferences.capture()
        cursorSwitch.isOn = capture.includeCursor
        shadowSwitch.isOn = capture.includeShadow
        delaySegmented.selectedIndex = CapturePreferences.delayOptions
            .firstIndex(of: capture.delaySeconds) ?? 0
        refreshDelayExplanation()

        let settings = output.settings()
        directoryLabel.stringValue = settings.directory.path
        formatSegmented.selectedIndex = ImageFileFormat.allCases.firstIndex(of: settings.format) ?? 0
        qualitySlider.value = settings.quality
        refreshQuality()
        // 无损格式下**只置灰滑块**，行标题与说明句照常读得出 —— 见 `refreshQuality`
        qualitySlider.isEnabledControl = settings.format.isLossy
        templateField.stringValue = settings.nameTemplate
        recorder.update(combo: shortcut.current)
        shortcutStatus.stringValue = L10n.t("当前：\(shortcut.current.displayString)")
        shortcutStatus.textColor = ChromePalette.Theme.current.label2.nsColor
    }

    /// 延时那一行的说明句 —— **它是这一项唯一的回执**（改了当场看不出效果）。
    private func refreshDelayExplanation() {
        let index = delaySegmented.selectedIndex
        let seconds = CapturePreferences.delayOptions.indices.contains(index)
            ? CapturePreferences.delayOptions[index]
            : 0
        delayRow.setSubtitle(CapturePreferences.delayExplanation(seconds: seconds,
                                                                combo: shortcut.current))
    }

    /// 质量那一行：读数 + 说明句。说明句随格式的有损/无损换。
    private func refreshQuality() {
        qualitySlider.readout = "\(Int((qualitySlider.value * 100).rounded()))%"
        let index = formatSegmented.selectedIndex
        let format = ImageFileFormat.allCases.indices.contains(index)
            ? ImageFileFormat.allCases[index]
            : .png
        qualityRow.setSubtitle(format.qualityExplanation)
    }

    private func generalChanged() {
        preferences.save(GeneralPreferences(playSound: soundSwitch.isOn,
                                           launchAtLogin: preferences.general().launchAtLogin))
        onPreferencesChanged?()
    }

    private func launchChanged() {
        let wants = launchSwitch.isOn
        // 交给宿主去真正注册（它才知道 `SMAppService` 的结果）。
        // 失败时**必须把开关拨回去**，否则界面上显示"已开启"而系统里没有 ——
        // 那种不一致用户只能靠重启去发现。
        launchRow.setNotice("")
        preferences.save(GeneralPreferences(playSound: preferences.general().playSound,
                                           launchAtLogin: wants))
        onPreferencesChanged?()
    }

    /// 宿主在登录项注册失败后回调：把开关拨回去 + 琥珀行 + 一个能直接点开的去处。
    func reportLaunchAtLogin(failure message: String?) {
        if let message {
            launchSwitch.isOn = false
            launchRow.setNotice(message,
                                actionTitle: L10n.t("打开登录项设置"),
                                target: self,
                                action: #selector(openLoginItems))
            preferences.save(GeneralPreferences(playSound: preferences.general().playSound,
                                                launchAtLogin: false))
        } else {
            // 成功**不留痕**：这一行的常态就是开关本身，加一句"已加入登录项"是多余的噪音。
            // （只有失败才需要一行**不会自己走**的待办。）
            launchRow.setNotice("")
        }
    }

    @objc private func openLoginItems() {
        NSWorkspace.shared.open(SystemSettingsLink.loginItems)
    }

    @objc private func insertToken(_ sender: NSButton) {
        let token = sender.title
        let field = templateField
        // 插到**光标处**而不是末尾：用户可能正想改中间那一段
        // `currentEditor()` 返回的是 `NSText` 协议，它只有 `insertText(_:)` ——
        // 要"插到光标处"得拿 `NSTextView`（`replacementRange` 在它上面）。
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertText(token, replacementRange: editor.selectedRange())
        } else {
            field.stringValue += token
        }
        outputChanged()
    }

    private func captureChanged() {
        let index = delaySegmented.selectedIndex
        let delay = CapturePreferences.delayOptions.indices.contains(index)
            ? CapturePreferences.delayOptions[index]
            : 0
        preferences.save(CapturePreferences(includeCursor: cursorSwitch.isOn,
                                           includeShadow: shadowSwitch.isOn,
                                           delaySeconds: delay))
        refreshDelayExplanation()
        onPreferencesChanged?()
    }

    @objc private func outputChanged() {
        let formatIndex = formatSegmented.selectedIndex
        let format = ImageFileFormat.allCases.indices.contains(formatIndex)
            ? ImageFileFormat.allCases[formatIndex]
            : .png
        let template = templateField.stringValue.isEmpty
            ? FileNameTemplate.defaultTemplate
            : templateField.stringValue
        // 无损格式下那块滑块**不可用**，所以它的值不该被写回去（写了也没意义，
        // 而"用户再也调不动它、它却还在改数值"是一类很难解释的行为）。
        qualitySlider.isEnabledControl = format.isLossy
        refreshQuality()
        output.save(OutputSettings(directory: output.settings().directory,
                                   format: format,
                                   quality: qualitySlider.value,
                                   nameTemplate: template))
        // 质量与模板只对"下一次截图"生效，不必重启 —— 采集流程每次都现读设置
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = output.settings().directory
        panel.prompt = L10n.t("选这个文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let settings = output.settings()
        output.save(OutputSettings(directory: url,
                                   format: settings.format,
                                   quality: settings.quality,
                                   nameTemplate: settings.nameTemplate))
        directoryLabel.stringValue = url.path
    }

    // MARK: - Pro 状态区（ticket 31）

    /// 把一份判定贴到界面上。
    ///
    /// **全部从 `snapshot` 推**，界面不许自己拼判据 —— 否则"状态说已购买、
    /// 按钮却写着升级"这类自相矛盾迟早出现（卡片那边也是同一条规矩）。
    private func applyProSnapshot(_ snapshot: EntitlementSnapshot) {
        let palette = ChromePalette.Theme.current
        proStatusLabel.stringValue = Self.proStatusText(snapshot)
        proStatusLabel.textColor = palette.label.nsColor

        // 按钮的**可用性**是判据，放 Core（`Entitlement.allowsUpgradePurchase`）——
        // 散在这里的 `switch` 里时，漏一档就是"某个状态的用户被关在门外"，
        // 而那种错不崩不报错（2026-10-04 就是这么踩的：`.unknown` 置灰 ⇒ 点不动）。
        proActionButton.isEnabled = snapshot.entitlement.allowsUpgradePurchase
        // 文字与可用性**同源**：关掉的那一档必须自己说明为什么关。
        //
        // 价格写在按钮上（"点之前看得见"）：拿不到价格时退回不带价格的那个标题 ——
        // 宁可少说，也不写死一个 `¥36`（每个店面的价格与货币都不同）。
        let price = ProEntitlement.shared.priceText
        if snapshot.entitlement.isPurchased {
            proActionButton.title = L10n.t("已购买")
        } else if let price {
            proActionButton.title = L10n.t("升级到 Pro · \(price)")
        } else {
            proActionButton.title = L10n.t("升级到 Pro")
        }

        // 「恢复购买」**永远可点**：App Review 要求可恢复，
        // 而且"我明明买过"的人第一件事就是找这个按钮。
    }

    private static func proStatusText(_ snapshot: EntitlementSnapshot) -> String {
        switch snapshot.entitlement {
        case .unknown:
            L10n.t("Marquee Pro · 正在确认…")
        case .free:
            L10n.t("Marquee Pro · 免费版（最近截图保留 \(ProLimits.default.freeHistoryLimit) 张）")
        case .trial(let daysLeft):
            L10n.t("Marquee Pro · 试用中，还剩 \(daysLeft) 天")
        case .pro:
            L10n.t("Marquee Pro · 已购买，谢谢")
        case .revoked(let reason):
            switch reason {
            case .storeRevoked: L10n.t("Marquee Pro · 这笔购买已被撤销")
            case .purchaseNotFound: L10n.t("Marquee Pro · 这个账号下找不到这笔购买")
            }
        }
    }

    private func proActionTapped() {
        let palette = ChromePalette.Theme.current
        proOutcomeLabel.stringValue = L10n.t("正在打开 App Store…")
        proOutcomeLabel.textColor = palette.label2.nsColor
        // 买成之后判定会变，状态区靠 `observe` 那条路自己更新 ——
        // 但**结果本身必须有回话**，见 `showPurchaseOutcome`。
        Task { [weak self] in
            let outcome = await ProEntitlement.shared.purchasePro()
            self?.showPurchaseOutcome(outcome)
        }
    }

    /// 购买的结果。
    ///
    /// ⚠️ 这里原本是 `_ = await …purchasePro()` —— **把结果整个丢掉**，
    /// 于是"点了没反应"是唯一可能的表现：取消没有回话、失败没有回话、
    /// **商店里压根没有这个商品也没有回话**（开发版没挂 StoreKit 配置时就是这一档）。
    /// 用户原话：「点击升级到 pro 无效」。
    ///
    /// 与「恢复购买」同一条规矩：**用户主动点的动作，五种结果都常驻**。
    /// 顺带一提，这一行也是**排障的第一手证据** —— 它会当场说出是哪一档。
    private func showPurchaseOutcome(_ outcome: PurchaseOutcome) {
        let palette = ChromePalette.Theme.current
        switch outcome {
        case .purchased:
            proOutcomeLabel.stringValue = L10n.t("已购买 ✓")
            proOutcomeLabel.textColor = palette.success.nsColor
        case .cancelledByUser:
            // 他自己按的取消：不是错误，不报红 —— 与恢复购买同一句话
            proOutcomeLabel.stringValue = L10n.t("已取消，没有改动")
            proOutcomeLabel.textColor = palette.label2.nsColor
        case .pending:
            // 家人共享的"购买前询问"、或银行的额外验证。**既不是成功也不是失败**，
            // 而"什么都没变"正是此刻最难自己搞明白的一件事，所以要说清下一步。
            proOutcomeLabel.stringValue = L10n.t("等待批准 · 批准后会自动解锁")
            proOutcomeLabel.textColor = palette.label2.nsColor
        case .unavailable:
            // **我们这边的问题**（商品没建 / 还没审核过 / bundle id 对不上），
            // 所以不许说成"网络问题"（PITFALLS 180 同一条原则）。
            // 开发版另给一句可执行的下一步 —— 这一档在开发机上最常见的原因
            // 就是"没用 Xcode 运行"，而那句话当场就能排掉。
            proOutcomeLabel.stringValue = AppIdentity().isDevelopmentBuild
                ? L10n.t("暂时买不了 · 商店里没有这个商品（开发版：请用 Xcode 运行，且 scheme 要挂 Products.storekit）")
                : L10n.t("暂时买不了 · 商店里还没有这个商品")
            proOutcomeLabel.textColor = palette.danger.nsColor
        case .failed:
            proOutcomeLabel.stringValue = L10n.t("购买失败 · 请稍后再试")
            proOutcomeLabel.textColor = palette.danger.nsColor
        }
    }

    private func proRestoreTapped() {
        proOutcomeLabel.stringValue = L10n.t("正在恢复…")
        proOutcomeLabel.textColor = ChromePalette.Theme.current.label2.nsColor
        Task { [weak self] in
            let outcome = await ProEntitlement.shared.restorePurchases()
            self?.showRestoreOutcome(outcome)
        }
    }

    /// 恢复购买**必须如实回报** —— 这是用户主动点的动作，
    /// 悄悄失败等于骗他"恢复过了，确实没有记录"。
    ///
    /// ⚠️ **说哪句话不在这里**：五档措辞由 `ProFeedback` 一处决定 ——
    /// 覆盖层里点「恢复购买」也会说同一件事（那儿只有一行提示行），
    /// 两处各写一份的话，"用户取消该说中性的话"这类判断必然只修一处。
    /// 这里只管它的颜色与放置（那一行**常驻**，不自动消失）。
    private func showRestoreOutcome(_ outcome: EntitlementCoordinator.RestoreOutcome) {
        let feedback = ProFeedback.restore(outcome)
        let palette = ChromePalette.Theme.current
        proOutcomeLabel.stringValue = feedback.text
        proOutcomeLabel.textColor = switch feedback.kind {
        case .success: palette.success.nsColor
        case .neutral: palette.label2.nsColor
        case .failure: palette.danger.nsColor
        }
    }

    // MARK: - 快捷键

    private func apply(_ combo: KeyCombo) {
        let palette = ChromePalette.Theme.current
        let result = shortcut.change(to: combo)
        if let message = result.failureMessage {
            // 冲突用**危险红**（`--c-err`），不是琥珀：琥珀是"去系统设置里办点事"，
            // 而冲突的下一步是**就地再按一次**（稿子 §04）。
            shortcutStatus.stringValue = message
            shortcutStatus.textColor = palette.danger.nsColor
            // 改键失败时显示的是回滚后的当前组合，并让用户能立刻再试
            recorder.update(combo: shortcut.current)
            window?.makeFirstResponder(recorder)
        } else {
            shortcutStatus.stringValue = L10n.t("已生效：\(combo.displayString)")
            shortcutStatus.textColor = palette.label2.nsColor
            onShortcutChanged?(combo)
        }
        // 延时那一行的说明句里带着**当前快捷键** —— 改了键它就得跟着改，
        // 否则它会一直指着旧键，而用户会照着它去按。
        refreshDelayExplanation()
    }

    @objc private func resetShortcut() {
        recorder.update(combo: ShortcutService.defaultCombo)
        apply(ShortcutService.defaultCombo)
    }
}

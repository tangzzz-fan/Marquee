import AppKit
import MarqueeCore

/// 偏好设置窗口：**正好四页**（PRD 3.1 的硬约束）。
///
/// ## 为什么用分段控件而不是 `NSTabView`
///
/// `NSTabView` 的顶部标签是十年前的观感，而 ticket 17 的目标是"像系统自带" ——
/// 到时候要换一遍。分段控件 + 自己换内容视图从一开始就是那个样子。
///
/// ## 每一页都**直接写盘**
///
/// 没有"确定 / 应用"按钮：改一下立刻生效、立刻落盘。这类工具的偏好项都是
/// 一眼能看出效果的小开关，而"改完忘了点应用"是这类窗口最经典的坑。
@MainActor
final class PreferencesWindowController: NSWindowController {

    /// 快捷键变更且已生效
    var onShortcutChanged: ((KeyCombo) -> Void)?
    /// 通用 / 截屏页改动后通知宿主（它要据此调整采集器与登录项）
    var onPreferencesChanged: (() -> Void)?

    private let shortcut: ShortcutService
    private let preferences: UserDefaultsPreferencesStore
    private let output: UserDefaultsOutputStore

    private let segmented = NSSegmentedControl()
    private let container = NSView()
    private var pages: [SettingsPage: NSView] = [:]
    private var currentPage: SettingsPage = .general

    // 通用
    private let soundSwitch = NSButton()
    private let launchSwitch = NSButton()
    private let launchNote = NSTextField(labelWithString: "")
    // 通用页底部的 Pro 状态区（ticket 31）
    private let proStatusLabel = NSTextField(labelWithString: "")
    private let proActionButton = NSButton()
    private let proRestoreButton = NSButton()
    // 截屏
    private let cursorSwitch = NSButton()
    private let shadowSwitch = NSButton()
    private let delayPopup = NSPopUpButton()
    // 输出
    private let directoryLabel = NSTextField(labelWithString: "")
    private let formatPopup = NSPopUpButton()
    private let qualitySlider = NSSlider()
    private let qualityLabel = NSTextField(labelWithString: "")
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

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.t("Marquee 设置") + AppIdentity().developmentTitleSuffix
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        buildShell()
        recorder.onRecord = { [weak self] combo in self?.apply(combo) }
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

    private func buildShell() {
        guard let window else { return }

        segmented.segmentCount = SettingsPage.allCases.count
        for (index, page) in SettingsPage.allCases.enumerated() {
            segmented.setLabel(page.title, forSegment: index)
        }
        segmented.segmentStyle = .rounded
        segmented.trackingMode = .selectOne
        segmented.target = self
        segmented.action = #selector(pageChanged)
        segmented.selectedSegment = 0
        segmented.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(segmented)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            segmented.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 16),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content

        pages = [
            .general: makeGeneralPage(),
            .capture: makeCapturePage(),
            .output: makeOutputPage(),
            .shortcuts: makeShortcutsPage(),
        ]
        select(.general)
    }

    private func select(_ page: SettingsPage) {
        currentPage = page
        segmented.selectedSegment = SettingsPage.allCases.firstIndex(of: page) ?? 0
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let view = pages[page] else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
    }

    @objc private func pageChanged() {
        let index = segmented.selectedSegment
        guard SettingsPage.allCases.indices.contains(index) else { return }
        select(SettingsPage.allCases[index])
    }

    // MARK: - 四页

    private func makeGeneralPage() -> NSView {
        configure(soundSwitch, action: #selector(generalChanged))
        configure(launchSwitch, action: #selector(launchChanged))
        launchNote.font = .systemFont(ofSize: 11)
        launchNote.textColor = .secondaryLabelColor
        launchNote.maximumNumberOfLines = 2
        launchNote.lineBreakMode = .byWordWrapping
        launchNote.preferredMaxLayoutWidth = 420

        return page([
            row(title: L10n.t("截图后播放提示音"),
                subtitle: L10n.t("连着截很多张时想安静一点可以关掉"),
                control: soundSwitch),
            row(title: L10n.t("开机时自动启动"),
                subtitle: L10n.t("Marquee 常驻菜单栏，开机自启后随时按快捷键就能截"),
                control: launchSwitch),
            launchNote,
            separator(),
            makeProStatusRow(),
        ])
    }

    /// 通用页底部的 Pro 状态区（ticket 31）。
    ///
    /// **刻意不新增第 5 页** —— PRD 3.1 定了"首选项 ≤ 4 页"，多一页的收益远小于
    /// 破坏一条已写进产品文档的约束（`SettingsPage` 那个枚举与守着它的测试都在拦着，
    /// 那份摩擦是刻意的）。状态区接在通用页最底下，信息密度也刚好。
    private func makeProStatusRow() -> NSView {
        proStatusLabel.font = .systemFont(ofSize: 12)
        proStatusLabel.textColor = .secondaryLabelColor
        proStatusLabel.lineBreakMode = .byTruncatingTail

        proActionButton.bezelStyle = .rounded
        proActionButton.target = self
        proActionButton.action = #selector(proActionTapped)

        proRestoreButton.bezelStyle = .rounded
        proRestoreButton.title = L10n.t("恢复购买")
        proRestoreButton.target = self
        proRestoreButton.action = #selector(proRestoreTapped)

        let buttons = NSStackView(views: [proRestoreButton, proActionButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [proStatusLabel, NSView(), buttons])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return stack
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return box
    }

    // MARK: - Pro 状态区（ticket 31）

    /// 把一份判定贴到界面上。
    ///
    /// **全部从 `snapshot` 推**，界面不许自己拼判据 —— 否则"状态说已购买、
    /// 按钮却写着升级"这类自相矛盾迟早出现（卡片那边也是同一条规矩）。
    private func applyProSnapshot(_ snapshot: EntitlementSnapshot) {
        proStatusLabel.stringValue = Self.proStatusText(snapshot)

        switch snapshot.entitlement {
        case .pro:
            proActionButton.title = L10n.t("已购买")
            proActionButton.isEnabled = false
        case .trial, .unknown, .free, .revoked:
            proActionButton.title = L10n.t("升级到 Pro")
            proActionButton.isEnabled = true
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

    @objc private func proActionTapped() {
        // 不等结果：买成之后判定会变，状态区靠 `observe` 那条路自己更新。
        Task { _ = await ProEntitlement.shared.purchasePro() }
    }

    @objc private func proRestoreTapped() {
        Task { [weak self] in
            let outcome = await ProEntitlement.shared.restorePurchases()
            self?.showRestoreOutcome(outcome)
        }
    }

    /// 恢复购买**必须如实回报** —— 这是用户主动点的动作，
    /// 悄悄失败等于骗他"恢复过了，确实没有记录"。
    ///
    /// 这里只是临时把它写进标签；下一次判定变化会覆盖回真实状态。
    private func showRestoreOutcome(_ outcome: EntitlementCoordinator.RestoreOutcome) {
        proStatusLabel.stringValue = switch outcome {
        case .restored: L10n.t("已恢复购买")
        case .nothingToRestore: L10n.t("这个账号下没有可恢复的购买")
        case .failed: L10n.t("恢复失败，请检查网络后重试")
        }
    }

    private func makeCapturePage() -> NSView {
        configure(cursorSwitch, action: #selector(captureChanged))
        configure(shadowSwitch, action: #selector(captureChanged))

        delayPopup.target = self
        delayPopup.action = #selector(captureChanged)
        delayPopup.addItems(withTitles: CapturePreferences.delayOptions.map {
            $0 == 0 ? L10n.t("不延时") : L10n.t("\($0) 秒")
        })
        delayPopup.controlSize = .small

        return page([
            row(title: L10n.t("截图里包含鼠标指针"),
                subtitle: L10n.t("默认不带 —— 指针会挡在内容上"),
                control: cursorSwitch),
            row(title: L10n.t("窗口截图带阴影"),
                subtitle: L10n.t("在覆盖层里按 ⌥ 可以临时反过来"),
                control: shadowSwitch),
            row(title: L10n.t("延时截图"),
                subtitle: L10n.t("按下快捷键后等几秒再出现选择框，方便先把画面摆好"),
                control: delayPopup),
        ])
    }

    private func makeOutputPage() -> NSView {
        directoryLabel.font = .systemFont(ofSize: 12)
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.textColor = .secondaryLabelColor

        let chooseButton = NSButton(title: L10n.t("选择…"), target: self, action: #selector(chooseDirectory))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small

        let directoryRow = NSStackView(views: [directoryLabel, chooseButton])
        directoryRow.orientation = .horizontal
        directoryRow.spacing = 8

        formatPopup.target = self
        formatPopup.action = #selector(outputChanged)
        formatPopup.addItems(withTitles: [L10n.t("PNG（无损）"), "JPEG", "HEIC"])
        formatPopup.controlSize = .small

        qualitySlider.target = self
        qualitySlider.action = #selector(outputChanged)
        qualitySlider.minValue = 0.5
        qualitySlider.maxValue = 1
        qualitySlider.isContinuous = true
        qualitySlider.controlSize = .small
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let qualityRow = NSStackView(views: [qualitySlider, qualityLabel])
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 8

        templateField.target = self
        templateField.action = #selector(outputChanged)
        templateField.placeholderString = FileNameTemplate.defaultTemplate
        templateField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let hint = NSTextField(labelWithString: L10n.t("可用变量：{date} {time} {n} {app} {title}"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        return page([
            row(title: L10n.t("保存位置"), subtitle: L10n.t("只有按 ⌘S 或点「保存」时才写盘"), control: directoryRow),
            row(title: L10n.t("图片格式"), subtitle: L10n.t("JPEG / HEIC 有损，可调质量"), control: formatPopup),
            row(title: L10n.t("质量"), subtitle: L10n.t("只在有损格式下有效"), control: qualityRow),
            row(title: L10n.t("文件名模板"), subtitle: nil, control: templateField),
            hint,
        ])
    }

    private func makeShortcutsPage() -> NSView {
        shortcutStatus.font = .systemFont(ofSize: 11)
        shortcutStatus.textColor = .secondaryLabelColor
        shortcutStatus.maximumNumberOfLines = 2
        shortcutStatus.lineBreakMode = .byWordWrapping
        shortcutStatus.preferredMaxLayoutWidth = 420

        let reset = NSButton(title: L10n.t("恢复默认（⌃Q）"), target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .rounded
        reset.controlSize = .small

        let hint = NSTextField(labelWithString: L10n.t("点上面的方框后按下新的组合；Esc 取消。与系统或其他应用冲突时会明确告诉你。"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 420

        return page([
            row(title: L10n.t("全屏截图"), subtitle: L10n.t("全局生效，应用不在前台也能触发"), control: nil),
            recorder,
            shortcutStatus,
            reset,
            hint,
        ])
    }

    // MARK: - 控件工厂

    private func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    private func row(title: String, subtitle: String?, control: NSView?) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let texts = NSStackView(views: [titleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if let subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.maximumNumberOfLines = 2
            sub.lineBreakMode = .byWordWrapping
            sub.preferredMaxLayoutWidth = 320
            texts.addArrangedSubview(sub)
        }

        let stack = NSStackView(views: [texts])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        if let control {
            stack.addArrangedSubview(NSView())
            stack.addArrangedSubview(control)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return stack
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.setButtonType(.switch)
        button.title = ""
        button.target = self
        button.action = action
    }

    // MARK: - 读写

    private func loadAll() {
        let general = preferences.general()
        soundSwitch.state = general.playSound ? .on : .off
        launchSwitch.state = general.launchAtLogin ? .on : .off

        let capture = preferences.capture()
        cursorSwitch.state = capture.includeCursor ? .on : .off
        shadowSwitch.state = capture.includeShadow ? .on : .off
        delayPopup.selectItem(at: CapturePreferences.delayOptions.firstIndex(of: capture.delaySeconds) ?? 0)

        let settings = output.settings()
        directoryLabel.stringValue = settings.directory.path
        formatPopup.selectItem(at: ImageFileFormat.allCases.firstIndex(of: settings.format) ?? 0)
        qualitySlider.doubleValue = settings.quality
        updateQualityLabel(settings.quality)
        templateField.stringValue = settings.nameTemplate
        recorder.update(combo: shortcut.current)
        shortcutStatus.stringValue = L10n.t("当前：\(shortcut.current.displayString)")
        shortcutStatus.textColor = .secondaryLabelColor
    }

    @objc private func generalChanged() {
        preferences.save(GeneralPreferences(playSound: soundSwitch.state == .on,
                                           launchAtLogin: preferences.general().launchAtLogin))
        onPreferencesChanged?()
    }

    @objc private func launchChanged() {
        let wants = launchSwitch.state == .on
        // 交给宿主去真正注册（它才知道 `SMAppService` 的结果）。
        // 失败时**必须把开关拨回去**，否则界面上显示"已开启"而系统里没有 ——
        // 那种不一致用户只能靠重启去发现。
        preferences.save(GeneralPreferences(playSound: preferences.general().playSound,
                                           launchAtLogin: wants))
        onPreferencesChanged?()
    }

    /// 宿主在登录项注册失败后回调，把开关与提示拨回去。
    func reportLaunchAtLogin(failure message: String?) {
        if let message {
            launchSwitch.state = .off
            launchNote.stringValue = message
            launchNote.textColor = .systemRed
            preferences.save(GeneralPreferences(playSound: preferences.general().playSound,
                                                launchAtLogin: false))
        } else {
            launchNote.stringValue = launchSwitch.state == .on
                ? L10n.t("已加入系统登录项。可在「系统设置 → 通用 → 登录项」里查看")
                : ""
            launchNote.textColor = .secondaryLabelColor
        }
    }

    @objc private func captureChanged() {
        let index = delayPopup.indexOfSelectedItem
        let delay = CapturePreferences.delayOptions.indices.contains(index)
            ? CapturePreferences.delayOptions[index]
            : 0
        preferences.save(CapturePreferences(includeCursor: cursorSwitch.state == .on,
                                           includeShadow: shadowSwitch.state == .on,
                                           delaySeconds: delay))
        onPreferencesChanged?()
    }

    @objc private func outputChanged() {
        let formatIndex = formatPopup.indexOfSelectedItem
        let format = ImageFileFormat.allCases.indices.contains(formatIndex)
            ? ImageFileFormat.allCases[formatIndex]
            : .png
        let template = templateField.stringValue.isEmpty
            ? FileNameTemplate.defaultTemplate
            : templateField.stringValue
        updateQualityLabel(qualitySlider.doubleValue)
        output.save(OutputSettings(directory: output.settings().directory,
                                   format: format,
                                   quality: qualitySlider.doubleValue,
                                   nameTemplate: template))
        // 质量与模板只对"下一次截图"生效，不必重启 —— 采集流程每次都现读设置
    }

    private func updateQualityLabel(_ value: Double) {
        qualityLabel.stringValue = "\(Int((value * 100).rounded()))%"
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

    // MARK: - 快捷键

    private func apply(_ combo: KeyCombo) {
        let result = shortcut.change(to: combo)
        if let message = result.failureMessage {
            shortcutStatus.stringValue = message
            shortcutStatus.textColor = .systemRed
            // 改键失败时显示的是回滚后的当前组合，并让用户能立刻再试
            recorder.update(combo: shortcut.current)
            window?.makeFirstResponder(recorder)
        } else {
            shortcutStatus.stringValue = L10n.t("已生效：\(combo.displayString)")
            shortcutStatus.textColor = .secondaryLabelColor
            onShortcutChanged?(combo)
        }
    }

    @objc private func resetShortcut() {
        recorder.update(combo: ShortcutService.defaultCombo)
        apply(ShortcutService.defaultCombo)
    }
}

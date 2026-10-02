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
/// 引导就补这一句话：它是什么、怎么触发、键在哪改、还差什么权限。
///
/// ## 三步，每一步都能跳过
///
/// 强制的引导是最招人烦的一类欢迎页。这里只要求"看到"：右下角从「继续」走到
/// 「开始使用」，中途直接关窗口也算跳过（状态照样记下，不会下次再弹）。
@MainActor
final class OnboardingWindowController: NSWindowController {

    /// 引导结束（走完或跳过）。宿主据此落状态。
    var onFinish: (() -> Void)?

    // MARK: - 步骤

    private enum Step: Int, CaseIterable {
        case features
        case shortcut
        case permission

        var title: String {
            switch self {
            case .features: L10n.t("Marquee 就在菜单栏")
            case .shortcut: L10n.t("先挑一个顺手的键")
            case .permission: L10n.t("还差「屏幕录制」权限")
            }
        }

        var subtitle: String {
            switch self {
            case .features: L10n.t("它不占 Dock、不弹窗口。按一下快捷键，屏幕就冻住，等你框出要截的那块。")
            case .shortcut: L10n.t("点下面的框，直接按下你想用的组合键。随时可以在菜单栏的「设置…」里改。")
            case .permission: L10n.t("macOS 不允许任何应用在没有这个权限的情况下截屏 —— 包括 Marquee。")
            }
        }
    }

    // MARK: - 依赖

    private let shortcut: ShortcutService
    private let onShortcutChanged: (KeyCombo) -> Void
    private let currentPermission: () -> ScreenRecordingPermission

    // MARK: - 控件

    private var step: Step = .features
    private let container = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let dotsLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let nextButton = NSButton()

    private let recorder: ShortcutRecorderView
    private let shortcutStatus = NSTextField(labelWithString: "")
    private let permissionStatus = NSTextField(labelWithString: "")

    init(shortcut: ShortcutService,
         currentPermission: @escaping () -> ScreenRecordingPermission,
         onShortcutChanged: @escaping (KeyCombo) -> Void) {
        self.shortcut = shortcut
        self.currentPermission = currentPermission
        self.onShortcutChanged = onShortcutChanged
        recorder = ShortcutRecorderView(combo: shortcut.current)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.t("欢迎使用 Marquee") + AppIdentity().developmentTitleSuffix
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        recorder.onRecord = { [weak self] combo in self?.apply(combo) }
        window.delegate = self

        buildShell()
        show(.features)
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

    private func buildShell() {
        guard let window else { return }

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.preferredMaxLayoutWidth = 480

        dotsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dotsLabel.textColor = .tertiaryLabelColor

        backButton.title = L10n.t("上一步")
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(goBack)

        nextButton.title = L10n.t("继续")
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(goNext)

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        let footer = NSStackView(views: [dotsLabel, NSView(), backButton, nextButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let root = NSStackView(views: [header, container, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56),
            container.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56),
            container.heightAnchor.constraint(equalToConstant: 240),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56),
        ])
        window.contentView = content
    }

    // MARK: - 切步骤

    private func show(_ next: Step) {
        step = next
        titleLabel.stringValue = next.title
        subtitleLabel.stringValue = next.subtitle
        dotsLabel.stringValue = Self.stepDots(current: next)

        container.subviews.forEach { $0.removeFromSuperview() }

        let body: NSView
        switch next {
        case .features: body = makeFeaturesStep()
        case .shortcut: body = makeShortcutStep()
        case .permission: body = makePermissionStep()
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])

        backButton.isHidden = (next == .features)
        nextButton.title = (next == .permission) ? L10n.t("开始使用") : L10n.t("继续")
    }

    /// 「● ○ ○」—— 用字符而不是自绘，省掉一套几何。
    private static func stepDots(current: Step) -> String {
        Step.allCases.map { $0 == current ? "●" : "○" }.joined(separator: " ")
    }

    @objc private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        show(previous)
    }

    @objc private func goNext() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        show(next)
    }

    private func finish() {
        // **这里不调 `onFinish`。** `close()` 会触发 `windowWillClose`，
        // 那才是唯一的收尾点 —— 两处各调一次的话状态会被写两遍，
        // 而且将来有人往其中一个里加了动作，它就会执行两次。
        close()
    }

    // MARK: - 第一步：能干什么

    private func makeFeaturesStep() -> NSView {
        let rows: [(String, String)] = [
            (L10n.t("截图"), L10n.t("拖出一块区域，或者单击一个窗口")),
            (L10n.t("就地标注"), L10n.t("矩形、箭头、画笔、马赛克、文字，画完直接进剪贴板")),
            (L10n.t("滚动截屏"), L10n.t("一屏装不下的，接着往下滚")),
            (L10n.t("识别文字"), L10n.t("把图里的字直接复制出来")),
            (L10n.t("钉图"), L10n.t("把一张图钉在屏幕上，对着改东西")),
            (L10n.t("最近截图"), L10n.t("刚截的那张永远找得回来")),
        ]
        let stack = NSStackView(views: rows.map { featureRow($0.0, $0.1) })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func featureRow(_ title: String, _ detail: String) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.alignment = .right
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let text = NSTextField(labelWithString: detail)
        text.font = .systemFont(ofSize: 13)
        text.textColor = .secondaryLabelColor

        let row = NSStackView(views: [name, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    // MARK: - 第二步：热键

    private func makeShortcutStep() -> NSView {
        shortcutStatus.font = .systemFont(ofSize: 12)
        shortcutStatus.textColor = .secondaryLabelColor
        recorder.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: L10n.t("默认是 ⌃Q。"))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [recorder, shortcutStatus, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    /// 与偏好页**同一套**改键逻辑（`PreferencesWindowController.apply`）——
    /// 两处各写一遍的话，"改键失败要回滚显示"这类细节必然只修一处。
    private func apply(_ combo: KeyCombo) {
        let result = shortcut.change(to: combo)
        if let message = result.failureMessage {
            shortcutStatus.stringValue = message
            shortcutStatus.textColor = .systemRed
            recorder.update(combo: shortcut.current)
            window?.makeFirstResponder(recorder)
        } else {
            shortcutStatus.stringValue = L10n.t("已生效：\(combo.displayString) · 以后按它就能截")
            shortcutStatus.textColor = .secondaryLabelColor
            onShortcutChanged(combo)
        }
    }

    // MARK: - 第三步：权限

    private func makePermissionStep() -> NSView {
        permissionStatus.font = .systemFont(ofSize: 13, weight: .medium)

        let open = NSButton(title: L10n.t("打开系统设置"),
                            target: self,
                            action: #selector(openSystemSettings))
        open.bezelStyle = .rounded

        let note = NSTextField(labelWithString:
            L10n.t("授权之后可能需要重启 Marquee。权限只影响截屏，不影响别的功能。"))
        note.font = .systemFont(ofSize: 12)
        note.textColor = .tertiaryLabelColor
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 440

        let buttons = NSStackView(views: [open, NSView()])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [permissionStatus, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        refreshPermissionStatus()
        return stack
    }

    /// 权限可能在**别的窗口里**被改掉（用户在系统设置里勾完再切回来），
    /// 所以每次切回本应用都重读一次状态 —— 只查一次的话，用户会看到
    /// "我明明勾了，它还说没有"。
    private func refreshPermissionStatus() {
        switch currentPermission() {
        case .granted:
            permissionStatus.stringValue = L10n.t("当前状态：已授权")
            permissionStatus.textColor = .systemGreen
        case .notDetermined, .denied:
            permissionStatus.stringValue = L10n.t("当前状态：还没授权")
            permissionStatus.textColor = .systemOrange
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

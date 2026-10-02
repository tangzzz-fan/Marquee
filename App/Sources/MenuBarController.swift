import AppKit
import MarqueeCore

/// 菜单栏入口。
///
/// 约束（PRD 3.1「功能简洁」）：下拉菜单 **≤ 6 项**，当前 **5 项**
/// （截屏 / 滚动截屏 / 最近截图 / 设置… / ─ / 退出）。
///
/// ticket 15 的两处调整：
/// - **删掉「延时截屏」这个占位项**。延时已经进了「设置 → 截屏」页 ——
///   同一个功能摆两个入口，用户会以为它们不同步。删掉它顺带给「最近截图」腾出了位置。
/// - 「快捷键…」改回「设置…」（ticket 02 时它只能改快捷键，所以叫那个名字）。
///
/// ## 回调必须由 init 注入（**不要**改回可选 `var`）
///
/// ticket 11 漏接过 `onScrollCapture`：菜单里能看到「滚动截屏」、项也是启用的，
/// 但点下去完全没反应 —— 可选闭包为 nil 时是**静默 no-op**，
/// 从"用户点了没反应"到"原来是没接线"之间没有任何线索。
/// 做成必填参数后，漏接就是编译错误。
@MainActor
final class MenuBarController {

    /// 点击「截屏」
    private let onCapture: () -> Void
    /// 点击「滚动截屏」
    private let onScrollCapture: () -> Void
    /// 点击「设置…」
    private let onShowPreferences: () -> Void
    /// 造「最近截图」面板（ticket 16）。每次需要时现造一个控制器，
    /// 内容由它自己在 `viewWillAppear` 里重新读磁盘 —— 于是"刚截的那张"一定在。
    private let makeRecentPanel: () -> NSViewController
    private var recentPopover: NSPopover?

    private let statusItem: NSStatusItem
    private let captureItem = NSMenuItem(title: L10n.t("截屏"),
                                         action: #selector(triggerCapture),
                                         keyEquivalent: "a")

    init(onCapture: @escaping () -> Void,
         onScrollCapture: @escaping () -> Void,
         onShowPreferences: @escaping () -> Void,
         makeRecentPanel: @escaping () -> NSViewController) {
        self.onCapture = onCapture
        self.onScrollCapture = onScrollCapture
        self.onShowPreferences = onShowPreferences
        self.makeRecentPanel = makeRecentPanel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Marquee")
        image?.isTemplate = true
        statusItem.button?.image = image
        // 开发版在提示里加个后缀。菜单栏是**图标**（LSUIElement，没有标题栏），
        // 悬停提示是唯一不打扰人、又能随时确认"我跑的是哪一个"的地方。
        statusItem.button?.toolTip = "Marquee" + AppIdentity().developmentTitleSuffix
        statusItem.menu = makeMenu()
        updateShortcut(KeyCombo.fullScreenCapture)
    }

    /// 快捷键变化后同步菜单上显示的组合。
    ///
    /// 菜单里的 keyEquivalent 只在应用激活时生效，**不**承担全局触发 ——
    /// 全局触发是 Carbon 的事（`CarbonGlobalHotKey`）。这里放它纯粹是"告诉用户现在是哪个键"。
    func updateShortcut(_ combo: KeyCombo) {
        captureItem.keyEquivalent = combo.keyLabel.lowercased()
        captureItem.keyEquivalentModifierMask = Self.appKitModifiers(for: combo.modifiers)
    }

    // MARK: - 私有

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        captureItem.target = self
        menu.addItem(captureItem)

        // ticket 11：长截图（手动滚动）
        let scroll = NSMenuItem(title: L10n.t("滚动截屏"),
                                action: #selector(triggerScrollCapture),
                                keyEquivalent: "")
        scroll.target = self
        menu.addItem(scroll)

        // ticket 16：最近截图。**不是子菜单**，点了弹一层面板 ——
        // 子菜单放不下缩略图，而"看不见缩略图"就等于回到"我记不清哪张是哪张"。
        let recent = NSMenuItem(title: L10n.t("最近截图"),
                                action: #selector(showRecent),
                                keyEquivalent: "")
        recent.target = self
        menu.addItem(recent)

        let settings = NSMenuItem(title: L10n.t("设置…"),
                                  action: #selector(showPreferences),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("退出 Marquee"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    /// 未实现的菜单项：显式禁用，避免出现"点了没反应"的假入口。
    private static func placeholder(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 语义修饰键 → AppKit 修饰位（只用于菜单展示）
    private static func appKitModifiers(for modifiers: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    @objc private func triggerCapture() {
        onCapture()
    }

    @objc private func triggerScrollCapture() {
        onScrollCapture()
    }

    @objc private func showPreferences() {
        onShowPreferences()
    }

    @objc private func showRecent() {
        let popover: NSPopover
        if let existing = recentPopover {
            popover = existing
        } else {
            let created = NSPopover()
            // `.transient`：点别处就收起来（它是一层面板，不是窗口）
            created.behavior = .transient
            created.contentViewController = makeRecentPanel()
            recentPopover = created
            popover = created
        }
        guard let button = statusItem.button else { return }
        // 应用是 accessory（后台）：不激活的话弹层可能开在别的应用窗口后面
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

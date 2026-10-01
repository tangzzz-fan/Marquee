import AppKit
import MarqueeCore

/// 菜单栏入口。
///
/// 约束（PRD 3.1「功能简洁」）：下拉菜单 **≤ 6 项**，当前 6 项
/// （截屏 / 滚动截屏 / 延时截屏 / 最近截图 / 快捷键… / 退出），已到上限 ——
/// 再加东西要先合并，别默默变第 7 项。
///
/// 「设置…」这一项在 ticket 02 里直接变成了**可用的「快捷键…」**：
/// 与其摆一个点不动的「设置…」占位、再另开一个只能改快捷键的窗口，
/// 不如让唯一存在的设置入口直达唯一存在的设置项。
/// ticket 15 做完整四页偏好设置时，把这一项改回「设置…」即可。
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
    /// 点击「快捷键…」
    private let onShowShortcuts: () -> Void

    private let statusItem: NSStatusItem
    private let captureItem = NSMenuItem(title: "截屏",
                                         action: #selector(triggerCapture),
                                         keyEquivalent: "a")

    init(onCapture: @escaping () -> Void,
         onScrollCapture: @escaping () -> Void,
         onShowShortcuts: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onScrollCapture = onScrollCapture
        self.onShowShortcuts = onShowShortcuts
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Marquee")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Marquee"
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
        let scroll = NSMenuItem(title: "滚动截屏",
                                action: #selector(triggerScrollCapture),
                                keyEquivalent: "")
        scroll.target = self
        menu.addItem(scroll)

        // ticket 15：延时截屏（3 / 5 / 10 秒）
        menu.addItem(Self.placeholder("延时截屏"))
        // ticket 16：最近截图面板
        menu.addItem(Self.placeholder("最近截图"))

        let shortcuts = NSMenuItem(title: "快捷键…",
                                   action: #selector(showShortcuts),
                                   keyEquivalent: "")
        shortcuts.target = self
        menu.addItem(shortcuts)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Marquee",
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

    @objc private func showShortcuts() {
        onShowShortcuts()
    }
}

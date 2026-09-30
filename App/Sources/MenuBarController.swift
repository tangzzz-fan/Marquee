import AppKit
import MarqueeCore

/// 菜单栏入口。
///
/// 约束（PRD 3.1「功能简洁」）：下拉菜单 **≤ 6 项**，当前 5 项。
///
/// 「设置…」这一项在 ticket 02 里直接变成了**可用的「快捷键…」**：
/// 与其摆一个点不动的「设置…」占位、再另开一个只能改快捷键的窗口，
/// 不如让唯一存在的设置入口直达唯一存在的设置项。
/// ticket 15 做完整四页偏好设置时，把这一项改回「设置…」即可。
@MainActor
final class MenuBarController {

    /// 点击「截屏」
    var onCapture: (() -> Void)?
    /// 点击「快捷键…」
    var onShowShortcuts: (() -> Void)?

    private let statusItem: NSStatusItem
    private let captureItem = NSMenuItem(title: "截屏",
                                         action: #selector(triggerCapture),
                                         keyEquivalent: "a")

    init() {
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
        onCapture?()
    }

    @objc private func showShortcuts() {
        onShowShortcuts?()
    }
}

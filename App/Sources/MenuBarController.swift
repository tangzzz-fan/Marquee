import AppKit

/// 菜单栏入口。
///
/// 约束（PRD 3.1「功能简洁」）：下拉菜单 **≤ 6 项**。
///
/// 尚未实现的项以 `nil` action 加入菜单 —— AppKit 会把它们呈现为禁用态。
/// 这是刻意的：宁可让用户看到一个明确的灰项，也不要放一个点了没反应的假入口。
/// 每项的归属 ticket 写在旁边，实现时删掉注释即可。
@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Marquee")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Marquee"
        statusItem.menu = Self.makeMenu()
    }

    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()

        // ticket 02：全屏截图直达剪贴板
        menu.addItem(placeholder("截屏"))
        // ticket 15：延时截屏（3 / 5 / 10 秒）
        menu.addItem(placeholder("延时截屏"))
        // ticket 16：最近截图面板
        menu.addItem(placeholder("最近截图"))
        // ticket 15：偏好设置
        menu.addItem(placeholder("设置…"))

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
}

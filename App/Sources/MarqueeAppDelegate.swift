import AppKit
import MarqueeCore

@MainActor
final class MarqueeAppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var coordinator: CaptureCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = CaptureCoordinator()
        let menuBar = MenuBarController()

        menuBar.onCapture = { [weak coordinator] in coordinator?.performCapture() }
        menuBar.onShowShortcuts = { [weak coordinator] in coordinator?.showShortcutPreferences() }
        coordinator.onShortcutChanged = { [weak menuBar] combo in menuBar?.updateShortcut(combo) }

        self.coordinator = coordinator
        self.menuBar = menuBar

        // 注册全局快捷键放在最后：这样即使注册失败（被占用），
        // 菜单栏图标与菜单已经就位，用户仍能通过菜单截图。
        // `start()` 会把实际生效的组合回推给菜单。
        coordinator.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

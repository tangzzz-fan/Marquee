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

        // 开发用冒烟入口：`Marquee -marqueeSmokeOverlay` 启动即弹出覆盖层，1.5 秒后自动退出。
        //
        // 存在的理由：覆盖层的行为依赖真实屏幕与 TCC 授权，无法在自动化测试里验证，
        // 但"创建逐屏面板 → 绘制 → 拆解"这条路一旦崩，是每次按快捷键都会立刻撞上的。
        // 这个开关让这条路径至少能被冒烟一次（自动退出 = 不留残影）。
        if ProcessInfo.processInfo.arguments.contains("-marqueeSmokeOverlay") {
            coordinator.performCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApplication.shared.terminate(nil)
            }
        }

        // 排障入口：`Marquee -marqueeDiagnostics` 打印权限与快捷键的实际状态后退出。
        //
        // 这两件事都属于"不会必然报错"的状态（权限被拒只是返回 false；
        // 非独占注册永远返回成功），而它们又都发生在用户机器上、我们看不见。
        // 让用户跑一条命令把状态贴回来，比来回猜快得多。
        if ProcessInfo.processInfo.arguments.contains("-marqueeDiagnostics") {
            print(coordinator.diagnosticsReport())
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

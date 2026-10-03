import AppKit
import CoreGraphics
import MarqueeCapture
import MarqueeCore

@MainActor
final class MarqueeAppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var coordinator: CaptureCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = CaptureCoordinator()

        // 菜单项的回调在构造时就注入（`MenuBarController` 的必填参数），
        // 漏接一个就是编译错误 —— ticket 11 曾经漏接「滚动截屏」，
        // 症状是菜单项看着正常、点下去静默无反应。
        let menuBar = MenuBarController(
            onCapture: { [weak coordinator] in coordinator?.performCapture() },
            onScrollCapture: { [weak coordinator] in coordinator?.performScrollCapture() },
            onShowPreferences: { [weak coordinator] in coordinator?.showPreferences() },
            makeRecentPanel: { [weak coordinator] in
                coordinator?.makeRecentPanelController() ?? NSViewController()
            },
            // 菜单展开时现算「滚动截屏」要不要带小锁（ticket 31）。
            // 与覆盖层里那两格走的是**同一个判据** —— `ProCard.content` 返回非 nil
            // 就是被挡，不另写一遍 `access(to:)`。
            isScrollCaptureLocked: {
                ProCard.content(for: ProEntitlement.shared.snapshot, feature: .scrollCapture) != nil
            }
        )
        coordinator.onShortcutChanged = { [weak menuBar] combo in menuBar?.updateShortcut(combo) }

        self.coordinator = coordinator
        self.menuBar = menuBar

        // 注册全局快捷键放在最后：这样即使注册失败（被占用），
        // 菜单栏图标与菜单已经就位，用户仍能通过菜单截图。
        // `start()` 会把实际生效的组合回推给菜单。
        coordinator.start()

        // Pro 权益（ticket 31）：先按缓存**立刻**出判定，再在后台向商店核实。
        // 放在这里而不是等界面创建时：`verifyWithStore` 要一个网络往返，
        // 而"用户打开购买界面的那一刻"正是最不该开一次新请求的时候。
        ProEntitlement.shared.start()

        // 首次启动的引导（ticket 34）。**放在最后** —— 走到这里菜单栏图标与
        // 全局快捷键都已经就位，所以引导还开着的时候用户就能按快捷键截一张，
        // 而不是听人讲完才知道该按什么。
        coordinator.presentOnboardingIfNeeded()

        // 权限登记入口：`Marquee -marqueeRequestPermission`
        //
        // 存在的理由：macOS 只在应用**真的发起采集**时才把它登记进「屏幕录制」列表，
        // 而我们的权限门拦在采集之前 —— 不主动跑一次这一步，用户翻遍系统设置也找不到
        // 可勾选的 Marquee。这个开关让"登记 + 请求授权"能被单独触发，不必等用户按快捷键。
        //
        // 用 `open -a Marquee.app --args -marqueeRequestPermission` 启动（而不是直接 exec 可执行文件）：
        // LaunchServices 启动才会让 Marquee 成为自己的 "responsible process"。
        // 从 shell 直接 exec 时，TCC 可能把这次访问算在父进程（终端）头上，
        // 于是登记的是终端而不是 Marquee —— 那正是"列表里找不到 Marquee"的一种成因。
        if ProcessInfo.processInfo.arguments.contains("-marqueeRequestPermission") {
            print("app 路径：\(Bundle.main.bundleURL.path)")
            print("正在请求屏幕录制权限（若弹出系统授权框，请点「打开系统设置」）…")
            NSApplication.shared.activate()
            Task {
                let granted = await SystemScreenRecordingPermission().requestPermission()
                // L10N-EXEMPT-START: `-marqueeRequestPermission` 的控制台报告，贴回来给我看
                let report = """
                Marquee 权限登记探针
                  app 路径    : \(Bundle.main.bundleURL.path)
                  请求结果    : \(granted ? "✅ 已授权（如刚授权，需退出并重新打开应用才生效）" : "❌ 仍未授权")
                  preflight   : \(CGPreflightScreenCaptureAccess() ? "true" : "false")
                  时间        : \(Date())
                """
                // L10N-EXEMPT-END
                print(report)
                Self.writeProbeReport(report)
                // 多留一会儿再退出：系统授权框可能正在等用户操作
                try? await Task.sleep(for: .seconds(15))
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // 开发用冒烟入口：`Marquee -marqueeSmokeOverlay` 启动即弹出覆盖层，1.5 秒后自动退出。
        //
        // 存在的理由：覆盖层的行为依赖真实屏幕与 TCC 授权，无法在自动化测试里验证，
        // 但"创建逐屏面板 → 绘制 → 拆解"这条路一旦崩，是每次按快捷键都会立刻撞上的。
        // 这个开关让这条路径至少能被冒烟一次（自动退出 = 不留残影）。
        if ProcessInfo.processInfo.arguments.contains("-marqueeSmokeEditor") {
            coordinator.presentEditor(image: Self.sampleEditorImage())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApplication.shared.terminate(nil)
            }
        }

        // 编辑器演示：`Marquee -marqueeDemoEditor`
        //
        // 与冒烟开关的区别：这个**不自动退出**，而且预置了每类标注各一个。
        // 存在的理由：编辑器里五种标注（矩形/椭圆/箭头/画笔/文字）的渲染没法目视验收时，
        // 用一张合成图就能把它们全摆出来看 —— **不需要屏幕录制权限**。
        if ProcessInfo.processInfo.arguments.contains("-marqueeDemoEditor") {
            coordinator.presentEditor(image: EditorDemo.makeImage(), seed: EditorDemo.annotations)
        }

        if ProcessInfo.processInfo.arguments.contains("-marqueeSmokeOverlay") {
            coordinator.performCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApplication.shared.terminate(nil)
            }
        }
        // 最近截图面板的冒烟：`Marquee -marqueeSmokeRecent`
        //
        // 存在的理由：这个面板是**约束拼出来的**（面板总高 / 列表高度 / 底部那三段的宽度），
        // 而约束冲突与模糊布局都不会崩、也不会在开发机上被一眼看到 ——
        // 表现只是"某一块位置不对"。Core 那一半已经单测钉住了数字，
        // 但"把数字摆成真的视图"这一步只能在运行期验。
        // 报告（含每个子视图的矩形与模糊布局清单）落在 `<数据根>/reports/recent-panel-smoke.txt`。
        if ProcessInfo.processInfo.arguments.contains("-marqueeSmokeRecent") {
            let report = coordinator.recentPanelSmokeReport()
            print(report)
            Self.writeProbeReport(report, name: "recent-panel-smoke.txt")
            NSApplication.shared.terminate(nil)
        }

        // 长截图覆盖层的空状态：满屏蒙层 + 光标旁的提示框。
        // 这条路径不需要权限（还没开始抓帧），但它是新写的绘制分支，
        // 崩了同样是"一进长截图就废"。
        if ProcessInfo.processInfo.arguments.contains("-marqueeSmokeScrollOverlay") {
            coordinator.performScrollCapture()
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
            let report = coordinator.diagnosticsReport()
            print(report)
            // **同时落一份文件**：沙盒构建只能经 `open` 启动（直接跑会撞嵌套沙箱），
            // 而那条路 stdout 拿不到 —— 不落文件的话，App Store 版就没有任何
            // 自证状态的手段（"沙盒下文件到底落在哪"全靠这份报告）。
            Self.writeProbeReport(report, name: "diagnostics.txt")
            NSApplication.shared.terminate(nil)
        }

        // 内购探针：`Marquee -marqueeEntitlement [purchase|trial|restore]`
        //
        // 存在的理由：**购买界面还没做，而"能在真实沙盒里买一次"是这一票的验收**。
        // 有了它，整条链路（取商品 → 购买 → 校验 → 判定 → 缓存）现在就能在
        // 任一构建上跑一遍 —— 包括正式 id 的 Release 构建（那才是能连真实沙盒的那个）。
        //
        // 建议这样用：
        //   open -a Marquee.app --args -marqueeEntitlement            # 只查看
        //   open -a Marquee.app --args -marqueeEntitlement purchase   # 真买一次
        // 报告同时落到 `<数据根>/reports/entitlement-probe.txt`
        //（用 `open` 启动时 stdout 不回终端；沙盒构建**只能**用 `open` 启动）。
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-marqueeEntitlement") {
            let next = arguments.count > index + 1 ? arguments[index + 1] : ""
            let action = next.hasPrefix("-") ? "" : next
            print("内购探针启动（动作：\(action.isEmpty ? "只查看" : action)），约 3 秒后出报告…")
            NSApplication.shared.activate()
            Task { await ProEntitlement.runProbe(action: action) }
            return
        }
    }

    /// 切回本应用时，重读引导页上的屏幕录制权限状态。
    ///
    /// 用户看到引导说"还没授权"，多半就切去系统设置勾上了；勾完切回来，
    /// 那一行**必须自己变**。只读一次的话，他会以为勾选没生效。
    ///
    /// `currentPermission()` 是纯读（`CGPreflightScreenCaptureAccess` + 进程内记忆），
    /// 不会登记 TCC、也不弹框，所以每次激活都调它是安全的。
    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator?.refreshOnboardingPermission()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// 把探针结果落到固定路径。
    ///
    /// 用 `open`（LaunchServices）启动时 stdout 不会回到调用方的终端，
    /// 所以这类一次性探针必须落文件才读得到。
    ///
    /// ⚠️ 沙盒构建**只能**走 `open` 这条路：在终端里直接跑二进制会撞上
    /// **嵌套沙箱** —— 本会话自身已在沙盒里，`libsecinit` 初始化 App Sandbox
    /// 会失败并直接 SIGTRAP，**连 `main` 都进不去**（症状是"一行输出都没有"）。
    /// 所以报告落文件不是可选的美化，是 App Store 版唯一能自证状态的手段。
    private static func writeProbeReport(_ text: String, name: String = "permission-probe.txt") {
        let directory = AppIdentity().logDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: directory.appendingPathComponent(name),
                        atomically: true,
                        encoding: .utf8)
    }

    /// 编辑器冒烟用的固定图，不依赖屏幕采集。
    private static func sampleEditorImage() -> CGImage {
        let width = 640
        let height = 400
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.12, 0.34, 0.68, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.95, 0.95, 0.95, 1])!)
        context.fill(CGRect(x: 70, y: 90, width: 220, height: 140))
        return context.makeImage()!
    }
}

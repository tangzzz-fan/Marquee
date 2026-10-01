import AppKit
import MarqueeCore

/// 延时截图的倒计时。
///
/// ## 为什么延时是"覆盖层出现**之前**"的那几秒
///
/// 用户按下快捷键要截的往往是"需要先摆出来的东西"（展开的下拉、悬停的提示、
/// 某个瞬时的状态）。覆盖层一旦出现就会吃掉所有鼠标事件 —— 那时候再等几秒，
/// 用户反而什么都摆不了。
///
/// ## 为什么不做成"能中止"
///
/// 一个不能成为 key window 的窗口收不到键盘，要支持 `Esc` 就得再挂一层全局监听。
/// 而这段等待最长 10 秒，收益远小于代价。**能点穿**更有用：等的时候还能操作下面。
@MainActor
public final class CountdownHUD {

    private var panel: NSPanel?
    private var label: NSTextField?
    private var task: Task<Void, Never>?

    public init() {}

    /// 倒数 `seconds` 秒，然后调 `completion`（主线程）。
    ///
    /// `seconds <= 0` 时**直接**调 `completion` —— 不显示任何东西、也不空转一个循环，
    /// 那样"延时 0"与"不延时"在行为上完全等价。
    public func run(seconds: Int, completion: @escaping @MainActor () -> Void) {
        cancel()
        guard seconds > 0 else {
            completion()
            return
        }

        let panel = makePanel()
        self.panel = panel
        panel.orderFrontRegardless()

        task = Task { [weak self] in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self?.label?.stringValue = "\(remaining)"
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.teardown()
            completion()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        teardown()
    }

    // MARK: - 窗口

    private func makePanel() -> NSPanel {
        let side: CGFloat = 132
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: visible.midX - side / 2,
                           y: visible.midY - side / 2,
                           width: side,
                           height: side)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        // 点穿：等待期间用户还能操作下面（这也是"不能中止"的补偿）
        panel.ignoresMouseEvents = true

        // 深色底不自己画（ticket 17）：交给统一的材质层（26+ 玻璃 / 15 的 HUD 材质）。
        // 直接自绘 `black 0.72` 的话，26 上会是一块扁平的黑方块 —— 与系统风格不搭。
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let background = ChromeBackground.makeBackgroundView(cornerRadius: Self.cornerRadius)
        background.frame = container.bounds
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)

        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 64, weight: .semibold)
        field.textColor = .white
        field.alignment = .center
        field.frame = CGRect(x: 0, y: frame.height / 2 - 40, width: frame.width, height: 80)
        // 数字加在材质**之后** —— 顺序反了会被材质盖住。
        container.addSubview(field)

        panel.contentView = container
        label = field
        return panel
    }

    /// HUD 的圆角。材质层与任何自绘都要用它，避免两边各写一个数字。
    static let cornerRadius: CGFloat = 18

    private func teardown() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        label = nil
    }
}

/// 提示音。
///
/// 单独包一层是为了把"用哪个系统音"这个决定收在一处 —— 散在各调用点的话，
/// 改一次音效要满仓库找。
@MainActor
public enum CaptureFeedback {
    /// 截图成功。
    public static func playSuccess() {
        // `Grab` 是 macOS 自带里最"截图"的那个（系统截图也用它）。
        // 取不到就**什么都不播** —— 不能因为一个音效让整次截图出问题。
        NSSound(named: "Grab")?.play()
    }
}

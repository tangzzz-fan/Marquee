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
                self?.show(remaining)
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
        // ⚠️ **窗口不要自己的阴影**：内容只有几个数字，窗口阴影会沿着字的外轮廓
        // 糊出一圈灰晕，和字自己的投影叠成两层。阴影由字承担（见 `digitShadow`）。
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        // 点穿：等待期间用户还能操作下面（这也是"不能中止"的补偿）
        panel.ignoresMouseEvents = true

        // ⚠️ **倒计时没有材质**（稿子 ⑩ §07 把它写进了「永远不玻璃」名单）。
        //
        // 这里原先是 `ChromeBackground.makeBackgroundView(...)` 铺的一块材质板，
        // 理由写的是"直接自绘黑 72% 的话，26 上会是一块扁平的黑方块，与系统风格不搭"。
        // 稿子 ⑨ 的 G 那一格其实从来就没有板：它就是**屏幕正中一个大数字**
        //（`text-shadow` 兜住可读性），旁边的注脚写着「数字就是全部」。
        //
        // ⇒ 那块板是实装自己加的，不是设计要的。去掉之后：
        //   · 等待期间底下的东西**一点不被挡**（这块 HUD 的全部意义就是"在旁边等"，不是"盖住"）；
        //   · 而它也就此离开了玻璃族 —— 玻璃是给"浮件"的，一个纯数字不是件。
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))

        let field = NSTextField(labelWithString: "")
        field.alignment = .center
        field.frame = CGRect(x: 0, y: frame.height / 2 - 40, width: frame.width, height: 80)
        field.attributedStringValue = Self.digit("")
        container.addSubview(field)

        panel.contentView = container
        label = field
        return panel
    }

    /// 换数字。**字号 / 颜色 / 投影每次都一起给。**
    ///
    /// ⚠️ 不能用 `label.stringValue = "\(n)"`：那个 setter 会把整串属性
    /// **换成默认的**（系统字体、黑色、无投影），而第一帧恰好是空串 ——
    /// 于是"设过一次格式"看起来成立，实际上从第二个数字起就全丢了。
    /// 这类错不崩不报错，只是"倒计时看着不对"。
    private func show(_ remaining: Int) {
        label?.attributedStringValue = Self.digit("\(remaining)")
    }

    private static func digit(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.white,
            .shadow: digitShadow,
        ])
    }

    /// 数字上的投影。**它现在就是这块 HUD 唯一的"底"。**
    ///
    /// 值取稿子 ⑨ 的 `text-shadow: 0 0 1px rgba(0,0,0,.9), 0 1px 3px rgba(0,0,0,.5)`。
    /// AppKit 一枚 `NSShadow` 只能给一层，所以取两条的并集：模糊 3、下移 1、
    /// 不透明度取中间偏保守的 72%。**浅色内容上的白数字**靠它才立得住 ——
    /// 而"底下可能是任何东西"正是这个 app 的常态。
    private static let digitShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()

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

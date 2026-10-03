import AppKit
import MarqueeCore

/// 快捷键录制控件：点一下进入录制，按下的组合直接被读走。
///
/// 为什么自己画而不是用 `NSTextField` 收键：文本框会吃掉 ⌘A / ⌘C 这类组合，
/// 而我们要录的恰恰是它们。必须拿到**原始的 keyDown**，所以只能是一个
/// `acceptsFirstResponder == true` 的自定义视图。
@MainActor
final class ShortcutRecorderView: NSView {

    /// 录到合法组合时回调（此时录制已结束）
    var onRecord: ((KeyCombo) -> Void)?

    /// 录制开始 / 结束的回调。
    ///
    /// 存在的唯一理由：**录制期间必须把全局快捷键挂起**（`ShortcutService.suspendForRecording`）。
    /// Carbon 的全局注册是系统级的，它会在按键到达响应链之前吃掉它 —— 不挂起的话，
    /// 用户按下**自己正在用的那颗键**时，录制器什么也收不到，反而真的触发一次截屏。
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var combo: KeyCombo
    private(set) var isRecording = false
    private let titleField = NSTextField(labelWithString: "")

    init(combo: KeyCombo) {
        self.combo = combo
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 34))

        titleField.alignment = .center
        titleField.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutRecorderView 只支持代码创建")
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 34) }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // 0x35 = kVK_Escape：取消录制，不改动原组合
        if event.keyCode == 0x35 {
            endRecording()
            return
        }

        // 只按修饰键时 `from` 返回 nil —— 继续等主键，只是给一个听觉反馈
        guard let recorded = KeyCombo.from(keyCode: UInt32(event.keyCode),
                                           deviceIndependentFlags: event.modifierFlags.rawValue) else {
            NSSound.beep()
            return
        }

        combo = recorded
        isRecording = false
        refresh()
        // **先**应用组合、**再**报告录制结束：`change(to:)` 内部会真正注册新键
        //（并清掉挂起标志），随后那次"结束"就成空操作。反过来则会把同一个组合
        // 注册两遍，Carbon 会把它判成冲突。
        onRecord?(recorded)
        onRecordingChanged?(false)
    }

    // MARK: - 录制状态

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        refresh()
        onRecordingChanged?(true)
    }

    /// 收尾只有这一处 —— 四条出口（录到键 / `Esc` / 失去焦点 / 外部 `update`）都走它。
    /// 分散成四份的话，"恢复全局注册"这类动作必然只修一处。
    ///
    /// ⚠️ **不能只在 `resignFirstResponder` 里收尾。** 点窗口红叉关掉设置窗时
    /// 第一响应者不一定会变（按钮不抢焦点），录制就会一直"挂着" ——
    /// 那意味着全局快捷键从此**彻底失灵且毫无提示**，比原本这个 bug 更糟。
    /// 所以另有一道兜底：窗口失焦 / 关窗（见 `viewDidMoveToWindow`）。
    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        refresh()
        onRecordingChanged?(false)
    }

    // MARK: - 兜底：宿主窗口不再可用时收尾

    /// 换宿主窗口时重新挂钩子。
    ///
    /// 判据只认"这个窗口还能不能收键盘"，不认"用户点在了哪里" ——
    /// 后者在 `resignFirstResponder` 里已经管了。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)

        guard let window else {
            // 被摘出窗口树（视图拆掉）—— 收尾，否则挂起状态留在服务里
            endRecording()
            return
        }
        center.addObserver(self,
                           selector: #selector(hostWindowWentAway),
                           name: NSWindow.didResignKeyNotification,
                           object: window)
        center.addObserver(self,
                           selector: #selector(hostWindowWentAway),
                           name: NSWindow.willCloseNotification,
                           object: window)
    }

    /// 通知都发在主线程（AppKit 的窗口通知），所以这里直接收尾是安全的。
    @objc private func hostWindowWentAway() {
        endRecording()
    }

    // 刻意不写 `deinit` 摘观察者：自 macOS 10.11 起，**基于 selector 的**观察者
    // 会在观察对象释放时被 `NotificationCenter` 自动摘掉（文档保证）。
    // 而视图的生命周期与本窗口一致 —— 上一个窗口的钩子也已经在
    // `viewDidMoveToWindow` 开头按 `object: nil` 清干净了。

    // MARK: - 外部更新

    func update(combo: KeyCombo) {
        self.combo = combo
        // 正在录制时被外部改掉（例如「恢复默认」）→ 先按正常出口收尾，
        // 否则挂起状态会留在那儿，全局快捷键再也回不来。
        endRecording()
        refresh()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
        path.lineWidth = isRecording ? 2 : 1
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    private func refresh() {
        titleField.stringValue = isRecording ? L10n.t("按下新的组合…") : combo.displayString
        titleField.textColor = isRecording ? .secondaryLabelColor : .labelColor
        needsDisplay = true
    }
}

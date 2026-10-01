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
        isRecording = true
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            refresh()
        }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // 0x35 = kVK_Escape：取消录制，不改动原组合
        if event.keyCode == 0x35 {
            isRecording = false
            refresh()
            return
        }

        // 只按修饰键时 `from` 返回 nil —— 继续等主键，只是给一个听觉反馈
        guard let recorded = KeyCombo.from(keyCode: UInt32(event.keyCode),
                                           deviceIndependentFlags: event.modifierFlags.rawValue) else {
            NSSound.beep()
            return
        }

        isRecording = false
        combo = recorded
        refresh()
        onRecord?(recorded)
    }

    // MARK: - 外部更新

    func update(combo: KeyCombo) {
        self.combo = combo
        isRecording = false
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

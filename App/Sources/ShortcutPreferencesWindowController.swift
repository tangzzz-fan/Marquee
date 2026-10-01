import AppKit
import MarqueeCore

/// 「快捷键」偏好面板。
///
/// 范围说明（ticket 02 追加需求）：**只有快捷键这一项**。
/// ticket 15 会把它并进完整的四页偏好设置（通用 / 快捷键 / 输出 / 高级），
/// 届时这个窗口要么作为其中一页、要么被替换掉。
/// 现在刻意不做多页外壳 —— 一个只有一个开关的"设置窗口"比一个直达的快捷键面板更难用。
@MainActor
final class ShortcutPreferencesWindowController: NSWindowController {

    /// 快捷键变更且已生效
    var onShortcutChanged: ((KeyCombo) -> Void)?

    private let service: ShortcutService
    private let recorder: ShortcutRecorderView
    private let statusLabel = NSTextField(labelWithString: "")

    init(service: ShortcutService) {
        self.service = service
        self.recorder = ShortcutRecorderView(combo: service.current)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "快捷键"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        buildContent()
        recorder.onRecord = { [weak self] combo in
            self?.apply(combo)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutPreferencesWindowController 只支持代码创建")
    }

    // MARK: - 展示

    func present() {
        recorder.update(combo: service.current)
        setStatus("点击方框后按下新的按键组合（Esc 取消）", isError: false)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 与编辑器窗口同一个坑：Marquee 是 `.accessory` 应用，
        // `makeKeyAndOrderFront` 依赖应用已激活 —— 少了这一行，
        // 刚从前台退下来的应用开这个窗口可能开在别的窗口后面（见 PITFALLS 54）。
        window?.orderFrontRegardless()
        window?.makeFirstResponder(recorder)
    }

    // MARK: - 私有

    private func buildContent() {
        guard let window else { return }

        let caption = NSTextField(labelWithString: "全屏截图")
        caption.font = .systemFont(ofSize: 13, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 260

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetToDefault))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small

        let doneButton = NSButton(title: "完成", target: self, action: #selector(closePanel))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.keyEquivalent = "\r"

        let row = NSStackView(views: [resetButton, NSView(), doneButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill

        let stack = NSStackView(views: [caption, recorder, statusLabel, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultHigh, for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
        ])
        window.contentView = content

        // 让 recorder 与底部的行撑满可用宽度
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func apply(_ combo: KeyCombo) {
        let result = service.change(to: combo)

        if let message = result.failureMessage {
            setStatus(message, isError: true)
            // 改键失败时显示的是回滚后的当前组合，并让用户能立刻再试一次
            recorder.update(combo: service.current)
            window?.makeFirstResponder(recorder)
        } else {
            setStatus("已生效：\(combo.displayString)", isError: false)
            onShortcutChanged?(combo)
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc private func resetToDefault() {
        recorder.update(combo: ShortcutService.defaultCombo)
        apply(ShortcutService.defaultCombo)
    }

    @objc private func closePanel() {
        window?.close()
    }
}

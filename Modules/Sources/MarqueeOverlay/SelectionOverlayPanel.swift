import AppKit

/// 覆盖层面板。
///
/// 关键点：
/// - `.nonactivatingPanel`：面板能成为 key 收键盘事件，但**不激活本应用** ——
///   激活会把用户从当前应用拽走（PRD 5.5 要求在当前 Space 出现且不打扰）
/// - `hidesOnDeactivate = false`：`NSPanel` 默认会在应用失活时隐藏自己，
///   而我们的应用本来就是 accessory（后台），不关掉这个开关蒙层会一闪就没
/// - `canBecomeKey = true`：`Esc` / 方向键 / `⏎` 必须收得到
/// - `becomesKeyOnlyIfNeeded = false`：`NSPanel` 默认只有点到文本框才变 key，
///   不关掉的话 `Esc` 到不了覆盖层
final class SelectionOverlayPanel: NSPanel {

    /// 一次 `Esc` 要关掉**所有屏**的蒙层。面板自己的 `cancel:` 只会收掉当前这一块。
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 盖住菜单栏与 Dock（PRD 5.5 第 1 条）
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 0x35 {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

import AppKit

/// 覆盖层面板。
///
/// 关键点：
/// - `.nonactivatingPanel`：面板能成为 key 收键盘事件，但**不激活本应用** ——
///   激活会把用户从当前应用拽走（PRD 5.5 要求在当前 Space 出现且不打扰）
/// - `hidesOnDeactivate = false`：`NSPanel` 默认会在应用失活时隐藏自己，
///   而我们的应用本来就是 accessory（后台），不关掉这个开关蒙层会一闪就没
/// - `canBecomeKey = true`：`Esc` / 方向键 / `⏎` 必须收得到
final class SelectionOverlayPanel: NSPanel {

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
    }
}

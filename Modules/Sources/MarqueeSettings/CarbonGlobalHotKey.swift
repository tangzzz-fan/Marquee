import Carbon.HIToolbox
import Foundation
import MarqueeCore

/// Carbon `RegisterEventHotKey` 版全局快捷键注册器。
///
/// 选它而不是 `NSEvent.addGlobalMonitorForEvents`：后者返回非 nil 也不代表能收到事件，
/// 强依赖「输入监控」授权；而 Carbon 这条路**不需要任何辅助功能/输入监控权限**
/// （`docs/SPIKE-PLAN.md` G1 实测 OSStatus = 0）。冲突检测见 G2。
///
/// 线程约束：Carbon 事件回调走主运行循环，`InstallEventHandler` 与
/// `RegisterEventHotKey` 官方标注 "Not thread safe"，所以整个类钉在 `@MainActor`。
@MainActor
public final class CarbonGlobalHotKey: HotKeyRegistering {

    /// 本应用的热键签名（'MRQK'）。Carbon 用它区分不同来源的热键。
    private static let signature: OSType = 0x4D_52_51_4B
    /// 真正生效的热键 id
    private static let liveHotKeyID: UInt32 = 1
    /// 可用性探测用的热键 id（与生效的那个分开，免得探测把自己顶掉）
    private static let probeHotKeyID: UInt32 = 2

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?

    public init() {}

    @discardableResult
    public func register(_ combo: KeyCombo,
                         handler: @escaping @MainActor () -> Void) -> HotKeyRegistrationOutcome {
        self.handler = handler
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.liveHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode,
                                        Self.carbonModifiers(for: combo.modifiers),
                                        hotKeyID,
                                        GetEventDispatcherTarget(),
                                        0, // 非独占：与系统截图那类组合共存时不至于把别人的热键废掉
                                        &ref)
        hotKeyRef = ref
        return HotKeyRegistrationOutcome.from(status: Int32(status))
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    public func probeAvailability(of combo: KeyCombo) -> HotKeyRegistrationOutcome {
        // 探测用独立的热键 id，避免与真正生效的那个混淆
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.probeHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode,
                                        Self.carbonModifiers(for: combo.modifiers),
                                        hotKeyID,
                                        GetEventDispatcherTarget(),
                                        OptionBits(kEventHotKeyExclusive),
                                        &ref)
        // 探测必须是"即注册即注销"：短暂占用一下只为拿返回值，不能真的把键拿走
        if let ref {
            UnregisterEventHotKey(ref)
        }
        return HotKeyRegistrationOutcome.from(status: Int32(status))
    }

    // 刻意不写 `deinit` 做清理：Swift 6 的 nonisolated deinit 不允许触碰
    // `EventHotKeyRef` / `EventHandlerRef` 这类非 Sendable 的存储属性（编不过，已实测）。
    // 这不构成泄漏 —— 进程退出时系统会回收该进程注册的热键与事件处理器，
    // 而运行期换键的注销由 `ShortcutService.apply` 保证（它每次都会先 unregister）。

    // MARK: - 私有

    /// 事件处理器只需装一次；重复安装会产生多份回调。
    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(),
                            marqueeHotKeyEventHandler,
                            1,
                            &eventType,
                            userData,
                            &eventHandlerRef)
    }

    fileprivate func handleHotKeyPress() {
        handler?()
    }

    /// 语义修饰键 → Carbon 修饰位。
    private static func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}

/// Carbon 的 C 回调。只做两件事：取出被按下的热键 ID，然后跳回主线程执行。
///
/// `DispatchQueue.main.async` + `assumeIsolated` 而不是直接调用：
/// 回调虽然实际发生在主运行循环上，但类型上它是 nonisolated 的，
/// 直接碰 `@MainActor` 状态在 Swift 6 下编不过；显式跳一次线程既合法也把假设写清楚了。
private func marqueeHotKeyEventHandler(_ callRef: EventHandlerCallRef?,
                                       _ event: EventRef?,
                                       _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return status }

    let instance = Unmanaged<CarbonGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            instance.handleHotKeyPress()
        }
    }
    return noErr
}

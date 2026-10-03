import Foundation

// MARK: - 接缝

/// 快捷键偏好的持久化。
public protocol ShortcutStoring: Sendable {
    /// 读取已保存的快捷键；`nil` = 从未保存过（调用方用默认值）
    func load() -> KeyCombo?
    func save(_ combo: KeyCombo)
    /// 恢复默认（删掉存的那条，而不是写回默认值 —— 否则将来改默认值老用户吃不到）
    func clear()
}

/// 全局快捷键注册器。
///
/// 真实现是 Carbon（`MarqueeSettings.CarbonGlobalHotKey`）。抽成协议是为了让
/// "改键 → 先注销旧的 → 探测是否被占 → 注册新的 → 冲突则回滚" 这段编排能脱离真实 Carbon 单测。
@MainActor
public protocol HotKeyRegistering: AnyObject {
    @discardableResult
    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> HotKeyRegistrationOutcome
    func unregister()

    /// 独占试注册一次再立刻注销，用来问「这个组合是不是已经被别的应用占了」。
    ///
    /// 存在的唯一理由：**非独占注册永远返回成功**（本机实测），
    /// 所以光看 `register` 的结果永远发现不了冲突 —— 这也正是
    /// "微信也在用同一个键，两个 app 一起响应"这类问题根本收不到提示的原因。
    /// 只有独占注册会在被占用时返回 `eventHotKeyExistsErr`。
    ///
    /// ⚠️ 调用前必须先 `unregister()`：**带着自己已有的非独占注册去独占探测同样会返回 -9878**（实测），
    /// 不先注销就会把自己的注册误报成"被别的应用占用"。
    func probeAvailability(of combo: KeyCombo) -> HotKeyRegistrationOutcome
}

// MARK: - 结果

/// 一次改键尝试的结果。
public enum ShortcutChangeResult: Equatable, Sendable {
    /// 已生效（并已落盘，如果是用户改的话）
    case applied(KeyCombo)
    /// 组合本身不合法，被本地校验拦下（未触碰系统）
    case rejected(ShortcutValidationError)
    /// 组合合法，但系统里已被别的应用占用
    case occupied(KeyCombo)
    /// 注册失败（其他 OSStatus）
    case registrationFailed(on: KeyCombo, status: Int32)

    /// 面向用户的提示文案；成功时为 `nil`
    public var failureMessage: String? {
        switch self {
        case .applied:
            nil
        case .rejected(let error):
            error.message
        case .occupied(let combo):
            L10n.t("\(combo.displayString) 已被其他应用占用（例如微信的截图快捷键）。\n请到菜单栏「快捷键…」换一个组合。")
        case .registrationFailed(_, let status):
            L10n.t("注册快捷键失败（错误码 \(status)）")
        }
    }
}

// MARK: - 编排

/// 快捷键服务：持有"当前生效的快捷键"，负责落盘与即时重注册。
///
/// 设计要点（对应"启动后能换键"这条需求）：
/// - `activate()` 在启动时注册，**不**落盘（避免把默认值写进用户偏好，见 `clear()` 的注释）
/// - `change(to:)` **先校验、再注册、成功才落盘**，失败时把旧键装回去 ——
///   任何一步都不能让用户落到"没有可用快捷键"的状态
@MainActor
public final class ShortcutService {

    public static let defaultCombo = KeyCombo.fullScreenCapture

    /// 当前生效的快捷键
    public private(set) var current: KeyCombo
    /// 最近一次注册的原始结果（诊断用）
    public private(set) var lastRegistration: HotKeyRegistrationOutcome = .registered

    private let store: ShortcutStoring
    private let registrar: HotKeyRegistering
    private let handler: @MainActor () -> Void
    /// 还有几个录制器正在录。见 `suspendForRecording()`。
    ///
    /// 用**计数**而不是布尔：设置窗与引导窗各有一个录制器、共用这一个服务，
    /// 布尔会让"先结束的那个"把全局注册提前装回来 —— 而另一个还在录，
    /// 于是它又按不动自己的键了（同一个 bug 换个入口复发）。
    private var recordingDepth = 0

    public init(store: ShortcutStoring,
                registrar: HotKeyRegistering,
                handler: @escaping @MainActor () -> Void) {
        self.store = store
        self.registrar = registrar
        self.handler = handler
        self.current = store.load() ?? Self.defaultCombo
    }

    /// 启动时调用：注册当前（已存或默认的）快捷键。
    @discardableResult
    public func activate() -> ShortcutChangeResult {
        apply(current, persist: false)
    }

    /// 用户改了快捷键。校验 → 试注册 → 成功才落盘；失败则回滚到上一个可用组合。
    @discardableResult
    public func change(to combo: KeyCombo) -> ShortcutChangeResult {
        if let error = ShortcutValidation.validate(combo) {
            return .rejected(error)
        }
        let previous = current
        let result = apply(combo, persist: true)
        guard case .applied = result else {
            _ = apply(previous, persist: false)
            return result
        }
        return result
    }

    /// 恢复默认快捷键
    @discardableResult
    public func resetToDefault() -> ShortcutChangeResult {
        change(to: Self.defaultCombo)
    }

    public func stop() {
        recordingDepth = 0
        registrar.unregister()
    }

    /// 进入"录制中"：把全局注册摘下来。
    ///
    /// ## 为什么非做不可
    ///
    /// Carbon 的 `RegisterEventHotKey` 是**系统级**的：它在按键送到本应用的响应链
    /// 之前就把它吃掉了。于是"录制时按下**当前生效**的那颗键"会同时踩两个坑 ——
    ///
    /// 1. 录制器收不到 `keyDown`，界面毫无反应（用户看到的："设置无效"）；
    /// 2. 那一下被当成一次真实的截屏请求，屏幕上真的浮出覆盖层。
    ///
    /// 也就是说，用户**最想按的那颗键（就是现在用的这颗）恰恰是唯一录不进去的**。
    /// 挂起之后录制器才收得到它自己。
    ///
    /// 计数式的：只有第一个进入的录制器会真的注销，也只有最后一个离开的会装回去。
    public func suspendForRecording() {
        recordingDepth += 1
        guard recordingDepth == 1 else { return }
        registrar.unregister()
    }

    /// 退出"录制中"：**最后一个**录制器离开时把 `current` 装回去。
    ///
    /// ⚠️ **不走 `apply`**：`apply` 里那道独占探测一旦返回 `.conflict` 就会
    /// **什么都不注册**。而这个组合此前已经注册成功过（否则不会成为 `current`），
    /// 再问一次系统毫无意义，问错了却会把一个本来可用的键弄丢。
    /// 更要紧的是：非独占注册在"别的应用也占着同一个键"时依然会成功，
    /// 这种共存本就正常工作 —— 挂起一次不该把它变成"被占用"。
    ///
    /// 若录制结束时已经通过 `change(to:)` 注册过新键，深度已被清成 0，
    /// 这里是空操作（重复 `register` 会被 Carbon 判成冲突）。
    public func resumeAfterRecording() {
        guard recordingDepth > 0 else { return }
        recordingDepth -= 1
        guard recordingDepth == 0 else { return }
        lastRegistration = registrar.register(current, handler: handler)
    }

    private func apply(_ combo: KeyCombo, persist: Bool) -> ShortcutChangeResult {
        // 任何一次"真的去注册"都结束了挂起状态 —— 否则随后的
        // `resumeAfterRecording()` 会把同一个组合再注册一遍（Carbon 会报冲突）。
        recordingDepth = 0

        // 先注销再注册：Carbon 对同一进程内同一组合的重复注册会返回 eventHotKeyExistsErr，
        // 不先注销的话"把 A 换成 A"这种操作会假报冲突。
        // 而且**带着自己的注册去独占探测也会假报占用**（本机实测），所以顺序不能换。
        registrar.unregister()

        // 非独占注册永远成功 → 必须用独占探测才能问出"这个键是不是别人在用"
        if case .conflict = registrar.probeAvailability(of: combo) {
            return .occupied(combo)
        }

        let outcome = registrar.register(combo, handler: handler)
        lastRegistration = outcome

        switch outcome {
        case .registered:
            current = combo
            if persist { store.save(combo) }
            return .applied(combo)
        case .conflict:
            return .occupied(combo)
        case .failed(let status):
            return .registrationFailed(on: combo, status: status)
        }
    }
}

// MARK: - 默认实现

/// `UserDefaults` 版偏好存储。
///
/// 放在 Core 而不是 `MarqueeSettings`：它只用到 Foundation，
/// 放这里可以用一个临时 suite 直接单测落盘/读回/清除三条路径，
/// 不必为此单独开一个测试 target。
public struct UserDefaultsShortcutStore: ShortcutStoring, @unchecked Sendable {

    public static let storageKey = "shortcut.fullScreenCapture"

    // `UserDefaults` 文档保证线程安全；`@unchecked Sendable` 显式承担该保证。
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> KeyCombo? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    public func save(_ combo: KeyCombo) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

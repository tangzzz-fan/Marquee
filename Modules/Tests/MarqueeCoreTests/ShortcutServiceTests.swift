import Foundation
import Testing
@testable import MarqueeCore

// MARK: - 测试替身

private final class FakeStore: ShortcutStoring, @unchecked Sendable {
    var stored: KeyCombo?
    private(set) var saveCount = 0

    init(stored: KeyCombo? = nil) { self.stored = stored }

    func load() -> KeyCombo? { stored }
    func save(_ combo: KeyCombo) { stored = combo; saveCount += 1 }
    func clear() { stored = nil }
}

@MainActor
private final class FakeRegistrar: HotKeyRegistering {
    /// 按"要注册的组合"决定结果，用来模拟"新键被占用、旧键可用"
    var outcome: (KeyCombo) -> HotKeyRegistrationOutcome = { _ in .registered }
    /// 独占探测的返回值：`.conflict` 表示这个组合已被别的应用占用
    var probeOutcome: (KeyCombo) -> HotKeyRegistrationOutcome = { _ in .registered }
    private(set) var registeredCombos: [KeyCombo] = []
    private(set) var probedCombos: [KeyCombo] = []
    private(set) var unregisterCount = 0

    @discardableResult
    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> HotKeyRegistrationOutcome {
        registeredCombos.append(combo)
        return outcome(combo)
    }

    func unregister() { unregisterCount += 1 }

    func probeAvailability(of combo: KeyCombo) -> HotKeyRegistrationOutcome {
        probedCombos.append(combo)
        return probeOutcome(combo)
    }
}

private let comboB = KeyCombo(keyCode: 0x0B, modifiers: [.control, .command], keyLabel: "B")
private let comboNoModifier = KeyCombo(keyCode: 0x0B, modifiers: [], keyLabel: "B")

@MainActor
private func makeService(stored: KeyCombo? = nil)
    -> (service: ShortcutService, store: FakeStore, registrar: FakeRegistrar) {
    let store = FakeStore(stored: stored)
    let registrar = FakeRegistrar()
    let service = ShortcutService(store: store, registrar: registrar, handler: {})
    return (service, store, registrar)
}

// MARK: - 校验

@Suite("快捷键校验：拦掉会把系统输入抢走的组合")
struct ShortcutValidationTests {

    @Test("没有修饰键 → 拒绝")
    func missingModifier() {
        #expect(ShortcutValidation.validate(comboNoModifier) == .missingModifier)
    }

    @Test("只有 ⇧ → 拒绝（会吃掉用户的普通输入）")
    func shiftOnly() {
        let combo = KeyCombo(keyCode: 0x00, modifiers: [.shift], keyLabel: "A")
        #expect(ShortcutValidation.validate(combo) == .shiftOnly)
    }

    @Test("⌃⌘A 是合法的")
    func defaultComboIsValid() {
        #expect(ShortcutValidation.validate(KeyCombo.fullScreenCapture) == nil)
    }

    @Test("系统保留组合被拦下并说明原因")
    func reservedCombos() {
        // 系统截图 ⌘⇧3
        let systemShot = KeyCombo(keyCode: 0x14, modifiers: [.command, .shift], keyLabel: "3")
        #expect(ShortcutValidation.validate(systemShot) == .reservedBySystem(conflict: "系统截图（全屏）"))

        // 应用切换 ⌘⇥
        let appSwitch = KeyCombo(keyCode: 0x30, modifiers: [.command], keyLabel: "⇥")
        #expect(ShortcutValidation.validate(appSwitch) == .reservedBySystem(conflict: "应用切换"))
    }

    @Test("提示文案不是空字符串 —— 否则用户看到的是一个没有原因的失败")
    func errorMessagesAreActionable() {
        #expect(!ShortcutValidationError.missingModifier.message.isEmpty)
        #expect(!ShortcutValidationError.shiftOnly.message.isEmpty)
        #expect(ShortcutValidationError.reservedBySystem(conflict: "应用切换").message.contains("应用切换"))
    }
}

// MARK: - 服务编排

@Suite("快捷键服务：启动、改键、回滚")
@MainActor
struct ShortcutServiceTests {

    @Test("从未存过偏好 → 用默认 ⌃⌘A")
    func fallsBackToDefault() {
        let harness = makeService(stored: nil)
        #expect(harness.service.current == .fullScreenCapture)
    }

    @Test("存过偏好 → 读取已保存的组合")
    func readsStoredCombo() {
        let harness = makeService(stored: comboB)
        #expect(harness.service.current == comboB)
    }

    @Test("启动注册**不**写盘：免得把默认值固化成用户偏好")
    func activateDoesNotPersist() {
        let harness = makeService(stored: nil)
        #expect(harness.service.activate() == .applied(.fullScreenCapture))
        #expect(harness.store.saveCount == 0)
        #expect(harness.registrar.registeredCombos == [.fullScreenCapture])
    }

    @Test("改键成功 → 注册新键 + 落盘")
    func changeAppliesAndPersists() {
        let harness = makeService(stored: nil)
        _ = harness.service.activate()

        #expect(harness.service.change(to: comboB) == .applied(comboB))
        #expect(harness.service.current == comboB)
        #expect(harness.store.stored == comboB)
        #expect(harness.registrar.registeredCombos.last == comboB)
    }

    @Test("改键前先注销 —— 否则把 A 换成 A 会被 Carbon 误报为冲突")
    func unregistersBeforeRegistering() {
        let harness = makeService(stored: nil)
        _ = harness.service.activate()
        let before = harness.registrar.unregisterCount

        _ = harness.service.change(to: comboB)
        #expect(harness.registrar.unregisterCount == before + 1)
    }

    @Test("探测到被别人占用 → 直接判定占用，**不**去注册（非独占注册永远成功，注册了也收不到事件）")
    func occupiedProbeBlocksRegistration() {
        let harness = makeService(stored: nil)
        harness.registrar.probeOutcome = { _ in .conflict }

        let result = harness.service.activate()

        #expect(result == .occupied(.fullScreenCapture))
        #expect(harness.registrar.probedCombos == [.fullScreenCapture])
        #expect(harness.registrar.registeredCombos.isEmpty, "已被占用就不该留下一个收不到事件的注册")
    }

    @Test("探测顺序：先注销自己再探测 —— 带着自己的非独占注册探测会假报占用")
    func unregistersBeforeProbing() {
        let harness = makeService(stored: nil)
        _ = harness.service.activate()
        let unregistersBefore = harness.registrar.unregisterCount

        _ = harness.service.change(to: comboB)

        #expect(harness.registrar.unregisterCount > unregistersBefore)
        #expect(harness.registrar.probedCombos.last == comboB)
    }

    @Test("改键时探测到新键被占 → 报告占用并回滚到旧键，且不落盘")
    func occupiedOnChangeRollsBack() {
        let harness = makeService(stored: nil)
        _ = harness.service.activate()
        // 只有 comboB 被占，旧键仍然可用 —— 才能验证回滚真的把它装回去了
        harness.registrar.probeOutcome = { $0 == comboB ? .conflict : .registered }

        let result = harness.service.change(to: comboB)

        #expect(result == .occupied(comboB))
        #expect(harness.service.current == .fullScreenCapture, "回滚到旧键")
        #expect(harness.registrar.registeredCombos.last == .fullScreenCapture)
        #expect(harness.store.stored == nil, "冲突时不能落盘")
    }

    @Test("非法组合**不**做探测：连碰都不该碰系统")
    func invalidComboIsNotProbed() {
        let harness = makeService(stored: nil)
        _ = harness.service.activate()
        let probesBefore = harness.registrar.probedCombos.count

        let result = harness.service.change(to: comboNoModifier)

        #expect(result == .rejected(.missingModifier))
        #expect(harness.registrar.probedCombos.count == probesBefore, "非法组合应在本地就被拦下")
        #expect(!harness.registrar.probedCombos.contains(comboNoModifier))
    }

    @Test("非法组合 → 拒绝，且完全不碰系统、不落盘")
    func invalidComboRejected() {
        let harness = makeService(stored: nil)
        _ = harness.service.activate()
        let registrationsBefore = harness.registrar.registeredCombos.count

        let result = harness.service.change(to: comboNoModifier)

        #expect(result == .rejected(.missingModifier))
        #expect(harness.service.current == .fullScreenCapture)
        #expect(harness.registrar.registeredCombos.count == registrationsBefore)
        #expect(harness.store.saveCount == 0)
    }

    @Test("新键被别的应用占用 → 报告占用，并回滚到旧键，不能留下「没有快捷键」的状态")
    func conflictRollsBack() {
        let harness = makeService(stored: nil)
        _ = harness.service.activate()

        harness.registrar.outcome = { combo in
            combo == comboB ? .conflict : .registered
        }

        let result = harness.service.change(to: comboB)

        #expect(result == .occupied(comboB))
        #expect(harness.service.current == .fullScreenCapture, "回滚到旧键")
        #expect(harness.registrar.registeredCombos.last == .fullScreenCapture)
        #expect(harness.store.stored == nil, "冲突时不能落盘")
    }

    @Test("注册失败（其他错误码）→ 报告状态码并回滚")
    func otherFailureRollsBack() {
        let harness = makeService(stored: nil)
        _ = harness.service.activate()
        harness.registrar.outcome = { _ in .failed(status: -50) }

        let result = harness.service.change(to: comboB)

        #expect(result == .registrationFailed(on: comboB, status: -50))
        #expect(harness.service.current == .fullScreenCapture)
        #expect(harness.store.stored == nil)
    }

    @Test("恢复默认 → 生效并落盘默认组合")
    func resetToDefault() {
        let harness = makeService(stored: comboB)
        _ = harness.service.activate()

        #expect(harness.service.resetToDefault() == .applied(.fullScreenCapture))
        #expect(harness.store.stored == .fullScreenCapture)
    }

    @Test("成功的改键没有失败文案，失败的都有")
    func failureMessages() {
        #expect(ShortcutChangeResult.applied(comboB).failureMessage == nil)
        #expect(ShortcutChangeResult.rejected(.missingModifier).failureMessage != nil)
        #expect(ShortcutChangeResult.occupied(comboB).failureMessage?.contains(comboB.displayString) == true)
    }
}

// MARK: - 落盘

@Suite("快捷键偏好的落盘与读回")
struct UserDefaultsShortcutStoreTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "com.tango.Marquee.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("没存过 → nil（让调用方用默认值，而不是把默认值当作用户选择）")
    func emptyReturnsNil() {
        let store = UserDefaultsShortcutStore(defaults: makeDefaults())
        #expect(store.load() == nil)
    }

    @Test("存 → 读回同一个组合")
    func roundTrip() {
        let store = UserDefaultsShortcutStore(defaults: makeDefaults())
        store.save(comboB)
        #expect(store.load() == comboB)
    }

    @Test("clear 之后回到 nil")
    func clearRemovesValue() {
        let defaults = makeDefaults()
        let store = UserDefaultsShortcutStore(defaults: defaults)
        store.save(comboB)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("存储内容被外部改坏时返回 nil，而不是崩溃")
    func corruptDataReturnsNil() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: UserDefaultsShortcutStore.storageKey)
        let store = UserDefaultsShortcutStore(defaults: defaults)
        #expect(store.load() == nil)
    }
}

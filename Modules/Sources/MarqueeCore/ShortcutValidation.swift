import Foundation

/// 一个快捷键为什么不能被采用。
public enum ShortcutValidationError: Equatable, Sendable {
    /// 一个修饰键都没按 —— 全局注册裸键会把整个系统的输入抢走
    case missingModifier
    /// 只有 ⇧ —— 全局注册后用户打不出大写字母
    case shiftOnly
    /// 与系统固定快捷键冲突（`conflict` 是它的可读称呼，用于提示文案）
    case reservedBySystem(conflict: String)

    /// 面向用户的提示文案
    public var message: String {
        switch self {
        case .missingModifier:
            "至少要有一个修饰键（⌘ ⌃ ⌥）"
        case .shiftOnly:
            "只有 ⇧ 不够，会和普通输入冲突，请带上 ⌘ ⌃ 或 ⌥"
        case .reservedBySystem(let conflict):
            "这个组合已被系统占用：\(conflict)"
        }
    }
}

/// 快捷键合法性校验。
///
/// 为什么要有这一层：全局快捷键是**系统级**的，注册成功就意味着所有应用都收不到这个按键。
/// 把 ⌘⇥、⌘⇧3 这类系统保留组合交给 Carbon，会得到一个"注册成功但行为诡异"的结果 ——
/// 比直接拒绝更糟。所以先在纯逻辑层拦掉。
public enum ShortcutValidation {

    /// 通过返回 `nil`
    public static func validate(_ combo: KeyCombo) -> ShortcutValidationError? {
        if combo.modifiers.isEmpty {
            return .missingModifier
        }
        if combo.modifiers == [.shift] {
            return .shiftOnly
        }
        if let name = reservedSystemShortcuts[combo] {
            return .reservedBySystem(conflict: name)
        }
        return nil
    }

    public static func isValid(_ combo: KeyCombo) -> Bool {
        validate(combo) == nil
    }

    /// 系统固定占用的组合。
    ///
    /// 只列"注册后一定会出问题"的：任务切换、Spotlight、系统截图、隐藏当前应用、锁屏。
    /// 不追求穷举 —— 真正占用与否由 Carbon 注册的 `eventHotKeyExistsErr` 兜底
    /// （见 `HotKeyRegistrationOutcome.conflict`），这里只拦掉那些"系统不会报错但会打架"的。
    private static let reservedSystemShortcuts: [KeyCombo: String] = {
        func combo(_ keyCode: UInt32, _ modifiers: ShortcutModifiers, _ label: String) -> KeyCombo {
            KeyCombo(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
        }
        return [
            combo(0x30, [.command], "⇥"): "应用切换",
            combo(0x32, [.command], "`"): "窗口切换",
            combo(0x31, [.command], "Space"): "Spotlight",
            combo(0x31, [.control, .command], "Space"): "表情与符号",
            combo(0x03, [.control, .command], "F"): "全屏切换",
            combo(0x0C, [.control, .command], "Q"): "锁定屏幕",
            combo(0x14, [.command, .shift], "3"): "系统截图（全屏）",
            combo(0x15, [.command, .shift], "4"): "系统截图（选区）",
            combo(0x17, [.command, .shift], "5"): "系统截图（工具条）",
            combo(0x16, [.command, .shift], "6"): "系统截图（触控栏）",
            combo(0x2F, [.command, .shift], "."): "隐藏当前应用",
        ]
    }()
}

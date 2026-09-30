import CoreGraphics
import Foundation

/// Carbon 虚拟键码 → 显示字形。
///
/// 数值全部取自 SDK `HIToolbox/Events.h` 的 `kVK_*`（已逐条核对，不是凭记忆写的）。
/// 特别提醒：`kVK_ANSI_5` = 0x17、`kVK_ANSI_6` = 0x16，**不是**顺序排列的 ——
/// 照直觉按下标推会得到一张错的表。
///
/// 表里只覆盖"能当一个快捷键主键"的按键：字母、数字、标点、编辑键、方向键、功能键。
/// 修饰键（⌘⌥⌃⇧）刻意不在表内：它们只能作为修饰出现，单独成键不是合法快捷键。
public enum KeyCodeLabel {

    /// 键码 → 字形；`nil` 表示该键码不被支持（或本身就是修饰键）。
    public static func label(for keyCode: UInt32) -> String? {
        table[keyCode]
    }

    /// 该键码是否是修饰键（⌘⌥⌃⇧ / Caps Lock / Fn）。
    public static func isModifierKey(_ keyCode: UInt32) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    private static let modifierKeyCodes: Set<UInt32> = [
        0x37, // kVK_Command
        0x38, // kVK_Shift
        0x3A, // kVK_Option
        0x3B, // kVK_Control
        0x36, // kVK_RightCommand
        0x3C, // kVK_RightShift
        0x3D, // kVK_RightOption
        0x3E, // kVK_RightControl
        0x39, // kVK_CapsLock
        0x3F, // kVK_Function
    ]

    private static let table: [UInt32: String] = [
        // 字母
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        // 数字（注意 5 / 6 是反序的）
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6",
        0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        // 标点
        0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[", 0x27: "'", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2F: ".", 0x32: "`",
        // 编辑与空白
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
        // 方向键
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        // 功能键
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]
}

// MARK: - 从事件构造快捷键

extension KeyCombo {

    /// 把「虚拟键码 + 设备无关修饰位」翻译成一个快捷键。
    ///
    /// 参数用 `UInt` 裸位而不是 `NSEvent.ModifierFlags`：Core 层不引入 AppKit，
    /// 调用方传 `event.modifierFlags.rawValue` 即可。
    /// 这些位值与 `NSEvent.ModifierFlags` / `CGEventFlags` 的公开取值一致且稳定。
    ///
    /// 返回 `nil` 表示这次按键不构成合法主键（按的是修饰键，或键码不在支持表内）。
    public static func from(keyCode: UInt32, deviceIndependentFlags flags: UInt) -> KeyCombo? {
        guard !KeyCodeLabel.isModifierKey(keyCode),
              let label = KeyCodeLabel.label(for: keyCode)
        else { return nil }
        return KeyCombo(keyCode: keyCode,
                        modifiers: ShortcutModifiers(deviceIndependentFlags: flags),
                        keyLabel: label)
    }
}

extension ShortcutModifiers {

    /// 设备无关修饰位（`NSEvent.ModifierFlags`）→ 语义修饰键。
    ///
    /// 位值取自 SDK `NSEvent.h:168-172`（`NSEventModifierFlag*`），逐条核对过：
    /// `capsLock = 1<<16`、`shift = 1<<17`、`control = 1<<18`、`option = 1<<19`、`command = 1<<20`。
    ///
    /// ⚠️ 别凭"⌘ 应该是最重要的所以位更大"之类的直觉写 —— `1<<16` 是 **Caps Lock**，
    /// 写错了不会崩，只会让所有 ⌘ 组合静默地变成"没按 ⌘"。
    public init(deviceIndependentFlags flags: UInt) {
        var result: ShortcutModifiers = []
        if flags & 0x0010_0000 != 0 { result.insert(.command) } // NSEventModifierFlagCommand
        if flags & 0x0002_0000 != 0 { result.insert(.shift) }   // NSEventModifierFlagShift
        if flags & 0x0008_0000 != 0 { result.insert(.option) }  // NSEventModifierFlagOption
        if flags & 0x0004_0000 != 0 { result.insert(.control) } // NSEventModifierFlagControl
        self = result
    }
}

import Foundation
import Testing
@testable import MarqueeCore

@Suite("KeyCombo：键码映射与显示")
struct KeyboardShortcutTests {

    @Test("默认全屏截图快捷键是 ⌃⌘A")
    func defaultCombo() {
        let combo = KeyCombo.fullScreenCapture
        #expect(combo.keyCode == 0x00) // kVK_ANSI_A
        #expect(combo.modifiers == [.control, .command])
        #expect(combo.displayString == "⌃⌘A")
    }

    @Test("显示顺序按 macOS 惯例：⌃ ⌥ ⇧ ⌘")
    func displayOrderMatchesSystemConvention() {
        let combo = KeyCombo(keyCode: 0x00,
                             modifiers: [.command, .shift, .option, .control],
                             keyLabel: "A")
        #expect(combo.displayString == "⌃⌥⇧⌘A")
    }

    @Test("从事件构造：数字键 5 与 6 的键码是反序的，别照下标推")
    func digitFiveAndSixAreSwapped() {
        // kVK_ANSI_5 = 0x17，kVK_ANSI_6 = 0x16（Events.h 实测）
        #expect(KeyCodeLabel.label(for: 0x17) == "5")
        #expect(KeyCodeLabel.label(for: 0x16) == "6")
    }

    @Test("从设备无关修饰位构造：只取 ⌘⌥⌃⇧，忽略 Caps Lock 等")
    func modifierFlagsMapping() {
        // 位值取自 NSEvent.h:168-172，与实现里的常量一一对应
        let capsLock: UInt = 0x0001_0000 // 1 << 16 —— 注意这里不是 ⌘
        let shift: UInt = 0x0002_0000    // 1 << 17
        let control: UInt = 0x0004_0000  // 1 << 18
        let option: UInt = 0x0008_0000   // 1 << 19
        let command: UInt = 0x0010_0000  // 1 << 20
        let function: UInt = 0x0080_0000 // 1 << 23

        let modifiers = ShortcutModifiers(
            deviceIndependentFlags: command | shift | control | option | capsLock | function
        )
        #expect(modifiers.contains(.command))
        #expect(modifiers.contains(.shift))
        #expect(modifiers.contains(.control))
        #expect(modifiers.contains(.option))
        #expect(modifiers == [.control, .option, .shift, .command])
    }

    @Test("⌘ 的位是 1<<20：写成 1<<16 会静默变成 Caps Lock")
    func commandBitIsNotCapsLockBit() {
        let commandOnly = ShortcutModifiers(deviceIndependentFlags: 0x0010_0000)
        #expect(commandOnly == .command)
        let capsLockOnly = ShortcutModifiers(deviceIndependentFlags: 0x0001_0000)
        #expect(capsLockOnly.isEmpty)
    }

    @Test("修饰键本身不构成快捷键主键")
    func modifierKeysAreNotComboKeys() {
        // 单独按 ⌘（0x37）不该产出一个快捷键
        #expect(KeyCombo.from(keyCode: 0x37, deviceIndependentFlags: 0) == nil)
        // 未知键码也不产出
        #expect(KeyCombo.from(keyCode: 0xFF, deviceIndependentFlags: 0) == nil)
    }

    @Test("按 ⇧3 得到的是 ⇧+3，字形取下档位")
    func shiftedDigitKeepsUnshiftedGlyph() {
        let combo = KeyCombo.from(keyCode: 0x14, // kVK_ANSI_3
                                  deviceIndependentFlags: 0x0010_0000 | 0x0002_0000) // ⌘ + ⇧
        #expect(combo?.keyLabel == "3")
        #expect(combo?.modifiers == [.command, .shift])
        #expect(combo?.displayString == "⇧⌘3")
    }

    @Test("Codable 往返：落盘再读回要得到同一个组合")
    func codableRoundTrip() throws {
        let original = KeyCombo(keyCode: 0x0B,
                                modifiers: [.option, .command],
                                keyLabel: "B")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        #expect(decoded == original)
    }
}

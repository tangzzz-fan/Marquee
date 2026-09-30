import Foundation

/// 快捷键的修饰键集合。
///
/// 刻意**不**直接存 Carbon 的 `cmdKey` / `shiftKey` 等常量：
/// `MarqueeCore` 是纯逻辑层，不该知道平台注册细节。
/// 语义修饰键 → Carbon 修饰键的映射发生在注册层（`MarqueeSettings.GlobalHotKey`），
/// 这样"⌃⌘A 长什么样、是否相等"这类判断可以脱离窗口系统单测。
public struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// macOS 惯例的显示顺序：⌃ ⌥ ⇧ ⌘，与系统菜单里的呈现一致。
    private static let displayOrder: [(ShortcutModifiers, String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    /// 形如 `⌃⌘` 的前缀（不含主键）
    public var displayPrefix: String {
        Self.displayOrder
            .filter { contains($0.0) }
            .map(\.1)
            .joined()
    }
}

/// 一个全局快捷键：虚拟键码 + 修饰键。
///
/// `Codable` 是为了落盘（`MarqueeSettings.ShortcutStore`）——
/// 属性全是标量，合成的编解码是稳定格式，不要手写 `CodingKeys` 去改字段名，
/// 否则用户已经存下的偏好会读不回来。
public struct KeyCombo: Hashable, Codable, Sendable {
    /// Carbon 虚拟键码（`kVK_ANSI_A` = 0x00 这种）
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers
    /// 主键的显示字形。
    ///
    /// 现在只存字形而不是从 `keyCode` 反查：完整的 虚拟键码 → 字形 映射表
    /// 属于 ticket 15（快捷键可配置）的活。在那之前，硬塞一张残缺的表
    /// 只会让"用户改了快捷键后显示错字"变成一个更难查的 bug。
    public let keyLabel: String

    public init(keyCode: UInt32, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// 形如 `⌃⌘A`
    public var displayString: String {
        modifiers.displayPrefix + keyLabel
    }
}

extension KeyCombo {
    /// 默认的「全屏截图」快捷键：⌃⌘A（ticket 02）
    ///
    /// 选这个组合的理由：旧版 Snip 与系统截图都占用了 ⌘⇧ 系列，
    /// ⌃⌘A 在主流应用里未被占用（已有对照见 `docs/SPIKE-PLAN.md` G2）。
    public static let fullScreenCapture = KeyCombo(keyCode: 0x00, // kVK_ANSI_A
                                                   modifiers: [.control, .command],
                                                   keyLabel: "A")
}

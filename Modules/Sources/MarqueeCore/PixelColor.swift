import CoreGraphics
import Foundation

/// 一个像素的颜色。ticket 10（放大镜取色）。
///
/// 组件是 **0...255 的 sRGB**，不是 0...1 的浮点：取色最终是给人看的
/// （`#1A2B3C`、`rgb(26, 43, 60)`），全程用整数可以避免"显示的和复制的不一致"
/// 这种只在末位差 1 的别扭问题。
public struct PixelColor: Equatable, Sendable, Hashable {

    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 从 0...1 的分量构造（四舍五入到 0...255）。
    ///
    /// ⚠️ 调用方给的颜色必须已经在 **sRGB** 空间里。本机是 P3 屏，
    /// 拿设备 RGB 分量的浮点值直接进来会偏色（`docs/SPIKE-PLAN.md` 与 MEMORY 陷阱 11）。
    public init(unitRed: Double, unitGreen: Double, unitBlue: Double) {
        func component(_ value: Double) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        self.init(red: component(unitRed), green: component(unitGreen), blue: component(unitBlue))
    }

    public static let black = PixelColor(red: 0, green: 0, blue: 0)
    public static let white = PixelColor(red: 255, green: 255, blue: 255)

    // MARK: - 格式

    /// 复制色值时用的格式。ticket 15 会把选择权暴露到偏好设置里。
    public enum Format: String, CaseIterable, Sendable {
        case hex
        case rgb
        case hsb

        public var displayName: String {
            switch self {
            case .hex: "HEX"
            case .rgb: "RGB"
            case .hsb: "HSB"
            }
        }
    }

    public func string(in format: Format) -> String {
        switch format {
        case .hex: hexString
        case .rgb: rgbString
        case .hsb: hsbString
        }
    }

    /// `#1A2B3C` —— 大写、带 `#`，可直接贴进 CSS
    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// `rgb(26, 43, 60)`
    public var rgbString: String {
        "rgb(\(red), \(green), \(blue))"
    }

    /// `hsb(210, 40%, 24%)` —— 色相取整度数，饱和度/亮度取整百分比
    public var hsbString: String {
        let hsb = hsbComponents
        return "hsb(\(Int(hsb.hue.rounded())), \(Int((hsb.saturation * 100).rounded()))%, "
            + "\(Int((hsb.brightness * 100).rounded()))%)"
    }

    /// 色相 0...360、饱和度与亮度 0...1。
    ///
    /// 边界行为（有单测钉住）：
    /// - 黑 `(0,0,0)` → `(0, 0, 0)`
    /// - 白 `(255,255,255)` → `(0, 0, 1)`：灰色没有色相，取 0 而不是 undefined
    /// - 纯红 `(255,0,0)` → `(0, 1, 1)`
    public var hsbComponents: (hue: Double, saturation: Double, brightness: Double) {
        let r = Double(red) / 255
        let g = Double(green) / 255
        let b = Double(blue) / 255

        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum

        // 亮度就是最大值；饱和度为 0 时（纯灰）色相无意义，取 0
        let brightness = maximum
        let saturation = maximum == 0 ? 0 : delta / maximum
        guard delta > 0 else { return (0, saturation, brightness) }

        var hue: Double
        if maximum == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return (hue, saturation, brightness)
    }
}

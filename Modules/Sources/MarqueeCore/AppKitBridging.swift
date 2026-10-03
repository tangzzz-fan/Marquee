#if canImport(AppKit)
import AppKit

/// `RGB`（Core 的 sRGB 值）→ `NSColor`。**全项目唯一一份实现。**
///
/// ## 为什么放在 Core（而不是某个视图模块里）
///
/// 因为它**不止一个模块要用**：覆盖层、App 宿主（偏好设置 / 最近截图 / 菜单栏）、
/// 以后的编辑器都要把同一份色板翻成 `NSColor`。
///
/// 放在某一个模块里的话，别的模块要么 import 它（**模块之间不许互相依赖**），
/// 要么自己写一份 —— 而自己写的那一份迟早会与这份分叉
///（最容易分叉的就是 alpha：`NSColor(red:...)` 忘了带 `alpha:` 参数时，
/// 半透明色会画成实心，而**画错的颜色不报错**）。
///
/// ⚠️ 用 `#if canImport(AppKit)` 包着：Core 的主体仍然是纯逻辑（可以在没有 UI 的
/// 上下文里跑），只有这一小块是"翻译给 AppKit 看的适配器"。
/// **适配器里不许做判断** —— 这里只有两个赋值，没有任何 `if`。
///
/// ## 两条都不能省
///
/// · **alpha 要带上** —— 色板里一半的颜色是半透明的（暗幕 32%、次要文字 64%、
///   格图标 82%、置灰 30%、小锁 55%…）。写死 `alpha: 1` 等于把「半透明」这个信息
///   **在最后一步丢掉了**，画出来全是实心，而那种错只会"看着差点意思"。
/// · **用 `srgbRed:` 而不是 `red:`** —— 后者是 deviceRGB，而设计稿给的是 sRGB
///   （P3 屏上两者能差出一眼可见的色偏，而"谁对"肉眼判断不了）。
public extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

public extension ChromePalette.Theme {

    /// 按一套系统外观取深浅。
    ///
    /// **入参化**（而不是在这里读 `NSApp.effectiveAppearance`）与
    /// `ChromePalette.resolved(isDark:)` / `ChromeMaterial.resolved(glassAvailable:)` 同一套路：
    /// 判断留在纯逻辑那边，这边只做"外观 → 是不是深色"这一次翻译。
    ///
    /// 判据用 `bestMatch(from:)` 而不是 `name == .darkAqua`：外观名不止两个
    /// （`.accessibilityHighContrastDarkAqua` 这些都要算作深色），
    /// 而按名字逐个比会**漏掉**它们 —— 表现是"开了高对比度之后界面变成浅色"。
    static func resolved(for appearance: NSAppearance) -> ChromePalette.Theme {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return ChromePalette.resolved(isDark: isDark)
    }

    /// 当前该用的那一套。
    ///
    /// ⚠️ **不要把这个用在 `draw` 之外的缓存里**：外观会变（用户在系统设置里切换），
    /// 而缓存下来的那一套不会跟着变。绘制时现取，成本只是两次比较。
    ///
    /// `NSApp` 为 `nil` 时（命令行工具、测试进程）回落到当前绘制外观 ——
    /// 不用 `?? .light` 那种兜底：那会让"没有 App 的上下文"静默变成浅色，
    /// 而这个项目里所有"没有 App 的上下文"其实都是深色的覆盖层。
    static var current: ChromePalette.Theme {
        guard let appearance = NSApp?.effectiveAppearance else {
            return resolved(for: NSAppearance.currentDrawing())
        }
        return resolved(for: appearance)
    }
}

/// SF Symbol 的取图与缓存。**全项目唯一一份。**
///
/// ## 为什么必须唯一
///
/// 它有三条容易写漏、而漏了都只是"图标看着怪"的规则：
///
/// 1. **`.preferringMonochrome()` 不能省**：不写它，符号会按自己的首选渲染模式画 ——
///    多色符号的**第一层会被整片填满**，`face.smiling` 因此变成一个实心圆点。
///    而它看起来只是"这个图标长得怪"，完全想不到是着色方式的问题。
/// 2. **缓存键里要带上外观**：动态色（`controlAccentColor`）解析出来的位图随外观变，
///    不区分就会在切换深浅色之后继续用旧位图。
/// 3. **颜色要放进 `SymbolConfiguration` 里**：模板图直接 `draw(in:)` **不会**
///    用"当前颜色"着色，否则图标全是黑的（在深色底上等于没画，而且不报错）。
///
/// 缓存本身不是提前优化：`NSImage(systemSymbolName:)` + `withSymbolConfiguration`
/// **每次调用都会新建一个图像**，而覆盖层工具条一帧要画 15 个 —— 鼠标一动就重建 15 个。
@MainActor
public enum ChromeSymbol {

    private static var cache: [String: NSImage] = [:]

    /// 取一张配好色的符号图。取不到（符号名写错、系统没有）返回 `nil`。
    public static func image(_ name: String,
                             pointSize: CGFloat,
                             weight: NSFont.Weight = .medium,
                             color: NSColor,
                             appearance: NSAppearance?) -> NSImage? {
        // `usingColorSpace` 而不是 `.redComponent`：后者对动态色（强调色）会**抛异常**。
        let resolved = color.usingColorSpace(.sRGB) ?? .white
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(appearance?.name.rawValue ?? "-")|"
            + "\(resolved.redComponent),\(resolved.greenComponent),\(resolved.blueComponent),\(resolved.alphaComponent)"
        if let cached = cache[key] { return cached }

        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
            .applying(.preferringMonochrome())
            .applying(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        cache[key] = made
        return made
    }

    /// 把符号画在矩形正中。
    public static func draw(_ name: String,
                            in rect: CGRect,
                            pointSize: CGFloat,
                            weight: NSFont.Weight = .medium,
                            color: NSColor,
                            appearance: NSAppearance?) {
        guard let image = image(name, pointSize: pointSize, weight: weight,
                                color: color, appearance: appearance) else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2,
                              y: rect.midY - size.height / 2,
                              width: size.width,
                              height: size.height))
    }
}
#endif

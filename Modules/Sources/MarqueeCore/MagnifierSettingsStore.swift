import CoreGraphics
import Foundation

/// 放大镜尺寸的持久化覆盖。
///
/// ## 为什么现在就做
///
/// `samplePoints` / `zoom` / `gap` 这三个数**只能靠眼睛调** ——
/// "看得清内容"和"能对准像素"之间的平衡没有公式，得在真实屏幕上试。
/// 而每试一个值都要重新构建，调参成本高到不会有人去调。
/// 与 ticket 05 的 `output.format` 同一做法：先给一个能用的旋钮，界面留到 ticket 15。
///
/// ```bash
/// defaults write dev.tango.Marquee lens.zoom -float 4
/// defaults write dev.tango.Marquee lens.samplePoints -float 32
/// defaults delete dev.tango.Marquee lens.zoom      # 回到默认
/// ```
///
/// 改完**下一次唤起覆盖层**即生效（不需要重启应用，也不需要重新构建）。
public struct MagnifierSettingsStore: @unchecked Sendable {

    public static let samplePointsKey = "lens.samplePoints"
    public static let zoomKey = "lens.zoom"
    public static let gapKey = "lens.gap"

    /// 允许范围。**必须有**：一个手滑写进去的 `10000` 会让放大镜铺满整块屏，
    /// 而这类错误只在打开覆盖层时才暴露 —— 那时用户已经在截屏了。
    public static let samplePointsRange: ClosedRange<Double> = 8...200
    public static let zoomRange: ClosedRange<Double> = 1...12
    public static let gapRange: ClosedRange<Double> = 0...80

    // `UserDefaults` 文档保证线程安全；`@unchecked Sendable` 显式承担该保证
    // （与 `UserDefaultsShortcutStore` 同一做法）。
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读出放大镜设置：缺省项用 `Settings.default`，越界项夹进范围。
    public func load() -> MagnifierLayout.Settings {
        let fallback = MagnifierLayout.Settings.default
        return MagnifierLayout.Settings(
            samplePoints: Self.clamp(number(Self.samplePointsKey) ?? fallback.samplePoints,
                                     to: Self.samplePointsRange),
            zoom: Self.clamp(number(Self.zoomKey) ?? fallback.zoom, to: Self.zoomRange),
            gap: Self.clamp(number(Self.gapKey) ?? fallback.gap, to: Self.gapRange)
        )
    }

    /// 读一个数。写进来的是字符串之类的东西就当没写（返回 `nil` → 用默认值），
    /// 而不是把它当 0 —— 那样放大镜会静默变成一条线。
    private func number(_ key: String) -> Double? {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(range.lowerBound, value), range.upperBound)
    }
}

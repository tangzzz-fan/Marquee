import CoreGraphics
import Foundation

/// Cocoa 全局坐标 ↔ Quartz 全局坐标。
///
/// **为什么必须有这一层**：Marquee 同时活在两套全局坐标里，而且它们长得几乎一样 ——
/// 都叫"全局坐标"、单位都是点，只有 y 轴方向相反：
///
/// | 空间 | 原点 | y 轴 | 谁在用 |
/// | --- | --- | --- | --- |
/// | Cocoa | 主屏**左下** | 向上 | `NSEvent.mouseLocation`、`NSScreen.frame`、`NSWindow.frame` |
/// | Quartz | 主屏**左上** | 向下 | `CGDisplayBounds`、`SCDisplay.frame`、`DisplayGeometry.frame` |
///
/// 单屏 + 只看主屏时两者恰好只差一个翻转，很容易"看起来是对的"；
/// 一旦有第二块屏（尤其是摆在上方）就会静默错位。所以转换集中在这里，并有单测钉住。
public enum ScreenCoordinateConversion {

    /// 主屏（`frame.origin == .zero` 的那块）的高度 —— 翻转的枢轴。
    ///
    /// 从 `DisplayGeometry` 推而不是从 `NSScreen.screens[0]` 取：
    /// `DisplayGeometry` 用的正是 Quartz 空间，"原点为零的那块屏"在两套空间里是同一块，
    /// 这样不需要额外假设 `screens[0]` 一定是主屏。
    public static func primaryScreenHeight(in displays: [DisplayGeometry]) -> CGFloat? {
        displays.first { $0.frame.origin == .zero }?.frame.height
    }

    public static func quartzPoint(fromCocoa point: CGPoint, primaryScreenHeight height: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }

    public static func cocoaPoint(fromQuartz point: CGPoint, primaryScreenHeight height: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }

    /// 注意矩形是**按边翻**而不是按原点翻：
    /// `y' = height - rect.maxY`，宽高不变。只翻原点会让矩形跑到错误的位置。
    public static func quartzRect(fromCocoa rect: CGRect, primaryScreenHeight height: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: height - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    public static func cocoaRect(fromQuartz rect: CGRect, primaryScreenHeight height: CGFloat) -> CGRect {
        quartzRect(fromCocoa: rect, primaryScreenHeight: height) // 该变换是对合的
    }
}

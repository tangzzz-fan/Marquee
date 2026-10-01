import CoreGraphics
import Foundation

/// 放大镜「这一步要做什么」的判定。
///
/// ## 为什么单独抽出来
///
/// 这个判断曾经写在覆盖层控制器里，用一句「取样像素没变就直接 return」代替，
/// 结果把**两件不同的事**混成了一件：
///
/// - 取样像素没变 → 不需要重新裁剪 + 放大（这是笔真开销，该省）
/// - 光标位置没变 → 盒子不需要挪
///
/// 前者为真时后者**不一定**为真。混在一起的后果是：光标动了、取样像素恰好没变时
/// 整个函数提前返回，**盒子留在原地不动** —— 表现就是「放大镜不跟随鼠标」。
/// 1x 屏上这个现象很常见（走一格像素也算没变），2x 屏上稍少但要撞上只是时间问题。
///
/// 判定本身是纯逻辑，抽到这里就能被完整断言。
public struct MagnifierTracker: Equatable, Sendable {

    /// 这一步该做什么。
    ///
    /// **只有"连盒子都没动"才是 `idle`。** 光标动了但取样像素没变必须报 `moved` ——
    /// 那正是"复用已放大的小图、只把盒子挪过去"的那一档。
    public enum Update: Equatable, Sendable {
        /// 取样像素与盒子位置都没变：不必重画
        case idle
        /// 取样像素没变，只有盒子动了：复用已放大的小图
        case moved(box: CGRect)
        /// 取样像素变了：必须重新裁剪 + 放大
        case resample(box: CGRect, center: PixelCoordinate)
    }

    /// 上一次真正取样的像素
    public private(set) var lastSample: PixelCoordinate?
    /// 上一次的盒子位置（Cocoa 全局坐标）
    public private(set) var lastBox: CGRect?
    /// 上一次取样所属的屏。**换屏必须重采** —— 同一个像素坐标在两块屏上是两个地方。
    public private(set) var lastDisplayID: UInt32?

    public init() {}

    public mutating func reset() {
        lastSample = nil
        lastBox = nil
        lastDisplayID = nil
    }

    /// 登记一次光标位置与取样像素，返回这一步该做什么。
    ///
    /// - Parameters:
    ///   - cursor: 光标位置，**Cocoa 全局坐标**
    ///   - center: 夹取后的取样像素（原图像素坐标）
    ///   - displayID: 取样像素所属的屏
    ///   - screenBounds: 摆位用的屏幕边界，与 `cursor` **同一个坐标空间**
    public mutating func update(cursor: CGPoint,
                                center: PixelCoordinate,
                                displayID: UInt32,
                                settings: MagnifierLayout.Settings,
                                screenBounds: CGRect) -> Update {
        let box = CGRect(origin: MagnifierLayout.origin(cursor: cursor,
                                                        settings: settings,
                                                        screenBounds: screenBounds),
                         size: settings.boxSize)

        let sameDisplay = lastDisplayID == displayID
        let sameSample = sameDisplay && lastSample == center
        if sameSample, lastBox == box {
            return .idle
        }

        lastSample = center
        lastBox = box
        lastDisplayID = displayID
        return sameSample ? .moved(box: box) : .resample(box: box, center: center)
    }
}

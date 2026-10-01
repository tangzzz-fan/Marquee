import CoreGraphics
import Foundation

/// 图像像素坐标系里的整数坐标（原点左上、y 向下）。
public struct PixelCoordinate: Equatable, Sendable, Hashable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// 放大镜的取样与放大。
///
/// 全程在**原图像素**上工作，不涉及点/像素换算 —— 那一步在
/// `MagnifierLayout.imagePixel(forCocoa:on:)` 里单独做掉，两者分开才好各自单测。
public enum PixelSampling {

    /// 把取样中心夹进图像内，**保证整个 side×side 的裁剪区都落在图里**。
    ///
    /// 只夹中心点是不够的：在屏幕角落时中心还有值，但裁剪区会越界，
    /// `CGImage.cropping(to:)` 越界时行为不可依赖（可能返回 nil，也可能给出更小的图）。
    public static func clampedCenter(_ point: CGPoint,
                                     side: Int,
                                     imageWidth: Int,
                                     imageHeight: Int) -> PixelCoordinate {
        let half = max(0, side / 2)
        let maximumX = max(half, imageWidth - 1 - (side - 1 - half))
        let maximumY = max(half, imageHeight - 1 - (side - 1 - half))
        return PixelCoordinate(x: min(max(half, Int(point.x.rounded())), maximumX),
                               y: min(max(half, Int(point.y.rounded())), maximumY))
    }

    /// 读一个像素的颜色。
    ///
    /// 实现走"裁 1×1 再画进 1×1 的 sRGB 上下文"而不是自己算 `dataProvider` 偏移：
    /// 后者要同时处理 `bytesPerRow` 对齐、颜色空间、alpha 预乘、以及裁剪视图的
    /// **共享底层缓冲**（`cropping(to:)` 的 dataProvider 仍是整页，行号要自己加偏移）。
    /// 1×1 重绘把这些一次做完，代价也只有一个 1×1 上下文。
    public static func color(of image: CGImage, at pixel: PixelCoordinate) -> PixelColor? {
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < image.width, pixel.y < image.height else { return nil }
        guard let patch = image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)) else {
            return nil
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          // 1 px 宽 → 4 字节/行，必须对齐成 16（MEMORY 陷阱 24）
                                          bytesPerRow: 16,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drew else { return nil }
        return PixelColor(red: bytes[0], green: bytes[1], blue: bytes[2])
    }

    /// 以 `center` 为中心裁一块 `side×side` 的方形区域，**最近邻**放大 `zoom` 倍。
    ///
    /// 最近邻是放大镜唯一正确的插值：双线性会把相邻像素混起来，
    /// 用户就是想看清"这一格到底是什么颜色"，混色等于把信息抹掉。
    public static func magnified(_ image: CGImage,
                                centeredAt center: PixelCoordinate,
                                side: Int,
                                zoom: Int) -> CGImage? {
        let side = max(1, side)
        let zoom = max(1, zoom)
        let origin = PixelCoordinate(x: center.x - side / 2, y: center.y - side / 2)
        guard origin.x >= 0, origin.y >= 0,
              origin.x + side <= image.width, origin.y + side <= image.height else { return nil }
        guard let patch = image.cropping(to: CGRect(x: origin.x, y: origin.y, width: side, height: side)) else {
            return nil
        }

        let scaledSide = side * zoom
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: scaledSide,
                                      height: scaledSide,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(patch, in: CGRect(x: 0, y: 0, width: scaledSide, height: scaledSide))
        return context.makeImage()
    }
}

/// 放大镜的尺寸与摆位。**纯几何**，可单测。
public struct MagnifierLayout: Equatable, Sendable {

    public struct Settings: Equatable, Sendable {
        /// 取样区域边长（**屏幕点**）。放大镜里看到的就是这么大一块地方。
        public var samplePoints: Double
        /// 放大倍数
        public var zoom: Double
        /// 放大镜与光标之间的间距（点）
        public var gap: Double

        public init(samplePoints: Double = 12, zoom: Double = 8, gap: Double = 18) {
            self.samplePoints = samplePoints
            self.zoom = zoom
            self.gap = gap
        }

        public static let `default` = Settings()

        /// 放大镜盒子的边长（点）
        public var boxSide: Double { samplePoints * zoom }
        public var boxSize: CGSize { CGSize(width: boxSide, height: boxSide) }
    }

    /// 全局 Cocoa 点 → 某块屏**采集帧**里的像素坐标。
    ///
    /// "准确"这件事全靠这一步（验收项：十字线与选区的像素对应关系）：
    /// 全局点 → Quartz（y 翻）→ 减去该屏 origin（屏内点）→ 乘 backingScale（屏内像素）。
    public static func imagePixel(forCocoa point: CGPoint,
                                  on display: DisplayGeometry,
                                  primaryScreenHeight: CGFloat) -> CGPoint {
        let quartz = ScreenCoordinateConversion.quartzPoint(fromCocoa: point,
                                                            primaryScreenHeight: primaryScreenHeight)
        let localX = quartz.x - display.frame.minX
        let localY = quartz.y - display.frame.minY
        return CGPoint(x: localX * display.backingScale, y: localY * display.backingScale)
    }

    /// 放大镜盒子的左上角（Cocoa 全局坐标）。
    ///
    /// 默认放在光标**右下**；任一边越界就翻到另一侧；翻过去仍越界（屏幕太小）才夹住。
    /// 必须保证盒子**不盖住光标** —— 盖住了就等于用户看不清自己正在取哪个像素。
    public static func origin(cursor: CGPoint,
                              settings: Settings,
                              screenBounds: CGRect) -> CGPoint {
        let box = settings.boxSize
        let gap = settings.gap

        var x = cursor.x + gap
        if x + box.width > screenBounds.maxX {
            x = cursor.x - gap - box.width
        }
        x = min(max(screenBounds.minX + 4, x), screenBounds.maxX - box.width - 4)

        // Cocoa 的 y 向上：光标"下方"是更小的 y
        var y = cursor.y - gap - box.height
        if y < screenBounds.minY {
            y = cursor.y + gap
        }
        y = min(max(screenBounds.minY + 4, y), screenBounds.maxY - box.height - 4)

        return CGPoint(x: x, y: y)
    }
}

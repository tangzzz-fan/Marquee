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

/// 放大时的插值方式。
public enum MagnifierInterpolation: Equatable, Sendable {
    /// 最近邻：绝不混色，每个源像素都是一个硬边方块
    case nearest
    /// 平滑：斜线不再呈阶梯状
    case smooth

    /// 按倍数自动选：**低倍数看内容、高倍数看像素**。
    ///
    /// 阈值取 6 的道理是"每个源像素占几个点"：
    /// - 3~5 倍时一个源像素只有 1.5~2.5 点，最近邻的阶梯边就是用户说的"锯齿感"
    /// - 6 倍以上一个源像素 ≥ 3 点，格子已经清楚到能被当成"格子"来读，此时混色反而碍事
    ///
    /// 注意**色值准确性与此无关**：读数是从原图读的（`PixelSampling.color(of:at:)`），
    /// 不经过这张放大图。所以平滑只是好看，不会让取色变糊。
    public static func automatic(forZoom zoom: Double) -> MagnifierInterpolation {
        zoom >= 6 ? .nearest : .smooth
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

    /// 以 `center` 为中心裁一块 `side×side` 的方形区域，放大 `zoom` 倍。
    ///
    /// 插值方式由 `interpolation` 决定（见 `MagnifierInterpolation`）：
    /// 低倍数平滑、高倍数最近邻。**这里就是"放大"真正发生的地方** ——
    /// 视图那一步是 1:1 直通（`side × zoom` 像素画进 `side × zoom / scale` 点的盒子），
    /// 所以插值质量放在这里设才有意义。
    public static func magnified(_ image: CGImage,
                                centeredAt center: PixelCoordinate,
                                side: Int,
                                zoom: Int,
                                interpolation: MagnifierInterpolation) -> CGImage? {
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
        context.interpolationQuality = interpolation == .smooth ? .high : .none
        context.draw(patch, in: CGRect(x: 0, y: 0, width: scaledSide, height: scaledSide))
        return context.makeImage()
    }
}

/// 放大镜的尺寸与摆位。**纯几何**，可单测。
public struct MagnifierLayout: Equatable, Sendable {

    public struct Settings: Equatable, Sendable {
        /// 取样区域边长（**屏幕点**）。放大镜里看到的就是这么大一块地方。
        ///
        /// 这个数决定"能不能认出内容"：太小就只能看到半个字的一角。
        public var samplePoints: Double
        /// 放大倍数 = 盒子边长 ÷ 取样边长（**与屏幕 scale 无关**，是用户感知到的倍数）。
        ///
        /// 取整：`boxSide = samplePoints × zoom`，而非整数的 zoom 会让
        /// "放大后的图"与"盒子"差一点点，最近邻下就表现为格子大小不均。
        public var zoom: Double
        /// 放大镜与光标之间的间距（点）
        public var gap: Double

        /// 默认值（2026-10-01 按用户实测反馈调过一轮）。
        ///
        /// 初版是 `samplePoints 12 / zoom 8`：采样区只有 12 点（不到一个字的宽度），
        /// 2x 屏上每个源像素被画成 **4 点**见方 —— 用户看到的是"像素格子"，
        /// 而不是"放大的内容"。放大镜此时只能用来读色，没法用来认字/看图标。
        ///
        /// 现在：**40 点的取样区（≈ 三四个字宽）× 3 倍 = 120 点的盒子**。
        /// 内容可辨认，边缘仍能靠十字线与中心像素框对准。
        public init(samplePoints: Double = 40, zoom: Double = 3, gap: Double = 22) {
            self.samplePoints = samplePoints
            self.zoom = max(1, zoom.rounded())
            self.gap = gap
        }

        public static let `default` = Settings()

        /// 放大镜盒子的边长（点），**仅用于"没有屏幕信息"时的估算**。
        ///
        /// 真实摆位请走 `MagnifierLayout.boxSide(sampledSide:zoom:backingScale:)` ——
        /// 那个是由**实际采样边长**推出来的，保证放大图与盒子 1:1（不会再多一次重采样）。
        public var boxSide: Double { samplePoints * zoom }
        public var boxSize: CGSize { CGSize(width: boxSide, height: boxSide) }

        /// 该用哪种插值（低倍数平滑、高倍数最近邻，见 `MagnifierInterpolation`）
        public var interpolation: MagnifierInterpolation { .automatic(forZoom: zoom) }
    }

    /// 一次摆位所需的全部几何量。
    ///
    /// 打成一个包，是因为它们总是**一起**算出来的（都取决于"哪块屏 + 当前设置"），
    /// 拆成四个参数只会让调用点变长、也更容易传错顺序。
    public struct Placement: Equatable, Sendable {
        /// 盒子边长（点）。**必须**由 `boxSide(sampledSide:zoom:backingScale:)` 推出来
        public var boxSide: Double
        public var gap: Double
        /// 该屏的 backing scale，用来把落位对齐到设备像素
        public var backingScale: Double
        /// 该屏边界，与 cursor **同一坐标空间**（别一个 Cocoa 一个 Quartz）
        public var screenBounds: CGRect

        public init(boxSide: Double, gap: Double, backingScale: Double, screenBounds: CGRect) {
            self.boxSide = boxSide
            self.gap = gap
            self.backingScale = backingScale
            self.screenBounds = screenBounds
        }
    }

    /// 由**实际采样边长**推出盒子边长（点）。
    ///
    /// 不能直接用 `samplePoints × zoom`：采样边长是 `round(samplePoints × scale)`，
    /// 与 `samplePoints × scale` 差最多半像素，而放大图是 `side × zoom` **像素**。
    /// 两者错开时，视图那一步就会做一次亚像素重采样 ——
    /// 表现为"个别格子被拉宽、个别被吃掉一行"，比单纯的块状更难忍受。
    public static func boxSide(sampledSide: Int, zoom: Double, backingScale: Double) -> Double {
        guard backingScale > 0 else { return Double(sampledSide) * zoom }
        return Double(sampledSide) * zoom / backingScale
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
    ///
    /// 最后还有一步**对齐设备像素**：放大图与盒子是 1:1 的，但盒子落在半个像素上时，
    /// 这次绘制就退化成一次亚像素重采样 —— 平滑插值下整体发虚，
    /// 最近邻下则是个别格子被拉宽/吃掉一行。对齐之后才是纯粹的直通拷贝。
    public static func origin(cursor: CGPoint,
                              placement: Placement) -> CGPoint {
        let box = CGSize(width: placement.boxSide, height: placement.boxSide)
        let gap = placement.gap
        let bounds = placement.screenBounds

        var x = cursor.x + gap
        if x + box.width > bounds.maxX {
            x = cursor.x - gap - box.width
        }
        x = min(max(bounds.minX + 4, x), bounds.maxX - box.width - 4)

        // Cocoa 的 y 向上：光标"下方"是更小的 y
        var y = cursor.y - gap - box.height
        if y < bounds.minY {
            y = cursor.y + gap
        }
        y = min(max(bounds.minY + 4, y), bounds.maxY - box.height - 4)

        // 对齐到设备像素网格。夹取留了 4 点余量，所以这一步不会把盒子推出屏外。
        let scale = placement.backingScale > 0 ? placement.backingScale : 1
        return CGPoint(x: (x * scale).rounded() / scale,
                       y: (y * scale).rounded() / scale)
    }

    /// 盒子矩形（左上角 + 边长），Cocoa 全局坐标。
    public static func box(cursor: CGPoint, placement: Placement) -> CGRect {
        CGRect(origin: origin(cursor: cursor, placement: placement),
               size: CGSize(width: placement.boxSide, height: placement.boxSide))
    }
}

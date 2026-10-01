import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 打码：马赛克（像素化）与毛玻璃（高斯模糊）。
///
/// ## 为什么走 CoreImage
///
/// ticket 09 定下的结论：`CIPixellate` / `CIGaussianBlur` 跑全画布 **2.64 ms**，
/// 而手写 CG 像素化是 **15.96 ms**（差 6 倍）。不要手写 Metal kernel，
/// 也不要自己按块取平均 —— 那是把已经调好的实现重写一遍。
///
/// 用的是 **typed filter API**（`CIFilterBuiltins`）：`filter.scale = 12` 直接写，
/// 而不是 `setValue(12, forKey: kCIInputScaleKey)` —— 后者写错 key 只是静默不生效。
public enum RedactionFilter {

    /// 马赛克块边长的允许范围（像素）。太小等于没打码，太大整块变成色块。
    public static let mosaicRange: ClosedRange<CGFloat> = 4...80
    /// 高斯模糊半径的允许范围（像素）
    public static let blurRange: ClosedRange<CGFloat> = 2...80

    /// 两种打码共用一个"强度"数值（马赛克＝块边长、模糊＝半径），界面也就只有一排控件。
    public static func clampStrength(_ strength: CGFloat, for kind: AnnotationKind) -> CGFloat {
        guard strength.isFinite else {
            // NaN / 无穷：按该类型的最小值处理，而不是拿另一个类型的范围来套
            return kind == .blur ? blurRange.lowerBound : mosaicRange.lowerBound
        }
        switch kind {
        case .blur: return min(max(blurRange.lowerBound, strength), blurRange.upperBound)
        case .mosaic: return min(max(mosaicRange.lowerBound, strength), mosaicRange.upperBound)
        default: return strength
        }
    }

    /// 对一小片图像打码。返回 `nil` 表示这个类型不需要打码或滤镜失败。
    public static func apply(_ kind: AnnotationKind, to image: CGImage, strength: CGFloat) -> CGImage? {
        switch kind {
        case .mosaic:
            return pixelate(image, blockSize: clampStrength(strength, for: kind))
        case .blur:
            return gaussianBlur(image, radius: clampStrength(strength, for: kind))
        default:
            return nil
        }
    }

    // MARK: - 私有

    /// `CIContext` 建一次很贵（几十毫秒），按需建一次就一直用。
    /// 它本身是线程安全的，所以可以直接当共享常量。
    private static let sharedContext = CIContext()

    private static func pixelate(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let filter = CIFilter.pixellate()
        filter.inputImage = CIImage(cgImage: image)
        filter.scale = Float(blockSize)
        // 中心放在图心，块就与图对齐；不设的话块从原点起算，边缘会留半块
        filter.center = CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2)
        return render(filter.outputImage, like: image)
    }

    private static func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let filter = CIFilter.gaussianBlur()
        // 先钳住边缘再模糊：否则边缘会向外"漏"成透明，贴回原图就是一圈发白
        filter.inputImage = CIImage(cgImage: image).clampedToExtent()
        filter.radius = Float(radius)
        return render(filter.outputImage, like: image)
    }

    /// 把滤镜结果取回 `CGImage`，**尺寸与色彩空间都与输入一致**。
    ///
    /// `clampedToExtent` 与像素化都会改变 extent，所以必须裁回原本的区域；
    /// 色彩空间也显式传进去，否则 CI 会按自己的工作空间输出，
    /// 贴回 P3 截图时又要多一次转换（见 `AnnotationRasterizer` 的色彩空间注释）。
    private static func render(_ image: CIImage?, like input: CGImage) -> CGImage? {
        guard let image else { return nil }
        let extent = CGRect(x: 0, y: 0, width: input.width, height: input.height)
        return sharedContext.createCGImage(image.cropped(to: extent),
                                           from: extent,
                                           format: .RGBA8,
                                           colorSpace: input.colorSpace)
    }
}

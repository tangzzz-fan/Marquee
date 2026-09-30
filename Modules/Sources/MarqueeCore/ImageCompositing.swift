import CoreGraphics
import Foundation

/// 要画进输出图的一片。
public struct ImageSlice: @unchecked Sendable {
    /// `CGImage` 创建后不可变、跨线程只读安全，`@unchecked Sendable` 显式承担这一保证
    public let image: CGImage
    /// 落位（像素，**原点左上**，与 `SelectionSlice.targetPixelRect` 同一空间）
    public let target: CGRect

    public init(image: CGImage, target: CGRect) {
        self.image = image
        self.target = target
    }
}

/// 把多片图像拼成一张。
public enum ImageCompositing {

    /// 逐片绘制到一张新图上。
    ///
    /// 两处容易静默出错的细节：
    /// 1. `CGContext` 的原点在**左下**，而我们算出来的 `target` 原点在左上 —— 必须翻 y。
    ///    不翻不会崩，只会让上下颠倒，且在单屏单片的常见路径里看不出来。
    /// 2. 单切片铺满时**直接返回原图**，不做重绘：避免无谓的色彩空间转换与重采样，
    ///    这是最常见的情形（单屏选区），不该为跨屏能力付质量代价。
    public static func compose(outputSize: CGSize, slices: [ImageSlice]) -> CGImage? {
        let width = Int(outputSize.width.rounded())
        let height = Int(outputSize.height.rounded())
        guard width > 0, height > 0, !slices.isEmpty else { return nil }

        if slices.count == 1, let only = slices.first,
           only.target.minX == 0, only.target.minY == 0,
           only.image.width == width, only.image.height == height {
            return only.image
        }

        // 用第一片的色彩空间，而不是硬编码 sRGB：截图应当保留来源屏的色彩空间特征
        let colorSpace = slices.first?.image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high

        for slice in slices {
            let flippedY = CGFloat(height) - slice.target.maxY
            context.draw(slice.image,
                         in: CGRect(x: slice.target.minX,
                                    y: flippedY,
                                    width: slice.target.width,
                                    height: slice.target.height))
        }
        return context.makeImage()
    }
}

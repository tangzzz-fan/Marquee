import CoreGraphics
import Foundation

/// 把文档栅格化成一张图：先裁出可见区域，再按对象描边。
///
/// 交互绘制走 SwiftUI Canvas（`MarqueeEditor`）。这里是导出路径，
/// `Esc` 复制到剪贴板之前必须走它，不能把对象信息留在剪贴板里。
public enum AnnotationRasterizer {

    public static func image(document: AnnotationDocument, source: CGImage) -> CGImage? {
        let crop = document.cropRect.standardized.integral
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        guard let cropped = source.cropping(to: crop) else { return nil }

        let width = Int(crop.width)
        let height = Int(crop.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // 翻成左上原点、y 向下，和标注坐标一致。图像用 CGImage 自己的方向画进去即可。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        context.translateBy(x: -crop.minX, y: -crop.minY)

        let ordered = document.annotations.enumerated().sorted { lhs, rhs in
            if lhs.element.zIndex != rhs.element.zIndex {
                return lhs.element.zIndex < rhs.element.zIndex
            }
            return lhs.offset < rhs.offset
        }
        for (_, annotation) in ordered {
            context.setStrokeColor(annotation.style.stroke.cgColor(in: colorSpace))
            context.setLineWidth(annotation.style.lineWidth)
            let box = annotation.frame.standardized
            switch annotation.kind {
            case .rectangle:
                context.stroke(box)
            case .ellipse:
                context.strokeEllipse(in: box)
            }
        }

        return context.makeImage()
    }
}

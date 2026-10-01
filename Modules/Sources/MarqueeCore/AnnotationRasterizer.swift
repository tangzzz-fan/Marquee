import CoreGraphics
import Foundation

/// 把文档栅格化成一张图：先裁出可见区域，再按对象描边。
///
/// 交互绘制走 SwiftUI Canvas（`MarqueeEditor`）。这里是导出路径，
/// `Esc` 复制到剪贴板之前必须走它，不能把对象信息留在剪贴板里。
///
/// ## ⚠️ 底图必须在翻转 CTM **之前**画（实测，2026-10-01）
///
/// 原来的写法是先翻成"左上原点、y 向下"再画底图，结果是**底图整个上下颠倒**，
/// 而标注位置是对的 —— 导出的成品是一张倒着的截图配正着的框。
/// 之所以一直没被发现：当时的断言用的是纯色底图，翻转看不出来。
///
/// 原因：翻转后 `draw(image, in: rect)` 仍把图像顶行放在 `rect.maxY`，
/// 而翻转后 `rect.maxY` 已经是视觉上的**下**边。所以底图要先在默认坐标系里画，
/// 之后再把 CTM 翻成左上原点，专门给标注的坐标用。
/// （同一个坑在 `ScrollStitchRenderer` 里也踩到过，那里的注释有对照实验数据。）
public enum AnnotationRasterizer {

    public static func image(document: AnnotationDocument, source: CGImage) -> CGImage? {
        let crop = document.cropRect.standardized.integral
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        guard let cropped = source.cropping(to: crop) else { return nil }

        let width = Int(crop.width)
        let height = Int(crop.height)
        // 保留来源色彩空间：**截图是 P3 时不该在导出这一步被悄悄转成 sRGB** ——
        // 超出 sRGB 色域的颜色会被裁掉，成品与屏幕上看到的就不是一回事了。
        // 建不出 8 位上下文的空间（线性 / 扩展空间等）退回 sRGB，不让整张图导不出来。
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = makeContext(space: cropped.colorSpace, width: width, height: height)
                ?? makeContext(space: fallback, width: width, height: height) else { return nil }
        // 标注颜色按**上下文实际拿到的**空间转换（见 `AnnotationColor.cgColor(in:)`）
        let colorSpace = context.colorSpace ?? fallback

        // ① 底图：默认 y 向上坐标系，rect 恰好铺满（画布尺寸 == 裁剪尺寸）
        //    上下文与底图同色彩空间，所以这一步是纯拷贝，不做任何转换。
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))

        // ② 翻成左上原点、y 向下，这样标注坐标（原图像素、原点左上）可以直接用
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
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
            let color = annotation.style.stroke.cgColor(in: colorSpace)
            let box = annotation.frame.standardized
            switch annotation.kind {
            case .rectangle:
                context.stroke(box)
            case .ellipse:
                context.strokeEllipse(in: box)
            case .arrow:
                drawArrow(annotation, color: color, in: context)
            case .pen:
                drawPen(annotation, in: context)
            case .text:
                AnnotationText.draw(annotation.text,
                                    fontSize: annotation.style.fontSize,
                                    color: color,
                                    at: box.origin,
                                    in: context)
            }
        }

        return context.makeImage()
    }

    /// 按给定色彩空间建一个 8 位 ARGB 上下文。空间不合适（线性 / 16 位等）时返回 nil，
    /// 由调用方回退 —— 这比"直接崩掉或静默给出错色的图"好。
    private static func makeContext(space: CGColorSpace?,
                                    width: Int,
                                    height: Int) -> CGContext? {
        guard let space else { return nil }
        return CGContext(data: nil,
                         width: width,
                         height: height,
                         bitsPerComponent: 8,
                         bytesPerRow: 0,
                         space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 箭头 = 线段 + 实心三角头部。
    private static func drawArrow(_ annotation: Annotation, color: CGColor, in context: CGContext) {
        guard annotation.path.count >= 2 else { return }
        let start = annotation.path[0]
        let end = annotation.path[1]

        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let head = AnnotationGeometry.arrowHead(from: start,
                                                to: end,
                                                lineWidth: annotation.style.lineWidth)
        guard head.count == 3 else { return }
        context.setFillColor(color)
        context.move(to: head[0])
        context.addLine(to: head[1])
        context.addLine(to: head[2])
        context.closePath()
        context.fillPath()
    }

    /// 画笔 = 圆头圆角的折线。圆角不能省：默认的斜接会在急弯处戳出尖刺。
    private static func drawPen(_ annotation: Annotation, in context: CGContext) {
        guard annotation.path.count >= 2 else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: annotation.path[0])
        for point in annotation.path.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }
}

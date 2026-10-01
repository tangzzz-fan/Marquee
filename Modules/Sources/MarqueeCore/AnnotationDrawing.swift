import CoreGraphics

/// 把标注画到 `CGContext` 上。
///
/// ## 为什么单独抽出来
///
/// **覆盖层与导出必须画得一模一样**。覆盖层的绘制是 CoreGraphics，
/// 导出（`AnnotationRasterizer`）也是 CoreGraphics —— 所以能共用同一份代码，
/// 于是"覆盖层里看到的"与"最终导出的"天然一致。
///
/// 反面做法（覆盖层用 `NSBezierPath` 自己再画一遍）很诱人，但会让线宽、颜色空间、
/// 文字基线全部漂移，而且**只在某些图上看得出来** —— 纯色图与对称图都是盲的，
/// 等发现时已经是"导出跟预览不一样"这种最难查的一类反馈。
/// （同一个决策在 ticket 08：编辑器与导出共用 `AnnotationText`。）
///
/// ## 坐标系
///
/// 调用方负责把 CTM 设成**原点左上、y 向下**。`Annotation` 的坐标就是这个约定。
public enum AnnotationDrawing {

    /// 画一批标注。
    ///
    /// - Parameter source: 打码 / 模糊要用的底图。传 `nil` 时这两类会被跳过
    ///   （宁可少画，也不要画成一块黑 —— 那看起来像"打码成功了"，而实际导出的是另一回事）。
    /// - Parameter sourceScale: **底图每 1 个标注单位对应多少底图像素**。
    ///   导出路径上恒为 1（标注早就换成像素了）；覆盖层的预览是屏幕倍率
    ///   （底图来自冻结的整屏像素，而标注坐标是点）。
    ///   ⚠️ 传错不会崩：马赛克格子会**大一倍或小一半**，而"格子大小不对"看起来
    ///   只是"强度调得不一样"，很难联想到是倍率。
    public static func draw(_ annotations: [Annotation],
                            in context: CGContext,
                            colorSpace: CGColorSpace,
                            source: CGImage? = nil,
                            sourceScale: CGFloat = 1) {
        for annotation in ordered(annotations) {
            draw(annotation, in: context, colorSpace: colorSpace,
                 source: source, sourceScale: sourceScale)
        }
    }

    /// 画一个标注。
    public static func draw(_ annotation: Annotation,
                            in context: CGContext,
                            colorSpace: CGColorSpace,
                            source: CGImage? = nil,
                            sourceScale: CGFloat = 1) {
        let color = annotation.style.stroke.cgColor(in: colorSpace)
        context.setStrokeColor(color)
        context.setLineWidth(annotation.style.lineWidth)
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
        case .mosaic, .blur:
            guard let source else { return }
            drawRedaction(annotation, source: source, sourceScale: sourceScale, in: context)
        }
    }

    /// 绘制顺序：`zIndex` 小的先画；相同则数组里靠前的先画（后者盖在上面）。
    ///
    /// Swift 的 `sorted` **不稳定**，所以相同 `zIndex` 时必须用原下标决出先后 ——
    /// 否则两个同层的标注谁压谁是不确定的，重跑一次可能换个样子。
    public static func ordered(_ annotations: [Annotation]) -> [Annotation] {
        annotations.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.zIndex != rhs.element.zIndex {
                    return lhs.element.zIndex < rhs.element.zIndex
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - 各类图形

    /// 箭头 = 线段 + 实心三角头部。
    static func drawArrow(_ annotation: Annotation, color: CGColor, in context: CGContext) {
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
    static func drawPen(_ annotation: Annotation, in context: CGContext) {
        guard annotation.path.count >= 2 else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: annotation.path[0])
        for point in annotation.path.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    /// 打码：把框内那一块**源图**抠出来做滤镜，再贴回去。
    ///
    /// ⚠️ 这里必须**局部反翻一次 CTM**。当前 CTM 已经是"左上原点、y 向下"，
    /// 而 `draw(image, in:)` 在 y 向下的上下文里会把图像**上下颠倒**地放进去
    /// （它的顶行仍然落在 `rect.maxY`，而那已是视觉上的下边）。
    /// 马赛克因为细节被抹掉了未必看得出来，**模糊会很明显** —— 有一条用
    /// "上黑下白"底图的回归专门盯它。
    static func drawRedaction(_ annotation: Annotation,
                              source: CGImage,
                              sourceScale: CGFloat,
                              in context: CGContext) {
        let scale = sourceScale > 0 ? sourceScale : 1
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        // 取整：半个像素的区域会让马赛克的格子与整幅的像素网格错开。
        // 取整要在**换算成底图像素之后**做，否则 1x 底图上会差半个像素。
        let pixelRegion = annotation.frame.standardized
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .integral
            .intersection(bounds)
        guard pixelRegion.width >= 1, pixelRegion.height >= 1,
              let patch = source.cropping(to: pixelRegion) else { return }

        // 画回上下文时用**标注单位**（CTM 是标注单位），不是底图像素
        let region = pixelRegion.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))

        // ⚠️ `effectStrength` 与标注同单位，而 `RedactionFilter` 按**底图像素**工作 ——
        // 所以这里要乘 `sourceScale`。漏掉它的话预览里的格子会比导出的小一半
        // （2x 屏），而"格子看着小了点"只会被当成强度没调对。
        guard let processed = RedactionFilter.apply(annotation.kind,
                                                    to: patch,
                                                    strength: annotation.style.effectStrength * scale) else {
            // 打码失败就**遮死**：宁可糊掉一块，也绝不能把敏感内容原样导出去
            let colorSpace = context.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!)
            context.fill(region)
            return
        }

        context.saveGState()
        context.translateBy(x: region.minX, y: region.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(processed, in: CGRect(origin: .zero, size: region.size))
        context.restoreGState()
    }
}

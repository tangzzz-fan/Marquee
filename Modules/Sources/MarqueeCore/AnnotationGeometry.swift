import CoreGraphics
import Foundation

/// 箭头与画笔的几何。**纯函数、无状态**，可完整单测。
///
/// 坐标一律是**原图像素**（原点左上、y 向下），与 `Annotation` 一致。
public enum AnnotationGeometry {

    /// 点到线段的最短距离。
    ///
    /// 命中测试要用它而不是"点到包围盒"：箭头是一条斜线，
    /// 用包围盒会让整块空白区域都可点中，用户点空白处却选中了箭头。
    public static func distance(from point: CGPoint,
                                toSegment start: CGPoint,
                                end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        // 投影到线段上并夹住两端（夹住才是"线段"，否则是"直线"）
        var t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        t = min(1, max(0, t))
        let projected = CGPoint(x: start.x + t * dx, y: start.y + dy * t)
        return hypot(point.x - projected.x, point.y - projected.y)
    }

    /// 点到折线的最短距离。空数组视为"无穷远"。
    public static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<points.count {
            let candidate = distance(from: point, toSegment: points[index - 1], end: points[index])
            if candidate < best { best = candidate }
        }
        return best
    }

    /// 箭头头部的长度（跟着线宽走，粗箭头要有大头）。
    public static func arrowHeadLength(forLineWidth lineWidth: CGFloat) -> CGFloat {
        max(10, lineWidth * 3.5)
    }

    /// 箭头头部的三个顶点：`[尖端, 一侧翼, 另一侧翼]`。
    ///
    /// 起点终点重合（拖了一下但没拖动）时返回空数组：
    /// 归一化零向量会得到 NaN，画出来是"什么都没画但日志也不报错"，不如明确不画。
    public static func arrowHead(from start: CGPoint,
                                 to end: CGPoint,
                                 lineWidth: CGFloat) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1e-6 else { return [] }

        let ux = dx / length
        let uy = dy / length
        let headLength = min(arrowHeadLength(forLineWidth: lineWidth), length)
        // 30° 左右的张角：够醒目，又不至于盖住箭头指向的目标
        let halfWidth = headLength * 0.55

        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        // 左法线（y 向下坐标系里 (−dy, dx) 在视觉上是逆时针一侧）
        let normal = CGPoint(x: -uy, y: ux)
        return [end,
                CGPoint(x: base.x + normal.x * halfWidth, y: base.y + normal.y * halfWidth),
                CGPoint(x: base.x - normal.x * halfWidth, y: base.y - normal.y * halfWidth)]
    }

    /// 折线（或箭头本体）的包围盒。
    ///
    /// **含半个线宽**（粗线的外沿会超出中心线）与箭头头部 —— 否则
    /// 控制点会落在图形里面、导出时头部还可能被裁掉。
    public static func frame(forPath points: [CGPoint],
                             lineWidth: CGFloat,
                             headFrom start: CGPoint? = nil,
                             headTo end: CGPoint? = nil) -> CGRect {
        var all = points
        if let start, let end {
            all.append(contentsOf: arrowHead(from: start, to: end, lineWidth: lineWidth))
        }
        guard let first = all.first else { return .zero }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in all.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let slop = max(1, lineWidth / 2)
        return CGRect(x: minX - slop, y: minY - slop,
                      width: (maxX - minX) + slop * 2,
                      height: (maxY - minY) + slop * 2)
    }

    /// 把一串点从 `from` 框等比映射到 `to` 框（拖控制点时用）。
    ///
    /// 框退化成零宽/零高时（比如把箭头拖成一条竖线）不能除零：
    /// 那个轴上直接跟随平移，不做缩放。
    public static func scale(points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        let source = old.standardized
        let target = new.standardized
        let scaleX = source.width > 1e-6 ? target.width / source.width : 1
        let scaleY = source.height > 1e-6 ? target.height / source.height : 1
        return points.map { point in
            CGPoint(x: target.minX + (point.x - source.minX) * scaleX,
                    y: target.minY + (point.y - source.minY) * scaleY)
        }
    }
}

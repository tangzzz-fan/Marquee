import CoreGraphics

/// 选区几何工具。
///
/// 覆盖层拖拽时，锚点与当前点的相对位置有四种情况（往哪个方向拖都有可能），
/// 需要归一化成「左上角 + 正宽高」的矩形；跨屏拖拽还要按屏幕裁剪。
/// 这些都是纯计算，放在 Core 里单测覆盖，覆盖层只负责把鼠标坐标喂进来。
public enum Selection {

    /// 由拖拽锚点与当前点归一化出矩形，保证宽高非负。
    public static func rect(anchor: CGPoint, current: CGPoint) -> CGRect {
        CGRect(x: min(anchor.x, current.x),
               y: min(anchor.y, current.y),
               width: abs(current.x - anchor.x),
               height: abs(current.y - anchor.y))
    }

    /// 吸附到整数点。
    ///
    /// 选区最终会换算成像素，保留小数会让「看上去 100 点宽」在 2x 屏上产生 ±1 像素的抖动，
    /// 也会让相同操作的输出尺寸不稳定。因此落点前统一吸附到整点。
    public static func snapped(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded()
        let minY = rect.minY.rounded()
        let maxX = rect.maxX.rounded()
        let maxY = rect.maxY.rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 把矩形裁剪到给定边界内；完全无交集时返回 nil。
    ///
    /// 注意 `CGRect.intersection` 在无交集时返回 `.null`（一个无限大的负矩形），
    /// 直接使用会得到难以察觉的错误结果，所以这里显式判定。
    public static func clipped(_ rect: CGRect, to bounds: CGRect) -> CGRect? {
        guard !rect.isNull, !bounds.isNull else { return nil }
        guard rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        guard rect.intersects(bounds) else { return nil }
        let result = rect.intersection(bounds)
        guard !result.isNull, result.width > 0, result.height > 0 else { return nil }
        return result
    }
}

import CoreGraphics

/// 覆盖层里**就地画**的标注，连同它所在坐标空间的尺寸。
///
/// 坐标是"选区局部点"（原点 = 选区左上角，y 向下），尺寸是选区在屏幕上的**点**大小。
/// 到像素的换算只在栅格化那一刻做一次 —— 那时才知道真正的输出像素尺寸
/// （跨屏选区时，输出尺寸由参与屏里最大的倍率决定，不是逐屏一致的）。
public struct InlineAnnotations: Equatable, Sendable {

    public var annotations: [Annotation]
    /// 标注坐标空间的尺寸（点），即选区 / 窗口在屏幕上的大小。
    public var pointSize: CGSize

    public init(annotations: [Annotation] = [], pointSize: CGSize) {
        self.annotations = annotations
        self.pointSize = pointSize
    }

    public var isEmpty: Bool { annotations.isEmpty }

    /// 换算到实际输出像素尺寸。
    ///
    /// 倍率取**宽度比**：选区的点尺寸与像素尺寸宽高比必然一致（像素尺寸就是点尺寸乘倍率），
    /// 不一致说明上游算错了。用单一倍率能保证"线宽"这种只有一个数的属性有确定的值 ——
    /// 而线宽比位置更容易被看出不对（位置差半个像素看不出来，线粗细差一档一眼就看出来）。
    ///
    /// 点尺寸为 0（理论上不该出现）时返回原样，宁可画得偏小也不要除以 0。
    public func scaled(toPixelSize pixelSize: CGSize) -> [Annotation] {
        guard pointSize.width > 0, pointSize.height > 0 else { return annotations }
        let factor = pixelSize.width / pointSize.width
        guard factor > 0, factor != 1 else { return annotations }
        return annotations.map { $0.scaled(by: factor) }
    }
}

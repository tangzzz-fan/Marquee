import CoreGraphics

/// 标注可选的描边颜色与线宽档位。
///
/// ## 为什么放 Core
///
/// 覆盖层的浮动工具栏与编辑器窗口是**两套**绘制代码（一个走 AppKit/CG、一个走 SwiftUI），
/// 但它们给用户看、给用户挑的必须是同一组颜色。各写一份迟早分叉，
/// 而分叉的表现是"在覆盖层里挑的橙，进编辑器变成了另一个橙" ——
/// 没人会往"两份常量"上面想，只会觉得颜色"自己变了"。
public enum AnnotationPalette {

    /// 描边颜色。顺序即工具条上的顺序：先红（最常用），白在最后。
    ///
    /// 没有纯黑：覆盖层的工具条本身是深色的，纯黑色块在上面几乎看不见；
    /// 而深色截图上用黑色描边同样看不见。白色已经覆盖了"深底"那一档。
    public static let colors: [AnnotationColor] = [
        .red,
        AnnotationColor(red: 1, green: 0.58, blue: 0),
        AnnotationColor(red: 1, green: 0.84, blue: 0.1),
        AnnotationColor(red: 0.2, green: 0.78, blue: 0.35),
        AnnotationColor(red: 0.05, green: 0.48, blue: 1),
        AnnotationColor(red: 1, green: 1, blue: 1),
    ]

    /// 线宽档位（点）。两档之间要一眼看得出来 —— 2 / 4 / 8 之间是翻倍关系。
    public static let lineWidths: [CGFloat] = [2, 4, 8]

    /// 覆盖层里打码强度的三档（**点**）。
    ///
    /// ⚠️ 与编辑器那三档**不是一回事**：编辑器里的强度单位是**原图像素**，
    /// 而覆盖层里所有长度都是"看起来多大"的**点** —— 同一个数字在 2x 屏上差一倍。
    /// 所以另立一组，而不是复用。
    ///
    /// 数值按"能不能盖住字"定：14 点的汉字要让格子约到 1/4 个字宽才认不出来，
    /// 也就是 4 点上下（2x 屏上是 8 设备像素）。所以这三档偏小是**故意的**。
    public static let overlayRedactionStrengths: [CGFloat] = [4, 8, 16]

    /// 覆盖层里打码强度的默认档（上面那一组的中间一个）。
    public static var defaultRedactionStrength: CGFloat { overlayRedactionStrengths[1] }

    /// 默认描边色。与 `AnnotationStyle.default` 保持一致。
    public static var defaultColor: AnnotationColor { .red }

    /// 默认线宽。
    public static var defaultLineWidth: CGFloat { 4 }

    /// 取最接近 `value` 的档位下标（`AnnotationStyle` 里存的线宽可能来自别处）。
    public static func lineWidthIndex(nearest value: CGFloat) -> Int {
        var best = 0
        for (index, candidate) in lineWidths.enumerated()
        where abs(candidate - value) < abs(lineWidths[best] - value) {
            best = index
        }
        return best
    }
}

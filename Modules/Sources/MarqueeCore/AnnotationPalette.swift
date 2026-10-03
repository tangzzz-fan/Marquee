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

    /// 覆盖层里的线宽档位（**点**）。两档之间要一眼看得出来 —— 2 / 4 / 8 之间是翻倍关系。
    ///
    /// ⚠️ 名字里的 `overlay` 是 2026-10-03 补上的：原先叫 `lineWidths`，
    /// 而它其实**只属于覆盖层**。编辑器里那三档是原图像素（4 / 8 / 16），
    /// 两组数字刻意不同 —— 同一个数字在 2x 屏上差一倍。
    /// 名字看着像共用的，迟早会有人把编辑器也接过来（那正是设计稿 §08 要防的）。
    public static let overlayLineWidths: [CGFloat] = [2, 4, 8]

    /// 覆盖层里打码强度的三档（**点**）。
    ///
    /// ⚠️ 与编辑器那三档**不是一回事**：编辑器里的强度单位是**原图像素**，
    /// 而覆盖层里所有长度都是"看起来多大"的**点** —— 同一个数字在 2x 屏上差一倍。
    /// 所以另立一组，而不是复用。
    ///
    /// 数值按"能不能盖住字"定：14 点的汉字要让格子约到 1/4 个字宽才认不出来，
    /// 也就是 4 点上下（2x 屏上是 8 设备像素）。所以这三档偏小是**故意的**。
    public static let overlayRedactionStrengths: [CGFloat] = [4, 8, 16]

    /// 覆盖层里字号的三档（**点**）。
    ///
    /// 与打码强度同理：编辑器里字号是**原图像素**，覆盖层里是**点**，
    /// 2x 屏上同一个数字差一倍 —— 所以另立一组，而不是复用 `AnnotationStyle.default` 的 36。
    ///
    /// 数值按"截图上看得清"定：18 点相当于正文注释，44 点相当于给整张图盖个头。
    public static let overlayFontSizes: [CGFloat] = [18, 28, 44]

    /// 覆盖层里字号的默认档（中间一个）。
    public static var defaultOverlayFontSize: CGFloat { overlayFontSizes[1] }

    /// 覆盖层里打码强度的默认档（`overlayRedactionStrengths` 的中间一个）。
    public static var defaultRedactionStrength: CGFloat { overlayRedactionStrengths[1] }

    /// 三档尺寸的**格数**。
    ///
    /// 三组值（线宽 / 打码强度 / 字号）的**含义**不同，但格数相同 ——
    /// 工具条上那一排永远只有三格，切工具时换的是"这三格代表什么"（`OverlaySizeMeaning`）。
    /// 写死 3 会让加第四档时漏改；从实际数据取，加档位时自动跟上。
    public static var overlaySizeSlotCount: Int { OverlaySizeMeaning.lineWidth.values.count }

    /// 表情贴纸面板里的常用表情。
    ///
    /// 挑的是"标注截图时真会用到的"：对错、指向、强调、完成度。
    /// 不做完整 emoji 选择器（那是系统「表情与符号」面板的活），
    /// 覆盖层里要的是"一秒点中就落下去"。
    public static let emojis: [String] = [
        "😀", "😂", "🥲", "😍", "🤔", "😱",
        "👍", "👎", "👏", "🙏", "💪", "🤝",
        "❤️", "🔥", "✨", "⭐️", "💡", "⚠️",
        "✅", "❌", "❓", "❗️", "🎯", "📌",
    ]

    // MARK: - 编辑器那三组（**原图像素**，与覆盖层刻意不是同一组数）

    /// 编辑器里的线宽档位（**原图像素**）。
    ///
    /// 三档仍取翻倍关系（4 / 8 / 16），与覆盖层同构 ——
    /// 变的只是**单位**：那边描述"屏幕上的笔"，这边描述"图里的笔"。
    /// 2x 屏上同一个视觉粗细，在覆盖层里是 4 点、在编辑器里就是 8 px。
    public static let editorLineWidths: [CGFloat] = [4, 8, 16]

    /// 编辑器里的打码强度（**原图像素**）：马赛克＝格边长、模糊＝半径。
    ///
    /// 数值按"能不能盖住字"定：一张 1440 px 宽的长图里，汉字大约 24–32 px 高，
    /// 要让格子密到认不出来，格边长得在 1/4 字高上下 —— 也就是 8 px 起。
    public static let editorRedactionStrengths: [CGFloat] = [8, 16, 32]

    /// 编辑器里的字号（**原图像素**）。
    ///
    /// 长图动辄 1440 px 宽，而字号是**按图**定的：36 px 相当于正文注释，
    /// 88 px 相当于给整张图盖个头。覆盖层那三档（18 / 28 / 44 点）在编辑器里
    /// 会显得像蚂蚁 —— 这也是"两组不能共用"最直观的证据。
    public static let editorFontSizes: [CGFloat] = [36, 56, 88]

    /// 编辑器里的默认档（都是**中间那一档**）。
    ///
    /// ⚠️ 它们**必须落在上面那三组里**：不落进去的话，一进编辑器三档芯片全不高亮 ——
    /// 用户看到的是"当前尺寸未知"，而那个状态在界面上长得像"坏了"。
    /// 这一条由 `AnnotationSizeScaleTests` 对**两套**（覆盖层 / 编辑器）一起钉住。
    public static var defaultEditorLineWidth: CGFloat { editorLineWidths[1] }
    public static var defaultEditorRedactionStrength: CGFloat { editorRedactionStrengths[1] }
    public static var defaultEditorFontSize: CGFloat { editorFontSizes[1] }

    /// 编辑器的默认样式。宿主建会话时用它，而不是 `AnnotationStyle.default` ——
    /// 后者那四个数是**覆盖层的**（线宽 4 点、字号 36 点、打码 12 点）。
    public static var editorDefaultStyle: AnnotationStyle {
        AnnotationStyle(stroke: defaultColor,
                        lineWidth: defaultEditorLineWidth,
                        fontSize: defaultEditorFontSize,
                        effectStrength: defaultEditorRedactionStrength)
    }

    /// 默认描边色。与 `AnnotationStyle.default` 保持一致。
    public static var defaultColor: AnnotationColor { .red }

    /// 默认线宽。
    public static var defaultLineWidth: CGFloat { 4 }

    /// 取最接近 `value` 的档位下标（`AnnotationStyle` 里存的线宽可能来自别处）。
    public static func lineWidthIndex(nearest value: CGFloat) -> Int {
        var best = 0
        for (index, candidate) in overlayLineWidths.enumerated()
        where abs(candidate - value) < abs(overlayLineWidths[best] - value) {
            best = index
        }
        return best
    }
}

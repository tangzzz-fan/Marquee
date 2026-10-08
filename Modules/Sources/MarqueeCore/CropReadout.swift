import CoreGraphics
import Foundation

/// 编辑器里那台**裁切读数框**：拖保留框时实时报"裁完是多大"。
///
/// ## 它是一层"确认"，而不是一个提示
///
/// 裁切是**画布级的破坏性操作**：它改的是画布本身，不是加一个对象。
/// 设计稿的结论是"不设二次确认"（那会造出整个产品唯一的模态，与"标注可反复改"
/// 的核心手感正好相反）—— 代价由这台读数框来付：
/// **还不等按 `⏎`，用户已经看到裁完会小多少**，于是"确认"这一步在拖的时候就完成了。
///
/// ## 为什么几何要进 Core
///
/// 它的两个失败长相都是"不崩不报错"：
/// ① **压住保留框** —— 它说的正是"框里剩多少"，压住框就是压住证据；
/// ② **跑出画布** —— 那等于这条信息根本不存在。
/// 两者都只能靠算，所以算在 Core、钉在测试里。
///
/// ⚠️ 与覆盖层那个读数框**是同一件东西**（稿子原话「读数框逐字 ④」）：
/// 尺寸、行阶全部取 `OverlayReadout`，两处各写一个数的话，
/// "同一块框换内容"这条前提会在某一次改动里悄悄失效。
public enum CropReadout {

    /// 框的**最小**尺寸。与覆盖层那个**同一个来源**。
    ///
    /// ⚠️ 是"最小"不是"固定"：`1440 × 2000` 这种四位数已经贴到 132 的边
    /// （实测中文 111.3 / 内宽 116），而长截图动辄 `1440 × 12000` ——
    /// 写死宽度会让最下面那几位数字被**静默裁掉**，而那正好是"裁完到底多大"这个问题的答案。
    /// 所以框按内容长出去（`size(textWidth:)`），高度仍是设计稿的 44（两行的高度不变）。
    public static var minimumSize: CGSize { OverlayReadout.minimumSize }

    /// 第一行（结果）的字号。
    public static var primaryFontSize: CGFloat { OverlayReadout.primaryFontSize }
    /// 第二行（对照）的字号。
    public static var secondaryFontSize: CGFloat { OverlayReadout.secondaryFontSize }

    /// 与保留框之间让开的距离。
    ///
    /// 取 8：比覆盖层工具条贴选区那 10 略紧一档 —— 编辑器里框线是 1.5 点白芯 + 握把 12 见方，
    /// 8 点已经能把读数框从握把上让开，再远就与框失去"这是一组"的观感。
    public static let gap: CGFloat = 8

    /// 两行文案。第一行是**裁完的原图像素**，第二行是原图尺寸。
    public struct Lines: Equatable, Sendable {
        public let headline: String
        public let detail: String
    }

    /// 框该多大：**至少**设计稿那 132 × 44，内容更长就长出去。
    ///
    /// 由调用方把两行文字**量出来的宽度**传进来（字体是平台的事，Core 不该知道字体）。
    public static func size(textWidth: CGFloat) -> CGSize {
        CGSize(width: max(minimumSize.width, ceil(textWidth) + OverlayReadout.textPadding.width * 2),
               height: minimumSize.height)
    }

    /// 读数框该落在哪（与保留框同为**视图坐标**，原点左上）。
    ///
    /// 规则三条，按优先级：
    /// 1. **跟框的右下外侧** —— 框里是用户正在看的内容，读数框不该压在它上面；
    /// 2. 右下放不下就**翻到另一侧**（框的左上外侧），而不是往回缩 ——
    ///    缩回来正好压住框的右下角，那里有握把；
    /// 3. 最后**夹进画布**。这一条优先级最高：出画布等于这条信息不存在。
    ///    极端情况（框大到与画布同宽同高）下重叠无法避免 —— 那时它仍是可读的，
    ///    而它**不可点**（视图层 `allowsHitTesting(false)`），所以不会挡住拖拽。
    ///
    /// - Parameter size: 框的实际大小。默认取最小尺寸；调用方量过文字之后传 `size(textWidth:)`。
    public static func frame(cropFrame: CGRect,
                             canvas: CGSize,
                             size: CGSize = CropReadout.minimumSize) -> CGRect {
        var x = cropFrame.maxX + gap
        var y = cropFrame.maxY + gap

        if x + size.width > canvas.width {
            x = cropFrame.minX - gap - size.width
        }
        if y + size.height > canvas.height {
            y = cropFrame.minY - gap - size.height
        }

        x = min(max(0, x), max(0, canvas.width - size.width))
        y = min(max(0, y), max(0, canvas.height - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// 两行字。
    ///
    /// - Parameter crop: **裁完之后**的尺寸（原图像素）。
    /// - Parameter original: 原图尺寸（原图像素）。它不随裁切变 ——
    ///   这正是第二行的意义：告诉用户"你正在从一张多大的图里切"。
    public static func lines(crop: CGSize, original: CGSize) -> Lines {
        // ⚠️ 尺寸先拼成字符串再进 `L10n.t`：`String(localized:)` 的整数插值会按语言
        // 加千位分隔符，而分辨率是**标识**不是计数 —— `1,440 px` 不是我们想说的事。
        Lines(headline: L10n.t("\(dimensions(crop)) px"),
              detail: L10n.t("原图 \(dimensions(original)) px"))
    }

    private static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}

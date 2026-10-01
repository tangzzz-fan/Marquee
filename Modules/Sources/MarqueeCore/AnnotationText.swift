import CoreGraphics
import CoreText
import Foundation

/// 文字的测量与绘制。
///
/// ## 为什么用 CoreText 而不是各画各的
///
/// 编辑器（SwiftUI Canvas）与导出（`AnnotationRasterizer`）如果各用一套文字绘制，
/// 就会出现"编辑器里刚好放得下、导出后被裁掉半个字"这种事 —— 而框的大小是按
/// **测量结果**算出来的，两边测出来的尺寸必须完全一致。
/// 所以两边都调这里的 `measure` 与 `draw`，字体也只取一处（系统 UI 字体）。
///
/// 坐标一律**原图像素、原点左上、y 向下**（与 `Annotation` 一致）。
public enum AnnotationText {

    /// 系统 UI 字体。Core 里没有 AppKit，走 CoreText 的 UI 字体入口。
    public static func font(size: CGFloat) -> CTFont {
        let clamped = max(1, size)
        if let font = CTFontCreateUIFontForLanguage(.system, clamped, nil) {
            return font
        }
        // 兜底：取不到 UI 字体也不能让标注画不出来
        return CTFontCreateWithName("Helvetica" as CFString, clamped, nil)
    }

    /// 行高（升部 + 降部）。空文本也要有一个能点中的高度。
    public static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let font = font(size: fontSize)
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font))
    }

    /// 排版尺寸（不算字形外挂的装饰）。
    ///
    /// 空文本给一个"光标宽度"的宽度 —— 否则刚落下的文字框宽 0，点不中也看不到。
    public static func measure(_ text: String, fontSize: CGFloat) -> CGSize {
        let height = lineHeight(fontSize: fontSize)
        guard !text.isEmpty else {
            return CGSize(width: ceil(fontSize * 0.75), height: height)
        }
        let line = makeLine(text: text, fontSize: fontSize, color: nil)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGSize(width: ceil(CGFloat(width)), height: height)
    }

    /// 文本包围框，左上角在 `origin`（原图像素）。
    public static func frame(text: String, fontSize: CGFloat, origin: CGPoint) -> CGRect {
        CGRect(origin: origin, size: measure(text, fontSize: fontSize))
    }

    /// 在**左上原点、y 向下**的上下文里画一行文字。
    ///
    /// 内部的局部翻转不能省：CoreText 的字形空间是 y 向上，
    /// 直接把基线设在 `origin.y` 会让文字整个跑到上面去（且是镜像的）。
    /// 这里先平移到基线（`origin.y + ascent`），再局部翻成 y 向上，然后从 (0,0) 画。
    public static func draw(_ text: String,
                            fontSize: CGFloat,
                            color: CGColor,
                            at origin: CGPoint,
                            in context: CGContext) {
        guard !text.isEmpty else { return }
        let font = font(size: fontSize)
        let line = makeLine(text: text, fontSize: fontSize, color: color, fontOverride: font)

        context.saveGState()
        context.textMatrix = .identity
        let ascent = CTFontGetAscent(font)
        context.translateBy(x: origin.x, y: origin.y + ascent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func makeLine(text: String,
                                 fontSize: CGFloat,
                                 color: CGColor?,
                                 fontOverride: CTFont? = nil) -> CTLine {
        let font = fontOverride ?? font(size: fontSize)
        var attributes: [CFString: Any] = [kCTFontAttributeName: font]
        if let color {
            attributes[kCTForegroundColorAttributeName] = color
        }
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(attributed)
    }
}

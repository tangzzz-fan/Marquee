import Foundation

/// 升级卡片的**几何**：尺寸、贴在哪儿、每个按钮的命中区。
///
/// ## 为什么放 Core
///
/// 与工具条同一个理由：位置算错的表现是"卡片跑到屏幕外面"或"它盖住了选区"，
/// 而用户只会说"那个东西没出来"，不会告诉你它在哪。贴边、翻面这几种情况
/// 靠肉眼试不全，必须能单测。
///
/// ## 坐标约定（与 `OverlayToolbar` 一致）
///
/// 函数收发的是 **Cocoa 全局点**（y 向上）；内部布局用**卡片左下角为原点**的
/// 局部坐标。从顶部往下量的那几行统一走 `row(_:_:in:)` 换算 ——
/// "从顶上数"和"从底下数"混着写，是这类几何最容易出的错。
public enum ProCardLayout {

    // MARK: - 尺寸

    public static let width: CGFloat = 300
    public static let padding: CGFloat = 16
    /// 标题行高
    public static let titleHeight: CGFloat = 20
    /// 标题与正文之间的间距
    public static let titleBodyGap: CGFloat = 6
    /// 正文（留两行）
    public static let bodyHeight: CGFloat = 36
    /// 正文与按钮之间的间距
    public static let bodyButtonGap: CGFloat = 16
    public static let buttonHeight: CGFloat = 30
    /// 两个按钮之间的间距
    public static let buttonGap: CGFloat = 10
    /// 卡片与它依附的工具条之间的间距
    public static let gapFromAnchor: CGFloat = 10
    /// 夹取时与屏幕边缘留的余量
    public static let screenMargin: CGFloat = 8

    public static var size: CGSize {
        let height = padding            // 上内边距
            + titleHeight
            + titleBodyGap
            + bodyHeight
            + bodyButtonGap
            + buttonHeight
            + padding                   // 下内边距
        return CGSize(width: width, height: height)
    }

    // MARK: - 卡片内部的几块

    /// 卡片里那几块内容的矩形（**卡片局部坐标**，左下角为原点）。
    public struct Content: Equatable, Sendable {
        public var title: CGRect
        public var body: CGRect
        /// 主按钮（在右）
        public var primary: CGRect
        /// 次按钮（在左）
        public var secondary: CGRect
    }

    /// 从**顶部**往下量一行。
    private static func row(_ top: CGFloat, _ height: CGFloat,
                            in size: CGSize,
                            x: CGFloat = padding,
                            width: CGFloat? = nil) -> CGRect {
        let w = width ?? (size.width - padding * 2)
        return CGRect(x: x, y: size.height - top - height, width: w, height: height)
    }

    public static func content(in card: CGRect) -> Content {
        let size = card.size
        let inner = size.width - padding * 2
        let buttonWidth = (inner - buttonGap) / 2

        let bodyTop = padding + titleHeight + titleBodyGap
        let buttonTop = bodyTop + bodyHeight + bodyButtonGap

        return Content(
            title: row(padding, titleHeight, in: size),
            body: row(bodyTop, bodyHeight, in: size),
            primary: row(buttonTop, buttonHeight, in: size,
                         x: padding + buttonWidth + buttonGap, width: buttonWidth),
            secondary: row(buttonTop, buttonHeight, in: size,
                           x: padding, width: buttonWidth)
        )
    }

    // MARK: - 位置

    /// 卡片该放在哪（**Cocoa 全局点**）。
    ///
    /// 与弹层同一套路：优先弹在工具条**外侧**，放不下再翻到内侧，
    /// **最后统一夹进屏幕**（夹取必须最后做）。
    /// 水平方向**居中于工具条** —— 卡片比工具条窄，居中才不会看起来像贴错了边。
    public static func frame(toolbar: CGRect,
                             screenFrame: CGRect,
                             gap: CGFloat = gapFromAnchor) -> CGRect {
        let size = Self.size
        let screen = screenFrame.standardized

        let below = toolbar.minY - gap - size.height
        let above = toolbar.maxY + gap
        let roomBelow = below - screen.minY
        let roomAbove = screen.maxY - above

        var origin = CGPoint(x: toolbar.midX - size.width / 2, y: below)
        if roomBelow < 0, roomAbove > roomBelow {
            origin.y = above
        }

        let minX = screen.minX + screenMargin
        let maxX = max(minX, screen.maxX - screenMargin - size.width)
        let minY = screen.minY + screenMargin
        let maxY = max(minY, screen.maxY - screenMargin - size.height)
        origin.x = min(max(minX, origin.x), maxX)
        origin.y = min(max(minY, origin.y), maxY)

        return CGRect(origin: origin, size: size)
    }

    // MARK: - 命中

    /// 点在哪个按钮上。`nil` = 不在按钮上（卡片其余部分不接受点击）。
    ///
    /// 返回的是**这个按钮代表哪个动作**（`primary` / `secondary` 是角色，
    /// 同一个角色在不同档位下是不同的动作）。
    public static func action(at point: CGPoint,
                              in card: CGRect,
                              buttons: ProCardContent) -> ProCardAction? {
        let local = CGPoint(x: point.x - card.minX, y: point.y - card.minY)
        let layout = content(in: card)
        if layout.primary.contains(local) { return buttons.primary }
        if layout.secondary.contains(local) { return buttons.secondary }
        return nil
    }
}

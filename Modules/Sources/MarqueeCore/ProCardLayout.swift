import Foundation

/// 升级卡片的**几何**：尺寸、五个槽、贴在哪儿、每个按钮的命中区。
///
/// ## 为什么放 Core
///
/// 与工具条同一个理由：位置算错的表现是"卡片跑到屏幕外面"或"它盖住了选区"，
/// 而用户只会说"那个东西没出来"，不会告诉你它在哪。贴边、翻面这几种情况
/// 靠肉眼试不全，必须能单测。
///
/// ## 它与稿子的对应关系
///
/// 稿子在 `docs/design/2026-10-03-引导与升级卡片/pro-upgrade-card.html`，
/// 给出了**五个槽**（① 图标 ② 标题 ③ 正文 ④ 按钮组 ⑤ 微行）与两条尺寸：
///
/// | 载体 | 尺寸 | 微行 |
/// | --- | --- | --- |
/// | **A** 覆盖层内（恒深色） | 300 × **140** | 有 |
/// | **B** 菜单入口旁的系统面板（跟随外观） | 300 × **115** | 无 |
///
/// 两个尺寸**是同一行加法**，只差微行那一档：
/// `16 + 18 + 6 + 18 + 17 + 24 [ + 11 + 14 ] + 16` —— 所以它写成一个带开关的函数，
/// 而不是两个写死的数（写死的话，改了内边距只有一边会跟着动）。
///
/// ## 坐标约定
///
/// 与 `OverlayToolbar` 一致：`frame` 收发 **Cocoa 全局点**（y 向上）；
/// `content(in:)` 返回的是**以卡片左下角为原点的局部坐标** ——
/// 视图画的时候加 `box.origin`，控制层判命中时减 `card.origin`，
/// 于是"画出来的"与"点得到的"是**同一组矩形**（不是两份算得一样的东西）。
///
/// ⚠️ 从顶部往下量的那几行统一走 `row(_:_:in:x:width:)` ——
/// "从顶上数"和"从底下数"混着写，是这类几何最容易出的错。
public enum ProCardLayout {

    // MARK: - 外框

    public static let width: CGFloat = 300
    public static let cornerRadius: CGFloat = 10
    public static let padding: CGFloat = 16

    // MARK: - 五个槽的竖向阶（稿子 §03 那一行加法）

    /// ① 图标槽：16 × 16。
    public static let glyphSize: CGFloat = 16
    /// 图标与标题之间的距离。稿子：`.card__head{gap:8px}`。
    public static let glyphTitleGap: CGFloat = 8
    /// ② 标题行高（13pt / 18）。
    public static let headHeight: CGFloat = 18
    /// ② 与 ③ 之间。稿子：`.card__body{margin-top:6px}`。
    public static let headBodyGap: CGFloat = 6
    /// ③ 正文行高（12pt / 18）—— **一行**。
    public static let bodyHeight: CGFloat = 18
    /// ③ 与 ④ 之间。稿子：`.card__acts{margin-top:17px}`。
    public static let bodyButtonGap: CGFloat = 17
    /// ④ 按钮高（稿子：「高 24」）。
    public static let buttonHeight: CGFloat = 24
    /// ④ 里两个按钮之间。
    public static let buttonGap: CGFloat = 10
    /// ④ 与 ⑤ 之间。稿子：`.card__micro{margin-top:11px}`。
    public static let buttonMicroGap: CGFloat = 11
    /// ⑤ 微行的行高（11pt / 14）。
    public static let microHeight: CGFloat = 14
    /// 微行里键帽与那句话之间的距离。稿子：`.card__micro{gap:5px}`。
    public static let microGap: CGFloat = 5

    /// `esc` 键帽。稿子：`.kbd--x{min-width:16px;height:15px;border-radius:3.5px}`。
    ///
    /// ⚠️ 它比微行的行高（14）**高 1 点** —— 稿子就是这么给的。
    /// 那 0.5 点上下溢出落在 16 点的内边距里，看不见也碰不到别的东西，
    /// 所以**不去"修正"它**：改了就不再是稿子那个键帽了。
    public static let escKeyCapHeight: CGFloat = 15
    public static let escKeyCapMinWidth: CGFloat = 16
    public static let escKeyCapRadius: CGFloat = 3.5
    /// 键帽左右的内边距（`padding:0 4px`）。
    public static let escKeyCapPadding: CGFloat = 4

    /// ④ 里主按钮的左右内边距（稿子：`.btn--pri{padding:0 12px}`）。
    public static let primaryButtonPadding: CGFloat = 12
    /// ④ 里文字按钮的左右内边距（稿子：`.btn--txt{padding:0 8px}`）。
    public static let textButtonPadding: CGFloat = 8

    // MARK: - 字阶（稿子 §01：「卡片的四个字号 = 同一套字阶向下取两档」）

    /// ② 标题 13 / semibold（`--font-body`）。
    public static let titleFontSize: CGFloat = 13
    /// ③ 正文 12 / regular。
    public static let bodyFontSize: CGFloat = 12
    /// ④ 按钮 12（主 semibold / 次 medium）。
    public static let buttonFontSize: CGFloat = 12
    /// ⑤ 微行 11 / regular。
    public static let microFontSize: CGFloat = 11
    /// `esc` 键帽上那几个字母：10 / medium（稿子：`.kbd--x{font:500 10px}`）。
    public static let escKeyCapFontSize: CGFloat = 10

    /// ③ 正文那一行的**可用宽度**（内宽）。
    ///
    /// 稿子给的是「≤ 22 字」—— 那是按中文量的。英文同样占这条宽度，
    /// 而"够不够放"只能用真字体量（这一批同一类错已经犯过两次：
    /// 提示行与最近截图面板底部那一句）。断言在 `LocalizationScanTests` 里。
    public static var bodyLineWidth: CGFloat { width - padding * 2 }

    /// ④ 两个按钮 + 中间间距的**总可用宽度**（内宽）。
    public static var buttonRowWidth: CGFloat { width - padding * 2 }

    // MARK: - 锚定

    /// 卡片与工具条外缘之间的距离。稿子：「卡片左缘 = 工具条外缘 **+ 8 pt**」。
    public static let gapFromToolbar: CGFloat = 8
    /// 夹取时与屏幕边缘留的余量。
    public static let screenMargin: CGFloat = 8

    // MARK: - 尺寸

    /// 卡片高。`includesMicro == false` 就是载体 B（115）。
    public static func height(includesMicro: Bool) -> CGFloat {
        let base = padding          // 上内边距
            + headHeight
            + headBodyGap
            + bodyHeight
            + bodyButtonGap
            + buttonHeight
            + padding               // 下内边距
        guard includesMicro else { return base }
        return base + buttonMicroGap + microHeight
    }

    public static func size(includesMicro: Bool) -> CGSize {
        CGSize(width: width, height: height(includesMicro: includesMicro))
    }

    // MARK: - 卡片里那五块的矩形

    /// 卡片里那五块的矩形（**卡片局部坐标**，左下角为原点）。
    ///
    /// ⑤ 微行是 `nil` 表示载体 B 没有这一槽 —— 用它而不是一个空矩形：
    /// 空矩形会被 `contains` 当成"左上角那一个点"，于是"没有微行"和
    /// "微行在原点"在命中判定里长得一模一样。
    public struct Content: Equatable, Sendable {
        /// ① 图标（16 × 16，在标题行里竖直居中）
        public var glyph: CGRect
        /// ② 标题
        public var title: CGRect
        /// ③ 正文（一行）
        public var body: CGRect
        /// ④ 主按钮（贴在右下角）
        public var primary: CGRect
        /// ④ 次按钮（主按钮左边）
        public var secondary: CGRect
        /// ⑤ 微行里的 `esc` 键帽
        public var escKeyCap: CGRect?
        /// ⑤ 微行里那句话（键帽右侧）
        public var micro: CGRect?
    }

    /// 从**顶部**往下量一行。`top` 是这一行的上边到卡片顶部的距离。
    private static func row(_ top: CGFloat,
                            _ height: CGFloat,
                            in size: CGSize,
                            x: CGFloat = padding,
                            width: CGFloat? = nil) -> CGRect {
        let w = width ?? (size.width - padding * 2)
        return CGRect(x: x,
                      y: size.height - top - height,
                      width: w,
                      height: height)
    }

    /// 那三处**要靠字体量**的宽度。
    ///
    /// 由视图量好带进来（Core 不碰字体）。做成一个结构体而不是三个参数：
    /// 再加一处要量的宽度时，编译会替我们找到所有调用点，
    /// 而三个裸参数很容易在某个调用点上安静地传错位。
    public struct Measures: Equatable, Sendable {
        public var primaryButtonWidth: CGFloat
        public var secondaryButtonWidth: CGFloat
        public var escKeyCapWidth: CGFloat

        public init(primaryButtonWidth: CGFloat,
                    secondaryButtonWidth: CGFloat,
                    escKeyCapWidth: CGFloat = ProCardLayout.escKeyCapMinWidth) {
            self.primaryButtonWidth = primaryButtonWidth
            self.secondaryButtonWidth = secondaryButtonWidth
            self.escKeyCapWidth = escKeyCapWidth
        }
    }

    /// 排一遍五个槽。**尺寸从 `card` 出**（所以本函数对 `card.origin` 无感）。
    ///
    /// - Parameters:
    ///   - primaryButtonWidth: 主按钮宽（由视图按**真实字体**量出来 —— Core 不碰字体）
    ///   - secondaryButtonWidth: 次按钮宽，同上
    public static func content(in card: CGRect,
                               includesMicro: Bool,
                               measures: Measures) -> Content {
        let size = card.size
        let primaryButtonWidth = measures.primaryButtonWidth
        let secondaryButtonWidth = measures.secondaryButtonWidth

        let headerTop = padding
        let bodyTop = headerTop + headHeight + headBodyGap
        let buttonTop = bodyTop + bodyHeight + bodyButtonGap

        // ① 图标在标题行里竖直居中（稿子：`.card__head{align-items:center}`）
        let glyph = CGRect(x: padding,
                           y: size.height - headerTop - (headHeight + glyphSize) / 2,
                           width: glyphSize,
                           height: glyphSize)
        // ② 标题从图标右边让开 gap 起，到右内边距止
        let titleX = padding + glyphSize + glyphTitleGap
        let title = row(headerTop, headHeight, in: size,
                        x: titleX, width: max(0, size.width - padding - titleX))
        // ③ 正文占满内宽
        let body = row(bodyTop, bodyHeight, in: size)

        // ④ 按钮组**右对齐**，主按钮贴右下角（稿子：「主按钮贴右下角，离"结束"最近」）
        //
        // ⚠️ 主按钮的宽度**不夹**（它承载"推荐"，被裁掉一半比挤掉次按钮更难看），
        // 次按钮则同时受两条约束：不与主按钮重叠、不探出左内边距。
        // 两个都保住的做法是**让它变窄**，而不是让它移出去 ——
        // 移出去的话它会画到卡片外面（那是渲染事故），而变窄只是文案被裁。
        //
        // 正常长度下这两条都不会触发（稿子的示意值是 96 + 10 + 72 = 178，而内宽是 268）；
        // 它们是为**长英文**准备的兜底，而"长英文放不放得下"另有一条断言在管
        // （`LocalizationScanTests` —— 稿子量的是中文，英文往往更长）。
        let primaryX = max(padding, size.width - padding - primaryButtonWidth)
        let primary = row(buttonTop, buttonHeight, in: size,
                          x: primaryX, width: primaryButtonWidth)
        let secondaryWidth = min(secondaryButtonWidth,
                                 max(0, primaryX - buttonGap - padding))
        let secondary = row(buttonTop, buttonHeight, in: size,
                            x: primaryX - buttonGap - secondaryWidth,
                            width: secondaryWidth)

        guard includesMicro else {
            return Content(glyph: glyph, title: title, body: body,
                           primary: primary, secondary: secondary,
                           escKeyCap: nil, micro: nil)
        }

        // ⑤ 微行：键帽 + 一句话
        let microTop = buttonTop + buttonHeight + buttonMicroGap
        let capWidth = max(escKeyCapMinWidth, measures.escKeyCapWidth)
        let cap = CGRect(x: padding,
                         y: size.height - microTop - escKeyCapHeight,
                         width: capWidth,
                         height: escKeyCapHeight)
        let textX = padding + capWidth + microGap
        let micro = row(microTop, microHeight, in: size,
                        x: textX, width: max(0, size.width - padding - textX))
        return Content(glyph: glyph, title: title, body: body,
                       primary: primary, secondary: secondary,
                       escKeyCap: cap, micro: micro)
    }

    // MARK: - 位置

    /// 卡片该放在哪（**Cocoa 全局点**）。
    ///
    /// ## 水平：贴工具条的**外缘**
    ///
    /// 稿子给的是「卡片左缘 = 工具条外缘 + 8 pt」—— 也就是**并排**在工具条旁边，
    /// 不是挂在它上下。优先右侧；右边装不下就翻到左侧；两边都装不下才夹进屏幕。
    ///
    /// ## 竖向：往**背离选区**的那一侧长
    ///
    /// ⚠️ 这一条是我定的（稿子只给了水平锚定），判据是它自己那句**「卡片不覆盖选区」**：
    ///
    /// | 工具条在哪 | 卡片怎么对 | 为什么 |
    /// | --- | --- | --- |
    /// | 选区**下方**（常态） | 顶边与工具条顶边对齐，**向下**长 | 整张卡都在选区下面 |
    /// | 选区**上方**（选区贴屏底） | 底边与工具条底边对齐，**向上**长 | 反过来会把卡片推进选区里 |
    ///
    /// 写成"与工具条垂直居中"就错了：卡片 140 高、工具条 40 高，居中之后
    /// 卡片会**往选区那侧探出去 50 点** —— 正好压住用户要截的东西。
    public static func frame(toolbar: CGRect,
                             selection: CGRect?,
                             screenFrame: CGRect,
                             includesMicro: Bool) -> CGRect {
        let size = Self.size(includesMicro: includesMicro)
        let screen = screenFrame.standardized

        // ① 水平：优先工具条右侧
        var x = toolbar.maxX + gapFromToolbar
        if x + size.width > screen.maxX - screenMargin {
            // ② 右侧放不下 → 翻到左侧（卡片右缘 = 工具条左缘 − 8）
            let flipped = toolbar.minX - gapFromToolbar - size.width
            x = flipped >= screen.minX + screenMargin
                ? flipped
                : screen.maxX - screenMargin - size.width
        }

        // ③ 竖向：往背离选区的那一侧长
        var y = toolbar.midY - size.height / 2
        if let selection {
            if toolbar.maxY <= selection.minY {
                y = toolbar.maxY - size.height      // 工具条在选区下方：顶边对齐，向下长
            } else if toolbar.minY >= selection.maxY {
                y = toolbar.minY                    // 工具条在选区上方：底边对齐，向上长
            }
        }

        // ④ 夹取**必须最后做**（与工具条同一个理由：先夹再翻会得到"翻上去又被夹回来"）
        let minX = screen.minX + screenMargin
        let maxX = max(minX, screen.maxX - screenMargin - size.width)
        let minY = screen.minY + screenMargin
        let maxY = max(minY, screen.maxY - screenMargin - size.height)
        x = min(max(minX, x), maxX)
        y = min(max(minY, y), maxY)

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - 命中

    /// 点在哪个按钮上。`nil` = 不在按钮上 —— 卡片其余部分不接受点击。
    ///
    /// 返回的是**这个按钮代表哪个动作**（`primary` / `secondary` 是角色，
    /// 同一个角色在不同档位下是不同的动作）。
    ///
    /// ⚠️ 判据用的是**与绘制同一份** `layout`（由调用方算好一次带下来）——
    /// 两处各算一遍的话，"看着在按钮上、点它没反应"就会在某次调尺寸时悄悄出现。
    public static func action(at point: CGPoint,
                              in card: CGRect,
                              layout: Content,
                              buttons: ProCardContent) -> ProCardAction? {
        let local = CGPoint(x: point.x - card.minX, y: point.y - card.minY)
        if layout.primary.contains(local) { return buttons.primary }
        if layout.secondary.contains(local) { return buttons.secondary }
        return nil
    }
}

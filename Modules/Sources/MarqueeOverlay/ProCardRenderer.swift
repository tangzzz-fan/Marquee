import AppKit
import MarqueeCore

/// 升级卡片的**量尺与画法**（ticket 31 · 2026-10-04 对齐稿子）。
///
/// ## 为什么抽出来
///
/// 卡片有**两个载体**：覆盖层里那张（贴着工具条弹，载体 A），和菜单入口被挡时那张
/// （独立小面板 —— 因为那时覆盖层还没出现，载体 B）。
///
/// 两处各实现一遍的话，改一个错别字就得记得改两处；而"忘了改另一处"的表现是
/// **同一张卡片长得不一样**，用户只会觉得哪里不对劲，说不清是哪里。
///
/// ## 分工
///
/// - **几何**在 Core（`ProCardLayout`）：五个槽的竖阶、按钮右对齐、贴哪儿。
/// - **字体**在这里：Core 不碰 `NSFont`，所以"按钮多宽""键帽多宽"由这里量出来，
///   装进 `ProCardLayout.Measures` 交给 Core 排。
/// - **画**也在这里，且**照着传进来的 `layout` 画** —— 视图不再自己算任何一个坐标，
///   于是"画出来的"与"点得到的"是同一组矩形（`ProCardLayout.action` 用的是同一份）。
@MainActor
public enum ProCardRenderer {

    // MARK: - 字号（稿子 §01 的字阶）

    // ⚠️ 六枚字体写成**计算属性**而不是 `static let`：`NSFont` 不是 `Sendable`，
    // 存成全局常量会被 Swift 6 的并发检查拦下（"shared mutable state"）。
    // 写成计算属性没有代价 —— `NSFont.systemFont` 自己就是带缓存的。
    // 字号**从 Core 取**（`ProCardLayout` 那五枚）—— 于是"卡片上这四个字多大"
    // 只有一处声明，而那条按真字体量的宽度断言用的也是同一份数。
    static var titleFont: NSFont {
        .systemFont(ofSize: ProCardLayout.titleFontSize, weight: .semibold)
    }
    static var bodyFont: NSFont { .systemFont(ofSize: ProCardLayout.bodyFontSize) }
    static var primaryButtonFont: NSFont {
        .systemFont(ofSize: ProCardLayout.buttonFontSize, weight: .semibold)
    }
    static var textButtonFont: NSFont {
        .systemFont(ofSize: ProCardLayout.buttonFontSize, weight: .medium)
    }
    static var microFont: NSFont { .systemFont(ofSize: ProCardLayout.microFontSize) }
    static var escKeyCapFont: NSFont {
        .systemFont(ofSize: ProCardLayout.escKeyCapFontSize, weight: .medium)
    }

    /// `esc` 键帽上那三个字母。**不进本地化** —— 它是键名，两种语言下都是 `esc`。
    static let escKeyCapLabel = "esc"

    // MARK: - 量

    /// 把三处要靠字体量的宽度算出来（Core 拿它排五个槽）。
    public static func measures(for content: ProCardContent) -> ProCardLayout.Measures {
        let primary = textWidth(actionTitle(content.primary), font: primaryButtonFont)
            + ProCardLayout.primaryButtonPadding * 2
        let secondary = textWidth(actionTitle(content.secondary), font: textButtonFont)
            + ProCardLayout.textButtonPadding * 2
        let cap = textWidth(escKeyCapLabel, font: escKeyCapFont)
            + ProCardLayout.escKeyCapPadding * 2
        return ProCardLayout.Measures(primaryButtonWidth: primary,
                                      secondaryButtonWidth: secondary,
                                      escKeyCapWidth: cap)
    }

    /// 排一遍五个槽。**绘制与命中都用这一份**。
    public static func layout(for content: ProCardContent,
                              in card: CGRect,
                              includesMicro: Bool) -> ProCardLayout.Content {
        ProCardLayout.content(in: card,
                              includesMicro: includesMicro,
                              measures: measures(for: content))
    }

    // MARK: - 画

    /// 画一整张卡片。
    ///
    /// - Parameters:
    ///   - box: 卡片矩形（**调用方视图的局部坐标** —— 与 `layout` 同一套原点体系）
    ///   - hovered: 鼠标此刻压在哪个按钮上（`nil` = 不在任何按钮上）
    ///   - pressed: 此刻**按着**哪个按钮（`nil` = 没按）
    public static func draw(_ content: ProCardContent,
                            layout: ProCardLayout.Content,
                            in box: NSRect,
                            theme: ChromePalette.Theme = ChromePalette.dark,
                            hovered: ProCardAction? = nil,
                            pressed: ProCardAction? = nil,
                            priceText: String? = nil) {
        let radius = ProCardLayout.cornerRadius
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        // 描边：深色宿主用白 12%，浅色宿主用黑 10%（稿子：`.card--bl{border:1px solid rgba(0,0,0,.10)}`）。
        // 判断依据是**卡片自己的底**而不是系统外观 —— 载体 A 在浅色系统下也仍是深色卡片。
        // 描边 **16%**（稿子 ⑩ §07：「描边 12% → 16%：透底后原 12% 会「化」，
        // +4 个点才重新成为一条边」）。浅色那侧仍是 10%（§04 的原值）。
        let outlineColor = theme == ChromePalette.dark
            ? ChromePalette.Overlay.panelBorder.nsColor
            : ChromePalette.Overlay.panelBorderLight.nsColor
        outlineColor.setStroke()
        outline.stroke()

        // ① 图标：**用户刚点的那个功能**，用强调色（`--c-glyph`）
        draw(AnnotationIcon.icon(for: content.feature),
             in: layout.glyph.offsetBy(dx: box.minX, dy: box.minY),
             color: theme.glyph.nsColor,
             isDark: theme == ChromePalette.dark)
        // ② 标题
        drawLine(title(content.feature),
                 in: layout.title.offsetBy(dx: box.minX, dy: box.minY),
                 font: titleFont,
                 color: theme.label.nsColor)
        // ③ 正文：**一行**（稿子：≤ 22 字）
        drawLine(body(content, priceText: priceText),
                 in: layout.body.offsetBy(dx: box.minX, dy: box.minY),
                 font: bodyFont,
                 color: theme.label2.nsColor)
        // ④ 按钮组
        drawButton(content.secondary,
                   in: layout.secondary.offsetBy(dx: box.minX, dy: box.minY),
                   font: textButtonFont,
                   theme: theme,
                   prominent: false,
                   state: buttonState(of: content.secondary, hovered: hovered, pressed: pressed))
        drawButton(content.primary,
                   in: layout.primary.offsetBy(dx: box.minX, dy: box.minY),
                   font: primaryButtonFont,
                   theme: theme,
                   prominent: true,
                   state: buttonState(of: content.primary, hovered: hovered, pressed: pressed))
        // ⑤ 微行（只有载体 A 有）
        if let cap = layout.escKeyCap, let micro = layout.micro {
            drawEscKeyCap(in: cap.offsetBy(dx: box.minX, dy: box.minY), theme: theme)
            drawLine(microLabel,
                     in: micro.offsetBy(dx: box.minX, dy: box.minY),
                     font: microFont,
                     color: theme.label2.nsColor)
        }
    }

    /// 一个按钮此刻是哪种态。**主次各只有一个**：`hovered`/`pressed` 是同一个动作时才轮到它。
    private static func buttonState(of action: ProCardAction,
                                    hovered: ProCardAction?,
                                    pressed: ProCardAction?) -> ButtonState {
        if pressed == action { return .pressed }
        if hovered == action { return .hovered }
        return .normal
    }

    enum ButtonState { case normal, hovered, pressed }

    /// 按钮。主按钮 = **唯一色块**（`--c-fill`），次按钮 = 纯文字。
    ///
    /// ## 三个态都有出处（稿子 §06）
    ///
    /// | 态 | 主按钮 | 文字按钮 |
    /// | --- | --- | --- |
    /// | 默认 | `#006FDC` · 白字 | 透明底 · 次要字色 |
    /// | 悬停 | `#0072DF` | 底 `--c-ghost` · 主字色 |
    /// | 按下 | `#0059C4` | 底 `--c-ghost-p` · 主字色 |
    ///
    /// ⚠️ **必须有点击反馈**：没有悬停与按下的按钮，用户点一下看不到任何变化，
    /// 结论就是"这个卡片点不动" —— 而它其实是能点的（2026-10-04 用户报的原话）。
    /// ⚠️ `prominent` 是**角色**（主 / 次），不是动作 —— 传 `action == .startTrial`
    /// 那种写法会让"恢复购买当主按钮"的那一档变成两个色块（三个动作里总有一个会踩中）。
    private static func drawButton(_ action: ProCardAction,
                                   in rect: CGRect,
                                   font: NSFont,
                                   theme: ChromePalette.Theme,
                                   prominent: Bool,
                                   state: ButtonState) {
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        if prominent {
            // 主按钮：**全卡唯一色块**，三种态各一档色（稿子 §06）
            let fill: RGB
            switch state {
            case .normal: fill = theme.fill
            case .hovered: fill = theme.fillHover
            case .pressed: fill = theme.fillPressed
            }
            fill.nsColor.setFill()
            path.fill()
        } else if state != .normal {
            // 文字按钮：**常态无底无框**，只有悬停 / 按下才铺一层
            (state == .pressed ? theme.ghostPressed : theme.ghost).nsColor.setFill()
            path.fill()
        }

        let color = prominent
            ? NSColor.white
            : (state == .normal ? theme.label2.nsColor : theme.label.nsColor)
        let attributed = NSAttributedString(string: actionTitle(action), attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        attributed.draw(at: NSPoint(x: rect.midX - attributed.size().width / 2,
                                    y: rect.midY - attributed.size().height / 2))
    }

    /// `esc` 键帽：`--c-cap` 底 + `--c-capbd` 描边 + 主字色。
    private static func drawEscKeyCap(in rect: CGRect, theme: ChromePalette.Theme) {
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: ProCardLayout.escKeyCapRadius,
                                yRadius: ProCardLayout.escKeyCapRadius)
        theme.cap.nsColor.setFill()
        path.fill()
        path.lineWidth = 1
        theme.capBorder.nsColor.setStroke()
        path.stroke()

        let attributed = NSAttributedString(string: escKeyCapLabel, attributes: [
            .font: escKeyCapFont,
            .foregroundColor: theme.label.nsColor,
        ])
        attributed.draw(at: NSPoint(x: rect.midX - attributed.size().width / 2,
                                    y: rect.midY - attributed.size().height / 2))
    }

    // MARK: - 内部

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 单行文字，左对齐、**垂直居中**。
    ///
    /// 只画单行是刻意的：多行文本在非 flipped 坐标里要靠 `draw(with:options:)` 定位，
    /// 而它的原点语义随上下文变，容易"文字贴底"或"跑出框"；`draw(at:)` 没有这个问题，
    /// 代价是文案必须写短。卡片的正文本来就该短（稿子：≤ 22 字）。
    private static func drawLine(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        attributed.draw(at: NSPoint(x: rect.minX,
                                    y: rect.midY - attributed.size().height / 2))
    }

    /// SF Symbol 一把画进给定矩形。
    ///
    /// 用 `ChromeSymbol`（`.preferringMonochrome()` + 缓存）——
    /// 多色符号在这套 `paletteColors` 下第一层会被整片填充，而重建图像的代价
    /// 在"鼠标划过按钮"时是每秒几十次。
    private static func drawSymbol(_ name: String, in rect: CGRect,
                                   color: NSColor, isDark: Bool) {
        ChromeSymbol.draw(name, in: rect,
                          pointSize: ProCardLayout.glyphSize,
                          weight: .medium,
                          color: color,
                          appearance: NSAppearance(named: isDark ? .darkAqua : .aqua))
    }

    /// 画一枚图标 —— **两个来源在这里合流**。
    ///
    /// 卡片槽与工具条走的是同一份判据（`AnnotationIcon.icon(for:)`），
    /// 所以"用户在格子上看到什么、卡片上就是什么"是结构上成立的，不靠人记得同步。
    private static func draw(_ icon: AnnotationIcon.Icon, in rect: CGRect,
                             color: NSColor, isDark: Bool) {
        switch icon {
        case .symbol(let name):
            drawSymbol(name, in: rect, color: color, isDark: isDark)
        case .glyph(let glyph):
            // 卡片槽与工具条**不是同一个尺寸** —— 工具条那枚按 17 点墨迹摆，
            // 这里按卡片自己的图标槽高度摆（`ProCardLayout.glyphSize`）。
            // 墨迹高度取 `glyphSize` 是刻意的：卡片上那一格就是给这么大一枚图形留的。
            ChromeGlyph.draw(glyph, in: rect, color: color,
                             inkHeight: ProCardLayout.glyphSize)
        }
    }

    // MARK: - 文案
    //
    // 三个函数都是**穷尽 switch**：加了新能力 / 新原因 / 新动作却不给文案，
    // 编译就过不去 —— 而 `default` 会让新情况悄悄落到一句不相干的话上。

    /// 卡片标题：**先陈述事实，再给选项**。标题里不出现价格，"升级"也不做主语。
    ///
    /// ⚠️ **刻意写成四句独立文案，不是 `"\(入口名)是 Pro 能力"` 那样的拼接。** 两个理由：
    ///
    /// 1. 拼接会把中文语序焊死 —— 英文里这个变量该在句首；
    /// 2. 生成器（`Tools/L10nCatalog`）要**按表达式名猜**说明符类型。它曾经把
    ///    `cardEntryName(…)` 猜成了 `%lld`（正确是 `%@`），于是 catalog 里生出一个
    ///    错 key —— 而那种错**不会让编译失败**，只在运行时静默不翻译。
    private static func title(_ feature: ProFeature) -> String {
        switch feature {
        case .scrollCapture: L10n.t("滚动截屏是 Pro 能力")
        case .textRecognition: L10n.t("识别文字是 Pro 能力")
        case .pin: L10n.t("钉图是 Pro 能力")
        case .unlimitedHistory: L10n.t("最近截图是 Pro 能力")
        }
    }

    /// 卡片正文：**一句后果陈述，一行写完**（稿子：≤ 22 字）。
    ///
    /// ⚠️ 它要与主按钮说的是**同一件事**：主按钮给"试用"，正文就说"试用结束会怎样"；
    /// 主按钮给"了解 Pro"，正文就先安抚"免费版仍然可用"。
    /// 两句话指向不同的下一步时，用户会停下来想"到底哪句算数"。
    ///
    /// 所以 `.neverPurchased` 这一档要看 `primary`：同一个 reason 下，
    /// 主按钮是「7 天免费试用」还是「了解 Pro」取决于**试用有没有用过**。
    private static func body(_ content: ProCardContent, priceText: String?) -> String {
        // "哪一句"的判据在 Core（`ProCard.bodyVariant`），这里只负责把它翻成中文 ——
        // 判据留在视图层的话，"对着用过试用的人说可以试用 7 天"这种错没人拦得住。
        switch ProCard.bodyVariant(for: content, priceAvailable: priceText != nil) {
        case .trialWithPrice:
            // ⚠️ 价格文案来自商店（`displayPrice`），**不许自己拼** ——
            // 每个店面的货币与格式都不同，写死一个 `¥36` 只会在中国区看着对。
            L10n.t("试用 7 天 · 之后 \(priceText ?? "") · 免费版仍可用")
        case .trial: L10n.t("试用 7 天，结束后自动回到免费版")
        case .trialEnded: L10n.t("试用已结束，免费版仍可截图与标注")
        case .revokedByStore: L10n.t("购买已撤销，可点恢复购买重新获取")
        case .purchaseNotFound: L10n.t("这个账号下找不到这笔购买")
        }
    }

    private static func actionTitle(_ action: ProCardAction) -> String {
        switch action {
        case .startTrial: L10n.t("7 天免费试用")
        case .purchase: L10n.t("了解 Pro")
        case .restore: L10n.t("恢复购买")
        }
    }

    /// ⑤ 微行那一句。**只在载体 A 出现**（它承诺"这张卡不会吃掉你手上的截图"）。
    private static var microLabel: String { L10n.t("关闭卡片，选区保留") }
}

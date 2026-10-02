import AppKit
import MarqueeCore

/// 升级卡片的**画法**（ticket 31）。
///
/// ## 为什么抽出来
///
/// 卡片有**两个载体**：覆盖层里那张（贴着工具条弹），和菜单入口被挡时那张
/// （独立小面板 —— 因为那时覆盖层还没出现）。
///
/// 两处各实现一遍的话，改一个错别字就得记得改两处；而"忘了改另一处"的表现是
/// **同一张卡片长得不一样**，用户只会觉得哪里不对劲，说不清是哪里。
///
/// ## 分工
///
/// 几何由调用方给（`ProCardLayout` 算出来的 `box`），这里只管怎么画 ——
/// 于是"画在哪"仍然只有一个来源，"画成什么样"也只有一个来源。
public enum ProCardRenderer {

    /// 画一整张卡片：描边 + 标题 + 正文 + 两个按钮。
    public static func draw(_ content: ProCardContent, in box: NSRect) {
        let layout = ProCardLayout.content(in: box)

        let radius = OverlayToolbar.cornerRadius
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.12).setStroke()
        outline.stroke()

        drawLine(title(content.feature), in: layout.title,
                 font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
        drawLine(body(content.reason), in: layout.body,
                 font: .systemFont(ofSize: 11),
                 color: NSColor.white.withAlphaComponent(0.75))

        drawButton(content.primary, in: layout.primary, prominent: true)
        drawButton(content.secondary, in: layout.secondary, prominent: false)
    }

    /// 单行文字，左对齐、**垂直居中**。
    ///
    /// 只画单行是刻意的：多行文本在非 flipped 坐标里要靠 `draw(with:options:)` 定位，
    /// 而它的原点语义随上下文变，容易"文字贴底"或"跑出框"；`draw(at:)` 没有这个问题，
    /// 代价是文案必须写短。卡片的正文本来就该短。
    private static func drawLine(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        attributed.draw(at: NSPoint(x: rect.minX,
                                    y: rect.midY - attributed.size().height / 2))
    }

    /// 按钮。主按钮实心，次按钮只铺一层薄底。
    private static func drawButton(_ action: ProCardAction, in rect: CGRect, prominent: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if prominent {
            // 用项目自己那一支**验过对比度**的绿（`OverlayAccent.confirm`），
            // 而不是 `controlAccentColor`：后者的实际色值由用户的强调色设置决定，
            // 遇到浅黄时白字会糊成一片 —— 而"看不清按钮上的字"最容易被当成"这个 app 很糙"。
            NSColor(red: OverlayAccent.confirm.red,
                    green: OverlayAccent.confirm.green,
                    blue: OverlayAccent.confirm.blue,
                    alpha: 1).setFill()
        } else {
            NSColor.white.withAlphaComponent(0.14).setFill()
        }
        path.fill()

        let attributed = NSAttributedString(string: actionTitle(action), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: prominent ? .semibold : .regular),
            .foregroundColor: NSColor.white,
        ])
        attributed.draw(at: NSPoint(x: rect.midX - attributed.size().width / 2,
                                    y: rect.midY - attributed.size().height / 2))
    }

    // MARK: - 文案
    //
    // 三个函数都是**穷尽 switch**：加了新能力 / 新原因 / 新动作却不给文案，
    // 编译就过不去 —— 而 `default` 会让新情况悄悄落到一句不相干的话上。

    /// 卡片标题。
    ///
    /// ⚠️ **刻意写成四句独立文案，不是 `"\(入口名)是 Pro 能力"` 那样的拼接。** 两个理由：
    ///
    /// 1. 拼接会把中文语序焊死 —— 英文里这个变量该在句首（"Text recognition is a Pro
    ///    feature"），拼出来的句子翻不动；
    /// 2. 生成器（`Tools/L10nCatalog`）要**按表达式名猜**说明符类型。它把
    ///    `cardEntryName(…)` 猜成了 `%lld`（正确是 `%@`），于是 catalog 里生出一个
    ///    错 key —— 而那种错**不会让编译失败**，只在运行时静默不翻译。
    ///
    ///    真被咬到时，第一反应会是"翻译没生效"，而不是"key 生成错了"。
    private static func title(_ feature: ProFeature) -> String {
        switch feature {
        case .scrollCapture: L10n.t("滚动截屏是 Pro 能力")
        case .textRecognition: L10n.t("识别文字是 Pro 能力")
        case .pin: L10n.t("钉图是 Pro 能力")
        case .unlimitedHistory: L10n.t("最近截图是 Pro 能力")
        }
    }

    private static func body(_ reason: BlockedReason) -> String {
        switch reason {
        case .neverPurchased: L10n.t("一次买断，不订阅")
        case .trialEnded: L10n.t("试用已结束，购买后继续使用")
        case .revoked(let cause):
            // 两档分开说：退款与"被移出家人共享"是完全不同的两件事，
            // 对后者说"你退款了"会让用户以为账号被盗。
            switch cause {
            case .storeRevoked: L10n.t("购买被撤销：退款，或移出家人共享")
            case .purchaseNotFound: L10n.t("这个账号下找不到这笔购买")
            }
        }
    }

    private static func actionTitle(_ action: ProCardAction) -> String {
        switch action {
        case .startTrial: L10n.t("7 天免费试用")
        case .purchase: L10n.t("了解 Pro")
        case .restore: L10n.t("恢复购买")
        }
    }
}

import CoreGraphics
import Foundation

/// 「最近截图」面板（菜单栏弹出那一层）的**几何与文案**。
///
/// ## 为什么这一块要放 Core
///
/// 它与 `ChromeControl` 是同一条脉络：一堆单独看都很普通、改错却**不会报错**的数。
///
/// | 数 | 改错了会怎样 |
/// | --- | --- |
/// | 面板宽 340 / 行 46 | 四段内容挤不下 → 文字被截断尾巴（而截断不报错） |
/// | 缩略图 48 × 34 | 比例失衡：16:10 的图会被裁掉两边，4:3 的会留黑边 |
/// | 复制徽章的 5 点外扩 | 出到行外 → 被相邻行的发丝线切开 |
/// | 行数上限 12 | 面板高过屏幕 → 底部那行"升级到 Pro"看不见 |
///
/// 「面板高随条数变」这条尤其要在这里算：它由三个常量相加而成，
/// 而那三项分别在**标题带 / 列表 / 底部**三个地方画，
/// 谁改了自己那一段都不会想到要去改这个和。
///
/// ## 一句话界限
///
/// 这一层只管**数与字**，不碰任何 AppKit 类型 —— 于是它可以在没有 UI 的上下文里跑测试。
/// 真正画的时候由 App 那边读这些值（见 `App/Sources/RecentCapturesPanelController.swift`）。
public enum RecentPanel {

    // MARK: - 面板

    /// 面板宽。稿子 §01：「340 宽」。
    ///
    /// ⚠️ 它与偏好设置窗口的 440 是**两个数**，别顺手统一：那个是独立窗口、
    /// 这个是弹在菜单栏下面的浮层，宽度由"一行里放得下什么"决定。
    public static let width: CGFloat = 340
    /// 列表里最多几条。稿子：「最高 12 行」。
    public static let maximumRows = 12
    /// 面板圆角。稿子：「10 pt」。
    public static let cornerRadius: CGFloat = 10
    /// 面板描边。稿子：「1px 白色 12%」。
    public static let borderWidth: CGFloat = 1

    // MARK: - 标题带

    /// 标题带高。稿子：「34 高 · 左右内边距 10」。
    public static let titleBarHeight: CGFloat = 34
    public static let titleBarPadding: CGFloat = 10

    // MARK: - 行

    /// 列表左右的内边距。稿子：「行 左右 5（列内再 5 = 视觉 10）」——
    /// **两个 5 都要有**：列表的 5 让悬停底离面板边 5 点，
    /// 行自己的 5 让缩略图离面板边 10 点。只留一个的话，
    /// 要么悬停底顶到面板边上（像一块色斑），要么内容贴着边（像没排过版）。
    public static let listPadding: CGFloat = 5
    /// 行高。稿子：「46 高」。
    public static let rowHeight: CGFloat = 46
    /// 行自己的左右内边距。
    public static let rowPadding: CGFloat = 5
    /// 行悬停底的圆角。稿子：「6 pt」。
    public static let rowCornerRadius: CGFloat = 6
    /// 行内四段之间恒定的间隙。稿子：`.rt{gap:10px}` —— 它属于图，不属于字。
    public static let rowGap: CGFloat = 10
    /// 尺寸那行与时间那行之间的间隙。稿子：`.rt__m{margin-top:2px}`。
    public static let rowDetailGap: CGFloat = 2
    /// 第一行（时间）的行高。稿子：`font:400 12px/16px`。
    public static let timeLineHeight: CGFloat = 16
    /// 第二行（尺寸）的行高。稿子：`font:500 11px/14px`。
    public static let detailLineHeight: CGFloat = 14

    // MARK: - 缩略图（它就是按钮）

    /// 缩略图。稿子：「48 × 34（约 1.41 : 1，容纳 16:10 与 4:3 两种）」。
    public static let thumbnailSize = CGSize(width: 48, height: 34)
    public static let thumbnailCornerRadius: CGFloat = 4
    /// 常态描边（发丝线）。
    public static let thumbnailBorderWidth: CGFloat = 1
    /// 悬停时那圈蓝环的**总宽**。
    ///
    /// 稿子写的是「1px 描边 + 1px 外圈」（`border-color` 加 `box-shadow: 0 0 0 1px`），
    /// 画出来是一条 2 点的蓝环 —— 而它**压在**发丝线描边上、不占内容。
    /// 所以这里直接是一个 2，不是"描边 1 + 外圈 1"两个数：拆成两个数就要保证它俩一起改。
    public static let thumbnailRingWidth: CGFloat = 2
    /// 按下时图面压暗的强度。稿子：`.rt__im.is-press i.im::after{background:rgba(0,0,0,.38)}`。
    public static let thumbnailPressDim: Double = 0.38

    /// 复制徽章（悬停 / 按下才出现）。
    public static let copyBadgeSize: CGFloat = 18
    /// 徽章相对**缩略图自己**的位置（左下角为原点）。
    ///
    /// 缩略图是一件独立的视图，它画徽章时用的是自己的坐标系 ——
    /// 算式写在那儿的话，"行里量出来的位置"与"画出来的位置"就成了两份事实。
    /// 所以这里给一份，行与缩略图**共用**。
    public static var copyBadgeInThumbnail: CGRect {
        CGRect(x: thumbnailSize.width + copyBadgeOffset - copyBadgeSize,
               y: thumbnailSize.height + copyBadgeOffset - copyBadgeSize,
               width: copyBadgeSize,
               height: copyBadgeSize)
    }
    /// 徽章**外扩**出缩略图右上角的距离。稿子：`.rt__badge{top:-5px;right:-5px}`。
    public static let copyBadgeOffset: CGFloat = 5
    public static let copyBadgeCornerRadius: CGFloat = 5
    /// 徽章里那枚图标的大小。稿子：`svg{width:11px;height:11px}`。
    public static let copyBadgeIconSize: CGFloat = 11

    // MARK: - 两个动作（编辑 / 删除）

    /// 动作按钮高。稿子：`.btn--mini{height:24px}`。
    public static let actionHeight: CGFloat = 24
    /// 动作按钮左右的内边距。稿子：`padding:0 8px` —— 宽度由文字宽度加它组成。
    public static let actionHorizontalPadding: CGFloat = 8
    /// 两个动作之间的间隙。稿子：`.rt__acts{gap:2px}`。
    public static let actionGap: CGFloat = 2
    public static let actionCornerRadius: CGFloat = 6

    // MARK: - 底部那一行（免费版才有）

    /// 底部高。稿子：「30 高」。
    public static let footerHeight: CGFloat = 30
    public static let footerPadding: CGFloat = 10
    /// 底部那三段（"免费版只保留最近 5 张" · "升级到 Pro" "可保留全部"）之间的间隙。
    public static let footerGap: CGFloat = 4

    // MARK: - 空态

    /// 空态块高。稿子：「120 高（面板总高 184）」。
    public static let emptyBlockHeight: CGFloat = 120
    /// 取景框图标的大小。稿子：`svg{width:26px;height:26px}`。
    public static let emptyIconSize: CGFloat = 26
    public static let emptyGap: CGFloat = 8

    /// 空态那枚图标。
    ///
    /// ⚠️ **必须是语言无关的符号**：SF Symbol 里有一批会自动本地化，
    /// 中文环境下会变成汉字（`textformat` → 「格式」两个字）。
    /// 覆盖层工具条已经踩过这个坑（`docs/PITFALLS.md` 28）。
    public static let emptyIconSymbol = "viewfinder"

    // MARK: - 尺寸算式

    /// 列表宽（行都排在这条宽度里）。
    public static var listWidth: CGFloat { width - listPadding * 2 }

    /// 列表区的高度。
    ///
    /// ⚠️ 空态与有内容是**两块不同高度的东西**：没有条目时不是"0 行"，
    /// 而是一块 120 高的空态。写成 `count × 46` 的话，
    /// 空面板会变成一个只剩标题带的窄条 —— 而它看起来像没加载出来。
    public static func bodyHeight(rowCount: Int) -> CGFloat {
        rowCount == 0 ? emptyBlockHeight : CGFloat(rowCount) * rowHeight
    }

    /// 面板总高。
    ///
    /// = 标题带 + 列表 + 底部（免费版才有）+ **上下各 1 点描边**。
    /// 稿子给了三个数：满 12 行 618 / 空态 186 / 已购买满 12 行 588 —— 三个都在这条算式上。
    public static func panelHeight(rowCount: Int, showsFooter: Bool) -> CGFloat {
        titleBarHeight
            + bodyHeight(rowCount: rowCount)
            + (showsFooter ? footerHeight : 0)
            + borderWidth * 2
    }

    /// 在给定的可用高度里，最多能**完整**放下几行。
    ///
    /// ## 为什么要它，而不是加滚动条
    ///
    /// 稿子原话：「618 pt 在任一 Mac 上放得下，所以**不需要滚动条** ——
    /// 一个不会滚动的东西，看起来就不像图库。」
    /// 滚动条在这里不只是多一个控件：它是"这是图库"的第一个信号。
    ///
    /// 所以放不下时**减少行数**，而不是让它滚。
    /// 下限是 1：一个"有内容却一行都不显示"的面板比越屏更糟，
    /// 而这条下限在实际屏幕上永远不会触发（最低支持的屏幕内容高也远大于 46 + 34 + 30）。
    public static func visibleRowCount(available: CGFloat, showsFooter: Bool) -> Int {
        let chrome = titleBarHeight + (showsFooter ? footerHeight : 0) + borderWidth * 2
        let room = available - chrome
        guard room > 0 else { return 1 }
        return min(maximumRows, max(1, Int(room / rowHeight)))
    }

    /// 一个动作按钮的宽度：文字宽 + 左右各 8。
    public static func actionWidth(textWidth: CGFloat) -> CGFloat {
        textWidth + actionHorizontalPadding * 2
    }

    // MARK: - 就地升起的那张卡片

    /// 卡片下缘离面板下缘的距离。
    ///
    /// 稿子：`.card--inpanel{position:absolute;left:19px;bottom:44px}`。
    /// 它等于**底部那一行的 30 + 描边 1 + 再留 13** —— 也就是说卡片**不盖住底部那行**
    /// （那行上写着"免费版只保留最近 5 张"，正是这张卡片要解释的事）。
    ///
    /// 它是从底部往上量的，所以这里写成"面板下缘 + 44"。
    public static let upgradeCardBottomInset: CGFloat = 44

    /// 卡片上缘与面板上缘之间至少留的空隙。
    public static let upgradeCardTopMargin: CGFloat = 2

    /// 显示那张卡片时，面板**至少**要有这么高。
    ///
    /// ⚠️ 稿子说「点了才出现 —— **面板不变高**」。那句话在它画的那一屏上成立
    /// （满 12 行的面板 618 高，卡片只占底下一块）。
    /// 但行数少到装不下这张 140 高的卡片时（空态 186 / 一行 112），
    /// 两条路都不好：让卡片露到面板外面，或者把它压在标题带上。
    /// 取的是第三条 —— **面板长到刚好装下它**（空态那一档正好等于 186，不用长）。
    ///
    /// "卡片露在面板外面"是这里唯一不能接受的结果：它会盖住旁边的窗口内容，
    /// 而那看起来像渲染出错。
    public static var upgradeCardMinimumPanelHeight: CGFloat {
        // 最近截图面板里那处「就地升起」用的是**载体 B**（无微行，115 高）：
        // 那时没有选区，微行那句「选区保留」不成立。
        let card = ProCardLayout.size(includesMicro: false)
        return upgradeCardBottomInset + card.height + upgradeCardTopMargin
    }

    /// 「升级到 Pro」点下去之后就地升起的卡片放在哪（**面板局部坐标**）。
    ///
    /// 水平居中、下缘钉在上面那个 44 上 —— 两者都是判据，不是"看着差不多"：
    /// 偏一点会让卡片看起来是"贴歪了"，而它同时会**盖住底部那行说明**。
    ///
    /// 面板意外地矮时**向下让**（宁可盖住标题带，也不出面板）——
    /// 调用方本该先按 `upgradeCardMinimumPanelHeight` 把面板撑够，这里是那条不变量的兜底。
    public static func upgradeCardFrame(inPanel panel: CGRect) -> CGRect {
        let size = ProCardLayout.size(includesMicro: false)
        let ideal = panel.minY + upgradeCardBottomInset
        let lowest = panel.maxY - upgradeCardTopMargin - size.height
        let y = max(panel.minY + borderWidth, min(ideal, lowest))
        return CGRect(x: panel.midX - size.width / 2,
                      y: y,
                      width: size.width,
                      height: size.height)
    }

    // MARK: - 行的解剖

    /// 一行里那四段（加一枚徽章）的矩形。**全部是行局部坐标**。
    public struct RowLayout: Equatable, Sendable {
        /// 整行 —— 悬停底就铺这一块。
        public var row: CGRect
        /// 行内再缩 5 之后的内容区。
        public var content: CGRect
        public var thumbnail: CGRect
        /// 时间 + 尺寸那两行占的那一块。
        public var text: CGRect
        /// 第一行：时间。稿子：`font:400 12px/16px`。
        public var time: CGRect
        /// 第二行：尺寸（mono）。稿子：`font:500 11px/14px` + `margin-top:2px`。
        public var detail: CGRect
        /// 两个动作，**从右往左**数：`actions[0]` 是最右边那个（删除）。
        public var actions: [CGRect]
        /// 复制徽章（悬停 / 按下才画）。
        public var badge: CGRect
    }

    /// 排一行。
    ///
    /// - Parameter actionWidths: 两个动作各自的宽度（**由调用方量文字** ——
    ///   宽度取决于本地化之后的字，Core 不能瞎猜一个数）。
    ///   顺序与 `actions` 一致：先给最右边那个。
    public static func rowLayout(in row: CGRect, actionWidths: [CGFloat]) -> RowLayout {
        let content = row.insetBy(dx: rowPadding, dy: 0)

        // 缩略图：竖直居中
        let thumbnail = CGRect(x: content.minX,
                               y: content.midY - thumbnailSize.height / 2,
                               width: thumbnailSize.width,
                               height: thumbnailSize.height)

        // 两个动作：**从右往左**贴 right 缘排。顺序反过来的话，
        // 本地化把"编辑"变长时，右边那个（删除）会跟着往左移 —— 而它本该钉在右缘上。
        var actions: [CGRect] = []
        var cursor = content.maxX
        for width in actionWidths {
            let box = CGRect(x: cursor - width,
                             y: content.midY - actionHeight / 2,
                             width: width,
                             height: actionHeight)
            actions.append(box)
            cursor = box.minX - actionGap
        }

        // 文字：吃掉缩略图与动作之间剩下的全部宽度
        let textMinX = thumbnail.maxX + rowGap
        let textMaxX = (actions.last?.minX ?? content.maxX) - rowGap
        let text = CGRect(x: textMinX,
                          y: content.minY,
                          width: max(0, textMaxX - textMinX),
                          height: content.height)

        // 两行字：**整块竖直居中**，块内第一行在上、第二行在下（差 2 点）。
        //
        // 按"第一行贴顶"排是更顺手的写法，但那样两行字会顶在行的上边、
        // 下面空出一大块 —— 而它看起来只是"这行有点偏"。整块居中的判据能写成断言。
        let blockHeight = timeLineHeight + rowDetailGap + detailLineHeight
        let blockTop = text.midY + blockHeight / 2
        let time = CGRect(x: text.minX, y: blockTop - timeLineHeight,
                          width: text.width, height: timeLineHeight)
        let detail = CGRect(x: text.minX, y: blockTop - blockHeight,
                            width: text.width, height: detailLineHeight)

        // 徽章：**外扩**在缩略图右上角之外 5 点。
        //
        // 稿子特意交代了它的位置理由：「放在图面正中会挡内容，放在行尾会被误读成第三个动作」。
        // `top:-5px;right:-5px` 换算过来就是"右上角往外各 5 点" —— 于是它
        // **压在行内边距里**：右边不会顶到文字（还差 5 点），上边不会出到行外（还差 1 点）。
        let badge = copyBadgeInThumbnail.offsetBy(dx: thumbnail.minX, dy: thumbnail.minY)

        return RowLayout(row: row,
                         content: content,
                         thumbnail: thumbnail,
                         text: text,
                         time: time,
                         detail: detail,
                         actions: actions,
                         badge: badge)
    }
}

// MARK: - 文案
//
// ⚠️ 这几句**必须**放 Core：它们有的要参与判据（空态那句里的快捷键要跟着配置走），
// 有的要被测试当数据遍历（底部的三段拼起来才是一句话）。
// 留在视图里的话，"文案对不对"就只剩肉眼一条路。

public extension RecentPanel {

    /// 标题带右侧那行常驻小字。
    ///
    /// 稿子：「标题带 左『最近截图』，右一行常驻小字『点缩略图 = 复制』」，
    /// 而**空态时它不出现** —— 那时没有缩略图可以点，写在那儿只会让人去找一个不存在的东西。
    static var copyHint: String { L10n.t("点缩略图 = 复制") }

    static var emptyTitle: String { L10n.t("还没有截图") }

    /// 空态第二句。**带着当前快捷键**。
    ///
    /// 稿子 §02：「同一个 ⌃Q，出现在三个地方，只有一个来源」——
    /// 菜单里那行、这里这句、偏好里那个录制器，三处读的是同一份配置。
    /// 写死 `⌃Q` 的话，用户改过键之后这句话就成了一句**反话**：
    /// 他照着按，什么都不会发生。
    static func emptySubtitle(shortcut: KeyCombo) -> String {
        L10n.t("按 \(shortcut.displayString) 截第一张")
    }

    // MARK: 底部那一行（免费版才有）

    /// 底部第一段：配额说明。
    ///
    /// ⚠️ 数字取**当前真实上限**（`CaptureHistoryStore.limit`），不是稿子示意图里那个 12 ——
    /// 稿子里 12 既是"最多显示 12 行"也是它当时假设的免费配额，而我们的免费配额是 5。
    /// 写死 12 的话，用户会数着列表里的条数发现对不上。
    static func footerPrefix(limit: Int) -> String {
        L10n.t("免费版只保留最近 \(limit) 张")
    }

    /// 三段之间的分隔符。**不是文案**（它在两种语言里都是一个点）。
    // L10N-EXEMPT: 中点分隔符，两种语言里都是它
    static let footerSeparator = "·"

    /// 中间那一段 —— 唯一可点的词。稿子：「唯一的可点词是『升级到 Pro』（蓝）」。
    static var footerAction: String { L10n.t("升级到 Pro") }

    /// 最后一段。
    static var footerSuffix: String { L10n.t("可保留全部") }

    // MARK: 一行里的两行字

    /// 第一行：时间。
    ///
    /// 稿子：「时间写到分钟、不写『3 天前』；相对时间会让人算，绝对时间不用算。」
    ///
    /// ⚠️ 用 `dateFormatFromTemplate` 而不是写死一个格式串：模板让系统按语言排顺序
    /// （中文 `10月3日 18:47`、英文 `Oct 3 at 18:47`），写死的那个总有一边别扭。
    ///
    /// ⚠️ 模板里的 `d` 是**一个**：写成 `dd` 会得到 `10月03日`——
    /// 带前导零的那一版像机器编号，而稿子给的是 `10月3日`。
    /// `HH`（大写）也是刻意的：截图历史问的是"哪一张"，24 小时制不必再判上下午。
    public static func rowDate(_ date: Date,
                               locale: Locale = .current,
                               timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMMdHHmm",
                                                        options: 0,
                                                        locale: locale)
        return formatter.string(from: date)
    }

    /// 第二行：尺寸，有标注时追加数量。
    ///
    /// 稿子：「有标注时追加 · 3 个标注」，而「没有标注的行**不写**『0 个标注』
    /// （那是噪声，不是信息）」。
    public static func rowDetail(pixelSize: CGSize, annotationCount: Int) -> String {
        // ⚠️ 像素尺寸**先拼成字符串再进 `L10n.t`**，不能直接把 `Int` 插进去。
        // `L10n.t("\(1234)…")` 走的是 `String(localized:)` 的整数插值，
        // 它会按**当前语言**格式化数字 —— 中文下 `1234` 变成 **`1,234`**，
        // 于是这行会显示成「1,234×768 px」。那不是本地化，那是把尺寸读数写坏了：
        // 分辨率是一个**标识**，不是一个计数，任何语言下都不该有千位分隔符。
        // （这个错在中文开发机上当场就能看见，而它挂在"本地化"名下，很容易被当成正常。）
        let dimensions = "\(Int(pixelSize.width.rounded()))×\(Int(pixelSize.height.rounded()))"
        let size = L10n.t("\(dimensions) px")
        guard annotationCount > 0 else { return size }
        // 标注数**是**一个计数，那里按语言加分隔符是对的（1000 个标注 → `1,000`）。
        return L10n.t("\(size) · \(annotationCount) 个标注")
    }
}

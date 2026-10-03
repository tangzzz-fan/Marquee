import CoreGraphics
import Foundation
import Testing

@testable import MarqueeCore

/// 最近截图面板的几何与文案（设计稿第 2 轮 D 块）。
@Suite("最近截图面板（几何与文案）")
struct RecentPanelTests {

    // MARK: - 面板高度

    @Test("三种面板高度都对得上稿子：满 12 行 618 · 空态 186 · 已购买满 12 行 588")
    func panelHeightsMatchSpec() {
        // 稿子 §01 那三个数是**互相印证**的：只要有一处少算了描边或底部，
        // 就会有一个对不上。所以三个一起钉，而不是只钉一个。
        #expect(RecentPanel.panelHeight(rowCount: 12, showsFooter: true) == 618,
                "34 + 12×46 + 30 + 2 = 618")
        #expect(RecentPanel.panelHeight(rowCount: 0, showsFooter: true) == 186,
                "空态块 120 而不是 0 行：34 + 120 + 30 + 2 = 186")
        #expect(RecentPanel.panelHeight(rowCount: 12, showsFooter: false) == 588,
                "已购买时底部整条消失：34 + 12×46 + 2 = 588")
    }

    @Test("空态不是「0 行」—— 它是另一块 120 高的东西")
    func emptyIsItsOwnBlock() {
        // 这条单独写出来，是因为把空态当成"0 行"是最自然的写法，
        // 而它的表现是：面板缩成一条只剩标题带的窄条（看起来像没加载出来）。
        #expect(RecentPanel.bodyHeight(rowCount: 0) == RecentPanel.emptyBlockHeight)
        #expect(RecentPanel.bodyHeight(rowCount: 0) != 0)
        #expect(RecentPanel.bodyHeight(rowCount: 1) == RecentPanel.rowHeight)
        #expect(RecentPanel.bodyHeight(rowCount: 12) == 12 * RecentPanel.rowHeight)
    }

    @Test("底部那一行只在免费版出现 —— 有它没它差 30")
    func footerIsOptional() {
        let with = RecentPanel.panelHeight(rowCount: 3, showsFooter: true)
        let without = RecentPanel.panelHeight(rowCount: 3, showsFooter: false)
        #expect(with - without == RecentPanel.footerHeight)
    }

    // MARK: - 放不下时减少行数（而不是加滚动条）

    @Test("618 点的高度正好装下 12 行 —— 那是稿子说的「任一 Mac 上都放得下」")
    func twelveRowsFitIn618() {
        #expect(RecentPanel.visibleRowCount(available: 618, showsFooter: true) == 12)
        // 少一点就得让一行：617 只差 1 点，但那一行是真的放不下
        #expect(RecentPanel.visibleRowCount(available: 617, showsFooter: true) == 11)
        // 已购买（没有底部）时同样 12 行只需要 588
        #expect(RecentPanel.visibleRowCount(available: 588, showsFooter: false) == 12)
    }

    @Test("可用高度变小就少显示几行，而且**永远不超过 12**")
    func visibleRowsShrinkWithHeight() {
        // 稿子给的是"不需要滚动条"：放不下时减少行数，而不是让它滚 ——
        // 「一个不会滚动的东西，看起来就不像图库」。
        for available in [400.0, 500.0, 700.0, 1200.0] {
            let rows = RecentPanel.visibleRowCount(available: available, showsFooter: true)
            #expect(rows <= RecentPanel.maximumRows, "\(available) 点里算出了 \(rows) 行")
            // 算出来的行数必须**真的装得下**：多一行就溢出
            let used = RecentPanel.panelHeight(rowCount: rows, showsFooter: true)
            #expect(used <= available, "\(available) 点里排出 \(rows) 行 = \(used) 点，放不下")
        }
        #expect(RecentPanel.visibleRowCount(available: 400, showsFooter: true) == 7)
    }

    @Test("可用高度离谱地小时，下限是 1 行 —— 而不是 0")
    func visibleRowsHaveAFloor() {
        // 一个"有内容却一行都不显示"的面板比越屏更糟：用户会以为历史被清空了。
        // 实际屏幕上永远不会走到这里（最低支持的屏幕内容高也远大于 34+30+46），
        // 但算式得有个底。
        #expect(RecentPanel.visibleRowCount(available: 10, showsFooter: true) == 1)
        #expect(RecentPanel.visibleRowCount(available: 0, showsFooter: false) == 1)
        #expect(RecentPanel.visibleRowCount(available: -50, showsFooter: true) == 1)
    }

    // MARK: - 行的解剖

    private func layout(actionWidths: [CGFloat] = [40, 40]) -> RecentPanel.RowLayout {
        RecentPanel.rowLayout(in: CGRect(x: RecentPanel.listPadding,
                                         y: 100,
                                         width: RecentPanel.listWidth,
                                         height: RecentPanel.rowHeight),
                              actionWidths: actionWidths)
    }

    @Test("四段宽度之和**正好**等于行的内容宽 —— 不多不少")
    func segmentsFillTheRowExactly() {
        let l = layout()
        let width = l.thumbnail.width
            + RecentPanel.rowGap + l.text.width
            + RecentPanel.rowGap + l.actions.reduce(0) { $0 + $1.width }
            + CGFloat(l.actions.count - 1) * RecentPanel.actionGap
        #expect(abs(width - l.content.width) < 0.001,
                "四段加起来 \(width)，内容宽 \(l.content.width) —— 差出来的那点会把文字挤掉或留一条缝")
    }

    @Test("缩略图贴左缘、动作贴右缘，文字吃掉中间")
    func anchorsAreOnTheRightEdges() {
        let l = layout()
        #expect(l.thumbnail.minX == l.content.minX)
        #expect(l.actions.first?.maxX == l.content.maxX, "最右边那个动作必须钉在右缘上")
        #expect(l.text.minX == l.thumbnail.maxX + RecentPanel.rowGap)
        #expect(l.text.maxX == (l.actions.last?.minX ?? 0) - RecentPanel.rowGap)
    }

    @Test("动作**从右往左**排：给的第一段宽就是最右边那个")
    func actionsAreLaidOutFromTheRight() {
        // 顺序反过来的话，本地化把「编辑」变长时，右缘那个（删除）会跟着往左移 ——
        // 而它本该钉在右缘上。这种错只在英文界面上看得出来。
        let l = layout(actionWidths: [60, 30])
        #expect(l.actions.count == 2)
        #expect(l.actions[0].width == 60, "先给的那个是最右边的")
        #expect(l.actions[0].maxX == l.content.maxX)
        #expect(l.actions[1].maxX == l.actions[0].minX - RecentPanel.actionGap)
    }

    @Test("两段间距与高度都按稿子：动作 24 高、间距 2")
    func actionMetrics() {
        let l = layout()
        #expect(l.actions.allSatisfy { $0.height == RecentPanel.actionHeight })
        #expect(l.actions.allSatisfy { $0.midY == l.row.midY }, "动作要竖直居中")
        #expect(l.thumbnail.midY == l.row.midY, "缩略图也要竖直居中")
    }

    // MARK: - 复制徽章

    @Test("徽章外扩在缩略图右上角之外 5 点，而且行里与缩略图里量出来是**同一个位置**")
    func badgeSitsOutsideTheCorner() {
        let l = layout()
        #expect(l.badge.maxX == l.thumbnail.maxX + RecentPanel.copyBadgeOffset)
        #expect(l.badge.maxY == l.thumbnail.maxY + RecentPanel.copyBadgeOffset)
        #expect(l.badge.size == CGSize(width: RecentPanel.copyBadgeSize,
                                       height: RecentPanel.copyBadgeSize))
        // ⚠️ 缩略图是一件**独立视图**，它在自己的坐标系里画那枚徽章。
        // 算式写两份的话，"命中区量出来的位置"与"画出来的位置"迟早会分叉 ——
        // 表现是"徽章看着在那儿，点它却没反应"，而那种偏差只有几点。
        #expect(l.badge == RecentPanel.copyBadgeInThumbnail.offsetBy(dx: l.thumbnail.minX,
                                                                    dy: l.thumbnail.minY))
    }

    @Test("徽章整枚落在行里，而且**不撞上文字**")
    func badgeStaysInsideAndClearOfText() {
        // 两个都要紧：出到行外会被相邻行的发丝线切开（46 高的行只剩 1 点余量），
        // 撞到文字就等于盖住了时间。
        let l = layout()
        #expect(l.row.contains(l.badge), "徽章出到行外了：\(l.badge) 不在 \(l.row) 里")
        #expect(!l.badge.intersects(l.text), "徽章压住文字了")
        // 那条 1 点的余量是稿子定的（行 46、缩略图 34 居中、徽章外扩 5 ⇒ 上边剩 1）——
        // 万一谁把行高改小，这里会红。
        #expect(l.row.maxY - l.badge.maxY >= 1)
    }

    // MARK: - 缩略图的形状

    @Test("缩略图要同时容得下 16:10 与 4:3 —— 比例落在两者之间")
    func thumbnailRatioIsACompromise() {
        // 稿子：「固定 48 × 34，纵横比不逐张跟随（否则每行高矮不一）；
        // 过长的图居中裁切」。48/34 ≈ 1.41，正好夹在 4:3（1.333）与 16:10（1.6）之间。
        let ratio = RecentPanel.thumbnailSize.width / RecentPanel.thumbnailSize.height
        #expect(ratio > 4.0 / 3.0, "比 4:3 还窄 —— 4:3 的图两边会被裁掉")
        #expect(ratio < 16.0 / 10.0, "比 16:10 还宽 —— 16:10 的图会留黑边")
        #expect(RecentPanel.thumbnailSize == CGSize(width: 48, height: 34))
    }

    // MARK: - 两个 5

    @Test("行的 5 与列表的 5 是两个数，都不能省")
    func twoInsetsBothExist() {
        // 列表那 5 让**悬停底**离面板边 5 点（不然悬停时会贴到边上，像一块色斑）；
        // 行自己那 5 让**缩略图**离面板边 10 点（那是视觉上的左缘）。
        // 只留一个的话两者必错其一，而"差 5 点"靠肉眼看不出来。
        #expect(RecentPanel.listPadding == 5)
        #expect(RecentPanel.rowPadding == 5)
        #expect(RecentPanel.listWidth == RecentPanel.width - RecentPanel.listPadding * 2)
        // 一行排完之后，缩略图离面板左缘正好是 10
        let l = layout()
        #expect(l.thumbnail.minX == RecentPanel.listPadding + RecentPanel.rowPadding)
    }

    // MARK: - 一行里的两行字

    @Test("时间写到分钟，而且按语言排顺序 —— 不写「3 天前」")
    func rowDateIsAbsolute() {
        // 2026-10-03 18:47 Asia/Shanghai
        let date = Date(timeIntervalSince1970: 1_791_024_420)
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let zh = RecentPanel.rowDate(date, locale: Locale(identifier: "zh_CN"), timeZone: zone)
        // 与稿子那张图上的字**逐字相同**（`10月03日` 那种带前导零的变体是另一版）
        #expect(zh == "10月3日 18:47", "实际：\(zh)")
        #expect(!zh.contains("天"), "相对时间会让人算 —— 稿子明确不要：\(zh)")

        let en = RecentPanel.rowDate(date, locale: Locale(identifier: "en_US"), timeZone: zone)
        #expect(en.contains("Oct") && en.contains("18:47"),
                "英文该按自己的语言排（`Oct 3 at 18:47`）：\(en)")
        #expect(!en.contains("10月"), "英文界面下不该出现中文：\(en)")
    }

    @Test("没有标注的行**不写**「0 个标注」——那是噪声")
    func rowDetailOmitsZeroAnnotations() {
        let size = CGSize(width: 1234, height: 768)
        let plain = RecentPanel.rowDetail(pixelSize: size, annotationCount: 0)
        #expect(plain == "1234×768 px")
        // ⚠️ 分辨率是**标识**不是计数：任何语言下都不该有千位分隔符。
        // 把 `Int` 直接插进 `L10n.t` 时，中文下会得到「1,234×768 px」——
        // 而它挂在"本地化"名下，很容易被当成正常。
        #expect(!plain.contains(","), "尺寸读数被本地化成千位分隔了：\(plain)")
        #expect(!plain.contains("，"), "尺寸读数被本地化了：\(plain)")
        #expect(!plain.contains("0 个标注"), "没标注时不写「0 个标注」")
        let withMarks = RecentPanel.rowDetail(pixelSize: size, annotationCount: 3)
        #expect(withMarks.contains("1234×768 px"))
        #expect(withMarks.contains("3"), "有标注时必须标出来：\(withMarks)")
        // 尺寸要**取整**（1.5 倍屏上取到的宽高是 1234.0 这种小数）
        #expect(RecentPanel.rowDetail(pixelSize: CGSize(width: 1234.4, height: 767.6),
                                      annotationCount: 0) == "1234×768 px")
    }

    // MARK: - 文案

    @Test("空态那句带着**当前**快捷键 —— 三处一个来源")
    func emptySubtitleFollowsTheShortcut() {
        // 稿子 §02：「同一个 ⌃Q，出现在三个地方（菜单 / 空态 / 录制器），
        // 三处不是三个键，是同一个值的三个视图」。
        // 写死 ⌃Q 的话，用户改过键之后这句话就是一句**反话**。
        let defaultCombo = KeyCombo(keyCode: 12, modifiers: [.control], keyLabel: "Q")
        let other = KeyCombo(keyCode: 1, modifiers: [.shift, .command], keyLabel: "S")

        let first = RecentPanel.emptySubtitle(shortcut: defaultCombo)
        let second = RecentPanel.emptySubtitle(shortcut: other)

        #expect(first.contains(defaultCombo.displayString))
        #expect(second.contains(other.displayString))
        #expect(first != second, "换了键这句话必须跟着换 —— 否则它说的是一个按不出来的键")
        #expect(!RecentPanel.emptyTitle.isEmpty)
    }

    @Test("底部三段拼起来是完整一句，而中间那段是唯一可点的词")
    func footerPiecesCompose() {
        let prefix = RecentPanel.footerPrefix(limit: 5)
        #expect(prefix.contains("5"), "配额数字要取**当前**上限，不是稿子示意图里的 12：\(prefix)")

        let sentence = prefix + RecentPanel.footerSeparator
            + RecentPanel.footerAction + RecentPanel.footerSuffix
        #expect(!RecentPanel.footerAction.isEmpty)
        #expect(!RecentPanel.footerSuffix.isEmpty)
        #expect(!sentence.contains("%"), "拼完之后还剩格式符：\(sentence)")
        // 三段必须互不相同，否则"唯一那个可点的词"就无从谈起
        #expect(Set([prefix, RecentPanel.footerAction, RecentPanel.footerSuffix]).count == 3)
    }

    @Test("标题带那行小字与空态标题都是真文案，不是空串")
    func basicStringsAreNotEmpty() {
        #expect(!RecentPanel.copyHint.isEmpty)
        #expect(!RecentPanel.emptyTitle.isEmpty)
        #expect(!RecentPanel.emptyIconSymbol.isEmpty)
        // 图标名必须是**语言无关**的符号（`textformat` 那种中文下会变成汉字）
        #expect(RecentPanel.emptyIconSymbol == "viewfinder")
    }

    // MARK: - 行里那两行字

    @Test("两行字**整块**竖直居中，块内第一行在上、差 2 点")
    func textBlockIsCentered() {
        let l = layout()
        #expect(l.time.height == RecentPanel.timeLineHeight)
        #expect(l.detail.height == RecentPanel.detailLineHeight)
        #expect(l.time.minY == l.detail.maxY + RecentPanel.rowDetailGap)
        // 整块居中：上下留白相等
        let above = l.text.maxY - l.time.maxY
        let below = l.detail.minY - l.text.minY
        #expect(abs(above - below) < 0.001, "整块没居中：上 \(above) 下 \(below)")
        // 而且整块必须装得进行里（改大了行高就会红）
        #expect(l.time.maxY <= l.text.maxY)
        #expect(l.detail.minY >= l.text.minY)
    }

    @Test("两行字都从文字的**左缘**开始 —— 不缩进")
    func bothLinesShareTheLeftEdge() {
        let l = layout()
        #expect(l.time.minX == l.text.minX)
        #expect(l.detail.minX == l.text.minX)
    }

    // MARK: - 就地在面板里升起的卡片

    @Test("升起的卡片水平居中，而且**不盖住底部那行说明**")
    func upgradeCardSitsCenteredAboveTheFooter() {
        // 底部那行上写着"免费版只保留最近 5 张" —— 那正是这张卡片要解释的事，
        // 盖住它等于把话说到一半捂上嘴。
        let panel = CGRect(x: 20, y: 300, width: RecentPanel.width,
                           height: RecentPanel.panelHeight(rowCount: 12, showsFooter: true))
        let card = RecentPanel.upgradeCardFrame(inPanel: panel)

        #expect(card.midX == panel.midX, "卡片没水平居中")
        #expect(card.minY - panel.minY == RecentPanel.upgradeCardBottomInset)
        #expect(card.minY >= panel.minY + RecentPanel.footerHeight + RecentPanel.borderWidth,
                "卡片压到底部那行上了")
        #expect(panel.contains(card), "卡片跑到面板外面了")
    }

    @Test("装不下这张卡片的面板必须被撑够 —— 否则它会露到面板外面")
    func cardMinimumPanelHeightIsEnough() {
        // 稿子说"面板不变高"，那是在它画的满 12 行那一屏上成立。
        // 行数少时（空态 / 一两行）必须撑到装得下 —— 让卡片露到面板外面是唯一不能接受的结果。
        let needed = RecentPanel.upgradeCardMinimumPanelHeight
        #expect(needed > 0)
        // 空态那一档本来就高过它（装得下还得有余量）——
        // ⚠️ 这条原先写的是 `== needed`，那是**照着当时的数**写的：
        // 卡片从 140 变成 115（去掉微行，稿子 §04）之后它就红了。
        // 「空态装得下」才是那条不变量，等号只是当时恰好成立。
        #expect(RecentPanel.panelHeight(rowCount: 0, showsFooter: true) >= needed,
                "空态那一档装不下这张卡片了")
        // 三行往上就不用撑了
        #expect(RecentPanel.panelHeight(rowCount: 3, showsFooter: true) > needed)
        // 一两行必须撑
        #expect(RecentPanel.panelHeight(rowCount: 1, showsFooter: true) < needed)
        #expect(RecentPanel.panelHeight(rowCount: 2, showsFooter: true) < needed)

        for rows in 0...12 {
            let natural = max(RecentPanel.panelHeight(rowCount: rows, showsFooter: true), needed)
            let panel = CGRect(x: 0, y: 0, width: RecentPanel.width, height: natural)
            let card = RecentPanel.upgradeCardFrame(inPanel: panel)
            #expect(panel.contains(card), "\(rows) 行时卡片露到面板外面：\(card)")
        }
    }

    @Test("面板意外地矮时，卡片往里让而不是出面板")
    func upgradeCardNeverEscapesATinyPanel() {
        // 正常路径上撑高那一步会拦住这种情况，但算式自己也不该能算出"卡片在面板外"。
        let tiny = CGRect(x: 0, y: 0, width: RecentPanel.width, height: 60)
        let card = RecentPanel.upgradeCardFrame(inPanel: tiny)
        #expect(card.minX >= tiny.minX && card.maxX <= tiny.maxX, "横向出界了")
        #expect(card.minY >= tiny.minY, "往下跑出面板了")
    }
}

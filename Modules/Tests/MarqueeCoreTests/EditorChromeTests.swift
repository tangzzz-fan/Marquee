import CoreGraphics
import Foundation
import Testing

@testable import MarqueeCore

/// 编辑器窗口的几何与状态行（设计稿第 3 轮 B 块）。
@Suite("编辑器窗口（几何与状态行）")
struct EditorChromeTests {

    // MARK: - 窗口

    @Test("窗口 1200 × 760；画布 = 剩下的全部")
    func windowAndCanvas() {
        // 稿子 §03：「整窗 1200 × 760」。
        #expect(EditorChrome.defaultWindowSize == CGSize(width: 1200, height: 760))

        // ⚠️ 稿子把画布写成 688（48 + 688 + 22 = 758，差 2）。
        // 那 2 点是它把工具条的 1px 下边线与状态行的 1px 上边线**各算了一次** ——
        // 那两条线本来就画在 48 与 22 里面。
        // 所以画布取"剩下的全部"，它才是这扇窗存在的理由。
        #expect(EditorChrome.canvasHeight(windowHeight: 760)
                    == 760 - EditorChrome.toolbarHeight - EditorChrome.statusLineHeight)
        #expect(EditorChrome.canvasHeight(windowHeight: 760) == 690)
        // 窗口再矮也不会算出 0 或负数（否则画布那层约束会崩）
        #expect(EditorChrome.canvasHeight(windowHeight: 10) >= 1)
    }

    @Test("工具条 48 是**跟着最高的那件长出来的**：48 = 5 + 38 + 5")
    func toolbarHeightIsDerivedFromItsTallest() {
        // 稿子 §10 把这条列为"登记过的改动"：40 → 48。
        // 写成推导式而不是两个独立的数 —— 哪天尺寸芯片涨到 40，
        // 条高会跟着涨（而不是芯片被裁掉半截）。
        #expect(EditorChrome.toolbarHeight
                    == EditorChrome.toolbarPadding * 2 + EditorChrome.chipSize.height)
        #expect(EditorChrome.toolbarHeight == 48)
        // 托盘比芯片矮，所以它不该决定条高
        #expect(EditorChrome.traySize.height < EditorChrome.chipSize.height)
    }

    // MARK: - 整条工具条放得下

    @Test("整条工具条放得进窗口宽度 —— 放不下就会把最右边那几格裁掉")
    func toolbarFitsInTheWindow() {
        // 这一条是编辑器版的「整条必须放得进 1024 点的屏」（覆盖层那条）。
        // 编辑器里它不是崩溃也不是报错：`HStack` 的 `Spacer` 会先缩成 0，
        // 然后右边那几格被**直接裁掉** —— 历史上有过一次，
        // 用户报的是「OCR 入口我不知道在哪」（其实压根没画出来）。
        let required = EditorChrome.minimumToolbarWidth()
        #expect(required <= EditorChrome.defaultWindowSize.width,
                "整条要 \(required) 点，而窗口只有 \(EditorChrome.defaultWindowSize.width)")
        // ⚠️ 还要一个**下限**：上面那条只保证"别超"，而算式里**少算一项**会让它变得更容易通过 ——
        // 那条断言于是成了假话（"放得下"是因为我们根本没把那一项算进去）。
        // 1146 是这个算式当前的答案，1100 这个下限能拦住任何**成组的**漏算
        //（漏掉托盘 −174、漏掉右簇 −222 都会当场红）。
        #expect(required > 1100, "整条的宽度预算少了一项：算出来只有 \(required)")
        // 窗口下限也必须放得下它 —— 否则用户一缩窄就丢按钮
        #expect(EditorChrome.minimumWindowSize.width >= required)
        #expect(EditorChrome.minimumWindowSize.width <= EditorChrome.defaultWindowSize.width)
    }

    @Test("托盘 174 = 内边距 6 ×2 + 色块 22 ×6 + 间隙 6 ×5")
    func trayWidthIsDerived() {
        // 稿子 §04：「托盘 174 × 34（④ 的 .tray 逐字）」。
        // 这个 174 是**六个色块 + 内外边距**加出来的，不是量出来的 ——
        // 所以写成算式：改色块大小、加一个颜色，条宽自动跟上。
        #expect(EditorChrome.traySize.width
                    == EditorChrome.swatchSize * 6 + EditorChrome.swatchGap * 5 + 6 * 2)
        #expect(EditorChrome.traySize.width == 174)
    }

    @Test("一条分组竖线的占宽 = 两侧间隙 + 线自己左右的余量")
    func separatorWidthAddsUp() {
        // 稿子：`.vsep{width:1px;h:18px;margin:0 6px}` 而 `.ebar{gap:2px}` ——
        // 于是它实际吃掉 2+6+1+6+2 = 17 点。把 17 写死的话，
        // 哪天线的余量改了，条的宽度预算就少算或超算。
        #expect(EditorChrome.separatorWidth
                    == EditorChrome.toolbarGap * 2 + EditorChrome.separatorMargin * 2
                    + EditorChrome.separatorSize.width)
        #expect(EditorChrome.separatorWidth == 17)
    }

    @Test("红绿灯那一簇让出 72 点 —— 那是系统画的三颗，我们只能让位")
    func trafficLightsReserve() {
        // 稿子：`.tls{gap:8px;padding:0 12px 0 8px}` + 三颗 12 点的灯。
        // 8 + (12+8) + (12+8) + 12 + 12 = 72。
        #expect(EditorChrome.trafficLightsWidth == 72)
        // 至少要比三颗灯本身宽 —— 否则我们会去盖住它们
        #expect(EditorChrome.trafficLightsWidth > 3 * 12 + 2 * 8)
    }

    @Test("`✗` 前让开 8 点：取消与完成压在整条最右，但取消不该挨着别的东西")
    func cancelHasItsOwnGap() {
        #expect(EditorChrome.gapBeforeCancel == 8)
        // 让开的距离要**看得出来**（小于 4 点等于没有），但也别夸张到像换了一组
        #expect(EditorChrome.gapBeforeCancel >= 4)
        #expect(EditorChrome.gapBeforeCancel < EditorChrome.cellSize)
    }

    @Test("分组就是那六件，顺序即从左到右")
    func groupOrder() {
        // 顺序写死在枚举里，视图按它排 —— 散在视图里的 `HStack` 顺序
        // 是"改一处忘三处"的老家。
        #expect(EditorChrome.ToolbarGroup.allCases
                    == [.annotationTools, .crop, .colorTray, .sizeChips, .zoom, .actions])
        // 八个标注工具 + 第九格裁切 = brief 的九个工具，到顶
        #expect(EditorChrome.annotationToolCount == 8)
        #expect(EditorChrome.annotationToolCount + 1 == 9, "brief：工具 ≤ 9，而上限就是 9")
    }

    // MARK: - 状态行

    @Test("常态：说这张图是什么，尺寸**不许带千位分隔符**")
    func statusLeadingNormal() {
        let size = CGSize(width: 1440, height: 2000)
        let withSegments = EditorChrome.leading(pixelSize: size, segments: 4, mode: .normal)
        #expect(withSegments == "长截图 · 1440 × 2000 px · 4 段拼接")

        // ⚠️ 分辨率是**标识**不是计数：`String(localized:)` 的整数插值会按语言加分隔符，
        // 而 `1,440 × 2,000 px` 不是我们想说的事（上一批在最近截图面板里踩过一次）。
        #expect(!withSegments.contains(","), "尺寸被本地化成千位分隔了：\(withSegments)")
        #expect(!withSegments.contains("，"))
    }

    @Test("不知道拼了几段时不编一个数，也不留一个孤零零的分隔符")
    func statusLeadingWithoutSegments() {
        let size = CGSize(width: 800, height: 600)
        let plain = EditorChrome.leading(pixelSize: size, segments: nil, mode: .normal)
        #expect(plain == "长截图 · 800 × 600 px")
        #expect(!plain.hasSuffix("·"), "末尾挂了一个没有下文的「·」：\(plain)")
        #expect(!plain.contains("段拼接"))

        // 一段不算"拼接" —— 写「1 段拼接」等于告诉用户一件他没问过的事
        let single = EditorChrome.leading(pixelSize: size, segments: 1, mode: .normal)
        #expect(single == plain)
    }

    @Test("裁切进行中：状态行换成**模式动词**，两张脸不一样")
    func statusLeadingDuringCrop() {
        let size = CGSize(width: 800, height: 600)
        let waiting = EditorChrome.leading(pixelSize: size, segments: nil, mode: .croppingWaitingForFrame)
        let adjusting = EditorChrome.leading(pixelSize: size, segments: nil, mode: .croppingAdjusting)

        // 两句话都要说清"现在干什么"和"怎么出去"
        for text in [waiting, adjusting] {
            #expect(text.contains("裁剪中"), "裁切中必须说出来：\(text)")
            #expect(text.contains("Esc"), "没给出路：\(text)")
        }
        #expect(waiting.contains("拖出保留框"), "还没框的时候要教他拖：\(waiting)")
        #expect(adjusting.contains("⏎"), "有框之后要说 ⏎ 能应用：\(adjusting)")
        #expect(waiting != adjusting, "框拖出来前后说了同一句 —— 用户不知道什么时候可以按 ⏎")
        // 那时不该再报尺寸：画布上的读数框正在说"裁完多大"（判断 4）
        #expect(!adjusting.contains("px"))
    }

    @Test("「适应窗口」四个字只在**真的**是适应窗口时才出现")
    func statusTrailing() {
        // 稿子 §03 画的是「适应窗口 34%」，而键盘那一表写着「点百分数回到适应窗口」——
        // 也就是说用户手动缩过之后，那四个字就成了替过去的状态说话。
        let fitted = EditorChrome.trailing(zoomPercent: 34, isFitted: true)
        #expect(fitted.contains("适应窗口"))
        #expect(fitted.contains("34%"))

        let manual = EditorChrome.trailing(zoomPercent: 34, isFitted: false)
        #expect(manual == "34%")
        #expect(!manual.contains("适应窗口"))

        // 两态在数字相同时也必须不同 —— 否则这条判据等于没有
        #expect(fitted != manual)
    }
}

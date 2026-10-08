import CoreGraphics
import Foundation
import Testing

@testable import MarqueeCore

/// 编辑器里那台**裁切读数框**（设计稿 §07 c 的登记项）。
///
/// ## 它为什么值得单测
///
/// 它是"破坏性操作"的**提前告知**：还不等按 `⏎`，用户就该看到裁完会小多少。
/// 而它的几何一旦算错，表现是**悄悄压住保留框**或**跑出画布** ——
/// 两种情况都不崩不报错，只是那块信息看不见了。
@Suite("裁切读数框（编辑器）")
struct CropReadoutTests {

    /// 画布（= 窗口减掉工具条与状态行）。
    private let canvas = CGSize(width: 1200, height: 690)

    /// 一个居中的保留框。
    private let frame = CGRect(x: 100, y: 80, width: 400, height: 300)

    @Test("132 × 44 —— 与覆盖层那个读数框是同一件（稿子：逐字 ④）")
    func sizeMatchesDesign() {
        #expect(CropReadout.minimumSize == CGSize(width: 132, height: 44))
        // 与覆盖层那份共用同一个数：两处各写一个，迟早有一处不是这个数
        #expect(CropReadout.minimumSize == OverlayReadout.minimumSize)
        // 稿子「逐字 ④」还包括行阶：第一行 13 点、第二行 11 点
        #expect(CropReadout.primaryFontSize == OverlayReadout.primaryFontSize)
        #expect(CropReadout.secondaryFontSize == OverlayReadout.secondaryFontSize)
    }

    @Test("框**至少** 132 宽，内容更长就长出去 —— 高度不变")
    func sizeGrowsWithContent() {
        // 窄内容不许把框缩小：那是"同一块框换内容"的物理前提
        #expect(CropReadout.size(textWidth: 40) == CropReadout.minimumSize)
        #expect(CropReadout.size(textWidth: 0) == CropReadout.minimumSize)

        // 长内容必须放得下。长截图的第二行可能是 `原图 1440 × 12000 px`（五位数字），
        // 而 132 的内宽只有 116 —— 写死宽度会把最后几位**静默裁掉**，
        // 而那几个数字正是这个问题的答案。
        let wide = CropReadout.size(textWidth: 150)
        #expect(wide.width == 150 + OverlayReadout.textPadding.width * 2)
        #expect(wide.height == CropReadout.minimumSize.height, "高度不该跟着变：两行永远是两行")

        // 撑开之后再算位置：框变宽了，夹取也必须跟着用新的宽度
        let tall = CropReadout.lines(crop: CGSize(width: 1440, height: 12000),
                                     original: CGSize(width: 1440, height: 12000))
        #expect(tall.headline == "1440 × 12000 px")
    }

    @Test("跟在保留框的右下外侧 —— 不压住框里的内容")
    func sitsOutsideBottomTrailing() {
        let rect = CropReadout.frame(cropFrame: frame, canvas: canvas)
        #expect(rect.size == CropReadout.minimumSize)
        #expect(rect.minX == frame.maxX + CropReadout.gap)
        #expect(rect.minY == frame.maxY + CropReadout.gap)

        // 意图：它说的是"框里剩多少"，压住框就是压住证据
        #expect(!rect.intersects(frame), "读数框压住了保留框：\(rect) vs \(frame)")
    }

    @Test("右下放不下就**翻到另一侧**，而不是被夹回来压住框")
    func flipsWhenNoRoom() {
        // 框贴着右下角
        let corner = CGRect(x: canvas.width - 60, y: canvas.height - 60, width: 40, height: 40)
        let rect = CropReadout.frame(cropFrame: corner, canvas: canvas)

        #expect(rect.maxX <= canvas.width)
        #expect(rect.maxY <= canvas.height)
        // 翻到左上那一侧：贴框的左/上边，而不是压着框
        #expect(rect.maxX <= corner.minX, "没翻过去，压住了框：\(rect) vs \(corner)")
        #expect(rect.maxY <= corner.minY, "没翻上去，压住了框：\(rect) vs \(corner)")
        #expect(!rect.intersects(corner))
    }

    @Test("永远不出画布 —— 出画布等于这条信息根本不存在")
    func alwaysInsideCanvas() {
        // 极端：保留框就是整张画布（此时"不压住框"已无解，但**不许出画布**）
        let whole = CGRect(origin: .zero, size: canvas)
        let rect = CropReadout.frame(cropFrame: whole, canvas: canvas)
        #expect(canvas.rectContains(rect), "读数框跑到画布外了：\(rect)")

        // 随便扫一遍各种框位，都不许出界
        for x in stride(from: CGFloat(0), through: canvas.width, by: 137) {
            for y in stride(from: CGFloat(0), through: canvas.height, by: 91) {
                let probe = CGRect(x: x, y: y, width: 120, height: 90)
                let placed = CropReadout.frame(cropFrame: probe, canvas: canvas)
                #expect(canvas.rectContains(placed), "框在 \(probe) 时读数框出界：\(placed)")
            }
        }
    }

    @Test("两行文案：第一行是**裁完**的原图像素，第二行是原图")
    func textLines() {
        // 稿子 §07 c 的例子：1400 × 620 的结果 / 1440 × 2000 的原图
        let lines = CropReadout.lines(crop: CGSize(width: 1400, height: 620),
                                      original: CGSize(width: 1440, height: 2000))
        #expect(lines.headline == "1400 × 620 px")
        #expect(lines.detail == "原图 1440 × 2000 px")

        // 两行不同 —— 相同的话"提前告知"就没内容了
        #expect(lines.headline != lines.detail)
    }

    @Test("小数尺寸四舍五入到整数，且**不许出现千位分隔符**")
    func textRounding() {
        let lines = CropReadout.lines(crop: CGSize(width: 1399.6, height: 619.4),
                                      original: CGSize(width: 1440, height: 2000))
        #expect(lines.headline == "1400 × 619 px")

        // 分辨率是**标识**不是计数：`String(localized:)` 会按语言加分隔符
        let big = CropReadout.lines(crop: CGSize(width: 1440, height: 2000),
                                    original: CGSize(width: 1440, height: 2000))
        for text in [big.headline, big.detail] {
            #expect(!text.contains(","), "被本地化成千位分隔了：\(text)")
            #expect(!text.contains("，"))
        }
    }
}

private extension CGSize {
    /// 这个矩形是否完整落在画布内（含边界）。
    func rectContains(_ rect: CGRect) -> Bool {
        rect.minX >= -0.001 && rect.minY >= -0.001
            && rect.maxX <= width + 0.001 && rect.maxY <= height + 0.001
    }
}

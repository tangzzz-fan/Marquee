import CoreGraphics
import Foundation
import MarqueeCore
import MarqueeTestSupport
import Testing

/// 滚动拼接的排布与渲染（ticket 11）。
///
/// 这一组刻意**完全不用真实配准**：位移由测试直接给定。
/// 理由是把两类症状一模一样（长图错位）的问题分开定位 ——
/// 「排布公式错了」和「配准算错了」混在一起排查会非常慢。
/// 真实配准由 `MarqueeCaptureTests.VisionScrollRegistrarTests` 的装置自检覆盖。
@Suite("滚动拼接")
struct ScrollStitcherTests {

    // MARK: - 排布

    @Test("整数步长：每帧只贡献它靠下的 d 行，总高 = 累计位移 + 视高")
    func integerStepLayout() {
        var stitcher = ScrollStitcher(pixelWidth: 400, viewHeight: 400)

        stitcher.append(rows: 0)
        #expect(stitcher.totalHeight == 400)

        stitcher.append(rows: 300)
        #expect(stitcher.totalHeight == 700)

        stitcher.append(rows: 300)
        #expect(stitcher.totalHeight == 1000)
        #expect(stitcher.accumulatedRows == 600)
        #expect(stitcher.frameCount == 3)

        let plan = stitcher.plan
        #expect(plan.slices.count == 3)
        #expect(plan.offsets == [0, 300, 600])

        // 第 0 帧：整帧。第 1 帧：源行 100..<400（= 靠下的 300 行）落到长图 400..<700。
        // 第 2 帧：同理落到 700..<1000。
        #expect(plan.slices[0].canvasRows == 0..<400)
        #expect(plan.slices[0].sourceRows == 0..<400)
        #expect(plan.slices[1].canvasRows == 400..<700)
        #expect(plan.slices[1].sourceRows == 100..<400)
        #expect(plan.slices[2].canvasRows == 700..<1000)
        #expect(plan.slices[2].sourceRows == 100..<400)

        for slice in plan.slices {
            #expect(slice.destinationTop == Double(slice.sourceRows.lowerBound) + plan.offsets[slice.frameIndex])
        }
        #expect(plan.isPixelExact)
    }

    @Test("长图的每一行都被某一帧完整覆盖 —— 底边不留半透明")
    func fullCoverage() {
        for step in [300.0, 300.5, 299.25] {
            var stitcher = ScrollStitcher(pixelWidth: 200, viewHeight: 400)
            stitcher.append(rows: 0)
            for _ in 0..<5 { stitcher.append(rows: step) }
            let plan = stitcher.plan
            #expect(plan.totalHeight > 0)
            assertFullyCovered(plan, step: step)
        }
    }

    @Test("总高取 floor：累计位移带小数时不产生只有一半内容的末行")
    func totalHeightUsesFloor() {
        var stitcher = ScrollStitcher(pixelWidth: 100, viewHeight: 400)
        stitcher.append(rows: 0)
        stitcher.append(rows: 300.5)
        // 内容真实下沿在 700.5；取 ceil 会得到 701 行，最后一行只有一半有内容
        #expect(stitcher.totalHeight == 700)

        var integral = ScrollStitcher(pixelWidth: 100, viewHeight: 400)
        integral.append(rows: 0)
        integral.append(rows: 300)
        #expect(integral.totalHeight == 700)
    }

    @Test("亚像素相位被带进落位，长图里的行号仍然连续")
    func fractionalPhasePlacement() {
        var stitcher = ScrollStitcher(pixelWidth: 100, viewHeight: 400)
        stitcher.append(rows: 0)
        stitcher.append(rows: 300.5)
        let plan = stitcher.plan
        #expect(plan.isPixelExact == false)

        // 第 1 片的落位必须换算成精确坐标，且相位落在 [0, 1)
        let second = plan.slices[1]
        let phase = second.destinationTop - Double(second.canvasRows.lowerBound)
        #expect(abs(phase) <= 1.0)
        assertFullyCovered(plan, step: 300.5)
    }

    // MARK: - 渲染

    @Test("整数步长端到端：拼接结果与真值逐像素一致")
    func integerStitchMatchesTruth() {
        let page = SyntheticPage(width: 320, height: 4000)
        let viewHeight = 400
        let step = 300
        let frameCount = 5
        let frames = (0..<frameCount).compactMap {
            page.frame(offsetY: $0 * step, viewHeight: viewHeight)
        }
        #expect(frames.count == frameCount)

        var stitcher = ScrollStitcher(pixelWidth: page.width, viewHeight: viewHeight)
        stitcher.append(rows: 0)
        for _ in 1..<frameCount { stitcher.append(rows: Double(step)) }

        let expectedHeight = (frameCount - 1) * step + viewHeight
        #expect(stitcher.totalHeight == expectedHeight)

        let composed = ScrollStitchRenderer.render(plan: stitcher.plan, frames: frames)
        #expect(composed != nil)
        guard let composed, let truth = page.truth(height: expectedHeight) else { return }
        #expect(composed.height == expectedHeight)
        #expect(composed.width == page.width)

        guard let mae = BitmapReader.meanAbsoluteError(composed, truth) else { return }
        // 单位是 0...255 的灰度级；"MAE < 1/255" 即"平均差不到 1 个灰阶"
        #expect(mae < 1.0, "整数步长的拼接应当与真值一致，实测 MAE = \(mae)")
    }

    @Test("亚像素步长：相位被真正重采样（比一律向下取整更接近真值）")
    func fractionalStitchBeatsFloor() {
        let page = SyntheticPage(width: 320, height: 4000)
        let viewHeight = 400
        let step = 300.5
        let frameCount = 4
        let frames = (0..<frameCount).compactMap {
            page.frame(offsetY: Int((Double($0) * step).rounded(.down)), viewHeight: viewHeight)
        }
        #expect(frames.count == frameCount)

        let fractional = stitcher(step: step, frames: frameCount, page: page, viewHeight: viewHeight)
        let floored = stitcher(step: step.rounded(.down), frames: frameCount, page: page, viewHeight: viewHeight)

        guard let fractionalImage = ScrollStitchRenderer.render(plan: fractional.plan, frames: frames),
              let flooredImage = ScrollStitchRenderer.render(plan: floored.plan, frames: frames) else {
            Issue.record("渲染失败")
            return
        }
        // 真值：真实下沿是 (n-1)*300.5 + 400，取 floor 的那部分行
        guard let truth = page.truth(height: fractionalImage.height) else { return }
        guard let fractionalMAE = BitmapReader.meanAbsoluteError(fractionalImage, truth),
              let flooredMAE = BitmapReader.meanAbsoluteError(flooredImage, truth) else { return }

        // 不做相位处理的版本每一步都丢半行，误差应当明显更大
        #expect(fractionalMAE < flooredMAE,
                "亚像素相位应当优于一律向下取整：\(fractionalMAE) vs \(flooredMAE)")
    }

    // MARK: - 工具

    private func stitcher(step: Double,
                          frames: Int,
                          page: SyntheticPage,
                          viewHeight: Int) -> ScrollStitcher {
        var stitcher = ScrollStitcher(pixelWidth: page.width, viewHeight: viewHeight)
        stitcher.append(rows: 0)
        for _ in 1..<frames { stitcher.append(rows: step) }
        return stitcher
    }

    /// 每一行都要被**至少一片完整覆盖**。
    ///
    /// 只断言"有片覆盖"是不够的：小数落位会让某一行的上半来自 A 片、下半来自 B 片，
    /// 如果两者之间存在缝隙，那一行的部分像素就永远没人写 —— 表现为长图里一条**半透明横线**。
    private func assertFullyCovered(_ plan: ScrollStitchPlan, step: Double) {
        for y in 0..<plan.totalHeight {
            let covered = plan.slices.contains { slice in
                let top = slice.destinationTop
                let bottom = top + Double(slice.sourceRows.count)
                return top <= Double(y) + 1e-6 && bottom >= Double(y + 1) - 1e-6
            }
            #expect(covered, "步长 \(step)：长图第 \(y) 行没有被任何一片完整覆盖")
        }
    }
}

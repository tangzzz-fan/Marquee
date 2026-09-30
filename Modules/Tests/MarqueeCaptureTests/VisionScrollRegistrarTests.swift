import CoreGraphics
import Foundation
import MarqueeCapture
import MarqueeCore
import MarqueeTestSupport
import Testing
import Vision

/// 滚动配准的**装置自检**（ticket 11 的硬性验收项）。
///
/// ## 为什么这条测试必须打在真实实现上
///
/// 配准属于"不崩、不报错、只会悄悄错"的模块 —— `docs/SPIKE-PLAN.md` 的 K1/K2/K3
/// 三个坑全是靠"已知位移的合成图回归"才发现的，其中一个还会让位移**符号整体反转**，
/// 症状是"长图永远只有一屏"，看起来像功能没做完，实际上是算错了。
///
/// 所以这里用真实 Vision + 真实拼接跑端到端，并与**真值**逐像素比对。
/// 位移符号、行序、新内容取哪几行，任何一处搞反都会让 MAE 直接爆掉。
@Suite("Vision 滚动配准（装置自检）")
struct VisionScrollRegistrarTests {

    private let pageWidth = 480
    private let pageHeight = 6000
    private let viewHeight = 600
    private let step = 400

    // MARK: - 装置本身先立住

    @Test("装置自检：取帧确实发生位移、内容非空 —— 否则后面的结论都不算数")
    func harnessIsSound() throws {
        let page = SyntheticPage(width: pageWidth, height: pageHeight)
        let first = try #require(page.frame(offsetY: 0, viewHeight: viewHeight))
        let second = try #require(page.frame(offsetY: step, viewHeight: viewHeight))

        let a = try #require(BitmapReader.read(first))
        let b = try #require(BitmapReader.read(second))

        var difference = 0
        for y in stride(from: 0, to: viewHeight, by: 7) {
            for x in stride(from: 0, to: pageWidth, by: 9) {
                difference += abs(a.luma(x: x, y: y) - b.luma(x: x, y: y))
            }
        }
        #expect(difference > 0, "两帧一模一样，说明取帧没产生位移")

        let dark = (0..<80).flatMap { y in (0..<pageWidth).map { x in a.luma(x: x, y: y) } }
            .filter { $0 < 200 }.count
        let ratio = Double(dark) / Double(pageWidth * 80)
        #expect(ratio > 0.03, "帧内几乎没有内容（非空像素 \(ratio)），配准会得出多义结果")
    }

    // MARK: - 位移符号与量级

    @Test("位移符号：向下滚动 = 正的行数（符号反了会让长图永远只有一屏）")
    func shiftSignIsPositiveForDownwardScroll() async throws {
        let page = SyntheticPage(width: pageWidth, height: pageHeight)
        let previous = try #require(page.frame(offsetY: 0, viewHeight: viewHeight))
        let current = try #require(page.frame(offsetY: step, viewHeight: viewHeight))

        let shift = try await VisionScrollRegistrar().register(previous: previous, current: current)

        #expect(shift.rows > 0, "向下滚动应当是正位移，实际 \(shift.rows)")
        #expect(abs(shift.rows - Double(step)) < 1.0,
                "位移应当是 \(step) 行，实际 \(shift.rows)")
        #expect(shift.confidence > 0.5)
    }

    @Test("亚像素位移：真实重采样出来的 0.5 行也能被认出来")
    func detectsFractionalShift() async throws {
        let page = SyntheticPage(width: pageWidth, height: pageHeight)
        let fractional = 300.5
        let previous = try #require(page.frame(offsetY: 0, viewHeight: viewHeight))
        let current = try #require(page.frame(offsetY: fractional, viewHeight: viewHeight))

        let shift = try await VisionScrollRegistrar().register(previous: previous, current: current)

        #expect(abs(shift.rows - fractional) < 0.75,
                "期望 ≈ \(fractional)，实际 \(shift.rows)")
    }

    @Test("没动：位移接近 0（滚到底的判据就建立在这上面）")
    func stationaryFrameReportsZero() async throws {
        let page = SyntheticPage(width: pageWidth, height: pageHeight)
        let previous = try #require(page.frame(offsetY: 2000, viewHeight: viewHeight))
        let current = try #require(page.frame(offsetY: 2000, viewHeight: viewHeight))

        let shift = try await VisionScrollRegistrar().register(previous: previous, current: current)

        #expect(abs(shift.rows) < 1.0, "同一帧的位移应当接近 0，实际 \(shift.rows)")
    }

    // MARK: - 端到端：配准 + 拼接 vs 真值

    @Test("整数滚动端到端：拼接结果与真值的平均绝对误差 < 1/255，高度与真值一致")
    func endToEndMatchesTruth() async throws {
        let page = SyntheticPage(width: pageWidth, height: pageHeight)
        let frameCount = 5
        let frames = try (0..<frameCount).map { index in
            try #require(page.frame(offsetY: index * step, viewHeight: viewHeight))
        }

        let registrar = VisionScrollRegistrar()
        var stitcher = ScrollStitcher(pixelWidth: pageWidth, viewHeight: viewHeight)
        var registrationMilliseconds: [Double] = []

        stitcher.append(rows: 0)
        for index in 1..<frameCount {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let shift = try await registrar.register(previous: frames[index - 1], current: frames[index])
            registrationMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            stitcher.append(rows: shift.rows)
        }

        let expectedHeight = (frameCount - 1) * step + viewHeight
        #expect(stitcher.totalHeight == expectedHeight,
                "长图高度应为 \(expectedHeight)，实际 \(stitcher.totalHeight)")

        let stitchStartedAt = DispatchTime.now().uptimeNanoseconds
        let composed = try #require(ScrollStitchRenderer.render(plan: stitcher.plan, frames: frames))
        let stitchMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - stitchStartedAt) / 1_000_000

        let truth = try #require(page.truth(height: expectedHeight))
        #expect(composed.height == expectedHeight)
        #expect(composed.width == pageWidth)

        let mae = try #require(BitmapReader.meanAbsoluteError(composed, truth))
        // 单位是 0...255 的灰度级；"MAE < 1/255" 即"平均差不到 1 个灰阶"
        #expect(mae < 1.0, "端到端拼接应当与真值一致，实测 MAE = \(mae)")

        print("""
        [滚动配准实测] 单次配准 \(registrationMilliseconds.map { String(format: "%.0f", $0) }.joined(separator: "/")) ms \
        （均值 \(String(format: "%.0f", registrationMilliseconds.reduce(0, +) / Double(registrationMilliseconds.count))) ms）；\
        \(frameCount) 帧拼接 \(String(format: "%.0f", stitchMilliseconds)) ms；\
        输出 \(composed.width)×\(composed.height) px；MAE \(mae)
        """)
    }

    @Test("配准耗时在预算内：单帧百毫秒级仍可用，但如果掉到秒级说明该降采样了")
    func registrationStaysWithinBudget() async throws {
        let page = SyntheticPage(width: pageWidth, height: pageHeight)
        let previous = try #require(page.frame(offsetY: 0, viewHeight: viewHeight))
        let current = try #require(page.frame(offsetY: step, viewHeight: viewHeight))
        let registrar = VisionScrollRegistrar()

        // 丢掉第一次（框架首次调用有一次性开销），取 5 次的均值
        _ = try await registrar.register(previous: previous, current: current)
        var samples: [Double] = []
        for _ in 0..<5 {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            _ = try await registrar.register(previous: previous, current: current)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        }
        let average = samples.reduce(0, +) / Double(samples.count)
        print("[滚动配准实测] \(pageWidth)×\(viewHeight) 帧，单次配准均值 \(String(format: "%.1f", average)) ms")

        // 抓帧间隔是 350 ms，配准必须远低于它，否则抓帧节奏会被拖垮
        #expect(average < 150, "单次配准 \(average) ms 太慢，需要给 VisionScrollRegistrar 开降采样")
    }
}

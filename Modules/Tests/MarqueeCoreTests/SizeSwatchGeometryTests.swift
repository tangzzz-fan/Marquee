import CoreGraphics
import Testing
@testable import MarqueeCore

/// 尺寸档画多大 —— 覆盖层与编辑器共用的一份规则。
@Suite("尺寸档的画法")
struct SizeSwatchGeometryTests {

    @Test("形状按「这三档代表什么」分：线宽圆点、打码方块、字号字母")
    func shapeFollowsMeaning() {
        #expect(SizeSwatchGeometry.shape(for: .lineWidth) == .circle)
        #expect(SizeSwatchGeometry.shape(for: .redactionStrength) == .square)
        #expect(SizeSwatchGeometry.shape(for: .fontSize) == .letter)
    }

    @Test("三档必须**一眼分得出**大小 —— 打码那组原先后两档几乎一样大")
    func slotsAreVisuallyDistinct() {
        // 这是本类型的核心判据，也是对那次返工的回归：
        // 旧公式 `4 + value * 1.4` 夹到上限时，4/8/16 会画成 9.6 / 15.2 / 16，
        // 后两档差 0.8 点 —— 在 20 点的格子里根本看不出区别。
        let sides = (0..<3).map { SizeSwatchGeometry.relativeSide(index: $0, of: 3) }

        #expect(sides == sides.sorted(), "要递增，否则档位顺序和视觉大小对不上")
        #expect(sides.last! >= sides.first! * 2,
                "最大的不到最小的两倍，用户分不出「强弱」")
        for index in 1..<sides.count {
            #expect(sides[index] - sides[index - 1] > 0.15,
                    "第 \(index) 档比前一档只大 \(sides[index] - sides[index - 1])，看不出来")
        }
    }

    @Test("档位大小**不跟数值走** —— 换一组数值画出来必须一样")
    func sizesDoNotDependOnValues() {
        // 2/4/8（线宽）与 4/8/16（打码）与 24/36/56（编辑器字号）三组数值范围差一个量级，
        // 但它们都是"三档"，画出来就该一样。跟着数值线性映射正是旧实现出问题的地方。
        for meaning in OverlaySizeMeaning.allCases {
            let sides = (0..<3).map { SizeSwatchGeometry.relativeSide(index: $0, of: meaning.values.count) }
            #expect(sides == [0.36, 0.61, 0.86], "\(meaning) 的三档画得跟别人不一样")
        }
    }

    @Test("比例恒落在格子内，且不会把格子撑满")
    func staysInsideTheCell() {
        for count in 1...6 {
            for index in 0..<count {
                let side = SizeSwatchGeometry.relativeSide(index: index, of: count)
                #expect(side > 0 && side < 1, "占满或为负都会画出格子外")
            }
        }
    }

    @Test("越界的档位序号按边界夹住，不是崩溃也不是算出一个怪值")
    func outOfRangeIndexClamps() {
        #expect(SizeSwatchGeometry.relativeSide(index: 9, of: 3)
                == SizeSwatchGeometry.relativeSide(index: 2, of: 3))
        #expect(SizeSwatchGeometry.relativeSide(index: -1, of: 3)
                == SizeSwatchGeometry.relativeSide(index: 0, of: 3))
        // 只有一档时没有"比大小"可言，给一个偏大的固定值（画出来就是个明显的点）
        #expect(SizeSwatchGeometry.relativeSide(index: 0, of: 1) == 0.86)
    }
}

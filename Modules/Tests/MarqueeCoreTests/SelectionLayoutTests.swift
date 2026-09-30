import CoreGraphics
import Testing
@testable import MarqueeCore

@Suite("跨屏选区布局")
struct SelectionLayoutTests {

    /// 主屏：1440×900 @2x，原点 (0,0)
    private let retinaPrimary = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                backingScale: 2,
                                                displayID: 1)
    /// 主屏右侧：1920×1080 @1x
    private let plainRight = DisplayGeometry(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                             backingScale: 1,
                                             displayID: 2)

    @Test("单屏 2x：输出像素 = 点 × 2，只有一片且铺满")
    func singleRetinaDisplay() throws {
        let layout = try #require(SelectionLayout.plan(
            selection: CGRect(x: 100, y: 100, width: 200, height: 100),
            displays: [retinaPrimary]
        ))

        #expect(layout.outputScale == 2)
        #expect(layout.outputPixelSize == CGSize(width: 400, height: 200))
        #expect(layout.slices.count == 1)
        #expect(layout.slices[0].display.displayID == 1)
        #expect(layout.slices[0].globalPointRect == CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(layout.slices[0].targetPixelRect == CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    @Test("选区超出屏幕：裁剪到屏内，落位带上被裁掉的偏移")
    func clipsToDisplay() throws {
        // 选区从屏内 (1400, 800) 出发，右下角跑到屏外
        let layout = try #require(SelectionLayout.plan(
            selection: CGRect(x: 1400, y: 800, width: 400, height: 400),
            displays: [retinaPrimary]
        ))

        #expect(layout.outputPixelSize == CGSize(width: 800, height: 800))
        let slice = layout.slices[0]
        #expect(slice.globalPointRect == CGRect(x: 1400, y: 800, width: 40, height: 100))
        // 左上角没被裁 → 落位仍是 (0,0)，但尺寸只剩屏内那部分
        #expect(slice.targetPixelRect == CGRect(x: 0, y: 0, width: 80, height: 200))
    }

    @Test("跨屏 1x + 2x：输出取最大的 scale，两片落位按边算且严丝合缝")
    func spansMixedScaleDisplays() throws {
        // 从 2x 主屏的 (1300, 200) 拖到 1x 右屏的 (1640, 500)
        let selection = CGRect(x: 1300, y: 200, width: 340, height: 300)
        let layout = try #require(SelectionLayout.plan(selection: selection,
                                                       displays: [retinaPrimary, plainRight]))

        // 最大 scale = 2，所以输出 = 340×300 点 ×2
        #expect(layout.outputScale == 2)
        #expect(layout.outputPixelSize == CGSize(width: 680, height: 600))
        #expect(layout.slices.count == 2)

        let left = try #require(layout.slices.first { $0.display.displayID == 1 })
        let right = try #require(layout.slices.first { $0.display.displayID == 2 })

        // 左片：主屏被裁到 x∈[1300,1440] → 140 点宽 → 280 px
        #expect(left.globalPointRect == CGRect(x: 1300, y: 200, width: 140, height: 300))
        #expect(left.targetPixelRect == CGRect(x: 0, y: 0, width: 280, height: 600))
        // 右片：右屏被裁到 x∈[1440,1640] → 200 点宽 → 400 px，紧接左片
        #expect(right.globalPointRect == CGRect(x: 1440, y: 200, width: 200, height: 300))
        #expect(right.targetPixelRect == CGRect(x: 280, y: 0, width: 400, height: 600))

        // 无缝：左片右边界 == 右片左边界，且合起来正好是输出宽度
        #expect(left.targetPixelRect.maxX == right.targetPixelRect.minX)
        #expect(left.targetPixelRect.width + right.targetPixelRect.width == layout.outputPixelSize.width)
    }

    @Test("1x 屏上的部分也按输出 scale 放大 —— 这样混合 DPI 下不会出现尺寸错乱")
    func mixedScaleKeepsTargetConsistent() throws {
        // 选区完全落在 1x 右屏上
        let layout = try #require(SelectionLayout.plan(
            selection: CGRect(x: 1440, y: 0, width: 100, height: 100),
            displays: [retinaPrimary, plainRight]
        ))
        // 只与右屏相交 → 最大（也是唯一）scale = 1
        #expect(layout.outputScale == 1)
        #expect(layout.outputPixelSize == CGSize(width: 100, height: 100))
        #expect(layout.slices.count == 1)
    }

    @Test("零面积选区返回 nil")
    func zeroAreaReturnsNil() {
        #expect(SelectionLayout.plan(selection: CGRect(x: 100, y: 100, width: 0, height: 100),
                                     displays: [retinaPrimary]) == nil)
    }

    @Test("选区完全落在所有屏之外返回 nil")
    func offScreenReturnsNil() {
        #expect(SelectionLayout.plan(selection: CGRect(x: 9000, y: 9000, width: 100, height: 100),
                                     displays: [retinaPrimary, plainRight]) == nil)
    }

    @Test("切片顺序稳定：自上而下、自左而右")
    func slicesAreOrderedDeterministically() throws {
        let lowerLeft = DisplayGeometry(frame: CGRect(x: 0, y: 900, width: 1000, height: 600),
                                        backingScale: 1, displayID: 10)
        let upperRight = DisplayGeometry(frame: CGRect(x: 1000, y: -600, width: 1000, height: 600),
                                         backingScale: 1, displayID: 11)

        let layout = try #require(SelectionLayout.plan(
            selection: CGRect(x: 0, y: -600, width: 2000, height: 2100),
            displays: [lowerLeft, upperRight]
        ))
        #expect(layout.slices.map(\.display.displayID) == [11, 10])
    }
}

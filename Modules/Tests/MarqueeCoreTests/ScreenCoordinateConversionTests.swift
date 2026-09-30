import CoreGraphics
import Testing
@testable import MarqueeCore

@Suite("Cocoa ↔ Quartz 坐标换算")
struct ScreenCoordinateConversionTests {

    /// 主屏 1440×900，第二块屏挂在主屏**上方**（Quartz 下 y 为负）
    private let primary = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                          backingScale: 2,
                                          displayID: 1)
    private let above = DisplayGeometry(frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                                        backingScale: 1,
                                        displayID: 2)

    @Test("枢轴 = origin 为零的那块屏的高度")
    func primaryHeight() {
        #expect(ScreenCoordinateConversion.primaryScreenHeight(in: [primary, above]) == 900)
        // 顺序不影响结果
        #expect(ScreenCoordinateConversion.primaryScreenHeight(in: [above, primary]) == 900)
        #expect(ScreenCoordinateConversion.primaryScreenHeight(in: [above]) == nil)
    }

    @Test("点：y 取补")
    func pointFlipsY() {
        let quartz = ScreenCoordinateConversion.quartzPoint(fromCocoa: CGPoint(x: 100, y: 880),
                                                            primaryScreenHeight: 900)
        #expect(quartz == CGPoint(x: 100, y: 20))
    }

    @Test("矩形按**边**翻转：y' = 高度 − maxY，宽高不变")
    func rectFlipsByEdges() {
        // Cocoa 下 y 从底边算起 100，高 50 → 顶边在 150
        let cocoa = CGRect(x: 200, y: 100, width: 300, height: 50)
        let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoa, primaryScreenHeight: 900)
        #expect(quartz == CGRect(x: 200, y: 750, width: 300, height: 50))
    }

    @Test("只翻原点（不按边）会错位 —— 这条断言就是用来钉住这个错误的")
    func edgeFlipDiffersFromOriginFlip() {
        let cocoa = CGRect(x: 0, y: 100, width: 300, height: 50)
        let correct = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoa, primaryScreenHeight: 900)
        let originOnly = CGRect(x: 0,
                                y: 900 - cocoa.minY,
                                width: cocoa.width,
                                height: cocoa.height)
        #expect(correct != originOnly)
        #expect(correct.minY == 750)
        #expect(originOnly.minY == 800)
    }

    @Test("换算是对合的：来回一次回到原值")
    func roundTrip() {
        let original = CGRect(x: 37, y: 61, width: 213, height: 99)
        let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: original, primaryScreenHeight: 900)
        let back = ScreenCoordinateConversion.cocoaRect(fromQuartz: quartz, primaryScreenHeight: 900)
        #expect(back == original)
    }

    @Test("主屏上方的第二块屏：Cocoa 下 y 超过主屏高度，Quartz 下为负")
    func displayAbovePrimary() {
        // Cocoa 里"主屏上方 100 点"= y 1000
        let cocoa = CGRect(x: 0, y: 1000, width: 200, height: 80)
        let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoa, primaryScreenHeight: 900)
        // Quartz 里应在 y = -180 起（主屏顶边为 0，第二块屏占 -1080..0）
        #expect(quartz.minY == -180)
        #expect(quartz.maxY == -100)
    }
}

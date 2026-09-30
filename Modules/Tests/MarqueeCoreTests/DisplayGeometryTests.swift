import Testing
import CoreGraphics
@testable import MarqueeCore

@Suite("DisplayGeometry：点 ↔ 像素换算")
struct DisplayGeometryTests {

    private let retina = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         backingScale: 2, displayID: 1)
    private let plain = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                        backingScale: 1, displayID: 2)
    /// 位于主屏右侧的第二块屏，用来验证 frame 偏移被正确扣除
    private let second = DisplayGeometry(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                         backingScale: 2, displayID: 3)

    @Test("2x 屏：点坐标换算为双倍像素")
    func retinaDoublesPixels() {
        let px = retina.pixelRect(for: CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(px == CGRect(x: 200, y: 200, width: 400, height: 200))
    }

    @Test("1x 屏：点坐标与像素坐标一致")
    func plainScreenIsIdentity() {
        let px = plain.pixelRect(for: CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(px == CGRect(x: 100, y: 100, width: 200, height: 100))
    }

    @Test("带偏移的屏幕：先扣除屏幕原点再换算")
    func offsetScreenSubtractsOrigin() {
        let px = second.pixelRect(for: CGRect(x: 1540, y: 50, width: 100, height: 100))
        // 本地坐标 (100, 50)，2x → (200, 100)
        #expect(px == CGRect(x: 200, y: 100, width: 200, height: 200))
    }

    @Test("像素尺寸 = 点尺寸 × scale")
    func pixelSize() {
        #expect(retina.pixelSize == CGSize(width: 2880, height: 1800))
        #expect(plain.pixelSize == CGSize(width: 1920, height: 1080))
    }

    @Test("半像素点：换算后取整到整像素，不产生小数")
    func halfPointRoundsToWholePixel() {
        let px = retina.pixelRect(for: CGRect(x: 0.25, y: 0.75, width: 10.5, height: 10.5))
        #expect(px.minX == px.minX.rounded())
        #expect(px.minY == px.minY.rounded())
        #expect(px.width == px.width.rounded())
        #expect(px.height == px.height.rounded())
        #expect(px.width == 21)
    }
}

@Suite("Selection：拖拽几何")
struct SelectionTests {

    @Test("拖拽方向：四个方向都归一化成正宽高矩形")
    func normalizesAllDragDirections() {
        let expected = CGRect(x: 10, y: 20, width: 90, height: 60)
        #expect(Selection.rect(anchor: CGPoint(x: 10, y: 20), current: CGPoint(x: 100, y: 80)) == expected)
        #expect(Selection.rect(anchor: CGPoint(x: 100, y: 80), current: CGPoint(x: 10, y: 20)) == expected)
        #expect(Selection.rect(anchor: CGPoint(x: 100, y: 20), current: CGPoint(x: 10, y: 80)) == expected)
        #expect(Selection.rect(anchor: CGPoint(x: 10, y: 80), current: CGPoint(x: 100, y: 20)) == expected)
    }

    @Test("零面积拖拽：得到宽高为 0 的矩形，不会被误认为有效选区")
    func zeroAreaDrag() {
        let rect = Selection.rect(anchor: CGPoint(x: 50, y: 50), current: CGPoint(x: 50, y: 50))
        #expect(rect.width == 0 && rect.height == 0)
    }

    @Test("吸附到整点")
    func snappingToWholePoints() {
        let snapped = Selection.snapped(CGRect(x: 10.4, y: 20.6, width: 89.3, height: 59.2))
        #expect(snapped == CGRect(x: 10, y: 21, width: 90, height: 59))
    }

    @Test("裁剪到屏幕内：跨屏选区只保留交集")
    func clippingAcrossScreens() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let clipped = Selection.clipped(CGRect(x: 1200, y: 100, width: 800, height: 200), to: bounds)
        #expect(clipped == CGRect(x: 1200, y: 100, width: 240, height: 200))
    }

    @Test("完全在屏幕外：返回 nil 而不是 null 矩形")
    func clippingOutsideReturnsNil() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(Selection.clipped(CGRect(x: 2000, y: 100, width: 100, height: 100), to: bounds) == nil)
    }

    @Test("边界相切但没有面积：返回 nil")
    func degenerateIntersectionReturnsNil() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(Selection.clipped(CGRect(x: 100, y: 0, width: 50, height: 50), to: bounds) == nil)
    }
}

@Suite("DisplayGeometry + Selection：选区有效性")
struct SelectionValidityTests {

    private let retina = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         backingScale: 2, displayID: 1)

    @Test("正常选区有效")
    func validSelection() {
        #expect(retina.isValidSelection(CGRect(x: 100, y: 100, width: 200, height: 200)))
    }

    @Test("零面积选区无效")
    func zeroAreaIsInvalid() {
        #expect(!retina.isValidSelection(CGRect(x: 100, y: 100, width: 0, height: 200)))
    }

    @Test("屏外选区无效")
    func offScreenIsInvalid() {
        #expect(!retina.isValidSelection(CGRect(x: 2000, y: 2000, width: 100, height: 100)))
    }

    @Test("跨屏选区：与本屏有交集即有效，且换算基于交集")
    func crossScreenSelectionIsValid() {
        let rect = CGRect(x: 1400, y: 100, width: 200, height: 100)
        #expect(retina.isValidSelection(rect))
        // 交集是 (1400,100,40,100)，2x → (2800,200,80,200)
        let clipped = Selection.clipped(rect, to: retina.frame)!
        #expect(retina.pixelRect(for: clipped) == CGRect(x: 2800, y: 200, width: 80, height: 200))
    }
}

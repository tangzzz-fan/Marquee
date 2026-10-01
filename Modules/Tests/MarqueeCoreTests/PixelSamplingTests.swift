import CoreGraphics
import Foundation
import MarqueeTestSupport
import Testing
@testable import MarqueeCore

@Suite("取色与放大镜")
struct PixelSamplingTests {

    // MARK: - 色值格式

    @Test("HEX 大写、补零、带 #")
    func hexFormatting() {
        #expect(PixelColor.black.hexString == "#000000")
        #expect(PixelColor.white.hexString == "#FFFFFF")
        #expect(PixelColor(red: 26, green: 43, blue: 60).hexString == "#1A2B3C")
        // 单字节值必须补到两位，否则 #00000A 变成 #0000A 会贴错
        #expect(PixelColor(red: 0, green: 0, blue: 10).hexString == "#00000A")
        #expect(PixelColor(red: 255, green: 0, blue: 0).hexString == "#FF0000")
    }

    @Test("RGB 与 HSB 文本")
    func otherFormats() {
        let color = PixelColor(red: 26, green: 43, blue: 60)
        #expect(color.rgbString == "rgb(26, 43, 60)")
        #expect(PixelColor.Format.hex.displayName == "HEX")
        #expect(color.string(in: .hex) == color.hexString)
        #expect(color.string(in: .rgb) == color.rgbString)
        #expect(color.string(in: .hsb) == color.hsbString)
    }

    @Test("HSB 边界值：全黑、全白、纯红")
    func hsbBoundaries() {
        let black = PixelColor.black.hsbComponents
        #expect(black.hue == 0)
        #expect(black.saturation == 0)
        #expect(black.brightness == 0)
        #expect(PixelColor.black.hsbString == "hsb(0, 0%, 0%)")

        let white = PixelColor.white.hsbComponents
        #expect(white.hue == 0, "灰色没有色相，应当取 0 而不是 undefined")
        #expect(white.saturation == 0)
        #expect(white.brightness == 1)
        #expect(PixelColor.white.hsbString == "hsb(0, 0%, 100%)")

        let red = PixelColor(red: 255, green: 0, blue: 0).hsbComponents
        #expect(red.hue == 0)
        #expect(red.saturation == 1)
        #expect(red.brightness == 1)

        let green = PixelColor(red: 0, green: 255, blue: 0).hsbComponents
        #expect(green.hue == 120)
        let blue = PixelColor(red: 0, green: 0, blue: 255).hsbComponents
        #expect(blue.hue == 240)

        // 色相回绕：洋红落在红与蓝之间
        let magenta = PixelColor(red: 255, green: 0, blue: 255).hsbComponents
        #expect(magenta.hue == 300)
    }

    @Test("0...1 分量构造：夹住越界值并四舍五入")
    func unitComponentConstruction() {
        #expect(PixelColor(unitRed: 0, unitGreen: 0, unitBlue: 0) == .black)
        #expect(PixelColor(unitRed: 1, unitGreen: 1, unitBlue: 1) == .white)
        #expect(PixelColor(unitRed: 1.7, unitGreen: -0.3, unitBlue: 0.5)
            == PixelColor(red: 255, green: 0, blue: 128))
    }

    // MARK: - 取样中心

    @Test("取样中心被夹住，保证整个裁剪区都落在图内")
    func clampedCenter() {
        // 20×10 的图，取样 4×4（half = 2）
        #expect(PixelSampling.clampedCenter(CGPoint(x: 10, y: 5), side: 4, imageWidth: 20, imageHeight: 10)
            == PixelCoordinate(x: 10, y: 5))
        // 左上角：中心被推到 (2, 2)，这样 origin 才是 (0, 0) 而不是负数
        #expect(PixelSampling.clampedCenter(CGPoint(x: 0, y: 0), side: 4, imageWidth: 20, imageHeight: 10)
            == PixelCoordinate(x: 2, y: 2))
        // 右下角：中心被拉回 (18, 8) —— 此时 origin = 16，裁剪区刚好贴住右下（覆盖到第 19/9 行）
        #expect(PixelSampling.clampedCenter(CGPoint(x: 19.9, y: 9.9), side: 4, imageWidth: 20, imageHeight: 10)
            == PixelCoordinate(x: 18, y: 8))
        // 小数坐标四舍五入
        #expect(PixelSampling.clampedCenter(CGPoint(x: 9.6, y: 4.4), side: 4, imageWidth: 20, imageHeight: 10)
            == PixelCoordinate(x: 10, y: 4))
    }

    // MARK: - 读像素

    @Test("读像素：四色图四个角各读各的")
    func readsQuadrantColors() {
        let image = TestImage.fourQuadrants() // 左上红 右上绿 / 左下蓝 右下白
        #expect(PixelSampling.color(of: image, at: PixelCoordinate(x: 0, y: 0)) == PixelColor(red: 255, green: 0, blue: 0))
        #expect(PixelSampling.color(of: image, at: PixelCoordinate(x: 1, y: 0)) == PixelColor(red: 0, green: 255, blue: 0))
        #expect(PixelSampling.color(of: image, at: PixelCoordinate(x: 0, y: 1)) == PixelColor(red: 0, green: 0, blue: 255))
        #expect(PixelSampling.color(of: image, at: PixelCoordinate(x: 1, y: 1)) == .white)
        // 越界返回 nil，不崩
        #expect(PixelSampling.color(of: image, at: PixelCoordinate(x: 2, y: 0)) == nil)
        #expect(PixelSampling.color(of: image, at: PixelCoordinate(x: -1, y: 0)) == nil)
    }

    // MARK: - 放大

    @Test("放大用最近邻：输出里只允许出现源图那两种颜色，不许出现混色")
    func magnificationIsNearestNeighbour() {
        let image = TestImage.checkerboard(width: 8, height: 8)
        let first = PixelSampling.color(of: image, at: PixelCoordinate(x: 0, y: 0))
        let second = PixelSampling.color(of: image, at: PixelCoordinate(x: 1, y: 0))
        #expect(first != nil && second != nil && first != second)

        let zoomed = PixelSampling.magnified(image,
                                            centeredAt: PixelCoordinate(x: 4, y: 4),
                                            side: 8,
                                            zoom: 3)
        guard let out = zoomed, let bitmap = BitmapReader.read(out) else {
            Issue.record("放大失败")
            return
        }
        #expect(out.width == 24)
        #expect(out.height == 24)

        var seen: Set<PixelColor> = []
        for y in 0..<out.height {
            for x in 0..<out.width {
                let pixel = bitmap.rgba(x: x, y: y)
                seen.insert(PixelColor(red: pixel.red, green: pixel.green, blue: pixel.blue))
            }
        }
        // 双线性插值会把相邻格混出第三种颜色 —— 这条断言就是用来钉住"没有混色"的
        #expect(seen.count == 2, "放大后出现了 \(seen.count) 种颜色，说明发生了插值混色：\(seen)")
        #expect(seen.contains(first!) && seen.contains(second!), "输出颜色应当就是源图那两种")
    }

    @Test("放大：裁剪区越界或边长超过图像时返回 nil，而不是给一张残图")
    func magnificationRejectsInvalidRequests() {
        let image = TestImage.checkerboard(width: 4, height: 4)
        // 中心已在图内，但 6×6 的取样区放不下
        #expect(PixelSampling.magnified(image, centeredAt: PixelCoordinate(x: 2, y: 2), side: 6, zoom: 2) == nil)
        // 边长超过图像尺寸
        #expect(PixelSampling.magnified(image, centeredAt: PixelCoordinate(x: 2, y: 2), side: 8, zoom: 2) == nil)
    }

    // MARK: - 点 → 像素

    @Test("全局 Cocoa 点 → 采集帧像素：Retina 2x 主屏")
    func imagePixelOnRetina() {
        // 1440×900 @2x，主屏高度 900。
        // Cocoa 的 y 向上：y=850 是屏幕靠下；翻到 Quartz 后 y=50 是屏幕靠上。
        let pixel = MagnifierLayout.imagePixel(forCocoa: CGPoint(x: 100, y: 850),
                                              on: TestDisplays.retina,
                                              primaryScreenHeight: 900)
        #expect(pixel == CGPoint(x: 200, y: 100))
    }

    @Test("全局 Cocoa 点 → 采集帧像素：右侧 1x 副屏（要减掉屏幕 origin）")
    func imagePixelOnSecondaryDisplay() {
        let pixel = MagnifierLayout.imagePixel(forCocoa: CGPoint(x: 1500, y: 500),
                                              on: TestDisplays.plainRight,
                                              primaryScreenHeight: 900)
        // 全局 x 1500 → 该屏内 60（origin.x = 1440）；1x 所以像素等于点
        #expect(pixel == CGPoint(x: 60, y: 400))
    }

    // MARK: - 摆位

    @Test("放大镜永远落在屏幕内，且不盖住光标")
    func magnifierAvoidsEdgesAndCursor() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let settings = MagnifierLayout.Settings.default
        let box = settings.boxSize

        for cursor in [CGPoint(x: 500, y: 400),
                       CGPoint(x: 2, y: 2),
                       CGPoint(x: 998, y: 798),
                       CGPoint(x: 2, y: 798),
                       CGPoint(x: 998, y: 2),
                       CGPoint(x: 990, y: 10)] {
            let origin = MagnifierLayout.origin(cursor: cursor, settings: settings, screenBounds: bounds)
            let boxRect = CGRect(origin: origin, size: box)
            #expect(bounds.contains(boxRect), "光标 \(cursor) 时放大镜 \(boxRect) 跑出屏幕")
            #expect(!boxRect.contains(cursor), "光标 \(cursor) 时放大镜盖住了取样点")
            // 关键一条：放大镜要**贴着**光标（间距就是 gap）。
            // 只靠夹取也能满足"不越界、不盖光标"，但会把放大镜甩到屏幕另一头 ——
            // 用户看着一个远处的放大镜，根本不知道它在放大哪一块。
            let gap = settings.gap
            let huggingX = cursor.x <= boxRect.minX - gap + 1 || cursor.x >= boxRect.maxX + gap - 1
            #expect(huggingX, "光标 \(cursor) 时放大镜 \(boxRect) 没有贴着光标（水平间距应约为 \(gap)）")
        }
    }

    @Test("放大镜默认在光标右下；右边放不下就翻到左边")
    func magnifierFlipsSide() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let settings = MagnifierLayout.Settings.default

        // 中间：放在右下（Cocoa 里"下方"是更小的 y）
        let center = MagnifierLayout.origin(cursor: CGPoint(x: 400, y: 400),
                                           settings: settings, screenBounds: bounds)
        #expect(center.x > 400)
        #expect(center.y < 400)

        // 贴右边界：翻到左边
        let right = MagnifierLayout.origin(cursor: CGPoint(x: 990, y: 400),
                                          settings: settings, screenBounds: bounds)
        #expect(right.x < 990)
    }
}

import CoreGraphics
import Testing
@testable import MarqueeCore

/// 钉图的状态与几何（ticket 14）。
@Suite("钉图的状态与几何")
struct PinStateTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func state(width: CGFloat = 400,
                       height: CGFloat = 300,
                       scale: CGFloat = 1) -> PinState {
        PinState(baseSize: CGSize(width: width, height: height),
                 scale: scale,
                 origin: CGPoint(x: 200, y: 300))
    }

    // MARK: - 缩放

    @Test("放大的锚点是**左上角** —— 那一角不动，图往右下长")
    func zoomAnchorsTheTopLeft() {
        // ⚠️ 这条钉的是"滚轮放大时图会不会到处跑"。锚点若取中心（或忘了 Cocoa 的
        // frame 原点在**左下**、只改高度不挪 y），连滚几次图就找不着北了。
        var subject = state()
        let before = subject.frame

        subject.zoom(by: 1.5, screenFrame: screen)

        #expect(subject.frame.minX == before.minX, "左边不动")
        #expect(subject.frame.maxY == before.maxY, "上边不动（Cocoa 的 maxY 才是视觉上边）")
        #expect(subject.frame.width > before.width)
        #expect(subject.frame.height > before.height)
    }

    @Test("缩小的锚点同样是左上角")
    func zoomOutAlsoAnchorsTheTopLeft() {
        var subject = state()
        let before = subject.frame

        subject.zoom(by: 1 / 1.5, screenFrame: screen)

        #expect(subject.frame.minX == before.minX)
        #expect(subject.frame.maxY == before.maxY)
        #expect(subject.frame.width < before.width)
    }

    @Test("缩放有上下限，到顶之后再滚不会漂移")
    func zoomIsClampedAndDoesNotDriftAtTheLimit() {
        var subject = state()

        for _ in 0..<100 { subject.zoom(by: 1.5, screenFrame: screen) }
        let atMax = subject.frame
        #expect(subject.scale == PinGeometry.zoomRange.upperBound)

        subject.zoom(by: 1.5, screenFrame: screen)
        #expect(subject.frame == atMax, "已经在顶了，再滚一格必须**原地不动**")

        for _ in 0..<200 { subject.zoom(by: 0.5, screenFrame: screen) }
        #expect(subject.scale == PinGeometry.zoomRange.lowerBound)
    }

    @Test("缩放倍率是相对**1:1 的显示尺寸**，不是相对当前尺寸累乘")
    func scaleIsRelativeToOneToOne() {
        var subject = state(width: 400, height: 300)

        subject.zoom(by: 2, screenFrame: screen)

        // 2 倍就是 2 倍：800×600。累乘的实现这里也会得到同样的数，
        // 所以下面这条才是关键 —— 它保证"回到 ×1"是一个**存在且能算出来的档位**。
        #expect(subject.size == CGSize(width: 800, height: 600))

        subject.zoom(by: 0.5, screenFrame: screen)
        #expect(subject.size == CGSize(width: 400, height: 300))
    }

    // MARK: - 不透明度

    @Test("不透明度是一个**循环**：一路点下去会回到最不透明")
    func opacityCycles() {
        var subject = state()
        #expect(subject.opacity == 1)

        var seen: [CGFloat] = []
        for _ in 0..<PinGeometry.opacitySteps.count {
            subject.cycleOpacity()
            seen.append(subject.opacity)
        }
        #expect(seen == [0.75, 0.5, 0.25, 1], "实际：\(seen)")
        #expect(subject.opacityIndex == 0)
    }

    // MARK: - 位置

    @Test("拖到屏幕外时**至少留一角**在屏内 —— 否则用户再也抓不到它")
    func moveKeepsACornerOnScreen() {
        var subject = state()

        subject.move(to: CGPoint(x: -5000, y: -5000), screenFrame: screen)

        let frame = subject.frame
        // 右下角仍要落在屏幕里一点（留 40 点的可抓区域）
        #expect(frame.maxX >= screen.minX + 40)
        #expect(frame.maxY >= screen.minY + 40)
        #expect(frame.minX < screen.minX, "它是被拖出左边了，但没被整个拽回来")
    }

    @Test("放大到比屏幕还大之后，仍然能被拖回来（不会被硬缩回屏幕内）")
    func oversizedPinIsNotSqueezedBack() {
        var subject = state(width: 2000, height: 1500, scale: 2)

        subject.clampInto(screen)

        // 比屏幕大是**正常用法**（放大看局部细节），所以不能把尺寸压回去
        #expect(subject.size.width > screen.width)
    }

    @Test("在一屏之内正常拖动时，夹取**不该**改变位置")
    func clampIsANoOpForAComfortablePosition() {
        var subject = state()
        let before = subject.frame

        subject.clampInto(screen)

        #expect(subject.frame == before, "本来就在屏幕里，夹取不该动它")
    }

    // MARK: - 控制条

    @Test("控制条贴在钉图的右上角**内侧**")
    func stripSitsInsideTheTopRight() {
        let pin = CGRect(x: 200, y: 300, width: 400, height: 300)

        let strip = PinGeometry.stripFrame(pinFrame: pin, screenFrame: screen)

        #expect(strip.maxX <= pin.maxX, "不能探出右边（钉图常常贴着屏幕边）")
        #expect(strip.maxY <= pin.maxY, "不能探出上边")
        #expect(pin.contains(strip))
        // 贴右上：与右上角的距离应当明显小于到左下角的距离
        let toTopRight = hypot(pin.maxX - strip.maxX, pin.maxY - strip.maxY)
        let toBottomLeft = hypot(strip.minX - pin.minX, strip.minY - pin.minY)
        #expect(toTopRight < toBottomLeft)
    }

    @Test("钉图太小的时候控制条退到框外 —— 挤在图上会把它整个盖住")
    func stripFallsOutsideWhenThePinIsTiny() {
        let pin = CGRect(x: 200, y: 300, width: 60, height: 40)

        let strip = PinGeometry.stripFrame(pinFrame: pin, screenFrame: screen)

        #expect(!pin.intersects(strip), "小钉图上不该有重叠")
    }

    @Test("控制条必须落在屏幕内 —— 点不到的控制条等于没有")
    func stripIsAlwaysOnScreen() {
        // 钉图整个贴在屏幕右上角
        let pin = CGRect(x: screen.maxX - 300, y: screen.maxY - 200, width: 300, height: 200)

        let strip = PinGeometry.stripFrame(pinFrame: pin, screenFrame: screen)

        #expect(screen.contains(strip), "实际 \(strip) 不在 \(screen) 里")
    }

    // MARK: - 尺寸换算

    @Test("像素 → 显示点要除屏幕倍率，否则 2x 屏上钉出来只有一半大")
    func displaySizeDividesByBackingScale() {
        let size = PinGeometry.displaySize(pixelSize: CGSize(width: 800, height: 600),
                                          backingScale: 2)
        #expect(size == CGSize(width: 400, height: 300))

        // 倍率无效时不能除零
        #expect(PinGeometry.displaySize(pixelSize: CGSize(width: 800, height: 600),
                                        backingScale: 0) == CGSize(width: 800, height: 600))
    }
}

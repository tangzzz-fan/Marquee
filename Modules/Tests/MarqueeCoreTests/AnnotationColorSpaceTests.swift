import CoreGraphics
import Foundation
import MarqueeTestSupport
import Testing
@testable import MarqueeCore

/// 色彩空间：截图是 P3 时，导出**不该**把它悄悄转成 sRGB。
///
/// 为什么值得专门测：本机的 `CGColorSpaceCreateDeviceRGB()` 就是 Display P3
/// （见 MEMORY 陷阱 11），所以"导出恒用 sRGB"这条一直是**静默**发生的 ——
/// 它不报错，只是把超出 sRGB 色域的颜色裁掉了，成品与屏幕上看到的不是一回事。
@Suite("导出保留来源色彩空间")
struct AnnotationColorSpaceTests {

    private func p3Context(width: Int = 60, height: Int = 40) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        return CGContext(data: nil,
                         width: width,
                         height: height,
                         bitsPerComponent: 8,
                         bytesPerRow: 0,
                         space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 一块**超出 sRGB 色域**的饱和绿：转成 sRGB 会被裁，正好用来暴露"偷偷转换"
    private func saturatedP3Image() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = p3Context() else { return nil }
        context.setFillColor(CGColor(colorSpace: space, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        return context.makeImage()
    }

    private func rawBytes(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        return Array(UnsafeBufferPointer(start: base, count: CFDataGetLength(data)))
    }

    @Test("P3 的来源图导出后仍是 P3，且底图逐字节不变")
    func preservesSourceColorSpace() throws {
        guard let source = saturatedP3Image() else {
            Issue.record("本机建不出 Display P3 上下文")
            return
        }
        #expect(source.colorSpace?.name == CGColorSpace.displayP3)

        let document = AnnotationDocument(pixelSize: CGSize(width: 60, height: 40))
        guard let rendered = AnnotationRasterizer.image(document: document, source: source) else {
            Issue.record("栅格化失败")
            return
        }

        #expect(rendered.colorSpace?.name == CGColorSpace.displayP3,
                "导出把 P3 转成了 \((rendered.colorSpace?.name as String?) ?? "nil")")
        // 上下文与底图同色彩空间 → 这一步是纯拷贝，一个字节都不该变
        let before = rawBytes(source)
        let after = rawBytes(rendered)
        #expect(before != nil && after != nil)
        #expect(before == after, "底图在导出时被重新编码了（像素值变了）")
    }

    /// 连带必须一起改的一处：`AnnotationColor.cgColor(in:)` 原来是**把 sRGB 分量
    /// 直接塞进目标空间**。目标恒为 sRGB 时它是对的，一旦上下文改为保留 P3，
    /// 同一个"红"就会变成 P3 里的红（更艳）—— 用户挑的颜色在两个空间里不再是同一个颜色。
    @Test("标注颜色按色彩空间转换，而不是把 sRGB 分量塞进 P3")
    func annotationColorIsConverted() throws {
        guard let source = saturatedP3Image() else {
            Issue.record("本机建不出 Display P3 上下文")
            return
        }
        var document = AnnotationDocument(pixelSize: CGSize(width: 60, height: 40))
        document.annotations = [Annotation(kind: .rectangle,
                                          frame: CGRect(x: 5, y: 5, width: 50, height: 30),
                                          style: AnnotationStyle(stroke: AnnotationColor(red: 1, green: 0.23, blue: 0.19),
                                                                 lineWidth: 8),
                                          zIndex: 1)]
        guard let rendered = AnnotationRasterizer.image(document: document, source: source),
              let bitmap = BitmapReader.read(rendered) else {
            Issue.record("栅格化失败")
            return
        }

        // 读回来经过一次 P3 → sRGB，应当回到"用户挑的那个红"（约 255, 59, 48）
        let stroke = bitmap.rgba(x: 30, y: 6)
        #expect(abs(Int(stroke.red) - 255) <= 3, "红分量 \(stroke.red)")
        #expect(abs(Int(stroke.green) - 59) <= 4,
                "绿分量 \(stroke.green)：明显偏低说明 sRGB 分量被当成 P3 用了")
        #expect(abs(Int(stroke.blue) - 48) <= 4, "蓝分量 \(stroke.blue)")

        // 换成"直接塞进 P3"的写法会得到明显更饱和的红 —— 这里顺带确认差异是真实存在的
        let misinterpreted = AnnotationColor(red: 1, green: 0.23, blue: 0.19)
            .cgColor(in: CGColorSpace(name: CGColorSpace.displayP3)!)
        let components = misinterpreted.components ?? []
        #expect(abs((components.count > 1 ? components[1] : 0) - 0.23) > 0.02,
                "转换后的分量不该等于原始 sRGB 数值，否则说明没做转换")
    }

    @Test("sRGB 来源图导出的仍是 sRGB（不受上一条影响）")
    func srgbSourceStaysSRGB() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let source = context.makeImage()!

        let document = AnnotationDocument(pixelSize: CGSize(width: 40, height: 30))
        let rendered = AnnotationRasterizer.image(document: document, source: source)
        #expect(rendered?.colorSpace?.name == CGColorSpace.sRGB)
    }
}

import CoreGraphics
import Foundation
import MarqueeTestSupport
import SwiftUI
import Testing
@testable import MarqueeCore

/// 编辑器画布里的文字方向。
///
/// 为什么值得单独测：`AnnotationRasterizer`（导出）用的是自己搭的"左上原点、y 向下"上下文，
/// 而编辑器走的是 SwiftUI `Canvas` 的 `withCGContext` —— 后者的坐标系由 SwiftUI 决定。
/// 如果两者的 y 方向不一致，编辑器里的文字就会**上下镜像**，而"有没有墨"这类断言看不出来
/// （与底图被画颠倒那次是同一类错误）。这里直接把画布渲染出来读像素。
@MainActor
@Suite("编辑器画布：文字方向与导出一致")
struct AnnotationTextCanvasTests {

    private func renderCanvasText(_ text: String,
                                  fontSize: CGFloat,
                                  at origin: CGPoint,
                                  size: CGSize) -> Bitmap? {
        let view = Canvas { context, _ in
            context.withCGContext { cg in
                AnnotationText.draw(text,
                                    fontSize: fontSize,
                                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                                    at: origin,
                                    in: cg)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return BitmapReader.read(image)
    }

    private func isInk(_ bitmap: Bitmap, _ x: Int, _ y: Int) -> Bool {
        let pixel = bitmap.rgba(x: x, y: y)
        return Int(pixel.red) + Int(pixel.green) + Int(pixel.blue) < 380
    }

    @Test("画布里的 'L' 与导出的一致：竖笔在左、横笔在底、顶部无墨")
    func canvasTextMatchesRasterizer() throws {
        let size = CGSize(width: 120, height: 120)
        let origin = CGPoint(x: 20, y: 20)
        guard let bitmap = renderCanvasText("L", fontSize: 80, at: origin, size: size) else {
            Issue.record("ImageRenderer 没能渲染出画布")
            return
        }
        #expect(bitmap.width == 120 && bitmap.height == 120)
        #expect(bitmap.height == 120)

        func inked(_ rect: CGRect) -> Bool {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) where isInk(bitmap, x, y) { return true }
            }
            return false
        }

        // 竖笔：左侧、中部（origin.y = 20，字号 80，行高约 95）
        #expect(inked(CGRect(x: 22, y: 50, width: 10, height: 20)), "左侧中部应当有竖笔")
        // 横笔：底部
        #expect(inked(CGRect(x: 30, y: 88, width: 30, height: 12)), "底部应当有横笔")
        // 镜像后横笔会跑到顶部
        #expect(!inked(CGRect(x: 30, y: 22, width: 30, height: 10)), "顶部不该有墨（有则文字被上下镜像）")
    }

    @Test("带裁剪的上下文里也能画文字（编辑器要按裁切区裁剪，不能整幅都露出来）")
    func canvasTextInsideClippedContext() throws {
        let size = CGSize(width: 240, height: 120)
        let view = Canvas { context, _ in
            // 只留左半边可见
            var clipped = context
            clipped.clip(to: Path(CGRect(x: 0, y: 0, width: 120, height: 120)))
            clipped.withCGContext { cg in
                AnnotationText.draw("LL",
                                    fontSize: 80,
                                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                                    at: CGPoint(x: 10, y: 20),
                                    in: cg)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let bitmap = BitmapReader.read(image) else {
            Issue.record("ImageRenderer 没能渲染出画布")
            return
        }

        var leftInk = false
        var rightInk = false
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where isInk(bitmap, x, y) {
                if x < 118 { leftInk = true } else { rightInk = true }
            }
        }
        #expect(leftInk, "裁剪区内应当有文字（带 clip 的上下文里 withCGContext 也要能画）")
        #expect(!rightInk, "裁剪区外不该有墨")
    }

    @Test("画布里文字不左右镜像：从左往右长，而不是往左溢出")
    func canvasTextIsNotHorizontallyMirrored() throws {
        let size = CGSize(width: 240, height: 120)
        let origin = CGPoint(x: 20, y: 20)
        guard let bitmap = renderCanvasText("LL", fontSize: 80, at: origin, size: size) else {
            Issue.record("ImageRenderer 没能渲染出画布")
            return
        }

        var minX = Int.max
        var maxX = Int.min
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where isInk(bitmap, x, y) {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        #expect(minX != Int.max, "画布上完全没有墨 —— 文字没画出来")

        // 起笔落在锚点附近（字形有左边距，允许十几像素的偏差）
        #expect(minX >= Int(origin.x) - 2 && minX <= Int(origin.x) + 16,
                "起笔应当靠近锚点 x=\(origin.x)，实际最左墨在 x=\(minX)")
        // 镜像的话墨会往左溢出、总宽度只剩一个字的宽度
        #expect(maxX - minX > 60,
                "两个 L 应当横向铺开，实际墨迹只占 \(maxX - minX) 像素（\(minX)...\(maxX)）")
    }
}

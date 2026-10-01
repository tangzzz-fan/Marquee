import CoreGraphics
import Foundation
import MarqueeCore
import MarqueeTestSupport
import Testing

/// 覆盖层里打码（马赛克 / 模糊）的两件事：
/// ① 底图从哪来、和导出的底图是不是同一张；
/// ② 预览画出来与导出画出来**是不是逐像素一致**。
///
/// 第 ② 件是这一整套设计的全部意义所在 —— 覆盖层与导出共用 `AnnotationDrawing`，
/// 但坐标单位不同（点 vs 像素），中间隔着一个屏幕倍率。
/// 倍率一旦接错，马赛克格子会大一倍或小一半，而"格子大小不对"看起来只是
/// **强度没调对**，几乎不可能联想到是坐标换算。
@Suite("打码底图与预览一致性")
struct OverlayRedactionTests {

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - 造图

    /// 水平渐变：马赛克的格子边界只有在有梯度的地方才数得出来（纯色图是盲的）。
    private func gradient(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for x in 0..<width {
            let value = CGFloat(x) / CGFloat(max(1, width - 1))
            context.setFillColor(CGColor(colorSpace: sRGB, components: [value, value, value, 1])!)
            context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
        }
        return context.makeImage()
    }

    private func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(colorSpace: sRGB, components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 按 `AnnotationDrawing` 的约定准备上下文：**原点左上、y 向下**，
    /// 且 1 个标注单位 = `scale` 个设备像素。
    private func render(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        body(context)
        return context.makeImage()
    }

    // MARK: - 底图从哪来

    @Test("单屏：底图就是选区那块像素，倍率＝该屏的 backing scale")
    func singleDisplayCropsTheSelection() {
        guard let frame = solid(width: 400, height: 200, red: 1, green: 0, blue: 0) else {
            Issue.record("造不出测试图"); return
        }
        let display = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                                      backingScale: 2,
                                      displayID: 1)

        let result = OverlayRedactionSource.make(selection: CGRect(x: 10, y: 20, width: 50, height: 30),
                                                 displays: [display],
                                                 frames: [1: frame])

        #expect(result?.scale == 2)
        #expect(result?.image.width == 100)
        #expect(result?.image.height == 60)
    }

    @Test("缺任何一块屏的冻结帧就整体放弃 —— 不给残缺的底图")
    func missingFrameGivesNoBackdrop() {
        let display = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                                      backingScale: 2,
                                      displayID: 1)

        let result = OverlayRedactionSource.make(selection: CGRect(x: 10, y: 20, width: 50, height: 30),
                                                 displays: [display],
                                                 frames: [:])

        // 缺一块时若交出"残缺底图"，缺的那块会显示成原图 —— 看着像"打码没生效"，
        // 比"这次预览不显示打码"危险得多（用户可能就这么发出去了）。
        #expect(result == nil)
    }

    @Test("跨屏时缺**其中一块**的帧也要整体放弃")
    func missingOneOfTwoFramesGivesNoBackdrop() {
        // ⚠️ 这条与上面那条不是同一件事：单屏缺帧时 `ImageCompositing` 会因为
        // "一片都没有"而返回 nil，**碰巧**也能对。而跨屏缺一块时它会老老实实
        // 拼出一张少了一半的图 —— 那半张会显示成原图，看着像"打码没生效"。
        let left = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   backingScale: 1, displayID: 1)
        let right = DisplayGeometry(frame: CGRect(x: 100, y: 0, width: 100, height: 100),
                                    backingScale: 2, displayID: 2)
        let selection = CGRect(x: 50, y: 0, width: 100, height: 40)
        guard let leftImage = solid(width: 100, height: 100, red: 1, green: 0, blue: 0) else {
            Issue.record("造不出测试图"); return
        }

        let result = OverlayRedactionSource.make(selection: selection,
                                                 displays: [left, right],
                                                 frames: [1: leftImage])   // 少了 2 号屏

        #expect(result == nil)
    }

    @Test("跨屏：按与导出**完全相同**的布局拼接（尺寸与倍率都取自 SelectionLayout）")
    func crossDisplayMatchesExportLayout() {
        let left = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   backingScale: 1, displayID: 1)
        let right = DisplayGeometry(frame: CGRect(x: 100, y: 0, width: 100, height: 100),
                                    backingScale: 2, displayID: 2)
        let selection = CGRect(x: 50, y: 0, width: 100, height: 40)

        guard let layout = SelectionLayout.plan(selection: selection, displays: [left, right]),
              let leftImage = solid(width: 100, height: 100, red: 1, green: 0, blue: 0),
              let rightImage = solid(width: 200, height: 200, red: 0, green: 0, blue: 1) else {
            Issue.record("造不出测试图"); return
        }

        let result = OverlayRedactionSource.make(selection: selection,
                                                 displays: [left, right],
                                                 frames: [1: leftImage, 2: rightImage])

        #expect(result?.scale == layout.outputScale)
        #expect(result?.image.width == Int(layout.outputPixelSize.width))
        #expect(result?.image.height == Int(layout.outputPixelSize.height))

        guard let image = result?.image, let bitmap = BitmapReader.read(image) else {
            Issue.record("读不出底图"); return
        }
        // 左半来自 1x 屏（红），右半来自 2x 屏（蓝）
        #expect(bitmap.rgba(x: 2, y: 20).red > 200)
        #expect(bitmap.rgba(x: image.width - 3, y: 20).blue > 200)
    }

    // MARK: - 预览 == 导出（这一套设计的全部意义）

    @Test("同一个标注、同一块底图：导出（像素、倍率 1）与覆盖层预览（点、倍率 2）**逐像素一致**")
    func previewMatchesExportPixelForPixel() {
        let pixelSize = CGSize(width: 400, height: 80)
        guard let backdrop = gradient(width: 400, height: 80) else {
            Issue.record("造不出测试图"); return
        }

        // 导出：标注早就被 InlineAnnotations 换算成像素（8 点 × 2 = 16 像素），
        // 底图是真实采集到的像素图，倍率 1。
        let exported = render(size: pixelSize, scale: 1) { context in
            let annotation = Annotation(kind: .mosaic,
                                        frame: CGRect(origin: .zero, size: pixelSize),
                                        style: AnnotationStyle(stroke: .red, effectStrength: 16),
                                        zIndex: 0)
            AnnotationDrawing.draw([annotation], in: context, colorSpace: self.sRGB,
                                   source: backdrop, sourceScale: 1)
        }

        // 覆盖层：标注坐标是**点**（尺寸只有一半），底图仍是那块像素图，倍率 2。
        // 强度 8 点 —— 与导出那条路径上 8 点被换算成 16 像素是同一个物理大小。
        let previewed = render(size: pixelSize, scale: 2) { context in
            let annotation = Annotation(kind: .mosaic,
                                        frame: CGRect(origin: .zero,
                                                      size: CGSize(width: 200, height: 40)),
                                        style: AnnotationStyle(stroke: .red, effectStrength: 8),
                                        zIndex: 0)
            AnnotationDrawing.draw([annotation], in: context, colorSpace: self.sRGB,
                                   source: backdrop, sourceScale: 2)
        }

        guard let lhs = exported.flatMap(BitmapReader.read),
              let rhs = previewed.flatMap(BitmapReader.read) else {
            Issue.record("渲染失败"); return
        }

        // 先证明这张图**不是均匀的**（纯色测试图对"格子大小"是盲的）
        let row = lhs.rowLuma(y: 40)
        #expect(Set(row).count > 2, "测试图本身没有梯度，这条断言会变成空跑")

        for y in stride(from: 0, to: pixelSize.height, by: 7) {
            for x in stride(from: 0, to: pixelSize.width, by: 11) {
                #expect(lhs.luma(x: Int(x), y: Int(y)) == rhs.luma(x: Int(x), y: Int(y)),
                        "预览与导出在 (\(x), \(y)) 不一致：\(lhs.luma(x: Int(x), y: Int(y))) vs \(rhs.luma(x: Int(x), y: Int(y)))")
            }
        }
    }

    @Test("模糊同理 —— 两条打码路径都要过这一关")
    func blurPreviewMatchesExport() {
        let pixelSize = CGSize(width: 200, height: 60)
        guard let backdrop = gradient(width: 200, height: 60) else {
            Issue.record("造不出测试图"); return
        }

        let exported = render(size: pixelSize, scale: 1) { context in
            let annotation = Annotation(kind: .blur,
                                        frame: CGRect(origin: .zero, size: pixelSize),
                                        style: AnnotationStyle(stroke: .red, effectStrength: 24),
                                        zIndex: 0)
            AnnotationDrawing.draw([annotation], in: context, colorSpace: self.sRGB,
                                   source: backdrop, sourceScale: 1)
        }
        let previewed = render(size: pixelSize, scale: 2) { context in
            let annotation = Annotation(kind: .blur,
                                        frame: CGRect(origin: .zero,
                                                      size: CGSize(width: 100, height: 30)),
                                        style: AnnotationStyle(stroke: .red, effectStrength: 12),
                                        zIndex: 0)
            AnnotationDrawing.draw([annotation], in: context, colorSpace: self.sRGB,
                                   source: backdrop, sourceScale: 2)
        }

        guard let lhs = exported.flatMap(BitmapReader.read),
              let rhs = previewed.flatMap(BitmapReader.read) else {
            Issue.record("渲染失败"); return
        }
        for y in stride(from: 0, to: pixelSize.height, by: 9) {
            for x in stride(from: 0, to: pixelSize.width, by: 13) {
                #expect(lhs.luma(x: Int(x), y: Int(y)) == rhs.luma(x: Int(x), y: Int(y)))
            }
        }
    }
}

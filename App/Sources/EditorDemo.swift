import CoreGraphics
import MarqueeCore

/// 编辑器演示用的合成图与预置标注。
///
/// ## 为什么要这么一个东西
///
/// 编辑器的渲染（尤其是文字走 CoreText、箭头头部、画笔折线）无法在自动化测试里目视确认，
/// 而走真实截图流程又要屏幕录制权限 —— 链条太长，验证一次的成本很高。
/// 这里用一张**合成图**（纯 CoreGraphics，不需要任何权限）把**七类**标注一次摆全
/// （矩形 / 椭圆 / 箭头 / 画笔 / 文字 / 序号 / 马赛克 / 模糊）：
///
/// ```bash
/// Marquee.app/Contents/MacOS/Marquee -marqueeDemoEditor
/// ```
///
/// 看到的就是"导出时会画成什么样"的直接证据（同样的 `AnnotationText` 与
/// `AnnotationGeometry`，只是画布换成 SwiftUI Canvas）。
enum EditorDemo {

    /// 合成底图：白底 + 稀疏网格 + 几条斜线，方便看出标注有没有对齐、有没有被裁掉。
    static func makeImage(width: Int = 900, height: Int = 600) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.85, 0.87, 0.9, 1])!)
        context.setLineWidth(1)
        for x in stride(from: 0, through: width, by: 50) {
            context.move(to: CGPoint(x: CGFloat(x), y: 0))
            context.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(height)))
        }
        for y in stride(from: 0, through: height, by: 50) {
            context.move(to: CGPoint(x: 0, y: CGFloat(y)))
            context.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(y)))
        }
        context.strokePath()

        // 一条对角斜线：箭头/画笔的贴合度一眼能看出来
        context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.6, 0.65, 0.75, 1])!)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: 40, y: 40))
        context.addLine(to: CGPoint(x: CGFloat(width) - 40, y: CGFloat(height) - 40))
        context.strokePath()

        return context.makeImage()!
    }

    /// 五类标注各一个。坐标用**图像像素**（原点左上），与标注模型一致。
    static var annotations: [Annotation] {
        let red = AnnotationStyle(stroke: .red, lineWidth: 4, fontSize: 36)
        let blue = AnnotationStyle(stroke: AnnotationColor(red: 0.05, green: 0.48, blue: 1),
                                   lineWidth: 6,
                                   fontSize: 36)
        let green = AnnotationStyle(stroke: AnnotationColor(red: 0.2, green: 0.78, blue: 0.35),
                                    lineWidth: 4,
                                    fontSize: 36)

        let text = Annotation(kind: .text,
                              frame: AnnotationText.frame(text: L10n.t("文字标注 ABC"),
                                                          fontSize: red.fontSize,
                                                          origin: CGPoint(x: 60, y: 60)),
                              style: red,
                              zIndex: 5,
                              text: L10n.t("文字标注 ABC"))

        let counter = Annotation.counter(number: 1,
                                         style: blue,
                                         zIndex: 6,
                                         origin: CGPoint(x: 60, y: 140))

        // 打码两块：马赛克压住网格线（块状一眼可见），模糊压住对角斜线（糊没糊一眼可见）
        let mosaic = Annotation(kind: .mosaic,
                                frame: CGRect(x: 380, y: 260, width: 200, height: 120),
                                style: AnnotationStyle(stroke: .red, lineWidth: 1, effectStrength: 16),
                                zIndex: 7)
        let blur = Annotation(kind: .blur,
                              frame: CGRect(x: 620, y: 260, width: 200, height: 120),
                              style: AnnotationStyle(stroke: .red, lineWidth: 1, effectStrength: 16),
                              zIndex: 8)

        return [
            Annotation(kind: .rectangle,
                       frame: CGRect(x: 380, y: 60, width: 200, height: 120),
                       style: red, zIndex: 1),
            Annotation(kind: .ellipse,
                       frame: CGRect(x: 620, y: 60, width: 200, height: 120),
                       style: blue, zIndex: 2),
            Annotation(kind: .arrow,
                       frame: AnnotationGeometry.frame(forPath: [CGPoint(x: 80, y: 520),
                                                                 CGPoint(x: 320, y: 400)],
                                                       lineWidth: green.lineWidth,
                                                       headFrom: CGPoint(x: 80, y: 520),
                                                       headTo: CGPoint(x: 320, y: 400)),
                       style: green, zIndex: 3,
                       path: [CGPoint(x: 80, y: 520), CGPoint(x: 320, y: 400)]),
            Annotation(kind: .pen,
                       frame: AnnotationGeometry.frame(forPath: [CGPoint(x: 420, y: 520),
                                                                 CGPoint(x: 480, y: 440),
                                                                 CGPoint(x: 540, y: 540),
                                                                 CGPoint(x: 600, y: 430),
                                                                 CGPoint(x: 700, y: 500)],
                                                       lineWidth: 5),
                       style: AnnotationStyle(stroke: AnnotationColor(red: 1, green: 0.58, blue: 0),
                                              lineWidth: 5),
                       zIndex: 4,
                       path: [CGPoint(x: 420, y: 520), CGPoint(x: 480, y: 440),
                              CGPoint(x: 540, y: 540), CGPoint(x: 600, y: 430),
                              CGPoint(x: 700, y: 500)]),
            text,
            counter,
            mosaic,
            blur,
        ]
    }
}

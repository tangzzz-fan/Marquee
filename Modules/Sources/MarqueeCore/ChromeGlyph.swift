#if canImport(AppKit)
import AppKit

/// 自绘图标（`AnnotationGlyph`）的 AppKit 渲染。**全项目唯一一份。**
///
/// ## 为什么单独有一个渲染器
///
/// 因为几何在 Core、而"怎么画"不该跟着一起复制。钉图这枚现在有两个落点
/// （覆盖层工具条第 13 格、升级卡片的图标槽），两处各写一段 `NSBezierPath` 的话，
/// 它们不会报错 —— 只会在某次改动里分叉成两个形状（`AnnotationIcon` 的文件头
/// 记的就是这类错）。所以两个落点都走这里。
///
/// ## 与 `ChromeSymbol` 的分工
///
/// `ChromeSymbol` 管**系统符号**（取图 + 缓存 + 着色）；这里管**自绘图形**。
/// 两者不互相调用 —— 混起来的话，"哪些图标来自系统"会变成一个只有读实现才知道的事。
///
/// ## 不做缓存，也**不加 `@MainActor`**
///
/// `ChromeSymbol` 那层缓存是必需的（`NSImage(systemSymbolName:)` 每次调用都新建图像，
/// 而工具条一帧要画 15 个），也正是它需要主线程隔离。
/// 这里没有那个问题：一枚图形最多 3 条子路径、十几个点，
/// 构造 `NSBezierPath` 的代价远在绘制噪声之下 —— **为它加一个缓存只会多一处要失效的状态**，
/// 而没有状态就不需要隔离标注。加一个 `@MainActor` 只会让
/// `Tools/SymbolProbe` 那种裸命令行探针凭空多一层 `assumeIsolated`。
///
/// （调用方本来就都在主线程上：AppKit 的 `draw` 与 SwiftUI 的 `makeNSView` 都是。
/// 那是 AppKit 的规矩，不是这个类型该替它记的事。）
public enum ChromeGlyph {

    /// 把一枚自绘图标画在矩形**正中**。
    ///
    /// - Parameter inkHeight: 这枚图形**墨迹**要多高（点）。默认值是
    ///   `AnnotationGlyph.toolbarInkHeight`（工具条上那颗，与被换掉的 SF Symbol 一样高）。
    ///   卡片那侧要自己给自己的值 —— 卡片上的图标槽与工具条不是同一个尺寸。
    public static func draw(_ glyph: AnnotationGlyph,
                            in rect: CGRect,
                            color: NSColor,
                            inkHeight: CGFloat) {
        let side = glyph.side(fittingInkHeight: inkHeight)
        // 图形盒子按 rect **正中**摆：稿子的几何在 16 格里是居中的
        //（`inkBounds` 横竖对称），所以居中摆就等于"视觉上居中"。
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)

        color.setStroke()
        for part in glyph.parts {
            let path = NSBezierPath()
            path.lineWidth = glyph.strokeWidth * side / glyph.grid
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            switch part {
            case .circle(let center, let radius):
                let c = glyph.point(center, side: side)
                let r = radius * side / glyph.grid
                path.appendOval(in: CGRect(x: origin.x + c.x - r,
                                           y: origin.y + c.y - r,
                                           width: r * 2, height: r * 2))
            case .polyline(let points, let closed):
                guard !points.isEmpty else { continue }
                for (index, point) in points.enumerated() {
                    let p = glyph.point(point, side: side)
                    let target = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
                    if index == 0 { path.move(to: target) } else { path.line(to: target) }
                }
                if closed { path.close() }
            }
            path.stroke()
        }
    }
}
#endif

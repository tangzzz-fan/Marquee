import CoreGraphics
import Testing

@testable import MarqueeCore

/// 自绘图标的几何（目前只有钉图一枚）。
///
/// ## 为什么值得单开一个 suite
///
/// 因为稿子 ⑩ §06 给这枚图形写了**四条可以算出来的硬约束**，而它们全都是
/// "错了也不报错、只是图看着不对" 那一类：
///
/// 1. 视觉边界 x 4.15–11.85 · y 1.65–14.15（横竖都居中）；
/// 2. 领口**从头的 45° 处接出**（不是"大概贴着"）；
/// 3. 针与横档**同轴**，一根线，不并线；
/// 4. 针只占 x 7.25–8.75，**右下 9 × 9 完整留给 Pro 锁**。
///
/// 写在注释里的话，某天有人挪一格也没人知道；写成断言之后至少会红一次。
@Suite("自绘图标几何（稿子 ⑩ §06）")
struct AnnotationGlyphTests {

    private let pin = AnnotationGlyph.pin

    // MARK: - 稿子给的那四条

    @Test("钉图的视觉边界就是稿子写的那一串 —— 横竖都居中")
    func inkBoundsMatchSpec() {
        let box = pin.inkBounds
        #expect(abs(box.minX - 4.15) < 0.001)
        #expect(abs(box.maxX - 11.85) < 0.001)
        #expect(abs(box.minY - 1.65) < 0.001)
        #expect(abs(box.maxY - 14.15) < 0.001)

        // 「横竖向都居中」—— 这条比四个具体数字更重要：数字改一格时居中还可能成立，
        // 而中心一旦偏了，图标在格子里就是歪的（那正是这枚图形当初被重画的理由之一）。
        #expect(abs(box.minX - (pin.grid - box.maxX)) < 0.001, "左右不对称")

        // ⚠️ **稿子写的是「横竖向都居中」，而它自己给的那条路径并不满足这一句。**
        //
        // 实测：y 的上下余量是 1.65 与 1.85，**差 0.2 格**（换算到工具条上约 0.27 点）。
        // 这里选择相信**路径数据**而不是那句描述 —— 数据是它真正画出来的东西，
        // 而且 0.2 格在任何尺寸下都看不出来。
        //
        // 留着这条断言是为了别让将来的人拿"居中"当依据去挪它：
        // 挪完这条仍是绿的，但下面"针不伸进锁位"那条的余量就变了 ——
        // **一条搬得动的依据比没有依据更危险。**
        #expect(abs(box.minY - (pin.grid - box.maxY)) < 0.25,
                "上下偏移 \(abs(box.minY - (pin.grid - box.maxY))) 格 —— 稿子的路径值是 0.2，超出说明被挪过")
    }

    @Test("领口从头（圆）的 45° 处接出 —— 端点正好落在圆上")
    func collarStartsOnHead() {
        guard case .circle(let center, let radius) = pin.parts[0],
              case .polyline(let collar, _) = pin.parts[1],
              let first = collar.first, let last = collar.last else {
            Issue.record("钉图的前两段必须是一个圆 + 一条折线")
            return
        }
        for point in [first, last] {
            let distance = ((point.x - center.x) * (point.x - center.x)
                            + (point.y - center.y) * (point.y - center.y)).squareRoot()
            #expect(abs(distance - radius) < 0.005,
                    "领口端点 (\(point.x), \(point.y)) 离头心 \(distance)，而半径是 \(radius) —— 接不上就是一条断线")
        }
        // 45°：两端与头心的连线应当是对角方向（|dx| == |dy|）
        #expect(abs(abs(first.x - center.x) - abs(first.y - center.y)) < 0.001,
                "领口不是从 45° 处接出来的")
    }

    @Test("针与横档同轴，一根线 —— 不并线")
    func needleIsCoaxial() {
        guard let needleX = pin.verticalStrokeX,
              let collarBox = pin.bounds(ofPartAt: 1) else {
            Issue.record("钉图必须有一段竖直的针，以及一段横档")
            return
        }
        #expect(abs(needleX - collarBox.midX) < 0.001,
                "针在 x=\(needleX)，横档中心在 x=\(collarBox.midX) —— 不同轴看起来就是歪的")
        #expect(abs(needleX - 8) < 0.001, "稿子把针定在 x = 8")
    }

    @Test("针够窄，不会伸进右下角那块 Pro 锁的位置")
    func needleClearsTheLockBadge() {
        // 锁在格的右下角：28 的格子里占 9 × 9、离右下各 2（稿子 §07 的锁位）。
        let cell = OverlayToolbar.buttonSize
        let lockLeftEdge = cell - EditorChrome.lockBadgeSize - 2

        let side = pin.side(fittingInkHeight: AnnotationGlyph.toolbarInkHeight)
        let originX = (cell - side) / 2
        guard case .polyline(let needle, _) = pin.parts[2] else {
            Issue.record("第三段必须是针")
            return
        }
        let scale = side / pin.grid
        let halfStroke = pin.strokeWidth / 2 * scale
        let rightInk = originX + (needle.map(\.x).max() ?? 0) * scale + halfStroke

        #expect(rightInk < lockLeftEdge,
                "针的右缘落在格内 x=\(rightInk)，而锁从 x=\(lockLeftEdge) 起 —— 叠上了")
    }

    // MARK: - 换图形不换大小

    @Test("按稿子的墨迹高度摆，图形算出来的边长正好让墨迹高 17 点")
    func sideMatchesTargetInkHeight() {
        let side = pin.side(fittingInkHeight: AnnotationGlyph.toolbarInkHeight)
        let rendered = pin.inkBounds.height * side / pin.grid
        #expect(abs(rendered - AnnotationGlyph.toolbarInkHeight) < 0.001,
                "算出来 \(rendered) 点，而目标是被换掉那枚 SF Symbol 的墨迹高度 17 点")

        // ⚠️ 目标值本身也要钉住：它来自实测（`Tools/SymbolProbe`：
        // SF Symbol `pin` @ pointSize 14 / .medium 的墨迹是 11 × 17）。
        // 改这一个数等于"顺手把钉图放大/缩小一档"，而那是一次**没人要求过的改动**。
        #expect(AnnotationGlyph.toolbarInkHeight == 17)
    }

    // MARK: - 坐标翻转

    @Test("网格坐标翻到画布坐标时 y 要翻过来 —— 否则图钉是倒的")
    func gridCoordinatesFlipY() {
        let side: CGFloat = 16
        guard case .circle(let center, _) = pin.parts[0],
              case .polyline(let needle, _) = pin.parts[2],
              let needleBottom = needle.last else {
            Issue.record("钉图的前/后段形状变了")
            return
        }
        // 稿子的 y 向下、画布 y 向上：头应当落在**更大**的 y 上（视觉上在上方）。
        let head = pin.point(center, side: side)
        let tip = pin.point(needleBottom, side: side)
        #expect(head.y > tip.y,
                "头在 y=\(head.y)、针尖在 y=\(tip.y) —— 这样画出来是一枚**倒着**的图钉")
    }

    // MARK: - 结构

    @Test("三段：圆头 + 横档 + 直针，与稿子一字不差")
    func partsMatchSpec() {
        #expect(pin.parts.count == 3)
        #expect(pin.grid == 16)
        #expect(pin.strokeWidth == 1.5)
        guard case .circle(let center, let radius) = pin.parts[0] else {
            Issue.record("第一段必须是圆头")
            return
        }
        #expect(center == CGPoint(x: 8, y: 4.8))
        #expect(radius == 2.4)
        // 横档与针都是**开口折线**：稿子是一笔线描，两端各自收圆头，
        // 靠"两端都落在圆上"接上（上一条断言的就是这个）。
        for index in [1, 2] {
            guard case .polyline(_, let closed) = pin.parts[index] else {
                Issue.record("第 \(index) 段必须是折线")
                return
            }
            #expect(!closed)
        }
    }
}

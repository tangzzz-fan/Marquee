import CoreGraphics

/// **自绘图标**的几何。坐标一律给在 16 格坐标系里（与 SF Symbol 的 viewBox 同构），
/// 渲染方自己乘缩放系数。
///
/// ## 为什么图形数据要放在 Core
///
/// 因为同一枚图标**不止一处要画**。钉图这枚现在有两个落点：覆盖层工具条第 13 格、
/// 升级卡片左上角的图标槽。两处各写一遍路径的话，它们**不会报错、也不会崩** ——
/// 只会在某一次改动里分叉成两个不一样的「钉图」，而用户只会觉得这个 app 有点糙。
/// 这与 `AnnotationIcon` 那条「同一功能同一图标」是同一条规矩，只是这次不是符号名，
/// 而是**几何本身**。
///
/// ## 为什么不用 SF Symbol
///
/// 稿子 ⑩ §06 明确要求偏离系统惯例（原话：「**故意不随 macOS 的 45° 斜针惯例**，
/// 登记在案」），理由是正面图钉的公众认知是「圆头 + 横档 + 针」，
/// 而横档正是它和「笔」在一条 16 点宽的条上唯一的区分点（见 `pin` 的注释）。
/// 这是**一次自觉的例外**，不是把图标体系改成自绘 —— 其余图标仍然只从 SF Symbol 取。
public struct AnnotationGlyph: Equatable, Sendable {

    /// 一条子路径。
    ///
    /// 只支持圆与折线两种：这枚图形只用得到这两种，而多一种就多一处要在
    /// 两个渲染端各实现一遍的东西（弧线在两端的参数化差一点点，画出来就是两个形状）。
    public enum Part: Equatable, Sendable {
        /// 整圆（描边，不填充）。
        case circle(center: CGPoint, radius: CGFloat)
        /// 折线。`closed` 为真时首尾相连 —— 稿子批评旧图的第一条正是"收口边没画"。
        case polyline(points: [CGPoint], closed: Bool)
    }

    public let parts: [Part]
    /// 坐标所在的格子边长。稿子给的就是 **16**，与工具条上其余图标的 viewBox 一致。
    public let grid: CGFloat
    /// 笔画宽度，也在**格**里给（稿子：1.5）。
    public let strokeWidth: CGFloat

    public init(parts: [Part], grid: CGFloat = 16, strokeWidth: CGFloat = 1.5) {
        self.parts = parts
        self.grid = grid
        self.strokeWidth = strokeWidth
    }

    /// 墨迹包围盒（**含笔画半宽**）—— 稿子 §06 就是用它给钉图定了两条硬约束。
    public var inkBounds: CGRect {
        var box: CGRect?
        for part in parts {
            let one: CGRect
            switch part {
            case .circle(let center, let radius):
                one = CGRect(x: center.x - radius, y: center.y - radius,
                             width: radius * 2, height: radius * 2)
            case .polyline(let points, _):
                guard let first = points.first else { continue }
                var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
                for p in points.dropFirst() {
                    minX = min(minX, p.x); maxX = max(maxX, p.x)
                    minY = min(minY, p.y); maxY = max(maxY, p.y)
                }
                one = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            box = box.map { $0.union(one) } ?? one
        }
        let half = strokeWidth / 2
        return (box ?? .zero).insetBy(dx: -half, dy: -half)
    }

    /// 让墨迹高度正好是 `inkHeight` 点时，一格该映射成多少点。
    ///
    /// 用它是为了**换图标不换大小**：把 SF Symbol 换成自绘图形时，
    /// "新图形在条上占多大"若各人各拍一个数，换完就会出现"钉图比邻居大一圈"。
    /// 所以目标值取的是**被换掉那枚符号的实测墨迹高度**，见 `AnnotationGlyph.toolbarInkHeight`。
    public func side(fittingInkHeight inkHeight: CGFloat) -> CGFloat {
        guard inkBounds.height > 0 else { return grid }
        return grid * inkHeight / inkBounds.height
    }

    /// 把一格坐标换成"以矩形正中为原点、边长为 `side`"的画布坐标。
    ///
    /// ⚠️ **这里做了一次 y 翻转**：稿子的 SVG 坐标原点在左上、y 向下，
    /// 而 AppKit / 渲染端是 y 向上。不翻的话画出来是**上下颠倒**的图钉 ——
    /// 它照样是一枚好看的图钉（所以不看图很难发现），只是针朝上。
    public func point(_ grid: CGPoint, side: CGFloat) -> CGPoint {
        let scale = side / self.grid
        return CGPoint(x: grid.x * scale, y: (self.grid - grid.y) * scale)
    }

    // MARK: - 全项目共用的那几枚

    /// 工具条上图标的目标墨迹高度（点）。
    ///
    /// **实测值**，不是拍的：SF Symbol `pin` 在 `pointSize 14 / .medium` 下
    /// 墨迹为 **11 × 17**（`Tools/SymbolProbe` 量的；同一批里 `square.and.arrow.down`
    /// 是 13 × 15、`xmark` 12 × 12、`text.viewfinder` 14 × 14）。
    /// 也就是说钉图本来就是条上最高的那一枚 —— 换图形不该顺手把它缩小或放大。
    public static let toolbarInkHeight: CGFloat = 17

    /// **钉图**（稿子 ⑩ §06）。
    ///
    /// 三件事，各自到位（稿子原话）：
    ///
    /// | 件 | 几何 | 为什么 |
    /// | --- | --- | --- |
    /// | 圆头 | `circle 8 4.8 r2.4` | 领口从头的 45° 处接出 |
    /// | 横档 | `M6.3 6.5 4.9 8.9h6.2l-1.4-2.4` | 图钉的「指纹」，**也是它和笔的区别** |
    /// | 直针 | `M8 8.9v4.5` | 与横档同轴，一根线，不并线 |
    ///
    /// 旧图形被否掉的三条（都只在缩到 1× 时才发作）：
    /// ① 轮廓不闭合（收口边根本没画）；② 右肩两笔相距 0.92，1.5 的笔画压下去并成一条糊带；
    /// ③ 斜置 —— 全条唯一不站直的图标。
    ///
    /// ⚠️ 稿子还说旧图「上一版在这里读起来像第二支笔 —— brush 就在同一条斜线上」。
    /// 那一句针对的是**稿子自己手绘转录的版本**；实装当时用的是 SF Symbol `pin`，
    /// 它本来就是站直的、闭合的、不并线的（见 `docs/design/2026-10-04-玻璃材质/对照.md`）。
    /// ⇒ **这次改的是「像不像图钉」，不是「修一个 16px 下糊掉的 bug」。**
    public static let pin = AnnotationGlyph(parts: [
        .circle(center: CGPoint(x: 8, y: 4.8), radius: 2.4),
        .polyline(points: [CGPoint(x: 6.3, y: 6.5),
                           CGPoint(x: 4.9, y: 8.9),
                           CGPoint(x: 11.1, y: 8.9),
                           CGPoint(x: 9.7, y: 6.5)],
                  closed: false),
        .polyline(points: [CGPoint(x: 8, y: 8.9), CGPoint(x: 8, y: 13.4)],
                  closed: false),
    ])

    /// 图形里**竖直的那一段**（起止点 x 相同）的 x 值。钉图的那根针就是它。
    ///
    /// 单独把它挑出来，是为了让稿子那两句"硬要求"能变成断言：
    /// 「与横档同轴，一根线，不并线」与「针只占 x 7.25–8.75，**右下 9 × 9 完整留给 Pro 锁**」。
    /// 不挑出来的话，那两句就只是注释 —— 某天有人把针挪歪两格，没有任何东西会响。
    public var verticalStrokeX: CGFloat? {
        for part in parts {
            guard case .polyline(let points, _) = part,
                  points.count >= 2,
                  let first = points.first,
                  let last = points.last,
                  abs(first.x - last.x) < 0.001 else { continue }
            return first.x
        }
        return nil
    }

    /// 某个子路径的格坐标包围盒（**不含**笔画）。按声明顺序取第 `index` 条。
    public func bounds(ofPartAt index: Int) -> CGRect? {
        guard parts.indices.contains(index) else { return nil }
        switch parts[index] {
        case .circle(let center, let radius):
            return CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        case .polyline(let points, _):
            guard let first = points.first else { return nil }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points.dropFirst() {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}

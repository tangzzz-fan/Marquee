import CoreGraphics

/// 选区的几何编辑：拖控制点改大小、拖框内移动、`⇧` 锁比例、边缘吸附。
///
/// ## 为什么全是纯函数
///
/// 这些规则靠肉眼试不全 —— "对边固定"只在拖到极限时才看得出问题，
/// "最小尺寸该停住而不是翻转"要故意拖过头才撞得到，
/// 而"吸附"更是得拿标尺量。抽成纯函数之后这些都能脱机断言。
///
/// ## 坐标
///
/// 与 `SelectionSession` 一样，**不关心单位**，但调用方必须一致：
/// 覆盖层喂进来的是 **Cocoa 全局点坐标**（y 向上）。
/// 所以下面所有叫 `top` 的东西都是 **`maxY`** —— 写反了不会崩，只会让
/// "拖上边"变成"拖下边"，而且**只在拖到极限或看吸附线时**才显得不对。
public enum SelectionGeometry {

    /// 把"原点左上、y 向下"的矩形 / 点换成 Cocoa 那一套（y 向上）。
    ///
    /// ## 为什么需要这一层
    ///
    /// `Handle` 是按 **Cocoa 约定**命名的：`.top` = **`maxY`**（`movingEdges` 同理）。
    /// 而**标注**的坐标系是"原点左上、y 向下"（`Annotation` 的约定）。
    /// 把标注的框直接喂给上面的函数，用户拖"上边"动的是**下边** ——
    /// 不崩、不报错，而且**只在拖到极限或锁比例时**才显得怪（PITFALLS 59 的同一族）。
    ///
    /// 翻转是**对合**的（`flip(flip(x)) == x`），所以进去翻一次、出来翻一次就还原。
    /// 有一对测试专门钉住"拖左上角动的确实是视觉左上角"。
    public enum YDown {
        public static func flip(_ rect: CGRect) -> CGRect {
            let box = rect.standardized
            return CGRect(x: box.minX, y: -box.maxY, width: box.width, height: box.height)
        }

        public static func flip(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: -point.y)
        }
    }

    /// 控制点的命中半径（点）。与编辑器的 `AnnotationHandle` 同一量级，手感一致。
    public static let handleHitRadius: CGFloat = 6
    /// 控制点画出来的边长（点）。比命中区小 —— 画 12 点的方块太抢眼，
    /// 而"看得见的小方块 + 摸得到的 12 点命中区"是这类控件的通行做法。
    ///
    /// ⚠️ 这是**白芯**的边长，不是控制点的整体足迹：黑边还各占 1 点（见下一条）。
    public static let handleVisualSide: CGFloat = 5

    /// 控制点那圈黑边的宽度（点）。
    ///
    /// 控制点是画在**别人的内容**上的（选区里是用户要截的那片画面），
    /// 所以它和选区描边、吸附线一样走「白芯黑边」那条纪律 ——
    /// 纯白的小方块压在一张白底网页上就等于没画。
    public static let handleEdgeWidth: CGFloat = 1

    /// 控制点的**整体足迹**（点）：白芯 + 两侧各一圈黑边。
    ///
    /// 设计稿 §02 给的是「7 × 7 白芯黑边」—— 而 `5 + 1 + 1 = 7`，两者对得上。
    /// 单独留一个常量是为了让"改了白芯大小、足迹就跟着变"这件事**明摆着**，
    /// 而不是散在两处的加法（散着写的话，改了芯忘了边，控制点之间就会开始互相咬）。
    public static var handleVisualFootprint: CGFloat { handleVisualSide + handleEdgeWidth * 2 }
    /// 最小边长（点）。沿用"框小于 8 像素视为误操作"的阈值。
    public static let minimumSide: CGFloat = 8
    /// 吸附阈值（点）。
    public static let snapThreshold: CGFloat = 6

    // MARK: - 控制点

    /// 八个控制点：四角 + 四边中点。
    ///
    /// 顺序即绘制顺序，也是命中测试的顺序（角优先于边 —— 角上的命中区与相邻边的
    /// 命中区会重叠一点点，先判角更符合直觉：视觉上角更"尖"）。
    public enum Handle: CaseIterable, Sendable, Equatable {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left

        public var isCorner: Bool {
            switch self {
            case .top, .bottom, .left, .right: false
            case .topLeft, .topRight, .bottomLeft, .bottomRight: true
            }
        }

        /// 拖这个控制点时，矩形的哪几条边跟着动（其余边固定）。
        ///
        /// ⚠️ `top` 对应 **`maxY`**（Cocoa y 向上）。
        public var movingEdges: Edge {
            switch self {
            case .topLeft: [.minX, .maxY]
            case .top: [.maxY]
            case .topRight: [.maxX, .maxY]
            case .right: [.maxX]
            case .bottomRight: [.maxX, .minY]
            case .bottom: [.minY]
            case .bottomLeft: [.minX, .minY]
            case .left: [.minX]
            }
        }

        /// 控制点的中心（Cocoa 约定：`top` = `maxY`）。
        public func center(on rect: CGRect) -> CGPoint {
            let box = rect.standardized
            return switch self {
            case .topLeft: CGPoint(x: box.minX, y: box.maxY)
            case .top: CGPoint(x: box.midX, y: box.maxY)
            case .topRight: CGPoint(x: box.maxX, y: box.maxY)
            case .right: CGPoint(x: box.maxX, y: box.midY)
            case .bottomRight: CGPoint(x: box.maxX, y: box.minY)
            case .bottom: CGPoint(x: box.midX, y: box.minY)
            case .bottomLeft: CGPoint(x: box.minX, y: box.minY)
            case .left: CGPoint(x: box.minX, y: box.midY)
            }
        }
    }

    /// 控制点的命中区（Cocoa 坐标下的正方形）。
    public static func handleFrame(_ handle: Handle,
                                   on rect: CGRect,
                                   radius: CGFloat = handleHitRadius) -> CGRect {
        let center = handle.center(on: rect)
        return CGRect(x: center.x - radius,
                      y: center.y - radius,
                      width: radius * 2,
                      height: radius * 2)
    }

    /// 点在哪个控制点上（`nil` = 不在任何控制点上）。
    ///
    /// 用 `allCases` 的顺序遍历，角在边之前 —— 两者命中区在角上重叠，
    /// 先判角才不会出现"明明点在角上却按边处理"。
    public static func handle(at point: CGPoint,
                              in rect: CGRect,
                              radius: CGFloat = handleHitRadius) -> Handle? {
        Handle.allCases.first { handleFrame($0, on: rect, radius: radius).contains(point) }
    }

    // MARK: - 缩放

    /// 拖控制点改大小：对边固定，最小尺寸**停住而不翻转**。
    ///
    /// - Parameter aspect: 非 `nil` 时锁宽高比（`⇧`）。只有四角支持 —— 边中点的
    ///   语义是"只改一个方向"，锁比例会和它直接冲突。
    public static func resized(_ rect: CGRect,
                               handle: Handle,
                               to point: CGPoint,
                               aspect: CGFloat? = nil,
                               minimum: CGFloat = minimumSide) -> CGRect {
        if let aspect, handle.isCorner, aspect > 0 {
            return resizedLockingAspect(rect, handle: handle, to: point,
                                        aspect: aspect, minimum: minimum)
        }

        let box = rect.standardized
        var minX = box.minX, maxX = box.maxX
        var minY = box.minY, maxY = box.maxY

        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }

        // 最小尺寸：把**动的那条边**顶回去，而不是让框翻面。
        //
        // 拖过头时"翻转"看起来像"框突然跳到另一边"，而用户以为自己只是拖到了极限。
        // 停住则是符合直觉的（系统截图工具都是这个行为）。
        if maxX - minX < minimum {
            if handle.movingEdges.contains(.minX), !handle.movingEdges.contains(.maxX) {
                minX = maxX - minimum
            } else if handle.movingEdges.contains(.maxX), !handle.movingEdges.contains(.minX) {
                maxX = minX + minimum
            }
        }
        if maxY - minY < minimum {
            if handle.movingEdges.contains(.minY), !handle.movingEdges.contains(.maxY) {
                minY = maxY - minimum
            } else if handle.movingEdges.contains(.maxY), !handle.movingEdges.contains(.minY) {
                maxY = minY + minimum
            }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `⇧` 锁比例：以**对角固定**为基准，取位移较大的那一轴决定尺寸。
    private static func resizedLockingAspect(_ rect: CGRect,
                                             handle: Handle,
                                             to point: CGPoint,
                                             aspect: CGFloat,
                                             minimum: CGFloat) -> CGRect {
        let box = rect.standardized
        let fixed: CGPoint
        switch handle {
        case .topLeft: fixed = CGPoint(x: box.maxX, y: box.minY)
        case .topRight: fixed = CGPoint(x: box.minX, y: box.minY)
        case .bottomLeft: fixed = CGPoint(x: box.maxX, y: box.maxY)
        case .bottomRight: fixed = CGPoint(x: box.minX, y: box.maxY)
        default: fixed = CGPoint(x: box.midX, y: box.midY)
        }

        // 取"较大的那一轴"决定尺寸，而不是只看横向 ——
        // 只看横向的话，用户往下拖得再多、框也纹丝不动，像是卡住了。
        let dx = abs(point.x - fixed.x)
        let dy = abs(point.y - fixed.y)
        var width = max(dx, dy * aspect)
        var height = width / aspect
        if width < minimum { width = minimum; height = width / aspect }
        if height < minimum { height = minimum; width = height * aspect }

        let originX = point.x < fixed.x ? fixed.x - width : fixed.x
        let originY = point.y < fixed.y ? fixed.y - height : fixed.y
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    // MARK: - 吸附

    /// 参与吸附的边。
    public struct Edge: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let minX = Edge(rawValue: 1 << 0)
        public static let maxX = Edge(rawValue: 1 << 1)
        public static let minY = Edge(rawValue: 1 << 2)
        public static let maxY = Edge(rawValue: 1 << 3)
        public static let all: Edge = [.minX, .maxX, .minY, .maxY]
    }

    /// 吸附线集合。屏幕可见区与每扇窗的边界都往这里丢。
    public struct SnapTargets: Equatable, Sendable {
        public var verticalLines: [CGFloat]
        public var horizontalLines: [CGFloat]

        public init(verticalLines: [CGFloat] = [], horizontalLines: [CGFloat] = []) {
            self.verticalLines = verticalLines
            self.horizontalLines = horizontalLines
        }

        /// 从一堆矩形收集四条边。
        ///
        /// **只收边、不收中线**：中线吸附会在不该吸的地方吸住
        /// （用户想把框拉到窗口左边，结果先被窗口正中吸了一下），
        /// 而它的收益远小于这个别扭。
        public static func edges(of rects: [CGRect]) -> SnapTargets {
            var verticals: [CGFloat] = []
            var horizontals: [CGFloat] = []
            for rect in rects {
                let box = rect.standardized
                verticals.append(box.minX)
                verticals.append(box.maxX)
                horizontals.append(box.minY)
                horizontals.append(box.maxY)
            }
            return SnapTargets(verticalLines: verticals, horizontalLines: horizontals)
        }

        public var isEmpty: Bool { verticalLines.isEmpty && horizontalLines.isEmpty }
    }

    /// 吸附结果。
    public struct SnapResult: Equatable, Sendable {
        public var rect: CGRect
        /// 吸上的那条竖线的 x（`nil` = 这个方向没吸上）。界面用它画提示线 ——
        /// 没有提示线的话，用户只会觉得"这里有点顿"，说不上来在吸。
        public var verticalLine: CGFloat?
        public var horizontalLine: CGFloat?
    }

    /// 一组候选值对一组吸附线的最优吸附。返回"哪个值吸到了哪条线"。
    ///
    /// 只返回**一个**（最接近的）：如果两条边各吸各的，矩形会被拉伸变形，
    /// 而用户只是想把它挪过去。
    static func match(values: [CGFloat],
                      lines: [CGFloat],
                      threshold: CGFloat) -> (source: CGFloat, target: CGFloat)? {
        var best: (source: CGFloat, target: CGFloat, distance: CGFloat)?
        for value in values {
            for line in lines {
                let distance = abs(line - value)
                guard distance <= threshold else { continue }
                if best == nil || distance < best!.distance {
                    best = (value, line, distance)
                }
            }
        }
        guard let best else { return nil }
        return (best.source, best.target)
    }

    /// 吸附一个矩形。
    ///
    /// - Parameter edges: 哪些边参与吸附。移动整框时是 `.all`；拖控制点时是
    ///   `handle.movingEdges`（**固定边不该参与** —— 否则用户拖上边，下边却被吸走，
    ///   框会莫名其妙地长高）。
    ///
    /// 两条 x 边都在 `edges` 里时按**平移**处理（尺寸不变）；
    /// 只有一条时只动那一条边。混着来会让"移动"变成"拉伸"。
    public static func snapped(_ rect: CGRect,
                               edges: Edge,
                               targets: SnapTargets,
                               threshold: CGFloat = snapThreshold) -> SnapResult {
        var box = rect.standardized
        var verticalLine: CGFloat?
        var horizontalLine: CGFloat?

        let hasMinX = edges.contains(.minX)
        let hasMaxX = edges.contains(.maxX)
        if hasMinX || hasMaxX {
            let values = (hasMinX ? [box.minX] : []) + (hasMaxX ? [box.maxX] : [])
            if let hit = match(values: values, lines: targets.verticalLines, threshold: threshold) {
                let offset = hit.target - hit.source
                verticalLine = hit.target
                if hasMinX && hasMaxX {
                    box.origin.x += offset
                } else if hasMinX {
                    box.origin.x += offset
                    box.size.width -= offset
                } else {
                    box.size.width += offset
                }
            }
        }

        let hasMinY = edges.contains(.minY)
        let hasMaxY = edges.contains(.maxY)
        if hasMinY || hasMaxY {
            let values = (hasMinY ? [box.minY] : []) + (hasMaxY ? [box.maxY] : [])
            if let hit = match(values: values, lines: targets.horizontalLines, threshold: threshold) {
                let offset = hit.target - hit.source
                horizontalLine = hit.target
                if hasMinY && hasMaxY {
                    box.origin.y += offset
                } else if hasMinY {
                    box.origin.y += offset
                    box.size.height -= offset
                } else {
                    box.size.height += offset
                }
            }
        }

        return SnapResult(rect: box, verticalLine: verticalLine, horizontalLine: horizontalLine)
    }
}

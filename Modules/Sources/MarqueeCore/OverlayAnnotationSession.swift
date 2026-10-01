import CoreGraphics
import Foundation

/// 覆盖层里"就地画标注"的状态机：选工具、落笔、收笔、撤销、重做。
///
/// ## 坐标
///
/// 一律用**选区局部点**：原点 = 选区的左上角，x 向右、y **向下**。
/// 于是它和 `Annotation` 的坐标系（原点左上、y 向下）完全一致，
/// 只有"单位是点还是像素"一处差别 —— 栅格化时按选区尺寸乘一次就完事。
///
/// 为什么不直接存像素：覆盖层是逐屏点坐标工作的，画的时候 1 点 = 1 屏幕点，
/// 线宽与字号按"看起来多粗"来定才对。存像素就得在每次鼠标移动时反向换算，
/// 一旦屏幕 scale 变了（换屏、改分辨率）已有的标注还得重算。
///
/// ## 为什么放 Core
///
/// 落笔 / 收笔 / 最小尺寸 / 撤销栈这些全是纯逻辑，脱机就能测。
/// 放在 `MarqueeOverlay` 里就只能靠人手点 —— 而"一次误点留下了一个点"
/// 这种问题恰恰是最不容易在手工点击中稳定复现的。
public struct OverlayAnnotationSession: Equatable, Sendable {

    /// 一笔至少要多长才算数（点）。
    ///
    /// 一次误点（按下、手抖 1 点、松开）不该在图上留下任何东西 ——
    /// 而留下的往往是一个 1×1 的点，用户得先放大才找得到它，
    /// 却会一直看到导出图里多一个脏点。
    public static let minimumExtent: CGFloat = 3

    /// 画笔相邻两点的最小间距（点）。鼠标事件很密，不去重会存下成百上千个几乎重合的点。
    public static let penMinimumStep: CGFloat = 1.5

    /// 已提交的标注（按画的先后）。
    public private(set) var annotations: [Annotation] = []
    /// 正在画的那一笔。`nil` = 没在画。
    public private(set) var draft: Annotation?

    /// 当前工具。`nil` = 不在画标注（拖拽 = 重画选区）。
    public private(set) var tool: OverlayTool?

    /// 下一个标注用的样式（颜色 / 线宽）。改它**不入撤销栈** —— 它不影响已有内容。
    public var style: AnnotationStyle

    private var strokeStart: CGPoint?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    public init(style: AnnotationStyle = AnnotationStyle(stroke: AnnotationPalette.defaultColor,
                                                         lineWidth: AnnotationPalette.defaultLineWidth)) {
        self.style = style
    }

    // MARK: - 状态

    public var isEmpty: Bool { annotations.isEmpty && draft == nil }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// 是否正处在"画标注"模式。
    public var isDrawing: Bool { tool != nil }

    /// 该画到屏幕上的全部标注（已提交的 + 正在画的草稿）。
    ///
    /// 草稿也要画：用户拖的时候必须看到框跟着走，否则工具像是没反应。
    public var visibleAnnotations: [Annotation] {
        guard let draft else { return annotations }
        return annotations + [draft]
    }

    // MARK: - 工具

    /// 选中某个工具；**再选一次同一个工具 = 取消选中**。
    ///
    /// 取消选中要能一步做到：画完几个箭头想改选区大小，不该先去别处点一下。
    public mutating func toggle(tool: OverlayTool) {
        cancelStroke()
        self.tool = (self.tool == tool) ? nil : tool
    }

    /// 取消工具选择（回到"调整选区"的模式）。
    public mutating func clearTool() {
        cancelStroke()
        tool = nil
    }

    // MARK: - 一笔

    /// 落笔。返回是否真的开始了（没选工具 / 已有草稿时为 `false`）。
    @discardableResult
    public mutating func beginStroke(at point: CGPoint) -> Bool {
        guard let tool, draft == nil else { return false }
        strokeStart = point
        draft = makeAnnotation(tool: tool, at: point)
        return true
    }

    /// 拖到哪。没在画时是空操作。
    public mutating func updateStroke(to point: CGPoint) {
        guard var current = draft, let start = strokeStart else { return }
        switch current.kind {
        case .rectangle, .ellipse:
            // 用 union 而不是自己算 min/max：反向拖拽（右下往左上）时
            // `CGRect(x:y:width:height:)` 会得到一个负尺寸的框，
            // 描边在有的路径上画不出来 —— 表现是"往回拖就什么都没有"。
            current.frame = CGRect(origin: start, size: .zero)
                .union(CGRect(origin: point, size: .zero))
        case .arrow:
            current.path = [start, point]
            current.frame = Self.boundingBox(current.path)
        case .pen:
            if let last = current.path.last,
               hypot(point.x - last.x, point.y - last.y) < Self.penMinimumStep {
                return
            }
            current.path.append(point)
            current.frame = Self.boundingBox(current.path)
        case .text, .mosaic, .blur:
            // 覆盖层的工具条上目前没有这三类（文字要输入框、打码要底图，见 ticket 22）
            return
        }
        draft = current
    }

    /// 收笔。太短的一笔会被丢掉。
    ///
    /// - Returns: 是否真的产出了一个标注。
    @discardableResult
    public mutating func endStroke(at point: CGPoint) -> Bool {
        guard draft != nil else { return false }
        updateStroke(to: point)
        defer {
            draft = nil
            strokeStart = nil
        }
        guard let candidate = draft, Self.isUsable(candidate) else { return false }
        commit(candidate)
        return true
    }

    /// 丢掉正在画的那一笔（`Esc` / 工具被换掉时用）。已提交的标注不动。
    public mutating func cancelStroke() {
        draft = nil
        strokeStart = nil
    }

    // MARK: - 撤销

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        cancelStroke()
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(annotations)
        annotations = next
        cancelStroke()
        return true
    }

    /// 全部清掉（连同撤销栈）。
    public mutating func removeAll() {
        annotations = []
        draft = nil
        strokeStart = nil
        undoStack = []
        redoStack = []
    }

    // MARK: - 内部

    private mutating func commit(_ annotation: Annotation) {
        undoStack.append(annotations)
        redoStack.removeAll()
        annotations.append(annotation)
    }

    private func makeAnnotation(tool: OverlayTool, at point: CGPoint) -> Annotation {
        // zIndex 用序号递增：后画的盖在上面，与数组顺序一致
        let zIndex = annotations.count
        switch tool {
        case .rectangle, .ellipse:
            return Annotation(kind: tool.kind,
                              frame: CGRect(origin: point, size: .zero),
                              style: style,
                              zIndex: zIndex)
        case .arrow:
            return Annotation(kind: .arrow,
                              frame: CGRect(origin: point, size: .zero),
                              style: style,
                              zIndex: zIndex,
                              path: [point, point])
        case .pen:
            return Annotation(kind: .pen,
                              frame: CGRect(origin: point, size: .zero),
                              style: style,
                              zIndex: zIndex,
                              path: [point])
        }
    }

    /// 一笔是否够格成为标注。
    static func isUsable(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle, .ellipse:
            let box = annotation.frame.standardized
            return box.width >= minimumExtent && box.height >= minimumExtent
        case .arrow:
            guard annotation.path.count >= 2 else { return false }
            return distance(annotation.path[0], annotation.path[1]) >= minimumExtent
        case .pen:
            guard annotation.path.count >= 2 else { return false }
            var total: CGFloat = 0
            for index in 1..<annotation.path.count {
                total += distance(annotation.path[index - 1], annotation.path[index])
            }
            return total >= minimumExtent
        case .text, .mosaic, .blur:
            return true
        }
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}

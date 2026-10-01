import CoreGraphics
import Foundation

/// 标注颜色。放在 Core 里，不依赖 SwiftUI / AppKit 的 `Color`。
///
/// 组件语义是 **sRGB**（用户在工具栏里挑的是一组固定颜色，与屏幕色彩空间无关）。
public struct AnnotationColor: Equatable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = AnnotationColor(red: 1, green: 0.23, blue: 0.19)

    /// 转成指定色彩空间的 `CGColor`。
    ///
    /// **必须做一次转换，不能直接把 sRGB 分量塞进目标空间**：
    /// `CGColor(colorSpace: p3, components: [1, 0.23, 0.19])` 表示的是 **P3 里**的那个颜色，
    /// 而 P3 色域比 sRGB 大 —— 同样一组数字在 P3 下看起来更艳。
    /// 于是"同一个红色"在 P3 截图上会突然变成另一个红。
    ///
    /// 转换的语义才是对的：用户挑的是"这个颜色"，它在哪个色彩空间里都该是同一个颜色。
    public func cgColor(in colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGColor {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? colorSpace
        let base = CGColor(colorSpace: srgb, components: [red, green, blue, alpha])!
        guard colorSpace != srgb else { return base }
        return base.converted(to: colorSpace, intent: .defaultIntent, options: nil) ?? base
    }
}

/// 描边样式。
///
/// `fontSize` 只有文字标注用（它是文字的"粗细"，即缩放文字的方式）；
/// `lineWidth` 对文字无意义。两者放在同一个样式里，是因为工具栏是同一组控件 ——
/// 选中文字时改的是字号，选中图形时改的是线宽。
public struct AnnotationStyle: Equatable, Sendable, Codable {
    public var stroke: AnnotationColor
    public var lineWidth: CGFloat
    /// 字号（原图像素）。默认按截图常见宽度给，2x 屏下大约相当于 18 点的屏幕文字。
    public var fontSize: CGFloat
    /// 打码强度（原图像素）：马赛克＝块边长、毛玻璃＝模糊半径。
    ///
    /// 和 `fontSize` 一样，它是"某一类标注才用得上"的参数 ——
    /// 界面因此可以只有一排控件，按当前选中的对象决定改的是谁。
    public var effectStrength: CGFloat

    public init(stroke: AnnotationColor = .red,
                lineWidth: CGFloat = 4,
                fontSize: CGFloat = 36,
                effectStrength: CGFloat = 12) {
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.effectStrength = effectStrength
    }

    public static let `default` = AnnotationStyle()
}

public enum AnnotationKind: Equatable, Sendable, Codable {
    case rectangle
    case ellipse
    /// 箭头：`path` 恰好两个点 `[起点, 终点]`
    case arrow
    /// 自由画笔：`path` 是折线点序列
    case pen
    /// 文字：内容在 `Annotation.text`，框由 `AnnotationText.measure` 量出来
    case text
    /// 马赛克：把框内像素化。强度 = 块边长（像素）
    case mosaic
    /// 毛玻璃：把框内高斯模糊。强度 = 半径（像素）
    case blur
}

/// 一个可再次编辑的标注。坐标在**原图像素**里，原点左上、y 向下。
///
/// 不跟裁切后的画布走：裁切只改 `cropRect`，对象留在原图上，撤销裁切时位置不用重算。
public struct Annotation: Equatable, Sendable, Identifiable, Codable {
    public var id: UUID
    public var kind: AnnotationKind
    /// 包围盒。矩形/椭圆就是图形本身；箭头与画笔是路径的包围盒；文字是排版框。
    public var frame: CGRect
    public var style: AnnotationStyle
    public var zIndex: Int
    /// 路径点（原图像素）。箭头 = `[起点, 终点]`；画笔 = 折线点序列；其它类型为空。
    ///
    /// 为什么不塞进 `AnnotationKind` 的关联值：那样 `kind` 就不再是简单的可比较标签，
    /// 命中测试、工具栏、序列化都要跟着解包 —— 而"这个对象是什么"与"它的点在哪"
    /// 本来就是两件事。
    public var path: [CGPoint]
    /// 文字内容（`kind == .text` 时有意义）。序号标记就是内容为 `"1."` `"2."` 的文字。
    public var text: String

    public init(id: UUID = UUID(),
                kind: AnnotationKind,
                frame: CGRect,
                style: AnnotationStyle = .default,
                zIndex: Int,
                path: [CGPoint] = [],
                text: String = "") {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.style = style
        self.zIndex = zIndex
        self.path = path
        self.text = text
    }

    /// 点是否落在这个对象上（含半个线宽的命中余量，细线也点得到）。
    ///
    /// 箭头与画笔按**到路径的距离**判，不按包围盒 —— 斜线的包围盒里有大片空白，
    /// 用包围盒会让"点空白处却选中了箭头"。
    public func contains(_ point: CGPoint) -> Bool {
        let slop = max(style.lineWidth / 2, 3)
        let box = frame.standardized.insetBy(dx: -slop, dy: -slop)
        switch kind {
        case .rectangle, .text, .mosaic, .blur:
            // 打码是按**区域**作用的：它没有"描边"，点哪儿算哪儿就是整个框
            return box.contains(point)
        case .ellipse:
            let radiusX = box.width / 2
            let radiusY = box.height / 2
            guard radiusX > 0, radiusY > 0 else { return false }
            let dx = (point.x - box.midX) / radiusX
            let dy = (point.y - box.midY) / radiusY
            return dx * dx + dy * dy <= 1
        case .arrow, .pen:
            guard path.count >= 2 else { return box.contains(point) }
            return AnnotationGeometry.distance(from: point, toPolyline: path) <= slop
        }
    }

    /// 平移：框与路径一起走。
    ///
    /// 分开处理会漏 —— 只挪 `frame` 的话，箭头与画笔会"框走了线还在原地"。
    public func translated(by delta: CGPoint) -> Annotation {
        var copy = self
        copy.frame.origin.x += delta.x
        copy.frame.origin.y += delta.y
        copy.path = path.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return copy
    }

    /// 按比例整体放大 / 缩小（含线宽、字号、打码强度）。
    ///
    /// 覆盖层里画的标注存的是**点**，导出要的是**像素**，两者差一个屏幕倍率。
    /// 只缩 `frame` 与 `path` 是不够的：线宽不跟着走的话，Retina 上导出的线条
    /// 会细成屏幕上的**一半**（看着像"导出把线变细了"）。
    public func scaled(by factor: CGFloat) -> Annotation {
        guard factor != 1 else { return self }
        var copy = self
        copy.frame = CGRect(x: frame.minX * factor,
                            y: frame.minY * factor,
                            width: frame.width * factor,
                            height: frame.height * factor)
        copy.path = path.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
        copy.style.lineWidth *= factor
        copy.style.fontSize *= factor
        copy.style.effectStrength *= factor
        return copy
    }

    /// 按新框重新贴合（拖控制点时用）。
    ///
    /// - 箭头 / 画笔：路径等比缩放
    /// - 文字：字号按高度比缩放，框由字号重新量出来（拖动它就是在缩放文字）
    /// - 矩形 / 椭圆：只有框变
    public mutating func applyFrame(_ newFrame: CGRect) {
        switch kind {
        case .rectangle, .ellipse, .mosaic, .blur:
            frame = newFrame
        case .arrow, .pen:
            path = AnnotationGeometry.scale(points: path, from: frame, to: newFrame)
            frame = newFrame
        case .text:
            let oldHeight = max(1, frame.standardized.height)
            let ratio = newFrame.standardized.height / oldHeight
            let clamped = min(400, max(6, style.fontSize * ratio))
            style.fontSize = clamped
            frame = AnnotationText.frame(text: text,
                                         fontSize: clamped,
                                         origin: newFrame.standardized.origin)
        }
    }

    /// 序号标记用：内容形如 `"3."` 的文字。
    public static func counter(number: Int,
                               style: AnnotationStyle,
                               zIndex: Int,
                               origin: CGPoint) -> Annotation {
        let text = "\(number)."
        return Annotation(kind: .text,
                          frame: AnnotationText.frame(text: text,
                                                      fontSize: style.fontSize,
                                                      origin: origin),
                          style: style,
                          zIndex: zIndex,
                          text: text)
    }
}

extension AnnotationColor: Codable {}

public enum AnnotationHandle: CaseIterable, Equatable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public func point(on frame: CGRect) -> CGPoint {
        let box = frame.standardized
        switch self {
        case .topLeft: return CGPoint(x: box.minX, y: box.minY)
        case .topRight: return CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeft: return CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
        }
    }
}

public enum AnnotationHit: Equatable, Sendable {
    case handle(UUID, AnnotationHandle)
    case body(UUID)
}

/// 一次截图的可编辑文档。图像本身不放在这里（`CGImage` 不好比较），只留像素尺寸。
///
/// `Codable`：ticket 16 的"最近截图"要把**矢量**标注存下来重编辑，
/// 所以模型必须能序列化。有一条测试专门跑"存 → 取 → 再栅格化"的一致性。
public struct AnnotationDocument: Equatable, Sendable, Codable {
    public var pixelSize: CGSize
    /// 可见区域，原图像素，原点左上。整图时等于 `(0, 0, width, height)`。
    public var cropRect: CGRect
    public var annotations: [Annotation]

    public init(pixelSize: CGSize, cropRect: CGRect? = nil, annotations: [Annotation] = []) {
        self.pixelSize = pixelSize
        self.cropRect = cropRect ?? CGRect(origin: .zero, size: pixelSize)
        self.annotations = annotations
    }

    public var canvasPixelSize: CGSize { cropRect.size }

    /// 命中测试。控制点只对已选中的对象生效，并且先于对象本身。
    ///
    /// 对象从前到后：`zIndex` 大的在上；相同则数组里更靠后的在上（后画的盖住先画的）。
    /// 完全落在裁切区外的对象点不中。
    public func hitTest(_ point: CGPoint, selected: Set<UUID>, handleRadius: CGFloat) -> AnnotationHit? {
        let selectedFrontToBack = orderedFrontToBack().filter { selected.contains($0.id) }
        for annotation in selectedFrontToBack {
            for handle in AnnotationHandle.allCases {
                let center = handle.point(on: annotation.frame)
                let dx = point.x - center.x
                let dy = point.y - center.y
                if dx * dx + dy * dy <= handleRadius * handleRadius {
                    return .handle(annotation.id, handle)
                }
            }
        }

        for annotation in orderedFrontToBack() where annotation.frame.intersects(cropRect) || annotation.contains(point) {
            guard annotation.frame.intersects(cropRect.insetBy(dx: -annotation.style.lineWidth,
                                                               dy: -annotation.style.lineWidth)) else { continue }
            if annotation.contains(point) {
                return .body(annotation.id)
            }
        }
        return nil
    }

    /// 前到后。Swift 的 `sorted` 不稳定，所以相同 `zIndex` 时用原下标决出先后。
    func orderedFrontToBack() -> [Annotation] {
        annotations.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.zIndex != rhs.element.zIndex {
                    return lhs.element.zIndex > rhs.element.zIndex
                }
                return lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    public static func resized(_ frame: CGRect, handle: AnnotationHandle, to point: CGPoint) -> CGRect {
        let box = frame.standardized
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let bottom: CGFloat
        switch handle {
        case .topLeft:
            left = point.x
            top = point.y
            right = box.maxX
            bottom = box.maxY
        case .topRight:
            left = box.minX
            top = point.y
            right = point.x
            bottom = box.maxY
        case .bottomLeft:
            left = point.x
            top = box.minY
            right = box.maxX
            bottom = point.y
        case .bottomRight:
            left = box.minX
            top = box.minY
            right = point.x
            bottom = point.y
        }
        var rect = CGRect(x: min(left, right),
                          y: min(top, bottom),
                          width: abs(right - left),
                          height: abs(bottom - top))
        if rect.width < 1 { rect.size.width = 1 }
        if rect.height < 1 { rect.size.height = 1 }
        return rect
    }
}

/// 画布缩放与平移。`scale` 是「视图点 / 图像像素」。
/// `pan` 是裁切区左上角在视图里的位置。
public struct CanvasViewport: Equatable, Sendable {
    public var scale: CGFloat
    public var pan: CGPoint

    public init(scale: CGFloat = 1, pan: CGPoint = .zero) {
        self.scale = scale
        self.pan = pan
    }

    public func imagePoint(forView point: CGPoint, cropOrigin: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.x) / scale + cropOrigin.x,
                y: (point.y - pan.y) / scale + cropOrigin.y)
    }

    public func viewPoint(forImage point: CGPoint, cropOrigin: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - cropOrigin.x) * scale + pan.x,
                y: (point.y - cropOrigin.y) * scale + pan.y)
    }

    public func viewRect(forImage rect: CGRect, cropOrigin: CGPoint) -> CGRect {
        let origin = viewPoint(forImage: CGPoint(x: rect.minX, y: rect.minY), cropOrigin: cropOrigin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
    }

    /// 以视图上的某个点为锚放大，锚点下的图像像素保持不动。
    public mutating func zoom(by factor: CGFloat, around viewPoint: CGPoint) {
        let clamped = min(8, max(0.1, scale * factor))
        let local = CGPoint(x: (viewPoint.x - pan.x) / scale, y: (viewPoint.y - pan.y) / scale)
        scale = clamped
        pan = CGPoint(x: viewPoint.x - local.x * scale, y: viewPoint.y - local.y * scale)
    }

    public mutating func pan(by delta: CGPoint) {
        pan.x += delta.x
        pan.y += delta.y
    }

    /// 把整张图像素放进视图，四周留出 `inset` 点。
    public static func fitted(pixelSize: CGSize, in viewSize: CGSize, inset: CGFloat = 24) -> CanvasViewport {
        let available = CGSize(width: max(1, viewSize.width - inset * 2),
                               height: max(1, viewSize.height - inset * 2))
        let width = max(pixelSize.width, 1)
        let height = max(pixelSize.height, 1)
        let scale = min(8, max(0.1, min(available.width / width, available.height / height)))
        let fitted = CGSize(width: width * scale, height: height * scale)
        let pan = CGPoint(x: (viewSize.width - fitted.width) / 2,
                          y: (viewSize.height - fitted.height) / 2)
        return CanvasViewport(scale: scale, pan: pan)
    }
}

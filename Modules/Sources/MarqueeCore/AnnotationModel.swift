import CoreGraphics
import Foundation

/// 标注颜色。放在 Core 里，不依赖 SwiftUI / AppKit 的 `Color`。
///
/// 组件是 0...1 的 sRGB。栅格化时必须用命名的 sRGB 色彩空间来建 `CGColor`，
/// 否则在 P3 屏上 `CGColor(red:green:blue:alpha:)` 会偏色（见 MEMORY 陷阱 11）。
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

    public func cgColor(in colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
    }
}

/// 描边样式。填充、字体、虚线留给后面的标注类型，本条只需要颜色和线宽。
public struct AnnotationStyle: Equatable, Sendable {
    public var stroke: AnnotationColor
    public var lineWidth: CGFloat

    public init(stroke: AnnotationColor = .red, lineWidth: CGFloat = 4) {
        self.stroke = stroke
        self.lineWidth = lineWidth
    }

    public static let `default` = AnnotationStyle()
}

public enum AnnotationKind: Equatable, Sendable {
    case rectangle
    case ellipse
}

/// 一个可再次编辑的标注。坐标在**原图像素**里，原点左上、y 向下。
///
/// 不跟裁切后的画布走：裁切只改 `cropRect`，对象留在原图上，撤销裁切时位置不用重算。
public struct Annotation: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: AnnotationKind
    public var frame: CGRect
    public var style: AnnotationStyle
    public var zIndex: Int

    public init(id: UUID = UUID(),
                kind: AnnotationKind,
                frame: CGRect,
                style: AnnotationStyle = .default,
                zIndex: Int) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.style = style
        self.zIndex = zIndex
    }

    /// 点是否落在这个对象上（含半个线宽的命中余量，细线也点得到）。
    public func contains(_ point: CGPoint) -> Bool {
        let slop = style.lineWidth / 2
        let rect = frame.standardized.insetBy(dx: -slop, dy: -slop)
        switch kind {
        case .rectangle:
            return rect.contains(point)
        case .ellipse:
            let radiusX = rect.width / 2
            let radiusY = rect.height / 2
            guard radiusX > 0, radiusY > 0 else { return false }
            let dx = (point.x - rect.midX) / radiusX
            let dy = (point.y - rect.midY) / radiusY
            return dx * dx + dy * dy <= 1
        }
    }
}

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
public struct AnnotationDocument: Equatable, Sendable {
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

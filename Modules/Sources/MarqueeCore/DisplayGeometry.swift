import CoreGraphics

/// 一块显示器在**全局点坐标系**中的几何信息，以及该屏的点↔像素换算。
///
/// 为什么单独抽出来：选区交互全程在全局点坐标下进行，只有在采集与导出时才换算成像素。
/// 多显示器混合 DPI（1x 与 2x 混用）下这里是最容易出错的地方，所以它必须是
/// 一个可以脱离窗口系统单测的纯类型，而不是散在覆盖层代码里的 `* 2`。
public struct DisplayGeometry: Equatable, Sendable {
    /// 该屏在全局点坐标系中的 frame。
    public let frame: CGRect
    /// backing scale factor：普通屏 1.0，Retina 2.0
    public let backingScale: CGFloat
    /// 稳定标识，用于在多次查询之间匹配同一块屏幕
    public let displayID: UInt32

    public init(frame: CGRect, backingScale: CGFloat, displayID: UInt32) {
        self.frame = frame
        self.backingScale = backingScale
        self.displayID = displayID
    }

    /// 该屏的像素尺寸（点 × backing scale，取整到整像素）
    public var pixelSize: CGSize {
        CGSize(width: (frame.width * backingScale).rounded(),
               height: (frame.height * backingScale).rounded())
    }

    /// 全局点坐标下的矩形 → 本屏像素坐标下的矩形（相对本屏左上角）
    public func pixelRect(for globalRect: CGRect) -> CGRect {
        let local = CGRect(x: globalRect.minX - frame.minX,
                           y: globalRect.minY - frame.minY,
                           width: globalRect.width,
                           height: globalRect.height)
        return CGRect(x: (local.minX * backingScale).rounded(),
                      y: (local.minY * backingScale).rounded(),
                      width: (local.width * backingScale).rounded(),
                      height: (local.height * backingScale).rounded())
    }

    /// 选区是否可截取：换算到像素后宽高都不小于 1，且与本屏有实际交集。
    public func isValidSelection(_ globalRect: CGRect) -> Bool {
        guard let clipped = Selection.clipped(globalRect, to: frame) else { return false }
        let px = pixelRect(for: clipped)
        return px.width >= 1 && px.height >= 1
    }
}

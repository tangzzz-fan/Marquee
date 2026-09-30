import CoreGraphics
import MarqueeCore

/// 采集模块：ScreenCaptureKit 的封装层，不含任何窗口或 UI 逻辑。
///
/// 归属 ticket：02（全屏）、03（区域）、04（窗口）、11 / 12（滚动）。
///
/// 采集走的 API 已在 `docs/SPIKE-PLAN.md` 与 `docs/PRD.md` 5.3 核实：
/// `SCScreenshotManager.captureImage(in:)`（15.2+）、
/// `SCContentFilter(desktopIndependentWindow:)`（12.3+）、
/// `ignoreShadowsSingleWindow`（14.0+）、`includeChildWindows`（14.2+）。
public protocol ScreenCapturing: Sendable {
    /// 截取指定显示器的整屏内容（ticket 02）
    func captureFullScreen(_ display: DisplayGeometry) async throws -> CapturedImage

    /// 截取全局点坐标下的一个区域（ticket 03）
    func captureRegion(_ rect: CGRect, on display: DisplayGeometry) async throws -> CapturedImage
}

/// 采集结果。
///
/// `CGImage` 创建后不可变，跨线程只读安全，因此这里用 `@unchecked Sendable`
/// 显式承担该保证（Swift 6 不会为 Core Foundation 类型自动推导）。
public struct CapturedImage: @unchecked Sendable {
    public let image: CGImage
    public let displayID: UInt32
    /// 采集时的 backing scale，用于后续校验像素尺寸是否符合预期
    public let backingScale: CGFloat

    public init(image: CGImage, displayID: UInt32, backingScale: CGFloat) {
        self.image = image
        self.displayID = displayID
        self.backingScale = backingScale
    }

    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

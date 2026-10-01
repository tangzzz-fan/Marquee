import CoreGraphics
import Foundation

/// 放大镜取色用的一屏像素（ticket 10）。
///
/// 归属本文件的原因与其它接缝一致：协议在 Core，实现模块只提供 OS 实现。
public struct LensFrame: @unchecked Sendable {
    public let display: DisplayGeometry
    /// 该屏的整屏像素（**不含** Marquee 自己的窗口 —— 采集时按进程排除）
    public let image: CGImage

    public init(display: DisplayGeometry, image: CGImage) {
        self.display = display
        self.image = image
    }
}

/// 提供放大镜要采样的那一屏像素。
///
/// ## 为什么是"取一次整屏帧"而不是每次移动都去采
///
/// 放大镜要跟着光标走（验收项是 120 fps 不掉帧）。每次移动都调一次
/// `SCScreenshotManager` 是几十毫秒量级，120 fps 根本不可能。
/// 所以覆盖层出现后**取一屏、留着**，之后所有取样都在内存里做（裁剪 + 放大都是纯计算）。
///
/// 代价是这一帧是**冻结**的：覆盖层期间被采窗口如果自己变了（视频、
/// 动画、滚动），放大镜显示的会是那一刻的画面。对"取色"这个用途可以接受 ——
/// 用户看的是静态界面；真要在动的东西上取色，系统自带的取色器更合适。
public protocol LensFrameProviding: Sendable {
    /// 取一屏像素。失败返回 `nil`。
    ///
    /// **失败必须可容忍**：放大镜是锦上添花，拿不到就只是不显示，
    /// 绝不能让截屏主流程（选区、采集、剪贴板）受影响。
    func lensFrame(for display: DisplayGeometry) async -> LensFrame?
}

/// 用现成的采集器取一屏。真实实现就是 `ScreenCaptureKitCapturer.captureFullScreen`。
public struct CapturerLensProvider: LensFrameProviding {

    private let capturer: ScreenCapturing

    public init(capturer: ScreenCapturing) {
        self.capturer = capturer
    }

    public func lensFrame(for display: DisplayGeometry) async -> LensFrame? {
        guard let captured = try? await capturer.captureFullScreen(display) else { return nil }
        return LensFrame(display: display, image: captured.image)
    }
}

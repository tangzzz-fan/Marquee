import CoreGraphics
import Foundation

/// 区域截图 → 剪贴板的编排（ticket 03）。
///
/// 与 `FullScreenCaptureFlow` 同一套写法：权限门 → 逐屏取片 → 拼接 → PNG → 剪贴板。
/// 差别只在于"取哪块"：整屏是一次采集，选区是**逐屏取交集再拼**。
///
/// 跨屏之所以要拼而不是一次采集：`SCScreenshotManager.captureImage(in:)`（15.2+）
/// 确实能吃一个跨屏矩形，但它比最低系统 15.0 高，且它对输出分辨率的选择不由我们控制。
/// 逐屏取交集 + 拼接的好处是**布局逻辑是纯的、可单测的**，且各屏以原生 scale 取片，不丢细节。
@MainActor
public final class RegionCaptureFlow {

    private let permission: ScreenRecordingPermissionProbing
    private let capturer: ScreenCapturing
    private let clipboard: ClipboardWriting
    private let clock: MonotonicClock

    public init(permission: ScreenRecordingPermissionProbing,
                capturer: ScreenCapturing,
                clipboard: ClipboardWriting,
                clock: MonotonicClock = SystemMonotonicClock()) {
        self.permission = permission
        self.capturer = capturer
        self.clipboard = clipboard
        self.clock = clock
    }

    /// - Parameter selection: **Quartz 全局点坐标**下的选区（调用方负责从 Cocoa 转换）
    /// - Parameter displays: 当前全部显示器
    public func capture(selection: CGRect,
                        displays: [DisplayGeometry],
                        save: CaptureSaveRequest? = nil) async -> CaptureOutcome {
        let output = CaptureOutput(clipboard: clipboard, clock: clock)
        let startedAt = output.begin()

        let grantedJustNow: Bool
        switch await CaptureGateRunner.run(permission) {
        case .blocked(let decision):
            return .permissionBlocked(blockedBy: decision, grantedJustNow: false)
        case .proceed(let justGranted):
            grantedJustNow = justGranted
        }

        guard let layout = SelectionLayout.plan(selection: selection, displays: displays) else {
            return .failed(CaptureFailure(message: "选区太小，或者不落在任何显示器上"))
        }

        do {
            var slices: [ImageSlice] = []
            slices.reserveCapacity(layout.slices.count)
            for slice in layout.slices {
                let captured = try await capturer.captureRegion(slice.globalPointRect, on: slice.display)
                slices.append(ImageSlice(image: captured.image, target: slice.targetPixelRect))
            }

            guard let composed = ImageCompositing.compose(outputSize: layout.outputPixelSize,
                                                          slices: slices) else {
                return .failed(CaptureFailure(message: "拼接选区图像失败"))
            }
            return output.finish(composed, startedAt: startedAt, save: save)
        } catch {
            return output.failure(error, grantedJustNow: grantedJustNow)
        }
    }
}

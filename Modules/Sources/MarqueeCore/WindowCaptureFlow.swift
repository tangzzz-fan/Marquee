import Foundation

/// 点到高亮窗口时怎么截。
public enum WindowCaptureStyle: Equatable, Sendable {
    /// 只截这一扇窗本身，不含挡住它的其他窗口。
    /// 这是窗口识别的业界标准（系统截图 / Snip / CleanShot）：叠层用**拖选区**来拿。
    /// `includeShadow == false` 时无阴影、无背景（`⌥` 单击）。
    case isolatedWindow(includeShadow: Bool)
    /// 截取该窗矩形范围内屏幕上实际看到的内容（叠层会出现在图里）。
    /// 与拖选区等价，留给明确要「按窗口框切一块屏幕」的调用方。
    case visibleOnScreen
}

/// 窗口截图 → 剪贴板（ticket 04）。
///
/// 单击走独立窗口滤镜（PRD B5 / 系统截图 / 旧版 Snip）：拿到的是这一扇窗，
/// 即使它被别的窗口挡住。叠在一起的画面用拖选区截，不要用点窗口。
@MainActor
public final class WindowCaptureFlow {

    private let permission: ScreenRecordingPermissionProbing
    private let capturer: ScreenCapturing
    private let clipboard: ClipboardWriting
    /// 最近截图（ticket 16）。`nil` = 不记（测试与自检路径）。
    private let history: (any CaptureHistoryWriting)?
    private let clock: MonotonicClock

    public init(permission: ScreenRecordingPermissionProbing,
                capturer: ScreenCapturing,
                clipboard: ClipboardWriting,
                history: (any CaptureHistoryWriting)? = nil,
                clock: MonotonicClock = SystemMonotonicClock()) {
        self.permission = permission
        self.capturer = capturer
        self.clipboard = clipboard
        self.history = history
        self.clock = clock
    }

    /// - Parameter window: 命中测试给出的那扇窗（frame 是 Quartz 全局点坐标）
    /// - Parameter style: 单击＝独立窗口（可带阴影）；`⌥` 单击＝无阴影无背景
    /// - Parameter displays: 跨屏时逐屏取片 / 推 backing scale
    public func capture(window: WindowInfo,
                        style: WindowCaptureStyle,
                        displays: [DisplayGeometry],
                        save: CaptureSaveRequest? = nil,
                        inline: InlineAnnotations? = nil) async -> CaptureOutcome {
        switch style {
        case .visibleOnScreen:
            let region = RegionCaptureFlow(permission: permission,
                                           capturer: capturer,
                                           clipboard: clipboard,
                                           clock: clock)
            return await region.capture(selection: window.frame,
                                        displays: displays,
                                        save: save,
                                        inline: inline)

        case .isolatedWindow(let includeShadow):
            return await captureIsolated(window,
                                        includeShadow: includeShadow,
                                        displays: displays,
                                        save: save,
                                        inline: inline)
        }
    }

    private func captureIsolated(_ window: WindowInfo,
                                 includeShadow: Bool,
                                 displays: [DisplayGeometry],
                                 save: CaptureSaveRequest?,
                                 inline: InlineAnnotations? = nil) async -> CaptureOutcome {
        let output = CaptureOutput(clipboard: clipboard, clock: clock, history: history)
        let startedAt = output.begin()

        let grantedJustNow: Bool
        switch await CaptureGateRunner.run(permission) {
        case .blocked(let decision):
            return .permissionBlocked(blockedBy: decision, grantedJustNow: false)
        case .proceed(let justGranted):
            grantedJustNow = justGranted
        }

        let scale = displays
            .filter { $0.frame.intersects(window.frame) }
            .map(\.backingScale)
            .max() ?? 1

        do {
            let captured = try await capturer.captureWindow(window,
                                                            includeShadow: includeShadow,
                                                            backingScale: scale)
            return output.finish(captured.image, startedAt: startedAt, save: save, inline: inline)
        } catch {
            return output.failure(error, grantedJustNow: grantedJustNow)
        }
    }
}

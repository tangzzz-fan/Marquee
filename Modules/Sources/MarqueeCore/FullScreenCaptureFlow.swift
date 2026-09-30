import CoreGraphics
import Foundation

/// 全屏截图 → 剪贴板的完整编排。
///
/// 这是 ticket 02 的主干：**权限门 → 定位显示器 → 采集 → 编码 → 写剪贴板**。
/// 全部依赖都是注入的（权限探针 / 采集器 / 剪贴板 / 显示器定位 / 时钟），
/// 因此这条路径可以在没有真实授权、没有真实屏幕的环境下逐分支断言 ——
/// 特别是"权限没过时**绝不能**静默返回"这条最容易写错的分支。
///
/// 放在 `@MainActor`：剪贴板写入与后续 UI 反馈都在主线程，避免额外的线程跳跃；
/// 真正耗时的采集与系统权限请求本身就是 `async` / 已下沉到后台线程，不会卡住 UI。
@MainActor
public final class FullScreenCaptureFlow {

    private let permission: ScreenRecordingPermissionProbing
    private let capturer: ScreenCapturing
    private let clipboard: ClipboardWriting
    private let displays: DisplayLocating
    private let clock: MonotonicClock

    public init(permission: ScreenRecordingPermissionProbing,
                capturer: ScreenCapturing,
                clipboard: ClipboardWriting,
                displays: DisplayLocating,
                clock: MonotonicClock = SystemMonotonicClock()) {
        self.permission = permission
        self.capturer = capturer
        self.clipboard = clipboard
        self.displays = displays
        self.clock = clock
    }

    /// 走完一次全屏截图。**任何**失败都会返回携带说明的结果，不会静默什么都不做。
    public func capture(save: CaptureSaveRequest? = nil) async -> CaptureOutcome {
        let output = CaptureOutput(clipboard: clipboard, clock: clock)
        let startedAt = output.begin()

        // ── 1. 权限门 ────────────────────────────────────────────────
        var grantedJustNow = false
        switch await CaptureGateRunner.run(permission) {
        case .blocked(let decision):
            return .permissionBlocked(blockedBy: decision, grantedJustNow: false)
        case .proceed(let justGranted):
            grantedJustNow = justGranted
        }

        // ── 2. 定位显示器 ────────────────────────────────────────────
        guard let display = displays.displayUnderPointer() else {
            return .failed(CaptureFailure(message: "没找到鼠标所在的显示器，请把鼠标移到要截的屏幕上再试"))
        }

        // ── 3. 采集 + 编码 + 写剪贴板 ───────────────────────────────
        do {
            let captured = try await capturer.captureFullScreen(display)
            return output.finish(captured.image, startedAt: startedAt, save: save)
        } catch {
            return output.failure(error, grantedJustNow: grantedJustNow)
        }
    }
}

// MARK: - 结果类型

/// 一次成功采集的度量。性能预算"按下快捷键 → 剪贴板可用 ≤ 150 ms"就是拿这里比。
public struct CaptureMetrics: Equatable, Sendable {
    /// 物理像素尺寸。Retina 下应等于 点数 × 2，**不是**点数
    public let pixelSize: CGSize
    public let pngByteCount: Int
    public let elapsedMilliseconds: Double
    /// `⌘S` 写成的文件路径。没要求落盘时为 `nil`。
    public let savedFilePath: String?
    /// 剪贴板已经写上，但落盘失败时的说明。正常复制和落盘成功都是 `nil`。
    public let saveFailureMessage: String?
    /// 落盘实际用掉的序号（撞名时会比申请的更大）。
    public let savedSequence: Int?
    /// 刚截到的图。编辑器要用它；比较结果时不看这张图（`CGImage` 没有值相等）。
    public let image: CGImage?

    public init(pixelSize: CGSize,
                pngByteCount: Int,
                elapsedMilliseconds: Double,
                savedFilePath: String? = nil,
                saveFailureMessage: String? = nil,
                savedSequence: Int? = nil,
                image: CGImage? = nil) {
        self.pixelSize = pixelSize
        self.pngByteCount = pngByteCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.savedFilePath = savedFilePath
        self.saveFailureMessage = saveFailureMessage
        self.savedSequence = savedSequence
        self.image = image
    }

    public static func == (lhs: CaptureMetrics, rhs: CaptureMetrics) -> Bool {
        lhs.pixelSize == rhs.pixelSize
            && lhs.pngByteCount == rhs.pngByteCount
            && lhs.elapsedMilliseconds == rhs.elapsedMilliseconds
            && lhs.savedFilePath == rhs.savedFilePath
            && lhs.saveFailureMessage == rhs.saveFailureMessage
            && lhs.savedSequence == rhs.savedSequence
    }
}

public struct CaptureFailure: Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum CaptureOutcome: Equatable, Sendable {
    case copiedToClipboard(CaptureMetrics)
    /// 权限没过。`grantedJustNow` 为真时，提示文案需要额外提醒"重启应用"。
    case permissionBlocked(blockedBy: CaptureGateDecision, grantedJustNow: Bool)
    case failed(CaptureFailure)
}

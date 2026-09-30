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
    public func capture() async -> CaptureOutcome {
        let startedAt = clock.now()

        // ── 1. 权限门 ────────────────────────────────────────────────
        var grantedJustNow = false
        switch CaptureGate.decision(for: permission.currentPermission()) {
        case .guideToSystemSettings:
            return .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false)

        case .requestSystemPrompt:
            // `CGRequestScreenCaptureAccess()` 会阻塞到用户点完系统框，
            // 因此在后台线程上跑（实测这个框可能停留数秒）。
            let granted = await Task.detached(priority: .userInitiated) { [permission] in
                permission.requestPermission()
            }.value
            guard granted else {
                // 用户刚拒绝 → 系统不会再弹框，只能引导去系统设置
                return .permissionBlocked(blockedBy: .guideToSystemSettings, grantedJustNow: false)
            }
            grantedJustNow = true

        case .proceed:
            break
        }

        // ── 2. 定位显示器 ────────────────────────────────────────────
        guard let display = displays.displayUnderPointer() else {
            return .failed(CaptureFailure(message: "没找到鼠标所在的显示器，请把鼠标移到要截的屏幕上再试"))
        }

        // ── 3. 采集 + 编码 + 写剪贴板 ───────────────────────────────
        do {
            let captured = try await capturer.captureFullScreen(display)
            guard let png = ImageEncoding.pngData(from: captured.image) else {
                return .failed(CaptureFailure(message: "截图编码为 PNG 失败"))
            }
            clipboard.writePNG(png)
            return .copiedToClipboard(CaptureMetrics(
                pixelSize: captured.pixelSize,
                pngByteCount: png.count,
                elapsedMilliseconds: (clock.now() - startedAt) * 1000
            ))
        } catch {
            // 刚授权就采集失败，几乎一定是"权限需要重启进程才生效"（见 SPIKE A5）。
            // 这个提示必须给出来，否则用户会以为是应用坏了。
            if grantedJustNow {
                return .failed(CaptureFailure(message: "已获得屏幕录制权限。请退出并重新打开 Marquee，权限才会生效"))
            }
            return .failed(CaptureFailure(message: "截图失败：\(error.localizedDescription)"))
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

    public init(pixelSize: CGSize, pngByteCount: Int, elapsedMilliseconds: Double) {
        self.pixelSize = pixelSize
        self.pngByteCount = pngByteCount
        self.elapsedMilliseconds = elapsedMilliseconds
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

import CoreGraphics
import Foundation
import MarqueeCore
import ScreenCaptureKit

/// 屏幕录制的真实权限探针。
///
/// ## 为什么这里**不**用 UserDefaults 推断 `.denied`
///
/// `CGPreflightScreenCaptureAccess()` 只返回一个布尔（`CGWindow.h:300`），
/// 区分不了"从未询问"和"已经被拒绝"。曾经的做法是自己持久化一个
/// "我们主动请求过" 的标记来补出三态 —— 那是个**危险的**做法，实测会把人锁死：
///
/// 1. 用户第一次按快捷键 → 我们调系统请求 → 记下标记
/// 2. 之后签名身份变了（ad-hoc 每次重新构建都会变），TCC 与该身份相关的状态被重置，
///    但**我们的标记还在**
/// 3. 于是我们再也不敢调 `CGRequestScreenCaptureAccess()`
/// 4. 而 macOS 只在应用**调用采集 API 时**才把它登记进
///    「系统设置 → 隐私与安全性 → 屏幕录制」列表 —— 现在列表里根本没有 Marquee
/// 5. 用户去系统设置也授权不了，每次按快捷键都只看到提示，**永远出不来**
///
/// 进程内记忆没有这个问题：签名一变是新进程，标记自然清掉，可以再问一次。
/// 但同一进程里必须记住"已经问过"—— macOS 15+ 上即使用户去系统设置勾过，
/// `CGPreflightScreenCaptureAccess()` 在重启前也会一直是 false，
/// 如果继续报 `.notDetermined`，每次快捷键都会再弹系统框。
public struct SystemScreenRecordingPermission: ScreenRecordingPermissionProbing {

    public init() {}

    public func currentPermission() -> ScreenRecordingPermission {
        if CGPreflightScreenCaptureAccess() { return .granted }
        if ProcessRequestState.shared.hasRequested { return .denied }
        return .notDetermined
    }

    @discardableResult
    public func requestPermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard ProcessRequestState.shared.markIfFirst() else {
            return CGPreflightScreenCaptureAccess()
        }

        await registerInScreenRecordingList()
        if CGPreflightScreenCaptureAccess() { return true }

        // 拿权威结论。同一会话里若上面的枚举已经弹过框，这里通常不再弹。
        return CGRequestScreenCaptureAccess()
    }

    /// 让 macOS 把本应用登记进「屏幕录制」列表。
    ///
    /// 只枚举 `SCShareableContent`，**不要**再截一帧：
    /// `SCScreenshotManager.captureImage` 会被当成一次新的采集尝试，
    /// 在 macOS 15+ 上叠出第二张系统授权框。
    private func registerInScreenRecordingList() async {
        _ = try? await SCShareableContent.excludingDesktopWindows(false,
                                                                  onScreenWindowsOnly: true)
    }
}

/// 进程内"已经问过系统"的记忆。
///
/// 必须是进程级（不是实例级）：宿主里可能同时有 `CaptureCoordinator`
/// 和 `-marqueeRequestPermission` 各持有一份探针。
private final class ProcessRequestState: @unchecked Sendable {
    static let shared = ProcessRequestState()

    private let lock = NSLock()
    private var didRequest = false

    var hasRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRequest
    }

    /// 若这是本进程第一次请求，记下并返回 `true`（调用方应当去弹系统框）。
    func markIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didRequest { return false }
        didRequest = true
        return true
    }
}

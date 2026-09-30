import CoreGraphics
import Foundation
import MarqueeCore

/// 屏幕录制的真实权限探针。
///
/// 关键点：`CGPreflightScreenCaptureAccess()` 只返回一个布尔
/// （`CGWindow.h:300`，macOS 10.15+），它**区分不了"从未询问"和"已经被拒绝"**。
/// 而 `CGRequestScreenCaptureAccess()` 的文档明确写了"曾被拒绝的进程不会再被询问"
/// （`CGWindow.h:305`）—— 所以如果只靠布尔值，第一次拒绝之后我们每次都会去调请求，
/// 用户却看不到任何框，表现为"按了快捷键没反应"。
///
/// 因此这里额外持久化一个"我们主动请求过"的痕迹，把布尔补成三态。
public struct SystemScreenRecordingPermission: ScreenRecordingPermissionProbing, @unchecked Sendable {

    // `UserDefaults` 是文档保证线程安全的；`@unchecked Sendable` 显式承担这一保证，
    // 而不是把它偷偷标成 Sendable 了事。
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func currentPermission() -> ScreenRecordingPermission {
        if CGPreflightScreenCaptureAccess() { return .granted }
        let askedBefore = defaults.bool(forKey: SystemSettingsLink.permissionRequestedDefaultsKey)
        return askedBefore ? .denied : .notDetermined
    }

    @discardableResult
    public func requestPermission() -> Bool {
        // 先记痕迹再请求：万一请求过程中被中断，也不至于下次又去弹一个不会出现的框
        defaults.set(true, forKey: SystemSettingsLink.permissionRequestedDefaultsKey)
        return CGRequestScreenCaptureAccess()
    }
}

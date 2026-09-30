import CoreGraphics
import Foundation
import MarqueeCore

/// 屏幕录制的真实权限探针。
///
/// ## 为什么这里**不**声称 `.denied`
///
/// `CGPreflightScreenCaptureAccess()` 只返回一个布尔（`CGWindow.h:300`），
/// 区分不了"从未询问"和"已经被拒绝"。曾经的做法是自己持久化一个
/// "我们主动请求过" 的标记来补出三态 —— 那是个**危险的**做法，实测会把人锁死：
///
/// 1. 用户第一次按快捷键 → 我们调系统请求 → 记下标记
/// 2. 之后签名身份变了（ad-hoc 每次重新构建都会变），TCC 与该身份相关的状态被重置，
///    但**我们的标记还在**
/// 3. 于是我们再也不敢调 `CGRequestScreenCaptureAccess()`
/// 4. 而 macOS 只在应用**调用采集相关 API 时**才把它登记进
///    「系统设置 → 隐私与安全性 → 屏幕录制」列表 —— 现在列表里根本没有 Marquee
/// 5. 用户去系统设置也授权不了，每次按快捷键都只看到提示，**永远出不来**
///
/// 所以这里保守地返回 `.notDetermined`，让上层去调一次系统请求：
/// 真被拒绝时该调用**不会弹任何框**、直接返回 `false`（`CGWindow.h:305`），代价可以忽略；
/// 而已经授权、只是当前进程还没生效时，它会返回 `true`，我们据此走"请重启应用"的正确分支。
public struct SystemScreenRecordingPermission: ScreenRecordingPermissionProbing {

    public init() {}

    public func currentPermission() -> ScreenRecordingPermission {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    @discardableResult
    public func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

import CoreGraphics
import Foundation

/// 权限门的执行体（含"弹一次系统请求框"这一步）。
///
/// 抽出来是因为全屏采集与区域采集都要走同一条门，而这条门里藏着本 ticket 最关键的判断：
/// `CGRequestScreenCaptureAccess()` 会**阻塞**到用户做出选择，且对被拒绝过的进程不会再弹。
/// 复制一份到两个流程里，迟早会有一份被改坏。
@MainActor
public enum CaptureGateRunner {

    public enum Result: Equatable, Sendable {
        case proceed(grantedJustNow: Bool)
        case blocked(CaptureGateDecision)
    }

    public static func run(_ permission: ScreenRecordingPermissionProbing) async -> Result {
        switch CaptureGate.decision(for: permission.currentPermission()) {
        case .guideToSystemSettings:
            return .blocked(.guideToSystemSettings)

        case .requestSystemPrompt:
            // 这一步里会真的碰一次采集 API（让 macOS 把 Marquee 登记进「屏幕录制」列表），
            // 并且可能弹系统框停住好几秒 —— 必须离开主线程。
            // 探针必须保证同一进程只问一次：问完若仍未授权，`currentPermission()`
            // 应报 `.denied`，下次快捷键走 `guideToSystemSettings` 而不是再弹系统框。
            let granted = await Task.detached(priority: .userInitiated) { [permission] in
                await permission.requestPermission()
            }.value
            return granted ? .proceed(grantedJustNow: true) : .blocked(.guideToSystemSettings)

        case .proceed:
            return .proceed(grantedJustNow: false)
        }
    }
}

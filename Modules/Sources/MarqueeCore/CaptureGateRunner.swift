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
            // 系统框可能停留数秒，必须离开主线程
            let granted = await Task.detached(priority: .userInitiated) { [permission] in
                permission.requestPermission()
            }.value
            return granted ? .proceed(grantedJustNow: true) : .blocked(.guideToSystemSettings)

        case .proceed:
            return .proceed(grantedJustNow: false)
        }
    }
}

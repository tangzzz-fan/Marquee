import CoreGraphics
import Foundation
import MarqueeCore
import ScreenCaptureKit

/// ScreenCaptureKit 版采集器。
///
/// 归属 ticket：02（全屏）、03（区域）、04（窗口）、11 / 12（滚动）。
///
/// 走 `SCScreenshotManager.captureImage(contentFilter:configuration:)`（macOS 14.0+，
/// 见 `SCScreenshotManager.h:153`）而不是 `captureImage(in:)`（15.2+，只吃一个矩形，
/// 无法控制排除自身窗口与分辨率），也不用 macOS 26+ 的 `SCScreenshotConfiguration`——
/// 最低系统是 15.0，用不上也不能用。
public struct ScreenCaptureKitCapturer: ScreenCapturing {

    public init() {}

    public func captureFullScreen(_ display: DisplayGeometry) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw CaptureError.displayNotFound(display.displayID)
        }

        // 排除本进程自己的窗口：菜单栏项、之后的覆盖层与编辑器都不能出现在截图里
        // （PRD 5.5 第 3 条 / SPIKE 待人工项 M6）。
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownProcessID }

        // `excludingWindows:` 语义下桌面背景与 Dock 会被包含，正是"整屏"应有的样子
        // （`SCStream.h:158`）。
        let filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)

        let configuration = SCStreamConfiguration()
        // 目标像素尺寸 = 点 × backingScale。不设的话 SCK 会按自动策略给一个可能被缩放的结果，
        // Retina 下就会得到"看起来对但只有一半分辨率"的图。
        configuration.width = Int(display.pixelSize.width)
        configuration.height = Int(display.pixelSize.height)
        // 分辨率取 best：宁可慢一点点也不要插值模糊（SPIKE 待人工项 M12）。
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        // 截图不带鼠标指针 —— 指针是"当前状态"，不属于"这一屏的内容"
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: configuration)
        return CapturedImage(image: image,
                             displayID: scDisplay.displayID,
                             backingScale: display.backingScale)
    }

    public func captureRegion(_ rect: CGRect, on display: DisplayGeometry) async throws -> CapturedImage {
        // ticket 03 实现。刻意在这里显式抛错而不是返回整屏：
        // 静默降级会变成"选区截了个整屏"这种极难察觉的错。
        throw CaptureError.notImplemented("区域采集属于 ticket 03")
    }
}

public enum CaptureError: Error, Equatable, Sendable {
    case displayNotFound(UInt32)
    case notImplemented(String)

    public var localizedDescription: String {
        switch self {
        case .displayNotFound(let id):
            "没找到 ID 为 \(id) 的显示器"
        case .notImplemented(let detail):
            "尚未实现：\(detail)"
        }
    }
}

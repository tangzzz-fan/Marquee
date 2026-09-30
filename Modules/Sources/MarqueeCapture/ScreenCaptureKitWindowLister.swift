import Foundation
import MarqueeCore
import ScreenCaptureKit

/// 用 ScreenCaptureKit 拉当前可见窗口清单。
///
/// `SCWindow.frame` 与 `SCDisplay.frame` 同一套空间（Quartz 全局点坐标），
/// 覆盖层命中测试前要经 `ScreenCoordinateConversion` 从 Cocoa 转过来。
public struct ScreenCaptureKitWindowLister: WindowListing {

    public init() {}

    public func listWindows() async -> [WindowInfo] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true,
                                                                                  onScreenWindowsOnly: true) else {
            return []
        }
        let zOrder = CGWindowZOrder.frontToBack()
        let alphaByID = Dictionary(uniqueKeysWithValues: zOrder.map { ($0.id, $0.alpha) })
        let listed = content.windows.compactMap { window -> WindowInfo? in
            guard window.isOnScreen else { return nil }
            // SCK 不给 alpha。不从窗口列表补上的话，全透明的挡板也会被当成可点窗口。
            let alpha = alphaByID[window.windowID] ?? 1
            return WindowInfo(
                windowID: window.windowID,
                frame: window.frame,
                layer: window.windowLayer,
                ownerPID: window.owningApplication?.processID ?? 0,
                ownerName: window.owningApplication?.applicationName ?? "",
                title: window.title,
                alpha: alpha
            )
        }
        let ids = zOrder.map(\.id)
        // 窗口列表拿不到时退回 SCK 原顺序，总比完全没有悬停好
        guard !ids.isEmpty else { return listed }
        return WindowCatalog.orderedForHitTesting(listed, frontToBackIDs: ids)
    }
}

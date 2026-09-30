import AppKit
import CoreGraphics
import MarqueeCore

/// 找到鼠标指针所在的显示器。
///
/// 为什么不用 `NSScreen.frame` 直接当 `DisplayGeometry.frame`：
/// `NSScreen` 用的是 Cocoa 坐标（原点在主屏**左下**、y 轴向上），
/// 而 `SCDisplay.frame` / `CGDisplayBounds` 用的是 Quartz 坐标（原点在主屏**左上**、y 轴向下）。
/// 两者混用会让多屏（尤其是副屏在主屏上方时）的选区垂直翻转。
/// 这里统一走 Quartz，坐标语义与采集层一致。
struct SystemDisplayLocator: DisplayLocating {

    func displayUnderPointer() -> DisplayGeometry? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        let activeIDs = ids.prefix(Int(count))

        // 指针位置用 CGEvent 读，同样是 Quartz 全局坐标
        let pointer = CGEvent(source: nil)?.location
        let targetID = activeIDs.first { displayID -> Bool in
            guard let pointer else { return false }
            return CGDisplayBounds(displayID).contains(pointer)
        } ?? CGMainDisplayID()

        return geometry(for: targetID)
    }

    private func geometry(for displayID: CGDirectDisplayID) -> DisplayGeometry? {
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else { return nil }
        return DisplayGeometry(frame: bounds,
                               backingScale: backingScale(for: displayID),
                               displayID: displayID)
    }

    /// 像素宽 / 点宽 = backing scale。
    ///
    /// 不直接用 `NSScreen.backingScaleFactor`：`CGDisplayCopyDisplayMode` 给了更原始的事实，
    /// 而且在缩放分辨率（"更多空间"）下两者会不一致 —— 采集关心的正是像素与点的比例。
    private func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        if let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 {
            return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        }
        // 取不到显示模式时退回 AppKit 的说法
        return NSScreen.screens
            .first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == displayID
            }?
            .backingScaleFactor ?? 1
    }
}

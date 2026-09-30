import CoreGraphics
import Foundation

/// 一个可截图的窗口。
///
/// 这是从 `CGWindowListCopyWindowInfo` / `SCWindow` 抽出来的**纯值类型**，
/// 目的是让"哪一层算普通窗口""点在哪扇窗上"这些判定能脱离真实窗口系统单测 ——
/// 而它们恰恰是最容易写错、又最不容易看出来的部分（选错窗口不会报错，只会截错东西）。
public struct WindowInfo: Equatable, Sendable {
    /// `kCGWindowNumber`，与 `SCWindow.windowID` 是同一个值，采集时靠它对应
    public let windowID: UInt32
    /// **Quartz 全局点坐标**（`kCGWindowBounds` 就是这个空间）
    public let frame: CGRect
    /// `kCGWindowLayer`
    public let layer: Int
    /// `kCGWindowOwnerPID`
    public let ownerPID: Int32
    /// `kCGWindowOwnerName`
    public let ownerName: String
    /// `kCGWindowName`（没有屏幕录制授权时系统会抹掉这个字段）
    public let title: String?
    /// `kCGWindowAlpha`
    public let alpha: Double

    public init(windowID: UInt32,
                frame: CGRect,
                layer: Int,
                ownerPID: Int32,
                ownerName: String,
                title: String?,
                alpha: Double) {
        self.windowID = windowID
        self.frame = frame
        self.layer = layer
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.alpha = alpha
    }

    /// 悬停时显示给用户的说明（应用名 + 窗口标题）
    public var hoverLabel: String {
        guard let title, !title.isEmpty else { return ownerName }
        return "\(ownerName) — \(title)"
    }
}

/// 窗口清单的筛选与命中测试。
public enum WindowCatalog {

    /// 可以作为截图目标的窗口层区间 `[0, 20)`。
    ///
    /// 数值取自 `CGWindowLevel.h`：普通窗口 `kCGNormalWindowLevel = 0`、
    /// 浮动窗口 `3`、模态面板 `8` —— 都在区间内；
    /// 而 `kCGDockWindowLevel = 20`、`kCGMainMenuWindowLevel = 24`、
    /// `kCGStatusWindowLevel = 25`、桌面为负值，全部被挡在外面。
    /// 用区间而不是"等于 0"，是为了让浮动面板（很多应用的检查器/工具栏）也能被选中。
    public static let selectableLayers = 0..<20

    /// 太小的窗口多半是辅助窗口/阴影壳，选它没有意义
    public static let minimumSide: CGFloat = 10

    /// 全透明窗口不可见，不该被选中
    public static let minimumAlpha: Double = 0.01

    /// 过滤出可以作为目标的窗口。
    ///
    /// 排除项：自己的进程（否则会选中覆盖层自己）、层级不在 `selectableLayers` 内、
    /// 尺寸过小、几乎全透明。
    public static func selectable(from windows: [WindowInfo], excludingPID pid: Int32) -> [WindowInfo] {
        windows.filter { window in
            guard window.ownerPID != pid else { return false }
            guard selectableLayers.contains(window.layer) else { return false }
            guard window.alpha >= minimumAlpha else { return false }
            guard window.frame.width >= minimumSide, window.frame.height >= minimumSide else { return false }
            return true
        }
    }

    /// 只留下真实在屏上的窗口，并排成**前台 → 后台**。
    ///
    /// `frontToBackIDs` 来自 `CGWindowListCopyWindowInfo`（越靠前越靠近用户）。
    /// 不在这份清单里的窗口，屏幕上已经看不到（别的 Space、已关闭、或被系统标成不在屏上），
    /// 不能拿它们的矩形去做命中 —— 否则会选中一块区域内根本看不见的窗。
    public static func orderedForHitTesting(_ windows: [WindowInfo],
                                            frontToBackIDs: [UInt32]) -> [WindowInfo] {
        var rank: [UInt32: Int] = [:]
        rank.reserveCapacity(frontToBackIDs.count)
        for (index, id) in frontToBackIDs.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return windows
            .filter { rank[$0.windowID] != nil }
            .sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }
    }

    /// 命中测试：返回该点上**用户实际看见**的那扇窗；没有则 `nil`。
    ///
    /// 输入必须已经是前台 → 后台（`orderedForHitTesting`）。
    /// 取第一个框住该点的可选窗口，**不再按 layer 重排**：
    /// 层数更高但排在后面的窗，是被挡住的，不该因为 layer 数字更大就被选上。
    public static func topmost(at point: CGPoint,
                               in windows: [WindowInfo],
                               excludingPID pid: Int32) -> WindowInfo? {
        selectable(from: windows, excludingPID: pid).first { $0.frame.contains(point) }
    }
}

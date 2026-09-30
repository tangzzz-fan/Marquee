import CoreGraphics
import MarqueeCore

/// 覆盖层的选区交互状态机。
///
/// 归属 ticket：03（选区）、04（窗口识别）、10（放大镜）。
///
/// 之所以把它定义成纯值类型而不是散在 `NSPanel` 子类里：覆盖层的窗口行为无法自动化测试，
/// 但**状态迁移可以**。把迁移规则抽出来单测，是这一层唯一能被测试覆盖的部分，
/// 也是唯一能防止「Esc 在某些状态下退不出去」这类 bug 的手段。
public enum SelectionPhase: Equatable, Sendable {
    /// 蒙层已出现，尚未开始拖拽
    case awaitingDrag
    /// 正在拖拽：锚点固定，当前点跟随鼠标
    case dragging(anchor: CGPoint, current: CGPoint)
    /// 已落点，等待提交采集
    case settled(rect: CGRect)
    /// 已取消，覆盖层即将关闭
    case cancelled
}

import CoreGraphics
import Foundation

/// 覆盖层的选区交互状态机。
///
/// 归属 ticket：03（选区）、04（窗口识别）、10（放大镜）。
///
/// 之所以是纯值类型而不是散在 `NSPanel` 子类里：覆盖层的窗口行为无法自动化测试，
/// 但**状态迁移可以**。把迁移规则抽出来单测，是这一层唯一能被测试覆盖的部分，
/// 也是唯一能防止「Esc 在某些状态下退不出去」这类 bug 的手段。
///
/// ⚠️ **坐标空间约定**：本类型不关心单位，但调用方必须一致。
/// 覆盖层喂进来的是 **Cocoa 全局点坐标**（`NSEvent` 与 `NSScreen.frame` 都在这个空间）。
/// 只有在提交采集时才通过 `ScreenCoordinateConversion` 转成 Quartz 全局坐标
/// （`DisplayGeometry.frame` 用的是那个空间）。两套空间混用会让多屏下的选区上下翻转。
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

/// 选区拖拽会话。
///
/// 把「按下 → 拖 → 松手 → 微调 → 提交/取消」的全部规则收在一个可单测的值类型里。
/// 不标 `@MainActor`：它是纯值类型，没有共享状态，测试与调用都不该被隔离约束绑架。
public struct SelectionSession: Equatable, Sendable {

    public private(set) var phase: SelectionPhase = .awaitingDrag
    /// ⇧ 是否按下。拖拽中它表示「锁定正方形」，已落点后它表示「方向键步长 ×10」。
    public private(set) var isShiftDown = false
    /// 是否经过方向键精修。精修后不再吸附到整点（见 `nudge` 的注释）。
    public private(set) var isRefined = false

    public init() {}

    // MARK: - 查询

    /// 当前选区（连续点坐标）。无有效选区时为 `nil`。
    public var rect: CGRect? {
        switch phase {
        case .awaitingDrag, .cancelled:
            nil
        case .dragging(let anchor, let current):
            Self.validRect(anchor: anchor, current: current, square: isShiftDown)
        case .settled(let rect):
            rect.width > 0 && rect.height > 0 ? rect : nil
        }
    }

    public var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    /// 是否已经落点（可以提交）
    public var isSettled: Bool {
        if case .settled = phase { return true }
        return false
    }

    public var isCancelled: Bool { phase == .cancelled }

    // MARK: - 拖拽

    public mutating func beginDrag(at point: CGPoint) {
        guard !isCancelled else { return }
        phase = .dragging(anchor: point, current: point)
        isRefined = false
    }

    public mutating func updateDrag(to point: CGPoint) {
        guard case .dragging(let anchor, _) = phase else { return }
        phase = .dragging(anchor: anchor, current: point)
    }

    /// 松手落点。返回是否产生了一个**可采集**的选区。
    ///
    /// 面积不足 1×1 点直接视为"没选"。
    /// 注意阈值要在**吸附之前**判：`Selection.snapped` 会把 0.5 点吸成 1 点，
    /// 在吸附之后判的话，"误点一下"也会交出一张 2×2 像素的空图。
    @discardableResult
    public mutating func endDrag(at point: CGPoint) -> Bool {
        guard case .dragging(let anchor, _) = phase else { return false }
        guard let raw = Self.validRect(anchor: anchor, current: point, square: isShiftDown),
              raw.width >= 1, raw.height >= 1 else {
            phase = .awaitingDrag
            return false
        }
        // 鼠标拖拽本来也给不出有意义的亚点精度，落点吸附到整点让输出尺寸稳定
        phase = .settled(rect: Selection.snapped(raw))
        return true
    }

    public mutating func setShiftDown(_ isDown: Bool) {
        isShiftDown = isDown
        // 拖拽中按/放 ⇧ 应当立即改变形状，而不是等下一次鼠标移动
        if case .dragging(let anchor, let current) = phase {
            phase = .dragging(anchor: anchor, current: current)
        }
    }

    // MARK: - 方向键精修

    /// 平移已落点的选区。
    ///
    /// **刻意不吸附到整点**：ticket 03 要求 ±1 像素微调，
    /// 而 2x 屏上「1 像素」= 0.5 点 —— 吸附会把这一步吃掉。
    /// 吸附只在 `endDrag` 做，精修之后以精修为准。
    @discardableResult
    public mutating func nudge(dx: CGFloat, dy: CGFloat) -> Bool {
        guard case .settled(let rect) = phase else { return false }
        phase = .settled(rect: rect.offsetBy(dx: dx, dy: dy))
        isRefined = true
        return true
    }

    // MARK: - 结束

    public mutating func cancel() {
        phase = .cancelled
    }

    /// 直接给出一个矩形（整屏 / 程序化设定）
    public mutating func settle(rect: CGRect) {
        phase = .settled(rect: rect)
        isRefined = false
    }

    // MARK: - 内部

    private static func validRect(anchor: CGPoint, current: CGPoint, square: Bool) -> CGRect? {
        let effective = square ? Self.squaredCurrent(anchor: anchor, current: current) : current
        let rect = Selection.rect(anchor: anchor, current: effective)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// ⇧ 锁定正方形：取拖拽位移较大的那一轴作为边长，方向保持原样。
    private static func squaredCurrent(anchor: CGPoint, current: CGPoint) -> CGPoint {
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: anchor.x + (dx < 0 ? -side : side),
                       y: anchor.y + (dy < 0 ? -side : side))
    }
}

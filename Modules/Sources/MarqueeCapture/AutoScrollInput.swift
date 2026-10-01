import CoreGraphics
import Foundation
import MarqueeCore

/// 用合成滚轮事件驱动页面滚动（ticket 12 里自动滚动的"手"）。
///
/// ## 为什么要先把指针对准选区
///
/// 滚轮事件并不是"发给某个窗口"的 —— 它由窗口服务器按**指针下方的窗口**派发。
/// 指针不在选区上，事件就滚了别的窗口，用户看到的现象是
/// "按了自动滚动，什么都没发生（或者旁边那个应用莫名其妙滚了）"。
/// 所以 `begin(targeting:)` 先把指针挪到选区中心。
///
/// ## 为什么拆成一串小事件，而不是一个大事件
///
/// 单个巨大的滚轮事件在不同应用里处理差别很大：有的当成"翻页"直接跳到底，
/// 有的被惯性平滑掉，还有的干脆忽略。拆成若干小步更像真人在滚，
/// 各应用的行为也一致得多。
public struct CGEventScrollWheelEmitter: ScrollWheelEmitting {

    /// 一次 `emitScrollDown` 拆成多少个滚轮事件
    private let eventCount: Int
    /// 事件单位。用 `.pixel` 而不是 `.line`：行高因应用而异，
    /// 而"滚了多少点"与选区高度是同一个尺度（`AutoScrollPolicy.stepFraction` 也是按点算的）。
    private let unit: CGScrollEventUnit

    public init(eventCount: Int = 8, unit: CGScrollEventUnit = .pixel) {
        self.eventCount = max(1, eventCount)
        self.unit = unit
    }

    public func begin(targeting point: CGPoint) async {
        CGWarpMouseCursorPosition(point)
        // 挪指针是**异步**生效的（要过窗口服务器）。不让出一小会儿，
        // 头几个事件会按旧位置派发。
        try? await Task.sleep(for: .milliseconds(40))
    }

    public func emitScrollDown(points: Double) async {
        guard points > 0 else { return }

        // ⚠️ 符号：CGEvent 的 wheel1 **向下滚是负值**（与 `NSEvent.scrollingDeltaY` 一致）。
        // 写成正值会让页面往上跑，而且不会报任何错 —— 只是方向反了。
        let perEvent = -points / Double(eventCount)
        let step = Int32(perEvent.rounded())
        guard step != 0 else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<eventCount {
            guard let event = CGEvent(scrollWheelEvent2Source: source,
                                      units: unit,
                                      wheelCount: 1,
                                      wheel1: step,
                                      wheel2: 0,
                                      wheel3: 0) else { continue }
            event.post(tap: .cghidEventTap)
            // 事件之间留缝：连发太快会被合并成一个，惯性也就跟真人不像了
            try? await Task.sleep(for: .milliseconds(8))
        }
    }
}

/// `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` 的封装。
///
/// ## 为什么要自己记"问过了没有"
///
/// `CGPreflightPostEventAccess()` 只给一个布尔值，分不出"从未询问过"与"已经被拒绝" ——
/// 而这两者要走完全不同的分支：前者可以弹一次系统框，后者只能引导用户去系统设置。
/// 所以"问过一次仍未授权"这件事必须由本进程记住。
///
/// **只记在进程内，绝不写 UserDefaults**：与屏幕录制权限同一个坑 ——
/// 签名身份一变 TCC 就重置，而磁盘上的标记还在，于是再也不敢弹框，
/// 用户被永久锁死（2026-09-30 实测踩到，见 `docs/DEV-NOTES.md` 第 1 节）。
public final class SystemPostEventPermission: PostEventPermissionProbing, @unchecked Sendable {

    private let lock = NSLock()
    private var askedOnce = false

    public init() {}

    public func currentPostEventPermission() -> PostEventPermission {
        if CGPreflightPostEventAccess() { return .granted }
        return withLock { askedOnce ? .denied : .notDetermined }
    }

    @discardableResult
    public func requestPostEventPermission() -> Bool {
        // 被拒绝过的进程再调它不会弹框，直接返回 false。
        let granted = CGRequestPostEventAccess()
        withLock { askedOnce = true }
        return granted
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

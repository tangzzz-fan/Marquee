import CoreGraphics
import Foundation

// MARK: - 接缝：合成滚动事件

/// 把"往下滚一点"送进别的应用。
///
/// 抽成协议的理由与其它接缝一致：自动滚动的**编排**（滚多少、等多久、什么时候收工）
/// 必须能脱机单测，真正发事件的那一下才需要真实系统。
/// 真实实现见 `MarqueeCapture.CGEventScrollWheelEmitter`。
public protocol ScrollWheelEmitting: Sendable {
    /// 开始之前把"操作落点"对准。
    ///
    /// **这一步不能省**：滚轮事件是发给**指针下方**那个窗口的，
    /// 指针要是不在选区上，滚的就是别的窗口（用户看到的是"什么都没发生"）。
    /// 真实实现会把指针移到选区中心。
    ///
    /// - Parameter point: Quartz 全局点坐标，与提交采集时用的是同一套坐标
    func begin(targeting point: CGPoint) async

    /// 发一次向下滚动。
    ///
    /// - Parameter points: 滚动距离，单位是**屏幕点**。
    ///   用点而不是"滚轮行"：不同应用的行高差别很大，而"滚多少距离"与选区高度是同一个尺度。
    func emitScrollDown(points: Double) async
}

// MARK: - 接缝：事件发送权限

/// 「把合成事件送进别的进程」的授权状态 —— 也就是系统设置里的**辅助功能**。
///
/// ## 为什么自动滚动会引出一个新权限
///
/// 手动滚动是用户自己在滚，Marquee **一个事件都不用发**；
/// 自动滚动必须**代用户发滚轮事件**，而 macOS 把"向其它进程注入事件"划进辅助功能授权。
/// 也就是说：自动滚动是本项目里**唯一**需要辅助功能的功能。
///
/// 因此它必须是**按需**的 —— 用户主动按空格才问，拒绝了就退回手动，
/// 不挡任何已有能力（截图、标注、手动长截图全都不需要它）。
public enum PostEventPermission: Equatable, Sendable {
    /// 已授权，可以直接发事件
    case granted
    /// 本进程已经问过一次系统、仍然没给。系统不会再弹框，只能去系统设置手动打开。
    case denied
    /// 从未询问过 —— 可以走一次系统授权流程
    case notDetermined
}

/// 权限探针。抽成协议的理由与屏幕录制权限一致：
/// "权限状态 → 走哪条分支"必须能脱离真实 TCC 单测。
public protocol PostEventPermissionProbing: Sendable {
    /// 当前状态，**不弹**任何系统框
    func currentPostEventPermission() -> PostEventPermission

    /// 触发系统授权流程（会弹框）。返回结束后是否已授权。
    @discardableResult
    func requestPostEventPermission() -> Bool
}

// MARK: - 策略

/// 自动滚动的节奏与熔断。
///
/// 全部阈值集中在这里，因为它们**只能靠眼睛在真实页面上调**：
/// 滚太快会拍到惯性未停的糊帧、滚太慢整场慢得让人以为卡住。
public struct AutoScrollPolicy: Equatable, Sendable {
    /// 每一步滚多远 = 选区高度 × 这个比例。
    ///
    /// 用**比例**而不是固定的像素/行数：选区大小与页面行高千差万别，
    /// 固定值要么滚不动、要么一次滚过头 —— 后者会让相邻两帧没有重叠，
    /// 配准直接判 `noOverlap`，整场白跑。0.65 留出约 35% 重叠。
    public var stepFraction: Double

    /// 每拍之间等多久（秒）。
    ///
    /// 比手动滚动的 `frameInterval`（0.35 s）小：自动滚动要**勤看着点**画面停没停，
    /// 不然每步都要多等好几个 0.35 秒，整场慢得像卡住。
    public var tickInterval: Double

    /// 发完滚动后至少等几拍才去判"停稳"。
    ///
    /// 惯性衰减需要时间，刚发完事件的那几拍必然还在动 —— 提前判只会白等一轮。
    public var minimumFramesBeforeSettle: Int

    /// 连续几拍位移足够小算"停稳"。
    ///
    /// 取 2 以上是为了躲开惯性回弹时那一下瞬时归零：只安静一拍就判稳，
    /// 会把回弹前的瞬间当成终点。
    public var settledFrames: Int

    /// 单步最多等几拍就放弃等待、直接拍一帧。
    ///
    /// 页面在无限加载、或一直有动画时永远不会"停"，没有这个上限就会**死等**。
    public var maximumFramesPerStep: Int

    /// 连续几步「抓到的帧没带来新内容」判定到底。
    public var stationaryStepsBeforeBottom: Int

    /// 整场最多滚多少步（保险丝）。
    public var maximumSteps: Int

    /// 连续多少次"采不到画面"就收工 —— 采不到说明这条路已经不通了。
    public var probeFailuresBeforeStall: Int

    public init(stepFraction: Double = 0.65,
                tickInterval: Double = 0.12,
                minimumFramesBeforeSettle: Int = 2,
                settledFrames: Int = 2,
                maximumFramesPerStep: Int = 20,
                stationaryStepsBeforeBottom: Int = 2,
                maximumSteps: Int = 60,
                probeFailuresBeforeStall: Int = 4) {
        self.stepFraction = stepFraction
        self.tickInterval = tickInterval
        self.minimumFramesBeforeSettle = minimumFramesBeforeSettle
        self.settledFrames = settledFrames
        self.maximumFramesPerStep = maximumFramesPerStep
        self.stationaryStepsBeforeBottom = stationaryStepsBeforeBottom
        self.maximumSteps = maximumSteps
        self.probeFailuresBeforeStall = probeFailuresBeforeStall
    }

    public static let `default` = AutoScrollPolicy()
}

/// 自动滚动为什么停下。
public enum AutoScrollStopReason: Equatable, Sendable {
    /// 画面不再前进 —— 到底了
    case atBottom
    /// 长图撞到高度上限
    case atLimit
    /// 采集 / 配准持续失败
    case stalled(String)
    /// 滚满步数熔断
    case tooLong
    /// 没有辅助功能授权，一步都没发出去
    case needsPermission
    /// 用户中断
    case cancelled
}

// MARK: - 驱动器

/// 自动滚动的节奏驱动器。
///
/// ## 职责边界
///
/// 它**不发事件、不抓帧、不拼图** —— 那三件事分别归 `ScrollWheelEmitting`、
/// 采集器与 `ScrollCaptureSession`。它只回答一个问题：
/// **下一步该干什么**。这样"什么时候滚、什么时候等、什么时候收工"这套判断
/// 能在没有屏幕、没有权限、没有真实应用的环境下被完整断言。
///
/// ## 一次 `step()` 只做一件事
///
/// 探测一拍、抓一帧、或发一次滚动。宿主按 `policy.tickInterval` 反复调它，
/// 与手动模式下按 `frameInterval` 反复调 `captureFrame()` 是同一种驱动方式。
/// 刻意不做成"内部自带定时器的异步循环"：那样这套判断就没法被逐拍断言了。
@MainActor
public final class AutoScrollDriver {

    public enum Stage: Equatable, Sendable {
        case idle
        /// 已经发出滚动，正在等画面停下
        case settling(step: Int, frames: Int)
        /// 画面停稳了，抓一帧正式并入长图
        case capturing(step: Int)
        case finished(AutoScrollStopReason)
    }

    public struct Status: Equatable, Sendable {
        public var stage: Stage
        /// 长图会话的最新进度（高度、帧数、告警）
        public var capture: ScrollCaptureSession.Progress
        /// 给用户看的一句话；正常推进时为空
        public var message: String?

        public var isFinished: Bool {
            if case .finished = stage { return true }
            return false
        }
    }

    private let session: ScrollCaptureSession
    private let emitter: ScrollWheelEmitting
    private let permission: PostEventPermissionProbing
    public let policy: AutoScrollPolicy

    public private(set) var status: Status

    private var settledFrameCount = 0
    private var probeFailureCount = 0
    private var stationaryStepCount = 0
    private var lastCanvasHeight: Int

    public init(session: ScrollCaptureSession,
                emitter: ScrollWheelEmitting,
                permission: PostEventPermissionProbing,
                policy: AutoScrollPolicy = .default) {
        self.session = session
        self.emitter = emitter
        self.permission = permission
        self.policy = policy
        self.lastCanvasHeight = session.progress.canvasHeight
        self.status = Status(stage: .idle, capture: session.progress)
    }

    /// 走。
    ///
    /// - 没授权：一步都不发，直接以 `.needsPermission` 收工（**不在这里弹框**：
    ///   弹框是宿主的决定，它还要负责告诉用户去哪儿打开）
    /// - 已经收工：原样返回，绝不重复发事件
    @discardableResult
    public func start() async -> Status {
        guard !status.isFinished else { return status }
        guard session.progress.phase.isAcceptingFrames else {
            return finish(.stalled("长截图还没开始，没法自动滚动"))
        }
        guard permission.currentPostEventPermission() == .granted else {
            return finish(.needsPermission)
        }
        await emitter.begin(targeting: session.quartzSelectionCenter)
        return await scrollNext(step: 1)
    }

    /// 推进一拍。宿主按 `policy.tickInterval` 反复调用。
    @discardableResult
    public func step() async -> Status {
        switch status.stage {
        case .idle:
            return await start()
        case .settling(let step, let frames):
            return await settle(step: step, frames: frames)
        case .capturing(let step):
            return await capture(step: step)
        case .finished:
            return status
        }
    }

    /// 中断（`Esc`）：已拼好的部分保留可用，由宿主决定接下来做什么。
    @discardableResult
    public func stop(_ reason: AutoScrollStopReason = .cancelled) -> Status {
        guard !status.isFinished else { return status }
        return finish(reason)
    }

    // MARK: - 内部

    /// 等画面停下。
    ///
    /// 这一步是自动滚动与手动滚动的**本质区别**：手动时用户看得见自己在滚，
    /// 自动时没人看着，拍到糊帧也没人知道 —— 只能靠"连续几拍位移足够小"来代表"停了"。
    private func settle(step: Int, frames: Int) async -> Status {
        let shift = await session.probeFrame()

        if shift == nil {
            probeFailureCount += 1
            if probeFailureCount >= policy.probeFailuresBeforeStall {
                return finish(.stalled("连续采不到画面，自动滚动已停下"))
            }
        } else {
            probeFailureCount = 0
        }

        let nextFrames = frames + 1
        let stillMoving = (shift?.rows ?? 0) >= session.settings.policy.minimumScrollRows
        let quiet = nextFrames >= policy.minimumFramesBeforeSettle && !stillMoving
        settledFrameCount = quiet ? settledFrameCount + 1 : 0

        if settledFrameCount >= policy.settledFrames || nextFrames >= policy.maximumFramesPerStep {
            status = Status(stage: .capturing(step: step), capture: session.progress)
            return status
        }
        status = Status(stage: .settling(step: step, frames: nextFrames),
                        capture: session.progress,
                        message: "正在滚动…（第 \(step) 屏）")
        return status
    }

    /// 停稳之后正式抓一帧，由会话决定它是新内容还是"没动"。
    private func capture(step: Int) async -> Status {
        let progress = await session.captureFrame()

        switch progress.phase {
        case .atLimit:
            return finish(.atLimit)
        case .stalled(let message):
            return finish(.stalled(message))
        default:
            break
        }

        if progress.canvasHeight > lastCanvasHeight {
            stationaryStepCount = 0
            lastCanvasHeight = progress.canvasHeight
        } else {
            stationaryStepCount += 1
        }

        if stationaryStepCount >= policy.stationaryStepsBeforeBottom {
            return finish(.atBottom)
        }
        if step >= policy.maximumSteps {
            return finish(.tooLong)
        }
        return await scrollNext(step: step + 1)
    }

    private func scrollNext(step: Int) async -> Status {
        settledFrameCount = 0
        let distance = session.quartzSelection.height * policy.stepFraction
        await emitter.emitScrollDown(points: distance)
        status = Status(stage: .settling(step: step, frames: 0),
                        capture: session.progress,
                        message: "正在滚动…（第 \(step) 屏）")
        return status
    }

    private func finish(_ reason: AutoScrollStopReason) -> Status {
        status = Status(stage: .finished(reason),
                        capture: session.progress,
                        message: Self.message(for: reason))
        return status
    }

    private static func message(for reason: AutoScrollStopReason) -> String {
        switch reason {
        case .atBottom: "看起来已经滚到底了，按 ⏎ 结束"
        case .atLimit: "长图已达高度上限，按 ⏎ 结束"
        case .stalled(let detail): "\(detail)，按 ⏎ 结束可保留已拼好的部分"
        case .tooLong: "滚动步数已达上限，按 ⏎ 结束"
        case .needsPermission: "自动滚动需要「辅助功能」授权；也可以自己滚（手动模式）"
        case .cancelled: "已停止自动滚动"
        }
    }
}

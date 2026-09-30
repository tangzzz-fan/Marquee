import CoreGraphics
import Foundation

/// 一次滚动截屏的会话（ticket 11：手动滚动 MVP）。
///
/// 职责：**编排抓帧节奏、判定每帧能不能要、把长图交出去**。
/// 三件事各自有独立的可测落点：
/// - 位移怎么算 → `ScrollFrameRegistering`（Vision 实现 / 测试替身）
/// - 排布怎么算 → `ScrollStitcher`（纯值类型）
/// - 什么时候停 → `ScrollRegistrationPolicy`（纯值类型）
///
/// ## 为什么是「被驱动」而不是自带定时器
///
/// 抓帧节奏由宿主按 `Settings.frameInterval` 反复调 `captureFrame()` 驱动，
/// 而不是内部起 `Task.sleep` 循环。这样整个会话能在没有时钟、没有屏幕的环境下
/// 被逐帧推进并断言状态迁移 —— 覆盖层那层「窗口行为无法自动化测试」的处境正好相反，
/// 这里刻意把逻辑留在能测的一侧。
@MainActor
public final class ScrollCaptureSession {

    // MARK: - 值类型

    public struct Settings: Equatable, Sendable {
        /// 两次抓帧之间的间隔（秒）。
        ///
        /// 太小会拍到滚动惯性还没停的帧（运动模糊，SPIKE 待人工项 M14）；
        /// 太大用户得多滚一会儿才够。0.35 s 是"手滚一屏大约耗时"的量级。
        public var frameInterval: Double
        /// 长图高度上限。超了就停下来提示，避免无限滚动页面把内存吃光。
        public var maximumCanvasHeight: Int
        public var policy: ScrollRegistrationPolicy

        public init(frameInterval: Double = 0.35,
                    maximumCanvasHeight: Int = 40_000,
                    policy: ScrollRegistrationPolicy = .default) {
            self.frameInterval = frameInterval
            self.maximumCanvasHeight = maximumCanvasHeight
            self.policy = policy
        }

        public static let `default` = Settings()
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case capturing
        /// 已经滚到底：不再追加，等用户结束
        case atBottom
        /// 连续配准失败 / 抓帧失败：停止追加，保留已有内容等用户决定
        case stalled(String)
        /// 已到高度上限
        case atLimit
        case finished
        case cancelled

        public var isAcceptingFrames: Bool { self == .capturing }
    }

    public struct Progress: Equatable, Sendable {
        public var phase: Phase
        public var frameCount: Int
        public var canvasHeight: Int
        /// 累计精确位移（小数）
        public var accumulatedRows: Double
        /// 界面要显示的提示；正常时为空
        public var warning: String?
        /// 最近一次配准耗时（毫秒），供性能回归观察
        public var lastRegistrationMilliseconds: Double?
        /// 收尾拼接耗时（毫秒）。只有 `finished` 之后才有值。
        public var stitchMilliseconds: Double?

        public init(phase: Phase,
                    frameCount: Int,
                    canvasHeight: Int,
                    accumulatedRows: Double,
                    warning: String? = nil,
                    lastRegistrationMilliseconds: Double? = nil,
                    stitchMilliseconds: Double? = nil) {
            self.phase = phase
            self.frameCount = frameCount
            self.canvasHeight = canvasHeight
            self.accumulatedRows = accumulatedRows
            self.warning = warning
            self.lastRegistrationMilliseconds = lastRegistrationMilliseconds
            self.stitchMilliseconds = stitchMilliseconds
        }

        public static let idle = Progress(phase: .idle,
                                          frameCount: 0,
                                          canvasHeight: 0,
                                          accumulatedRows: 0)
    }

    public enum BeginResult: Equatable, Sendable {
        case started(Progress)
        case permissionBlocked(blockedBy: CaptureGateDecision, grantedJustNow: Bool)
        case failed(CaptureFailure)
    }

    // MARK: - 依赖

    private let permission: ScreenRecordingPermissionProbing
    private let capturer: ScreenCapturing
    private let registrar: ScrollFrameRegistering
    private let clipboard: ClipboardWriting
    private let clock: MonotonicClock
    public let settings: Settings

    // MARK: - 状态

    public private(set) var progress: Progress = .idle
    private var stitcher: ScrollStitcher?
    private var frames: [CGImage] = []
    /// 本会话采的固定区域（**Quartz 全局点坐标**）与它所在的屏
    private var region: CGRect = .zero
    private var regionDisplay: DisplayGeometry?
    private var output: CaptureOutput?
    private var startedAt: Double = 0
    private var stationaryCount = 0
    private var failureCount = 0

    public init(permission: ScreenRecordingPermissionProbing,
                capturer: ScreenCapturing,
                registrar: ScrollFrameRegistering,
                clipboard: ClipboardWriting,
                clock: MonotonicClock = SystemMonotonicClock(),
                settings: Settings = .default) {
        self.permission = permission
        self.capturer = capturer
        self.registrar = registrar
        self.clipboard = clipboard
        self.clock = clock
        self.settings = settings
    }

    /// 已采到的帧数（诊断与断言用）
    public var frameCount: Int { frames.count }

    // MARK: - 起步

    /// - Parameter selection: **Quartz 全局点坐标**下的选区
    public func begin(selection: CGRect, displays: [DisplayGeometry]) async -> BeginResult {
        reset()

        switch await CaptureGateRunner.run(permission) {
        case .blocked(let decision):
            return .permissionBlocked(blockedBy: decision, grantedJustNow: false)
        case .proceed:
            break
        }

        // 滚动截屏只在一屏内成立：滚的是这块区域，跨屏没有意义。
        // 取交集最大的那块屏并把选区裁进它 —— 明确裁掉，而不是默默取整张屏。
        var best: (display: DisplayGeometry, overlap: CGRect)?
        var bestArea: CGFloat = 0
        for display in displays {
            let overlap = display.frame.intersection(selection)
            guard !overlap.isNull, overlap.width >= 8, overlap.height >= 8 else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = (display, overlap)
            }
        }

        guard let (display, clipped) = best else {
            return .failed(CaptureFailure(message: "长截图区域太小，或者不落在任何显示器上"))
        }

        region = clipped
        regionDisplay = display

        let output = CaptureOutput(clipboard: clipboard, clock: clock)
        self.output = output
        startedAt = output.begin()

        // 先抓一帧作基线：用户按确认时看到的内容就是长图的顶部
        do {
            let captured = try await capturer.captureRegion(region, on: display)
            frames = [captured.image]
            var stitcher = ScrollStitcher(pixelWidth: captured.image.width,
                                          viewHeight: captured.image.height)
            stitcher.append(rows: 0)
            self.stitcher = stitcher
            progress = Progress(phase: .capturing,
                                frameCount: 1,
                                canvasHeight: stitcher.totalHeight,
                                accumulatedRows: 0)
        } catch {
            return .failed(CaptureFailure(message: "长截图起步失败：\(error.localizedDescription)"))
        }
        return .started(progress)
    }

    // MARK: - 逐帧推进

    /// 抓一帧并对齐。宿主按 `settings.frameInterval` 节奏反复调用。
    @discardableResult
    public func captureFrame() async -> Progress {
        guard progress.phase.isAcceptingFrames,
              let stitcher,
              let previous = frames.last,
              let display = regionDisplay else {
            return progress
        }

        let captured: CapturedImage
        do {
            captured = try await capturer.captureRegion(region, on: display)
        } catch {
            return recordFailure("抓帧失败：\(error.localizedDescription)")
        }

        // 像素尺寸变了说明区域或屏发生了变化，继续拼会得到错位长图 —— 宁停不拼
        guard captured.image.width == stitcher.pixelWidth,
              captured.image.height == stitcher.viewHeight else {
            return stall("画面尺寸发生了变化（\(stitcher.pixelWidth)×\(stitcher.viewHeight) → "
                         + "\(captured.image.width)×\(captured.image.height)）")
        }

        let registrationStartedAt = clock.now()
        let shift: ScrollShift
        do {
            shift = try await registrar.register(previous: previous, current: captured.image)
        } catch let failure as ScrollRegistrationFailure {
            return recordFailure(failure.localizedDescription)
        } catch {
            return recordFailure("配准失败：\(error.localizedDescription)")
        }
        progress.lastRegistrationMilliseconds = (clock.now() - registrationStartedAt) * 1000

        if shift.confidence < settings.policy.minimumConfidence {
            return recordFailure("这一帧可信度不足（\(String(format: "%.2f", shift.confidence))）")
        }

        switch settings.policy.verdict(for: shift, frameHeight: stitcher.viewHeight) {
        case .noOverlap(let rows):
            return recordFailure(ScrollRegistrationFailure.notEnoughOverlap(rows: rows).localizedDescription)

        case .stationary:
            failureCount = 0
            stationaryCount += 1
            progress.frameCount = frames.count
            progress.canvasHeight = stitcher.totalHeight
            if stationaryCount >= settings.policy.stationaryFramesBeforeStop {
                progress.phase = .atBottom
                progress.warning = "已经滚到底了，按 ⏎ 结束"
            } else {
                progress.warning = "没检测到滚动…继续往下滚"
            }
            return progress

        case .append(let rows):
            stationaryCount = 0
            failureCount = 0
            var updated = stitcher
            updated.append(rows: rows)
            if updated.totalHeight > settings.maximumCanvasHeight {
                progress.phase = .atLimit
                progress.canvasHeight = stitcher.totalHeight
                progress.warning = "长图已达 \(settings.maximumCanvasHeight) px 上限，按 ⏎ 结束"
                return progress
            }
            self.stitcher = updated
            frames.append(captured.image)
            progress.phase = .capturing
            progress.frameCount = frames.count
            progress.canvasHeight = updated.totalHeight
            progress.accumulatedRows = updated.accumulatedRows
            progress.warning = nil
            return progress
        }
    }

    // MARK: - 收场

    /// 结束并输出：拼长图 → 剪贴板 →（可选）落盘。
    public func finish(save: CaptureSaveRequest? = nil) async -> CaptureOutcome {
        guard progress.phase != .cancelled else {
            return .failed(CaptureFailure(message: "长截图已取消"))
        }
        guard let stitcher, let output, !frames.isEmpty else {
            return .failed(CaptureFailure(message: "长截图没有采到任何画面"))
        }

        let stitchStartedAt = clock.now()
        guard let composed = ScrollStitchRenderer.render(plan: stitcher.plan, frames: frames) else {
            return .failed(CaptureFailure(message: "拼接长图失败"))
        }
        progress.stitchMilliseconds = (clock.now() - stitchStartedAt) * 1000
        progress.phase = .finished
        progress.canvasHeight = composed.height

        return output.finish(composed, startedAt: startedAt, save: save)
    }

    public func cancel() {
        progress.phase = .cancelled
        frames = []
        stitcher = nil
        regionDisplay = nil
    }

    // MARK: - 内部

    private func reset() {
        progress = .idle
        stitcher = nil
        frames = []
        region = .zero
        regionDisplay = nil
        output = nil
        stationaryCount = 0
        failureCount = 0
    }

    private func recordFailure(_ message: String) -> Progress {
        failureCount += 1
        stationaryCount = 0
        progress.frameCount = frames.count
        progress.canvasHeight = stitcher?.totalHeight ?? 0
        if failureCount >= settings.policy.failuresBeforeStall {
            let tail = frames.count >= 2 ? "，已拼好的部分保留可用，按 ⏎ 结束" : ""
            progress.phase = .stalled(message + tail)
            progress.warning = message + tail
        } else {
            progress.warning = message
        }
        return progress
    }

    private func stall(_ message: String) -> Progress {
        let text = message + "，已停止拼接；按 ⏎ 结束可保留已拼好的部分"
        progress.phase = .stalled(text)
        progress.warning = text
        return progress
    }
}

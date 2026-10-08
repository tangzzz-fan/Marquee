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
        /// 看起来滚到底了 —— **只是提示，不是终局**（见 `isAcceptingFrames`）
        case atBottom
        /// 连续配准失败 / 抓帧失败：停止追加，保留已有内容等用户决定
        case stalled(String)
        /// 已到高度上限
        case atLimit
        case finished
        case cancelled

        /// 还收不收新帧。
        ///
        /// `atBottom` **刻意也算 true**：那只是"看起来到底了"的提示 ——
        /// 用户很可能只是停下来读一会儿，接着还要滚。
        /// 若在这里把抓帧循环停掉，用户再往下滚就**彻底没反应**，
        /// 而且长图会缺掉后半段（比误报更糟）。
        public var isAcceptingFrames: Bool { self == .capturing || self == .atBottom }
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

    /// 已经真正拼进过长图内容（不只是那一帧基线）。
    ///
    /// 用它区分"用户还没开始滚"和"滚过之后停下来了" —— 前者不该报"到底了"。
    public var hasAppendedContent: Bool { frames.count > 1 }

    /// 本会话采的区域（**Quartz 全局点坐标**，已裁进所在的那块屏）。
    ///
    /// 自动滚动（ticket 12）要用它算两件事：每步滚多远（选区高度的比例）、
    /// 以及把指针对准哪儿 —— 滚轮事件是发给**指针下方**那个窗口的。
    public var quartzSelection: CGRect { region }

    /// 选区中心（Quartz 全局点）。见 `quartzSelection`。
    public var quartzSelectionCenter: CGPoint {
        CGPoint(x: region.midX, y: region.midY)
    }

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
            return .failed(CaptureFailure(message: L10n.t("长截图区域太小，或者不落在任何显示器上")))
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
            return .failed(CaptureFailure(message: L10n.t("长截图起步失败：\(error.localizedDescription)")))
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
            return recordFailure(L10n.t("抓帧失败：\(error.localizedDescription)"))
        }

        // 像素尺寸变了说明区域或屏发生了变化，继续拼会得到错位长图 —— 宁停不拼
        guard captured.image.width == stitcher.pixelWidth,
              captured.image.height == stitcher.viewHeight else {
            // 拼成一条而不是两段拼：拆开的话只有前一半进了 catalog，
            // 英文环境下会看到"英文前半 + 中文后半"，而这种半截译文最容易漏掉
            return stall(L10n.t("画面尺寸发生了变化（\(stitcher.pixelWidth)×\(stitcher.viewHeight) → \(captured.image.width)×\(captured.image.height)）"))
        }

        let registrationStartedAt = clock.now()
        let shift: ScrollShift
        do {
            shift = try await registrar.register(previous: previous, current: captured.image)
        } catch let failure as ScrollRegistrationFailure {
            return recordFailure(failure.localizedDescription)
        } catch {
            return recordFailure(L10n.t("配准失败：\(error.localizedDescription)"))
        }
        progress.lastRegistrationMilliseconds = (clock.now() - registrationStartedAt) * 1000

        if shift.confidence < settings.policy.minimumConfidence {
            return recordFailure(L10n.t("这一帧可信度不足（\(String(format: "%.2f", shift.confidence))）"))
        }

        switch settings.policy.verdict(for: shift, frameHeight: stitcher.viewHeight) {
        case .noOverlap(let rows):
            return recordFailure(ScrollRegistrationFailure.notEnoughOverlap(rows: rows).localizedDescription)

        case .stationary:
            failureCount = 0
            stationaryCount += 1
            progress.frameCount = frames.count
            progress.canvasHeight = stitcher.totalHeight

            // 「滚到底」的前提是**真的滚过**。
            //
            // 一进长截图用户还没开始滚，帧帧都一样 —— 那是"还没开始"，不是"到底了"。
            // 不区分这两者的话，进门约 1 秒（3 帧 × 0.35 s）就会误报"已经滚到底"。
            // 用户实测踩到过，且那个提示会让人以为功能坏了。
            guard hasAppendedContent else {
                progress.warning = nil
                return progress
            }

            if stationaryCount >= settings.policy.stationaryFramesBeforeBottomHint {
                progress.phase = .atBottom
                progress.warning = L10n.t("看起来已经滚到底了 · 还可以继续滚，或按 ⏎ 结束")
            } else {
                progress.warning = L10n.t("没检测到滚动…继续往下滚")
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
                progress.warning = L10n.t("长图已达 \(settings.maximumCanvasHeight) px 上限，按 ⏎ 结束")
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

    /// 只探测"画面动没动"，**不进长图**。
    ///
    /// 自动滚动（ticket 12）用它做停滚检测：发完滚动事件后惯性还在继续，
    /// 这时候拍到的帧是糊的。要等画面**真的停下**，再把帧交给 `captureFrame()` 正式入图。
    ///
    /// 与 `captureFrame()` 的分工是刻意的 —— 探测**不改动任何会话状态**：
    /// 不动 `frames`、不动 `stitcher`、不动"连续静止"计数。
    /// 否则"多看了两眼"会把会话的判定带偏（比如把静止计数推到"到底"）。
    ///
    /// - Returns: 相对**最后一帧已入图的帧**的位移；抓帧或配准失败时返回 `nil`
    public func probeFrame() async -> ScrollShift? {
        guard progress.phase.isAcceptingFrames,
              let stitcher,
              let previous = frames.last,
              let display = regionDisplay else {
            return nil
        }

        let captured: CapturedImage
        do {
            captured = try await capturer.captureRegion(region, on: display)
        } catch {
            return nil
        }

        // 尺寸变了说明区域或屏发生了变化。这里不推进状态机 ——
        // 该怎么处理（停机报警）由下一次 `captureFrame()` 按老规矩判。
        guard captured.image.width == stitcher.pixelWidth,
              captured.image.height == stitcher.viewHeight else {
            return nil
        }

        let startedAt = clock.now()
        do {
            let shift = try await registrar.register(previous: previous, current: captured.image)
            progress.lastRegistrationMilliseconds = (clock.now() - startedAt) * 1000
            return shift
        } catch {
            return nil
        }
    }

    // MARK: - 收场

    /// 结束并输出：拼长图 → 剪贴板 →（可选）落盘。
    public func finish(save: CaptureSaveRequest? = nil) async -> CaptureOutcome {
        guard progress.phase != .cancelled else {
            return .failed(CaptureFailure(message: L10n.t("长截图已取消")))
        }
        guard let stitcher, let output, !frames.isEmpty else {
            return .failed(CaptureFailure(message: L10n.t("长截图没有采到任何画面")))
        }

        let stitchStartedAt = clock.now()
        // ⚠️ `plan` 只算一次，**渲染与段数用同一份**：分两次算的话，
        // "说了 5 段、而拼出来的是 4 段"这种不一致不会有任何东西发现。
        let plan = stitcher.plan
        guard let composed = ScrollStitchRenderer.render(plan: plan, frames: frames) else {
            return .failed(CaptureFailure(message: L10n.t("拼接长图失败")))
        }
        progress.stitchMilliseconds = (clock.now() - stitchStartedAt) * 1000
        progress.phase = .finished
        progress.canvasHeight = composed.height

        // 段数 = 真落进长图的**片数**（`slices.count`），不是采集帧数。
        // ⚠️ 当前实现里两者恒等（停住的帧不进 `frames`，入图的帧各贡献一段）——
        // 取"片数"是因为它描述的是**这张长图由什么构成**；那条等值关系由测试显式钉住。
        return output.finish(composed,
                             startedAt: startedAt,
                             save: save,
                             stitchedSegments: plan.slices.count)
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
            let tail = frames.count >= 2 ? L10n.t("，已拼好的部分保留可用，按 ⏎ 结束") : ""
            progress.phase = .stalled(message + tail)
            progress.warning = message + tail
        } else {
            progress.warning = message
        }
        return progress
    }

    private func stall(_ message: String) -> Progress {
        let text = message + L10n.t("，已停止拼接；按 ⏎ 结束可保留已拼好的部分")
        progress.phase = .stalled(text)
        progress.warning = text
        return progress
    }
}

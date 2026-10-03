import AppKit
import MarqueeCore
import os

/// 逐屏覆盖层的调度者（ticket 03 选区、ticket 04 窗口识别）。
///
/// 职责边界：
/// - 窗口与事件：本类（无法自动化测试）
/// - 状态迁移：`MarqueeCore.SelectionSession`（纯逻辑，有单测）
/// - 窗口命中：`MarqueeCore.WindowCatalog`（纯逻辑，有单测）
/// - 采集：`RegionCaptureFlow` / `FullScreenCaptureFlow` / `WindowCaptureFlow`
///
/// 因此这里只做三件事：把事件喂给状态机、把状态机的输出画出来、提交时调流程。
@MainActor
public final class SelectionOverlayController {

    /// 覆盖层出现的意图。**决定拖出区域之后做什么**，而不是加一个额外的模式弹窗
    /// （PRD 3.1 要求"模式弹窗 0 个"）。
    public enum Mode: Sendable {
        /// 一次成像：拖选区 / 点窗口 / 整屏，停住后 `⏎` 采集（ticket 03/04）
        case singleShot
        /// 长截图：拖出区域或点窗口后**直接开始连续抓帧**，用户自己滚（ticket 11）
        case scrollCapture
    }

    /// 采集成功之后**还要做什么**。
    ///
    /// 做成选项集而不是几个 `Bool`：调用点有六七处，而 `openEditor: false, pin: false`
    /// 这种字面量在所有地方长得一模一样 —— 加第三个标志时没人看得懂哪个 `false` 是什么。
    /// 选项集写出来是 `.pin` / `.openEditor` / `[]`，一眼看得出这一处想干什么。
    public struct AfterCapture: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// 把图送进**编辑器窗口**。只有长截图用它 —— 长图放不进一屏，
        /// 在覆盖层里既看不到全貌也没法标注（ticket 23 的结论）。
        public static let openEditor = AfterCapture(rawValue: 1 << 0)
        /// 把图**钉在屏幕上**（ticket 14）。
        public static let pin = AfterCapture(rawValue: 1 << 1)
    }

    public enum Outcome: Sendable {
        /// - Parameters:
        ///   - after: 采集完成后还要做什么（见 `AfterCapture`）。普通截图是 `[]` ——
        ///     这正是用户要的"不阻断"：拖完选区按 `⏎` 直接出图，不弹任何窗口。
        ///   - anchor: 原始选区（**Cocoa 全局点**）。钉图用它"**钉在原位**" ——
        ///     用户刚才盯着哪儿，图就出现在哪儿。整屏截图时为 `nil`。
        case completed(CaptureOutcome, after: AfterCapture, anchor: CGRect?)
        case cancelled
    }

    private let regionFlow: RegionCaptureFlow
    private let fullScreenFlow: FullScreenCaptureFlow
    private let windowFlow: WindowCaptureFlow
    private let windowLister: WindowListing
    private let displays: DisplayLocating
    private let onFinish: (Outcome) -> Void
    /// `⌘S` 时由宿主拼好落盘请求。`nil` 时 `⌘S` 只复制，不写磁盘。
    private let makeSaveRequest: (@MainActor (WindowInfo?) -> CaptureSaveRequest)?
    /// 长截图会话工厂。`nil` 时 `Mode.scrollCapture` 不可用。
    private let makeScrollSession: (@MainActor () -> ScrollCaptureSession)?
    /// 合成滚轮事件的"手"（ticket 12 自动滚动）。`nil` 时自动滚动不可用，手动滚动不受影响。
    private let makeScrollWheelEmitter: (@MainActor () -> ScrollWheelEmitting)?
    /// "往别的应用注入事件"的授权探针（系统设置里的**辅助功能**）。
    /// 自动滚动是唯一需要它的功能，所以它只用于**按需**申请。
    private let postEventPermission: PostEventPermissionProbing?
    /// 当前进程是不是跑在沙盒里（ticket 32）。
    ///
    /// **默认从运行期探测，宿主不需要接线** —— 漏接的后果是"App Store 版去申请一个
    /// 勾了也没用的权限"，而那正是这条判据要防的事（判据本体在 Core 的 `AutoScrollGate`）。
    /// 声明成 `var` 只为让测试能把它钉住。
    var isSandboxed = AppIdentity().isSandboxed
    /// 放大镜取色用的整屏像素来源（ticket 10）。`nil` 时整个放大镜不出现。
    private let lensProvider: LensFrameProviding?

    /// 文字识别（ticket 23）。与编辑器**共用同一个识别器实例** ——
    /// 预热只热一份模型，两个入口各建一个的话，第二次用还得重新付那 25 秒。
    private let textRecognition: TextRecognitionService?
    /// 复制色值用的剪贴板。`nil` 时 `⌥` 点击不复制。
    private let clipboard: ClipboardWriting?

    private var mode: Mode = .singleShot
    private var session = SelectionSession()
    private var overlays: [(panel: SelectionOverlayPanel, view: SelectionOverlayView)] = []
    private var displayGeometries: [DisplayGeometry] = []
    /// Cocoa ↔ Quartz 的翻转枢轴（主屏高度）
    private var primaryScreenHeight: CGFloat = 0
    /// 一旦开始提交/取消，就忽略后续事件（防止连点触发两次采集）
    private var isFinishing = false
    /// 覆盖层期间缓存的窗口清单。悬停只做命中测试，不每次去问 SCK。
    private var cachedWindows: [WindowInfo] = []
    private var hoveredWindow: WindowInfo?
    /// 鼠标此刻压在哪一格工具条上（`nil` = 不在任何格子上）。悬停态的真相在这里。
    ///
    /// 它是**从全局点算出来的**（`OverlayToolbar.slot(at:in:)`），不是视图自己推的：
    /// 绘制与命中必须同源，否则会出现"高亮在这儿、可点的是旁边那格"。
    private var hoveredSlot: OverlayToolbarSlot?
    private var isOptionDown = false
    private let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    /// 按下位置。用来区分「单击窗口」和「拖选区」，避免已落点后再点一下把选区清掉。
    private var pointerDownAt: CGPoint?
    private var dragExceededSlop = false
    private static let dragSlop: CGFloat = 4
    /// 一次 `Esc` 退出。不靠各块屏的面板各自消化，否则多屏要点好几次。
    private var keyMonitor: Any?

    // subsystem 从 `AppIdentity` 取，不写死 —— 但它是**固定的正式 id**，
    // 于是开发版与正式版的日志用同一条 grep 都能捞到（见 `AppIdentity.logSubsystem`）。
    private let logger = Logger(subsystem: AppIdentity().logSubsystem, category: "overlay")
    /// 前台应用变化（⌘Tab / 点了别的应用）→ 重取窗口清单
    private var activationObserver: NSObjectProtocol?

    // 长截图（ticket 11）
    private var scrollSession: ScrollCaptureSession?
    private var scrollDriver: Task<Void, Never>?
    private var scrollProgress: ScrollCaptureSession.Progress?
    private var scrollRect: CGRect?

    // 自动滚动（ticket 12）
    /// `nil` = 当前没有在自动滚动（手动模式）
    private var autoScrollDriver: AutoScrollDriver?
    private var autoScrollLoop: Task<Void, Never>?
    /// 自动滚动的一句话状态（等停稳 / 正在抓帧 / 为什么停了）
    private var autoScrollMessage: String?

    // 就地标注（ticket 21）
    /// 标注状态机（工具、落笔、撤销栈）。坐标在**选区局部点**里，见它的文档。
    private var annotationSession = OverlayAnnotationSession()

    /// 工具条上展开的弹层（色板/尺寸 或 表情）。`nil` = 没展开。
    ///
    /// 它是**会话状态**（跟工具、跟选区走），不是瞬时标志位 ——
    /// 这一点很要紧：瞬时标志位一旦决定常驻 UI 的可见性，某条分支漏了收尾
    /// 就会让那个东西**再也不出现**（PITFALLS 66）。
    private var palette: OverlayPalette?

    // MARK: - 宿主接缝（ticket 31：升级卡片）

    /// 「现在的权益判定是什么」—— 由宿主注入（App 层读 `ProEntitlement`）。
    ///
    /// 覆盖层**自己不持有权益状态**。持有一份就会出现"购买之后设置页解锁了、
    /// 这个窗口还锁着"这类问题；每次要用时问一次，答案永远和宿主一致。
    ///
    /// `nil` = 宿主没接（命令行工具、单测、`-marqueeDemoEditor`）⇒ **一律放行**。
    /// 这个默认值是刻意的：**没接线时锁死功能，比不锁糟得多** ——
    /// 那会让所有工具与测试都跑不起来，而"少收一次"没人会投诉。
    public var proEntitlement: (@MainActor () -> EntitlementSnapshot)?

    /// 商店的价格文案（宿主注入）。**同步读** —— 宿主在启动时取一次并缓存，
    /// 于是卡片画的时候不需要等一次网络往返（"卡片先出来、价格后到"那种闪烁更糟）。
    public var proPriceText: (@MainActor () -> String?)?

    /// 卡片上某个动作被点了。宿主负责真的去买 / 去恢复 / 去开试用。
    public var onProCardAction: (@MainActor (ProCardAction) -> Void)?

    /// 升级卡片（`nil` = 没弹）。
    ///
    /// 与 `palette` 同理，它是**会话状态**而不是瞬时标志位：瞬时标志位一旦
    /// 决定常驻 UI 的可见性，某条分支漏了收尾就会让那个东西**再也不出现**（PITFALLS 66）。
    ///
    /// 它**不碰 `session`（选区）、也不碰 `annotationSession`（标注）** ——
    /// 这正是"关掉卡片不许丢任何东西"那条产品规则的落点：用户关掉之后，
    /// 框好的选区、画好的标注都还在，他可以用免费能力把这次截图做完。
    private var proCard: ProCardContent?

    /// 表情面板里当前选中的那一枚（下标）。
    private var selectedEmojiIndex = 0

    // MARK: - 拖拽性能探针（现场开关）

    /// `defaults write dev.tango.Marquee overlay.traceFrames -bool YES`
    ///
    /// "有点卡"这种反馈**没法靠猜定位**：可能是覆盖层重绘、可能是窗口枚举、
    /// 也可能是玻璃材质的实时采样。所以先给一个能出数字的口子 ——
    /// 拖一次，日志里就有帧数、平均帧间隔与最大间隔。
    private static let tracesFrames = UserDefaults.standard.bool(forKey: "overlay.traceFrames")

    private var frameCount = 0
    private var frameStartedAt: CFTimeInterval = 0
    private var frameLastAt: CFTimeInterval = 0
    private var frameMaxGap: CFTimeInterval = 0
    private var isTracingFrames = false

    private func beginFrameTrace() {
        guard Self.tracesFrames else { return }
        isTracingFrames = true
        frameCount = 0
        frameMaxGap = 0
        frameStartedAt = CACurrentMediaTime()
        frameLastAt = frameStartedAt
    }

    private func noteFrame() {
        guard isTracingFrames else { return }
        let now = CACurrentMediaTime()
        frameCount += 1
        frameMaxGap = max(frameMaxGap, now - frameLastAt)
        frameLastAt = now
    }

    private func endFrameTrace(_ label: String) {
        guard isTracingFrames else { return }
        isTracingFrames = false
        let total = CACurrentMediaTime() - frameStartedAt
        let average = frameCount > 0 ? total / Double(frameCount) * 1000 : 0
        logger.info("""
        拖拽性能[\(label, privacy: .public)]：\(self.frameCount, privacy: .public) 帧 /         \(total * 1000, privacy: .public) ms，平均 \(average, privacy: .public) ms/帧，        最大间隔 \(self.frameMaxGap * 1000, privacy: .public) ms
        """)
    }

    // 选区几何编辑（ticket 19）
    /// 鼠标正按着的那一次拖拽**是哪一种**。
    ///
    /// 收成一个枚举而不是几个布尔量：`isDrawingStroke` / `isMovingRect` / `isResizing`
    /// 这种写法迟早出现两个同时为真的状态，而那种 bug 的表现是
    /// "拖着拖着变成了另一件事"，且只在特定顺序下复现。
    private enum DragMode: Equatable {
        case none
        /// 重画选区
        case select
        /// 移动整框（尺寸不变）。带着按下时那一版矩形当基准。
        case move(anchor: CGRect)
        /// 拖控制点改大小。基准同样是按下时那一版矩形 ——
        /// 每帧都以上一帧为基准的话，误差会累积，而且 `⇧` 锁比例会越锁越歪。
        case resize(handle: SelectionGeometry.Handle, anchor: CGRect)
        /// 画一笔标注
        case stroke
        /// 拖选中标注的控制点改大小（ticket 22 收尾）
        case annotationResize

        /// 日志用。不带它的话，"状态没收尾"那条 warning 只能说"非空"，
        /// 而想知道是哪一类拖拽漏了收尾还得回去读代码。
        // L10N-EXEMPT-START: 手势档位名，写进日志用来自证「是哪一类拖拽」，不是给用户读的
        var label: String {
            switch self {
            case .none: "none"
            case .select: "select(重画选区)"
            case .move: "move(移动整框)"
            case .resize: "resize(改大小)"
            case .stroke: "stroke(画一笔)"
            case .annotationResize: "annotationResize(缩标注)"
            }
        }
        // L10N-EXEMPT-END
    }
    private var dragMode: DragMode = .none
    /// 一次泄漏只报一条日志（探针挂在 `refresh` 上，不拦着会刷屏）。
    private var hasWarnedAboutDragLeak = false
    /// 拖拽中鼠标最后的位置。存它是因为"按 `⇧` 的那一刻"没有鼠标事件 ——
    /// 不存就只能等下次移动才看到变化，而用户明明按了键却没反应会以为没生效。
    private var lastDragPoint: CGPoint?
    /// 吸附命中的提示线（Cocoa 全局坐标）。`nil` = 这个方向没吸上。
    private var snapGuide: (vertical: CGFloat?, horizontal: CGFloat?) = (nil, nil)

    // 文字输入（ticket 22）
    /// 正在显示输入框的那块屏的视图。`nil` = 没在输入。
    ///
    /// 为什么记"视图"而不是一个布尔量：多屏时输入框只挂在**点到的那块屏**上，
    /// 而结束输入时要去收掉**那一个**。记布尔量就只能靠"遍历所有屏挨个收"，
    /// 那会在别的屏上误伤（比如同时打开两处输入）。
    private weak var textEditingView: SelectionOverlayView?

    // 文字识别（ticket 23）
    /// 识别的一句话状态（识别中 / 结果 / 为什么没成）。挂在读数框的第三行。
    private var ocrStatus: String?
    private var ocrStatusTask: Task<Void, Never>?

    /// 宿主推进来的**一句回执**（"刚才那一下"的结果），与 OCR 状态同一个套路。
    private var transientNotice: ReadoutLine?
    private var transientNoticeTask: Task<Void, Never>?

    // 打码预览（ticket 22）
    /// 从**冻结的整屏帧**拼出来的选区底图。只有选中马赛克/模糊时才准备。
    ///
    /// 它是"预览用的底图"，与导出时真实采集到的那张是**同一套布局规则**
    /// （`OverlayRedactionSource` 复用 `SelectionLayout` + `ImageCompositing`），
    /// 所以预览里看到的打码位置与大小就是导出图里的。
    private var redactionBackdrop: (image: CGImage, scale: CGFloat)?

    // 放大镜取色（ticket 10）
    /// 每块屏一份冻结的整屏像素，按需取、取到就留着（放大镜跟随光标时不再采集）
    private var lensFrames: [UInt32: LensFrame] = [:]
    private var lensRequestsInFlight: Set<UInt32> = []
    /// 当前算好的放大镜内容。`nil` = 不显示。
    private var magnifier: MagnifierPresentation?
    /// 放大的小图缓存。取样像素没变时复用，避免每次鼠标移动都裁剪 + 放大一次。
    private var lastLensImage: CGImage?
    /// 「光标在这一格上吗」的判定（什么才算真的变了）。纯逻辑，在 Core 里单测。
    private var magnifierTracker = MagnifierTracker()
    /// 当前取样像素的颜色
    private var sampledColor: PixelColor?
    /// 复制反馈文本（1.5 秒后自动清掉）
    private var magnifierStatus: String?
    /// 放大镜尺寸。ticket 15 会把它接到偏好设置上。
    public var lensSettings: MagnifierLayout.Settings = .default

    /// 窗口截图带不带阴影的**默认值**（来自「设置 → 截屏」，ticket 15）。
    ///
    /// 覆盖层里按 `⌥` 是"临时反过来"（PRD F4），所以两者是**相乘**的关系：
    /// `⌥` 按下时取反，松开时回到这个默认值。
    public var windowShadowDefault = true
    /// 复制色值用的格式。ticket 15 会把它接到偏好设置上。
    public var copyFormat: PixelColor.Format = .hex
    private var magnifierStatusTask: Task<Void, Never>?

    public init(regionFlow: RegionCaptureFlow,
                fullScreenFlow: FullScreenCaptureFlow,
                windowFlow: WindowCaptureFlow,
                windowLister: WindowListing,
                displays: DisplayLocating,
                onFinish: @escaping (Outcome) -> Void,
                makeSaveRequest: (@MainActor (WindowInfo?) -> CaptureSaveRequest)? = nil,
                makeScrollSession: (@MainActor () -> ScrollCaptureSession)? = nil,
                makeScrollWheelEmitter: (@MainActor () -> ScrollWheelEmitting)? = nil,
                postEventPermission: PostEventPermissionProbing? = nil,
                lensProvider: LensFrameProviding? = nil,
                textRecognizer: TextRecognizing? = nil,
                clipboard: ClipboardWriting? = nil) {
        self.regionFlow = regionFlow
        self.fullScreenFlow = fullScreenFlow
        self.windowFlow = windowFlow
        self.windowLister = windowLister
        self.displays = displays
        self.onFinish = onFinish
        self.makeSaveRequest = makeSaveRequest
        self.makeScrollSession = makeScrollSession
        self.makeScrollWheelEmitter = makeScrollWheelEmitter
        self.postEventPermission = postEventPermission
        self.lensProvider = lensProvider
        self.textRecognition = textRecognizer.map { TextRecognitionService(recognizer: $0) }
        self.clipboard = clipboard
    }

    public var isPresented: Bool { !overlays.isEmpty }

    /// 长截图正在连续抓帧
    public var isScrollCapturing: Bool { scrollSession != nil && scrollProgress != nil }

    /// 长截图会话已建立（**可能还在起步中**）。
    ///
    /// 用它当"别再来一次"的闸门，而不是 `isScrollCapturing`：
    /// 后者要等 `session.begin()` 返回才为真，而 `begin` 里要走权限门 + 抓一帧基线
    /// （实测几十到上百毫秒）。这段窗口里连按 `⏎` 会再建一个会话，
    /// 前一个就变成没人管的孤儿 —— 它的抓帧循环照跑，还多占一份采集。
    private var hasScrollSession: Bool { scrollSession != nil }

    // MARK: - 呈现 / 收场

    public func present(mode: Mode = .singleShot) {
        guard !isPresented else { return }

        self.mode = mode
        isFinishing = false
        session = SelectionSession()
        pointerDownAt = nil
        dragExceededSlop = false
        hoveredWindow = nil
        // 悬停态**每次开场都从"没有"开始**：上一次会话结束时鼠标停在哪一格，
        // 与这一次没有任何关系；而工具条的矩形也可能完全不同。
        hoveredSlot = nil
        isOptionDown = false
        textEditingView = nil
        resetScroll()
        resetMagnifier()
        displayGeometries = displays.allDisplays()

        guard !displayGeometries.isEmpty,
              let height = ScreenCoordinateConversion.primaryScreenHeight(in: displayGeometries) else {
            onFinish(.completed(.failed(CaptureFailure(message: L10n.t("没找到可用的显示器"))),
                                after: [], anchor: nil))
            return
        }
        primaryScreenHeight = height

        let pointer = NSEvent.mouseLocation // Cocoa 全局坐标
        var keyOverlayIndex = 0

        for (index, screen) in NSScreen.screens.enumerated() {
            let panel = SelectionOverlayPanel(contentRect: screen.frame,
                                              styleMask: [.borderless, .nonactivatingPanel],
                                              backing: .buffered,
                                              defer: false)
            let view = SelectionOverlayView()
            view.delegate = self
            // 走 `handleEscape()` 而不是 `cancel()`：面板自己的 `performKeyEquivalent`
            // 也能收到 `Esc`，而这条路上原来直连 `cancel()` —— 于是"正在输入文字时按 Esc"
            // 从这条路进来会把**整次截图**丢掉（从本地监听那条路进来却只是退出输入）。
            // 同一个键在两条路上做两件事，就是这类 bug 的温床。
            panel.onCancel = { [weak self] in self?.handleEscape() }
            panel.contentView = view

            overlays.append((panel, view))
            if screen.frame.contains(pointer) { keyOverlayIndex = index }
        }

        refresh()
        for overlay in overlays {
            overlay.panel.orderFront(nil)
        }
        // 只有指针所在那块屏的面板拿键盘焦点；其它屏只是显示
        let keyOverlay = overlays[keyOverlayIndex]
        keyOverlay.panel.makeKeyAndOrderFront(nil)
        keyOverlay.panel.makeFirstResponder(keyOverlay.view)
        installKeyMonitor()
        installActivationObserver()

        // ── 探针：覆盖层到底有没有拿到键盘焦点 ──────────────────────────
        //
        // 这件事**决定了覆盖层里能不能放输入框**（文字工具的前提）。
        // 面板是 `.nonactivatingPanel` + `canBecomeKey = true` + `becomesKeyOnlyIfNeeded = false`，
        // 按文档它应当能成为 key；但本项目有一条反证：**视图的 `keyDown` 曾经完全收不到 `⏎`**
        // （PITFALLS 56，最后是靠应用级本地监听绕过去的）。
        // 两者对不上，所以这里不猜 —— 记一条实测数据，下次排障直接看日志。
        //
        // 延迟一点点再查：`makeKeyAndOrderFront` 之后窗口系统需要一个回合才认账。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isPresented else { return }
            let anyKey = self.overlays.contains { $0.panel.isKeyWindow }
            let focused = self.overlays.contains { $0.panel.firstResponder === $0.view }
            self.logger.info("""
            覆盖层焦点：panel.isKeyWindow=\(anyKey, privacy: .public) \
            firstResponder=\(focused, privacy: .public) \
            app.isActive=\(NSApp.isActive, privacy: .public)（输入框需要 isKeyWindow=true）
            """)
        }

        // 清单与覆盖层并行：没有清单时仍可拖选区，不能串行等 SCK
        let pointerAtPresent = pointer
        Task { [weak self] in
            guard let self, !self.isFinishing else { return }
            self.cachedWindows = await self.windowLister.listWindows()
            self.updateHover(at: pointerAtPresent)
        }

        // 放大镜的整屏像素同样并行取。先踢一脚，用户不动鼠标也能看到放大镜。
        updateMagnifier(at: pointerAtPresent)
    }

    private func teardown() {
        for overlay in overlays {
            overlay.panel.onCancel = nil
            overlay.panel.ignoresMouseEvents = false
            overlay.view.delegate = nil
            overlay.panel.orderOut(nil)
        }
        overlays.removeAll()
        cachedWindows = []
        hoveredWindow = nil
        pointerDownAt = nil
        dragExceededSlop = false
        removeKeyMonitor()
        removeActivationObserver()
        resetScroll()
        resetMagnifier()
        // 标注也是每次会话的：**下一次唤起覆盖层必须从空白开始**。
        // 漏掉这一句的话，第二次截图的选区下方会挂着上一张图的箭头 ——
        // 而它们是"对的坐标、错的上下文"，看着像截图工具自己在图上乱画。
        annotationSession.removeAll()
        annotationSession.clearTool()
        textEditingView = nil
        dragMode = .none
        lastDragPoint = nil
        snapGuide = (nil, nil)
        redactionBackdrop = nil
        ocrStatusTask?.cancel()
        ocrStatusTask = nil
        ocrStatus = nil
        textRecognition?.reset()
        NSCursor.arrow.set()
    }

    private func resetScroll() {
        scrollDriver?.cancel()
        scrollDriver = nil
        autoScrollLoop?.cancel()
        autoScrollLoop = nil
        autoScrollDriver = nil
        autoScrollMessage = nil
        scrollSession = nil
        scrollProgress = nil
        scrollRect = nil
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 只回传"消费了没有"：`NSEvent` 不是 `Sendable`，跨隔离域回传它编译不过。
            let consumed = MainActor.assumeIsolated { self.handleOverlayKeyDown(event) }
            return consumed ? nil : event
        }
    }

    /// 覆盖层的**唯一**键盘入口。
    ///
    /// ## 为什么全部功能键都走这里，而不是交给视图的 `keyDown`
    ///
    /// 面板是 `.nonactivatingPanel`（刻意不激活本应用，免得把用户从当前应用拽走），
    /// 而"视图的 `keyDown` 能收到按键"依赖**面板是 key window 且视图是 first responder**。
    /// 这条链路在真实使用里并不可靠 —— 实测（2026-10-01，用户跑出来的日志）：
    /// `Esc` 生效（它走的就是这个本地监听），而 **`⏎` 杳无音讯**（它走视图 `keyDown`）。
    /// 用户看到的现象是"拖完选区按 `⏎` 什么都没发生"，然后按 `Esc` 退出 ——
    /// 还以为截图坏了。这正是 `STATUS-AND-ACCEPTANCE.md` 里标为"最没把握"的 B1。
    ///
    /// 本地监听是**应用级**的、与"哪个窗口是 key"无关。既然 `Esc` 已经证明它能稳定收到事件，
    /// 功能键就都放这里 —— 一条路走通，就不要留第二条只在特定前提下成立的路。
    ///
    /// - Returns: 是否已消费（`true` = 不再向下分发）
    private func handleOverlayKeyDown(_ event: NSEvent) -> Bool {
        guard !isFinishing else { return true }

        // 正在输入文字 → **整条让行**。
        //
        // 本地监听在事件到达窗口**之前**就跑，所以不让行的话，用户敲的每个字
        // 都会被当成快捷键吞掉 —— 表现得像"输入框是坏的"，而其实是这里吃掉了。
        // 唯一要拦的是 `Esc`（退出输入）；其余（含 `⏎`、`⌘Z`、输入法用来选词的上下键）
        // 全部放回给输入框自己处理。
        if annotationSession.isEditingText {
            if event.keyCode == 0x35 {   // Esc
                cancelTextEditing()
                return true
            }
            return false
        }

        switch Int(event.keyCode) {
        case 0x35: // Esc
            handleEscape()
            return true
        case 0x24, 0x4C: // ⏎ / 小键盘 Enter
            logger.info("覆盖层按键：⏎ 提交")
            performCommit(saveToDisk: false)
            return true
        case 0x01 where event.modifierFlags.contains(.command): // ⌘S
            logger.info("覆盖层按键：⌘S 提交并落盘")
            performCommit(saveToDisk: true)
            return true
        case 0x31: // 空格：长截图里开始 / 停止自动滚动
            logger.info("覆盖层按键：空格")
            toggleAutoScroll()
            return true
        case 0x33, 0x75: // Delete（退格）/ 前进删除
            if annotationSession.deleteSelected() {
                logger.info("删除选中的标注，剩 \(self.annotationSession.annotations.count) 个")
            }
            refresh()
            return true

        case 0x06 where event.modifierFlags.contains(.command): // ⌘Z / ⇧⌘Z
            let isRedo = event.modifierFlags.contains(.shift)
            let changed = isRedo ? annotationSession.redo() : annotationSession.undo()
            if changed {
                let action = isRedo ? L10n.t("重做") : L10n.t("撤销")
                logger.info("快捷键：\(action, privacy: .public)")
            }
            refresh()
            return true

        case 0x7B: // ←
            nudge(dx: -1, dy: 0)
            return true
        case 0x7C: // →
            nudge(dx: 1, dy: 0)
            return true
        case 0x7D: // ↓ —— Cocoa 视图坐标 y 向上，"下"是 -1
            nudge(dx: 0, dy: -1)
            return true
        case 0x7E: // ↑
            nudge(dx: 0, dy: 1)
            return true
        default:
            break
        }

        // 带 ⌘ / ⌃ 的组合放行给系统：⌘Tab、⌘`、⌘Space 这类是系统快捷键，
        // 覆盖层既不该吞掉它们，也没理由为它们哔一声
        //（用户按 ⌘Tab 想换目标应用，结果是"叮"一下什么都不发生，那才是最费解的表现）。
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            return false
        }
        return true
    }

    /// `Esc` 的**唯一入口**。
    ///
    /// 覆盖层有两条能收到 `Esc` 的路：面板自己的 `keyDown`，以及这个本地监听
    /// （用它是为了"一次 `Esc` 退出",不必每块屏各消化一次）。
    /// 两处各写一份判断，就一定会出现"从另一条路进来时漏掉了自动滚动分支"这种事。
    private func handleEscape() {
        // ① 正在输入文字 → 结束输入（丢掉这半截）
        if annotationSession.isEditingText {
            cancelTextEditing()
            return
        }
        // 自动滚动中按 `Esc` = 只停自动滚动，画面与已拼好的部分都留着。
        if autoScrollDriver != nil {
            stopAutoScroll()
            return
        }
        // 标注分**四级**退，**不会一步把整次截图丢掉**：
        //   ⓪ 弹层 / 升级卡片开着 → 只收那一层
        //   ① 拖到一半 / 画到一半 → 只结束这一次拖拽
        //   ② 选了工具   → 取消工具（回到"调整选区"）
        //   ③ 其它       → 取消整次截图
        // 少了前面几级的话，用户画了五个箭头想退出画标注模式，
        // 一下 `Esc` 全部作废，而这张图可能已经很难再复现。
        //
        // ⓪ 必须排在最前：面板是最浅的一层，"关掉刚打开的那东西"是所有人的第一直觉。
        //
        // 卡片排在弹层**之前** —— 两者不会同时出现，而卡片总是更晚弹出来的那个，
        // "关掉最新的那层"才符合直觉。
        // 收卡片只置 `proCard = nil`：**选区与标注一个字都不动**，
        // 关掉之后用户能接着把这次截图做完（产品的硬规则，见 MAS-AND-MONETIZATION §1）。
        if proCard != nil {
            // 与"点卡片外面"走**同一个收尾**（`dismissProCard`）——
            // 两条路各写一遍的话，迟早会有一边顺手清掉别的东西。
            dismissProCard()
            return
        }
        if palette != nil {
            palette = nil
            refresh()
            return
        }
        if case .annotationResize = dragMode {
            // 缩放到一半按 Esc = 退回按下时那一版（与拖选区几何一致）
            dragMode = .none
            annotationSession.cancelResize()
            refresh()
            return
        }
        if case .move(let anchor) = dragMode {
            // 移动/缩放拖到一半按 Esc = 退回按下时那一版几何（与系统截图工具一致）
            dragMode = .none
            snapGuide = (nil, nil)
            session.settle(rect: anchor)
            refresh()
            return
        }
        if case .resize(_, let anchor) = dragMode {
            dragMode = .none
            snapGuide = (nil, nil)
            session.settle(rect: anchor)
            refresh()
            return
        }
        if dragMode == .stroke || annotationSession.draft != nil {
            dragMode = .none
            annotationSession.cancelStroke()
            refresh()
            return
        }
        // 任何工具都先退出工具（回到"调整选区"）—— 少了这一档，
        // 选了「选择」再按 Esc 会**直接取消整次截图**，而用户只是想退出选择模式。
        if annotationSession.tool != nil {
            annotationSession.clearTool()
            refresh()
            return
        }
        cancel()
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - 前台应用变化

    /// ⌘Tab / 点别的应用之后，**窗口的前后顺序变了**，缓存的清单就过期了。
    ///
    /// 不刷新的话症状很隐蔽：悬停仍然按**旧顺序**做命中 ——
    /// 高亮会落到一个跟当前屏幕前后关系不符的窗口上；而且 `updateHover` 只在鼠标
    /// 移动时被调用，所以不动鼠标的话连高亮都停在旧窗口上。
    ///
    /// 注意**不动落点**：用户已经单击锁定某扇窗，那是明确的意图，
    /// 不该因为切了个应用就被清掉（`captureWindow` 走 `desktopIndependentWindow`，
    /// 被挡住也照样截得到那一扇窗）。
    private func installActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWindowsAfterActivationChange()
            }
        }
    }

    private func removeActivationObserver() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func refreshWindowsAfterActivationChange() {
        guard !isFinishing, isPresented else { return }
        let pointer = NSEvent.mouseLocation
        Task { [weak self] in
            guard let self, !self.isFinishing, self.isPresented else { return }
            self.cachedWindows = await self.windowLister.listWindows()
            // 强制重算一次：不重置的话，若前后命中的是同一扇窗就会走 early-return，
            // 而它现在的遮挡关系可能已经变了。相位判定交给 `updateHover` 自己。
            self.hoveredWindow = nil
            self.updateHover(at: pointer)
        }
    }

    // MARK: - 放大镜取色（ticket 10）

    /// 光标移动时重算放大镜。
    ///
    /// 按需取一屏像素（取到就缓存），之后所有取样都是**纯内存计算**：
    /// 裁一块方形 → 最近邻放大 → 读中心像素颜色。
    /// 不这么做就只能每次移动都去采集，而那是几十毫秒量级 —— 跟手是不可能的。
    ///
    /// ⚠️ **本方法自己负责把结果推给视图**（`pushMagnifier`），不依赖调用方。
    /// 早先的写法是只改 `magnifier`、指望调用方随后调 `refresh()`，而空闲移动走的是
    /// `updateHover` —— 那里在"悬停窗口没变"时直接 `return`，于是鼠标在同一个窗口内
    /// 移动、以及**落点之后**移动时，放大镜会停在原地不动。
    private func updateMagnifier(at cocoaPoint: CGPoint) {
        // 落点之后 / 长截图抓帧期间不显示放大镜，也就不必维护它（见 `showsMagnifier`）
        guard session.showsMagnifier, !hasScrollSession else {
            clearMagnifier()
            return
        }
        guard let lensProvider, primaryScreenHeight > 0 else {
            clearMagnifier()
            return
        }

        let quartz = ScreenCoordinateConversion.quartzPoint(fromCocoa: cocoaPoint,
                                                            primaryScreenHeight: primaryScreenHeight)
        guard let display = displayGeometries.first(where: { $0.frame.contains(quartz) }) else {
            clearMagnifier()
            return
        }

        requestLensFrameIfNeeded(for: display, using: lensProvider)
        guard let lens = lensFrames[display.displayID] else {
            // 这一屏的像素还没取回来：先不显示，取到后会自动补上
            clearMagnifier()
            return
        }

        let settings = lensSettings
        let scale = Double(display.backingScale)
        let side = max(1, Int((settings.samplePoints * scale).rounded()))
        let zoom = max(1, settings.zoom)
        // 盒子边长由**实际采样边长**推出来（不是 `samplePoints × zoom`）：
        // 少这一步，放大图与盒子就差最多半像素，绘制时会多一次亚像素重采样，
        // 表现为"个别格子被拉宽、个别被吃掉一行"。
        let placement = MagnifierLayout.Placement(
            boxSide: MagnifierLayout.boxSide(sampledSide: side, zoom: zoom, backingScale: scale),
            gap: settings.gap,
            backingScale: scale,
            screenBounds: display.frame
        )
        let center = PixelSampling.clampedCenter(
            MagnifierLayout.imagePixel(forCocoa: cocoaPoint,
                                       on: display,
                                       primaryScreenHeight: primaryScreenHeight),
            side: side,
            imageWidth: lens.image.width,
            imageHeight: lens.image.height
        )

        let step = magnifierTracker.update(cursor: cocoaPoint,
                                           center: center,
                                           displayID: display.displayID,
                                           placement: placement)

        switch step {
        case .idle:
            // 取样像素与盒子位置都没变（鼠标在同一格内抖动）—— 不重画
            return

        case .moved(let box):
            // 取样像素没变、只有盒子挪了：复用已放大的小图。
            // 这是鼠标移动时最常见的一档，省掉每帧一次裁剪 + 放大。
            magnifier = makeMagnifier(box: box,
                                      lensImage: lastLensImage,
                                      backingScale: scale)
            pushMagnifier()

        case .resample(let box, let center):
            guard let lensImage = PixelSampling.magnified(lens.image,
                                                         centeredAt: center,
                                                         side: side,
                                                         zoom: Int(zoom),
                                                         interpolation: settings.interpolation),
                  let color = PixelSampling.color(of: lens.image, at: center) else {
                clearMagnifier()
                return
            }
            lastLensImage = lensImage
            sampledColor = color
            magnifier = makeMagnifier(box: box,
                                      lensImage: lensImage,
                                      backingScale: scale)
            pushMagnifier()
        }
    }

    /// 拼出放大镜要画的东西。位置、小图、色值三者独立，所以能分开复用。
    private func makeMagnifier(box: CGRect,
                               lensImage: CGImage?,
                               backingScale: CGFloat) -> MagnifierPresentation {
        MagnifierPresentation(
            lensImage: lensImage,
            boxRect: box,
            // 一个源像素在盒子里占这么大：盒子边长 = 采样边长 × zoom（点），
            // 而一个源像素 = 1 / backingScale 点，再放大 zoom 倍。
            // 盒子边长与放大图是严格 1:1 的（见 `MagnifierLayout.boxSide(sampledSide:…)`）
            sampleMarkerSize: lensSettings.zoom / backingScale,
            colorLines: magnifierLines(),
            statusText: magnifierStatus
        )
    }

    /// 放大镜下方的读数行。
    ///
    /// 色值只在**按住 `⌥` 时**出现（PRD F4：「`⌥` 悬停即在放大镜旁显示 HEX/RGB，一键复制」）：
    /// 不按 `⌥` 时放大镜只负责"对准像素"，多两行数字反而干扰；
    /// 但仍留一句提示 —— 否则这个能力没人会发现。
    ///
    /// 三行的**角色**（而不是颜色）在这里定：颜色只有一个来源
    /// （`ChromePalette.Overlay.Readout`），而"第一行是主角、后两行是副手"
    /// 这条层级由 `ReadoutRole` 表达，`OverlayReadoutTests` 会把它们量一遍。
    private func magnifierLines() -> [ReadoutLine] {
        guard let color = sampledColor else { return [] }
        guard isOptionDown else {
            // 只有一行，而且是"你还能做一件事"的提示 —— 那是副手级。
            return [ReadoutLine(L10n.t("按住 ⌥ 取色"), .secondary)]
        }
        return [ReadoutLine(color.hexString, .primary),
                ReadoutLine(color.rgbString, .secondary),
                ReadoutLine(L10n.t("点击复制"), .secondary)]
    }

    /// 把放大镜的变化推给视图。
    ///
    /// 独立成一步的原因见 `updateMagnifier` 的注释：放大镜的更新发生在**移动事件**里，
    /// 而"把状态推给视图"原本只在 `refresh()` 里做、靠调用方顺手带一下。
    /// 落点之后以及悬停在同一个窗口内，那条路径上没有任何东西会调 `refresh()`。
    private func pushMagnifier() {
        guard !isFinishing, isPresented else { return }
        refresh()
    }

    /// 收起放大镜。**展示状态与跟踪状态必须一起清**。
    ///
    /// 只清 `magnifier` 会留下一个"跟踪器还记得取样点"的中间态：
    /// 光标再回到同一个像素时跟踪器报 `.idle`，放大镜就再也回不来了。
    private func clearMagnifier() {
        let wasVisible = magnifier != nil
        magnifier = nil
        lastLensImage = nil
        magnifierTracker.reset()
        if wasVisible { pushMagnifier() }
    }

    private func requestLensFrameIfNeeded(for display: DisplayGeometry, using provider: LensFrameProviding) {
        guard lensFrames[display.displayID] == nil,
              !lensRequestsInFlight.contains(display.displayID) else { return }
        lensRequestsInFlight.insert(display.displayID)

        Task { [weak self] in
            guard let self else { return }
            let frame = await provider.lensFrame(for: display)
            self.lensRequestsInFlight.remove(display.displayID)
            guard !self.isFinishing, self.isPresented else { return }
            if let frame {
                self.lensFrames[display.displayID] = frame
            }
            // 取到之后立刻按当前光标补一次：用户不该为了看到放大镜而再动一下鼠标
            self.updateMagnifier(at: NSEvent.mouseLocation)
            self.refresh()
        }
    }

    /// `⌥` 点击复制取样像素的色值。
    ///
    /// 生效相位：**落点之前**（悬停或还没开始拖的时候）。PRD F4 的原话是
    /// 「`⌥` 悬停即在放大镜旁显示 HEX/RGB，一键复制」；那个相位里 `⌥` 本来没有别的用途 ——
    /// ticket 04 的「`⌥`＝无阴影」是**落点之后**才生效的。
    ///
    /// **不带 `⌥` 的点击不受影响**：仍然是"选中这扇窗"，所以两个语义不打架。
    /// 落点之后放大镜已收起，取色也随之中止（那时 `⌥` 交给 ticket 04）。
    @discardableResult
    private func copySampledColor() -> Bool {
        guard let color = sampledColor, let clipboard else { return false }
        let text = color.string(in: copyFormat)
        clipboard.writeText(text)

        magnifierStatus = L10n.t("已复制 \(text)")
        rebuildMagnifier()

        magnifierStatusTask?.cancel()
        magnifierStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.magnifierStatus = nil
            self.rebuildMagnifier()
        }
        return true
    }

    /// 重建放大镜（用已有的位置与小图，只重算读数行）。
    ///
    /// 两处需要它，都不是"移动鼠标"：
    /// - `⌥` 按下/松开 → 色值行出现/消失
    /// - 复制反馈的显示与 1.5 秒后的清除
    ///
    /// 只调 `refresh()` 是不够的：`colorLines` 与 `statusText` 都是**烘进** presentation 的，
    /// 推的还是算好的那一份，用户得等到下一次鼠标移动才看得到变化。
    private func rebuildMagnifier() {
        guard let current = magnifier else { return }
        magnifier = MagnifierPresentation(lensImage: current.lensImage,
                                          boxRect: current.boxRect,
                                          sampleMarkerSize: current.sampleMarkerSize,
                                          colorLines: magnifierLines(),
                                          statusText: magnifierStatus)
        pushMagnifier()
    }

    private func resetMagnifier() {
        lensFrames = [:]
        lensRequestsInFlight = []
        magnifier = nil
        lastLensImage = nil
        magnifierTracker.reset()
        sampledColor = nil
        magnifierStatus = nil
        magnifierStatusTask?.cancel()
        magnifierStatusTask = nil
    }

    // MARK: - 长截图（ticket 11）

    /// 拖出区域（或点了窗口）之后立刻开滚。
    ///
    /// 关键一步是**把面板设成鼠标穿透**：滚动截屏要让用户去滚下面的应用，
    /// 而覆盖层面板会吞掉滚轮事件。`ignoresMouseEvents = true` 只影响鼠标，
    /// 键盘仍然回到本面板（`⏎` 结束 / `Esc` 取消照常）。
    private func beginScrollCapture(cocoaRect: CGRect) {
        guard !isFinishing, !hasScrollSession, let makeScrollSession else { return }
        guard cocoaRect.width >= 8, cocoaRect.height >= 8 else { return }

        let session = makeScrollSession()
        self.scrollSession = session
        scrollRect = cocoaRect
        autoScrollMessage = nil
        // 选区状态机也要落点：覆盖层靠它画出被采区域的镂空与描边
        self.session.settle(rect: cocoaRect)
        setPanelsIgnoreMouse(true)
        refresh()

        let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoaRect,
                                                           primaryScreenHeight: primaryScreenHeight)
        let geometries = displayGeometries

        Task { [weak self] in
            guard let self else { return }
            switch await session.begin(selection: quartz, displays: geometries) {
            case .started(let progress):
                self.scrollProgress = progress
                self.refresh()
                self.startScrollDriver(session)

            case .permissionBlocked(let decision, let grantedJustNow):
                // 复用既有的收尾通道：宿主已经会为这两种结果弹正确的说明
                self.teardown()
                self.onFinish(.completed(.permissionBlocked(blockedBy: decision,
                                                           grantedJustNow: grantedJustNow),
                                        after: [], anchor: nil))

            case .failed(let failure):
                self.teardown()
                self.onFinish(.completed(.failed(failure), after: [], anchor: nil))
            }
        }
    }

    /// 按会话给定的节奏反复抓帧。**不在这里做配准或拼接**，那些都归 Core 的会话，
    /// 这里只负责"按节拍敲一下"和把进度画出来。
    ///
    /// 循环退出条件是 `isAcceptingFrames` —— 注意 `atBottom`（"看起来到底了"）
    /// **仍算可接收**，所以这里不会因为误判到底就把抓帧停掉：
    /// 停了之后用户再滚就彻底没反应，长图还会缺后半段。
    private func startScrollDriver(_ session: ScrollCaptureSession) {
        scrollDriver?.cancel()
        let interval = session.settings.frameInterval
        scrollDriver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard let self, !self.isFinishing else { break }
                let progress = await session.captureFrame()
                self.scrollProgress = progress
                self.refresh()
                if !progress.phase.isAcceptingFrames { break }
            }
        }
    }

    /// 结束长截图：把长图交给宿主（剪贴板 + 可选落盘 + 打开编辑器）。
    private func finishScrollCapture(saveToDisk: Bool) {
        guard !isFinishing, let session = scrollSession else { return }
        isFinishing = true
        scrollDriver?.cancel()
        scrollDriver = nil
        autoScrollLoop?.cancel()
        autoScrollLoop = nil
        autoScrollDriver = nil
        let save = saveRequest(for: nil, enabled: saveToDisk)

        Task { [weak self] in
            guard let self else { return }
            let outcome = await session.finish(save: save)
            self.teardown()
            // 长截图**仍然进编辑器**：长图可能几千像素高，放不进一屏 ——
            // 在覆盖层里既看不到全貌也没法滚动，没法在它上面标注（见 ticket 23）。
            self.onFinish(.completed(outcome, after: .openEditor, anchor: nil))
        }
    }

    private func setPanelsIgnoreMouse(_ ignores: Bool) {
        for overlay in overlays {
            overlay.panel.ignoresMouseEvents = ignores
        }
    }

    // MARK: - 自动滚动（ticket 12）

    /// 空格：开始 / 停止自动滚动。只在长截图进行中有效。
    private func toggleAutoScroll() {
        guard !isFinishing, mode == .scrollCapture, hasScrollSession else { return }
        if autoScrollDriver != nil {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    /// 开始自动滚动。
    ///
    /// **权限只在这里申请** —— 用户真的按了空格才问一次。拒绝的话只是退回手动，
    /// 不挡任何已有能力：截图、标注、手动长截图全都不需要辅助功能授权。
    private func startAutoScroll() {
        guard autoScrollDriver == nil,
              let session = scrollSession,
              let makeScrollWheelEmitter,
              let postEventPermission else { return }

        // 判据在 Core（`AutoScrollGate`）：**沙盒**与**授权**是两个互不相干的来源，
        // 而它们要给出完全不同的话 —— 说反了就是把用户送去做一件注定没用的事。
        // 顺序也是判据的一部分，沙盒优先。
        let gate = AutoScrollGate.evaluate(
            isSandboxed: isSandboxed,
            permissionGranted: postEventPermission.currentPostEventPermission() == .granted
        )
        switch gate {
        case .unavailableInSandbox:
            // 沙盒里**连申请都不申请** —— 弹一个"去勾辅助功能"的提示是骗人。
            autoScrollMessage = AutoScrollGate.blockedMessage(for: gate)
            refresh()
            return

        case .needsPermission:
            // 先真的申请一次；申请失败才告诉他去哪儿勾（这是一条能走通的路）。
            if !postEventPermission.requestPostEventPermission() {
                autoScrollMessage = AutoScrollGate.blockedMessage(for: gate)
                refresh()
                return
            }

        case .allowed:
            break
        }

        // 手动抓帧循环必须先停：它按固定节奏抓帧，会和"等画面停稳"的探测互相踩，
        // 结果是把惯性未停的糊帧也拼进去。
        scrollDriver?.cancel()
        scrollDriver = nil

        let driver = AutoScrollDriver(session: session,
                                      emitter: makeScrollWheelEmitter(),
                                      permission: postEventPermission)
        autoScrollDriver = driver
        runAutoScrollLoop(driver)
    }

    /// 停掉自动滚动，**但把会话留着**：用户接着自己滚就能继续拼，按 `⏎` 也能拿到已拼的部分。
    private func stopAutoScroll() {
        autoScrollLoop?.cancel()
        autoScrollLoop = nil
        autoScrollDriver?.stop(.cancelled)
        autoScrollDriver = nil
        autoScrollMessage = nil
        resumeManualScrollIfNeeded()
        refresh()
    }

    /// 循环在**这一层**，判断全在 Core 的驱动器里 —— 那边能脱机单测。
    /// 与手动模式（`startScrollDriver`）是同一种驱动方式，只是节拍更密：
    /// 自动滚动要勤看着点画面停没停，不然每步都要多等好几个 0.35 秒。
    private func runAutoScrollLoop(_ driver: AutoScrollDriver) {
        autoScrollLoop?.cancel()
        let interval = driver.policy.tickInterval
        autoScrollLoop = Task { [weak self] in
            var status = await driver.start()
            while true {
                self?.applyAutoScroll(status)
                if status.isFinished || Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard let self, !self.isFinishing else { break }
                status = await driver.step()
            }
            self?.autoScrollDidFinish(status)
        }
    }

    private func applyAutoScroll(_ status: AutoScrollDriver.Status) {
        scrollProgress = status.capture
        autoScrollMessage = status.message
        refresh()
    }

    private func autoScrollDidFinish(_ status: AutoScrollDriver.Status) {
        autoScrollLoop = nil
        autoScrollDriver = nil
        guard !isFinishing else { return }

        switch status.stage {
        case .finished(.atBottom), .finished(.atLimit), .finished(.tooLong):
            // 滚完了：直接交图。用户按空格要的就是"自己滚完，给我长图"
            finishScrollCapture(saveToDisk: false)
        default:
            // 出问题或被打断：会话留着，用户可以选择结束（拿到已拼的部分）或者接着自己滚
            autoScrollMessage = status.message
            resumeManualScrollIfNeeded()
            refresh()
        }
    }

    /// 自动滚动结束后把"用户自己滚也能继续拼"这条退路接回去。
    private func resumeManualScrollIfNeeded() {
        guard let session = scrollSession, scrollDriver == nil, !isFinishing else { return }
        startScrollDriver(session)
    }

    // MARK: - 提交

    private func commitRegion(saveToDisk: Bool, after: AfterCapture) {
        guard !isFinishing else { return }
        guard let cocoaRect = session.rect else {
            commitWholeScreen(saveToDisk: saveToDisk, after: after)
            return
        }
        isFinishing = true

        let quartzRect = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoaRect,
                                                               primaryScreenHeight: primaryScreenHeight)
        let geometries = displayGeometries
        let save = saveRequest(for: nil, enabled: saveToDisk)
        let inline = inlineAnnotations()

        Task { [weak self] in
            guard let self else { return }
            // 覆盖层**先不关**：采集时按进程排除自身窗口，
            // 立刻关窗反而可能因为窗口还没真正消失而被拍进去。
            let outcome = await self.regionFlow.capture(selection: quartzRect,
                                                        displays: geometries,
                                                        save: save,
                                                        inline: inline)
            self.teardown()
            self.onFinish(.completed(outcome, after: after, anchor: cocoaRect))
        }
    }

    private func commitWindow(_ window: WindowInfo,
                              style: WindowCaptureStyle,
                              saveToDisk: Bool,
                              after: AfterCapture) {
        guard !isFinishing else { return }
        isFinishing = true
        let geometries = displayGeometries
        let save = saveRequest(for: window, enabled: saveToDisk)
        let inline = inlineAnnotations()

        // ⚠️ 有就地标注时**必须去掉阴影**。
        //
        // 带阴影的窗口图比窗口矩形大一圈（阴影是往外扩的），而标注坐标是相对
        // **窗口矩形**算的 —— 差这一圈，所有标注会整体偏移，且偏移量随阴影大小变
        // （浅色背景下阴影大，深色背景下阴影小）。表现是"有时候对、有时候偏"，
        // 属于最难查的一类。宁可这张图没有阴影。
        var effectiveStyle = style
        if inline != nil, case .isolatedWindow = style {
            effectiveStyle = .isolatedWindow(includeShadow: false)
            logger.info("有就地标注：这次窗口截图不带阴影（阴影会让标注坐标对不上）")
        }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.windowFlow.capture(window: window,
                                                        style: effectiveStyle,
                                                        displays: geometries,
                                                        save: save,
                                                        inline: inline)
            self.teardown()
            // 锚点取"覆盖层画出那一版"的矩形（Cocoa 全局），钉图据此**钉在原位**
            self.onFinish(.completed(outcome, after: after, anchor: self.settledCocoaRect))
        }
    }

    private func commitWholeScreen(saveToDisk: Bool, after: AfterCapture) {
        guard !isFinishing else { return }
        isFinishing = true
        let save = saveRequest(for: nil, enabled: saveToDisk)
        let inline = inlineAnnotations()

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.fullScreenFlow.capture(save: save, inline: inline)
            self.teardown()
            self.onFinish(.completed(outcome, after: after, anchor: nil))
        }
    }

    private func saveRequest(for window: WindowInfo?, enabled: Bool) -> CaptureSaveRequest? {
        guard enabled, let makeSaveRequest else { return nil }
        return makeSaveRequest(window)
    }

    private func cancel() {
        guard !isFinishing else { return }
        isFinishing = true
        session.cancel()
        scrollSession?.cancel()
        teardown()
        onFinish(.cancelled)
    }

    // MARK: - 读数与重绘

    /// 浮动工具栏该放哪、长什么样（ticket 20/21）。`nil` = 不显示。
    ///
    /// 工具条 + 提示行这一帧的内容与位置。
    ///
    /// ⚠️ **两者必须一次算出来**（`OverlayToolbar.panelFrames`）：
    /// 分两次算的话，贴屏底的选区的提示行会落到**工具条与选区之间**，
    /// 把用户正要截的东西盖住。而"它们是**一个东西**"正是稿子 §03 强调的。
    private struct PanelContent {
        var toolbar: OverlayToolbarPresentation
        var hintLine: OverlayHintLinePresentation?
    }

    /// 三种情况不显示：
    /// - 还没落点（拖到一半工具条跟着晃，既干扰又没意义）
    /// - 长截图期间（那时**只有提示行**，见 `scrollPresentation`）
    /// - 拿不到所在屏
    ///
    /// 具体坐标交给 `MarqueeCore.OverlayToolbar.panelFrames`（贴下方 → 放不下翻上方 → 夹进屏幕），
    /// 那里有单测：贴边与跨屏靠肉眼试不全。
    private func panelPresentationIfSettled() -> PanelContent? {
        guard session.isSettled, !hasScrollSession, let rect = annotationRect() else { return nil }
        // ⚠️ 这里的判据**只能看"会话状态"，不能看"鼠标是不是正按着"**。
        //
        // 我原先在这里加过一句"拖几何时收起工具栏"，判据是 `dragMode`。结果：
        // `dragMode` 是**只有 mouseUp 才会清**的瞬时状态，而 `endedDragAt` 里
        // "重画选区"那条分支漏了重置 —— 于是拖完选区之后 `dragMode` 永远停在 `.select`，
        // 工具栏**再也不出现**。而它坏掉的样子和"工具栏没做"一模一样。
        //
        // 其实这条规则本来就没必要：工具栏贴在选区**下方 10 点**（见 `OverlayToolbar.frame`），
        // 而控制点的命中半径是 6 点 —— 两者根本碰不到。去掉它，这一整类 bug 就不存在了。
        //
        // 重画选区时工具栏本来就会消失，因为那时 `session` 处于 `.dragging`、
        // 上面的 `isSettled` 已经是 false —— 判"会话状态"就够了。
        guard let visibleFrame = visibleFrame(containing: rect) else { return nil }
        // 那三档尺寸按**当前工具**换意义：画图形是线宽、画打码是打码强度、写文字是字号。
        // 与编辑器同一套做法，且**不新增控件** —— 工具栏每多一格就更宽，
        // 而它有一条"必须放得进 1024 点的屏"的硬约束。
        //
        // 三件事（取值 / 取当前值 / 画法）全部由 `sizeMeaning` 一个枚举决定：
        // 散开写成 `tool == .mosaic || tool == .blur` 的话，加第四种含义时一定漏一处。
        let meaning = annotationSession.sizeMeaning
        let sizeValues = meaning.values

        // ⚠️ **提示行的有无会改变工具条的位置**（整块 62 点 vs 40 点要整体摆），
        // 所以这里必须先决定"有没有话说"，再算位置 —— 反过来写的话，
        // 提示行出现/消失的那一帧工具条会**跳一下**。
        let hint = settledHintLine()
        let frames = OverlayToolbar.panelFrames(for: rect,
                                                screenFrame: visibleFrame,
                                                showingHint: hint != nil)
        let barFrame = frames.toolbar

        let toolbar = OverlayToolbarPresentation(
            frame: barFrame,
            activeTool: annotationSession.tool,
            stroke: annotationSession.style.stroke,
            sizeSlotValues: sizeValues,
            sizeSlotIndex: Self.nearestIndex(of: Self.selectedSizeValue(for: meaning, in: annotationSession), in: sizeValues),
            sizeSlotMeaning: meaning,
            isRecognizing: textRecognition?.isRunning ?? false,
            canUndo: annotationSession.canUndo,
            canRedo: annotationSession.canRedo,
            palette: palettePresentation(barFrame: barFrame, screenFrame: visibleFrame),
            proCard: proCardPresentation(barFrame: barFrame,
                                         selection: annotationRect(),
                                         screenFrame: visibleFrame),
            lockedFeatures: lockedFeatures,
            hoveredSlot: hoveredSlot
        )
        return PanelContent(
            toolbar: toolbar,
            hintLine: frames.hintLine.flatMap { frame in
                hint.map { OverlayHintLinePresentation(frame: frame, line: $0) }
            })
    }

    /// 这一帧画在哪块屏上。拿不到时返回 `nil`（那时工具条与提示行都不出现）。
    private func visibleFrame(containing rect: CGRect) -> CGRect? {
        NSScreen.screens.first { $0.frame.intersects(rect) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
    }

    /// 展开的弹层要画成什么样。
    ///
    /// 位置**从工具条的矩形算**（`OverlayToolbar.paletteFrame`），不另起一套 ——
    /// 弹层与工具条各算各的必然出现"面板飘在离按钮半格的地方"，
    /// 而那种偏差看起来像是设计如此。
    private func palettePresentation(barFrame: CGRect,
                                     screenFrame: CGRect) -> OverlayPalettePresentation? {
        guard let kind = palette else { return nil }
        let meaning = annotationSession.sizeMeaning
        let values = meaning.values
        return OverlayPalettePresentation(
            kind: kind,
            frame: OverlayToolbar.paletteFrame(kind, toolbar: barFrame, screenFrame: screenFrame),
            stroke: annotationSession.style.stroke,
            sizeSlotValues: values,
            sizeSlotIndex: Self.nearestIndex(of: Self.selectedSizeValue(for: meaning, in: annotationSession), in: values),
            sizeSlotMeaning: meaning,
            selectedEmojiIndex: selectedEmojiIndex
        )
    }

    /// 升级卡片要画成什么样。
    ///
    /// 与弹层同一个套路：位置**从工具条的矩形算**（`ProCardLayout.frame`），
    /// 不另起一套 —— 各算各的必然出现"卡片飘在离工具条半格的地方"。
    private func proCardPresentation(barFrame: CGRect,
                                     selection: CGRect?,
                                     screenFrame: CGRect) -> ProCardPresentation? {
        guard let content = proCard else { return nil }
        // 覆盖层里这张是**载体 A**：恒深色、带微行（稿子 §03）。
        let includesMicro = true
        let frame = ProCardLayout.frame(toolbar: barFrame,
                                        selection: selection,
                                        screenFrame: screenFrame,
                                        includesMicro: includesMicro)
        // ⚠️ `layout` 在这里算一次，**绘制与命中都用它**。
        // 两边各算一遍的话，"看着在按钮上、点它没反应"会在某次调尺寸时悄悄出现。
        // 量字宽要 `NSFont`，所以这一步走 `ProCardRenderer`（Core 不碰字体）。
        let layout = ProCardRenderer.layout(for: content,
                                            in: CGRect(origin: .zero, size: frame.size),
                                            includesMicro: includesMicro)
        return ProCardPresentation(frame: frame, content: content,
                                   layout: layout, priceText: proPriceText?(),
                                   includesMicro: includesMicro)
    }

    /// 当前这一组的选中值。
    private static func selectedSizeValue(for meaning: OverlaySizeMeaning,
                                          in session: OverlayAnnotationSession) -> CGFloat {
        switch meaning {
        case .lineWidth: session.style.lineWidth
        case .redactionStrength: session.style.effectStrength
        case .fontSize: session.style.fontSize
        }
    }

    /// 最接近的下标。
    ///
    /// 用"最近"而不是"相等"：`AnnotationStyle` 里的值可能来自别处（比如默认样式），
    /// 用相等比较会一个都匹配不上，表现是"三档里没有任何一档高亮"。
    private static func nearestIndex(of value: CGFloat, in values: [CGFloat]) -> Int {
        var best = 0
        for (index, candidate) in values.enumerated()
        where abs(candidate - value) < abs(values[best] - value) {
            best = index
        }
        return best
    }

    /// 就地标注作用在哪个矩形上（**Cocoa 全局点**）。`nil` = 现在没有可标注的画布。
    ///
    /// 区域落点与窗口落点一视同仁 —— 两者都会走 `session.settle`，
    /// 区别只在 `settledWindow` 有没有值。所以一个判据就够。
    private func annotationRect() -> CGRect? {
        guard session.isSettled else { return nil }
        if let window = session.settledWindow {
            let cocoa = ScreenCoordinateConversion.cocoaRect(fromQuartz: window.frame,
                                                             primaryScreenHeight: primaryScreenHeight)
            guard cocoa.width >= 1, cocoa.height >= 1 else { return nil }
            return cocoa
        }
        guard let rect = session.rect, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    /// 交叉验证"拖拽状态有没有漏收尾"。
    ///
    /// `dragMode` 只在鼠标按着时非空。这里用一个**独立的事实**去对：真的还有鼠标键按着吗？
    /// 对不上就记一条 warning —— 它坏掉时的现象是"某个东西再也不出现"，
    /// 与"那个东西没做"长得一模一样，没有日志根本分不清。
    ///
    /// ⚠️ 这条探针**误报过一次**（2026-10-01）：真因不在"某条分支漏了收尾"，
    /// 而在 `endedDragAt` 里"先分派、收尾交给 `defer`" —— 分支里调的 `refresh()`
    /// 跑在 `defer` 之前，于是它读到的是还没清掉的旧值。
    /// 所以探针报"没清"时，第一件事是**看它是在哪个时刻被读到的**，
    /// 而不是去找哪条分支忘了写。
    ///
    /// 只记日志、**不自动纠正**：`pressedMouseButtons` 是向窗口服务器查的，
    /// 万一它偶发不准，自动纠正会让工具栏在拖动中闪一下 —— 那比漏日志更难查。
    /// 一次泄漏只报一条（它会在每次 `refresh` 上触发，否则刷屏）。
    private func warnIfDragStateLeaked() {
        guard dragMode != .none, NSEvent.pressedMouseButtons == 0 else {
            hasWarnedAboutDragLeak = false
            return
        }
        guard !hasWarnedAboutDragLeak else { return }
        hasWarnedAboutDragLeak = true
    // L10N-EXEMPT-START: 拖拽状态没收尾的警告日志
        logger.warning("""
        拖拽状态没收尾：鼠标已松开，dragMode 仍是 \(self.dragMode.label, privacy: .public) \
        —— 注意先确认它是在**哪个时刻**被读到的（`endedDragAt` 里分派与 `refresh()` 的先后）
        """)
    // L10N-EXEMPT-END
    }

    /// 标注坐标系的**原点**（Cocoa 全局点）：选区的**视觉左上角**。
    ///
    /// ⚠️ Cocoa 的 `rect.origin` 是**左下角**（y 向上），而标注约定是"原点左上、y 向下"。
    /// 所以是 `maxY` 不是 `minY` —— 写成 `minY` 不会崩、不会报错，
    /// 只会让所有标注整体**上下镜像**，而且只在画了东西之后才看得出来。
    private func annotationOrigin() -> CGPoint? {
        guard let rect = annotationRect() else { return nil }
        return CGPoint(x: rect.minX, y: rect.maxY)
    }

    /// 把鼠标位置（Cocoa 全局点）换成标注坐标系里的点（原点＝选区左上角、y 向下）。
    ///
    /// - Returns: `nil` = **现在还没有画布**（还没落点）。调用方必须显式处理它 ——
    ///   曾经有个 `?? .zero` 的兜底把"没有画布"变成了"画布左上角"，
    ///   于是"按在空白处"这类判据在任何状态下都成立，**自由框选整条路被堵死**
    ///   （见 PITFALLS 101）。所以这里永远返回 `nil`，不兜底。
    private func annotationPoint(_ globalPoint: CGPoint) -> CGPoint? {
        guard let rect = annotationRect() else { return nil }
        return CGPoint(x: globalPoint.x - rect.minX, y: rect.maxY - globalPoint.y)
    }

    private func refresh() {
        warnIfDragStateLeaked()
        // 只在"按下→松开"之间记：这样数字对应的是**拖拽手感**，而不是整场会话。
        noteFrame()
        // 打码底图要在**拼 presentation 之前**算好：落点后的提示行要看它
        // （拿不到底图时得说"预览不可用，但标记仍会写进成品图"）。
        // 放在后面的话，提示行读到的是上一帧的值 —— 表现是"按钮点了，提示慢一拍"。
        rebuildRedactionBackdropIfNeeded()
        let cocoaRect = session.rect
        var presentation: SelectionPresentation

        if let progress = scrollProgress, isScrollCapturing {
            presentation = scrollPresentation(rect: scrollRect, progress: progress)
        } else if let window = session.settledWindow {
            let cocoaHover = session.rect
                ?? ScreenCoordinateConversion.cocoaRect(fromQuartz: window.frame,
                                                        primaryScreenHeight: primaryScreenHeight)
            presentation = windowPresentation(window, cocoaRect: cocoaHover, locked: true)
        } else if let cocoaRect, cocoaRect.width >= 1, cocoaRect.height >= 1 {
            let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoaRect,
                                                               primaryScreenHeight: primaryScreenHeight)
            let scale = pixelScale(forQuartzRect: quartz)
            let pixelSize = CGSize(width: (quartz.width * scale).rounded(),
                                   height: (quartz.height * scale).rounded())
            presentation = SelectionPresentation(
                globalRect: cocoaRect,
                hoverRect: nil,
                hoverCornerRadius: 10,
                // 读数框**换内容不换位置、也不换行数**（稿子 §08）：
                // 落点前它说颜色、落点后说尺寸，永远两行 —— 第一行是主角，第二行是副手。
                //
                // ⚠️ 那几条"必须说出来的事实"（打码预览不可用 / OCR 回执 / 正在输入文字）
                // 不在这里 —— 它们走**提示行**（见 `settledHintLine`）。
                // 塞进这个框会让它在有话说的时候长高，而稿子那句
                // 「同一个框，三种内容」的前提正是**它不变**。
                readout: [ReadoutLine("\(Int(quartz.width.rounded())) × \(Int(quartz.height.rounded())) pt   /   "
                                      + "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px", .primary),
                          ReadoutLine("(\(Int(quartz.minX.rounded())), \(Int(quartz.minY.rounded())))", .secondary)]
            )
        } else if let hovered = hoveredWindow, session.phase == .awaitingDrag {
            let cocoaHover = ScreenCoordinateConversion.cocoaRect(fromQuartz: hovered.frame,
                                                                  primaryScreenHeight: primaryScreenHeight)
            presentation = windowPresentation(hovered, cocoaRect: cocoaHover, locked: false)
        } else if mode == .scrollCapture {
            // 长截图的空状态。
            //
            // ⚠️ 这里**不能**把整块屏当"高亮镂空"：镂空等于不挖洞，屏幕几乎不变暗
            // （只剩四个圆角处有蒙层），用户看不出覆盖层在工作，会以为"拖不了"。
            // 正确做法是满屏蒙层 + 在光标旁挂一句提示 —— 那里正是用户的视线所在。
            presentation = SelectionPresentation(
                globalRect: nil,
                hoverRect: nil,
                hoverCornerRadius: 12,
                hintAnchor: NSEvent.mouseLocation,
                hintText: L10n.t("长截图：拖出要滚动的区域，或单击要滚动的窗口")
            )
        } else {
            presentation = .empty
        }

        // 放大镜只活在**落点之前**（`SelectionSession.showsMagnifier`）。
        //
        // 它是用来"对准"的，不是用来"看"的：选区一确定就没有用处，留在屏幕上只会挡住
        // 刚框定的内容。系统截图工具与微信截图都是这个行为（PRD F4 原话也是「选区时显示」）。
        // 长截图抓帧期间同理不显示 —— 那屏像素是开始滚动之前取的，滚起来后已与屏幕无关。
        presentation.magnifier = (session.showsMagnifier && !hasScrollSession) ? magnifier : nil

        // 就地标注与浮动工具栏（ticket 20/21）：对"区域落点"和"窗口落点"一视同仁，
        // 所以在这里**统一挂一次**，而不是塞进上面每个分支 ——
        // 那样以后加第三种落点方式时一定会漏掉一处。
        //
        // 提示行与工具条**同出同进**：它们的位置是一次算出来的
        // （见 `panelPresentationIfSettled`），分开挂会让两者落在不同的那一侧。
        if let panel = panelPresentationIfSettled() {
            presentation.toolbar = panel.toolbar
            presentation.hintLine = panel.hintLine
        }
        presentation.annotationOrigin = annotationOrigin()
        presentation.annotations = annotationSession.visibleAnnotations

        // 选区几何编辑（ticket 19）：控制点只在"能改几何"的时候出现 ——
        // 选了标注工具时拖动是画标注，这时还摆着控制点会让人以为能拖角。
        presentation.selectedAnnotationFrames = annotationSession.selectedAnnotations.map(\.frame)
        presentation.selectedAnnotationHandles = annotationHandleFrames()
        // 控制点只在"没选任何工具"时出现：选了任何工具（含「选择」）之后，
        // 拖动都属于工具自己的语义，这时还摆着控制点会让人以为能拖角改大小。
        presentation.showsSelectionHandles = session.isSettled && !hasScrollSession
            && annotationSession.tool == nil
        presentation.snapGuideVertical = snapGuide.vertical
        presentation.snapGuideHorizontal = snapGuide.horizontal

        // 打码预览（ticket 22）：底图与标注一起挂 —— 它们必须同一帧推出，
        // 否则会出现"底图换了但标注还没换"的一帧，看起来就是打码位置闪一下。
        // （底图本身在 `refresh()` 开头就算好了，见那里的注释。）
        presentation.redactionBackdrop = redactionBackdrop.map {
            RedactionBackdropPresentation(image: $0.image, scale: $0.scale)
        }

        // 光标（ticket 26）**必须最后算**：它要读上面刚挂好的工具条 / 控制点几何，
        // 提前算的话拿到的是上一帧的位置 —— 表现是"工具条移过去了、手型还留在原处"。
        presentation.cursor = cursorContext(for: presentation)

        for overlay in overlays {
            overlay.view.presentation = presentation
        }
    }

    /// 落点后那一行提示（**工具条外侧那 22 点的提示行**）。
    ///
    /// ## 常态下它**不出现**
    ///
    /// 稿子 §02 的原话：「『拖它 = 移动选区』这条提示只在悬停选区时出现，**不常显** ——
    /// 常显会挡住他自己要截的内容。」所以那句"拖角改大小 · 框内拖动移动 · ⏎ 确认 · Esc 取消"
    /// 被**删掉**了：它列的全是用户下一步要做的事，而工具条与读数的形状已经把话说完了。
    ///
    /// ## 但有三类信息没有别的地方可去
    ///
    /// 它们不是"提示"，是**必须说出来的事实** —— 少了就是 PITFALLS 里那类静默不一致：
    ///
    /// | 何时 | 为什么非说不可 |
    /// | --- | --- |
    /// | 打码底图没拿到 | 预览里不画打码、导出却会应用 —— 不说就是"成品图里凭空多了一块" |
    /// | OCR 的回执 | 用户刚点了一个异步动作，没有回执就等于"点了没反应" |
    /// | 正在输入文字 | 那一段键盘**整条让行**给输入框，不说用户不知道 `⏎` 归谁 |
    ///
    /// 它们只在真的发生时占那一行 —— 常态那一帧与稿子逐点一致。
    private func settledHintLine() -> ReadoutLine? {
        // OCR 的状态**优先于**常规提示：它是刚刚发生的事，而提示行只有那么大。
        // 识别完会在几秒后自动让位（见 `setOCRStatus`）。
        if let ocrStatus { return ReadoutLine(ocrStatus, .primary) }
        // 宿主推进来的回执（见 `showTransientNotice`）。**排在 OCR 之后**：
        // 两者都是"刚刚发生的事"，而 OCR 有进度语义（识别中就该一直显示）。
        if let transientNotice { return transientNotice }
        if annotationSession.isEditingText {
            return ReadoutLine(L10n.t("输入文字 · ⏎ 确认 · Esc 放弃"), .secondary)
        }
        if annotationSession.isSelecting {
            let count = annotationSession.selectedAnnotations.count
            return ReadoutLine(count > 0
                ? L10n.t("已选中 \(count) 个标注  ·  拖动移动  ·  Delete 删除  ·  Esc 取消选择")
                : L10n.t("点一个标注选中它  ·  拖角改大小  ·  选个工具可直接标注"), .secondary)
        }
        if annotationSession.isDrawing {
            if annotationSession.usesRedaction, redactionBackdrop == nil {
                // 琥珀：这一条会改变**结果**（成品的图里有一块打码，而你没看见）。
                return ReadoutLine(L10n.t("⚠️ 打码预览不可用（没拿到屏幕像素）—— 标记仍然会写进成品图"),
                                   .caution)
            }
            return ReadoutLine(L10n.t("在选区内拖动即可标注  ·  再点一次工具图标取消  ·  Esc 取消工具"),
                               .secondary)
        }
        return nil
    }

    /// `nil` = 鼠标不在这块屏上（走了 / 移出屏幕）—— 那种情况下**一切悬停都要收掉**。
    private func updateHover(at cocoaPoint: CGPoint?) {
        guard let cocoaPoint, session.phase == .awaitingDrag else {
            if hoveredWindow != nil {
                hoveredWindow = nil
                refresh()
            }
            return
        }
        let quartz = ScreenCoordinateConversion.quartzPoint(fromCocoa: cocoaPoint,
                                                            primaryScreenHeight: primaryScreenHeight)
        let hit = WindowCatalog.topmost(at: quartz, in: cachedWindows, excludingPID: ownPID)
        guard hit != hoveredWindow else { return }
        hoveredWindow = hit
        refresh()
    }

    private func windowPresentation(_ window: WindowInfo,
                                    cocoaRect: CGRect,
                                    locked: Bool) -> SelectionPresentation {
        var lines: [ReadoutLine] = []
        var title = window.hoverLabel
        if locked {
            title += L10n.t("  ·  ⏎ 确认")
        }
        lines.append(ReadoutLine(title, .primary))

        // ⚠️ 第二行是**"当前那一刻 ⌥ 是什么意思"的唯一声明处**（稿子 §08）。
        //
        // 三个细节都不能省：
        //
        // 1. **单独一行**，不再接在窗口标题后面 —— 接在后面时它读起来像标题的一部分，
        //    而它其实是一个"现在按 ⌥ 会改什么"的说明。
        // 2. **琥珀色**（`caution`）而不是次要色：稿子原话是
        //    「它是一个会改变结果的开关，不是一个说明」。
        // 3. **文案要说的是"结果"**，不是"这个键" —— 所以它得跟着偏好里那一项算。
        //    写死"⌥ 无阴影"在用户把「窗口截图带阴影」关掉之后就是一句**反话**：
        //    那时按 ⌥ 恰恰是**加上**阴影。而用户会照着这句话去按。
        if isOptionDown {
            lines.append(ReadoutLine(windowShadowInEffect
                                        ? L10n.t("⌥ 窗口截图 · 带阴影")
                                        : L10n.t("⌥ 窗口截图 · 不含阴影"),
                                     .caution))
        }

        return SelectionPresentation(globalRect: nil,
                                     hoverRect: cocoaRect,
                                     hoverCornerRadius: 10,
                                     readout: lines)
    }

    /// 这一次窗口截图**实际**带不带阴影（偏好里的默认值 ⊕ `⌥`）。
    ///
    /// 两处要用它：真正采集时给 `WindowCaptureStyle` 的那个值，以及读数框里那句
    /// 「⌥ 窗口截图 · 不含阴影」。**必须是同一个来源** —— 分开写的话，
    /// "标签说无阴影、导出却带了阴影"这种错不崩不报错，
    /// 只会让用户觉得"这个选项时灵时不灵"。
    private var windowShadowInEffect: Bool { windowShadowDefault != isOptionDown }

    /// 长截图抓帧中的读数：**两行进度 + 一行提示**（稿子 §10）。
    ///
    /// ## 读数框（两行，换内容不换位置）
    ///
    /// | 行 | 内容 |
    /// | --- | --- |
    /// | 一（主角） | `2 480 px 高` —— 刚拖出时就是「0 px 高」 |
    /// | 二（副手） | `18 帧 · 配准 4 ms`；配准是**可选值，拿不到就不显示、不留空位** |
    ///
    /// ## 提示行（工具条外侧那 22 点）
    ///
    /// ⚠️ **告警取代提示行，不叠行**（稿子 §10）。两行的话，用户会以为
    /// "已经滚到底了"是**除了**当前提示之外的另一个状态，而它其实是在说
    /// "刚才那句现在不作数了"。
    ///
    /// ⚠️ 而工具条**不在这里**：长截图期间面板是鼠标穿透的（用户要滚下面的应用），
    /// 那时工具条上的按钮**一个也点不动** —— 摆一排点不动的按钮就是"假入口"。
    /// 所以这一段是一块**只有提示行**的 22 点圆角条（见 `OverlayToolbar.panelRect`）。
    ///
    /// **这是与稿子的一处刻意背离，2026-10-03 与用户确认过**：稿子 §03 的 ③ 里画着工具条
    /// （提示行从它下面长出来），而稿子是不知道"面板必须鼠标穿透"这条约束的。
    /// 真要按稿子显示，`panelFrames(showingHint:)` 已经是现成的，改一行即可 ——
    /// 但那样会多出一排**看得见、点不动**的按钮，而那正是菜单栏那一节明令禁止的。
    private func scrollPresentation(rect: CGRect?,
                                    progress: ScrollCaptureSession.Progress) -> SelectionPresentation {
        let autoScrolling = autoScrollDriver != nil
        // 第一行：已拼高度。自动滚动时把状态并进去 —— 它与高度是同一件事的两面
        //（"还在长"与"长了多少"），分成两行会把读数框撑到三行。
        let heightLine = autoScrolling
            ? L10n.t("自动滚动中 · \(progress.canvasHeight) px 高")
            : L10n.t("\(progress.canvasHeight) px 高")
        // 第二行：帧数 · 配准耗时。配准拿不到时**不留空位**（稿子原话）。
        var detail = L10n.t("\(progress.frameCount) 帧")
        if let milliseconds = progress.lastRegistrationMilliseconds {
            detail += String(format: L10n.t(" · 配准 %.0f ms"), milliseconds)
        }
        // 提示行必须跟着状态走：自动滚动期间用户不需要"自己滚"的提示，
        // 他需要知道"怎么停"。反之亦然 —— 不写这一条，第一个问题就是"怎么不动了"。
        let hint = autoScrolling
            ? L10n.t("自动滚动中 · 空格停止 · Esc 停止（已拼的保留） · ⏎ 结束")
            : L10n.t("继续往下滚，或按空格自动滚 · ⏎ 结束 · ⌘S 结束并保存 · Esc 取消")
        let notice = progress.warning ?? autoScrollMessage

        var presentation = SelectionPresentation(
            globalRect: rect,
            hoverRect: nil,
            hoverCornerRadius: 10,
            isScrollCapturing: true,
            readout: [ReadoutLine(heightLine, .primary),
                      ReadoutLine(detail, .secondary)]
        )
        // 提示行贴在"工具条本该在的地方" —— 用同一个 `panelFrames`，于是
        // 将来若把工具条放回 ③，这一行会自动跟着挪到外侧，不必改这里。
        presentation.hintLine = hintLinePresentation(for: rect,
                                                     line: ReadoutLine(notice ?? hint,
                                                                       notice == nil ? .secondary : .caution))
        return presentation
    }

    /// 只有提示行时的那块 22 点条（长截图期间没有工具条）。
    private func hintLinePresentation(for rect: CGRect?,
                                      line: ReadoutLine) -> OverlayHintLinePresentation? {
        guard let rect, let visibleFrame = visibleFrame(containing: rect) else { return nil }
        let frames = OverlayToolbar.panelFrames(for: rect,
                                                screenFrame: visibleFrame,
                                                showingHint: true)
        return frames.hintLine.map { OverlayHintLinePresentation(frame: $0, line: line) }
    }


    /// 指针所在屏（Quartz 空间）。
    private func displayUnderPointer() -> DisplayGeometry? {
        guard primaryScreenHeight > 0 else { return displayGeometries.first }
        let quartz = ScreenCoordinateConversion.quartzPoint(fromCocoa: NSEvent.mouseLocation,
                                                            primaryScreenHeight: primaryScreenHeight)
        return displayGeometries.first { $0.frame.contains(quartz) } ?? displayGeometries.first
    }

    private func settleOnWindow(_ window: WindowInfo) {
        let cocoa = ScreenCoordinateConversion.cocoaRect(fromQuartz: window.frame,
                                                         primaryScreenHeight: primaryScreenHeight)
        session.settleWindow(window, cocoaRect: cocoa)
        hoveredWindow = nil
        refresh()
    }

    private func pixelScale(forQuartzRect rect: CGRect) -> CGFloat {
        displayGeometries
            .filter { $0.frame.intersects(rect) }
            .map(\.backingScale)
            .max() ?? 1
    }

    /// 方向键步长按**像素**给：2x 屏上 1 像素 = 0.5 点，
    /// 所以这里换算成点再交给状态机（ticket 03 要求 ±1 px / ⇧±10 px）。
    private func nudge(dx: CGFloat, dy: CGFloat) {
        // 长截图会话一旦建立，方向键就不该再挪采集区域（起步中也不行）
        guard !hasScrollSession else { return }
        guard let cocoaRect = session.rect else { return }
        let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoaRect,
                                                           primaryScreenHeight: primaryScreenHeight)
        let step = (session.isShiftDown ? 10 : 1) / pixelScale(forQuartzRect: quartz)
        guard session.nudge(dx: dx * step, dy: dy * step) else { return }
        refresh()
    }
}

// MARK: - 事件入口

extension SelectionOverlayController: SelectionOverlayViewDelegate {

    func overlayView(_ view: SelectionOverlayView, beganDragAt globalPoint: CGPoint) {
        beginFrameTrace()
        guard !isFinishing else { return }

        // ⚠️ 拖动**全程不会有 `mouseMoved`**（走的是 `mouseDragged`），
        // 所以悬停态得在这里主动收掉。不收的话，被高亮的那一格会一直亮着，
        // 看起来就像"这一格被选中了"（而它其实只是上一次光标路过的位置）。
        //
        // 注意这一条走的是"在画布上按下"这条路 —— 按在工具条上走的是
        // `clickedToolbarAt`，那时**要留住**悬停（它正是"按下"那个外观）。
        hoveredSlot = nil

        // 正在输入文字时，这一下点击**只用来结束输入** —— 与编辑器的做法一致。
        // 不这样的话：点一下会先把文字提交掉、再顺手在别处落一个新输入点。
        if annotationSession.isEditingText {
            commitTextEditing()
            return
        }

        // 表情工具：**点一下落一个**，内容在选工具时就定好了，所以既不拖一笔也不开输入框。
        // 放在文字分支**之前**：两者都是"点一下"，判据只能是工具本身。
        if annotationSession.tool == .emoji, !hasScrollSession {
            guard let rect = annotationRect(), rect.contains(globalPoint),
                  let local = annotationPoint(globalPoint) else {
                logger.info("表情工具已选中，但落点在选区之外 —— 忽略")
                return
            }
            annotationSession.stampEmoji(AnnotationPalette.emojis[selectedEmojiIndex], at: local)
            refresh()
            return
        }

        // 文字工具：**点一下**放下输入点，不是拖一笔（见 `OverlayTool.isStrokeBased`）。
        if annotationSession.tool == .text, !hasScrollSession {
            beginTextEdit(at: globalPoint)
            return
        }

        // 没选工具时，按在**已有标注上** = 选中并拖动它（隐式选择，ticket 24）。
        //
        // ⚠️ 判据是「**有画布 且 命中了东西**」，不是「没选工具」——
        // 只写后者的话，默认状态下的每一次按下都会被这里接走，
        // `dragMode` 被占成"画一笔"而草稿根本没开始 ——
        // 现象是**拖着鼠标，选区什么也不出现**（ticket 25 的回归，正是这么坏的）。
        //
        // `annotationPoint` 返回 `nil` 就等于"还没有画布"（它还负责落点判定），
        // 所以这两道闸写在同一个 `if` 里；判据本身在会话里，能被单测钉住。
        if !hasScrollSession, let pressPoint = annotationPoint(globalPoint),
           annotationSession.takesPressForAnnotationEditing(local: pressPoint) {
            lastDragPoint = globalPoint
            // 两种按下，**顺序不能换**（与 ticket 19 的选区同一条原则：最"尖"的先判）：
            //   ① 控制点   → 缩放
            //   ② 标注身上 → 移动
            // ①② 调过来的话，用户想拖角改大小、结果整个标注被挪走 ——
            // 而两者都是"图形跟着鼠标动"，看起来都像生效了。
            if annotationSession.beginResize(at: pressPoint) {
                dragMode = .annotationResize       // 复用同一条"按下→拖→松"的通道
            } else {
                annotationSession.beginMove(at: pressPoint)
                dragMode = .stroke
            }
            refresh()
            return
        }

        // 没命中任何标注：把之前选中的清掉（点一下别处那个框还亮着，会让人以为没点中），
        // **然后继续往下**走到选区几何那条路 —— 这一按的真实意图往往是
        // "挪一下整框"或"重画一个选区"，不该被"点在了空白处"吞掉。
        if annotationSession.isSelecting, !annotationSession.selection.isEmpty {
            annotationSession.clearSelection()
            refresh()
        }

        if annotationSession.isDrawing, !hasScrollSession {
            guard let rect = annotationRect(), rect.contains(globalPoint),
                  let local = annotationPoint(globalPoint) else {
                // 选区外按下：**什么都不做**。不偷偷重画选区（用户只是手滑了），
                // 也不画到选区外面去（会被裁掉，看起来像"工具坏了"）。
                logger.info("标注工具已选中，但落笔在选区之外 —— 忽略。要重画选区请先点掉工具或按 Esc")
                return
            }
            dragMode = .stroke
            lastDragPoint = globalPoint
            annotationSession.beginStroke(at: local)
            refresh()
            return
        }

        pointerDownAt = globalPoint
        lastDragPoint = globalPoint
        dragExceededSlop = false

        // 已落点时的按下分三种。**顺序不能换**：
        //   ① 控制点（最"尖"，先判它）
        //   ② 框内 → 移动整框
        //   ③ 框外 → 按住了拖就是重画选区（点一下不动仍是空操作，见 endedDragAt）
        //
        // 把 ①② 调过来的话，用户想拖右上角改大小、结果整框被挪走了 ——
        // 而两者都是"框在跟着鼠标动"，看起来都像"生效了"，很难说清哪里不对。
        if session.isSettled, !hasScrollSession, let rect = session.rect {
            if let handle = SelectionGeometry.handle(at: globalPoint, in: rect) {
                dragMode = .resize(handle: handle, anchor: rect)
                return
            }
            if rect.contains(globalPoint) {
                dragMode = .move(anchor: rect)
                return
            }
        }

        dragMode = .select
        if !session.isSettled {
            updateHover(at: globalPoint)
        }
    }

    func overlayView(_ view: SelectionOverlayView, draggedTo globalPoint: CGPoint) {
        guard !isFinishing else { return }
        lastDragPoint = globalPoint

        switch dragMode {
        case .annotationResize:
            guard let local = annotationPoint(globalPoint) else { return }
            annotationSession.updateResize(to: local)
            refresh()

        case .stroke:
            guard let local = annotationPoint(globalPoint) else { return }
            // 两种 `.stroke`：画一笔（`isDrawing`）或拖动已选中的标注（`isSelecting`）。
            // 用同一个 DragMode 是因为它们的生命周期完全相同（按下→拖→松），
            // 区别只在会话上调用哪个方法。
            if annotationSession.isMovingAnnotations {
                annotationSession.updateMove(to: local)
            } else {
                annotationSession.updateStroke(to: local)
            }
            refresh()

        case .move(let anchor):
            guard let delta = dragDelta(to: globalPoint) else { return }
            let moved = anchor.offsetBy(dx: delta.x, dy: delta.y)
            // 整框跑出屏幕就整次丢弃 —— 选区与工具栏都会跟着出屏，
            // 那样连"再拖回来"都做不到，只能按 Esc 重来。
            guard keepsOnScreen(moved) else { return }
            apply(moved, edges: .all)

        case .resize(let handle, let anchor):
            guard dragDelta(to: globalPoint) != nil else { return }
            apply(resizedRect(anchor: anchor, handle: handle, to: globalPoint),
                  edges: handle.movingEdges)

        case .select:
            guard let start = pointerDownAt else { return }
            if !dragExceededSlop {
                guard hypot(globalPoint.x - start.x, globalPoint.y - start.y) >= Self.dragSlop else { return }
                dragExceededSlop = true
                session.beginDrag(at: start)
            }
            session.updateDrag(to: globalPoint)
            // 拖拽时鼠标移动走的是 mouseDragged，不会触发 mouseMoved —— 放大镜得在这里跟
            updateMagnifier(at: globalPoint)
            refresh()

        case .none:
            break
        }
    }

    func overlayView(_ view: SelectionOverlayView, endedDragAt globalPoint: CGPoint, optionDown: Bool) {
        endFrameTrace("选区几何")   // L10N-EXEMPT: 日志标签，不是给用户看的文案
        guard !isFinishing else { return }

        // 先把这次拖拽的"种类"**取走并立刻清空**，再分派。
        //
        // ⚠️ 不能反过来（先分派、收尾交给 `defer`）。分支里会调 `refresh()`，
        // 而 `defer` 要等函数返回才跑 —— 那几拍里 `refresh()` 读到的是**旧值**。
        // 后果有两条，都是"看起来跟这不相关"的那种：
        //   ① 交叉验证探针误报「鼠标已松开、dragMode 仍非空」（用户 2026-10-01 的日志里
        //      连报两次，其实是误报 —— 真因就是这里）；
        //   ② 任何想读"这次拖拽是什么"的地方读到的是上一次的。
        // 我第一版写的就是 `defer`，结果每条需要读它的 `case` 里又各自补了一句
        // `dragMode = .none` —— 也就是说"收尾只留一处"根本没成立。
        // **要点：要读它，就得先取走。**
        //
        // ⚠️ 局部变量别叫 `mode` —— 控制层自己有一个 `mode: Mode`（采集模式），
        // 名字一撞就会把它遮住：`mode == .scrollCapture` 立刻编不过（两个枚举没有同名成员），
        // 但如果哪天它们有了同名成员，这里会**悄悄换成另一个含义**。
        let drag = dragMode
        dragMode = .none

        defer {
            pointerDownAt = nil
            dragExceededSlop = false
            lastDragPoint = nil
        }

        switch drag {
        case .annotationResize:
            if let local = annotationPoint(globalPoint) {
                if annotationSession.endResize(to: local) {
                    logger.info("标注缩放：已改大小")
                }
            } else {
                // 拿不到坐标系（选区没了）：退回按下前那一版，别把它留在半路上。
                annotationSession.cancelStroke()
            }
            refresh()
            return

        case .stroke:
            guard let local = annotationPoint(globalPoint) else { return }
            if annotationSession.isMovingAnnotations {
                let moved = annotationSession.endMove(at: local)
                if moved { logger.info("标注移动：已移动选中的标注") }
                refresh()
                return
            }
            let committed = annotationSession.endStroke(at: local)
            let verdict = committed ? L10n.t("已落一个") : L10n.t("太短，丢弃")
            logger.info("标注收笔：\(verdict, privacy: .public)，当前共 \(self.annotationSession.annotations.count) 个")
            refresh()
            return

        case .move, .resize:
            // 松手就结束这次几何编辑，吸附提示线随之收起
            snapGuide = (nil, nil)
            refresh()
            return

        case .select, .none:
            break
        }

        guard !hasScrollSession else { return }

        if dragExceededSlop {
            // 松手 = 选区落点停住，等方向键微调 / ⏎ 确认。立即提交会让微调键永远走不到。
            _ = session.endDrag(at: globalPoint)
            refresh()
            if mode == .scrollCapture, let rect = session.rect {
                // 长截图不需要"停住再确认"：拖到哪里就从哪里开始滚
                beginScrollCapture(cocoaRect: rect)
            }
            return
        }

        // 落点之后点击仍是空操作：放大镜已收起，取色随之结束，
        // `⌥` 在这里恢复 ticket 04 的"无阴影"语义（在提交时才被读）。
        if session.isSettled {
            return
        }

        // 落点之前按住 `⌥` 点击 = 复制取样色值（PRD F4）。
        // 不带 `⌥` 的点击不受影响，仍然是"选中这扇窗" —— 两个语义不打架。
        if optionDown, copySampledColor() {
            return
        }

        if let window = hoveredWindow {
            // 单击窗口 = 落点停住，等 ⏎ 确认。立刻采集就没有确认过程。
            isOptionDown = optionDown
            settleOnWindow(window)
            if mode == .scrollCapture, let rect = session.rect {
                beginScrollCapture(cocoaRect: rect)
            }
        }
    }

    func overlayView(_ view: SelectionOverlayView, movedTo globalPoint: CGPoint) {
        guard !isFinishing, !hasScrollSession else { return }
        // 拖拽中不会有 mouseMoved（走的是 draggedTo），所以这里只处理"空闲移动"
        updateMagnifier(at: globalPoint)
        updateHover(at: globalPoint)
        updateToolbarHover(at: globalPoint)
    }

    /// 鼠标移到别处 / 离开这块屏 —— 悬停态必须**当场**清掉。
    ///
    /// 少了这一步，被高亮的那一格会一直亮着，看起来就像"这一格被选中了"。
    func overlayViewDidExit(_ view: SelectionOverlayView) {
        guard !isFinishing else { return }
        updateToolbarHover(at: nil)
        updateHover(at: nil)
    }

    /// 算出"鼠标此刻压在哪一格工具条上"。
    ///
    /// 只有工具条**真的在屏幕上**时才算 —— 还在拖选区、或者已经提交时工具条不存在，
    /// 这时把悬停留着会让下一次工具条出现时**带着一个不属于它的高亮**。
    private func updateToolbarHover(at globalPoint: CGPoint?) {
        var slot: OverlayToolbarSlot?
        if let globalPoint, let bar = panelPresentationIfSettled()?.toolbar {
            slot = OverlayToolbar.slot(at: globalPoint, in: bar.frame)
        }
        guard slot != hoveredSlot else { return }
        hoveredSlot = slot
        refresh()
    }

    func overlayView(_ view: SelectionOverlayView, nudgeBy dx: CGFloat, dy: CGFloat) {
        guard !isFinishing else { return }
        nudge(dx: dx, dy: dy)
    }

    func overlayView(_ view: SelectionOverlayView, shiftChanged isDown: Bool) {
        session.setShiftDown(isDown)
        annotationSession.isShiftDown = isDown
        // 拖控制点时按 `⇧` 必须**当场**变形状，不能等下一次鼠标移动 ——
        // 用户按了键却看不到任何变化，只会以为这个键没生效（PITFALLS：谁改谁推）。
        if case .resize(let handle, let anchor) = dragMode, let point = lastDragPoint {
            apply(resizedRect(anchor: anchor, handle: handle, to: point),
                  edges: handle.movingEdges)
            return
        }
        if case .annotationResize = dragMode, let point = lastDragPoint,
           let local = annotationPoint(point) {
            annotationSession.updateResize(to: local)
        }
        refresh()
    }

    func overlayView(_ view: SelectionOverlayView, optionChanged isDown: Bool) {
        guard isOptionDown != isDown else { return }
        isOptionDown = isDown
        // `⌥` 是"显示色值 / 点击复制"的修饰键，按下与松开都要**当场**看到变化 ——
        // 不能等下一次鼠标移动（读数行是烘进 presentation 的，得重建）
        rebuildMagnifier()
    }

    func overlayViewDidRequestCommit(_ view: SelectionOverlayView) {
        performCommit(saveToDisk: false)
    }

    func overlayViewDidRequestSave(_ view: SelectionOverlayView) {
        performCommit(saveToDisk: true)
    }

    private func performCommit(saveToDisk: Bool, after: AfterCapture = []) {
        guard !isFinishing else { return }

        // 工具栏的「完成 / 保存」会走到这里，而输入框里可能还有没敲完的字 ——
        // 不先结算的话，用户刚打的字会**无声无息地消失**。
        // （`⏎` 到不了这里：它在输入期间被让行给输入框了。）
        commitTextEditing()

        if mode == .scrollCapture {
            if hasScrollSession {
                // 起步中（`session.begin` 还没返回）忽略按键：这时 `finish()` 会因为
                // 一帧都没有而报"没有采到任何画面"，对用户来说是莫名其妙的一次失败。
                if isScrollCapturing {
                    finishScrollCapture(saveToDisk: saveToDisk)
                }
                return
            }
            if let rect = session.rect {
                beginScrollCapture(cocoaRect: rect)
            } else if let display = displayUnderPointer() {
                // 没划区域就按 ⏎ = 整屏长截图（用户可能只想滚整个页面）
                let cocoa = ScreenCoordinateConversion.cocoaRect(fromQuartz: display.frame,
                                                                primaryScreenHeight: primaryScreenHeight)
                session.settle(rect: cocoa)
                refresh()
                beginScrollCapture(cocoaRect: cocoa)
            }
            return
        }

        switch session.commitAction(hasHoveredWindow: hoveredWindow != nil) {
        case .commitRegion:
            commitRegion(saveToDisk: saveToDisk, after: after)
        case .commitWindow:
            guard let window = session.settledWindow else {
                commitRegion(saveToDisk: saveToDisk, after: after)
                return
            }
            // `⌥` = 临时反转偏好里的那个选择（PRD F4）。
            // 写成 `!isOptionDown` 就把它变成了"永远带阴影" —— 而偏好里那一项会失效。
            //
            // 这里与读数框里那句「⌥ 窗口截图 · 不含阴影」用的是**同一个**判据
            // （`windowShadowInEffect`）—— 见那处的注释。
            let style = WindowCaptureStyle.isolatedWindow(includeShadow: windowShadowInEffect)
            commitWindow(window, style: style, saveToDisk: saveToDisk, after: after)
        case .settleHoveredWindow:
            guard let window = hoveredWindow else { return }
            settleOnWindow(window)
        case .commitWholeScreen:
            commitWholeScreen(saveToDisk: saveToDisk, after: after)
        }
    }

    func overlayViewDidRequestWholeScreen(_ view: SelectionOverlayView) {
        // 选了任何工具时，双击都没有意义：第一下已经算一笔了（落点 → 太短被丢弃）。
        // 真正会踩到的是"想画两笔、手快了一点"，那样第二笔会被吃掉 —— 挡掉更省事。
        guard annotationSession.tool == nil else { return }
        if mode == .scrollCapture {
            // 长截图里双击 = "整屏开始滚"，而不是"截一张整屏"
            performCommit(saveToDisk: false)
            return
        }
        // 双击整屏走的就是"完成"那条路：图进剪贴板、就地收场
        commitWholeScreen(saveToDisk: false, after: [])
    }

    func overlayViewDidToggleAutoScroll(_ view: SelectionOverlayView) {
        toggleAutoScroll()
    }

    func overlayView(_ view: SelectionOverlayView, clickedToolbarAt globalPoint: CGPoint) {
        guard !isFinishing, let bar = panelPresentationIfSettled()?.toolbar,
              let slot = OverlayToolbar.slot(at: globalPoint, in: bar.frame) else { return }
        // 点工具条**不会把正在打的字扔掉**：
        // - 改样式 / 撤销重做 → 输入继续（用户想改的就是这一行）
        // - 换工具 / 识别 / 保存 / 取消 / 完成 → 先**结算**（把内容落成标注），再执行动作
        //
        // 结算 ≠ 丢弃。只有 `Esc` 才丢 —— 这一条得写清楚，
        // 否则以后有人"顺手"在换工具时改成 `cancelTextEditing()`，用户的字就没了。
        if !slot.preservesTextEditing {
            commitTextEditing()
        }
        perform(toolbarSlot: slot)
    }

    func overlayView(_ view: SelectionOverlayView, clickedPaletteAt globalPoint: CGPoint) {
        guard !isFinishing, let kind = palette,
              let frame = currentPaletteFrame() else { return }
        guard let item = OverlayToolbar.paletteItem(at: globalPoint, in: frame, kind: kind) else {
            // 点在面板的空白处（格与格之间）：**什么都不做**，也不收起 ——
            // 收起会让"手抖了一下"变成"面板没了"，而用户只是想再点一次那个色。
            return
        }
        commitTextEditing()
        perform(paletteItem: item)
    }

    /// 点在了卡片外面：**收卡片，别的不动**。
    ///
    /// 与 `Esc` 走**同一个收尾**（`proCard = nil` + 刷新）—— 稿子把它们当成同一件事：
    /// 「卡片也没有 ✕，Esc / 点别处即是关闭」。两条路各写一遍的话，
    /// 迟早会出现"Esc 收得掉、点别处收不掉"（或者反过来还顺手清掉了别的状态）。
    func overlayViewDidDismissProCard(_ view: SelectionOverlayView) {
        dismissProCard()
    }

    /// 权益判定变了（用户刚买了 / 刚恢复完）—— 覆盖层要跟着变。
    ///
    /// ⚠️ **重新问一次 `ProCard.content`，而不是自己判断"现在是不是解锁了"**：
    /// 那个函数就是"该不该弹卡片"的**唯一判据**（返回 `nil` 恰好就是"该放行"）。
    /// 在这里另写一遍的话，"某一项放开了但卡片照弹"这类不一致迟早会出现。
    ///
    /// 有了它，"点恢复购买 → 成功了 → 锁**当场**消失"才成立 ——
    /// 否则用户会盯着一个已经没用的锁，以为恢复没成功。
    public func entitlementsChanged() {
        guard let current = proCard, let snapshot = proEntitlement?() else { return }
        proCard = ProCard.content(for: snapshot, feature: current.feature)
        refresh()
    }

    /// 收卡片。**只置 `proCard`**：选区与标注一个字都不动 ——
    /// 用户中途放弃，这次截图还能接着做完。
    private func dismissProCard() {
        guard proCard != nil else { return }
        proCard = nil
        refresh()
    }

    func overlayView(_ view: SelectionOverlayView, clickedProCardAt globalPoint: CGPoint) {
        guard !isFinishing, let content = proCard,
              let card = panelPresentationIfSettled()?.toolbar.proCard else { return }
        guard let action = ProCardLayout.action(at: globalPoint,
                                                in: card.frame,
                                                layout: card.layout,
                                                buttons: content) else {
            // 点在卡片的正文或空白处：**什么都不做**（那一层已经被视图吃掉了，
            // 不会掉进拖选区）。手抖一下就变成"发起购买"，是这张卡片上最贵的错误。
            return
        }
        logger.info("升级卡片：点了 \(action.rawValue, privacy: .public)")

        // ⚠️ **先让开，再执行。**
        //
        // 覆盖层是 `.screenSaver` 层的**非激活**面板，整屏压在普通窗口之上 ——
        // 而这两个动作都要开窗口（偏好设置 / StoreKit 的购买面板）。
        // 覆盖层不退场的话，那个窗口会在它**底下**打开：用户看到的是"点了没反应"，
        // 于是把整张卡片说成"点不动"。这正是 2026-10-04 用户报的那一条。
        //
        // `cancel()` 与 `Esc` 走同一条收尾（宿主那边对 `.cancelled` 只记一条日志），
        // 所以这里不会顺手做别的事。代价是**选区没了** —— 而用户点的是
        // "去了解 Pro / 开始试用"，那是一段要离开这次截图的流程。
        if action.needsAnotherWindow {
            cancel()
        } else {
            // 原地能完成的那一个（恢复购买）：只收卡片，**选区与标注一个字不动** ——
            // 成功就当场解锁（锁跟着消失），失败就留着这次截图接着做完。
            proCard = nil
            refresh()
        }
        onProCardAction?(action)
    }

    /// 此刻**锁着的** Pro 能力。工具条上那几格会补一个小锁角标。
    ///
    /// 与 `allowProEntry` 用**同一个判据**（`snapshot.access(to:)`）——
    /// 角标与"点了会不会弹卡片"必须同源。各算各的会出现"图标上没锁、点下去却弹出购买卡片"，
    /// 那比不画锁更让人困惑。
    ///
    /// 宿主没接时是**空集**（= 都不锁），与 `allowProEntry` 的放行一致。
    private var lockedFeatures: Set<ProFeature> {
        guard let snapshot = proEntitlement?() else { return [] }
        return Set(ProFeature.allCases.filter { !snapshot.access(to: $0).isAllowed })
    }

    /// 入口处的门。返回 `false` = 被挡住了、而且卡片已经弹出来。
    ///
    /// ## 为什么只在**入口**挡
    ///
    /// 进到流程中间再失败，用户会白框一次选区、白画几笔，然后才被告知要付费 ——
    /// 那是最容易招差评的顺序（见 `docs/MAS-AND-MONETIZATION.md` §「被挡住时的界面行为」）。
    ///
    /// ## 它**一个会话状态都不动**
    ///
    /// 这个函数只置 `proCard`：不碰 `session`（选区）、不碰 `annotationSession`（标注）。
    /// "关掉卡片不许丢任何东西"就是靠这一条成立的 ——
    /// 以后有人往这里"顺手"加一句 `cancel()` 或清空标注，那条规则当场失效。
    private func allowProEntry(_ slot: OverlayToolbarSlot) -> Bool {
        guard let feature = slot.proFeature else { return true }      // 免费格：不问
        guard let snapshot = proEntitlement?() else { return true }    // 宿主没接：放行
        // `ProCard.content` 返回 nil **就是**"该放行" —— 不在这里另外判一次。
        // 另判一次的话，"这一项已经放开成免费了、卡片却照弹"这类不一致迟早会出现。
        guard let card = ProCard.content(for: snapshot, feature: feature) else { return true }

        proCard = card
        logger.info("入口被挡：\(feature.rawValue, privacy: .public)")
        refresh()
        return false
    }

    /// 工具栏每一格的动作。
    ///
    /// 「完成」/「保存」与 `⏎`/`⌘S` 走**同一套收尾通道**（`performCommit`），
    /// 「取消」与 `Esc` 走同一个 `cancel()` —— 不另起一套，否则两条路的收尾行为迟早分叉。
    private func perform(toolbarSlot slot: OverlayToolbarSlot) {
        switch slot {
        case .tool(let tool):
            annotationSession.toggle(tool: tool)
            let current = annotationSession.tool?.rawValue ?? L10n.t("无")
            logger.info("工具栏：点了工具 \(tool.rawValue, privacy: .public) → 当前选中 \(current, privacy: .public)")
            // 选中「表情」就把表情面板打开。不打开的话，用户点一下画布只会得到
            // **上一次选的那一枚** —— 而他根本不知道那是哪一枚，只会觉得"点错了"。
            if annotationSession.tool == .emoji {
                palette = .emoji
            } else if palette == .emoji {
                palette = nil
            }

        case .style:
            // 再点一次收起（同一个键开也同一个键关，不留"另一个地方才能关"）
            palette = (palette == .style) ? nil : .style

        case .undo, .redo:
            let isRedo = (slot == .redo)
            // 正在输入文字时，撤销指的是"撤销我刚打的字" —— 与框里按 `⌘Z` 一致。
            // 直接去撤销文档的话，用户会看到刚敲的一整行**连同上一笔标注**被一起收走。
            if let view = textEditingView, view.undoTextInput(redo: isRedo) { return }
            let changed = isRedo ? annotationSession.redo() : annotationSession.undo()
            if changed {
                logger.info("工具栏：\(isRedo ? "重做" : "撤销", privacy: .public) → 现在 \(self.annotationSession.annotations.count) 个标注")
            }

        case .ocr:
            guard allowProEntry(slot) else { return }
            runTextRecognition()
            return     // runTextRecognition 自己会刷新（它要先显示"正在识别…"）

        case .pin:
            guard allowProEntry(slot) else { return }
            // 钉图 = 「完成」+ 多留一份在屏幕上。图**照样进剪贴板** ——
            // 每条提交路径都写剪贴板是这套设计的不变量，钉图不该是例外
            //（否则用户按了钉图会发现剪贴板没变，而他会以为截图没成）。
            logger.info("工具栏：钉图")
            performCommit(saveToDisk: false, after: .pin)
            return

        case .save:
            logger.info("工具栏：完成并保存到磁盘")
            performCommit(saveToDisk: true)
            return     // performCommit 会收场，不必再刷新

        case .cancel:
            logger.info("工具栏：取消")
            cancel()
            return

        case .confirm:
            logger.info("工具栏：完成（就地出图，不开窗口）")
            performCommit(saveToDisk: false)
            return
        }
        refresh()
    }

    /// 弹层里每一格的动作。
    private func perform(paletteItem item: OverlayPaletteItem) {
        switch item {
        case .color(let index):
            guard AnnotationPalette.colors.indices.contains(index) else { return }
            annotationSession.style.stroke = AnnotationPalette.colors[index]

        case .lineWidth(let index):
            applySizeSlot(index)

        case .emoji(let index):
            guard AnnotationPalette.emojis.indices.contains(index) else { return }
            selectedEmojiIndex = index
            // 选完**收起面板**：接下来用户要点画布落点，面板留着会挡住那一片。
            // 想换一枚再点一次「表情」格就有了。
            palette = nil
            logger.info("工具栏：选了第 \(index, privacy: .public) 枚表情")
        }
        refresh()
    }

    /// 那三档尺寸的点击：按当前工具改**不同的参数**（与编辑器同一套做法）。
    private func applySizeSlot(_ index: Int) {
        let meaning = annotationSession.sizeMeaning
        let values = meaning.values
        guard values.indices.contains(index) else { return }
        switch meaning {
        case .lineWidth:
            annotationSession.style.lineWidth = values[index]
        case .redactionStrength:
            annotationSession.style.effectStrength = values[index]
            logger.info("工具栏：打码强度 → \(self.annotationSession.style.effectStrength, privacy: .public) 点")
        case .fontSize:
            annotationSession.style.fontSize = values[index]
            // 正在输入的字号也要跟着变：用户是想"把这行字调大"，
            // 若只影响下一个字，他会以为这个键没用（谁改谁推）。
            if let pending = annotationSession.textEditor?.text {
                annotationSession.updateText(pending)
            }
            logger.info("工具栏：字号 → \(self.annotationSession.style.fontSize, privacy: .public) 点")
        }
    }

    /// 当前展开的弹层该放在哪（**Cocoa 全局点**）。`nil` = 没展开或工具条不在。
    ///
    /// 直接取呈现里的那一份，不再自己算一遍 —— 命中与绘制必须是同一份几何。
    private func currentPaletteFrame() -> CGRect? {
        panelPresentationIfSettled()?.toolbar.palette?.frame
    }

    /// 把就地画的标注打包给采集流程。
    ///
    /// `nil` = 没有标注（或没有画布）。**坐标空间用选区的点尺寸** ——
    /// 采集流程是唯一知道最终输出像素尺寸的地方，换算在那里做。
    private func inlineAnnotations() -> InlineAnnotations? {
        guard let rect = annotationRect(), !annotationSession.annotations.isEmpty else { return nil }
        return InlineAnnotations(annotations: annotationSession.annotations, pointSize: rect.size)
    }

    // MARK: - 选区几何编辑（ticket 19）

    /// 超过 4 点才算"真的在拖"。返回累计位移；没超过返回 `nil`。
    ///
    /// 统一在这里判定，是因为"点击"与"拖拽"必须分开：不加这道闸，
    /// 误点一下就会把选区挪 1 点（或者把框缩到最小），而用户完全看不出自己动了什么。
    private func dragDelta(to point: CGPoint) -> CGPoint? {
        guard let start = pointerDownAt else { return nil }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        if !dragExceededSlop {
            guard hypot(delta.x, delta.y) >= Self.dragSlop else { return nil }
            dragExceededSlop = true
        }
        return delta
    }

    /// 选区至少还压在某块屏上。
    ///
    /// 整框被拖出屏幕的话，选区与工具栏一起出屏 —— 那时连"再拖回来"都做不到
    /// （鼠标够不着它了），只能按 `Esc` 重来。所以宁可这一帧不动。
    private func keepsOnScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    /// 按 `⇧` 的状态决定要不要锁比例。
    ///
    /// 比例取自**按下时那一版**矩形：用"当前矩形"当基准的话，每帧都会以自己为基准
    /// 重新锁一次，比例会一路漂走（而且越拖越离谱）。
    private func resizedRect(anchor: CGRect,
                             handle: SelectionGeometry.Handle,
                             to point: CGPoint) -> CGRect {
        let aspect = session.isShiftDown && handle.isCorner
            ? anchor.width / max(anchor.height, 1)
            : nil
        return SelectionGeometry.resized(anchor, handle: handle, to: point, aspect: aspect)
    }

    /// 吸附并落点。`edges` 决定哪些边参与吸附：移动整框是四条，拖控制点只有动的那一两条。
    private func apply(_ rect: CGRect, edges: SelectionGeometry.Edge) {
        let result = SelectionGeometry.snapped(rect, edges: edges, targets: snapTargets())
        session.settle(rect: result.rect)
        snapGuide = (result.verticalLine, result.horizontalLine)
        refresh()
    }

    // MARK: - 文字输入（ticket 22）

    /// 点一下：在那个位置放下一个待输入的文字，并把输入框挂到**点到的那块屏**上。
    private func beginTextEdit(at globalPoint: CGPoint) {
        guard let rect = annotationRect(), rect.contains(globalPoint),
              let local = annotationPoint(globalPoint) else {
            // 选区外点击：什么都不做。不偷偷重画选区，也不把文字落到选区外面
            //（外面那部分会被裁掉，看起来像"输入框跑丢了"）。
            logger.info("文字工具：点在选区之外 —— 忽略。要重画选区请先按 Esc 退出工具")
            return
        }
        guard let annotation = annotationSession.beginText(at: local) else { return }
        guard let target = overlay(containing: globalPoint) else { return }

        textEditingView = target.view
        target.view.showTextInput(for: annotation, text: annotation.text)
        logger.info("文字输入开始：锚点 (\(Int(local.x)), \(Int(local.y)))，输入框在第 \(self.overlays.firstIndex { $0.view === target.view } ?? 0) 块屏")
        refresh()
    }

    /// 结束输入并**提交**（内容为空则丢弃）。没在输入时是空操作。
    private func commitTextEditing() {
        guard let view = textEditingView else { return }
        let text = view.textInputText ?? ""
        view.hideTextInput()
        textEditingView = nil

        if annotationSession.commitText(text) {
            logger.info("文字已落定：\(text.count, privacy: .public) 个字")
        } else {
            logger.info("文字输入结束：内容为空 —— 不留下任何东西")
        }
        refresh()
    }

    /// 结束输入并**丢弃**（`Esc`）。没在输入时是空操作。
    private func cancelTextEditing() {
        guard let view = textEditingView else { return }
        view.hideTextInput()
        textEditingView = nil
        annotationSession.cancelText()
        logger.info("文字输入已取消（这一下 Esc 没有丢掉整次截图）")
        refresh()
    }

    /// 选中标注的控制点，从**选区局部点**换成 **Cocoa 全局点**。
    ///
    /// 这是唯一一处做这个换算的地方 —— 视图拿到的直接是全局坐标，它只管画与命中。
    /// 两个坐标系 y 方向相反（标注原点左上、y 向下；Cocoa 原点左下、y 向上），
    /// 所以取的是 `origin.y - local.maxY`（把"局部下边"映到"全局上边"）。
    /// 写成 `+ local.minY` 不会崩，只会让控制点**上下镜像**地画在标注的另一侧。
    private func annotationHandleFrames() -> [AnnotationHandlePresentation] {
        guard let origin = annotationOrigin() else { return [] }
        return annotationSession.selectedHandles.map { item in
            let local = item.frame
            return AnnotationHandlePresentation(
                handle: item.handle,
                frame: CGRect(x: origin.x + local.minX,
                              y: origin.y - local.maxY,
                              width: local.width,
                              height: local.height)
            )
        }
    }

    // MARK: - 光标（ticket 26）

    /// 光标规则要吃的那份上下文。
    ///
    /// 几何**全部在这里算好**（Cocoa 全局点），Core 那条规则只做判断 ——
    /// 与"视图不做几何判断"是同一条约定，好处是规则可以脱机单测、
    /// 而多屏 / 翻转这类容易错的地方仍然只有一处。
    ///
    /// - Parameter presentation: **正在拼的那一版**。传进来而不是读一个属性 ——
    ///   它在 `refresh()` 里是局部的，读属性会拿到上一帧的几何。
    private func cursorContext(for presentation: SelectionPresentation) -> OverlayCursorContext {
        var context = OverlayCursorContext()
        context.drag = cursorDrag
        context.isSettled = session.isSettled
        context.isScrollCapturing = hasScrollSession
        // 落点前是 `nil`（正在拖的那个选区不算画布），落点后才是能标注的区域。
        // 两者混用的话，拖着找选区的时候光标会提前变成"可以画标注"。
        context.canvas = session.isSettled ? annotationRect() : nil
        context.tool = annotationSession.tool
        context.toolbar = presentation.toolbar?.frame
        context.palette = presentation.toolbar?.palette?.frame
        // 升级卡片：整块 + 两个按钮的命中区（**它排在弹层与工具条之前判**）。
        // 两个按钮的矩形由 `card.layout` 从**卡片局部**换成全局 —— 与命中用的是同一份矩形。
        if let card = presentation.toolbar?.proCard {
            context.proCard = card.frame
            context.proCardButtons = [card.layout.primary, card.layout.secondary].map {
                $0.offsetBy(dx: card.frame.minX, dy: card.frame.minY)
            }
        }

        // 选区控制点：`handleFrame` 只跟中心点有关，所以直接拿全局矩形算，
        // 不必先换算到局部再换回来（少一次转换就少一次翻错 y 的机会）。
        if presentation.showsSelectionHandles, let rect = annotationRect() {
            context.selectionHandles = SelectionGeometry.Handle.allCases.map {
                OverlayCursorContext.HandleRegion(handle: $0,
                                                  frame: SelectionGeometry.handleFrame($0, on: rect))
            }
        }
        context.annotationHandles = presentation.selectedAnnotationHandles.map {
            OverlayCursorContext.HandleRegion(handle: $0.handle, frame: $0.frame)
        }

        // 标注的包围盒：从**选区局部点**（原点左上、y 向下）换成 Cocoa 全局点。
        // 这也是唯一一处做这个换算的地方（`annotationHandleFrames` 同款），
        // 写成 `origin.y + local.minY` 不会崩，只会让"压着标注"的判定上下镜像。
        if let origin = annotationOrigin() {
            context.annotationFrames = annotationSession.annotations.map { annotation in
                let box = annotation.frame.standardized
                return CGRect(x: origin.x + box.minX,
                              y: origin.y - box.maxY,
                              width: box.width,
                              height: box.height)
            }
        }

        var disabled: Set<OverlayToolbarSlot> = []
        if !annotationSession.canUndo { disabled.insert(.undo) }
        if !annotationSession.canRedo { disabled.insert(.redo) }
        // 识别进行中那一格换成了沙漏的样子，再点一次不会有新的事情发生
        if textRecognition?.isRunning == true { disabled.insert(.ocr) }
        context.disabledSlots = disabled

        return context
    }

    /// 这次拖拽对应哪种光标。
    ///
    /// `.stroke` 要分两义（画一笔 / 挪一个标注），判据与会话里那条完全一样 ——
    /// 各写各的话，迟早出现"手上是合上的手、图里却在画新矩形"。
    private var cursorDrag: OverlayCursorContext.Drag {
        switch dragMode {
        case .none: .none
        case .select: .selection
        case .move: .movingSelection
        case .resize(let handle, _): .resizingSelection(handle)
        case .stroke: annotationSession.isMovingAnnotations ? .movingAnnotation : .drawingAnnotation
        case .annotationResize:
            annotationSession.resizingHandle.map { .resizingAnnotation($0) } ?? .none
        }
    }

    /// "覆盖层画出那一版"的选中矩形（**Cocoa 全局点**）。没有落点时是 `nil`。
    ///
    /// 单独抽出来是因为窗口落点要看的是**用户看到的那一圈**（`session.rect`），
    /// 而不是窗口自己的矩形 —— 两者在"带阴影/贴边"时会差一点，
    /// 而钉图按它定位，差一点就是"钉出来的位置跟刚才框的不是一处"。
    private var settledCocoaRect: CGRect? { session.rect }

    /// 点落在**哪块屏**的覆盖层上。
    ///
    /// 输入框必须挂到那个视图上：挂错屏的后果是它出现在另一块显示器上，
    /// 而用户在自己这块屏上什么都看不到 —— 与"点了没反应"完全一样。
    private func overlay(containing globalPoint: CGPoint)
        -> (panel: SelectionOverlayPanel, view: SelectionOverlayView)? {
        overlays.first { $0.panel.frame.contains(globalPoint) } ?? overlays.first
    }

    // MARK: - 文字识别（ticket 23）

    /// 识别选区里的文字，并把结果直接写进剪贴板。
    ///
    /// ## 为什么是"写剪贴板 + 一行状态"，而不是一个面板
    ///
    /// OCR 的全部用处就是"把这段文字拿走"。覆盖层的读数框只有三行、又是 CoreGraphics
    /// 画的，做不出可划选的文本区；为了它去引一个输入控件，代价远大于收益 ——
    /// **剪贴板本来就是最好的容器**（⌘V 直接能用，也能再粘回任何编辑器）。
    /// 编辑器里的结果面板保留，那里有空间。
    ///
    /// ## 底图从哪来
    ///
    /// 与打码同一处：冻结的整屏帧（`OverlayRedactionSource`）。
    /// 于是不额外采一次屏，也就不会把覆盖层自己拍进去。
    /// 代价是它与放大镜一样是**那一刻**的画面 —— 覆盖层期间屏幕内容不会变
    /// （鼠标事件都被覆盖层吃了），所以对识别来说没有实际影响。
    private func runTextRecognition() {
        guard let recognition = textRecognition else {
            setOCRStatus(L10n.t("这台机器上没有可用的文字识别（Vision 不可用）"))
            return
        }
        guard !recognition.isRunning else { return }
        guard !hasScrollSession, let rect = session.rect, rect.width >= 1, rect.height >= 1 else {
            setOCRStatus(L10n.t("先框出一块区域，再点识别"))
            return
        }

        let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: rect,
                                                           primaryScreenHeight: primaryScreenHeight)
        ensureLensFrames(for: quartz)
        guard let source = OverlayRedactionSource.make(selection: quartz,
                                                       displays: displayGeometries,
                                                       frames: lensFrames.mapValues(\.image)) else {
            // 冻结帧还没到（跨屏时会按需去取）。**说清楚**，别让用户以为功能坏了。
            setOCRStatus(L10n.t("还没拿到这块区域的像素 —— 稍等一下再点一次"))
            return
        }

        // 不自动消失：识别可能很久（没预热时首次约 25 秒），
        // 中途被清掉的话用户只会看到"点了没反应"。
        setOCRStatus(L10n.t("正在识别文字…"), autoClearAfter: nil)

        Task { [weak self] in
            guard let self else { return }
            await recognition.recognize(source.image)
            guard !self.isFinishing else { return }
            if case .ready = recognition.state {
                self.clipboard?.writeText(recognition.text)
                self.setOCRStatus((recognition.message ?? L10n.t("识别完成")) + L10n.t(" · 已复制到剪贴板"))
                self.logger.info("OCR 完成，文本已写进剪贴板")
            } else {
                self.setOCRStatus(recognition.message ?? L10n.t("识别失败"))
            }
        }
    }

    /// 宿主回报"刚才那一下"的结果 —— 现在只有一处用它：卡片上的「恢复购买」。
    ///
    /// ## 为什么那个动作特别需要它
    ///
    /// 卡片上三个动作里，另外两个会**开窗口**（StoreKit 的系统购买面板 / 偏好页），
    /// 用户看得见那扇窗；只有 `restore` 是**原地完成**的 —— 卡片收掉了、
    /// 覆盖层还留着，结果（成功了 / 这个账号下没有 / 连不上）全部落在这一行上。
    /// 少了它，用户看到的就是"点了没反应"。
    ///
    /// ⚠️ 颜色由调用方给（`role`）：提示行只有三档角色，而"失败"在偏好页
    /// 是危险红、在这里是琥珀 —— 那是各表面自己的事（见 `ProFeedback`）。
    public func showTransientNotice(_ text: String,
                                    role: ReadoutRole = .primary,
                                    autoClearAfter seconds: Double = 8) {
        transientNotice = ReadoutLine(text, role)
        refresh()

        transientNoticeTask?.cancel()
        transientNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.transientNotice = nil
            self.refresh()
        }
    }

    /// 更新那一行状态。`autoClearAfter` 为 `nil` 时一直留着（识别中就该一直显示）。
    private func setOCRStatus(_ text: String, autoClearAfter seconds: Double? = 8) {
        ocrStatus = text
        refresh()

        ocrStatusTask?.cancel()
        ocrStatusTask = nil
        guard let seconds else { return }
        ocrStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.ocrStatus = nil
            self.refresh()
        }
    }

    /// 准备打码预览的底图。
    ///
    /// 只在选中马赛克/模糊时做 —— 其余工具用不到，白拼一次图没有意义。
    /// 缺哪块屏的冻结帧就**整体放弃**（`nil`）：那时预览不画打码，
    /// 但导出仍会应用，所以界面必须把这件事说出来（见 `settledHintText()`）。
    private func rebuildRedactionBackdropIfNeeded() {
        guard annotationSession.usesRedaction,
              !hasScrollSession,
              let rect = session.rect, rect.width >= 1, rect.height >= 1 else {
            redactionBackdrop = nil
            return
        }
        let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: rect,
                                                           primaryScreenHeight: primaryScreenHeight)
        ensureLensFrames(for: quartz)
        redactionBackdrop = OverlayRedactionSource.make(selection: quartz,
                                                        displays: displayGeometries,
                                                        frames: lensFrames.mapValues(\.image))
    }

    /// 把选区涉及的屏都催一遍冻结帧。
    ///
    /// 放大镜只在光标所在那屏取帧，跨屏选区会缺其他屏 —— 缺一块就打不了码。
    /// 这里按需补齐，取到之后 `requestLensFrameIfNeeded` 会自己再推一次 `refresh`。
    private func ensureLensFrames(for quartz: CGRect) {
        guard let provider = lensProvider else { return }
        for display in displayGeometries where display.frame.intersects(quartz) {
            requestLensFrameIfNeeded(for: display, using: provider)
        }
    }

    /// 吸附线来源：屏幕可见区 + **与当前选区相邻的那些窗口**。
    ///
    /// ⚠️ 不能把所有窗口都丢进来。40 扇窗 × 4 条边 = 160 条线，6 点阈值下
    /// 屏幕上几乎每个位置都会落在某条线的阈值内 —— 表现是"到处都在吸"，
    /// 比不吸还难对准。**只取相关的那些，线少才吸得准。**
    private func snapTargets() -> SelectionGeometry.SnapTargets {
        var rects = NSScreen.screens.map(\.visibleFrame)
        if let current = session.rect {
            let vicinity = current.insetBy(dx: -24, dy: -24)
            for window in cachedWindows {
                let cocoa = ScreenCoordinateConversion.cocoaRect(fromQuartz: window.frame,
                                                                 primaryScreenHeight: primaryScreenHeight)
                if cocoa.intersects(vicinity) { rects.append(cocoa) }
            }
        }
        return SelectionGeometry.SnapTargets.edges(of: rects)
    }

    func overlayView(_ view: SelectionOverlayView, didChangeText text: String) {
        // 每次击键都同步进会话：这样"待输入的那一行"始终是完整内容 ——
        // 中途点工具条结算、或按 `⏎`，拿到的都是最新的一份，不会差最后一个字。
        annotationSession.updateText(text)
        refresh()
    }

    func overlayViewDidCommitText(_ view: SelectionOverlayView) {
        commitTextEditing()
    }

    func overlayViewDidCancelText(_ view: SelectionOverlayView) {
        cancelTextEditing()
    }

    func overlayViewDidRequestCancel(_ view: SelectionOverlayView) {
        // 自动滚动中按 `Esc` = **只停自动滚动**，不是把整次长截图丢掉：
        // 画面还在、已经拼好的部分也还在，接着自己滚或按 `⏎` 结束都行。
        // 再按一次 `Esc`（此时已不在自动滚动）才是取消整次长截图。
        handleEscape()
    }
}

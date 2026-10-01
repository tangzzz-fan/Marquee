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

    public enum Outcome: Sendable {
        /// - Parameter openEditor: 采集完成后要不要把图送进**编辑器窗口**。
        ///
        ///   普通截图从 ticket 20 起在覆盖层里就地完成，所以是 `false` ——
        ///   这正是用户要的"不阻断"：拖完选区按 `⏎` 直接出图，不弹任何窗口。
        ///   长截图（图放不进一屏）与工具栏上的「编辑」按钮才是 `true`。
        case completed(CaptureOutcome, openEditor: Bool)
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
    /// 放大镜取色用的整屏像素来源（ticket 10）。`nil` 时整个放大镜不出现。
    private let lensProvider: LensFrameProviding?
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
    private var isOptionDown = false
    private let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    /// 按下位置。用来区分「单击窗口」和「拖选区」，避免已落点后再点一下把选区清掉。
    private var pointerDownAt: CGPoint?
    private var dragExceededSlop = false
    private static let dragSlop: CGFloat = 4
    /// 一次 `Esc` 退出。不靠各块屏的面板各自消化，否则多屏要点好几次。
    private var keyMonitor: Any?

    private let logger = Logger(subsystem: "dev.tango.Marquee", category: "overlay")
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
    /// 鼠标正按着画一笔。用它把"画标注"的三步（按下/拖/松开）串起来。
    private var isDrawingStroke = false

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
        isOptionDown = false
        resetScroll()
        resetMagnifier()
        displayGeometries = displays.allDisplays()

        guard !displayGeometries.isEmpty,
              let height = ScreenCoordinateConversion.primaryScreenHeight(in: displayGeometries) else {
            onFinish(.completed(.failed(CaptureFailure(message: "没找到可用的显示器")),
                                openEditor: false))
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
            panel.onCancel = { [weak self] in self?.cancel() }
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
        isDrawingStroke = false
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
        // 自动滚动中按 `Esc` = 只停自动滚动，画面与已拼好的部分都留着。
        if autoScrollDriver != nil {
            stopAutoScroll()
            return
        }
        // 标注分三级退，**不会一步把整次截图丢掉**：
        //   ① 画到一半 → 丢掉这一笔
        //   ② 选了工具   → 取消工具（回到"调整选区"）
        //   ③ 其它       → 取消整次截图
        // 少了前两级的话，用户画了五个箭头想退出画标注模式，
        // 一下 `Esc` 全部作废，而这张图可能已经很难再复现。
        if isDrawingStroke || annotationSession.draft != nil {
            isDrawingStroke = false
            annotationSession.cancelStroke()
            refresh()
            return
        }
        if annotationSession.isDrawing {
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
    private func magnifierLines() -> [(text: String, color: NSColor)] {
        guard let color = sampledColor else { return [] }
        guard isOptionDown else {
            return [("按住 ⌥ 取色", ReadoutStyle.hint)]
        }
        return [(color.hexString, ReadoutStyle.normal),
                (color.rgbString, ReadoutStyle.hint),
                ("点击复制", ReadoutStyle.hint)]
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

        magnifierStatus = "已复制 \(text)"
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
                                        openEditor: false))

            case .failed(let failure):
                self.teardown()
                self.onFinish(.completed(.failed(failure), openEditor: false))
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
            self.onFinish(.completed(outcome, openEditor: true))
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

        if postEventPermission.currentPostEventPermission() != .granted,
           !postEventPermission.requestPostEventPermission() {
            autoScrollMessage = "自动滚动需要「辅助功能」授权（系统设置 → 隐私与安全性 → 辅助功能）。"
                + "也可以自己滚 —— 手动模式一样能拼长图"
            refresh()
            return
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

    private func commitRegion(saveToDisk: Bool) {
        guard !isFinishing else { return }
        guard let cocoaRect = session.rect else {
            commitWholeScreen(saveToDisk: saveToDisk)
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
            // 普通截图**一律就地完成**，不开任何窗口（要的"不阻断"就是这条）。
            // 唯一的例外是长截图：长图几千像素高放不进一屏，只能进编辑器 ——
            // 那个例外在 `finishScrollCapture` 里显式写死，不从这里走。
            self.onFinish(.completed(outcome, openEditor: false))
        }
    }

    private func commitWindow(_ window: WindowInfo, style: WindowCaptureStyle, saveToDisk: Bool) {
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
            // 普通截图**一律就地完成**，不开任何窗口（要的"不阻断"就是这条）。
            // 唯一的例外是长截图：长图几千像素高放不进一屏，只能进编辑器 ——
            // 那个例外在 `finishScrollCapture` 里显式写死，不从这里走。
            self.onFinish(.completed(outcome, openEditor: false))
        }
    }

    private func commitWholeScreen(saveToDisk: Bool) {
        guard !isFinishing else { return }
        isFinishing = true
        let save = saveRequest(for: nil, enabled: saveToDisk)
        let inline = inlineAnnotations()

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.fullScreenFlow.capture(save: save, inline: inline)
            self.teardown()
            // 普通截图**一律就地完成**，不开任何窗口（要的"不阻断"就是这条）。
            // 唯一的例外是长截图：长图几千像素高放不进一屏，只能进编辑器 ——
            // 那个例外在 `finishScrollCapture` 里显式写死，不从这里走。
            self.onFinish(.completed(outcome, openEditor: false))
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
    /// 三种情况不显示：
    /// - 还没落点（拖到一半工具条跟着晃，既干扰又没意义）
    /// - 长截图期间（那时一切操作由提示行负责，见 ticket 12）
    /// - 拿不到所在屏
    ///
    /// 具体坐标交给 `MarqueeCore.OverlayToolbar.frame`（贴下方 → 放不下翻上方 → 夹进屏幕），
    /// 那里有单测：贴边与跨屏靠肉眼试不全。
    private func toolbarPresentationIfSettled() -> OverlayToolbarPresentation? {
        guard session.isSettled, !hasScrollSession, let rect = annotationRect() else { return nil }
        let visibleFrame = NSScreen.screens.first { $0.frame.intersects(rect) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        guard let visibleFrame else { return nil }
        return OverlayToolbarPresentation(
            frame: OverlayToolbar.frame(for: rect, screenFrame: visibleFrame),
            activeTool: annotationSession.tool,
            stroke: annotationSession.style.stroke,
            lineWidth: annotationSession.style.lineWidth,
            canUndo: annotationSession.canUndo,
            canRedo: annotationSession.canRedo
        )
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

    /// 标注坐标系的**原点**（Cocoa 全局点）：选区的**视觉左上角**。
    ///
    /// ⚠️ Cocoa 的 `rect.origin` 是**左下角**（y 向上），而标注约定是"原点左上、y 向下"。
    /// 所以是 `maxY` 不是 `minY` —— 写成 `minY` 不会崩、不会报错，
    /// 只会让所有标注整体**上下镜像**，而且只在画了东西之后才看得出来。
    private func annotationOrigin() -> CGPoint? {
        guard let rect = annotationRect() else { return nil }
        return CGPoint(x: rect.minX, y: rect.maxY)
    }

    /// 把鼠标位置（Cocoa 全局点）换成标注坐标系里的点。
    private func annotationPoint(_ globalPoint: CGPoint) -> CGPoint? {
        guard let rect = annotationRect() else { return nil }
        return CGPoint(x: globalPoint.x - rect.minX, y: rect.maxY - globalPoint.y)
    }

    private func refresh() {
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
                sizeText: "\(Int(quartz.width.rounded())) × \(Int(quartz.height.rounded())) pt   /   "
                    + "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px",
                originText: "(\(Int(quartz.minX.rounded())), \(Int(quartz.minY.rounded())))",
                hoverRect: nil,
                hoverLabel: "",
                hoverCornerRadius: 10,
                // 落点后放大镜已收起，取色随之结束（那时 `⌥` 归 ticket 04 的"无阴影"）
                actionHintText: annotationSession.isDrawing
                    ? "在选区内拖动即可标注  ·  再点一次工具图标取消  ·  Esc 取消工具"
                    : "选个工具就能直接标注  ·  ⌘S 保存到磁盘  ·  ⏎ 确认  ·  Esc 取消"
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
                sizeText: "",
                originText: "",
                hoverRect: nil,
                hoverLabel: "",
                hoverCornerRadius: 12,
                hintAnchor: NSEvent.mouseLocation,
                hintText: "长截图：拖出要滚动的区域，或单击要滚动的窗口"
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
        presentation.toolbar = toolbarPresentationIfSettled()
        presentation.annotationOrigin = annotationOrigin()
        presentation.annotations = annotationSession.visibleAnnotations

        for overlay in overlays {
            overlay.view.presentation = presentation
        }
    }

    private func updateHover(at cocoaPoint: CGPoint) {
        guard session.phase == .awaitingDrag else {
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
        var hint = ""
        if locked {
            hint += "  ·  ⏎ 确认"
        }
        if isOptionDown {
            hint += "  ·  ⌥ 无阴影"
        }
        return SelectionPresentation(
            globalRect: nil,
            sizeText: "",
            originText: "",
            hoverRect: cocoaRect,
            hoverLabel: window.hoverLabel + hint,
            hoverCornerRadius: 10
        )
    }

    /// 长截图抓帧中的读数：进度 + 操作提示 + 告警。
    private func scrollPresentation(rect: CGRect?,
                                    progress: ScrollCaptureSession.Progress) -> SelectionPresentation {
        let autoScrolling = autoScrollDriver != nil
        var status: String
        if autoScrolling {
            status = "自动滚动中 · 已拼 \(progress.canvasHeight) px · \(progress.frameCount) 帧"
        } else {
            status = progress.frameCount <= 1
                ? "长截图已开始 · 往下滚"
                : "长截图 · 已拼 \(progress.canvasHeight) px · \(progress.frameCount) 帧"
        }
        if let milliseconds = progress.lastRegistrationMilliseconds {
            status += String(format: " · 配准 %.0f ms", milliseconds)
        }
        // 提示行必须跟着状态走：自动滚动期间用户不需要"自己滚"的提示，
        // 他需要知道"怎么停"。反之亦然 —— 不写这一条，第一个问题就是"怎么不动了"。
        let hint = autoScrolling
            ? "自动滚动中 · 空格停止 · Esc 停止（已拼的保留）· ⏎ 结束"
            : "继续往下滚，或按空格自动滚 · ⏎ 结束 · ⌘S 结束并保存 · Esc 取消"
        return SelectionPresentation(
            globalRect: rect,
            sizeText: "",
            originText: "",
            hoverRect: nil,
            hoverLabel: "",
            hoverCornerRadius: 10,
            isScrollCapturing: true,
            scrollStatusText: status,
            scrollHintText: hint,
            scrollWarningText: progress.warning ?? autoScrollMessage ?? ""
        )
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
        guard !isFinishing else { return }

        // 选中工具时，拖拽 = **画一笔标注**，而不是重画选区。
        // （视图不做这个判断：它只负责把"点在工具栏上"和"点在别处"分开，
        //   工具语义属于控制层 —— 视图那边多一份"什么时候算画标注"迟早跟这里对不上。）
        if annotationSession.isDrawing, !hasScrollSession {
            guard let rect = annotationRect(), rect.contains(globalPoint),
                  let local = annotationPoint(globalPoint) else {
                // 选区外按下：**什么都不做**。不偷偷重画选区（用户只是手滑了），
                // 也不画到选区外面去（会被裁掉，看起来像"工具坏了"）。
                logger.info("标注工具已选中，但落笔在选区之外 —— 忽略。要重画选区请先点掉工具或按 Esc")
                return
            }
            isDrawingStroke = true
            annotationSession.beginStroke(at: local)
            refresh()
            return
        }

        pointerDownAt = globalPoint
        dragExceededSlop = false
        if !session.isSettled {
            updateHover(at: globalPoint)
        }
    }

    func overlayView(_ view: SelectionOverlayView, draggedTo globalPoint: CGPoint) {
        guard !isFinishing else { return }

        if isDrawingStroke {
            guard let local = annotationPoint(globalPoint) else { return }
            annotationSession.updateStroke(to: local)
            refresh()
            return
        }

        guard let start = pointerDownAt else { return }
        if !dragExceededSlop {
            let distance = hypot(globalPoint.x - start.x, globalPoint.y - start.y)
            guard distance >= Self.dragSlop else { return }
            dragExceededSlop = true
            session.beginDrag(at: start)
        }
        session.updateDrag(to: globalPoint)
        // 拖拽时鼠标移动走的是 mouseDragged，不会触发 mouseMoved —— 放大镜得在这里跟
        updateMagnifier(at: globalPoint)
        refresh()
    }

    func overlayView(_ view: SelectionOverlayView, endedDragAt globalPoint: CGPoint, optionDown: Bool) {
        guard !isFinishing else { return }

        if isDrawingStroke {
            isDrawingStroke = false
            guard let local = annotationPoint(globalPoint) else { return }
            let committed = annotationSession.endStroke(at: local)
            let verdict = committed ? "已落一个" : "太短，丢弃"
            logger.info("标注收笔：\(verdict, privacy: .public)，当前共 \(self.annotationSession.annotations.count) 个")
            refresh()
            return
        }

        guard !hasScrollSession else { return }
        defer {
            pointerDownAt = nil
            dragExceededSlop = false
        }

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
    }

    func overlayView(_ view: SelectionOverlayView, nudgeBy dx: CGFloat, dy: CGFloat) {
        guard !isFinishing else { return }
        nudge(dx: dx, dy: dy)
    }

    func overlayView(_ view: SelectionOverlayView, shiftChanged isDown: Bool) {
        session.setShiftDown(isDown)
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

    private func performCommit(saveToDisk: Bool) {
        guard !isFinishing else { return }

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
            commitRegion(saveToDisk: saveToDisk)
        case .commitWindow:
            guard let window = session.settledWindow else {
                commitRegion(saveToDisk: saveToDisk)
                return
            }
            let style = WindowCaptureStyle.isolatedWindow(includeShadow: !isOptionDown)
            commitWindow(window, style: style, saveToDisk: saveToDisk)
        case .settleHoveredWindow:
            guard let window = hoveredWindow else { return }
            settleOnWindow(window)
        case .commitWholeScreen:
            commitWholeScreen(saveToDisk: saveToDisk)
        }
    }

    func overlayViewDidRequestWholeScreen(_ view: SelectionOverlayView) {
        // 选中标注工具时，双击没有意义：第一下已经算一笔了（落点 → 太短被丢弃）。
        // 真正会踩到的是"想画两笔、手快了一点"，那样第二笔会被吃掉 —— 挡掉更省事。
        guard !annotationSession.isDrawing else { return }
        if mode == .scrollCapture {
            // 长截图里双击 = "整屏开始滚"，而不是"截一张整屏"
            performCommit(saveToDisk: false)
            return
        }
        commitWholeScreen(saveToDisk: false)
    }

    func overlayViewDidToggleAutoScroll(_ view: SelectionOverlayView) {
        toggleAutoScroll()
    }

    func overlayView(_ view: SelectionOverlayView, clickedToolbarAt globalPoint: CGPoint) {
        guard !isFinishing, let bar = toolbarPresentationIfSettled(),
              let slot = OverlayToolbar.slot(at: globalPoint, in: bar.frame) else { return }
        perform(toolbarSlot: slot)
    }

    /// 工具栏每一格的动作。
    ///
    /// 「完成」/「保存」与 `⏎`/`⌘S` 走**同一套收尾通道**（`performCommit`），
    /// 「取消」与 `Esc` 走同一个 `cancel()` —— 不另起一套，否则两条路的收尾行为迟早分叉。
    private func perform(toolbarSlot slot: OverlayToolbar.Slot) {
        switch slot {
        case .tool(let tool):
            annotationSession.toggle(tool: tool)
            let current = annotationSession.tool?.rawValue ?? "无"
            logger.info("工具栏：点了工具 \(tool.rawValue, privacy: .public) → 当前选中 \(current, privacy: .public)")

        case .color(let index):
            guard AnnotationPalette.colors.indices.contains(index) else { return }
            annotationSession.style.stroke = AnnotationPalette.colors[index]

        case .lineWidth(let index):
            guard AnnotationPalette.lineWidths.indices.contains(index) else { return }
            annotationSession.style.lineWidth = AnnotationPalette.lineWidths[index]

        case .undo:
            if annotationSession.undo() {
                logger.info("工具栏：撤销 → 剩 \(self.annotationSession.annotations.count) 个标注")
            }

        case .redo:
            if annotationSession.redo() {
                logger.info("工具栏：重做 → 现在 \(self.annotationSession.annotations.count) 个标注")
            }

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

    /// 把就地画的标注打包给采集流程。
    ///
    /// `nil` = 没有标注（或没有画布）。**坐标空间用选区的点尺寸** ——
    /// 采集流程是唯一知道最终输出像素尺寸的地方，换算在那里做。
    private func inlineAnnotations() -> InlineAnnotations? {
        guard let rect = annotationRect(), !annotationSession.annotations.isEmpty else { return nil }
        return InlineAnnotations(annotations: annotationSession.annotations, pointSize: rect.size)
    }

    func overlayViewDidRequestCancel(_ view: SelectionOverlayView) {
        // 自动滚动中按 `Esc` = **只停自动滚动**，不是把整次长截图丢掉：
        // 画面还在、已经拼好的部分也还在，接着自己滚或按 `⏎` 结束都行。
        // 再按一次 `Esc`（此时已不在自动滚动）才是取消整次长截图。
        handleEscape()
    }
}

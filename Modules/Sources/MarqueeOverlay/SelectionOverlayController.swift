import AppKit
import MarqueeCore

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

    public enum Outcome: Sendable {
        case completed(CaptureOutcome)
        case cancelled
    }

    private let regionFlow: RegionCaptureFlow
    private let fullScreenFlow: FullScreenCaptureFlow
    private let windowFlow: WindowCaptureFlow
    private let windowLister: WindowListing
    private let displays: DisplayLocating
    private let onFinish: (Outcome) -> Void

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

    public init(regionFlow: RegionCaptureFlow,
                fullScreenFlow: FullScreenCaptureFlow,
                windowFlow: WindowCaptureFlow,
                windowLister: WindowListing,
                displays: DisplayLocating,
                onFinish: @escaping (Outcome) -> Void) {
        self.regionFlow = regionFlow
        self.fullScreenFlow = fullScreenFlow
        self.windowFlow = windowFlow
        self.windowLister = windowLister
        self.displays = displays
        self.onFinish = onFinish
    }

    public var isPresented: Bool { !overlays.isEmpty }

    // MARK: - 呈现 / 收场

    public func present() {
        guard !isPresented else { return }

        isFinishing = false
        session = SelectionSession()
        pointerDownAt = nil
        dragExceededSlop = false
        hoveredWindow = nil
        isOptionDown = false
        displayGeometries = displays.allDisplays()

        guard !displayGeometries.isEmpty,
              let height = ScreenCoordinateConversion.primaryScreenHeight(in: displayGeometries) else {
            onFinish(.completed(.failed(CaptureFailure(message: "没找到可用的显示器"))))
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

        // 清单与覆盖层并行：没有清单时仍可拖选区，不能串行等 SCK
        let pointerAtPresent = pointer
        Task { [weak self] in
            guard let self, !self.isFinishing else { return }
            self.cachedWindows = await self.windowLister.listWindows()
            self.updateHover(at: pointerAtPresent)
        }
    }

    private func teardown() {
        for overlay in overlays {
            overlay.panel.onCancel = nil
            overlay.view.delegate = nil
            overlay.panel.orderOut(nil)
        }
        overlays.removeAll()
        cachedWindows = []
        hoveredWindow = nil
        pointerDownAt = nil
        dragExceededSlop = false
        removeKeyMonitor()
        NSCursor.arrow.set()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 0x35 else { return event }
            MainActor.assumeIsolated {
                self?.cancel()
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - 提交

    private func commitRegion() {
        guard !isFinishing else { return }
        guard let cocoaRect = session.rect else {
            commitWholeScreen()
            return
        }
        isFinishing = true

        let quartzRect = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoaRect,
                                                               primaryScreenHeight: primaryScreenHeight)
        let geometries = displayGeometries

        Task { [weak self] in
            guard let self else { return }
            // 覆盖层**先不关**：采集时按进程排除自身窗口，
            // 立刻关窗反而可能因为窗口还没真正消失而被拍进去。
            let outcome = await self.regionFlow.capture(selection: quartzRect, displays: geometries)
            self.teardown()
            self.onFinish(.completed(outcome))
        }
    }

    private func commitWindow(_ window: WindowInfo, style: WindowCaptureStyle) {
        guard !isFinishing else { return }
        isFinishing = true
        let geometries = displayGeometries

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.windowFlow.capture(window: window,
                                                        style: style,
                                                        displays: geometries)
            self.teardown()
            self.onFinish(.completed(outcome))
        }
    }

    private func commitWholeScreen() {
        guard !isFinishing else { return }
        isFinishing = true

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.fullScreenFlow.capture()
            self.teardown()
            self.onFinish(.completed(outcome))
        }
    }

    private func cancel() {
        guard !isFinishing else { return }
        isFinishing = true
        session.cancel()
        teardown()
        onFinish(.cancelled)
    }

    // MARK: - 读数与重绘

    private func refresh() {
        let cocoaRect = session.rect
        let presentation: SelectionPresentation

        if let window = session.settledWindow {
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
                hoverCornerRadius: 10
            )
        } else if let hovered = hoveredWindow, session.phase == .awaitingDrag {
            let cocoaHover = ScreenCoordinateConversion.cocoaRect(fromQuartz: hovered.frame,
                                                                  primaryScreenHeight: primaryScreenHeight)
            presentation = windowPresentation(hovered, cocoaRect: cocoaHover, locked: false)
        } else {
            presentation = .empty
        }

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
        pointerDownAt = globalPoint
        dragExceededSlop = false
        if !session.isSettled {
            updateHover(at: globalPoint)
        }
    }

    func overlayView(_ view: SelectionOverlayView, draggedTo globalPoint: CGPoint) {
        guard !isFinishing, let start = pointerDownAt else { return }
        if !dragExceededSlop {
            let distance = hypot(globalPoint.x - start.x, globalPoint.y - start.y)
            guard distance >= Self.dragSlop else { return }
            dragExceededSlop = true
            session.beginDrag(at: start)
        }
        session.updateDrag(to: globalPoint)
        refresh()
    }

    func overlayView(_ view: SelectionOverlayView, endedDragAt globalPoint: CGPoint, optionDown: Bool) {
        guard !isFinishing else { return }
        defer {
            pointerDownAt = nil
            dragExceededSlop = false
        }

        if dragExceededSlop {
            // 松手 = 选区落点停住，等方向键微调 / ⏎ 确认。立即提交会让微调键永远走不到。
            _ = session.endDrag(at: globalPoint)
            refresh()
            return
        }

        if session.isSettled {
            return
        }

        if let window = hoveredWindow {
            // 单击窗口 = 落点停住，等 ⏎ 确认。立刻采集就没有确认过程。
            isOptionDown = optionDown
            settleOnWindow(window)
        }
    }

    func overlayView(_ view: SelectionOverlayView, movedTo globalPoint: CGPoint) {
        guard !isFinishing else { return }
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
        refresh()
    }

    func overlayViewDidRequestCommit(_ view: SelectionOverlayView) {
        guard !isFinishing else { return }
        switch session.commitAction(hasHoveredWindow: hoveredWindow != nil) {
        case .commitRegion:
            commitRegion()
        case .commitWindow:
            guard let window = session.settledWindow else {
                commitRegion()
                return
            }
            let style = WindowCaptureStyle.isolatedWindow(includeShadow: !isOptionDown)
            commitWindow(window, style: style)
        case .settleHoveredWindow:
            guard let window = hoveredWindow else { return }
            settleOnWindow(window)
        case .commitWholeScreen:
            commitWholeScreen()
        }
    }

    func overlayViewDidRequestWholeScreen(_ view: SelectionOverlayView) {
        commitWholeScreen()
    }

    func overlayViewDidRequestCancel(_ view: SelectionOverlayView) {
        cancel()
    }
}

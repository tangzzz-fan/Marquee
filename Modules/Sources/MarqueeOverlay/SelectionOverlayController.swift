import AppKit
import MarqueeCore

/// 逐屏覆盖层的调度者（ticket 03）。
///
/// 职责边界：
/// - 窗口与事件：本类（无法自动化测试）
/// - 状态迁移：`MarqueeCore.SelectionSession`（纯逻辑，有单测）
/// - 采集与拼接：`MarqueeCore.RegionCaptureFlow` / `FullScreenCaptureFlow`
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
    private let displays: DisplayLocating
    private let onFinish: (Outcome) -> Void

    private var session = SelectionSession()
    private var overlays: [(panel: SelectionOverlayPanel, view: SelectionOverlayView)] = []
    private var displayGeometries: [DisplayGeometry] = []
    /// Cocoa ↔ Quartz 的翻转枢轴（主屏高度）
    private var primaryScreenHeight: CGFloat = 0
    /// 一旦开始提交/取消，就忽略后续事件（防止连点触发两次采集）
    private var isFinishing = false

    public init(regionFlow: RegionCaptureFlow,
                fullScreenFlow: FullScreenCaptureFlow,
                displays: DisplayLocating,
                onFinish: @escaping (Outcome) -> Void) {
        self.regionFlow = regionFlow
        self.fullScreenFlow = fullScreenFlow
        self.displays = displays
        self.onFinish = onFinish
    }

    public var isPresented: Bool { !overlays.isEmpty }

    // MARK: - 呈现 / 收场

    public func present() {
        guard !isPresented else { return }

        isFinishing = false
        session = SelectionSession()
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
    }

    private func teardown() {
        for overlay in overlays {
            overlay.view.delegate = nil
            overlay.panel.orderOut(nil)
        }
        overlays.removeAll()
        NSCursor.arrow.set()
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

        if let cocoaRect, cocoaRect.width >= 1, cocoaRect.height >= 1 {
            let quartz = ScreenCoordinateConversion.quartzRect(fromCocoa: cocoaRect,
                                                               primaryScreenHeight: primaryScreenHeight)
            let scale = pixelScale(forQuartzRect: quartz)
            // 读数用与 `SelectionLayout` 相同的规则（取参与屏里最大的 scale），
            // 保证"屏幕上写的尺寸"和"实际拿到的像素"永远一致
            let pixelSize = CGSize(width: (quartz.width * scale).rounded(),
                                   height: (quartz.height * scale).rounded())
            presentation = SelectionPresentation(
                globalRect: cocoaRect,
                sizeText: "\(Int(quartz.width.rounded())) × \(Int(quartz.height.rounded())) pt   /   "
                    + "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px",
                originText: "(\(Int(quartz.minX.rounded())), \(Int(quartz.minY.rounded())))"
            )
        } else {
            presentation = .empty
        }

        for overlay in overlays {
            overlay.view.presentation = presentation
        }
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
        session.beginDrag(at: globalPoint)
        refresh()
    }

    func overlayView(_ view: SelectionOverlayView, draggedTo globalPoint: CGPoint) {
        guard !isFinishing else { return }
        session.updateDrag(to: globalPoint)
        refresh()
    }

    func overlayView(_ view: SelectionOverlayView, endedDragAt globalPoint: CGPoint) {
        guard !isFinishing else { return }
        if session.endDrag(at: globalPoint) {
            commitRegion()
        } else {
            // 面积太小（多半是误点一下）：不提交也不退出，让用户重来
            refresh()
        }
    }

    func overlayView(_ view: SelectionOverlayView, nudgeBy dx: CGFloat, dy: CGFloat) {
        guard !isFinishing else { return }
        nudge(dx: dx, dy: dy)
    }

    func overlayView(_ view: SelectionOverlayView, shiftChanged isDown: Bool) {
        session.setShiftDown(isDown)
        refresh()
    }

    func overlayViewDidRequestCommit(_ view: SelectionOverlayView) {
        guard !isFinishing else { return }
        // `⏎`：有选区就提交选区，没选区就是"整屏"意图
        if session.isSettled {
            commitRegion()
        } else {
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

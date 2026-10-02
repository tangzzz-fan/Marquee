import AppKit
import MarqueeCore
import MarqueeOverlay

/// 菜单入口被挡住时弹的那张卡片（ticket 31）。
///
/// ## 为什么不能复用覆盖层里那张
///
/// 「滚动截屏」是个**菜单项** —— 点它的时候覆盖层还没出现（覆盖层正是被这个动作
/// 叫起来的）。所以在覆盖层上画卡片这条路，对菜单入口根本不成立，得另起一个窗口。
///
/// ## 三条硬约束
///
/// 1. **不抢键盘焦点**（`.nonactivatingPanel`）。覆盖层一旦失去 key 焦点，键盘就会失效
///    —— 那是长截图那条已知限制，别在这里再加一处。
/// 2. **点别处自动收起**（`hidesOnDeactivate`），`Esc` 也能关。
///    它是一层提示，不是窗口；用户不该需要专门去"关掉"它。
/// 3. **只有一个实例**。连点两次菜单项时，旧的那张先收掉 —— 否则屏幕上会叠出两张。
@MainActor
final class ProCardPanel: NSPanel {

    private let cardContent: ProCardContent
    private let onAction: (ProCardAction) -> Void
    private var escapeMonitor: Any?

    init(content: ProCardContent,
         near point: CGPoint,
         onAction: @escaping (ProCardAction) -> Void) {
        self.cardContent = content
        self.onAction = onAction

        let size = ProCardLayout.size
        super.init(contentRect: CGRect(origin: Self.origin(near: point, size: size), size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        collectionBehavior = [.canJoinAllSpaces, .transient]

        // 材质底与覆盖层里那张保持一致（那边用的是同一档 `hudWindow`）。
        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = OverlayToolbar.cornerRadius
        effect.layer?.masksToBounds = true

        let card = ProCardHitView(content: content) { [weak self] action in
            self?.perform(action)
        }
        card.frame = effect.bounds
        effect.addSubview(card)
        contentView = effect
    }

    required init?(coder: NSCoder) { fatalError("ProCardPanel 只支持代码创建") }

    /// 呈现。**不激活应用** —— 它只是告知，不该把用户从手头的事里拽出来。
    func present() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // 53 = Esc
            self?.dismiss()
            return nil
        }
        orderFrontRegardless()
    }

    func dismiss() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        orderOut(nil)
    }

    private func perform(_ action: ProCardAction) {
        // 先收起来再回调：三个动作都会弹别的东西（系统购买面板 / 设置窗口），
        // 卡片留着会正好盖在它们该出现的位置上。
        dismiss()
        onAction(action)
    }

    /// 卡片贴在鼠标**下方**（菜单栏在屏幕顶部，上面没地方放）。
    /// 最后统一夹进屏幕 —— 与覆盖层里那张同一个套路。
    private static func origin(near point: CGPoint, size: CGSize) -> CGPoint {
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height - 8)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
                ?? NSScreen.main?.visibleFrame else { return origin }
        let margin: CGFloat = 8
        origin.x = min(max(screen.minX + margin, origin.x), screen.maxX - margin - size.width)
        origin.y = min(max(screen.minY + margin, origin.y), screen.maxY - margin - size.height)
        return origin
    }
}

/// 卡片本体：只管画 + 接点击。
///
/// 画法用的是**覆盖层里那张同一份** `ProCardRenderer` —— 两处各写一遍的话，
/// 改一个错别字就会让同一张卡片长得不一样，而用户只会觉得哪里不对劲。
@MainActor
private final class ProCardHitView: NSView {

    private let cardContent: ProCardContent
    private let onClick: (ProCardAction) -> Void

    init(content: ProCardContent, onClick: @escaping (ProCardAction) -> Void) {
        self.cardContent = content
        self.onClick = onClick
        super.init(frame: CGRect(origin: .zero, size: ProCardLayout.size))
    }

    required init?(coder: NSCoder) { fatalError("ProCardHitView 只支持代码创建") }

    override func draw(_ dirtyRect: NSRect) {
        ProCardRenderer.draw(cardContent, in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // `bounds` 的原点在 (0, 0)，所以视图局部点可以直接当卡片局部点用。
        guard let action = ProCardLayout.action(at: point, in: bounds, buttons: cardContent) else {
            return   // 点正文或空白：什么都不做（手抖一下不能变成"买了"）
        }
        onClick(action)
    }
}

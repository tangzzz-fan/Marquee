import AppKit
import MarqueeCore
import MarqueeOverlay

/// 菜单入口被挡住时弹的那张卡片（ticket 31）—— 稿子里的**载体 B**。
///
/// ## 为什么不能复用覆盖层里那张
///
/// 「滚动截屏」是个**菜单项** —— 点它的时候覆盖层还没出现（覆盖层正是被这个动作
/// 叫起来的）。所以在覆盖层上画卡片这条路，对菜单入口根本不成立，得另起一个窗口。
///
/// ## 载体 A 与载体 B 的关系（稿子 §04）
///
/// **骨架一样，宿主材质各自服从环境。**
///
/// | | 载体 A | 载体 B |
/// | --- | --- | --- |
/// | 在哪 | 覆盖层里 | 独立小面板 |
/// | 高 | 140（带微行） | **115**（无微行） |
/// | 外观 | **恒深色** | **跟随系统** |
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

        // ⚠️ 载体 B **没有微行**（稿子：「B 无此槽，高度随之 140 → 115」）——
        // 那句「esc 关闭卡片，选区保留」只在覆盖层里成立。
        let size = ProCardLayout.size(includesMicro: false)
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
        effect.layer?.cornerRadius = ProCardLayout.cornerRadius
        effect.layer?.masksToBounds = true

        let card = ProCardCanvasView(content: content) { [weak self] action in
            self?.perform(action)
        }
        card.frame = effect.bounds
        card.autoresizingMask = [.width, .height]
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
///
/// ⚠️ 它是 internal 而**不是 private**：最近截图面板里那处「就地升起」的卡片
/// 用的是同一块视图（见 `RecentCapturesPanelController`）。
/// 那张卡片不进独立窗口（它压在列表下沿、面板不变高），所以只能复用这一块，
/// 不能复用包着它的那个 `NSPanel`。
///
/// ## 三态与"松手才算"
///
/// 稿子 §06 给了**默认 / 悬停 / 按下**三档，这里实现的是最朴素也最不容易错的那一种：
/// 按下只记状态、**松手在同一个按钮上才算数**（拖出去再松手 = 我改主意了）。
/// 少了悬停与按下，用户点一下看不到任何变化，结论就是"这张卡片点不动"。
@MainActor
final class ProCardCanvasView: NSView {

    private let cardContent: ProCardContent
    /// 这一块画的是载体 A（带微行）还是载体 B（无微行）。
    ///
    /// 最近截图面板里那处「就地升起」用的是**无微行**那一档：那时没有选区，
    /// 「选区保留」这句话不成立。
    private let includesMicro: Bool
    private let onClick: (ProCardAction) -> Void

    private var hoveredAction: ProCardAction?
    private var pressedAction: ProCardAction?
    private var trackingArea: NSTrackingArea?

    init(content: ProCardContent,
         includesMicro: Bool = false,
         onClick: @escaping (ProCardAction) -> Void) {
        self.cardContent = content
        self.includesMicro = includesMicro
        self.onClick = onClick
        super.init(frame: CGRect(origin: .zero,
                                 size: ProCardLayout.size(includesMicro: includesMicro)))
    }

    required init?(coder: NSCoder) { fatalError("ProCardCanvasView 只支持代码创建") }

    /// 这一块自己的外观。载体 B **跟随系统**（`ProCardPanel` 里那层材质也是），
    /// 所以颜色要按它现取 —— 缓存的话，切到深色之后这张卡片还是浅色的。
    private var theme: ChromePalette.Theme {
        ChromePalette.Theme.resolved(for: effectiveAppearance)
    }

    private var layout: ProCardLayout.Content {
        ProCardRenderer.layout(for: cardContent, in: bounds, includesMicro: includesMicro)
    }

    override func draw(_ dirtyRect: NSRect) {
        ProCardRenderer.draw(cardContent,
                             layout: layout,
                             in: bounds,
                             theme: theme,
                             hovered: hoveredAction,
                             pressed: pressedAction)
    }

    // MARK: - 鼠标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.mouseEnteredAndExited` 与 `.mouseMoved` 要一起给：前者是"手在不在"，
        // 后者是"手在哪儿"。只给后者的话，悬停态有"进去"没有"出来"。
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                            .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(action(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        setPressed(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // 按下**只记状态**，不执行 —— 松手在同一个按钮上才算。
        // 原先按下即执行，于是"按下去又拖开"也会真的跑一遍购买入口。
        setPressed(action(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let released = action(at: convert(event.locationInWindow, from: nil))
        let started = pressedAction
        setPressed(nil)
        // 点正文或空白：什么都不做（手抖一下不能变成"买了"）。
        // 拖出去再松手：也什么都不做 —— 那是"我改主意了"。
        guard let released, released == started else { return }
        onClick(released)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// 某个点落在哪个按钮上。**用与绘制同一份 `layout`**。
    private func action(at localPoint: CGPoint) -> ProCardAction? {
        ProCardLayout.action(at: localPoint, in: bounds, layout: layout, buttons: cardContent)
    }

    private func setHovered(_ action: ProCardAction?) {
        guard hoveredAction != action else { return }
        hoveredAction = action
        needsDisplay = true
    }

    private func setPressed(_ action: ProCardAction?) {
        guard pressedAction != action else { return }
        pressedAction = action
        needsDisplay = true
    }
}

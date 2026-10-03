import AppKit
import ImageIO
import MarqueeCore
import MarqueeHistory

/// 菜单栏里的「最近截图」面板（ticket 16，设计稿第 2 轮 D 块）。
///
/// ## 它是「最近」，不是「图库」
///
/// 要解决的是"**刚**截的图找不到了"。独立图库窗口会带来窗口管理、搜索、分组、
/// 拖拽导出 —— 那是另一个产品。所以界限不靠文案守，靠**结构**守：
/// 没有搜索框、没有日期分组、没有排序与筛选、没有多选、没有放大查看，
/// 而且**没有滚动条**（稿子：「618 pt 在任一 Mac 上放得下，所以不需要滚动条 ——
/// 一个不会滚动的东西，看起来就不像图库」）。
///
/// 于是面板高度完全由**条数**决定（`RecentPanel.panelHeight`），
/// 放不下就少显示几行（`visibleRowCount`），而不是让它滚。
///
/// ## 外壳用系统的 popover
///
/// 稿子画的是一个 340 宽、10 点圆角、1px 描边、带一枚 12 × 6 舌尖和一套投影的面板。
/// **这些全部由 `NSPopover` 提供**：材质、圆角、舌尖、投影、点外面自动收起、Esc 收起。
///
/// 这是一个**刻意的选择**：自己拿 `NSPanel` 画那块外壳，等于要重新实现
/// 上面那一整列行为（尤其是"点别处就收起来"—— 它要么靠 `hidesOnDeactivate`，
/// 要么要装一对全局/局部鼠标监视器，两条路都有边界情况）。
/// 而 popover 正是 macOS 对这一件东西的官方实现 —— 稿子画的那些，
/// 本来就是照着一个 popover 画的。
///
/// ⚠️ 换来的唯一代价：面板的底是**系统材质**而不是那个纯色 `--c-panel`。
/// 这与覆盖层工具条是同一个做法（那边也用 `ChromeMaterial`），不是新开的口子。
///
/// ## 缩略图直接读原图，不走"先加载整图再缩"
///
/// 一张 5K 的全屏 PNG 解码出来是几十 MB，十二张就是几百 MB ——
/// 面板一打开就会卡住。`CGImageSourceCreateThumbnailAtIndex` 是为此设计的：
/// 它只解码到目标尺寸，代价与目标大小成正比，与源图大小无关。
@MainActor
final class RecentCapturesPanelController: NSViewController {

    struct Actions {
        /// 复制到剪贴板
        var onCopy: (CaptureHistoryEntry) -> Void
        /// 重新进编辑器（用历史里的**原图 + 标注**）
        var onEdit: (CaptureHistoryEntry) -> Void
        /// 删掉这一条（文件进废纸篓）
        var onDelete: (CaptureHistoryEntry) -> Void
    }

    private let store: CaptureHistoryStore
    private let actions: Actions
    /// 当前全屏截图快捷键。空态那句要用它 —— 稿子 §02：
    /// 「同一个 ⌃Q，出现在三个地方，只有一个来源」。
    private let currentShortcut: () -> KeyCombo
    /// 点「升级到 Pro」时要升起的那张卡片。`nil` = 这一格不该出现（已经是 Pro）。
    private let upgradeCard: () -> ProCardContent?
    private let onUpgradeAction: (ProCardAction) -> Void

    // MARK: 视图

    private let titleLabel = NSTextField(labelWithString: L10n.t("最近截图"))
    private let hintLabel = NSTextField(labelWithString: RecentPanel.copyHint)
    private let list = NSStackView()
    private let emptyBox = NSView()
    private let emptyTitle = NSTextField(labelWithString: RecentPanel.emptyTitle)
    private let emptySubtitle = NSTextField(labelWithString: "")
    private let emptyIcon = NSImageView()
    private let footerBar = NSView()
    private let footerSeparator = NSTextField(labelWithString: RecentPanel.footerSeparator)
    private let footerPrefix = NSTextField(labelWithString: "")
    private let footerSuffix = NSTextField(labelWithString: "")
    private let footerAction = ChromeTextButton()
    /// 列表区那一块的高度约束。**必须显式给** —— 见 `body()` 里的说明。
    private var bodyHeight: NSLayoutConstraint?
    private var panelHeight: NSLayoutConstraint?
    private var upgradeCardView: ProCardCanvasView?
    private var escapeMonitor: Any?

    init(store: CaptureHistoryStore,
         actions: Actions,
         currentShortcut: @escaping () -> KeyCombo,
         upgradeCard: @escaping () -> ProCardContent?,
         onUpgradeAction: @escaping (ProCardAction) -> Void) {
        self.store = store
        self.actions = actions
        self.currentShortcut = currentShortcut
        self.upgradeCard = upgradeCard
        self.onUpgradeAction = onUpgradeAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecentCapturesPanelController 只支持代码创建")
    }

    // MARK: - 搭起来

    override func loadView() {
        // 根视图兼职"外观变了通知一声"（`NSViewController` 没有那条回调）——
        // 这一页上的字色由 `applyTheme()` 统一下发，没人通知就永远是第一次那套。
        let container = AppearanceAwareView()
        container.onAppearanceChange = { [weak self] in self?.applyTheme() }
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleBar(), body(), footerBarView()])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let width = container.widthAnchor.constraint(equalToConstant: RecentPanel.width)
        let height = container.heightAnchor.constraint(
            equalToConstant: RecentPanel.panelHeight(rowCount: 0, showsFooter: true))
        panelHeight = height
        NSLayoutConstraint.activate([
            width, height,
            // 上下各留 1 点 —— 稿子那块面板的 340 × H 里含 1px 描边（上下两处）。
            // 外壳（popover）自己已经有一圈边，所以这里只**把位置让出来**，不画第二条。
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: RecentPanel.borderWidth),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                          constant: -RecentPanel.borderWidth),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    /// 标题带：左「最近截图」，右一行常驻小字。
    ///
    /// ⚠️ **空态时那行小字不出现** —— 那时没有缩略图可以点，
    /// 写在那儿只会让人去找一个不存在的东西（稿子 §03 的空态图上它也确实不在）。
    private func titleBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: RecentPanel.titleBarHeight).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 11)
        for label in [titleLabel, hintLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor,
                                                constant: RecentPanel.titleBarPadding),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor,
                                                constant: -RecentPanel.titleBarPadding),
            hintLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                               constant: 8),
        ])
        return bar
    }

    /// 列表区：要么是若干行，要么是一块空态。**两者占同一块地方**。
    ///
    /// ⚠️ 这一块的高度**显式写死**（`RecentPanel.bodyHeight`），不让它由内容撑。
    /// 让它撑的话，空态那一档会塌成 0（列表里一行都没有），
    /// 于是面板的总高与 `panelHeight` 对不上 —— 而表现只是"空面板矮了一截"。
    private func body() -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        let height = box.heightAnchor.constraint(equalToConstant: RecentPanel.emptyBlockHeight)
        height.isActive = true
        bodyHeight = height

        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false

        emptyIcon.image = NSImage(systemSymbolName: RecentPanel.emptyIconSymbol,
                                  accessibilityDescription: nil)
        emptyIcon.contentTintColor = .secondaryLabelColor
        emptyIcon.symbolConfiguration = .init(pointSize: RecentPanel.emptyIconSize, weight: .regular)
        emptyTitle.font = .systemFont(ofSize: 12, weight: .medium)
        emptySubtitle.font = .systemFont(ofSize: 11)
        let emptyStack = NSStackView(views: [emptyIcon, emptyTitle, emptySubtitle])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = RecentPanel.emptyGap
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyBox.addSubview(emptyStack)

        for child in [list, emptyBox] {
            child.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: box.topAnchor),
                child.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            ])
        }
        // 列表左右各留 5 点：**悬停底**因此离面板边 5 点（行自己再缩 5，缩略图才落在 10 上）。
        // 两个 5 都要有，只留一个必错其一 —— 见 `RecentPanel.listPadding` 的文档。
        list.leadingAnchor.constraint(equalTo: box.leadingAnchor,
                                      constant: RecentPanel.listPadding).isActive = true
        list.trailingAnchor.constraint(equalTo: box.trailingAnchor,
                                       constant: -RecentPanel.listPadding).isActive = true
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: emptyBox.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyBox.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: emptyBox.leadingAnchor,
                                                constant: 12),
        ])
        return box
    }

    /// 底部那一行。**免费版才有** —— 已购买时整条不出现，面板高度随之减 30。
    private func footerBarView() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: RecentPanel.footerHeight).isActive = true

        footerPrefix.font = .systemFont(ofSize: 11)
        footerSuffix.font = .systemFont(ofSize: 11)
        footerSeparator.font = .systemFont(ofSize: 11)

        footerAction.emphasis = .accent
        footerAction.title = RecentPanel.footerAction
        footerAction.onActivate = { [weak self] in self?.toggleUpgradeCard() }

        // ⚠️ 这条约束是"三段加起来别超过 320 点"（面板 340 − 左右各 10）。
        // 它**只有英文会撞上**：中文三段加起来 254，而原来的英文那句是 370。
        // 谁把文案改长了，`LocalizationScanTests` 里那条按真字体量的断言会先红。
        let row = NSStackView(views: [footerPrefix, footerSeparator, footerAction, footerSuffix])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = RecentPanel.footerGap
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor,
                                         constant: RecentPanel.footerPadding),
            row.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor,
                                          constant: -RecentPanel.footerPadding),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        // 顶部那条发丝线：稿子 `.rc__ft{border-top:1px solid var(--c-hair)}`。
        // 它同时是"底部这一行不是列表的一部分"的唯一标记。
        let line = ChromeSeparator()
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: bar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        return bar
    }

    // MARK: - 重读

    /// 重新读一遍索引，重建列表与面板高度。
    func reload() {
        dismissUpgradeCard()
        list.arrangedSubviews.forEach {
            list.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        // 高度先夹进屏幕可用高度，再决定显示几条 —— 稿子要的是"不要滚动条"。
        let available = Self.availableHeight()
        let limit = store.limit
        let showsFooter = limit != nil
        let all = store.entries()
        let rows = min(all.count,
                       RecentPanel.visibleRowCount(available: available, showsFooter: showsFooter))
        let entries = Array(all.prefix(rows))

        for (index, entry) in entries.enumerated() {
            list.addArrangedSubview(row(for: entry, index: index))
        }
        list.isHidden = entries.isEmpty
        emptyBox.isHidden = !entries.isEmpty
        hintLabel.isHidden = entries.isEmpty
        emptySubtitle.stringValue = RecentPanel.emptySubtitle(shortcut: currentShortcut())

        footerBar.isHidden = !showsFooter
        if let limit {
            footerPrefix.stringValue = RecentPanel.footerPrefix(limit: limit)
            footerSuffix.stringValue = RecentPanel.footerSuffix
        }

        // 高度三件事一起定，**顺序不能换**：先定列表区、再定总高（总高由它算出来）。
        // 反过来写的话，改一处忘一处，表现是"面板底部多出一块或差一块"。
        bodyHeight?.constant = RecentPanel.bodyHeight(rowCount: entries.count)
        let natural = RecentPanel.panelHeight(rowCount: entries.count, showsFooter: showsFooter)
        panelHeight?.constant = min(natural, available)
        applyTheme()
    }

    /// 面板所在那块屏的可用高度（扣掉菜单栏与 Dock）。
    ///
    /// 取鼠标所在那块屏 —— 用户是点菜单栏图标把它叫起来的，
    /// 那一刻鼠标就在那块屏上。取不到就退回主屏，再不行给一个保守值。
    private static func availableHeight() -> CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        return screen?.visibleFrame.height ?? 700
    }

    private func row(for entry: CaptureHistoryEntry, index: Int) -> NSView {
        let view = ChromeRecentRow(
            entry: entry,
            thumbnail: Self.thumbnail(at: store.directoryURL
                .appendingPathComponent(entry.originalFileName)),
            // 第一条不画上面那条线：画了它就会紧贴在标题带下面，像标题带的下边框。
            showsTopHairline: index > 0,
            onCopy: { [weak self] in self?.actions.onCopy(entry) },
            onEdit: { [weak self] in self?.actions.onEdit(entry) },
            onDelete: { [weak self] in
                self?.actions.onDelete(entry)
                self?.reload()
            })
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: RecentPanel.rowHeight).isActive = true
        return view
    }

    /// 按目标尺寸解码，**不解码整图**（见类型文档）。
    private static func thumbnail(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(RecentPanel.thumbnailSize.width,
                                                      RecentPanel.thumbnailSize.height) * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        // ⚠️ 逻辑尺寸给**真实像素尺寸**（而不是那块 48 × 34 的展示尺寸）：
        // 缩略图是按"填满并居中裁切"画的，那需要知道源图的比例。
        // 给成展示尺寸等于告诉它"这张图就是 48:34"，于是 16:9 的图会被压扁。
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: - 就地在面板里升起的卡片

    /// 点「升级到 Pro」：**不主动弹**，点了才出现（稿子 §04）。
    private func toggleUpgradeCard() {
        if upgradeCardView != nil {
            dismissUpgradeCard()
            return
        }
        guard let content = upgradeCard() else { return }

        let card = ProCardCanvasView(content: content) { [weak self] action in
            self?.dismissUpgradeCard()
            self?.onUpgradeAction(action)
        }
        view.addSubview(card)
        upgradeCardView = card
        layoutUpgradeCard()

        // 面板长到装得下它 —— 稿子说"面板不变高"，那是在它画的满 12 行那一屏上成立；
        // 行数少时两条路都不好（卡片露到面板外 / 压住标题带），所以宁可让它长够。
        let needed = max(panelHeight?.constant ?? 0, RecentPanel.upgradeCardMinimumPanelHeight)
        panelHeight?.constant = min(needed, Self.availableHeight())

        // Esc 收起这张卡片。装监视器只在它出现期间 —— 常驻一个监视器会连别处的 Esc 一起吃掉。
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // 53 = Esc
            self?.dismissUpgradeCard()
            return nil
        }
    }

    private func dismissUpgradeCard() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        upgradeCardView?.removeFromSuperview()
        upgradeCardView = nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutUpgradeCard()
    }

    private func layoutUpgradeCard() {
        guard let card = upgradeCardView else { return }
        card.frame = RecentPanel.upgradeCardFrame(inPanel: view.bounds)
    }

    // MARK: - 外观

    /// 颜色**每次现取**，不缓存 —— 外观切换时缓存的那份不会跟着变，
    /// 而"切了深色之后这一页还有几行字是黑的"极难联想到原因。
    ///
    /// 取的是**根视图**的 `effectiveAppearance`：这些标签都是它的子孙，
    /// 外观是继承下来的，从根上取与从每个标签上取是同一个值。
    private func applyTheme() {
        let palette = ChromePalette.Theme.resolved(for: view.effectiveAppearance)
        titleLabel.textColor = palette.label.nsColor
        for label in [hintLabel, footerSeparator, footerPrefix, footerSuffix, emptySubtitle] {
            label.textColor = palette.label2.nsColor
        }
        emptyTitle.textColor = palette.label.nsColor
        emptyIcon.contentTintColor = palette.label2.nsColor
    }
}

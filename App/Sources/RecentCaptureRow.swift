import AppKit
import MarqueeCore
import MarqueeHistory

/// 最近截图面板里的一行。
///
/// ## 这一行的四段（从左到右）
///
/// ```
/// [缩略图 48×34] 10 [时间 12 / 尺寸 11 mono] …… [编辑][删除]
/// ```
///
/// 四段的矩形**全部由 `RecentPanel.rowLayout` 算**（Core，有断言）——
/// 这里只负责把子视图摆到那些矩形上、按状态上色。
/// 算式写两份的话，"量出来的位置"与"画出来的位置"迟早分叉，
/// 而比分叉更糟的是：那种错只有几点，肉眼看不出来。
///
/// ## 缩略图**就是按钮**
///
/// 稿子 §02 把这件事列成"全块最重要的一件事"，并且要求**三条证据同时给**：
/// ① 标题带右侧常驻小字「点缩略图 = 复制」；② 悬停时缩略图描边转蓝并浮出一枚复制徽章；
/// ③ 按下时图面压暗、徽章变实心。三条分别在 `RecentCapturesPanelController`
/// （①）、`ChromeThumbnailButton`（②③）与本视图（行悬停的底）里。
///
/// ⚠️ **不靠 tooltip**：悬停提示要等、会飘，而这是一个高频动作。
@MainActor
final class ChromeRecentRow: ChromeControlView {

    private let thumbnail = ChromeThumbnailButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let editButton = ChromeTextButton()
    private let deleteButton = ChromeTextButton()

    /// 第一行上面那条发丝线要不要画。
    ///
    /// 稿子：`.rt+.rt{box-shadow:inset 0 1px 0 var(--c-hair)}` —— 它是"两条行之间"的线，
    /// 所以**第一条不画**（画了它就会紧贴在标题带下面，看起来像标题带的下边框）。
    private let showsTopHairline: Bool

    private var actions: [ChromeTextButton] { [editButton, deleteButton] }

    init(entry: CaptureHistoryEntry,
         thumbnail image: NSImage?,
         showsTopHairline: Bool,
         onCopy: @escaping () -> Void,
         onEdit: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.showsTopHairline = showsTopHairline
        super.init(frame: .zero)

        thumbnail.image = image
        thumbnail.onActivate = onCopy
        // ⚠️ 悬停提示是**补充**，不是那两个能力的说明 —— 稿子特意写明了
        // 「不靠 tooltip：悬停提示要等、会飘，而这是高频动作」。
        // 真正承担"图是按钮"这件事的是标题带那行小字、悬停的蓝环与那枚徽章。
        thumbnail.toolTip = L10n.t("点击复制到剪贴板")
        // VoiceOver 念的是这个（tooltip 不一定会被念到）。两者刻意分开：
        // 一个是"用鼠标的话点这里"，一个是"这一格是干什么的"。
        thumbnail.accessibilityLabel = L10n.t("复制到剪贴板")

        timeLabel.stringValue = RecentPanel.rowDate(entry.capturedAt)
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.lineBreakMode = .byTruncatingTail

        detailLabel.stringValue = RecentPanel.rowDetail(pixelSize: entry.pixelSize,
                                                        annotationCount: entry.annotationCount)
        // ⚠️ `monospacedDigitSystemFont` 而不是全等宽字体：这一行里有汉字
        //（「个标注」），全等宽对汉字没有对应字形、会掉回另一种字体，
        // 于是中英混排的间距看着更乱。等宽数字就够 —— 与覆盖层的读数框同一档做法。
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        detailLabel.lineBreakMode = .byTruncatingTail

        editButton.title = L10n.t("编辑")
        editButton.onActivate = onEdit
        editButton.toolTip = L10n.t("在编辑器里打开（原有的标注仍可编辑）")
        deleteButton.title = L10n.t("删除")
        deleteButton.onActivate = onDelete
        // 这句要说得出**去处**：用户真正的顾虑是"删了还能不能找回来"。
        // 现在文件进废纸篓，所以这句话是"移入废纸篓"，而不是旧版的"一起清掉"。
        deleteButton.toolTip = L10n.t("从历史里删掉 · 文件移入废纸篓")

        for view in [timeLabel, detailLabel] {
            view.isSelectable = false
            addSubview(view)
        }
        addSubview(thumbnail)
        actions.forEach { addSubview($0) }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ChromeRecentRow 只支持代码创建") }

    // MARK: - 摆位

    // ⚠️ 坐标**不翻转**（AppKit 默认，y 向上）—— `RecentPanel.rowLayout` 算出来的矩形
    // 就是按这个约定给的，视图与算式共用同一套方向。
    override func layout() {
        super.layout()
        let layout = RecentPanel.rowLayout(in: bounds, actionWidths: actions.map(\.intrinsicContentSize.width))
        thumbnail.frame = layout.thumbnail
        timeLabel.frame = layout.time
        detailLabel.frame = layout.detail
        // `rowLayout` 给出的动作是**从右往左**排的（`actions[0]` 最右），
        // 而这里的两个按钮在数组里是 [编辑, 删除] —— 所以要反着取。
        for (index, button) in actions.enumerated() {
            let rect = layout.actions[layout.actions.count - 1 - index]
            button.frame = rect
        }
    }

    // MARK: - 悬停

    /// 行一悬停：整行铺一层底，**同时**把那一层"传"给两个动作。
    ///
    /// 稿子：`.rt.is-hover .btn--mini{background:var(--c-ghost)}` ——
    /// 「整行一起亮，不是各亮各的」。按钮自己不知道行有没有被悬停，所以由行告诉它们。
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        syncActionHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        syncActionHighlight()
    }

    private func syncActionHighlight() {
        actions.forEach { $0.rowHighlighted = isHovered }
    }

    // MARK: - 画

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme
        if isHovered {
            fill(bounds, palette.rowHover, radius: RecentPanel.rowCornerRadius)
        }
        // 发丝线画在**悬停底之上** —— 稿子里它是 `inset box-shadow`，
        // 而 inset 阴影本来就是画在背景之上的。画反了的话，悬停那一行会把上下两条线吃掉，
        // 看起来像"这一行变高了"。
        if showsTopHairline {
            palette.hairline.nsColor.setFill()
            NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let palette = ChromePalette.Theme.resolved(for: effectiveAppearance)
        timeLabel.textColor = palette.label.nsColor
        detailLabel.textColor = palette.label2.nsColor
    }
}

// MARK: - 缩略图（它就是按钮）

/// 一行左边那张 48 × 34 的图 —— **它本身就是一个按钮**。
///
/// 三种状态（稿子 §04 的"三步"）：
///
/// | 状态 | 图 | 描边 | 徽章 |
/// | --- | --- | --- | --- |
/// | 常态 | 原图，圆角裁切 | 发丝线 1pt（内） | 不出现 |
/// | 悬停 | 同上 | 蓝环 2pt（骑在边上） | 浮出（`--c-fill`） |
/// | 按下 | 压暗 38% | 同上 | 变实（`--c-fill-p`） |
///
/// ⚠️ **徽章画在 bounds 之外**（右上角外扩 5 点），所以必须关掉默认裁剪
/// （`NSView` 默认会把绘制裁到自己 bounds 内）。没关的话它会被切掉一半 ——
/// 而"切掉一半"看起来像徽章本来就长这样。
@MainActor
final class ChromeThumbnailButton: ChromeControlView {

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var onActivate: (() -> Void)?
    /// 无障碍标签由外面按上（自绘控件不知道自己要干什么）。
    var accessibilityLabel: String? {
        didSet { setAccessibilityLabel(accessibilityLabel) }
    }

    override var wantsDefaultClipping: Bool { false }
    override var intrinsicContentSize: NSSize { RecentPanel.thumbnailSize }

    private var box: CGRect {
        CGRect(x: (bounds.width - RecentPanel.thumbnailSize.width) / 2,
               y: (bounds.height - RecentPanel.thumbnailSize.height) / 2,
               width: RecentPanel.thumbnailSize.width,
               height: RecentPanel.thumbnailSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme
        let frame = box

        // ① 图面。圆角裁切 + **按比例填满**（过长的图居中裁切，两端各留不出来的部分）——
        //    `draw(in:)` 直接拉伸会把 16:9 的图压扁，而那看起来只是"缩略图有点变形"。
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: RecentPanel.thumbnailCornerRadius,
                     yRadius: RecentPanel.thumbnailCornerRadius).addClip()
        if let image {
            let size = image.size
            if size.width > 0, size.height > 0 {
                let scale = max(frame.width / size.width, frame.height / size.height)
                let filled = CGSize(width: size.width * scale, height: size.height * scale)
                image.draw(in: CGRect(x: frame.midX - filled.width / 2,
                                      y: frame.midY - filled.height / 2,
                                      width: filled.width, height: filled.height))
            }
        }
        // ② 按下：图面压暗。稿子：`rgba(0,0,0,.38)`。
        //    它是"点完就是剪贴板里那张图"这一下的唯一反馈。
        if isPressed {
            RGB(hex: 0x000000, alpha: RecentPanel.thumbnailPressDim).nsColor.setFill()
            frame.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // ③ 描边。常态是**内**描边的发丝线；悬停/按下时换成**骑在边上**的蓝环
        //    （稿子：`border-color:--c-fill` + `box-shadow:0 0 0 1px --c-fill`，
        //     合起来是一条 2 点的环）。骑边画法不占图面，只多出外面那 1 点。
        if isHovered || isPressed {
            let ring = NSBezierPath(roundedRect: frame,
                                    xRadius: RecentPanel.thumbnailCornerRadius,
                                    yRadius: RecentPanel.thumbnailCornerRadius)
            ring.lineWidth = RecentPanel.thumbnailRingWidth
            palette.fill.nsColor.setStroke()
            ring.stroke()
        } else {
            let border = NSBezierPath(
                roundedRect: frame.insetBy(dx: RecentPanel.thumbnailBorderWidth / 2,
                                           dy: RecentPanel.thumbnailBorderWidth / 2),
                xRadius: RecentPanel.thumbnailCornerRadius,
                yRadius: RecentPanel.thumbnailCornerRadius)
            border.lineWidth = RecentPanel.thumbnailBorderWidth
            palette.hairline.nsColor.setStroke()
            border.stroke()
        }

        // ④ 复制徽章。位置由 Core 给（行里也是拿同一份算命中区）。
        guard isHovered || isPressed else { return }
        let badge = RecentPanel.copyBadgeInThumbnail
        fill(badge, isPressed ? palette.fillPressed : palette.fill,
             radius: RecentPanel.copyBadgeCornerRadius)
        drawSymbol("square.on.square", in: badge, tint: RGB(hex: 0xFFFFFF),
                   pointSize: RecentPanel.copyBadgeIconSize)
    }

    // MARK: 按下 / 松开

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        guard inside else { return }
        onActivate?()
    }

    // MARK: 无障碍（自绘的入场费）

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }
}

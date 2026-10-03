import AppKit
import MarqueeCore

/// 常规窗口（偏好设置 / 最近截图 / 菜单栏面板）里那几件控件的**画法**。
///
/// ## 为什么是自绘，不用系统控件
///
/// 设计稿 §01 给的是这几个数：开关 **38 × 22 / 钮 18**、分段控件 **24 高 / 选中段=device 键帽材质**、
/// 滑块 **150 × 24 / 轨 4 / 钮 14（已选段填蓝）**、标签条 **28 高 / 选中段=device 软底+描边**。
///
/// 这些用现成控件**一个都够不着**：`NSSegmentedControl` 的高度与圆角由系统定、
/// 它的"选中段"只能填系统强调色；`NSSlider` 的轨是系统画的一段凹槽，没有"已选部分填色"；
/// macOS 也没有公开的 `NSSwitch`。所以只能自己画。
///
/// ## 代价：**无障碍要自己写**
///
/// 换成自绘之后，`NSButton` 白送的那些 `accessibilityRole` / `accessibilityValue` /
/// `accessibilityPerformPress` 全都没了 —— 而"用 VoiceOver 的人点不到这个开关"
/// 不会崩、不会报错，只会让一部分用户用不了。所以每一件控件都显式实现了这几个。
/// **这是自绘的入场费，不是可选项。**
///
/// ## 三条共同纪律
///
/// 1. **颜色在 `draw` 里现取**（`theme` 是计算属性），不缓存 —— 外观切换时缓存的那份不会跟着变。
/// 2. **外观一变就重画**（`viewDidChangeEffectiveAppearance`）：深色下画的东西搬到浅色下
///    不会自己变，而"切了外观之后有个控件还是旧的"极难联想到原因。
/// 3. **几何全部来自 `ChromeControl`（Core）** —— 那边有断言钉着"钮在轨内""钮比轨粗"这些不变量。

// MARK: - 基类

/// 自绘控件的共同底座：外观、悬停/按下、无障碍。
///
/// ⚠️ 坐标**不翻转**（AppKit 默认，y 向上）。这几件控件都是水平排布的，
/// 翻转带来的收益（"按从上到下的顺序读"）在这里用不上，
/// 而混用两套 y 方向是这个项目里已经记过前科的坑。
@MainActor
class ChromeControlView: NSView {

    /// 值变了（用户操作导致）。**只由用户操作触发**，程序设值时不调 ——
    /// 否则"加载偏好"那一步会把每一页的默认值都写一遍盘。
    var onChange: (() -> Void)?

    /// 当前该用的那一套色板。
    ///
    /// ⚠️ **计算属性，不是缓存**：外观切换时缓存的那一份不会跟着变，
    /// 而"切了深色之后这几行字还是黑的"会被当成"系统 bug"。
    var theme: ChromePalette.Theme { .resolved(for: effectiveAppearance) }

    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    override var isOpaque: Bool { false }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.mouseMoved` 也要：分段控件那种"一段一段"的东西，只知道自己被悬停
        // 是不够的 —— 它要知道**是哪一段**。悬停的判定统一在这里做，
        // 子类只需要覆写 `hoverChanged(at:)`。
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved,
                                            .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverChanged(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverChanged(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        hoverChanged(at: nil)
    }

    /// 鼠标在这件控件里移动了（`nil` = 出去了）。**默认什么都不做。**
    ///
    /// 只有"内部还分成几块"的控件需要它（分段控件的每一段、标签条的每一格）——
    /// 而那些内部块的位置是**画的时候才算**的，所以它们得在绘制之后才能回答"鼠标在哪一块上"。
    func hoverChanged(at point: CGPoint?) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// 无外观依赖的矩形填充。
    func fill(_ rect: CGRect, _ color: RGB, radius: CGFloat) {
        color.nsColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// 画一个图标。取图与缓存**在 Core**（`ChromeSymbol`）——
    /// 那三条容易写漏的规则（单调渲染 / 缓存带外观 / 颜色进配置）只留一份。
    func drawSymbol(_ name: String,
                    in rect: CGRect,
                    tint: RGB,
                    pointSize: CGFloat = ChromeControl.tabIconSize) {
        ChromeSymbol.draw(name, in: rect,
                          pointSize: pointSize,
                          color: tint.nsColor,
                          appearance: effectiveAppearance)
    }

    func stroke(_ rect: CGRect, _ color: RGB, radius: CGFloat, width: CGFloat = 1) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = width
        color.nsColor.setStroke()
        path.stroke()
    }

    func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}

/// 一块「外观变了要通知我」的容器。
///
/// 为什么需要它：`viewDidChangeEffectiveAppearance` 是 **`NSView`** 的，
/// 而最近截图面板是一堆系统控件（标签、图标）拼的 —— 它们的颜色由控制器统一下发，
/// 得有人告诉控制器"外观变了"。
/// `NSViewController` 没有这条回调，所以让它的根视图兼职。
@MainActor
final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

// MARK: - 开关

/// 三处布尔项用的开关。稿子 §01：「38 × 22 · 钮 18」，开 = 轨填 `--c-fill`。
///
/// 「三态」里没有第三种 —— 稿子原话：「开关 · 两态（38 × 22，**没有第三态**）」。
/// 「正在忙」之类的中间态由**说明句**表达，不由开关变形表达。
@MainActor
final class ChromeSwitch: ChromeControlView {

    /// 程序设值走这里（`loadAll` 用）。**不触发 `onChange`**。
    var isOn: Bool = false {
        didSet { if isOn != oldValue { needsDisplay = true } }
    }

    /// 无障碍标签。自绘控件不会自己知道旁边那行字写的是什么，
    /// 所以调用方必须把它按上 —— 否则 VoiceOver 念出来是"复选框，未选中"，
    /// 用户不知道是哪一个。
    var label: String? {
        didSet { setAccessibilityLabel(label) }
    }

    override var intrinsicContentSize: NSSize { ChromeControl.switchTrackSize }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme
        let track = ChromeControl.switchTrackSize
        // 控件比内在尺寸大的时候居中 —— 否则它会贴在左下角，看起来像没对齐
        let box = CGRect(x: (bounds.width - track.width) / 2,
                         y: (bounds.height - track.height) / 2,
                         width: track.width, height: track.height)
        let radius = track.height / 2

        // 轨：关态是键帽色，开态是强调填充。
        // 描边不能省 —— 键帽色与窗底只差一点点，没有边就分不出"这里有个开关"。
        fill(box, isOn ? palette.fill : palette.cap, radius: radius)
        let borderColor = isHovered ? palette.borderHover : palette.capBorder
        stroke(box, borderColor, radius: radius)

        // 钮：按下时**变宽到 20**（稿子 §04：「悬停 / 按下（描边提亮 / 钮变宽 20）」）。
        // 这是"你正按着它"唯一的可视化 —— 光靠描边提亮在与悬停同时出现时分不开。
        let inset = ChromeControl.switchKnobInset
        let knobWidth = isPressed
            ? min(track.width - inset * 2, ChromeControl.switchKnobDiameter + 2)
            : ChromeControl.switchKnobDiameter
        let knobHeight = ChromeControl.switchKnobDiameter
        let knobX = isOn ? box.maxX - inset - knobWidth : box.minX + inset
        let knob = CGRect(x: knobX, y: box.midY - knobHeight / 2,
                          width: knobWidth, height: knobHeight)

        // 钮一律是白的：它压在**填蓝的轨**与**键帽色的轨**上都要看得见，
        // 而键帽色在深浅两套里都是中间调 —— 白钮是唯一在两个极端都成立的选择。
        fill(knob, NSColor.white, radius: knobHeight / 2)
        // 浅色下白钮压在浅色的轨上会糊掉，所以补一圈淡边
        stroke(knob.insetBy(dx: -0.5, dy: -0.5), RGB(hex: 0x000000, alpha: 0.08),
               radius: knobHeight / 2, width: 1)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        // 松开时**光标已经移走**就不算数 —— 这与系统按钮一致，
        // 也让"按错了想反悔"有一个不必点第二次的出口。
        guard inside else { return }
        isOn.toggle()
        onChange?()
    }

    // MARK: 无障碍（自绘的入场费）

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn }
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        isOn.toggle()
        onChange?()
        return true
    }
}

// MARK: - 分段控件

/// 延时 4 档 / 格式 3 档用的分段控件。稿子 §01：「24 高 · 段内边距 0 / 8 · 轨 `--c-inset` ·
/// 选中段 = 键帽材质（和 ① 的键帽同源）」。
///
/// ⚠️ **选中段用键帽材质、不用填充蓝**：这一页上填充蓝的含义是"开关打开了"，
/// 而分段控件的选中段是"当前选的是哪一档" —— 两者同色会让人以为
/// "选了 5 秒"等于"某个功能被打开了"。
@MainActor
final class ChromeSegmented: ChromeControlView {

    var titles: [String] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var selectedIndex: Int = 0 {
        didSet { if selectedIndex != oldValue { needsDisplay = true } }
    }

    private var segmentRects: [CGRect] = []
    /// 鼠标此刻压在哪一段上（`nil` = 不在任何一段）。悬停只给一点点反馈，
    /// 别让它看起来像被选中了。
    private var hoveredSegment: Int? {
        didSet { if hoveredSegment != oldValue { needsDisplay = true } }
    }

    /// 段的位置是**画的时候才算**的（宽度依赖文字），所以这里用上一次绘制留下的矩形。
    override func hoverChanged(at point: CGPoint?) {
        guard let point else { hoveredSegment = nil; return }
        hoveredSegment = segmentRects.firstIndex { $0.contains(point) }
    }

    override var intrinsicContentSize: NSSize {
        let width = titles.reduce(0) { $0 + segmentWidth($1) }
        return NSSize(width: width, height: ChromeControl.segmentedHeight)
    }

    private func segmentWidth(_ title: String) -> CGFloat {
        let text = title as NSString
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return (text.size(withAttributes: [.font: font]).width
                + ChromeControl.segmentHorizontalPadding * 2).rounded()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme
        let height = ChromeControl.segmentedHeight
        let box = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        let radius = 6.0

        // 轨：内凹色 + 一圈描边。它是"凹进去的一条槽"，不是"一排按钮的底"。
        fill(box, palette.inset, radius: radius)
        stroke(box, palette.border, radius: radius)

        // 段的位置**每次绘制重算**：宽度依赖文字，而文字长度随语言变
        //（英文比中文长一倍）—— 缓存一次就会在切语言之后错位。
        var x = box.minX
        segmentRects = titles.map { title in
            let rect = CGRect(x: x, y: box.minY, width: segmentWidth(title), height: height)
            x += rect.width
            return rect
        }

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for (index, title) in titles.enumerated() {
            let rect = segmentRects[index]
            let selected = index == selectedIndex
            // 选中段 = 键帽材质（与引导页那个录制框同源），**不是**填充蓝
            if selected {
                let cap = rect.insetBy(dx: 1, dy: 1)
                fill(cap, palette.cap, radius: radius - 1)
                stroke(cap, palette.capBorder, radius: radius - 1)
            } else if hoveredSegment == index {
                // 悬停只淡淡的提一下，别让它看起来像被选中了
                fill(rect.insetBy(dx: 1, dy: 1), palette.soft, radius: radius - 1)
            }
            let color = selected ? palette.label : palette.label2
            let text = title as NSString
            let size = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2),
                      withAttributes: [.font: font, .foregroundColor: color.nsColor])
        }

        // 段之间画细分割线，但**分割线不穿过选中段**（穿过去会把"这一整块是选中的"切开）
        for (index, rect) in segmentRects.enumerated() where index > 0 {
            guard index != selectedIndex, index - 1 != selectedIndex else { continue }
            palette.hairline.nsColor.setFill()
            NSRect(x: rect.minX, y: box.minY + 4, width: 1, height: height - 8).fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = segmentRects.firstIndex(where: { $0.contains(point) }),
              index != selectedIndex else { return }
        selectedIndex = index
        onChange?()
    }

    // MARK: 无障碍
    //
    // 自绘的分段控件不实现"每一段是一个可点的 radio"（那要自己算每一段的无障碍帧，
    // 而帧又依赖文字宽度）。退一步给整个控件一个角色 + 一个值：
    // VoiceOver 会念"单选组，5 秒" —— 至少**当前是哪一档**是听得见的，
    // 而不是一句"未知元素"。这是能力与代价之间取的中间点，写在这里免得下次被当成漏做。

    override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { titles.indices.contains(selectedIndex) ? titles[selectedIndex] : nil }

    override func accessibilityPerformPress() -> Bool {
        guard !titles.isEmpty else { return false }
        selectedIndex = (selectedIndex + 1) % titles.count
        onChange?()
        return true
    }
}

// MARK: - 滑块

/// 质量用的滑块。稿子 §01：「150 × 24 · 轨 4 · 钮 14」，
/// 轨 `--c-inset`、**已选段填 `--c-fill`**、右侧 11 点 mono 读数。
///
/// ⚠️ 两件事与系统滑块不同、也不打算"跟系统"：
/// 1. **已选段填色**（系统是一段均色的凹槽）—— 这一页上它要读起来像"一根进度条 + 一个钮"；
/// 2. **拖动过程中不回调**（见 `mouseDragged`）。
@MainActor
final class ChromeSlider: ChromeControlView {

    /// 0…1
    var value: Double = 0.8 {
        didSet { if value != oldValue { needsDisplay = true } }
    }
    /// 置灰时**只灰滑块**（轨、钮），不灰那一行 —— 稿子 §04 专门说了这一条。
    var isEnabledControl = true {
        didSet { if isEnabledControl != oldValue { needsDisplay = true } }
    }

    /// 右侧那个百分比读数（`nil` = 不画）。
    var readout: String? {
        didSet { if readout != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize { ChromeControl.sliderSize }

    private var knobDiameter: CGFloat { ChromeControl.sliderKnobDiameter }
    private var trackHeight: CGFloat { ChromeControl.sliderTrackHeight }

    /// 读数占的宽度 —— 先量出来，剩下的才是轨。
    private var readoutWidth: CGFloat {
        guard let readout else { return 0 }
        return (readout as NSString).size(withAttributes: [.font: readoutFont]).width + 10
    }

    private var readoutFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }

    private var trackRect: CGRect {
        let room = bounds.width - readoutWidth
        let track = CGRect(x: 0, y: bounds.midY - trackHeight / 2,
                           width: max(knobDiameter, room - knobDiameter), height: trackHeight)
        return track
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme
        // 置灰时只把**轨与钮**画淡，读数照常读得出 —— 它是"不适用"，不是"没这一项"
        let trackColor = isEnabledControl ? palette.inset : palette.soft
        let fillColor = isEnabledControl ? palette.fill : palette.disabled
        let knobColor = isEnabledControl ? NSColor.white : RGB(hex: 0xFFFFFF, alpha: 0.55).nsColor

        let track = trackRect
        let clamped = min(1, max(0, value))
        let knobX = track.minX + (track.width - knobDiameter) * clamped

        fill(track, trackColor, radius: trackHeight / 2)
        let filled = CGRect(x: track.minX, y: track.minY,
                            width: max(0, knobX + knobDiameter / 2 - track.minX), height: trackHeight)
        fill(filled, fillColor, radius: trackHeight / 2)

        let knob = CGRect(x: knobX, y: bounds.midY - knobDiameter / 2,
                          width: knobDiameter, height: knobDiameter)
        fill(knob, knobColor, radius: knobDiameter / 2)
        stroke(knob.insetBy(dx: -0.5, dy: -0.5), palette.capBorder,
               radius: knobDiameter / 2, width: 1)

        guard let readout else { return }
        let text = readout as NSString
        let size = text.size(withAttributes: [.font: readoutFont])
        text.draw(at: CGPoint(x: bounds.maxX - size.width, y: bounds.midY - size.height / 2),
                  withAttributes: [.font: readoutFont,
                                   .foregroundColor: palette.label.nsColor])
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabledControl else { return }
        isPressed = true
        update(with: event.locationInWindow)
    }

    /// ⚠️ 拖动过程中**只改显示、不回调** —— 稿子 §04：
    /// 「滑块在拖动过程中不写盘，**松手那一刻才落盘**：否则一次拖动会写几十次配置文件」。
    override func mouseDragged(with event: NSEvent) {
        guard isEnabledControl, isPressed else { return }
        update(with: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabledControl, isPressed else { return }
        isPressed = false
        onChange?()
    }

    private func update(with locationInWindow: CGPoint) {
        let point = convert(locationInWindow, from: nil)
        let track = trackRect
        let travel = track.width - knobDiameter
        guard travel > 0 else { return }
        value = min(1, max(0, Double((point.x - track.minX - knobDiameter / 2) / travel)))
    }

    // MARK: 无障碍

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0.0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 1.0) }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabledControl else { return false }
        value = min(1, value + 0.05)
        onChange?()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabledControl else { return false }
        value = max(0, value - 0.05)
        onChange?()
        return true
    }
}

// MARK: - 文字按钮（最近截图里那两个动作）

/// 只有文字的小按钮。稿子：`.btn--mini{height:24px;padding:0 8px;border-radius:6px;
/// font:500 11px/1;color:var(--c-label2)}`。
///
/// ⚠️ **常态没有底**，而且文字是 `--c-label2`（次要色）。稿子的原话是
/// 「常显不隐藏（隐藏会让每一行的宽度看起来在变）；平时**极静**，行一悬停才浮出底」。
/// 所以"看得见它在哪"靠的是**行悬停/鼠标悬停时浮出的那层底**，不是靠常态的描边。
@MainActor
final class ChromeTextButton: ChromeControlView {

    /// 它所在的那一行被悬停了 —— 由行设进来。
    ///
    /// 稿子：`.rt.is-hover .btn--mini{background:var(--c-ghost);color:var(--c-label)}` ——
    /// **整行一起亮，不是各亮各的**。行是唯一知道这件事的人（按钮自己只知道自己）。
    var rowHighlighted = false {
        didSet { if rowHighlighted != oldValue { needsDisplay = true } }
    }

    var title: String = "" {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    /// 点击。**不用 target-action** —— 自绘的这个不是 `NSControl`，
    /// 硬造一个假身份只为了省一次闭包，不划算。
    var onActivate: (() -> Void)?

    /// 两种语气。它们差的不只是颜色，而是**"我是这一行里的动作"还是"我是那句话里的一个词"**。
    enum Emphasis: Equatable {
        /// 动作按钮（编辑 / 删除）：常态次要色、行一悬停才浮出底。
        case quiet
        /// 一句话里唯一可点的那个词（`升级到 Pro`）：常态就是强调色（`--c-glyph`），
        /// 因为它必须**一眼看得出来可以点** —— 否则那就是一句普通的说明文字。
        case accent
    }

    var emphasis: Emphasis = .quiet {
        didSet { if emphasis != oldValue { needsDisplay = true } }
    }

    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: RecentPanel.actionWidth(textWidth: width),
                      height: RecentPanel.actionHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme
        let height = RecentPanel.actionHeight
        let box = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)

        // 按压 > 浮出 > 平静。三档的判据只在这一处 —— 散在几个 `if` 里的话，
        // "行悬停"与"鼠标压在按钮上"这两个来源迟早会有一处忘了算。
        let highlighted = rowHighlighted || isHovered
        if isPressed {
            fill(box, palette.ghostPressed, radius: RecentPanel.actionCornerRadius)
        } else if highlighted {
            fill(box, palette.actionHover, radius: RecentPanel.actionCornerRadius)
        }

        // ⚠️ `.accent` **不受 `rowHighlighted` 影响**：它是那句话里的一个词，
        // 不属于行里的动作组 —— 行悬停时跟着变亮会让它看起来像第三个动作
        //（稿子正是为了避免这个才把它放在底部那行里）。
        let lit = isPressed || isHovered || (emphasis == .quiet && rowHighlighted)
        let color: RGB
        switch emphasis {
        case .quiet: color = lit ? palette.label : palette.label2
        case .accent: color = palette.glyph
        }
        let text = title as NSString
        let size = text.size(withAttributes: [.font: Self.font])
        text.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                  withAttributes: [.font: Self.font, .foregroundColor: color.nsColor])
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        // 松开时鼠标已经移走就不算数 —— 与系统按钮一致，
        // 也给"按错了想反悔"留一个不必点第二次的出口。
        guard inside else { return }
        onActivate?()
    }

    // MARK: 无障碍

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { title }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }
}

// MARK: - 行

/// 每一页的内容单位。稿子 §01：「最小 58 高（12 上 12 下）· **无底无框** · 行间 1px `--c-hair`」
/// · 标题 13 / 500 + 说明 11 / 400。
///
/// ⚠️ "无底无框"是要点：这一页的秩序来自**行与行的发丝线**，不是来自给每一行套一个卡片。
/// 套了卡片就会读成"一页里有若干个区块"，而它们其实是同一个列表里的平级项。
@MainActor
final class ChromeRow: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    /// 右侧的控件（开关 / 分段 / 滑块 / 按钮…）。`nil` = 这一行只有文字。
    private(set) var control: NSView?

    init(title: String, subtitle: String, control: NSView?) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping

        self.control = control
        [titleLabel, subtitleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        // ⚠️ 两个标签的 `textColor` **不在这里设** —— 它要跟随外观，
        // 而 `init` 时拿不到有效的 `effectiveAppearance`。放在 `viewDidChangeEffectiveAppearance`。
        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: ChromeControl.rowMinHeight),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor,
                                            constant: ChromeControl.rowVerticalPadding + 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor,
                                                  constant: -ChromeControl.rowVerticalPadding),
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor,
                                                        constant: -12),
            ]
        } else {
            constraints.append(subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ChromeRow 只支持代码创建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let palette = ChromePalette.Theme.resolved(for: effectiveAppearance)
        titleLabel.textColor = palette.label.nsColor
        subtitleLabel.textColor = palette.label2.nsColor
    }

    /// 改说明句。**延时与质量那两行要用它** ——
    /// 那两项的回执全押在说明句上（改了当场看不出效果）。
    func setSubtitle(_ text: String) {
        subtitleLabel.stringValue = text
    }

    // MARK: - 第三行（少数几件"出错了"的事）

    private lazy var noticeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        return label
    }()

    private var noticeButton: NSButton?

    /// 这一行的**第三行**：一句"刚才那一下没成"，外加一个能直接点开的去处。
    ///
    /// ⚠️ 为什么是"这一行自己的第三行"，而不是像快捷键那样有个"状态槽"：
    /// 稿子 §04 的原话是「失败的提示**不自动消失** —— 它要一直在那儿，
    /// 直到用户真的去登录项里看明白。所以它不放在录制框那种『状态槽』里」。
    /// 状态槽是"刚才那一下"的回执，会过期；这一条是**一个待办**，不会自己走。
    ///
    /// - Parameters:
    ///   - text: 空串 = 收起来。
    ///   - actionTitle: 给了就补一个文字按钮（如「打开登录项设置」）。
    func setNotice(_ text: String, actionTitle: String? = nil,
                   target: AnyObject? = nil, action: Selector? = nil) {
        let palette = ChromePalette.Theme.resolved(for: effectiveAppearance)
        let visible = !text.isEmpty
        noticeLabel.stringValue = text
        // 出错的提示用琥珀（`caution`）而不是危险红：这一条是"去系统设置里办点事"，
        // 是**有救**的那种；红色留给"这件事已经失败了"。
        noticeLabel.textColor = palette.caution.nsColor

        if let actionTitle, let target, let action {
            let button = noticeButton ?? {
                let made = NSButton(title: actionTitle, target: target, action: action)
                made.bezelStyle = .inline
                made.controlSize = .small
                made.translatesAutoresizingMaskIntoConstraints = false
                noticeRow.addArrangedSubview(made)
                noticeButton = made
                return made
            }()
            button.title = actionTitle
            button.target = target
            button.action = action
            button.isHidden = !visible
        }
        noticeRow.isHidden = !visible
        noticeLabel.isHidden = !visible
    }

    private lazy var noticeRow: NSStackView = {
        let stack = NSStackView(views: [noticeLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.isHidden = true
        return stack
    }()

    /// 把第三行接在说明句下面。**只在真的要有第三行时调用一次。**
    func installNoticeRow() {
        noticeRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noticeRow)
        NSLayoutConstraint.activate([
            noticeRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            noticeRow.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 4),
            noticeRow.bottomAnchor.constraint(equalTo: bottomAnchor,
                                              constant: -ChromeControl.rowVerticalPadding),
        ])
    }
}

// MARK: - 标签条

/// 窗口顶部的四格标签条。稿子 §01：「28 高 · 宽随文字（示意 66–77）·
/// 选中 `--c-soft-h` + 1pt `--c-border` · 6 pt · 11 / 500 + 14pt 图标」。
///
/// ⚠️ **选中态用的是"软底 + 描边"，不是填充蓝** —— 与分段控件同一条理由：
/// 填充蓝在这个项目里的含义是"这个开关开着"，而标签的选中是"现在在看哪一页"。
/// 两者同色会让用户以为切页等于打开了什么。
///
/// ⚠️ **图标要用语言无关的**（`gearshape` / `camera` / `folder` / `keyboard`）：
/// SF Symbol 里有一批会自动本地化，中文环境下会变成汉字
/// （`textformat` 会变成「格式」两个字，夹在一排图标里非常突兀 ——
/// 覆盖层工具条已经踩过这个坑，见 PITFALLS 28）。
@MainActor
final class ChromeTabBar: ChromeControlView {

    /// 一格：图标名 + 标题。**顺序即从左到右**。
    struct Tab {
        var symbol: String
        var title: String
    }

    var tabs: [Tab] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var selectedIndex: Int = 0 {
        didSet { if selectedIndex != oldValue { needsDisplay = true } }
    }

    private var tabRects: [CGRect] = []
    private var hoveredTab: Int? {
        didSet { if hoveredTab != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: tabs.reduce(0) { $0 + tabWidth($1) } + CGFloat(max(0, tabs.count - 1)) * ChromeControl.tabSpacing,
               height: ChromeControl.tabBarHeight)
    }

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private func tabWidth(_ tab: Tab) -> CGFloat {
        let text = (tab.title as NSString).size(withAttributes: [.font: Self.labelFont]).width
        return (ChromeControl.tabHorizontalPadding * 2
                + ChromeControl.tabIconSize + ChromeControl.tabIconGap + text).rounded()
    }

    /// 上一次绘制的矩形。悬停判定要用它 —— 格子的位置是画的时候才算的。
    override func hoverChanged(at point: CGPoint?) {
        guard let point else { hoveredTab = nil; return }
        hoveredTab = tabRects.firstIndex { $0.contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme
        let height = ChromeControl.tabBarHeight
        let box = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)

        var x = box.minX
        tabRects = tabs.map { tab in
            let rect = CGRect(x: x, y: box.minY, width: tabWidth(tab), height: height)
            x += rect.width + ChromeControl.tabSpacing
            return rect
        }

        for (index, tab) in tabs.enumerated() {
            let rect = tabRects[index]
            let selected = index == selectedIndex
            // 悬停只给一格淡淡的底；选中给软底 + 描边。两者**不能同色** ——
            // 同色的话"鼠标划过"与"这一页是当前页"就分不开了。
            if selected {
                fill(rect, palette.softHover, radius: ChromeControl.tabCornerRadius)
                stroke(rect, palette.border, radius: ChromeControl.tabCornerRadius)
            } else if hoveredTab == index {
                fill(rect, palette.ghost, radius: ChromeControl.tabCornerRadius)
            }

            let tint = selected ? palette.label : palette.label2
            let iconSide = ChromeControl.tabIconSize
            let text = (tab.title as NSString).size(withAttributes: [.font: Self.labelFont])
            let contentWidth = iconSide + ChromeControl.tabIconGap + text.width
            let contentX = rect.midX - contentWidth / 2

            drawSymbol(tab.symbol, in: CGRect(x: contentX, y: rect.midY - iconSide / 2,
                                              width: iconSide, height: iconSide),
                       tint: tint)
            (tab.title as NSString).draw(
                at: CGPoint(x: contentX + iconSide + ChromeControl.tabIconGap,
                            y: rect.midY - text.height / 2),
                withAttributes: [.font: Self.labelFont, .foregroundColor: tint.nsColor])
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabRects.firstIndex(where: { $0.contains(point) }),
              index != selectedIndex else { return }
        selectedIndex = index
        onChange?()
    }

    // MARK: 无障碍

    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex].title : nil }

    override func accessibilityPerformPress() -> Bool {
        guard !tabs.isEmpty else { return false }
        selectedIndex = (selectedIndex + 1) % tabs.count
        onChange?()
        return true
    }
}

// MARK: - 面板

/// 一块**面板**：Pro 状态区那种"接在页尾的一小块"。
///
/// 稿子 §01：「Pro 状态区 panel · 整列宽 · 高随状态（示意 96–118）·
/// `--c-panel` + 1px `--c-hair` · 8 pt」。
///
/// ⚠️ 这一页上**只有这一块有底**。行是"无底无框"的（见 `ChromeRow`）——
/// 秩序来自行间的发丝线。给行也套上底，就会读成"一页里有若干个区块"，
/// 而它们其实是同一个列表里的平级项。面板只用来标记"这一块不是设置项，是一句状态"。
@MainActor
final class ChromePanel: NSView {

    private let content = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let pad = ChromeControl.proPanelPadding
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ChromePanel 只支持代码创建") }

    func setContent(_ views: [NSView]) {
        content.arrangedSubviews.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        views.forEach { content.addArrangedSubview($0) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromePalette.Theme.resolved(for: effectiveAppearance)
        let radius = ChromeControl.proPanelCornerRadius
        palette.panel.nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        // 描边用发丝线色（半透明的白/黑），不是那个更实的 `border` ——
        // 面板嵌在窗底里，它的边不该比窗里任何一条分割线更抢眼。
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = 1
        palette.hairline.nsColor.setStroke()
        path.stroke()
    }
}

/// 一行发丝线（行与行之间）。稿子 §01：「行间 1px `--c-hair`」。

@MainActor
final class ChromeSeparator: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        ChromePalette.Theme.resolved(for: effectiveAppearance).hairline.nsColor.setFill()
        NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1).fill()
    }
}

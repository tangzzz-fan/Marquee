import AppKit
import MarqueeCore

/// 菜单栏入口。
///
/// 约束（PRD 3.1「功能简洁」）：下拉菜单 **≤ 6 项**，当前 **5 项**
/// （截屏 / 滚动截屏 / 最近截图 / 设置… / ─ / 退出）。
///
/// ticket 15 的两处调整：
/// - **删掉「延时截屏」这个占位项**。延时已经进了「设置 → 截屏」页 ——
///   同一个功能摆两个入口，用户会以为它们不同步。删掉它顺带给「最近截图」腾出了位置。
/// - 「快捷键…」改回「设置…」（ticket 02 时它只能改快捷键，所以叫那个名字）。
///
/// ## 回调必须由 init 注入（**不要**改回可选 `var`）
///
/// ticket 11 漏接过 `onScrollCapture`：菜单里能看到「滚动截屏」、项也是启用的，
/// 但点下去完全没反应 —— 可选闭包为 nil 时是**静默 no-op**，
/// 从"用户点了没反应"到"原来是没接线"之间没有任何线索。
/// 做成必填参数后，漏接就是编译错误。
@MainActor
final class MenuBarController: NSObject {

    /// 点击「截屏」
    private let onCapture: () -> Void
    /// 点击「滚动截屏」
    private let onScrollCapture: () -> Void
    /// 「滚动截屏」现在是不是锁着的（ticket 31）。
    ///
    /// **每次展开菜单时现问**，而不是让谁在购买成功后推一个通知过来 ——
    /// 后者要求"权益变了"这件事必须通知到每一个界面，漏一处就是"买完了锁还在"。
    private let isScrollCaptureLocked: () -> Bool
    /// 点击「设置…」
    private let onShowPreferences: () -> Void
    /// 造「最近截图」面板（ticket 16）。每次需要时现造一个控制器，
    /// 内容由它自己在 `viewWillAppear` 里重新读磁盘 —— 于是"刚截的那张"一定在。
    private let makeRecentPanel: () -> NSViewController
    private var recentPopover: NSPopover?

    private let statusItem: NSStatusItem
    private let captureItem = NSMenuItem(title: L10n.t("截屏"),
                                         action: #selector(triggerCapture),
                                         keyEquivalent: "a")
    /// 「滚动截屏」项。持着它，才能在菜单展开时把锁图标换上去。
    private let scrollItem = NSMenuItem(title: L10n.t("滚动截屏"),
                                        action: #selector(triggerScrollCapture),
                                        keyEquivalent: "")

    init(onCapture: @escaping () -> Void,
         onScrollCapture: @escaping () -> Void,
         onShowPreferences: @escaping () -> Void,
         makeRecentPanel: @escaping () -> NSViewController,
         isScrollCaptureLocked: @escaping () -> Bool) {
        self.onCapture = onCapture
        self.onScrollCapture = onScrollCapture
        self.onShowPreferences = onShowPreferences
        self.makeRecentPanel = makeRecentPanel
        self.isScrollCaptureLocked = isScrollCaptureLocked
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // `super.init()` 之后才能调用自己的方法（下面的 `makeMenu` 就是）——
        // Swift 的初始化顺序：所有存储属性先就位，再放开 `self`。
        super.init()
        let image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Marquee")
        image?.isTemplate = true
        statusItem.button?.image = image
        // 开发版在提示里加个后缀。菜单栏是**图标**（LSUIElement，没有标题栏），
        // 悬停提示是唯一不打扰人、又能随时确认"我跑的是哪一个"的地方。
        statusItem.button?.toolTip = "Marquee" + AppIdentity().developmentTitleSuffix
        let menu = makeMenu()
        // 菜单展开时现算锁图标（ticket 31）。delegate 是 weak，无循环引用。
        menu.delegate = self
        statusItem.menu = menu
        updateShortcut(KeyCombo.fullScreenCapture)
    }

    /// 快捷键变化后同步菜单上显示的组合。
    ///
    /// 菜单里的 keyEquivalent 只在应用激活时生效，**不**承担全局触发 ——
    /// 全局触发是 Carbon 的事（`CarbonGlobalHotKey`）。这里放它纯粹是"告诉用户现在是哪个键"。
    func updateShortcut(_ combo: KeyCombo) {
        captureItem.keyEquivalent = combo.keyLabel.lowercased()
        captureItem.keyEquivalentModifierMask = Self.appKitModifiers(for: combo.modifiers)
    }

    // MARK: - 私有

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        captureItem.target = self
        menu.addItem(captureItem)

        // ticket 11：长截图（手动滚动）。ticket 31：免费版带一把小锁。
        scrollItem.target = self
        menu.addItem(scrollItem)

        // ticket 16：最近截图。**不是子菜单**，点了弹一层面板 ——
        // 子菜单放不下缩略图，而"看不见缩略图"就等于回到"我记不清哪张是哪张"。
        let recent = NSMenuItem(title: L10n.t("最近截图"),
                                action: #selector(showRecent),
                                keyEquivalent: "")
        recent.target = self
        menu.addItem(recent)

        let settings = NSMenuItem(title: L10n.t("设置…"),
                                  action: #selector(showPreferences),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("退出 Marquee"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    /// 未实现的菜单项：显式禁用，避免出现"点了没反应"的假入口。
    private static func placeholder(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 语义修饰键 → AppKit 修饰位（只用于菜单展示）
    private static func appKitModifiers(for modifiers: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    @objc private func triggerCapture() {
        onCapture()
    }

    @objc private func triggerScrollCapture() {
        onScrollCapture()
    }

    @objc private func showPreferences() {
        onShowPreferences()
    }

    @objc private func showRecent() {
        let popover: NSPopover
        if let existing = recentPopover {
            popover = existing
        } else {
            let created = NSPopover()
            // `.transient`：点别处就收起来（它是一层面板，不是窗口）
            created.behavior = .transient
            created.contentViewController = makeRecentPanel()
            recentPopover = created
            popover = created
        }
        guard let button = statusItem.button else { return }
        // 应用是 accessory（后台）：不激活的话弹层可能开在别的应用窗口后面
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

// MARK: - 菜单展开时刷新（ticket 31）

extension MenuBarController: NSMenuDelegate {

    /// 每次展开菜单时重算「滚动截屏」上那把锁。
    ///
    /// 放在这里，而不是"购买成功后推一个通知过来"：后者要求权益变化必须通知到
    /// 每一个界面，漏一处就是"买完了锁还在"。菜单本来就要重新画，顺手问一次最省事。
    ///
    /// ⚠️ **只换图标，绝不改 `isEnabled`。** 禁用菜单项会让用户点不动它 ——
    /// 也就永远看不到那张解释"为什么不行"的卡片。而免费版里这一项是**可点的**，
    /// 点了弹卡片（见 `CaptureCoordinator.performScrollCapture`）。
    /// 稿子 §02 把这条讲得更直白：**「锁是路标，不是惩罚」**——
    /// 它标记的是"唯一那个点了会先给你一张解释卡的入口"，条目文字保持全亮。
    func menuNeedsUpdate(_ menu: NSMenu) {
        scrollItem.image = Self.lockIndicator(locked: isScrollCaptureLocked())
    }

    /// 那一格里的图标。**两种状态给的是同尺寸的两枚。**
    ///
    /// ## 为什么解锁时也要给一枚（哪怕是空的）
    ///
    /// 因为菜单项一旦有图，AppKit 会给**整张菜单**留出一列图标位。
    /// 原先解锁时给的是 `nil` —— 于是买断之后那一列消失、**所有标题一起往左跳一下**。
    /// 那种跳动的幅度只有十几点，看到的瞬间会以为菜单重排了。
    ///
    /// ## 为什么是模板图（`isTemplate`）而不是自己上灰色
    ///
    /// 稿子那张表写的是「锁 9 × 9 · 颜色 = 右列的灰（`--c-label2`）」，
    /// 但它的 CSS 用的是 `stroke:currentColor`，并且专门画了一屏
    /// 「悬停 · 整行反白，**锁跟着变白**（可点这件事要看得见）」。
    /// 模板图在菜单里正是这个行为：常规态跟着菜单的前景色、高亮时跟着高亮色一起变白。
    /// 自己画一个固定灰的位图反而做不到后半句 —— 那样鼠标划过去时锁是唯一不变的东西。
    ///
    /// ⚠️ **一处与稿子的刻意背离**：稿子把锁安排在**右列**（与快捷键同一列、同一条右缘）。
    /// AppKit 没有把图形放进"快捷键列"的支持 API（那一列只画 `keyEquivalent`）——
    /// 只有两条路：抬着 `NSMenuItem.view` 自绘整行（拿掉原生高亮与无障碍），
    /// 或者让图形待在**前置**位置（就是这里）。
    /// 自绘那一条的代价是"菜单不再像系统菜单"，而稿子自己说过
    /// 「菜单是唯一一块改了尺寸就会被立刻察觉『不像系统』的界面」——
    /// 两害相权，选后者。**全菜单只有这一把锁，这一点没有打折。**
    static func lockIndicator(locked: Bool) -> NSImage? {
        guard let lock = NSImage(systemSymbolName: "lock.fill",
                                 accessibilityDescription: L10n.t("需要 Pro"))?
            .withSymbolConfiguration(.init(pointSize: lockPointSize, weight: .regular)) else {
            return nil
        }
        lock.isTemplate = true
        guard !locked else { return lock }
        // 空的同尺寸占位：什么都不画，但把那一格占住。
        let placeholder = NSImage(size: lock.size)
        placeholder.isTemplate = true
        return placeholder
    }

    /// 锁的字号。稿子：「锁 9 × 9（与 ④ 完全同尺寸）」。
    private static let lockPointSize: CGFloat = 9
}

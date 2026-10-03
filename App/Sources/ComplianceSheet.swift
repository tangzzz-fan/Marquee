import AppKit
import MarqueeCore
import MarqueeHistory
import MarqueeOverlay

/// 把三块 **AppKit 拼的窗口**（偏好 / 最近截图 / 引导页）离屏渲成 PNG。
///
/// `-marqueeSmokeCompliance` 用它出「设计稿 vs 实装」的对照材料。
///
/// ## 为什么值得有它
///
/// 这三块与编辑器、升级卡片不一样：它们是**约束拼出来的**（`NSStackView` +
/// `NSLayoutConstraint`），Core 的断言钉得住数字，钉不住"摆出来是不是稿子那个样子"。
/// 而肉眼验收要开窗口、切页面、点标签 —— 每次都对一遍是不现实的。
/// 让它们**离屏**渲成 PNG，一次跑完、落进报告目录，对照就成了一条命令的事。
///
/// ## 一处已知的失真
///
/// 这些窗口里有 `NSVisualEffectView`（材质）。`.behindWindow` 的混合模式要**窗口背后
/// 真有东西**才成立，离屏渲染时背后什么都没有 —— 材质会退化成一块平色。
/// 所以 PNG 里看到的材质底**比真机上的平**；布局、字号、控件、颜色照旧可信。
@MainActor
enum ComplianceSheet {

    /// 渲一张视图（含它的全部子视图）。`background` 先铺满 ——
    /// `cacheDisplay` 只画**这一棵视图树自己**，窗口底那层不在里面，
    /// 不铺的话 PNG 的空白处就是透明的（在浅色查看器里看起来像"黑底白字错位"）。
    static func png(of view: NSView, name: String, into directory: URL,
                    background: RGB? = nil) -> URL? {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }

        if let background {
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                background.nsColor.setFill()
                bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        view.cacheDisplay(in: bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: url)
        return url
    }

    /// 把一块窗口内容**按窗口自己的尺寸**照下来。
    ///
    /// ⚠️ 不要去改 `contentView.frame`：窗口在 `buildShell` 里已经按约束算好了内容尺寸，
    /// 从外面硬塞一个 `fittingSize` 会把布局打回"还没算过"的状态 ——
    /// 表现就是 PNG 里字叠着字、面板不见了。
    static func windowContent(of window: NSWindow, name: String,
                              into directory: URL, background: RGB) -> URL? {
        window.appearance = NSAppearance(named: .darkAqua)   // 这三块稿子都给了深色版
        window.layoutIfNeeded()
        guard let content = window.contentView else { return nil }
        return png(of: content, name: name, into: directory, background: background)
    }

    /// 全部渲一遍，返回落盘路径（顺序与报告里的一致）。
    static func render(shortcut: ShortcutService,
                       preferences: UserDefaultsPreferencesStore,
                       output: UserDefaultsOutputStore,
                       currentPermission: @escaping () -> ScreenRecordingPermission,
                       into directory: URL) -> [String] {
        var written: [String] = []

        // ── 偏好设置（四页各一张）
        let prefs = PreferencesWindowController(shortcut: shortcut,
                                                preferences: preferences,
                                                output: output)
        prefs.present()
        for page in SettingsPage.allCases {
            prefs.select(page)
            if let url = windowContent(of: prefs.window!, name: "prefs-\(page.rawValue).png",
                                       into: directory, background: ChromePalette.dark.background) {
                written.append(url.path)
            }
        }
        prefs.window?.orderOut(nil)

        // ── 最近截图面板：造一个**临时历史**（3 条，其中一条带标注）
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-compliance-\(UUID().uuidString)", isDirectory: true)
        let store = CaptureHistoryStore(directory: directoryURL)
        let annotation = Annotation(kind: .rectangle,
                                    frame: CGRect(x: 6, y: 5, width: 12, height: 9),
                                    zIndex: 0)
        for index in 0..<3 {
            _ = store.record(original: Self.sampleImage(index % 3),
                             originalPNG: nil,
                             annotations: index == 0 ? [annotation] : [],
                             at: Date().addingTimeInterval(TimeInterval(-index * 3600)))
        }
        let recent = RecentCapturesPanelController(
            store: store,
            actions: .init(onCopy: { _ in }, onEdit: { _ in }, onDelete: { _ in }),
            currentShortcut: { shortcut.current },
            upgradeCard: { ProCardContent(feature: .unlimitedHistory,
                                          reason: .neverPurchased,
                                          primary: .purchase,
                                          secondary: .restore) },
            onUpgradeAction: { _ in })
        _ = recent.view
        recent.reload()
        recent.view.frame = CGRect(origin: .zero, size: recent.view.fittingSize)
        if let url = png(of: recent.view, name: "recent-panel.png", into: directory) {
            written.append(url.path)
        }
        try? FileManager.default.removeItem(at: directoryURL)

        // ── 引导页
        let onboarding = OnboardingWindowController(shortcut: shortcut,
                                                    currentPermission: currentPermission,
                                                    onShortcutChanged: { _ in })
        onboarding.window?.orderFrontRegardless()
        if let url = windowContent(of: onboarding.window!, name: "onboarding.png",
                                   into: directory, background: ChromePalette.dark.background) {
            written.append(url.path)
        }
        onboarding.window?.orderOut(nil)

        return written
    }

    /// 造一张纯色小图 —— 对照材料不该要求屏幕录制授权。
    private static func sampleImage(_ index: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let width = 400 + index * 40
        let context = CGContext(data: nil, width: width, height: 300,
                                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let shade = 0.2 + Double(index) * 0.2
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [shade, shade, 0.8, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 300))
        return context.makeImage()!
    }
}

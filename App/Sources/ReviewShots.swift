import AppKit
import MarqueeCore
import MarqueeOverlay

/// 出两张 **App Store Connect 的 IAP 审核截图**（`-marqueeSmokeReview`）。
///
/// ## 为什么需要专门的工具
///
/// 审核截图有硬性尺寸，而且**各平台不同**：iOS 至少 640 × 920，
/// **macOS 要 1280 × 800**。而设计对照用的那几张是"窗口多大就拍多大"
/// （偏好页只有 440 × 430）—— 直接上传会被 ASC 以"尺寸不对"退回来，
/// 而那个报错只说"尺寸不对"，不告诉你该多大。
///
/// 这一支的做法：把**真界面**按 2–3 倍离屏渲染，再超采样缩进 1280 × 800 的画布，
/// 旁边配上说明，并用一个标注框指出购买入口。全程**不需要屏幕录制授权** ——
/// 所以它可以在任何机器上重跑，产物也不受开发机分辨率影响。
///
/// ## 两张图各自回答什么
///
/// | 商品 | 审核员要看到的 | 画的是 |
/// | --- | --- | --- |
/// | `…pro`（买断） | 用户在哪买 | 偏好设置 → 通用页底部那块 Pro 状态区 |
/// | `…pro.trial`（试用） | 用户在哪开始试用 | 覆盖层里的升级卡片（主按钮是「7 天免费试用」） |
///
/// ⚠️ 图上的标注框是**按运行期算出来的矩形**画的（`proPanelFrameInContent`、
/// `ProCardLayout.Content.primary`），不是从源码里估的坐标 ——
/// 布局一改，估的坐标会静静指到别处，而那张图会原样上传给审核。
@MainActor
enum ReviewShots {

    /// ASC 要的尺寸。macOS：1280 × 800。
    static let canvasSize = CGSize(width: 1280, height: 800)

    // MARK: - 入口

    static func render(shortcut: ShortcutService,
                       preferences: UserDefaultsPreferencesStore,
                       output: UserDefaultsOutputStore,
                       into directory: URL) -> [String] {
        // ⚠️ **把外观钉死**。`ChromePalette.Theme.current` 读的是 `NSApp.effectiveAppearance`，
        // 而窗口自己的底、面板、按钮却各自按主题取色 —— 不钉的话会出现
        // "窗口内底是浅色、面板是深色"这种**半深半浅**的图（第一版就是这个毛病，
        // 因为画布用了固定浅色而 app 当时是深色外观）。
        NSApp.appearance = NSAppearance(named: .darkAqua)

        var written: [String] = []

        // ── ① 买断：偏好设置 → 通用页
        let prefs = PreferencesWindowController(shortcut: shortcut,
                                                preferences: preferences,
                                                output: output)
        prefs.present()
        prefs.select(.general)
        if let url = purchaseEntryShot(prefs: prefs, into: directory) {
            written.append(url.path)
        }
        prefs.window?.orderOut(nil)

        // ── ② 试用：覆盖层里的升级卡片
        if let url = trialEntryShot(into: directory) {
            written.append(url.path)
        }

        return written
    }

    // MARK: - ① 买断：偏好页那一段

    private static func purchaseEntryShot(prefs: PreferencesWindowController,
                                          into directory: URL) -> URL? {
        guard let content = prefs.window?.contentView else { return nil }
        let theme = ChromePalette.dark
        // 2 倍离屏渲：最后会被缩进 601 × 588 —— 超采样之后反而比 1 倍更锐。
        guard let rep = ComplianceSheet.rep(of: content,
                                            background: theme.background,
                                            scale: 2),
              let windowImage = rep.cgImage else { return nil }

        // 窗口内容的点尺寸（440 × 430）→ 画布上的落地矩形。**两套坐标系都是 y 向上**，
        // 所以直接用同一个比例换算（含下面那个标注框）。
        let dest = CGRect(x: 56, y: 72, width: 601, height: 588)
        // 标注框：**运行期算出来的**面板矩形（不是估的坐标）
        let box = prefs.proPanelFrameInContent.map { panel -> CGRect in
            let sx = dest.width / content.bounds.width
            let sy = dest.height / content.bounds.height
            return CGRect(x: dest.minX + panel.minX * sx,
                          y: dest.minY + panel.minY * sy,
                          width: panel.width * sx,
                          height: panel.height * sy).insetBy(dx: -6, dy: -6)
        }

        return compose(into: directory,
                       name: "iap-review-pro.png",
                       theme: theme,
                       heading: "Where Marquee Pro is purchased",
                       subheading: "购买入口：菜单栏图标 →「设置…」→ 通用页底部「升级到 Pro」", // L10N-EXEMPT: 审核截图上的标注
                       footer: footerLine()) { context in
            context.draw(windowImage, in: dest)

            if let box {
                Self.annotate(box: box, color: .systemBlue, context: context)
                Self.leader(from: CGPoint(x: box.maxX, y: box.midY),
                            to: CGPoint(x: 700, y: box.midY),
                            color: .systemBlue)
            }
            // 说明块**对齐标注框的竖向中心** —— 否则引线会指到一片空白里去。
            let startY = (box?.midY ?? 400) + CGFloat(Self.purchaseNotes.count - 1) * 13
            Self.drawLines(Self.purchaseNotes, at: CGPoint(x: 726, y: startY), theme: theme)
        }
    }

    // L10N-EXEMPT-START: 审核截图上的标注文字。它是给 Apple 审核员看的（也不进 app 界面），
    // 而里面夹着的几个中文正是界面上那两颗按钮的名字 —— 引用了才看得出对应关系。
    private static let purchaseNotes = [
        "Preferences window, General page.",
        "The highlighted box is the purchase entry.",
        "· 升级到 Pro  → buys com.tango.marquee.pro (non-consumable)",
        "· 恢复购买   → restores an earlier purchase",
        "The app itself is free; only this one purchase unlocks Pro.",
        "No account and no subscription are involved.",
    ]
    // L10N-EXEMPT-END

    // MARK: - ② 试用：升级卡片

    private static func trialEntryShot(into directory: URL) -> URL? {
        let content = ProCardContent(feature: .scrollCapture,
                                     reason: .neverPurchased,
                                     primary: .startTrial,
                                     secondary: .purchase)
        let theme = ChromePalette.dark
        let cardSize = ProCardLayout.size(includesMicro: true)
        // **与 app 同一条取价路径**（`ProEntitlement.priceText`）——
        // 于是这张图上是哪一句，就是用户真会看到的那一句。
        // 取不到价格时它会退化成不带价格的那句（那也如实反映运行时的样子）。
        let price = ProEntitlement.shared.priceText
        // 卡片按 **2 倍**落地。⚠️ 不能只把矩形放大 2 倍就画 ——
        // 那样字号还是 12/13 pt，在 600 × 280 的框里会缩成一小撮。
        // 正确做法是**缩放 CTM**：在卡片自己的坐标（300 × 140）里排布与绘制，
        // 由 CTM 放大到 2 倍。下面那个标注框也走同一套换算。
        let scale: CGFloat = 2
        let cardRect = CGRect(x: 104, y: 372,
                              width: cardSize.width * scale,
                              height: cardSize.height * scale)

        return compose(into: directory,
                       name: "iap-review-trial.png",
                       theme: theme,
                       heading: "Where the 7-day free trial is started",
                       subheading: "试用入口：覆盖层里的升级卡片（用户按下某个 Pro 功能时出现）", // L10N-EXEMPT: 同上
                       footer: footerLine()) { context in
            // 覆盖层那一层底（卡片坐在它上面）
            theme.panel.nsColor.setFill()
            NSBezierPath(roundedRect: cardRect.insetBy(dx: -48, dy: -48),
                         xRadius: 18, yRadius: 18).fill()

            context.saveGState()
            context.translateBy(x: cardRect.minX, y: cardRect.minY)
            context.scaleBy(x: scale, y: scale)
            let local = CGRect(origin: .zero, size: cardSize)
            // 卡片自己的材质底（`ProCardRenderer.draw` 只描边，底要自己铺）
            theme.panel.nsColor.setFill()
            NSBezierPath(roundedRect: local,
                         xRadius: ProCardLayout.cornerRadius,
                         yRadius: ProCardLayout.cornerRadius).fill()
            let layout = ProCardRenderer.layout(for: content, in: local, includesMicro: true)
            ProCardRenderer.draw(content, layout: layout, in: local, theme: theme,
                                 priceText: price)
            context.restoreGState()

            // 标注框：主按钮（「7 天免费试用」）。矩形取自**同一份布局**，不是估的。
            let primaryOnCanvas = CGRect(x: cardRect.minX + layout.primary.minX * scale,
                                         y: cardRect.minY + layout.primary.minY * scale,
                                         width: layout.primary.width * scale,
                                         height: layout.primary.height * scale)
            let box = primaryOnCanvas.insetBy(dx: -5, dy: -5)
            Self.annotate(box: box, color: .systemGreen, context: context)
            Self.leader(from: CGPoint(x: box.maxX, y: box.midY),
                        to: CGPoint(x: 700, y: box.midY),
                        color: .systemGreen)

            Self.drawLines(Self.trialNotes, at: CGPoint(x: 726, y: 596), theme: theme)
        }
    }

    // L10N-EXEMPT-START: 同上
    private static let trialNotes = [
        "The card that appears over the capture overlay",
        "when a Pro feature is used while on the free tier.",
        "",
        "The highlighted button starts com.tango.marquee.pro.trial:",
        "· a non-consumable IAP at price tier 0 (§3.1.1)",
        "· 7 days of every Pro feature",
        "· when it ends nothing is charged — the app returns",
        "  to the free tier (capture and annotate stay free)",
    ]
    // L10N-EXEMPT-END

    // MARK: - 画布与画法

    /// 铺一块 1280 × 800 的画布，画完标题与页脚，再把 `body` 交出去画主体。
    private static func compose(into directory: URL,
                                name: String,
                                theme: ChromePalette.Theme,
                                heading: String,
                                subheading: String,
                                footer: String,
                                body: (CGContext) -> Void) -> URL? {
        let size = canvasSize
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil,
                                      width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        theme.background.nsColor.setFill()
        CGRect(origin: .zero, size: size).fill()

        let margin: CGFloat = 56
        draw(heading, at: CGPoint(x: margin, y: size.height - margin - 36),
             size: 34, weight: .semibold, color: theme.label.nsColor)
        draw(subheading, at: CGPoint(x: margin, y: size.height - margin - 68),
             size: 16, color: theme.label2.nsColor)
        draw(footer, at: CGPoint(x: margin, y: 34), size: 13, color: theme.label2.nsColor)

        body(context)

        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: url)
        return url
    }

    private static func draw(_ text: String, at point: CGPoint,
                             size: CGFloat, weight: NSFont.Weight = .regular,
                             color: NSColor) {
        (text as NSString).draw(at: point,
                                withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                 .foregroundColor: color])
    }

    private static func drawLines(_ lines: [String], at point: CGPoint, theme: ChromePalette.Theme) {
        var y = point.y
        for line in lines {
            if !line.isEmpty {
                draw(line, at: CGPoint(x: point.x, y: y), size: 15,
                     color: line.hasPrefix("·") || line.hasPrefix("  ")
                        ? theme.label.nsColor
                        : theme.label2.nsColor)
            }
            y -= 26
        }
    }

    /// 标注框：**圆角描边 + 半透明底**，不是实心（不能盖住要说明的那个控件）。
    private static func annotate(box: CGRect, color: NSColor, context: CGContext) {
        color.withAlphaComponent(0.12).setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        path.fill()
        color.setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    /// 引线：从标注框拉到说明文字那一列。
    private static func leader(from start: CGPoint, to end: CGPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 2
        color.setStroke()
        path.stroke()
    }

    private static func footerLine() -> String {
        let identity = AppIdentity()
        let size = "\(Int(canvasSize.width))×\(Int(canvasSize.height))"
        return "Marquee · \(identity.bundleIdentifier) · rendered offscreen from the app's own UI "
            + "(no screen-recording permission needed) · \(size) — App Store Connect's required size for macOS"
    }
}

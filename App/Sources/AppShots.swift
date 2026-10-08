import AppKit
import MarqueeCore
import MarqueeEditor
import MarqueeHistory

/// 出**App Store 的 app 截图**（`-marqueeSmokeAppShots`）。
///
/// ## 与 `ReviewShots` 的分工
///
/// | | 出什么 | 尺寸 |
/// | --- | --- | --- |
/// | `ReviewShots`（`-marqueeSmokeReview`） | **内购**的审核截图：购买入口在哪、试用在哪开始 | 1280 × 800 |
/// | 本文档 | **app 本体**的商店截图：这个 app 长什么样、能干什么 | 2880 × 1800 |
///
/// ## 尺寸：取最高那一档，而且**只许缩小**
///
/// ASC 对 macOS 的规格是 **16:10，四档之一**：1280×800 / 1440×900 / 2560×1600 / **2880×1800**。
/// 取最高那档而不是最小那档 —— ASC 会**自动向下缩放**，反过来（小图被放大显示）只会糊。
/// 同理，窗口落在画布上时**只用 ≤ 1 的倍率**：源图本来就是超采样渲的，
/// 放大等于把已经插过一次值的像素再插一次。
///
/// ## 为什么**离屏**出图
///
/// 截图要用真界面，而"拍屏"这条路要屏幕录制授权（而且会拍到自己的桌面）。
/// 这一支把真窗口按 2–3 倍离屏渲染再排进画布，于是：
/// **不需要授权、不受开发机分辨率影响、任何机器上都能重跑**，改一行界面就能重出一套。
///
/// ⚠️ **两条边界要记住**：
/// 1. **材质（玻璃）任何离屏渲染都拍不到**，会退到实色档（PITFALLS 187）——
///    所以编辑器那张图上的工具条是 `--c-panel` 实色，不是 macOS 26 上那块玻璃。
/// 2. **覆盖层（选区 + 工具条）这一张出不了**：它是逐屏全屏面板，背后是**实时桌面**，
///    而拿实时桌面要 SCK（= 屏幕录制授权）。那张只能真机拍 —— 见
///    `docs/APP-STORE-CONNECT.md` §7 的两条命令。
@MainActor
enum AppShots {

    /// ASC 对 macOS 的截图规格（16:10）里**最高**的那一档。
    static let canvasSize = CGSize(width: 2880, height: 1800)

    /// 画布内边距。
    private static let margin: CGFloat = 120
    /// 右侧说明栏的宽度。
    private static let notesWidth: CGFloat = 820
    private static let notesGap: CGFloat = 72

    /// 小窗口（偏好 440 × 430 / 引导 440 × 336）的**源**渲染倍率：
    /// 它们在画布上会被放到 3 倍那么大，所以源就按 3 倍渲 —— 两头都是 1:1 的像素，不插值。
    private static let sourceScale: CGFloat = 3

    /// 说明栏排在哪。**显式指定**，不做"看图宽自动决定"那种启发式 ——
    /// 自动决定的坏处不是错，而是**每次改一行界面就可能换一种排法**，
    /// 而"上一版和这一版为什么不一样"没人查得出来。
    private enum NotesPlacement {
        /// 排在图的右边（窄窗口用 —— 长图那类没有横向余量）。
        case right
        /// 折在副标题下面（宽窗口用）。
        case below
    }

    private struct Content {
        let image: CGImage
        /// 图像对应的**点**尺寸（图像自身是 `pointSize × sourceScale` 像素）。
        let pointSize: CGSize
        let sourceScale: CGFloat

        var nativeSize: CGSize {
            CGSize(width: pointSize.width * sourceScale, height: pointSize.height * sourceScale)
        }
    }

    // MARK: - 入口

    static func render(shortcut: ShortcutService,
                       preferences: UserDefaultsPreferencesStore,
                       output: UserDefaultsOutputStore,
                       editor: AnnotationEditorPresenter,
                       into directory: URL) -> [String] {
        // 与 `ReviewShots` 同一个理由：主题跟着 `NSApp.effectiveAppearance` 走，
        // 不钉的话会出"窗口内是浅色、画布是深色"这种半深半浅的图。
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // ⚠️ 按**语言**分目录：ASC 是按本地化各要一套截图。
        // 这一支渲的是当前进程的界面语言（`-AppleLanguages "(en)"` 可以换一套，
        // 见 `docs/APP-STORE-CONNECT.md` §7 的两条命令）。
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let target = directory.appendingPathComponent("app-shots/\(language)", isDirectory: true)

        var written: [String] = []

        // ── ① 编辑器（头图）────────────────────────────────────────────────
        // 这张图要同时说清三件事：工具条在顶上、长图在画布上、状态行在地板上。
        // 用的是**真窗口的整窗渲染**，不是拼出来的示意图。
        let editorCaption = caption(.editor, language: language)
        let (page, annotations) = longPage(language: language)
        if let window = editor.windowSnapshot(image: page, segments: 7, seed: annotations, scale: 2),
           let url = compose(name: "app-01-editor.png",
                             heading: editorCaption.heading,
                             subheading: editorCaption.subheading,
                             notes: editorCaption.notes,
                             placement: .below,
                             content: Content(image: window,
                                              pointSize: EditorChrome.defaultWindowSize,
                                              sourceScale: 2),
                             into: target) {
            written.append(url.path)
        }

        // ── ② 最近截图面板 ─────────────────────────────────────────────────
        let recentCaption = caption(.recent, language: language)
        if let shot = recentPanelShot(),
           let url = compose(name: "app-02-recent.png",
                             heading: recentCaption.heading,
                             subheading: recentCaption.subheading,
                             notes: recentCaption.notes,
                             placement: .right,
                             content: Content(image: shot.image,
                                              pointSize: shot.size,
                                              sourceScale: sourceScale),
                             into: target) {
            written.append(url.path)
        }

        // ── ③④ 偏好设置两页 ───────────────────────────────────────────────
        let prefs = PreferencesWindowController(shortcut: shortcut,
                                                preferences: preferences,
                                                output: output)
        prefs.present()
        let pages: [(page: SettingsPage, name: String, shot: Shot)] = [
            (.capture, "app-03-preferences-capture.png", .preferencesCapture),
            (.shortcuts, "app-04-preferences-shortcuts.png", .preferencesShortcuts),
        ]
        for page in pages {
            prefs.select(page.page)
            let text = caption(page.shot, language: language)
            if let url = windowShot(prefs.window, name: page.name, heading: text.heading,
                                    subheading: text.subheading, notes: text.notes,
                                    placement: .right, into: target) {
                written.append(url.path)
            }
        }
        prefs.window?.orderOut(nil)

        // ── ⑤ 首次启动的引导 ───────────────────────────────────────────────
        let onboarding = OnboardingWindowController(shortcut: shortcut,
                                                    currentPermission: { .granted },
                                                    onShortcutChanged: { _ in })
        onboarding.present()
        let onboardingCaption = caption(.onboarding, language: language)
        if let url = windowShot(onboarding.window, name: "app-05-onboarding.png",
                                heading: onboardingCaption.heading,
                                subheading: onboardingCaption.subheading,
                                notes: onboardingCaption.notes,
                                placement: .right, into: target) {
            written.append(url.path)
        }
        onboarding.window?.orderOut(nil)

        return written
    }

    // MARK: - 截图上的说明文字（**按语言各一套**）

    // L10N-EXEMPT-START: App Store 截图上的说明文字。它是**给商店访客看的**（不进 app 界面），
    // 而且**必须按语言各写一套** —— 英文那套图是给英文店面用的，混着中文上去就是
    // "本地化没做完"的样子。`ReviewShots` 里那两张审核图是同一个道理。
    private enum Shot {
        case editor, recent, preferencesCapture, preferencesShortcuts, onboarding
    }

    private struct Caption {
        let heading: String
        let subheading: String
        let notes: [String]
    }

    private static func caption(_ shot: Shot, language: String) -> Caption {
        let english = language.hasPrefix("en")
        switch shot {
        case .editor:
            return english
                ? Caption(heading: "Annotate it before you paste it",
                          subheading: "Scrolling captures land in the editor; annotations stay editable objects, not baked-in pixels",
                          notes: ["The editor opens for scrolling captures only — an ordinary",
                                  "screenshot is annotated right on the overlay, with no window at all.",
                                  "",
                                  "· Rectangle / Ellipse / Arrow / Pen / Text / Counter",
                                  "· Mosaic and blur: redaction runs locally, nothing is uploaded",
                                  "· ⌘Z unwinds all the way back, cropping included"])
                : Caption(heading: "粘贴之前，先标好",
                          subheading: "滚动截屏拼出的长图直接进编辑器；标注是「可反复改的对象」，不是画上去的像素",
                          notes: ["编辑器只服务长截图 —— 普通截图在覆盖层上就地标注完就走，",
                                  "不弹任何窗口。（长图几千像素高，一屏放不下才需要这扇窗。）",
                                  "",
                                  "· 矩形 / 椭圆 / 箭头 / 画笔 / 文字 / 序号",
                                  "· 马赛克与模糊：打码在本机做，图不上传",
                                  "· ⌘Z 一路撤到底，裁切也能撤回来"])

        case .recent:
            return english
                ? Caption(heading: "Recent captures are still editable",
                          subheading: "The last few shots are one menu away; the original image and the annotation vectors are kept",
                          notes: ["· Click a thumbnail to copy it again",
                                  "· Edit reopens the editor — annotations stay selectable and undoable",
                                  "· Delete moves the file to the Trash",
                                  "",
                                  "The free tier keeps the last 5; Pro keeps them all."])
                : Caption(heading: "最近截图，还能接着改",
                          subheading: "刚截的那几张在菜单里就能翻到；存的是「原图 + 标注矢量」，点进去还能接着改",
                          notes: ["· 点缩略图 = 再复制一次",
                                  "· 编辑 = 重新进编辑器（标注还能选中、还能撤）",
                                  "· 删除 = 连文件一起进废纸篓",
                                  "",
                                  "免费版保留最近 5 张，Pro 不设上限。"])

        case .preferencesCapture:
            return english
                ? Caption(heading: "Settings that stay out of the way",
                          subheading: "Four pages: General / Capture / Output / Shortcuts. Every change applies and persists immediately",
                          notes: ["· Delay 0 / 3 / 5 / 10 s (clicks pass through the countdown)",
                                  "· Include the pointer in the shot",
                                  "· Include the window shadow on window captures",
                                  "· Output format / folder / file-name template"])
                : Caption(heading: "设置不挡路",
                          subheading: "四页：通用 / 截屏 / 输出 / 快捷键。改一下立刻生效、立刻落盘",
                          notes: ["· 延时截图 0 / 3 / 5 / 10 秒（倒计时期间点得穿）",
                                  "· 截图里要不要带鼠标指针",
                                  "· 窗口截图要不要带阴影",
                                  "· 输出格式 / 目录 / 命名模板"])

        case .preferencesShortcuts:
            return english
                ? Caption(heading: "Your shortcut, not ours",
                          subheading: "⌃Q by default; a new key applies at once, and a conflict says so and rolls back",
                          notes: ["· The global hot key is suspended while recording —",
                                  "  pressing the key you already use won't take a screenshot",
                                  "· Conflicts are reported in red, never silently",
                                  "· “Restore default” goes back to ⌃Q"])
                : Caption(heading: "用你自己的键",
                          subheading: "默认 ⌃Q；改键即时生效，被别人占用会当场说清并回滚",
                          notes: ["· 录制期间全局注册会「挂起」 ——",
                                  "  按自己正用的那颗键不会真的去截屏",
                                  "· 冲突有红字说明，不静默失败",
                                  "· 「恢复默认」一键回 ⌃Q"])

        case .onboarding:
            return english
                ? Caption(heading: "Three steps, all skippable",
                          subheading: "On first launch: what it is / pick a key / screen-recording permission — every step can be skipped",
                          notes: ["· The tour blocks nothing: the menu bar icon is already there",
                                  "· The permission row re-reads on every activation:",
                                  "  tick it in System Settings and the row updates itself",
                                  "· Self-check runs with a -marquee prefix never show it"])
                : Caption(heading: "三步，都能跳过",
                          subheading: "首次启动：它是什么 / 挑一个键 / 屏幕录制权限 —— 每一步都能跳过",
                          notes: ["· 引导不挡功能：菜单栏图标那时已经在",
                                  "· 授权那一行是「每次切回来重读」的：",
                                  "  在系统设置里勾上，它自己就变色",
                                  "· 带 -marquee 前缀的自检运行一律不弹它"])
        }
    }
    /// 合成网页上**被标注的那句话**。
    ///
    /// 它是**图里的内容**（相当于用户截图里那句话），不是界面文案 —— 但两套语言各出一套时
    /// **它也得跟着换**：英文店面里配一张写着中文标注的图，看起来就是"本地化没做完"。
    private static func sampleAnnotationText(language: String) -> String {
        language.hasPrefix("en") ? "Wrong column" : "这一列不对"
    }
    // L10N-EXEMPT-END

    // MARK: - 一个真窗口 → 画布上的内容

    private static func windowShot(_ window: NSWindow?,
                                   name: String,
                                   heading: String,
                                   subheading: String,
                                   notes: [String],
                                   placement: NotesPlacement,
                                   into directory: URL) -> URL? {
        guard let content = window?.contentView, content.bounds.width > 1 else { return nil }
        guard let rep = ComplianceSheet.rep(of: content,
                                            background: ChromePalette.dark.background,
                                            scale: sourceScale),
              let image = rep.cgImage else { return nil }
        return compose(name: name,
                       heading: heading,
                       subheading: subheading,
                       notes: notes,
                       placement: placement,
                       content: Content(image: image,
                                        pointSize: content.bounds.size,
                                        sourceScale: sourceScale),
                       into: directory)
    }

    /// 造一个"最近截图"面板：临时历史 + 五条 + 真控制器。
    ///
    /// ⚠️ 与 `-marqueeSmokeRecent` 用同一套构造方式（临时目录 + `CaptureHistoryStore`），
    /// 只是这里要的是**图**而不是尺寸报告。
    private static func recentPanelShot() -> (image: CGImage, size: CGSize)? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-appshot-recent-\(UUID().uuidString)", isDirectory: true)
        // ⚠️ 限量取**免费档的真值**（不是随手一个 12）：面板底部那行小字念的就是它，
        // 而写死 12 会让图上出现一句**产品里不存在**的话（免费版是 5 张）。
        let limit = ProLimits.default.freeHistoryLimit
        let store = CaptureHistoryStore(directory: directory, limit: limit)
        for index in 0..<limit {
            let target = Annotation(kind: .rectangle,
                                    frame: CGRect(x: 20, y: 24, width: 90, height: 60),
                                    zIndex: 0)
            _ = store.record(original: thumbnail(index),
                             originalPNG: nil,
                             annotations: index % 2 == 0 ? [target] : [],
                             at: Date().addingTimeInterval(TimeInterval(-index * 600)))
        }
        let controller = RecentCapturesPanelController(
            store: store,
            actions: .init(onCopy: { _ in }, onEdit: { _ in }, onDelete: { _ in }),
            currentShortcut: { KeyCombo.fullScreenCapture },
            upgradeCard: { ProCardContent(feature: .unlimitedHistory,
                                          reason: .neverPurchased,
                                          primary: .purchase,
                                          secondary: .restore) },
            onUpgradeAction: { _ in })
        _ = controller.view
        controller.reload()
        // ⚠️ 先给定尺寸再 layout：离屏视图没有窗口，`fittingSize` 不会自己变成 frame。
        controller.view.frame = CGRect(origin: .zero, size: controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize
        guard let rep = ComplianceSheet.rep(of: controller.view,
                                            background: ChromePalette.dark.panel,
                                            scale: sourceScale),
              let image = rep.cgImage else { return nil }
        return (image, size)
    }

    /// 一张合成缩略图（**不依赖屏幕采集** —— 出图这条路不该要屏幕录制授权）。
    private static func thumbnail(_ index: Int) -> CGImage {
        let size = CGSize(width: 320, height: 200)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil,
                               width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // 五张各一个色相，一眼看得出"这是五张不同的图"
        let hue = CGFloat(index) / 5
        context.setFillColor(NSColor(hue: hue, saturation: 0.28, brightness: 0.92, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor(hue: hue, saturation: 0.20, brightness: 0.66, alpha: 1).cgColor)
        for row in 0..<4 {
            context.fill(CGRect(x: 24, y: 30 + CGFloat(row) * 34,
                                width: 180 - CGFloat(row) * 22, height: 12))
        }
        return context.makeImage()!
    }

    // MARK: - 头图那张"长网页"

    /// 一张合成的长图（**1440 × 2000 原图像素**）+ 五个标注。
    ///
    /// 坐标一律按**图像像素、原点左上**（与标注模型一致）。画进 `CGContext` 时
    /// 要把"自上而下的行号"折过去（`y = 高 − 上边距 − 自身高`）——
    /// 直接按上下文坐标画，整页会**上下颠倒**，而那种错不崩不报错（PITFALLS 里那一类）。
    private static func longPage(language: String) -> (CGImage, [Annotation]) {
        let width = 1440
        let height = 2000
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil,
                               width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        /// 按"自上而下"的行号取矩形（画布的 y 向上，所以折一下）。
        func rect(_ top: CGFloat, _ leading: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: leading, y: CGFloat(height) - top - h, width: w, height: h)
        }
        func fill(_ top: CGFloat, _ leading: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
            context.setFillColor(color.cgColor)
            context.fill(rect(top, leading, w, h))
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 顶部一条深色工具条：一眼看出"这是别人的界面"
        fill(0, 0, CGFloat(width), 72, NSColor(white: 0.13, alpha: 1))
        fill(24, 24, 120, 24, NSColor(white: 0.38, alpha: 1))
        for index in 0..<3 {
            fill(26, 260 + CGFloat(index) * 64, 320, 16, NSColor(white: 0.62, alpha: 1))
        }

        // 标题 + 正文段（**这张图的第一个标注框就套在这里**）
        fill(120, 80, 760, 40, NSColor(white: 0.16, alpha: 1))
        fill(180, 80, 60, 16, NSColor(white: 0.45, alpha: 1))
        for (index, w) in [1240, 1180, 1260, 900].enumerated() {
            fill(226 + CGFloat(index) * 34, 80, CGFloat(w), 16, NSColor(white: 0.72, alpha: 1))
        }

        // 一块"截图"占位 + 一块"代码"
        fill(400, 80, 560, 320, NSColor(red: 0.90, green: 0.93, blue: 0.97, alpha: 1))
        fill(400, 720, 640, 320, NSColor(white: 0.11, alpha: 1))
        for index in 0..<8 {
            fill(428 + CGFloat(index) * 34, 748, CGFloat(560 - index * 30), 12,
                 NSColor(hue: 0.34, saturation: 0.45, brightness: 0.78, alpha: 1))
        }

        // 中段正文
        fill(790, 80, 520, 26, NSColor(white: 0.20, alpha: 1))
        for (index, w) in [1280, 1240, 1180, 1260, 700].enumerated() {
            fill(846 + CGFloat(index) * 34, 80, CGFloat(w), 16, NSColor(white: 0.74, alpha: 1))
        }

        // 一张表格（网格）
        for row in 0..<4 {
            fill(1060 + CGFloat(row) * 74, 80, 1280, 2, NSColor(white: 0.82, alpha: 1))
            for column in 0..<5 {
                fill(1076 + CGFloat(row) * 74, 96 + CGFloat(column) * 256, 200, 14,
                     NSColor(white: 0.66, alpha: 1))
            }
        }

        // 一段"个人信息"（**打码的目标**）
        fill(1440, 80, 420, 24, NSColor(white: 0.20, alpha: 1))
        for (index, w) in [520, 620, 460].enumerated() {
            fill(1494 + CGFloat(index) * 40, 80, CGFloat(w), 18, NSColor(white: 0.55, alpha: 1))
        }

        // 页脚
        fill(1880, 0, CGFloat(width), 120, NSColor(white: 0.94, alpha: 1))
        for index in 0..<3 {
            fill(1912, 120 + CGFloat(index) * 200, 160, 12, NSColor(white: 0.70, alpha: 1))
        }

        guard let image = context.makeImage() else {
            fatalError("合成页没画出来")
        }

        // ── 五个标注（**原图像素**，原点左上）────────────────────────────────
        let red = AnnotationStyle(stroke: .red, lineWidth: 16, fontSize: 88)
        let blue = AnnotationStyle(stroke: AnnotationColor(red: 0.05, green: 0.48, blue: 1),
                                   lineWidth: 16, fontSize: 88)
        let green = AnnotationStyle(stroke: AnnotationColor(red: 0.2, green: 0.78, blue: 0.35),
                                    lineWidth: 16, fontSize: 88)

        let arrowPath = [CGPoint(x: 700, y: 780), CGPoint(x: 1180, y: 470)]
        let penPath = [CGPoint(x: 140, y: 1790), CGPoint(x: 340, y: 1720),
                       CGPoint(x: 540, y: 1810), CGPoint(x: 780, y: 1730)]

        // ⚠️ 豁免标记必须挂在**字面量自己那一行**上：`L10N-EXEMPT` 只豁免它所在的那行
        //（`blank(from: lineStart, to: i)` —— 注释写在上面对它无效，而症状是"扫了还是红"）。
        // 文案在 `sampleAnnotationText(language:)` 里，按语言各一套。
        let sampleText = sampleAnnotationText(language: language)

        let annotations: [Annotation] = [
            Annotation(kind: .rectangle,
                       frame: CGRect(x: 64, y: 168, width: 1320, height: 180),
                       style: red, zIndex: 1),
            Annotation(kind: .arrow,
                       frame: AnnotationGeometry.frame(forPath: arrowPath,
                                                       lineWidth: green.lineWidth,
                                                       headFrom: arrowPath[0],
                                                       headTo: arrowPath[1]),
                       style: green, zIndex: 2, path: arrowPath),
            Annotation(kind: .mosaic,
                       frame: CGRect(x: 72, y: 1478, width: 700, height: 116),
                       style: AnnotationStyle(stroke: .red, lineWidth: 1, effectStrength: 32),
                       zIndex: 3),
            Annotation(kind: .pen,
                       frame: AnnotationGeometry.frame(forPath: penPath, lineWidth: blue.lineWidth),
                       style: blue, zIndex: 4, path: penPath),
            Annotation(kind: .text,
                       frame: AnnotationText.frame(text: sampleText,
                                                   fontSize: red.fontSize,
                                                   origin: CGPoint(x: 760, y: 1640)),
                       style: red, zIndex: 5,
                       text: sampleText),
        ]
        return (image, annotations)
    }

    // MARK: - 画布

    /// 铺一块 2880 × 1800 的画布：标题 + 副标题在上、页脚在下，
    /// 真界面按"**只许缩小**"的倍率落进中间，说明按 `placement` 排。
    private static func compose(name: String,
                                heading: String,
                                subheading: String,
                                notes: [String],
                                placement: NotesPlacement,
                                content: Content,
                                into directory: URL) -> URL? {
        let size = canvasSize
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // ⚠️ **不许带 alpha 通道** —— 与 `ReviewShots.compose` 同一条理由
        //（Apple 截图规格页："Images can't include alpha channels or transparencies"）。
        guard let context = CGContext(data: nil,
                                      width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        let theme = ChromePalette.dark
        // 画布底**用 app 自己的深色**（不另配一套宣传色）——
        // 截图周围那一圈也是产品的一部分，换个色系会让它看起来像别人的 app。
        theme.background.nsColor.setFill()
        CGRect(origin: .zero, size: size).fill()

        draw(heading, at: CGPoint(x: margin, y: size.height - margin - 78),
             size: 60, weight: .semibold, color: theme.label.nsColor)
        draw(subheading, at: CGPoint(x: margin, y: size.height - margin - 140),
             size: 30, color: theme.label2.nsColor)

        // 内容区：顶端在副标题之下，底端在页脚之上
        var top = size.height - margin - 190
        let bottom: CGFloat = 150
        if placement == .below {
            // 说明折在副标题下面 —— 于是图区上沿被它压下来
            let step: CGFloat = 46
            var y = top - 30
            for line in notes {
                if !line.isEmpty {
                    draw(line, at: CGPoint(x: margin, y: y), size: 28,
                         color: line.hasPrefix("·") || line.hasPrefix("  ")
                            ? theme.label.nsColor : theme.label2.nsColor)
                }
                y -= step
            }
            top = y - 10
        }

        var area = CGRect(x: margin, y: bottom,
                          width: size.width - margin * 2, height: top - bottom)
        let native = content.nativeSize
        // ⚠️ **只许缩小**：`k ≤ 1`。源图已经是超采样渲出来的，放大只会糊。
        var k = min(1, area.height / native.height, area.width / native.width)

        if placement == .right {
            let available = area.width - notesWidth - notesGap
            k = min(1, area.height / native.height, available / native.width)
        }

        let placed = CGSize(width: native.width * k, height: native.height * k)
        // **上沿对齐**（不是垂直居中）：标题在上面，图紧跟着它读起来是一段；
        // 居中会在标题与图之间留一大块空洞，而那看起来像"图没放完"。
        let dest = CGRect(x: area.minX,
                          y: area.maxY - placed.height,
                          width: placed.width, height: placed.height)
        // 图自带投影：它坐在深色台面上，没有投影会像一张贴纸
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 44
        shadow.shadowOffset = NSSize(width: 0, height: -16)
        shadow.set()
        context.draw(content.image, in: dest)
        NSGraphicsContext.restoreGraphicsState()

        if placement == .right, !notes.isEmpty {
            var y = dest.midY + CGFloat(notes.count) * 22
            for line in notes {
                if !line.isEmpty {
                    draw(line, at: CGPoint(x: dest.maxX + notesGap, y: y), size: 30,
                         color: line.hasPrefix("·") || line.hasPrefix("  ")
                            ? theme.label.nsColor : theme.label2.nsColor)
                }
                y -= 54
            }
        }

        draw(footer(), at: CGPoint(x: margin, y: 72), size: 22, color: theme.label2.nsColor)
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

    /// 页脚：**它是这张图"是真是假"的凭据** —— 尺寸、来源、UI 语言。
    /// 两套语言各出一套图时，光看窗口内容分不出哪套是哪套（app 里大半是图标）。
    private static func footer() -> String {
        let identity = AppIdentity()
        let language = Bundle.main.preferredLocalizations.first ?? "unknown"
        return "Marquee · \(identity.bundleIdentifier)"
            + " · \(Int(canvasSize.width))×\(Int(canvasSize.height))"
            + " (App Store Connect's size for macOS) · UI language: \(language)"
            + " · rendered offscreen from the app's own UI — no screen-recording permission needed"
    }
}

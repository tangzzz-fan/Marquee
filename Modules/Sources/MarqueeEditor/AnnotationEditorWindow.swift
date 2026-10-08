import AppKit
import MarqueeCore
import SwiftUI

/// 造一块"浮件材质底"的接缝。
///
/// ## 为什么要注入而不是在这里自己画
///
/// 材质**只有一份实现**（`ChromeBackground`，在 `MarqueeOverlay`），
/// 而按模块依赖方向 `MarqueeEditor` **不能** import 它。所以由宿主把工厂递进来。
///
/// 另一条路是"在编辑器里再画一块深色/玻璃底"—— 那条路更短，但两份实现迟早分叉，
/// 而最容易分叉的恰好是那条看不见的规则：**「降低透明度」打开时要退回实色**。
/// 分叉之后的表现是"开着辅助功能的人，覆盖层是对的不透明、编辑器标题栏还是半透明"——
/// 而那种错只在辅助功能开着时才看得见。
///
/// ⚠️ 返回的视图**必须不参与命中测试**：它是垫在内容下面的，吃掉鼠标
/// 就等于"工具条看得见、点它没反应"（`ChromeBackground` 那边已经包好了）。
///
/// - Parameter cornerRadius: 圆角。编辑器工具条是整条顶边，所以传 0。
///
/// ⚠️ 这里**不能**给 typealias 加 `@MainActor`（编译器不收："type alias cannot have
/// a global actor"）。隔离由持有它的那两处提供：`AnnotationEditorPresenter` 是
/// `@MainActor` 的，`NSViewRepresentable.makeNSView` 也只在主线程被调。
public typealias EditorBackgroundFactory = (CGFloat) -> NSView

/// 截图标注窗口。宿主拿到 PNG 后自己写剪贴板。
@MainActor
public final class AnnotationEditorPresenter {
    private var controllers: [AnnotationEditorWindowController] = []
    /// 文字识别器（ticket 13）。`nil` 时编辑器里不出现「识别文字」——
    /// 依赖由宿主注入：`MarqueeEditor` 不依赖 `MarqueeCapture`（模块依赖方向）。
    private let recognizer: TextRecognizing?
    /// 工具条的材质底（稿子 ⑩ §07：`.ebar` 进玻璃族）。同上，由宿主注入。
    private let background: EditorBackgroundFactory?

    public init(recognizer: TextRecognizing? = nil,
                background: EditorBackgroundFactory? = nil) {
        self.recognizer = recognizer
        self.background = background
    }

    /// 冒烟：把编辑器的工具条与状态行渲成 PNG，返回落盘路径。
    ///
    /// 只在 `-marqueeSmokeEditor` 那条路上被调用 —— 生产路径不碰它。
    @discardableResult
    public func renderChromeSnapshots(image: CGImage, into directory: URL) -> [String] {
        AnnotationEditorView.renderChromeSnapshots(image: image, into: directory)
    }

    /// `seed` 用来预置标注（开发演示用：`-marqueeDemoEditor`），正常流程为空。
    ///
    /// `segments` 是这张长图**拼了几段**（只有长截图那条路知道）。
    /// `nil` = 不知道，状态行就不说这一句 —— 见 `EditorChrome.leading`。
    ///
    /// `seed` 放在闭包**前面**：尾随闭包只能匹配最后一个参数，
    /// 把它放后面就没法用尾随闭包语法了（`present(image:seed:) { … }`）。
    public func present(image: CGImage,
                        seed: [Annotation] = [],
                        segments: Int? = nil,
                        onCopyPNG: @escaping @MainActor (Data) -> Void,
                        onSave: @escaping @MainActor (CGImage) -> Void) {
        let controller = AnnotationEditorWindowController(image: image,
                                                          onCopyPNG: onCopyPNG,
                                                          onSave: onSave,
                                                          seed: seed,
                                                          segments: segments,
                                                          recognizer: recognizer,
                                                          background: background)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.present()
    }
}

@MainActor
final class AnnotationEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClosed: (() -> Void)?

    /// 编辑器窗口的默认尺寸。
    ///
    /// ⚠️ 宽度不是拍脑袋定的：工具栏那一排控件（9 个标注工具 + 5 个色点 + 3 档线宽
    /// + 「识别文字」+ 缩放 + 提示文本，外加十几处间距）实测约 **1110 点**。
    /// 原来给的 960 **放不下** —— `HStack` 里的 `Spacer()` 在空间不足时会缩成 0，
    /// 超出的部分被直接挤掉，**最右边的「识别文字」和缩放控件首当其冲**。
    /// 用户当时的反馈正是"OCR 入口我不知道在哪"：不是没找到，是它压根没画出来。
    ///
    /// `minSize` 同理：窗口窄到放不下工具栏就没有意义了，所以下限也抬到工具栏宽度之上。
    private static let defaultSize = NSSize(width: EditorChrome.defaultWindowSize.width,
                                            height: EditorChrome.defaultWindowSize.height)
    /// ⚠️ 下限由 **Core 算出来**（`EditorChrome.minimumWindowSize`）——
    /// 它是整条工具条所需的最小宽度（红绿灯 + 九个工具 + 托盘 + 尺寸芯片 + 缩放 + 右簇）。
    /// 写死一个数的话，往条上加一件东西就会让最右边那几格**被静默裁掉**
    ///（这条路径不崩不报错，只是少了几个按钮 —— 历史上真的发生过）。
    private static let minimumSize = NSSize(width: EditorChrome.minimumWindowSize.width,
                                            height: EditorChrome.minimumWindowSize.height)

    init(image: CGImage,
         onCopyPNG: @escaping @MainActor (Data) -> Void,
         onSave: @escaping @MainActor (CGImage) -> Void,
         seed: [Annotation] = [],
         segments: Int? = nil,
         recognizer: TextRecognizing? = nil,
         background: EditorBackgroundFactory? = nil) {
        // ⚠️ **工具条即标题栏**（设计稿 §10 的登记项之一）：
        // `.fullSizeContentView` 让内容铺到标题栏底下，标题条透明且不画标题 ——
        // 于是那 48 点里放的是工具，而不是"标题 + 工具"两行。
        // 省下的那一行全部给了画布，而画布是这扇窗存在的理由。
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.t("标注")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // 窗口底 = `--c-bg`（台面另有一块更暗的 `--c-inset`，在画布那层）。
        window.backgroundColor = ChromePalette.dark.background.nsColor
        super.init(window: window)
        window.delegate = self

        let root = AnnotationEditorView(image: image,
                                        onCopyPNG: onCopyPNG,
                                        onSave: onSave,
                                        seed: seed,
                                        segments: segments,
                                        recognizer: recognizer,
                                        background: background) { [weak self] in
            self?.close()
        }
        contentViewController = NSHostingController(rootView: root)

        // ⚠️ 尺寸必须在设置 `contentViewController` **之后**再定一次。
        //
        // `contentViewController` 的 setter 会按视图的 `fittingSize` 重排窗口，
        // 而画布用的是 `GeometryReader` —— 它**没有固有尺寸**（ideal size 就是 10×10），
        // 于是上面 `NSWindow(contentRect:)` 里给的 960×680 会被这一步覆盖掉，
        // 窗口缩成"工具栏那一条"。用户看到的现象是"编辑器没弹出来"。
        //
        // 这类问题的坑点在于：**窗口确实创建了、也叫到前台了**，
        // 只是面积几乎为零 —— 从现象上完全看不出是尺寸问题。
        window.setContentSize(Self.defaultSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AnnotationEditorWindowController 只支持代码创建")
    }

    /// 呈现窗口。
    ///
    /// ⚠️ `orderFrontRegardless()` **不能省**。
    ///
    /// Marquee 是 `.accessory` 应用（`main.swift` 的 `setActivationPolicy(.accessory)`，
    /// 无 Dock 图标），而 `makeKeyAndOrderFront` **依赖应用已经是 active 的** ——
    /// 一个刚从前台退下来的 accessory 应用调它，窗口很可能开在别的窗口后面。
    /// 用户看到的现象是"按了 `⏎`，编辑器窗口没出来"（其实已经开好了，
    /// 只是被盖住 —— 而"窗口没出来"和"截图失败"在他眼里是完全一样的）。
    ///
    /// 覆盖层没有暴露这个问题，是因为它用的是高层级 `NSPanel`（盖在所有东西上）；
    /// 编辑器是普通层级的 `NSWindow`，正好踩中。
    /// `orderFrontRegardless()` 不看应用的激活状态，是 Apple 给这类场景的 API。
    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClosed?()
        onClosed = nil
    }
}

/// SwiftUI Canvas 是唯一的交互渲染后端。见 `docs/RENDER-BENCH.md`。
enum SwiftUICanvasBackend: CanvasRendering {
    static var backendName: String { "SwiftUI.Canvas" }
}

private struct AnnotationEditorView: View {
    let image: CGImage
    let onCopyPNG: (Data) -> Void
    /// 保存到磁盘（ticket 23 剩下的一半）。传的是**栅格化后的图** ——
    /// 落盘的目录 / 格式 / 命名由宿主按输出设置决定，编辑器不碰那些。
    let onSave: (CGImage) -> Void
    let onClose: () -> Void

    /// 工具条的材质底（稿子 ⑩ §07：`.ebar` 进玻璃族）。
    /// `nil` 时退回**实色** `--c-panel` —— 那不是"没做"，而是与
    /// 「降低透明度」同一个回退档（`ChromeMaterial.opaque`）。
    let background: EditorBackgroundFactory?

    /// 文字识别（ticket 13）。`nil` = 宿主没注入，工具栏上就不出现「识别文字」。
    @State private var ocr: TextRecognitionService?
    @State private var showOCRPanel = false
    /// 那张纸被拖到哪了。`nil` = **还没拖过**，贴默认的右下角。
    ///
    /// 为什么用"有没有拖过"而不是"记一个坐标"：默认位置要跟着画布尺寸走
    ///（窗口一缩放，`nil` 这条路上的右下角自动重算），而拖过之后就是用户的决定了。
    @State private var ocrPanelOrigin: CGPoint?
    /// 那张纸有多大。拖动要夹取，而夹取要知道尺寸 —— 尺寸由内容决定（四张脸的高度不同），
    /// 所以只能量（`GeometryReader` 垫在纸背后），不能写死。
    @State private var ocrPanelSize = CGSize(width: 260, height: 120)
    /// 拖动起点（画布坐标，只在一次拖动期间有值）。
    @State private var ocrDragStart: CGPoint?

    @State private var session: AnnotationEditorSession
    @State private var viewport = CanvasViewport()
    @State private var didFit = false
    /// 当前缩放**是不是**「适应窗口」那一个 —— 状态行那四个字只在它为真时出现。
    @State private var zoomIsFitted = false
    /// 文字预设弹层开着没有。选中文字工具时自动开；用户点别处收掉之后工具仍是文字。
    @State private var showTextPresets = false
    @State private var dragging = false
    @State private var canvasSize = CGSize.zero
    /// 打码结果的缓存。CoreImage 一次 2.6 ms，不能每帧重算 ——
    /// 键是"框 + 强度 + 类型"，改了才重做。
    @State private var redactionCache: [UUID: RedactionCacheEntry] = [:]
    /// 裁切模式下正在拖的东西：某个角，或整框平移
    @State private var cropDrag: CropDrag?
    /// 正在编辑内容的文字标注（新落的空文字或双击唤起的）
    @State private var editingID: UUID?
    @State private var editingText = ""
    @FocusState private var editingFocused: Bool

    /// 色板来自 **Core 的共享定义**，与覆盖层浮动工具栏用的是同一份。
    ///
    /// 各写一份会分叉，而分叉的表现是"在覆盖层里挑的橙，进编辑器变成了另一个橙" ——
    /// 没人会往"两份常量"上面想，只会觉得颜色自己变了。
    ///
    /// ⚠️ **尺寸那三档刻意不在这里**：它们由 `OverlaySizeMeaning.editorValues` 给
    ///（同一个位置按当前工具换含义：线宽 / 字号 / 打码强度），Core 是唯一来源。
    /// 这里原先还躺着三个平行的数组（线宽 / 字号 / 打码强度），其中字号那个**已经与 Core 分叉**
    ///（写的 24 / 36 / 56，而 Core 是 36 / 56 / 88）—— 而三个都**没有任何读取方**，是死代码。
    /// 删掉比留着强：它们的分叉只在"有人顺手接入"的那天才发作，而那时没人会去比对 Core。
    private let colors = AnnotationPalette.colors

    /// 这张长图是**几段拼出来的**。`nil` = 宿主没传（不知道）。
    ///
    /// ⚠️ 不许在这里编一个数：状态行是"说真话"的地方，编出来的「4 段拼接」比不说更糟
    ///（`EditorChrome.leading` 的判据就是按这条写的：`nil` 或 1 都不显示）。
    /// 只有长截图那条路知道真值 —— 普通截图（就地标注）与 `-marqueeDemoEditor` 都是 `nil`。
    let segments: Int?

    init(image: CGImage,
         onCopyPNG: @escaping (Data) -> Void,
         onSave: @escaping (CGImage) -> Void,
         seed: [Annotation] = [],
         segments: Int? = nil,
         recognizer: TextRecognizing? = nil,
         background: EditorBackgroundFactory? = nil,
         onClose: @escaping () -> Void) {
        self.image = image
        self.onCopyPNG = onCopyPNG
        self.onSave = onSave
        self.onClose = onClose
        self.background = background
        self.segments = segments
        // 识别器只在**首次**建视图时被用一次：`State(initialValue:)` 之后重建视图不会重置它，
        // 否则识别到一半重建一次就会把结果丢掉。
        _ocr = State(initialValue: recognizer.map { TextRecognitionService(recognizer: $0) })
        // ⚠️ 样式用**编辑器那一套**（`editorDefaultStyle`），不是 `AnnotationStyle.default`：
        // 后者那四个数是覆盖层的（线宽 4 点、字号 36 点、打码 12 点）。
        // 接错的表现很具体：进编辑器时「4 px」被点亮 —— 而 4 是编辑器那三档里**最小**的一档，
        // 于是用户第一笔就画了一根细线，还以为默认是中档。
        var initial = AnnotationEditorSession(pixelSize: CGSize(width: image.width, height: image.height),
                                             style: AnnotationPalette.editorDefaultStyle)
        initial.document.annotations = seed
        _session = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            canvas
            statusLine
        }
        .background(ChromePalette.dark.background.color)
    }

    /// 把工具条与状态行各渲一张 PNG（**只在冒烟路径上跑**）。
    ///
    /// ## 为什么值得有它
    ///
    /// 工具条是 SwiftUI 拼的：Core 的首测钉住了那些数字（格 28 / 托盘 174 / 芯片 54 × 38 /
    /// 整条放得进窗口），但"摆出来是不是那样"只有眼睛能判 ——
    /// 而这一批恰好把整条重做了一遍（色板从弹层搬出来、尺寸加了读数、预设改住弹层）。
    ///
    /// `ImageRenderer` 让这一步不必靠人守在屏幕前：PNG 落在报告目录里，打开就能看。
    /// 它与 Core 的单测是**互补**的 —— 那边答"数对不对"，这边答"看起来对不对"。
    ///
    /// ⚠️ 渲染用的是**固定深色**（编辑器本来就不跟系统外观），所以 ImageRenderer
    /// 的默认环境（浅色）不会影响结果 —— 这也是"固定深色是刻意的"那条决定的副产品。
    @MainActor
    static func renderChromeSnapshots(image: CGImage, into directory: URL) -> [String] {
        // ⚠️ 传一个**假的识别器**：编辑器里那一格是 `if let ocr` 才画的，
        // 而真机上只有 Pro 用户进得来这个窗口（长截图 ⇒ Pro），
        // 所以他看到的**一定**带那一格。不传的话这张快照会少一格，
        // 而"少了一格"看起来就像编辑器根本没有识别文字能力。
        let view = AnnotationEditorView(image: image,
                                        onCopyPNG: { _ in },
                                        onSave: { _ in },
                                        recognizer: SnapshotRecognizer(),
                                        onClose: {})
        var written: [String] = []
        func render(_ content: some View, name: String) {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let rendered = renderer.cgImage,
                  let png = ImageEncoding.pngData(from: rendered) else { return }
            let url = directory.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: url)
            written.append(url.path)
        }
        render(view.toolbar.frame(width: EditorChrome.defaultWindowSize.width,
                                  height: EditorChrome.toolbarHeight), name: "editor-toolbar.png")
        render(view.statusLine.frame(width: EditorChrome.defaultWindowSize.width), name: "editor-status.png")
        // 状态行**带段数**那一版（长截图那条路才会出现的一句话）。
        // 为什么要单独渲一张：段数是从宿主一路递进来的（`segments`），
        // 而"递到了没有"在 Core 里测不出来 —— 它是接线，只能看。
        let stitched = AnnotationEditorView(image: image,
                                            onCopyPNG: { _ in },
                                            onSave: { _ in },
                                            segments: 12,
                                            recognizer: SnapshotRecognizer(),
                                            onClose: {})
        render(stitched.statusLine.frame(width: EditorChrome.defaultWindowSize.width),
               name: "editor-status-stitched.png")
        // 文字预设弹层那两段（它会因为「序号」多长出一截）
        render(view.textPresetPopover.background(ChromePalette.dark.panel.color), name: "editor-presets.png")
        // 裁切读数框（稿子 §07 c）：**它平时只在拖保留框时出现**，
        // 而"132 宽放不放得下两行字"只有渲出来才看得见 —— 这是它唯一的目视证据。
        // ⚠️ 专门渲两张：一张按稿子的尺寸，一张用长截图的常规高度（`12000`），
        // 后者会**把框撑宽**（写死 132 的话尾巴数字会被裁掉）。
        render(panel(view.cropReadoutBox(CropReadout.lines(crop: CGSize(width: 1400, height: 620),
                                                           original: CGSize(width: 1440, height: 2000)))),
               name: "editor-crop-readout.png")
        render(panel(view.cropReadoutBox(CropReadout.lines(crop: CGSize(width: 1440, height: 12000),
                                                           original: CGSize(width: 1440, height: 12000)))),
               name: "editor-crop-readout-tall.png")
        // 识别面板的一张脸（它的外壳在这一轮成了"可拖的纸"，标题条是把手）
        if let service = view.ocr {
            render(panel(view.ocrPanelContent(service)), name: "editor-ocr-panel.png")
        }
        return written
    }

    /// 给快照垫一层画布底色。**不能省**：面板与读数框都是深底上的浮件，
    /// 直接渲在透明底上，边与投影都看不见（"看不见边"会被误读成"没有边"）。
    private static func panel(_ content: some View) -> some View {
        content.padding(20).background(ChromePalette.dark.inset.color)
    }

    // MARK: - 工具条（= 标题栏）

    /// 整条工具条。**位置永固定**（设计稿 §02）。
    ///
    /// 九个工具在窗口存在的每一秒都待在同一格 —— 这是"用鼠标找回工具的时间为零"的原因。
    /// 所以任何"会长出来的东西"都住在弹层里：文字预设挂在文字格上（§05），
    /// 第一行因此**永不重排**（判断 3）。
    ///
    /// ⚠️ 整条有一个**宽度下限**（`EditorChrome.minimumToolbarWidth`），窗口的 `minSize`
    /// 就按它定。放不下的后果不是崩溃，而是最右边那几格**被静默裁掉** ——
    /// 历史上有过一次，用户报的是「OCR 入口我不知道在哪」。
    private var toolbar: some View {
        HStack(spacing: EditorChrome.toolbarGap) {
            // 红绿灯是**系统**画在标题栏上的（`.fullSizeContentView` 之后它们浮在工具条上），
            // 我们只把这一段让出来 —— 72 点，与 macOS 自己那三颗所占的宽度相当。
            Color.clear.frame(width: EditorChrome.trafficLightsWidth)

            // 1–8 标注工具
            toolButton(.select)
            toolButton(.rectangle)
            toolButton(.ellipse)
            toolButton(.arrow)
            toolButton(.pen)
            textToolButton
            toolButton(.mosaic)
            toolButton(.blur)

            // ｜ 9 裁切 ｜
            // 前后各一条分隔线：它**不改标注、改画布** —— 用线承认它不同类，
            // 但把它留在工具家族里（它与其他八个共用同一套手势：拖、Esc 退）。
            toolbarSeparator
            cropButton
            toolbarSeparator

            colorTray
            toolbarSeparator
            sizeChips
            toolbarSeparator
            zoomControls

            Spacer(minLength: 8)

            // 右簇的顺序照旧：读走东西的 → 改状态的 → 落盘的 → 离场的
            if let ocr {
                ocrButton(ocr)
                toolbarSeparator
            }
            iconButton(L10n.t("撤销"), systemImage: AnnotationIcon.undo,
                       isEnabled: session.canUndo) { session.undo() }
            iconButton(L10n.t("重做"), systemImage: AnnotationIcon.redo,
                       isEnabled: session.canRedo) { session.redo() }
            toolbarSeparator
            iconButton(L10n.t("保存到磁盘并关闭（⌘S）"), systemImage: AnnotationIcon.save) {
                saveAndClose()
            }
            // ⚠️ `✗` 与 `✓` 永远压在整条最右端，`✗` 前额外让开 8（④ 的分组规则一字未改）。
            iconButton(L10n.t("取消（丢弃刚画的标注，不改剪贴板）"),
                       systemImage: AnnotationIcon.cancel,
                       tint: ChromePalette.Overlay.cancel.color) {
                onClose()
            }
            .padding(.leading, EditorChrome.gapBeforeCancel)
            iconButton(L10n.t("完成（复制到剪贴板并关闭）"),
                       systemImage: AnnotationIcon.confirm,
                       tint: ChromePalette.Overlay.done.color) {
                copyAndClose()
            }
        }
        .padding(.horizontal, EditorChrome.toolbarPadding)
        .frame(height: EditorChrome.toolbarHeight)
        .background { toolbarBackground }
        .overlay(alignment: .bottom) { hairline }
    }

    /// 工具条的底。
    ///
    /// 稿子 ⑩ §07 把 `.ebar` 列进了玻璃族，并附一条约束：
    /// 「**与画布的接缝保持 1px `--c-hair`**」—— 那条接缝是下面那个 `hairline` overlay，
    /// 换成玻璃之后它反而更要紧：透明材质与画布之间没有那条线，两者会糊成一片，
    /// 而"工具条在哪结束、图从哪开始"正是这个窗口唯一的层级信息。
    @ViewBuilder
    private var toolbarBackground: some View {
        if let background {
            MaterialBackground(radius: 0, factory: background)
        } else {
            // 没有注入材质（命令行冒烟、SwiftUI 预览）→ 与「降低透明度」同一档的实色。
            ChromePalette.dark.panel.color
        }
    }

    /// 文字格：它与别的格**多一件事** —— 选中它时，预设弹层挂在它上面（§05）。
    ///
    /// ⚠️ 预设不是工具，所以它不进第一行；弹层由工具选中自动唤出，
    /// 而用户点别处把它收掉之后**工具仍然是文字**（弹层只是便利，不是模式）。
    private var textToolButton: some View {
        toolButton(.text)
            .popover(isPresented: $showTextPresets, arrowEdge: .bottom) {
                textPresetPopover
            }
    }

    /// 文字预设弹层：两个预设 + 「从几开始」。
    ///
    /// 稿子：`.pop--text{width:198px}`，两段分别是「文字」「序号」，
    /// 选「序号」之后在**分段控件正下方**长出「从几开始」那一行。
    /// 两段都不带解释文字 —— 「文字 / 序号」这两个词本身就是解释。
    ///
    /// ⚠️ 外壳用**系统 popover**（材质 / 圆角 / 舌尖 / 点外收起来都由它保证），
    /// 与最近截图面板同一个取舍：自己画那块外壳要重新实现一整套行为。
    /// 唯一的小差别：系统 popover 的舌尖对着格子的中点，而不是像稿子那样让弹层左缘与格左缘对齐。
    private var textPresetPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("预设"))
                .font(.system(size: 11))
                .foregroundStyle(ChromePalette.dark.label2.color)

            HStack(spacing: 2) {
                presetSegment(L10n.t("文字"), preset: .plain, systemImage: AnnotationIcon.presetText)
                presetSegment(L10n.t("序号"), preset: .counter, systemImage: AnnotationIcon.presetCounter)
            }

            if session.textPreset == .counter {
                counterRow
                Text(L10n.t("放一个，数字 +1（1–99）"))
                    .font(.system(size: 11))
                    .foregroundStyle(ChromePalette.dark.label2.color)
            }
        }
        .padding(12)
        .frame(width: 198, alignment: .leading)
    }

    private func presetSegment(_ title: String,
                               preset: AnnotationEditorSession.TextPreset,
                               systemImage: String) -> some View {
        let selected = session.textPreset == preset
        return Button {
            session.textPreset = preset
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            // 稿子：「底色 7% 的那一段 = 当前预设」（不是填充蓝 —— 蓝色在这个产品里
            // 的含义是"当前生效的工具/颜色/档位"，预设的选中是"这一支笔现在写什么"）。
            .background(selected ? Color.white.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? ChromePalette.dark.label.color : ChromePalette.dark.label2.color)
    }

    /// 「从几开始」：− 当前值 + 。
    ///
    /// 它是**这支笔的一个参数**，不是"设置" —— 所以它长在预设弹层里，
    /// 改它和改颜色是同一级动作（稿子 §05）。
    private var counterRow: some View {
        HStack(spacing: 6) {
            Text(L10n.t("从几开始"))
                .font(.system(size: 11))
                .foregroundStyle(ChromePalette.dark.label2.color)
            Spacer(minLength: 8)
            counterStep(systemImage: AnnotationIcon.zoomOut, title: L10n.t("减少")) {
                session.setCounterStart(session.nextCounter - 1)
            }
            Text("\(session.nextCounter)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ChromePalette.dark.label.color)
                .frame(width: 26)
            counterStep(systemImage: AnnotationIcon.zoomIn, title: L10n.t("增加")) {
                session.setCounterStart(session.nextCounter + 1)
            }
        }
    }

    private func counterStep(systemImage: String, title: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(ChromePalette.dark.label.color)
        .help(title)
    }

    /// 色板托盘：**从覆盖层的「样式」弹层搬进条上**（§10 的登记项）。
    ///
    /// 理由两条：brief 要求整条放大稿里看得见它；而编辑器停留最久，
    /// 颜色与尺寸是最高频的两个控件 —— 收进弹层等于每次多一次点击。
    /// 编辑器因此**没有「样式」格**：它的职责已经摊在条上。
    private var colorTray: some View {
        HStack(spacing: EditorChrome.swatchGap) {
            ForEach(colors, id: \.self) { color in
                Button {
                    session.setStrokeColor(color)
                } label: {
                    swatch(color)
                }
                .buttonStyle(.plain)
                .help(L10n.t("描边颜色"))
            }
        }
        .padding(6)
        .background(ChromePalette.dark.inset.color)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 一个色块。
    ///
    /// 当前色 = **白圈**（稿子 `.sw.is-cur`：`0 0 0 2px 面板色, 0 0 0 3.5px 白`）——
    /// 之所以是"面板色隔一圈再描白"，是为了让白圈**不贴着色块**：
    /// 白色色块配白圈会糊成一块，中间那圈底色把它分开了。
    private func swatch(_ color: AnnotationColor) -> some View {
        let selected = session.style.stroke == color
        return RoundedRectangle(cornerRadius: 5)
            .fill(swiftUI(color))
            .frame(width: EditorChrome.swatchSize, height: EditorChrome.swatchSize)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .padding(-3)
                }
            }
            .overlay {
                // 浅色块在深托盘上本来就看得出，但白块与托盘的内底只差一点 ——
                // 补一圈极淡的描边（稿子 `.hairedge`）
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
            .contentShape(Rectangle())
    }

    /// 尺寸三档 + **常显读数**。
    ///
    /// ⚠️ 读数（「8 px」）是这一批的关键件：编辑器里这三个数是**原图像素**，
    /// 而芯片画的是"细 / 中 / 粗"（不追真值）—— 所以真值必须**一直在场**，
    /// 否则用户永远不知道自己在调多大（§08）。
    private var sizeChips: some View {
        let target = sizeTarget
        let values = target.meaning.editorValues
        return HStack(spacing: EditorChrome.chipGap) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Button {
                    switch target.meaning {
                    case .lineWidth: session.setLineWidth(value)
                    case .fontSize: session.setFontSize(value)
                    case .redactionStrength: session.setEffectStrength(value)
                    }
                } label: {
                    sizeSwatch(index: index, count: values.count, meaning: target.meaning,
                               selected: isActiveSize(value, meaning: target.meaning))
                }
                .buttonStyle(.plain)
                .help("\(target.label) \(Int(value)) px")
            }
            sizeReadout(value: target.current)
                .padding(.leading, 2)
        }
    }

    /// 当前档的真值读数：「8 px」——数字 12 点、单位 10 点。
    ///
    /// 单位小一号是有意的：它是**单位**，不是数值的一部分。
    private func sizeReadout(value: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(Int(value.rounded()))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ChromePalette.dark.label.color)
            Text("px")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(ChromePalette.dark.label2.color)
        }
    }

    /// 缩放：− 百分数 + 。**点百分数回「适应窗口」**。
    private var zoomControls: some View {
        HStack(spacing: 0) {
            iconButton(L10n.t("缩小"), systemImage: AnnotationIcon.zoomOut) {
                zoom(by: 1 / 1.25)
            }
            .frame(width: EditorChrome.zoomStepSize)
            Button {
                fitToWindow()
            } label: {
                Text("\(zoomPercent)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ChromePalette.dark.label.color)
                    .frame(width: EditorChrome.zoomLabelWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("点一下回到「适应窗口」"))
            iconButton(L10n.t("放大"), systemImage: AnnotationIcon.zoomIn) {
                zoom(by: 1.25)
            }
            .frame(width: EditorChrome.zoomStepSize)
        }
    }

    /// 状态行（窗口的地板）。**说真话**：这张图是什么、现在多少倍。
    ///
    /// 裁切进行中时左半边换成**模式动词** —— 那一会儿用户脑子里只有"现在按什么"；
    /// 尺寸并没有消失，画布上的读数框那时正在说"裁完多大"（判断 4）。
    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(EditorChrome.leading(pixelSize: session.document.canvasPixelSize,
                                      segments: segments,
                                      mode: cropMode))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(EditorChrome.trailing(zoomPercent: zoomPercent, isFitted: zoomIsFitted))
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(ChromePalette.dark.label2.color)
        .padding(.horizontal, EditorChrome.statusLinePadding)
        .frame(height: EditorChrome.statusLineHeight)
        .background(ChromePalette.dark.panel.color)
        .overlay(alignment: .top) { hairline }
    }

    private var cropMode: EditorChrome.Mode {
        guard session.isCropping else { return .normal }
        return session.isCropFrameAdjusted ? .croppingAdjusting : .croppingWaitingForFrame
    }

    private var zoomPercent: Int { Int((viewport.scale * 100).rounded()) }

    /// 一条发丝线。**用自绘而不是 `Divider()`**：后者的颜色由系统给，
    /// 在深色面板上时有时无，分隔感不稳定。
    private var hairline: some View {
        Rectangle()
            .fill(ChromePalette.dark.hairline.color)
            .frame(height: 1)
    }

    private func ocrButton(_ service: TextRecognitionService) -> some View {
        iconButton(service.isRunning ? L10n.t("识别中…") : L10n.t("识别文字"),
                   systemImage: service.isRunning ? AnnotationIcon.recognizing
                                                  : AnnotationIcon.recognizeText,
                   isActive: showOCRPanel,
                   isEnabled: !service.isRunning) {
            // ⚠️ 已有结果时**只把纸拿回来**，不重跑识别（稿子 §07 判断 5：
            // 「看完就关，或者拖到不碍事的角落」—— 收拢过的纸要能一眼找回）。
            // 重跑会让用户白等一次，而且结果可能与刚才那次不同（Vision 不是幂等的）。
            // 「不要这个结果」由面板上的 `✕` 承担（它 reset 状态）。
            if service.state == .idle {
                Task { await service.recognize(image) }
            }
            showOCRPanel = true
        }
    }

    // MARK: - 文字识别（ticket 13）

    /// 识别结果面板：**三态四张脸**（设计稿 §07）。
    ///
    /// ## 为什么是四张脸
    ///
    /// 「没有文字」与「识别失败」是**两件事**：前者要换地方，后者可以重试。
    /// 合成一张的话，用户在一张纯截图上会去点"重试" —— 而重试会得到同一个答案，
    /// 给一个注定没用的按钮比不给更让人恼火。
    ///
    /// ## 三条刻意的做法
    ///
    /// 1. **只读**（`textSelection` 而不是可编辑控件）：用户要的是「能划、能 ⌘C」，
    ///    不需要改。可编辑会多出"改了但没生效"这一整类疑惑 ——
    ///    而那个「只读」标签是**能力声明**，不是限制声明，所以它常显。
    /// 2. **四张脸都不留白**：每种情况第一行说发生了什么，第二行说下一步。
    ///    留白会让人以为坏了，而"正在识别"那一刻用户已经在等了。
    /// 3. **浮在画布上、不挤画布宽度**（判断 5）：识别结果只是"顺手看一眼"的东西。
    ///    侧栏会永久吃掉 260 宽 —— 而画布宽度是这扇窗存在的全部理由。
    /// 4. **它是可以挪走的纸**（2026-10-08 补）：默认贴右下角、**按住标题条能拖**、
    ///    **点画布就收拢**、`✕` 才关掉。判据（默认位置 / 夹取）在 Core
    ///    （`EditorPanelPlacement`），这里只负责接手势 —— 拖出窗口是一条**有去无回**的路
    ///    （`✕` 也在拖出去的那一半上），不该靠手拖去发现。
    @ViewBuilder
    private func ocrPaper(canvas: CGSize) -> some View {
        if showOCRPanel, let service = ocr {
            let origin = ocrPanelOrigin ?? EditorPanelPlacement.defaultOrigin(panel: ocrPanelSize,
                                                                             canvas: canvas)
            ocrPanelContent(service)
                // 量它自己的尺寸：四张脸高度不同（90–172），夹取必须知道真实大小。
                // ⚠️ 尺寸只喂给**夹取数学**，不参与纸自己的布局 ⇒ 不会形成回路。
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size, initial: true) { _, size in
                                ocrPanelSize = size
                            }
                    }
                }
                .offset(x: origin.x, y: origin.y)
        }
    }

    @ViewBuilder
    private func ocrPanelContent(_ service: TextRecognitionService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题条是这张纸的**把手**（稿子 §07：「按住标题条可以拖」）。
            // `contentShape` 不能省：这一行里只有文字与按钮有命中区，中间那段空白拖不动。
            // `help` 也不省：纸没有边框把手，"能拖"这件事没有别的说明处
            //（与钉图控制条的按钮同一条做法 —— tooltip 是它唯一的说明）。
            ocrHeader(service)
                .contentShape(Rectangle())
                .help(L10n.t("拖动面板"))
                .gesture(panelDragGesture)
            switch service.state {
            case .idle, .running:
                ocrFace(symbol: AnnotationIcon.recognizing,
                        title: L10n.t("正在识别…"),
                        body: L10n.t("首次识别可能要十几秒，之后会快。"))
            case .empty:
                // 颜色是**安静**的（次要色，无红）：没字不是错误，是这张图的属性。
                // 也没有「重试」—— 重试会得到同一个答案。
                ocrFace(symbol: "rectangle.dashed",
                        title: L10n.t("这张图里没有文字"),
                        body: L10n.t("纯图或图形界面都可能这样；识别只看整张图。"))
            case .failed:
                // 红是给"坏了"的：图标（警告三角）+ 标题**双通道**，
                // 而它比「没有文字」那张多一行按钮 —— 有路可走的和没路可走的不该一样高。
                ocrFace(symbol: "exclamationmark.triangle",
                        title: L10n.t("识别失败了"),
                        body: L10n.t("重试不会影响已经画好的标注。"),
                        tint: ChromePalette.dark.danger.color,
                        retry: { Task { await service.recognize(image) } })
            case .ready(let result):
                ocrResult(result, service: service)
            }
        }
        .padding(12)
        .frame(width: Self.ocrPanelWidth, alignment: .leading)
        .background(ChromePalette.dark.panel.color)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(ChromePalette.Overlay.panelBorder.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
    }

    /// 拖动那张纸。
    ///
    /// 按「起点 + 位移」算，**不是**「上一帧 + 增量」：后者会把被夹掉的那一段
    /// 累进下一次移动，表现是**纸越拖越贴边、再也拽不回来**（`EditorPanelPlacement.dragged` 里写着）。
    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = ocrDragStart
                    ?? ocrPanelOrigin
                    ?? EditorPanelPlacement.defaultOrigin(panel: ocrPanelSize, canvas: canvasSize)
                if ocrDragStart == nil { ocrDragStart = start }
                ocrPanelOrigin = EditorPanelPlacement.dragged(from: start,
                                                              by: value.translation,
                                                              panel: ocrPanelSize,
                                                              canvas: canvasSize)
            }
            .onEnded { _ in ocrDragStart = nil }
    }

    /// 面板宽。稿子 §07：「260 宽 · 高 90–172」—— 三张脸只差高度。
    private static let ocrPanelWidth: CGFloat = 260

    private func ocrHeader(_ service: TextRecognitionService) -> some View {
        HStack(spacing: 6) {
            Text(L10n.t("识别文字"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChromePalette.dark.label.color)
            if case .ready = service.state {
                // 「只读」常显。它是**能力声明**（能划、能 ⌘C），不是限制声明 ——
                // 藏起来反而让人以为"这里是能改的，只是我没找到入口"。
                Text(L10n.t("只读"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChromePalette.dark.label2.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Spacer(minLength: 8)
            Button {
                showOCRPanel = false
                service.reset()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ChromePalette.dark.label2.color)
            .help(L10n.t("关闭"))
        }
    }

    /// 那个空/失败/进行中的形状：一行图标 + 一句"发生了什么" + 一句"下一步"。
    @ViewBuilder
    private func ocrFace(symbol: String,
                         title: String,
                         body: String,
                         tint: Color? = nil,
                         retry: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint ?? ChromePalette.dark.label2.color)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint ?? ChromePalette.dark.label.color)
            }
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(ChromePalette.dark.label2.color)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button(action: retry) {
                    Text(L10n.t("重试"))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ChromePalette.dark.label.color)
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func ocrResult(_ result: TextRecognitionResult,
                           service: TextRecognitionService) -> some View {
        ScrollView {
            Text(result.fullText)
                .font(.system(size: 12))
                .foregroundStyle(ChromePalette.dark.label.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: 96)
        .background(ChromePalette.dark.inset.color)
        .clipShape(RoundedRectangle(cornerRadius: 6))

        HStack(spacing: 8) {
            // 「4 行 · 41 字」——让你知道手里这段有多长（要粘到别处之前，这个数有用）。
            Text(L10n.t("\(result.lines.count) 行 · \(result.characterCount) 字"))
                .font(.system(size: 11))
                .foregroundStyle(ChromePalette.dark.label2.color)
            Spacer(minLength: 8)
            Button {
                copyText(result.fullText)
            } label: {
                Text(L10n.t("全部复制"))
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ChromePalette.dark.label.color)
        }
    }

    /// 复制的是**文本**，不是图 —— 与「Esc 复制并关闭」那条走 PNG 的链路是两回事，
    /// 没必要为它再引一层剪贴板依赖。
    private func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 尺寸三档改的是**哪一个参数**：线宽 / 字号 / 打码强度。
    ///
    /// 三者互斥（文字没有线宽、打码没有字号），而工具栏已经很挤 ——
    /// 与其摆三排按钮，不如让同一排按钮改"当前真正相关的那个"。
    private struct SizeTarget {
        var meaning: OverlaySizeMeaning
        var label: String
        /// 当前生效的那个值 —— **常显读数**用它。
        var current: CGFloat
        var values: [CGFloat] { meaning.editorValues }
    }

    private var sizeTarget: SizeTarget {
        if session.tool == .mosaic || session.tool == .blur || selectionContainsRedaction {
            return SizeTarget(meaning: .redactionStrength, label: L10n.t("打码强度"),
                              current: session.style.effectStrength)
        }
        if session.tool == .text || selectionContainsText {
            return SizeTarget(meaning: .fontSize, label: L10n.t("字号"),
                              current: session.style.fontSize)
        }
        return SizeTarget(meaning: .lineWidth, label: L10n.t("线宽"),
                          current: session.style.lineWidth)
    }

    /// 一张尺寸芯片。
    ///
    /// 画的是"细 / 中 / 粗"，**不追真值** —— 88 px 的字装不进 38 高的芯片里。
    /// 真值交给旁边那个常显读数（§08：「芯片画法不追真值，真值交给读数与 1:1 预览」）。
    ///
    /// ⚠️ 大小按**档位序号**均分（`SizeSwatchGeometry`），不按数值线性映射 ——
    /// 打码那三档是 8 / 16 / 32，线性映射会画出 9.6 / 15.2 / 16，
    /// **后两档几乎一样大**，用户点了"最强"看不出变化。
    ///
    /// 字母那一支的**基准比圆点大一截**（40 对 21）：A 的可见高度只有字号的七成，
    /// 用同一个基准会让三个字母明显比三个圆点小一圈，而它们本该是"一样粗"的三档。
    private func sizeSwatch(index: Int,
                            count: Int,
                            meaning: OverlaySizeMeaning,
                            selected: Bool) -> some View {
        let shape = SizeSwatchGeometry.shape(for: meaning)
        let base: CGFloat = shape == .letter ? 40 : 21
        let side = base * SizeSwatchGeometry.relativeSide(index: index, of: count)
        return ZStack {
            switch shape {
            case .circle:
                Circle().fill(.white).frame(width: side, height: side)
            case .square:
                Rectangle().fill(.white).frame(width: side, height: side)
            case .letter:
                Text("A").font(.system(size: side, weight: .semibold))
            }
        }
        .frame(width: EditorChrome.chipSize.width, height: EditorChrome.chipSize.height)
        // 稿子：`.sz.is-cur{background:var(--c-fill);color:#fff}` ——
        // 芯片的"当前档"用**填充蓝**（与工具格、色板同一条规则：全条同类只许一个）。
        .background(selected ? ChromePalette.dark.fill.color : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? Color.white : ChromePalette.dark.icon.color)
        // 命中区就是整张芯片：不写这句的话，圆点周围那一圈空白点不动
        .contentShape(Rectangle())
    }

    private func isActiveSize(_ value: CGFloat, meaning: OverlaySizeMeaning) -> Bool {
        switch meaning {
        case .lineWidth: session.style.lineWidth == value
        case .fontSize: session.style.fontSize == value
        case .redactionStrength: session.style.effectStrength == value
        }
    }

    private var selectionContainsText: Bool {
        session.document.annotations.contains { session.selection.contains($0.id) && $0.kind == .text }
    }

    private var selectionContainsRedaction: Bool {
        session.document.annotations.contains { annotation in
            session.selection.contains(annotation.id)
                && (annotation.kind == .mosaic || annotation.kind == .blur)
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                draw(in: context)
            }
            .gesture(drag)
            // 双击文字进入改内容。用 `SpatialTapGesture` 是因为 `TapGesture` 不给坐标，
            // 而"双击了哪一个"必须靠坐标命中。
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                beginEditingText(at: value.location)
            })
            .background {
                EditorEventMonitor(
                    // `Esc` 要退哪一层所需的**全部**状态，一次给全。
                    // 层级顺序**不在这里** —— 判据在 Core 的 `EditorEscapeState.escapeStep()`。
                    // 顺序若写在视图里，就一定会和覆盖层那份分叉，
                    // 而分叉的表现只有用户按下去才知道："退掉的东西不对"。
                    escapeState: EditorEscapeState(isEditingText: editingID != nil,
                                                   isCropping: session.isCropping,
                                                   tool: session.tool,
                                                   selection: session.selection),
                    onEscapeStep: { handleEscapeStep($0) },
                    onConfirm: copyAndClose,
                    onSave: saveAndClose,
                    onDelete: { session.deleteSelection() },
                    onUndo: { session.undo() },
                    onRedo: { session.redo() },
                    onPan: { dx, dy in
                        zoomIsFitted = false
                        viewport.pan(by: CGPoint(x: dx, y: dy))
                    },
                    onZoom: { factor, point in
                        zoomIsFitted = false
                        viewport.zoom(by: factor, around: point)
                    },
                    onCommitCrop: { _ = session.commitCrop() })
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) { textEditor }
            // 识别结果那张纸：浮在台面上，默认贴右下角、可以拖走（稿子 §04/§07）。
            // 它住在**画布这一层**而不是窗口那一层 ——「默认右下 + 夹进画布」判据算的都是画布坐标。
            .overlay(alignment: .topLeading) { ocrPaper(canvas: geo.size) }
            // 裁切读数框：跟着保留框，实时报"裁完多大"（稿子 §07 c）。
            .overlay(alignment: .topLeading) { cropReadoutLayer(canvas: geo.size) }
            .onAppear {
                fitIfNeeded(in: geo.size)
                rebuildRedactionCache()
            }
            // 选中文字格 → 预设弹层自动出现（稿子 §05：「与 ④ 表情弹层的出现机制同一件事」）。
            // 用户点别处把它收掉之后**工具仍然是文字** —— 弹层只是便利，不是模式。
            .onChange(of: session.tool) { _, tool in
                showTextPresets = (tool == .text)
            }
            .onChange(of: redactionSignature) { _, _ in
                rebuildRedactionCache()
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
                fitIfNeeded(in: newSize)
            }
        }
    }

    /// 文字输入框。
    ///
    /// 为什么不是"就地改画布上那行字"：那需要在画布里放一个真正的 `NSTextField` 并处理
    /// 光标、选区、输入法候选窗的定位 —— 而这是个截图工具，输一行标注字用不着那些。
    /// 这里放一个贴近该标注的小输入框，回车提交、Esc 取消。
    @ViewBuilder
    private var textEditor: some View {
        if let id = editingID, let annotation = textAnnotation(id) {
            let rect = viewport.viewRect(forImage: annotation.frame,
                                         cropOrigin: session.document.cropRect.origin)
            TextField(L10n.t("输入文字"), text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 220)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
                .focused($editingFocused)
                .onSubmit { commitTextEditing() }
                .offset(x: rect.minX, y: max(4, rect.minY - 34))
                .onAppear { editingFocused = true }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 点画布 = 让那张纸**收拢**（稿子 §07：「点画布它就收拢」）。
                // 它是**副作用**，不是模式 —— 这一下该干的活（选标注 / 画东西）照旧往下走。
                if showOCRPanel { showOCRPanel = false }
                // 正在输入时，这一下点击只用来结束输入 —— 否则会在输入框旁边再画一个框
                if editingID != nil {
                    commitTextEditing()
                    return
                }
                if session.isCropping {
                    handleCropDrag(value)
                    return
                }
                let point = viewport.imagePoint(forView: value.location,
                                                cropOrigin: session.document.cropRect.origin)
                if !dragging {
                    session.pointerDown(at: point,
                                        shift: NSEvent.modifierFlags.contains(.shift),
                                        handleRadius: 6 / viewport.scale)
                    // 文字是在 pointerDown 里落下的（落点即锚点），落下就要求输入内容
                    if let pending = session.pendingTextEditID {
                        editingID = pending
                        editingText = ""
                        // 正在输入时把预设弹层让开 —— 它挂的就是刚点过的那一格，
                        // 不收掉会正好压在输入框上。
                        showTextPresets = false
                    }
                    dragging = true
                } else {
                    session.pointerMoved(to: point)
                }
            }
            .onEnded { _ in
                if session.isCropping {
                    cropDrag = nil
                    return
                }
                session.pointerUp()
                dragging = false
            }
    }

    /// 裁切模式下的拖拽：抓角就改角，抓框内就整体平移。
    private func handleCropDrag(_ value: DragGesture.Value) {
        let cropOrigin = session.document.cropRect.origin
        let point = viewport.imagePoint(forView: value.location, cropOrigin: cropOrigin)
        guard let previous = cropDrag else {
            // 第一次进来：这一下抓的是某个角，还是整框
            cropDrag = CropDrag(handle: cropHandle(near: value.startLocation),
                                lastImagePoint: point)
            return
        }
        if let handle = previous.handle {
            session.updateCrop(handle: handle, to: point)
        } else {
            session.moveCrop(by: CGPoint(x: point.x - previous.lastImagePoint.x,
                                         y: point.y - previous.lastImagePoint.y))
        }
        cropDrag = CropDrag(handle: previous.handle, lastImagePoint: point)
    }

    /// 抓的是哪个角（视图坐标，12 点以内）；没抓到就返回 nil（= 拖整框）。
    private func cropHandle(near viewPoint: CGPoint) -> AnnotationHandle? {
        guard let draft = session.cropDraft else { return nil }
        let rect = viewport.viewRect(forImage: draft, cropOrigin: session.document.cropRect.origin)
        for handle in AnnotationHandle.allCases {
            let center = handle.point(on: rect)
            if hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= 12 { return handle }
        }
        return nil
    }

    // MARK: - 裁切读数框（设计稿 §07 c）

    /// 拖保留框时实时报"裁完是多大"。
    ///
    /// ## 它是"不设二次确认"的代价与前提
    ///
    /// 裁切是画布级的破坏性操作，而稿子的结论是**不加确认弹窗**
    ///（那会造出整个产品唯一的模态，与"标注可反复改"正好相反）。
    /// 这一步的职责由这台读数框来付：**还不等按 `⏎`，用户已经看到这一刀会切掉多少**。
    ///
    /// ⚠️ 只要**进了裁切模式**就显示（不等"框被拖过"）：框从进模式那一刻就在
    /// （初始 = 整张图），此时报"裁完 = 原图"是句实话 —— 而按"改过没有"来决定显不显示，
    /// 会让用户把框拖回原尺寸时它突然消失。
    @ViewBuilder
    private func cropReadoutLayer(canvas: CGSize) -> some View {
        if session.isCropping, let draft = session.cropDraft {
            let lines = CropReadout.lines(crop: draft.size, original: session.document.pixelSize)
            let box = CropReadout.frame(
                cropFrame: viewport.viewRect(forImage: draft,
                                             cropOrigin: session.document.cropRect.origin),
                canvas: canvas,
                size: CropReadout.size(textWidth: readoutTextWidth(lines))
            )
            cropReadoutBox(lines)
                .frame(width: box.width, height: box.height, alignment: .topLeading)
                // ⚠️ **不可点**：它是读数不是控件。吃掉鼠标就等于在保留框的右下挖了
                // 一个"拖不动"的洞 —— 而那里正是右下角握把所在。
                .allowsHitTesting(false)
                .offset(x: box.minX, y: box.minY)
        }
    }

    private func cropReadoutBox(_ lines: CropReadout.Lines) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 两行都用**等宽数字**、中等字重 —— 与覆盖层那个读数框同一套
            //（`OverlayReadout` 的行阶 13 / 11）。数字对齐，尺寸读起来才不用逐位比。
            Text(lines.headline)
                .font(.system(size: CropReadout.primaryFontSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ChromePalette.dark.label.color)
            Text(lines.detail)
                .font(.system(size: CropReadout.secondaryFontSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ChromePalette.dark.label2.color)
        }
        .lineLimit(1)
        .padding(.horizontal, OverlayReadout.textPadding.width)
        .padding(.vertical, OverlayReadout.textPadding.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChromePalette.dark.panel.color)
        .clipShape(RoundedRectangle(cornerRadius: OverlayReadout.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: OverlayReadout.cornerRadius)
            .stroke(ChromePalette.Overlay.panelBorder.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.38), radius: 12, y: 6)
    }

    /// 两行里较长的那一行有多宽。
    ///
    /// ## 为什么要量，而不是写死 132
    ///
    /// 框宽 = `max(132, 内容 + 两侧内边距)`。写死之后，`原图 1440 × 12000 px`
    /// 这种长截图的**常规**尺寸会被静默裁掉尾巴 —— 而尾巴上那几个数字
    /// 正是这个框存在的理由。实测（11 点等宽数字、内宽 116）：
    /// 中文 `原图 1440 × 2000 px` = 111.3，四位数已经用掉 96%；英文 `Original …` = 131.2，**放不下**。
    private func readoutTextWidth(_ lines: CropReadout.Lines) -> CGFloat {
        func width(_ text: String, _ fontSize: CGFloat) -> CGFloat {
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
            return (text as NSString).size(withAttributes: [.font: font]).width
        }
        return max(width(lines.headline, CropReadout.primaryFontSize),
                   width(lines.detail, CropReadout.secondaryFontSize))
    }

    private struct CropDrag {
        var handle: AnnotationHandle?
        var lastImagePoint: CGPoint
    }

    private func draw(in context: GraphicsContext) {
        let crop = session.document.cropRect
        let scale = viewport.scale
        let cropView = CGRect(origin: viewport.pan,
                              size: CGSize(width: crop.width * scale, height: crop.height * scale))
        context.drawLayer { layer in
            layer.clip(to: Path(cropView))
            let origin = CGPoint(x: viewport.pan.x - crop.minX * scale,
                                 y: viewport.pan.y - crop.minY * scale)
            let full = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            layer.draw(Image(decorative: image, scale: 1), in: CGRect(origin: origin, size: full))
            for annotation in session.visibleAnnotations() {
                drawAnnotation(annotation, in: layer, crop: crop)
            }
        }
        if session.isCropping {
            drawCropOverlay(in: context)
            return
        }
        for annotation in session.visibleAnnotations() where session.selection.contains(annotation.id) {
            let rect = viewport.viewRect(forImage: annotation.frame, cropOrigin: crop.origin)
            for handle in AnnotationHandle.allCases {
                let center = handle.point(on: rect)
                let mark = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
                context.fill(Path(mark), with: .color(.white))
                context.stroke(Path(mark), with: .color(.black), lineWidth: 1)
            }
        }
    }

    /// 裁切框：外面压暗 + 白边 + 四角握把。
    ///
    /// 压暗用 even-odd 填充一次画完（挖个洞），而不是画四条边 ——
    /// 后者在框贴边时会留下没盖到的一条缝。
    private func drawCropOverlay(in context: GraphicsContext) {
        guard let draft = session.cropDraft else { return }
        let rect = viewport.viewRect(forImage: draft, cropOrigin: session.document.cropRect.origin)

        var mask = Path(CGRect(origin: .zero, size: canvasSize))
        mask.addPath(Path(rect))
        context.fill(mask, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

        context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
        // 三分线：帮着对齐内容
        for fraction in [1.0 / 3, 2.0 / 3] {
            var vertical = Path()
            vertical.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            vertical.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            horizontal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
            context.stroke(vertical, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
            context.stroke(horizontal, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
        }
        for handle in AnnotationHandle.allCases {
            let center = handle.point(on: rect)
            let mark = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
            context.fill(Path(mark), with: .color(.white))
            context.stroke(Path(mark), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    private func drawAnnotation(_ annotation: Annotation,
                                in context: GraphicsContext,
                                crop: CGRect) {
        let scale = viewport.scale
        let color = swiftUI(annotation.style.stroke)
        func viewPoint(_ point: CGPoint) -> CGPoint {
            viewport.viewPoint(forImage: point, cropOrigin: crop.origin)
        }

        switch annotation.kind {
        case .rectangle, .ellipse:
            let rect = viewport.viewRect(forImage: annotation.frame, cropOrigin: crop.origin)
            let path: Path = annotation.kind == .ellipse ? Path(ellipseIn: rect) : Path(rect)
            context.stroke(path, with: .color(color), lineWidth: max(1, annotation.style.lineWidth * scale))

        case .arrow:
            guard annotation.path.count >= 2 else { return }
            let start = annotation.path[0]
            let end = annotation.path[1]
            var shaft = Path()
            shaft.move(to: viewPoint(start))
            shaft.addLine(to: viewPoint(end))
            context.stroke(shaft,
                           with: .color(color),
                           style: StrokeStyle(lineWidth: max(1, annotation.style.lineWidth * scale),
                                              lineCap: .round))
            // 头部用 Core 的几何算（与导出一致），只是把点换到视图坐标
            let head = AnnotationGeometry.arrowHead(from: start,
                                                    to: end,
                                                    lineWidth: annotation.style.lineWidth)
            guard head.count == 3 else { return }
            var triangle = Path()
            triangle.move(to: viewPoint(head[0]))
            triangle.addLine(to: viewPoint(head[1]))
            triangle.addLine(to: viewPoint(head[2]))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(color))

        case .pen:
            guard annotation.path.count >= 2 else { return }
            var path = Path()
            path.move(to: viewPoint(annotation.path[0]))
            for point in annotation.path.dropFirst() {
                path.addLine(to: viewPoint(point))
            }
            context.stroke(path,
                           with: .color(color),
                           style: StrokeStyle(lineWidth: max(1, annotation.style.lineWidth * scale),
                                              lineCap: .round,
                                              lineJoin: .round))

        case .mosaic, .blur:
            // 画的就是 Core 滤镜的输出（与导出同一套），所以编辑器里看到什么导出来就是什么。
            // 缓存由 `onChange(of: redactionSignature)` 重算；这里只取。
            guard let patch = redactionCache[annotation.id]?.image else { return }
            let rect = viewport.viewRect(forImage: annotation.frame, cropOrigin: crop.origin)
            context.draw(Image(decorative: patch, scale: 1), in: rect)

        case .text:
            // 走 CoreText 而不是 SwiftUI 的 `Text`：编辑器与导出必须**同一套排版**，
            // 否则会出现"编辑器里放得下、导出后被裁掉半个字"。
            // 前两条测试钉住了这里的方向与裁剪（SwiftUI 的 CG 上下文是左上原点、y 向下）。
            let origin = viewport.viewPoint(forImage: annotation.frame.standardized.origin,
                                            cropOrigin: crop.origin)
            context.withCGContext { cg in
                cg.saveGState()
                cg.translateBy(x: origin.x, y: origin.y)
                cg.scaleBy(x: scale, y: scale)
                AnnotationText.draw(annotation.text,
                                    fontSize: annotation.style.fontSize,
                                    color: annotation.style.stroke.cgColor(),
                                    at: .zero,
                                    in: cg)
                cg.restoreGState()
            }
        }
    }

    // MARK: - 打码

    private struct RedactionCacheEntry {
        var key: String
        var image: CGImage?
    }

    /// 打码对象的"身份"：框 + 强度 + 类型。变了才需要重算。
    private var redactionSignature: [String] {
        session.visibleAnnotations()
            .filter { $0.kind == .mosaic || $0.kind == .blur }
            .map { "\($0.id)|\($0.frame.standardized.integral)|\($0.style.effectStrength)|\($0.kind)" }
    }

    /// 重算打码缓存。
    ///
    /// **必须在 `onChange` 里做，不能在 `Canvas` 的绘制闭包里做** ——
    /// 在渲染过程中改 `@State` 是 SwiftUI 明令禁止的（会让画面与状态不同步）。
    private func rebuildRedactionCache() {
        var next: [UUID: RedactionCacheEntry] = [:]
        for annotation in session.visibleAnnotations() where annotation.kind == .mosaic || annotation.kind == .blur {
            let box = annotation.frame.standardized.integral
            let key = "\(box)|\(annotation.style.effectStrength)|\(annotation.kind)"
            if let cached = redactionCache[annotation.id], cached.key == key {
                next[annotation.id] = cached
                continue
            }
            let patch = image.cropping(to: box).flatMap {
                RedactionFilter.apply(annotation.kind, to: $0, strength: annotation.style.effectStrength)
            }
            next[annotation.id] = RedactionCacheEntry(key: key, image: patch)
        }
        redactionCache = next
    }

    // MARK: - 文字编辑

    private func textAnnotation(_ id: UUID) -> Annotation? {
        session.document.annotations.first { $0.id == id && $0.kind == .text }
    }

    private func beginEditingText(at viewPoint: CGPoint) {
        let point = viewport.imagePoint(forView: viewPoint,
                                        cropOrigin: session.document.cropRect.origin)
        guard case .body(let id)? = session.document.hitTest(point,
                                                            selected: session.selection,
                                                            handleRadius: 6 / viewport.scale),
              let annotation = textAnnotation(id) else { return }
        session.selection = [id]
        editingID = id
        editingText = annotation.text
    }

    private func commitTextEditing() {
        guard let id = editingID else { return }
        let trimmed = editingText
        session.setText(trimmed, for: id)
        // 空文字是看不见也点不中的垃圾对象，提交时清掉
        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.selection = [id]
            session.deleteSelection()
        }
        session.endTextEditing()
        editingID = nil
        editingFocused = false
    }

    private func cancelTextEditing() {
        guard let id = editingID else { return }
        if textAnnotation(id)?.text.isEmpty == true {
            session.selection = [id]
            session.deleteSelection()
        }
        session.endTextEditing()
        editingID = nil
        editingFocused = false
    }

    // MARK: - 工具栏按钮

    /// 工具条上**一个格子**的形态：28 × 28 · 圆角 6 · 图标 14 点 · 中文标签进 `help`。
    ///
    /// ## 三条点亮规则（与 ④ 同表）
    ///
    /// 1. **填充蓝 = 当前生效的那个**（工具、色板、尺寸档同类只许一个）；
    /// 2. **动作不亮** —— 撤销 / 重做 / 保存 / ✗ / ✓ 按下即执行，没有选中态；
    /// 3. **撤销与重做是全条唯一允许变灰的两格**（`isEnabled == false`）——
    ///    它们变了灰才是"真的没得撤"。识别文字那格带 Pro 小锁但**永不灰**：
    ///    能买的东西不许看起来像坏的。
    private func iconButton(_ title: String,
                            systemImage: String,
                            isActive: Bool = false,
                            isEnabled: Bool = true,
                            tint: Color? = nil,
                            cellSize: CGFloat = EditorChrome.cellSize,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: cellSize, height: cellSize)
                .background(isActive ? ChromePalette.dark.fill.color : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: EditorChrome.cellCornerRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(cellTint(tint: tint, isActive: isActive, isEnabled: isEnabled))
        .disabled(!isEnabled)
        .help(title)
    }

    /// 格子里那枚图标的颜色。
    ///
    /// ⚠️ 默认是 **82% 的白**而不是纯白：一排十几个纯白图标会**糊成一片亮**，
    /// 压低一档之后"亮起来"才有地方可亮（④ 的同一条理由）。
    /// 置灰（白 30%）只属于撤销 / 重做，而且**对比度无下限**是刻意的 ——
    /// 那个状态本来就该看起来"不活跃"。
    private func cellTint(tint: Color?, isActive: Bool, isEnabled: Bool) -> Color {
        if !isEnabled { return ChromePalette.dark.disabled.color }
        if isActive { return ChromePalette.dark.label.color }
        return tint ?? ChromePalette.dark.icon.color
    }

    /// 分组竖线：1 × 18，两侧各让开 6（`EditorChrome.separatorWidth` 算的是同一件事）。
    private var toolbarSeparator: some View {
        Rectangle()
            .fill(ChromePalette.dark.hairline.color)
            .frame(width: EditorChrome.separatorSize.width,
                   height: EditorChrome.separatorSize.height)
            .padding(.horizontal, EditorChrome.separatorMargin)
    }

    /// 裁切是**模式**不是工具：它不改文档，只是让你调好框再 `⏎`。
    ///
    /// 但它在**工具组里**（第九格、前面一条分隔线）：工具组的分界不是"画东西"，
    /// 是**模式** —— 同一时刻只亮一个，都在画布上用同一套手势（拖、Esc 退）。
    /// 挪到缩放旁边会把"有代价的破坏性操作"和"随手来回的视图控制"混成一堆（判断 2）。
    private var cropButton: some View {
        iconButton(session.isCropping ? L10n.t("裁切中：回车应用 · Esc 取消") : L10n.t("裁切"),
                   systemImage: AnnotationIcon.crop,
                   isActive: session.isCropping) {
            if session.isCropping {
                session.cancelCrop()
            } else {
                session.beginCrop()
            }
        }
    }

    /// 一个工具格。图标名**从 Core 取**（`AnnotationIcon`）—— 与覆盖层同一枚。
    private func toolButton(_ tool: AnnotationEditorTool) -> some View {
        let toolName = Self.title(for: tool)
        return iconButton(session.tool == tool ? L10n.t("\(toolName)（当前工具）") : toolName,
                          systemImage: AnnotationIcon.symbol(for: tool),
                          isActive: session.tool == tool) {
            session.tool = tool
        }
        .popover(isPresented: .constant(false)) { EmptyView() }
    }

    private static func title(for tool: AnnotationEditorTool) -> String {
        switch tool {
        case .select: L10n.t("选择")
        case .rectangle: L10n.t("矩形")
        case .ellipse: L10n.t("椭圆")
        case .arrow: L10n.t("箭头")
        case .pen: L10n.t("画笔")
        case .text: L10n.t("文字")
        case .mosaic: L10n.t("马赛克")
        case .blur: L10n.t("模糊")
        }
    }

    private func zoom(by factor: CGFloat) {
        // ⚠️ 手动缩过之后就不再是"适应窗口"了 —— 状态行那四个字要跟着摘掉，
        // 否则它会替一个已经过去的状态说话（用户明明缩过了，而它还说"适应窗口"）。
        zoomIsFitted = false
        let anchor = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        viewport.zoom(by: factor, around: anchor)
    }

    /// 回到「适应窗口」。**点缩放的百分数**就走这里。
    private func fitToWindow() {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }
        viewport = CanvasViewport.fitted(pixelSize: session.document.canvasPixelSize,
                                         in: canvasSize)
        zoomIsFitted = true
    }

    private func fitIfNeeded(in size: CGSize) {
        canvasSize = size
        guard !didFit, size.width > 1, size.height > 1 else { return }
        viewport = CanvasViewport.fitted(pixelSize: session.document.canvasPixelSize, in: size)
        didFit = true
        // 首次进入就是"适应窗口"那一档 —— 状态行因此一进来就说真话。
        zoomIsFitted = true
    }

    /// 执行 Core 的梯子算出来的那一步。
    ///
    /// 这里**只执行、不判断** —— "该退哪一层"是 `EditorEscapeState.escapeStep()` 的事，
    /// 五条分支的顺序在那边（有测试钉着）。
    private func handleEscapeStep(_ step: EscapeStep) {
        switch step {
        case .cancelTextEditing:
            cancelTextEditing()
        case .cancelGesture:
            session.cancelCrop()
        case .leaveTool:
            // 退回"选择"，**不动已画的标注**。
            // 少了这一档，用户画完几个箭头想退出标注模式，
            // 一下 `Esc` 就把窗口收了 —— 而这张图可能已经很难再复现。
            session.tool = .select
        case .clearSelection:
            session.selection = []
        case .dismiss:
            // 到底 = **带走**（完成并复制并关闭）。
            //
            // ⚠️ 与覆盖层**相反**，而且必须相反：那边退到底是"取消"，
            // 因为它的底是"还没有东西"；这边的底是"已经有东西"
            //（拼好的长图 + 刚画的标注），取消意味着**按一下丢掉几分钟的活**。
            //
            // 「丢弃」这件事在编辑器里由 `✗` 单独承担 —— 它必须**用手点**，
            // 不能让人顺着下意识按出来。`Esc` 逐层退到这里，用户想的是
            // "我不想在这个窗口里了"，不是"把我画的都毁掉"。
            copyAndClose()
        }
    }

    private func copyAndClose() {
        if let rendered = AnnotationRasterizer.image(document: session.document, source: image),
           let png = ImageEncoding.pngData(from: rendered) {
            onCopyPNG(png)
        }
        onClose()
    }

    /// 保存到磁盘并关闭。
    ///
    /// 与覆盖层工具栏上的「保存」是**同一个语义**：落盘 + 复制 + 收场。
    /// 三条路径（覆盖层保存、这里、长截图的 `⌘S`）行为一致，
    /// 用户不必记"哪个保存会顺手关掉窗口"。
    ///
    /// ⚠️ 栅格化失败时**什么都不做、也不关窗** —— 那样用户还能重试。
    /// 关掉的话，他的标注跟着没了、图也没落盘，两头空。
    private func saveAndClose() {
        guard let rendered = AnnotationRasterizer.image(document: session.document, source: image) else {
            return
        }
        if let png = ImageEncoding.pngData(from: rendered) {
            onCopyPNG(png)
        }
        onSave(rendered)
        onClose()
    }

    private func swiftUI(_ color: AnnotationColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

/// 键盘与滚轮不走 SwiftUI 的焦点链：菜单栏应用的窗口经常拿不到第一响应者。
private struct EditorEventMonitor: NSViewRepresentable {
    /// `Esc` 要退哪一层所需的**全部**状态。
    ///
    /// 判据在 Core 的 `EditorEscapeState.escapeStep()` —— 这里只负责把状态递进去、
    /// 把算出来的那一步回调出去。层级顺序若写在这个视图里，就会与覆盖层那份分叉。
    var escapeState: EditorEscapeState
    /// 梯子算好的那一步，交给视图执行。
    var onEscapeStep: (EscapeStep) -> Void
    /// `⏎` = 确认（与工具栏上那颗 `✓` 同一个动作）。
    ///
    /// macOS 的约定是 `⏎` 走默认按钮、`Esc` 走取消按钮 —— 两个界面都照这个来，
    /// 用户按下之前就知道会发生什么。
    var onConfirm: () -> Void
    var onSave: () -> Void
    var onDelete: () -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onPan: (CGFloat, CGFloat) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    /// 正在调整裁切框：此时 `⏎` = 应用裁切（**不是**"确认整张图"）。
    var onCommitCrop: () -> Void

    func makeNSView(context: Context) -> EditorEventMonitorView {
        let view = EditorEventMonitorView()
        view.actions = actions
        return view
    }

    func updateNSView(_ nsView: EditorEventMonitorView, context: Context) {
        nsView.actions = actions
    }

    private var actions: EditorEventMonitorView.Actions {
        EditorEventMonitorView.Actions(escapeState: escapeState,
                                       onEscapeStep: onEscapeStep,
                                       onConfirm: onConfirm,
                                       onSave: onSave,
                                       onDelete: onDelete,
                                       onUndo: onUndo,
                                       onRedo: onRedo,
                                       onPan: onPan,
                                       onZoom: onZoom,
                                       onCommitCrop: onCommitCrop)
    }
}

private final class EditorEventMonitorView: NSView {
    struct Actions {
        var escapeState: EditorEscapeState
        var onEscapeStep: (EscapeStep) -> Void
        var onConfirm: () -> Void
        var onSave: () -> Void
        var onDelete: () -> Void
        var onUndo: () -> Void
        var onRedo: () -> Void
        var onPan: (CGFloat, CGFloat) -> Void
        var onZoom: (CGFloat, CGPoint) -> Void
        var onCommitCrop: () -> Void
    }

    var actions = Actions(escapeState: EditorEscapeState(),
                          onEscapeStep: { _ in },
                          onConfirm: {}, onSave: {}, onDelete: {}, onUndo: {}, onRedo: {},
                          onPan: { _, _ in }, onZoom: { _, _ in },
                          onCommitCrop: {})
    private var monitor: Any?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            return handleKey(event)
        case .scrollWheel:
            let factor = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
            if event.modifierFlags.contains(.command) {
                let zoom = event.scrollingDeltaY >= 0 ? 1.08 : 0.92
                actions.onZoom(zoom, location(of: event))
            } else {
                actions.onPan(event.scrollingDeltaX * factor, event.scrollingDeltaY * factor)
            }
            return nil
        case .magnify:
            actions.onZoom(1 + event.magnification, location(of: event))
            return nil
        default:
            return event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let state = actions.escapeState

        // 输入文字时让按键照常送到输入框（退格、回车、⌘Z 都是编辑文本用的）。
        // `Esc` 例外 —— 它要退出输入，而那一步由梯子给出。
        if state.isEditingText, event.keyCode != 53 {
            return event
        }
        // 裁切进行中：`⏎` = 应用裁切（**不是**"确认整张图"）。
        if state.isCropping, event.keyCode == 0x24 || event.keyCode == 0x4C {
            actions.onCommitCrop()
            return nil
        }
        // 裁切进行中的其它按键只放行 ⌘ 组合（⌘Z 仍可撤销 —— 裁切前可能刚画了东西）。
        if state.isCropping, !event.modifierFlags.contains(.command) {
            return event
        }
        switch event.keyCode {
        case 53:
            // 「退哪一层」**不在这里判断** —— 判据是 Core 的 `EditorEscapeState.escapeStep()`。
            // 覆盖层那边的层级表更长（自动滚动、卡片、弹层），两边层数不同是有意的；
            // 统一的是**性格**：`Esc` 只退、`⏎` 才确认。
            actions.onEscapeStep(state.escapeStep())
            return nil
        case 0x24, 0x4C:
            // `⏎` = 确认。它以前**什么都没绑** —— 于是"退出键"被当成了确认键，
            // 而真正的默认按钮键是空的。现在两者各就各位。
            actions.onConfirm()
            return nil
        case 51, 117:
            actions.onDelete()
            return nil
        default:
            break
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            actions.onSave()
            return nil
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                actions.onRedo()
            } else {
                actions.onUndo()
            }
            return nil
        }
        return event
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}

/// `RGB`（Core 的 sRGB 值）→ SwiftUI 的 `Color`。
///
/// 走 `nsColor`：那一条已经保证 **alpha 带上、sRGB 而不是 deviceRGB** 两条都对
///（`AppKitBridging` 里有完整理由）。在这里再写一遍 `Color(red:green:blue:)`
/// 等于把那份说理抄一份、并且忘掉其中一半。
private extension RGB {
    var color: Color { Color(nsColor: nsColor) }
}

/// 只给版面快照用的**空识别器**：它永远不会真的被调用
/// （快照只渲染视图，不跑识别），存在的意义只是让那一格画出来。
@MainActor
private struct SnapshotRecognizer: TextRecognizing {
    func recognize(in image: CGImage, languages: [String]) async throws -> [RecognizedTextLine] { [] }
}

/// 把宿主给的材质视图垫在内容下面。
///
/// ⚠️ **`updateNSView` 必须是空的**：材质视图是"造一次就固定"的东西，
/// 在这里按 `radius` 重新摆一遍的话，它会**吃掉已经画在上面的内容**
///（`NSGlassEffectView` / `NSVisualEffectView` 都是自己管绘制的）。
/// 圆角在编辑器这一处恒为 0，本来也没有要更新的东西。
private struct MaterialBackground: NSViewRepresentable {
    let radius: CGFloat
    let factory: EditorBackgroundFactory

    func makeNSView(context: Context) -> NSView { factory(radius) }

    func updateNSView(_ view: NSView, context: Context) {}
}

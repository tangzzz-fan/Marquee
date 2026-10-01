import AppKit
import MarqueeCore
import SwiftUI

/// 截图标注窗口。宿主拿到 PNG 后自己写剪贴板。
@MainActor
public final class AnnotationEditorPresenter {
    private var controllers: [AnnotationEditorWindowController] = []

    public init() {}

    /// `seed` 用来预置标注（开发演示用：`-marqueeDemoEditor`），正常流程为空。
    ///
    /// `seed` 放在闭包**前面**：尾随闭包只能匹配最后一个参数，
    /// 把它放后面就没法用尾随闭包语法了（`present(image:seed:) { … }`）。
    public func present(image: CGImage,
                        seed: [Annotation] = [],
                        onCopyPNG: @escaping @MainActor (Data) -> Void) {
        let controller = AnnotationEditorWindowController(image: image, onCopyPNG: onCopyPNG, seed: seed)
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

    init(image: CGImage, onCopyPNG: @escaping @MainActor (Data) -> Void, seed: [Annotation] = []) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "标注"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        super.init(window: window)
        window.delegate = self

        let root = AnnotationEditorView(image: image, onCopyPNG: onCopyPNG, seed: seed) { [weak self] in
            self?.close()
        }
        contentViewController = NSHostingController(rootView: root)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AnnotationEditorWindowController 只支持代码创建")
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
    let onClose: () -> Void

    @State private var session: AnnotationEditorSession
    @State private var viewport = CanvasViewport()
    @State private var didFit = false
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

    private let colors: [AnnotationColor] = [
        .red,
        AnnotationColor(red: 1, green: 0.58, blue: 0),
        AnnotationColor(red: 1, green: 0.84, blue: 0.1),
        AnnotationColor(red: 0.2, green: 0.78, blue: 0.35),
        AnnotationColor(red: 0.05, green: 0.48, blue: 1),
        AnnotationColor(red: 1, green: 1, blue: 1),
        AnnotationColor(red: 0.1, green: 0.1, blue: 0.1),
    ]
    private let lineWidths: [CGFloat] = [2, 4, 8]
    /// 字号档位。文字标注的"粗细"就是字号，和线宽共用同一排控件。
    private let fontSizes: [CGFloat] = [24, 36, 56]
    /// 打码强度档位（马赛克＝块边长、模糊＝半径）。两档之间的差别要一眼看得出来。
    private let redactionStrengths: [CGFloat] = [8, 16, 32]

    init(image: CGImage,
         onCopyPNG: @escaping (Data) -> Void,
         seed: [Annotation] = [],
         onClose: @escaping () -> Void) {
        self.image = image
        self.onCopyPNG = onCopyPNG
        self.onClose = onClose
        var initial = AnnotationEditorSession(pixelSize: CGSize(width: image.width, height: image.height))
        initial.document.annotations = seed
        _session = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            canvas
        }
        .background(Color(white: 0.11))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolButton("选择", tool: .select)
            toolButton("矩形", tool: .rectangle)
            toolButton("椭圆", tool: .ellipse)
            toolButton("箭头", tool: .arrow)
            toolButton("画笔", tool: .pen)
            toolButton("文字", tool: .text)
            toolButton("马赛克", tool: .mosaic)
            toolButton("模糊", tool: .blur)
            // 裁切是**模式**不是工具：它不改文档，只是让你调好框再回车
            Button {
                if session.isCropping {
                    session.cancelCrop()
                } else {
                    session.beginCrop()
                }
            } label: {
                Text("裁切")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(session.isCropping ? Color.white.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("拖框调整裁切范围，回车应用，Esc 取消")

            // 序号是**文字工具的一个预设**，不占独立工具位（PRD：工具栏 ≤ 9 个工具）
            if session.tool == .text {
                Divider().frame(height: 18)
                presetButton("文字", preset: .plain)
                presetButton("序号", preset: .counter)
                if session.textPreset == .counter {
                    HStack(spacing: 2) {
                        Text("起始 \(session.nextCounter)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 46, alignment: .trailing)
                        Stepper("", value: counterBinding, in: 1...99)
                            .labelsHidden()
                            .controlSize(.mini)
                    }
                    .help("序号从几开始（后续每放一个自增）")
                }
            }

            Divider().frame(height: 18)
            ForEach(colors, id: \.self) { color in
                Button {
                    session.setStrokeColor(color)
                } label: {
                    Circle()
                        .fill(swiftUI(color))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white.opacity(session.style.stroke == color ? 0.95 : 0.25), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help("描边颜色")
            }
            Divider().frame(height: 18)
            sizeControls
            Spacer()
            Button { zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            Text("\(Int((viewport.scale * 100).rounded()))%")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 48)
            Button { zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            Text(session.isCropping ? "回车应用裁切 · Esc 取消" : "Esc 复制并关闭")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.16))
    }

    /// 这一排控件按**当前上下文**决定改的是哪个参数：线宽 / 字号 / 打码强度。
    ///
    /// 三者互斥（文字没有线宽、打码没有字号），而工具栏已经很挤 ——
    /// 与其摆三排按钮，不如让同一排按钮改"当前真正相关的那个"。
    private var sizeControls: some View {
        let target = sizeTarget
        return ForEach(target.values, id: \.self) { value in
            Button {
                switch target.kind {
                case .lineWidth: session.setLineWidth(value)
                case .fontSize: session.setFontSize(value)
                case .strength: session.setEffectStrength(value)
                }
            } label: {
                Text("\(Int(value))")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 22)
                    .background(isActiveSize(value, target: target.kind)
                                ? Color.white.opacity(0.18)
                                : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("\(target.label) \(Int(value))")
        }
    }

    private enum SizeTargetKind { case lineWidth, fontSize, strength }

    private var sizeTarget: (kind: SizeTargetKind, values: [CGFloat], label: String) {
        if session.tool == .mosaic || session.tool == .blur || selectionContainsRedaction {
            return (.strength, redactionStrengths, "打码强度")
        }
        if session.tool == .text || selectionContainsText {
            return (.fontSize, fontSizes, "字号")
        }
        return (.lineWidth, lineWidths, "线宽")
    }

    private func isActiveSize(_ value: CGFloat, target: SizeTargetKind) -> Bool {
        switch target {
        case .lineWidth: session.style.lineWidth == value
        case .fontSize: session.style.fontSize == value
        case .strength: session.style.effectStrength == value
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

    private var counterBinding: Binding<Int> {
        Binding(get: { session.nextCounter },
                set: { session.setCounterStart($0) })
    }

    private func presetButton(_ title: String, preset: AnnotationEditorSession.TextPreset) -> some View {
        Button {
            session.textPreset = preset
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(session.textPreset == preset ? Color.white.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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
                EditorEventMonitor(onEscape: copyAndClose,
                                  onDelete: { session.deleteSelection() },
                                  onUndo: { session.undo() },
                                  onRedo: { session.redo() },
                                  onPan: { dx, dy in viewport.pan(by: CGPoint(x: dx, y: dy)) },
                                  onZoom: { factor, point in viewport.zoom(by: factor, around: point) },
                                  isEditingText: editingID != nil,
                                  onCancelTextEditing: { cancelTextEditing() },
                                  isCropping: session.isCropping,
                                  onCommitCrop: { _ = session.commitCrop() },
                                  onCancelCrop: { session.cancelCrop() })
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) { textEditor }
            .onAppear {
                fitIfNeeded(in: geo.size)
                rebuildRedactionCache()
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
            TextField("输入文字", text: $editingText)
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

    private func toolButton(_ title: String, tool: AnnotationEditorTool) -> some View {
        Button {
            session.tool = tool
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(session.tool == tool ? Color.white.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func zoom(by factor: CGFloat) {
        let anchor = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        viewport.zoom(by: factor, around: anchor)
    }

    private func fitIfNeeded(in size: CGSize) {
        canvasSize = size
        guard !didFit, size.width > 1, size.height > 1 else { return }
        viewport = CanvasViewport.fitted(pixelSize: session.document.canvasPixelSize, in: size)
        didFit = true
    }

    private func copyAndClose() {
        if let rendered = AnnotationRasterizer.image(document: session.document, source: image),
           let png = ImageEncoding.pngData(from: rendered) {
            onCopyPNG(png)
        }
        onClose()
    }

    private func swiftUI(_ color: AnnotationColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

/// 键盘与滚轮不走 SwiftUI 的焦点链：菜单栏应用的窗口经常拿不到第一响应者。
private struct EditorEventMonitor: NSViewRepresentable {
    var onEscape: () -> Void
    var onDelete: () -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onPan: (CGFloat, CGFloat) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    /// 正在输入文字。此时**除了 Esc，其余按键一律放行** ——
    /// 否则退格会被当成"删除标注"，输入法候选也会被吞掉。
    var isEditingText: Bool
    var onCancelTextEditing: () -> Void
    /// 正在调整裁切框：回车应用、Esc 取消（覆盖层的 Esc 是"复制并关闭"，语义不同）
    var isCropping: Bool
    var onCommitCrop: () -> Void
    var onCancelCrop: () -> Void

    func makeNSView(context: Context) -> EditorEventMonitorView {
        let view = EditorEventMonitorView()
        view.actions = actions
        return view
    }

    func updateNSView(_ nsView: EditorEventMonitorView, context: Context) {
        nsView.actions = actions
    }

    private var actions: EditorEventMonitorView.Actions {
        EditorEventMonitorView.Actions(onEscape: onEscape,
                                       onDelete: onDelete,
                                       onUndo: onUndo,
                                       onRedo: onRedo,
                                       onPan: onPan,
                                       onZoom: onZoom,
                                       isEditingText: isEditingText,
                                       onCancelTextEditing: onCancelTextEditing,
                                       isCropping: isCropping,
                                       onCommitCrop: onCommitCrop,
                                       onCancelCrop: onCancelCrop)
    }
}

private final class EditorEventMonitorView: NSView {
    struct Actions {
        var onEscape: () -> Void
        var onDelete: () -> Void
        var onUndo: () -> Void
        var onRedo: () -> Void
        var onPan: (CGFloat, CGFloat) -> Void
        var onZoom: (CGFloat, CGPoint) -> Void
        var isEditingText: Bool
        var onCancelTextEditing: () -> Void
        var isCropping: Bool
        var onCommitCrop: () -> Void
        var onCancelCrop: () -> Void
    }

    var actions = Actions(onEscape: {}, onDelete: {}, onUndo: {}, onRedo: {},
                          onPan: { _, _ in }, onZoom: { _, _ in },
                          isEditingText: false, onCancelTextEditing: {},
                          isCropping: false, onCommitCrop: {}, onCancelCrop: {})
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
        // 输入文字时让按键照常送到输入框（退格、回车、⌘Z 都是编辑文本用的）
        if actions.isEditingText {
            if event.keyCode == 53 {
                actions.onCancelTextEditing()
                return nil
            }
            return event
        }
        // 裁切模式：回车应用、Esc 取消；⌘Z 仍可撤销（裁切前可能刚画了东西）
        if actions.isCropping {
            switch event.keyCode {
            case 53:
                actions.onCancelCrop()
                return nil
            case 0x24, 0x4C:
                actions.onCommitCrop()
                return nil
            default:
                break
            }
            guard event.modifierFlags.contains(.command) else { return event }
        }
        switch event.keyCode {
        case 53:
            actions.onEscape()
            return nil
        case 51, 117:
            actions.onDelete()
            return nil
        default:
            break
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

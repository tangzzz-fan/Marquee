import AppKit
import MarqueeCore
import SwiftUI

/// 截图标注窗口。宿主拿到 PNG 后自己写剪贴板。
@MainActor
public final class AnnotationEditorPresenter {
    private var controllers: [AnnotationEditorWindowController] = []

    public init() {}

    public func present(image: CGImage, onCopyPNG: @escaping @MainActor (Data) -> Void) {
        let controller = AnnotationEditorWindowController(image: image, onCopyPNG: onCopyPNG)
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

    init(image: CGImage, onCopyPNG: @escaping @MainActor (Data) -> Void) {
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

        let root = AnnotationEditorView(image: image, onCopyPNG: onCopyPNG, onClose: { [weak self] in
            self?.close()
        })
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

    init(image: CGImage, onCopyPNG: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.image = image
        self.onCopyPNG = onCopyPNG
        self.onClose = onClose
        _session = State(initialValue: AnnotationEditorSession(
            pixelSize: CGSize(width: image.width, height: image.height)
        ))
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
            ForEach(lineWidths, id: \.self) { width in
                Button {
                    session.setLineWidth(width)
                } label: {
                    Text("\(Int(width))")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 22)
                        .background(session.style.lineWidth == width ? Color.white.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("线宽 \(Int(width))")
            }
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
            Text("Esc 复制并关闭")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.16))
    }

    private var canvas: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                draw(in: context)
            }
            .gesture(drag)
            .background {
                EditorEventMonitor(onEscape: copyAndClose,
                                  onDelete: { session.deleteSelection() },
                                  onUndo: { session.undo() },
                                  onRedo: { session.redo() },
                                  onPan: { dx, dy in viewport.pan(by: CGPoint(x: dx, y: dy)) },
                                  onZoom: { factor, point in viewport.zoom(by: factor, around: point) })
                    .allowsHitTesting(false)
            }
            .onAppear { fitIfNeeded(in: geo.size) }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
                fitIfNeeded(in: newSize)
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = viewport.imagePoint(forView: value.location,
                                                cropOrigin: session.document.cropRect.origin)
                if !dragging {
                    session.pointerDown(at: point,
                                        shift: NSEvent.modifierFlags.contains(.shift),
                                        handleRadius: 6 / viewport.scale)
                    dragging = true
                } else {
                    session.pointerMoved(to: point)
                }
            }
            .onEnded { _ in
                session.pointerUp()
                dragging = false
            }
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
                let rect = viewport.viewRect(forImage: annotation.frame, cropOrigin: crop.origin)
                let path: Path = annotation.kind == .ellipse ? Path(ellipseIn: rect) : Path(rect)
                layer.stroke(path,
                             with: .color(swiftUI(annotation.style.stroke)),
                             lineWidth: max(1, annotation.style.lineWidth * scale))
            }
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
                                       onZoom: onZoom)
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
    }

    var actions = Actions(onEscape: {}, onDelete: {}, onUndo: {}, onRedo: {}, onPan: { _, _ in }, onZoom: { _, _ in })
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

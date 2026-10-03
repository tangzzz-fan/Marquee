import CoreGraphics
import Foundation

/// 编辑器的对象操作与撤销栈。
///
/// 画布视图只负责把指针和按键转成这里的调用。拖拽过程中的预览不进文档，
/// 松手才落成**一条**命令，所以一次拖动只撤销一步。
public struct AnnotationEditorSession: Sendable {
    public var document: AnnotationDocument
    public var tool: AnnotationEditorTool
    public var selection: Set<UUID>
    /// 下一笔的样式；改色、改线宽时，已选中的对象一起改。
    public var style: AnnotationStyle
    /// 文字工具的模式：普通文字 / 序号（内容自动为 `1.` `2.` …）
    public var textPreset: TextPreset = .plain
    /// 下一个序号标记用的数字。可手动改起始值。
    public var nextCounter: Int = 1
    /// 刚落下的、还没输入内容的文字。界面据此弹出输入框。
    public private(set) var pendingTextEditID: UUID?
    /// 画笔的采点间隔（原图像素）。见 `pointerMoved` 的注释。
    public static let penPointSpacing: CGFloat = 2
    /// 短于这个长度的箭头不算数（手抖点一下不该留下一个看不见的箭头）
    public static let minimumArrowLength: CGFloat = 6

    private var undoStack: [EditorCommand] = []
    private var redoStack: [EditorCommand] = []
    private var gesture: Gesture?

    public init(pixelSize: CGSize, style: AnnotationStyle = .default) {
        self.document = AnnotationDocument(pixelSize: pixelSize)
        self.tool = .select
        self.selection = []
        self.style = style
    }

    public var canUndo: Bool { !undoStack.isEmpty && gesture == nil }
    public var canRedo: Bool { !redoStack.isEmpty && gesture == nil }

    /// 文字工具要不要自动递增序号
    public enum TextPreset: Equatable, Sendable {
        case plain
        /// 序号：内容取 `"\(n)."`，每放一个自增（不回溯重排 —— 删掉 2 号不会让 3 号变 2 号）
        case counter
    }

    /// 文档加上尚未松手的那一笔。画布用这个画，不要直接画 `document`。
    public func visibleAnnotations() -> [Annotation] {
        var items = document.annotations
        switch gesture {
        case .moving(_, _, let current):
            overlay(&items, with: current)
        case .resizing(_, _, let current):
            overlay(&items, with: [current])
        case .drawing(_, let draft):
            items.append(draft)
        case nil:
            break
        }
        return items
    }

    public mutating func pointerDown(at point: CGPoint, shift: Bool, handleRadius: CGFloat) {
        switch tool {
        case .rectangle, .ellipse, .arrow, .mosaic, .blur:
            // 打码与矩形是同一套"拖出一个框"的手势，区别只在落成哪种对象
            let kind: AnnotationKind
            switch tool {
            case .rectangle: kind = .rectangle
            case .ellipse: kind = .ellipse
            case .mosaic: kind = .mosaic
            case .blur: kind = .blur
            default: kind = .arrow
            }
            var draft = Annotation(kind: kind,
                                   frame: CGRect(origin: point, size: .zero),
                                   style: style,
                                   zIndex: nextZIndex())
            if kind == .arrow {
                // 箭头要先记住起点：松手时才从起点连到终点，途中也才能实时看到方向
                draft.path = [point, point]
            }
            gesture = .drawing(start: point, draft: draft)
            selection = []

        case .pen:
            // 画笔从第一个点就开始收：它没有"拖出框"这一步，框是事后由点序列算出来的
            let draft = Annotation(kind: .pen,
                                   frame: AnnotationGeometry.frame(forPath: [point],
                                                                   lineWidth: style.lineWidth),
                                   style: style,
                                   zIndex: nextZIndex(),
                                   path: [point])
            gesture = .drawing(start: point, draft: draft)
            selection = []

        case .text:
            placeText(at: point)

        case .select:
            switch document.hitTest(point, selected: selection, handleRadius: handleRadius) {
            case .handle(let id, let handle):
                guard let annotation = document.annotations.first(where: { $0.id == id }) else { return }
                gesture = .resizing(handle: handle, original: annotation, current: annotation)
            case .body(let id):
                if shift {
                    if selection.contains(id) {
                        selection.remove(id)
                    } else {
                        selection.insert(id)
                    }
                } else {
                    if !selection.contains(id) {
                        selection = [id]
                    }
                    let original = document.annotations.filter { selection.contains($0.id) }
                    gesture = .moving(origin: point, original: original, current: original)
                }
            case nil:
                if !shift {
                    selection = []
                }
            }
        }
    }

    /// 落一个文字标注。
    ///
    /// 序号预设下内容直接就是 `"1."`、`"2."`…（不需要用户打字）；
    /// 普通文字先落一个空框，界面弹输入框 —— 空文本也量得出宽度，
    /// 所以刚落下的框是能看见、能点中的。
    private mutating func placeText(at point: CGPoint) {
        let content: String
        var counterValue: Int?
        switch textPreset {
        case .plain:
            content = ""
        case .counter:
            counterValue = nextCounter
            content = "\(nextCounter)."
        }

        let annotation = Annotation(kind: .text,
                                    frame: AnnotationText.frame(text: content,
                                                                fontSize: style.fontSize,
                                                                origin: point),
                                    style: style,
                                    zIndex: nextZIndex(),
                                    text: content)
        push(.add(annotation))
        document.annotations.append(annotation)
        selection = [annotation.id]
        if let counterValue {
            nextCounter = counterValue + 1
        } else {
            pendingTextEditID = annotation.id
        }
    }

    public mutating func setCounterStart(_ value: Int) {
        nextCounter = max(1, value)
    }

    /// 结束文字输入（无论提交还是取消），界面收起输入框。
    public mutating func endTextEditing() {
        pendingTextEditID = nil
    }

    /// 改文字内容。框按新内容重量，**左上角不动** —— 否则打字时框会一边长一边跑。
    public mutating func setText(_ text: String, for id: UUID) {
        guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        let before = document.annotations[index]
        guard before.text != text else { return }
        var after = before
        after.text = text
        after.frame = AnnotationText.frame(text: text,
                                           fontSize: after.style.fontSize,
                                           origin: before.frame.standardized.origin)
        push(.update(before: [before], after: [after]))
        document.annotations[index] = after
    }

    public mutating func pointerMoved(to point: CGPoint) {
        switch gesture {
        case .drawing(let start, var draft):
            switch draft.kind {
            case .rectangle, .ellipse, .mosaic, .blur:
                draft.frame = CGRect(x: min(start.x, point.x),
                                     y: min(start.y, point.y),
                                     width: abs(point.x - start.x),
                                     height: abs(point.y - start.y))
            case .arrow:
                draft.path = [start, point]
                draft.frame = AnnotationGeometry.frame(forPath: draft.path,
                                                       lineWidth: draft.style.lineWidth,
                                                       headFrom: start,
                                                       headTo: point)
            case .pen:
                // 采点要有间隔：不设阈值时一次拖动能收上千个点，
                // 序列化、命中测试、重绘全跟着变慢，而画出来完全一样。
                let last = draft.path.last ?? start
                guard hypot(point.x - last.x, point.y - last.y) >= Self.penPointSpacing else { break }
                draft.path.append(point)
                draft.frame = AnnotationGeometry.frame(forPath: draft.path,
                                                       lineWidth: draft.style.lineWidth)
            case .text:
                break
            }
            gesture = .drawing(start: start, draft: draft)
        case .moving(let origin, let original, _):
            let delta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            let moved = original.map { $0.translated(by: delta) }
            gesture = .moving(origin: origin, original: original, current: moved)
        case .resizing(let handle, let original, _):
            var updated = original
            updated.applyFrame(AnnotationDocument.resized(original.frame, handle: handle, to: point))
            gesture = .resizing(handle: handle, original: original, current: updated)
        case nil:
            break
        }
    }

    public mutating func pointerUp() {
        switch gesture {
        case .drawing(_, let draft):
            if let committed = committableDraft(draft) {
                push(.add(committed))
                document.annotations.append(committed)
                selection = [committed.id]
                // 画笔与文字留在原工具上：连着画几笔 / 连着放几个序号是常态。
                // 矩形这类"画一个就完事"的回到选择工具，免得想调整时又画出一个框。
                // 画笔、文字、打码都留在原工具上：连着画几笔 / 放几个 / 涂几块是常态。
                // 矩形这类"画一个就完事"的回到选择工具，免得想调整时又画出一个框。
                switch committed.kind {
                case .pen, .text, .mosaic, .blur:
                    break
                case .rectangle, .ellipse, .arrow:
                    tool = .select
                }
            }
        case .moving(_, _, let current):
            commitFrameChange(current)
        case .resizing(_, _, let current):
            commitFrameChange([current])
        case nil:
            break
        }
        gesture = nil
    }

    /// 松手时这一笔算不算数。太短的都丢掉 —— 手抖点一下不该留下一个看不见的对象。
    private func committableDraft(_ draft: Annotation) -> Annotation? {
        var committed = draft
        switch draft.kind {
        case .rectangle, .ellipse, .mosaic, .blur:
            let box = draft.frame.standardized
            guard box.width >= 2, box.height >= 2 else { return nil }
            committed.frame = box
        case .arrow:
            guard draft.path.count >= 2 else { return nil }
            let start = draft.path[0]
            let end = draft.path[1]
            guard hypot(end.x - start.x, end.y - start.y) >= Self.minimumArrowLength else { return nil }
        case .pen:
            // 单点等于一个圆点，没有信息量；至少要有一次真正的移动
            guard draft.path.count >= 2 else { return nil }
        case .text:
            break
        }
        committed.zIndex = nextZIndex()
        return committed
    }

    public mutating func setStrokeColor(_ color: AnnotationColor) {
        guard gesture == nil else { return }
        style.stroke = color
        let before = selectedAnnotations()
        guard !before.isEmpty else { return }
        let after = before.map { annotation -> Annotation in
            var copy = annotation
            copy.style.stroke = color
            return copy
        }
        push(.update(before: before, after: after))
        replace(after)
    }

    public mutating func setLineWidth(_ width: CGFloat) {
        guard gesture == nil else { return }
        let clamped = max(1, width)
        style.lineWidth = clamped
        let before = selectedAnnotations()
        guard !before.isEmpty else { return }
        let after = before.map { annotation -> Annotation in
            var copy = annotation
            copy.style.lineWidth = clamped
            return copy
        }
        push(.update(before: before, after: after))
        replace(after)
    }

    /// 改打码强度（选中马赛克/模糊时工具栏那一排就是它）。
    public mutating func setEffectStrength(_ strength: CGFloat) {
        guard gesture == nil else { return }
        let before = selectedAnnotations().filter { $0.kind == .mosaic || $0.kind == .blur }
        guard !before.isEmpty else { return }
        let after = before.map { annotation -> Annotation in
            var copy = annotation
            copy.style.effectStrength = RedactionFilter.clampStrength(strength, for: copy.kind)
            return copy
        }
        // 样式也要跟着记，否则下一个打码对象又回到旧强度
        style.effectStrength = after.first?.style.effectStrength ?? strength
        push(.update(before: before, after: after))
        replace(after)
    }

    /// 改字号（选中文字时工具栏的"粗细"就是它）。框按新字号重量，左上角不动。
    public mutating func setFontSize(_ size: CGFloat) {
        guard gesture == nil else { return }
        let clamped = min(400, max(6, size))
        style.fontSize = clamped
        let before = selectedAnnotations().filter { $0.kind == .text }
        guard !before.isEmpty else { return }
        let after = before.map { annotation -> Annotation in
            var copy = annotation
            copy.style.fontSize = clamped
            copy.frame = AnnotationText.frame(text: copy.text,
                                              fontSize: clamped,
                                              origin: annotation.frame.standardized.origin)
            return copy
        }
        push(.update(before: before, after: after))
        replace(after)
    }

    public mutating func deleteSelection() {
        guard gesture == nil else { return }
        let items = document.annotations.enumerated().compactMap { index, annotation -> RemovedAnnotation? in
            selection.contains(annotation.id) ? RemovedAnnotation(index: index, annotation: annotation) : nil
        }
        guard !items.isEmpty else { return }
        push(.remove(items))
        let ids = selection
        document.annotations.removeAll { ids.contains($0.id) }
        selection = []
    }

    /// 裁切。界面在 ticket 09；这里先把命令放进撤销栈，保证能和标注交错撤销。
    public mutating func applyCrop(_ rect: CGRect) {
        guard gesture == nil else { return }
        let bounds = CGRect(origin: .zero, size: document.pixelSize)
        let clamped = rect.standardized.intersection(bounds)
        guard clamped.width >= 1, clamped.height >= 1, clamped != document.cropRect else { return }
        push(.crop(before: document.cropRect, after: clamped))
        document.cropRect = clamped
    }

    // MARK: - 裁切模式

    /// 正在调整的裁切框（**原图像素**）。非 `nil` 即在裁切模式。
    ///
    /// 与 `applyCrop` 分开：拖框期间**不进撤销栈**（一次拖动只该产生一条命令），
    /// 回车才落成命令、Esc 直接丢弃。
    public private(set) var cropDraft: CGRect?

    public var isCropping: Bool { cropDraft != nil }

    /// 裁切框**已经被拖出来过**吗。
    ///
    /// 状态行靠它分辨两张脸：还没拖出时说「拖出保留框」，拖出来之后说「⏎ 应用」（§04）。
    ///
    /// 判据是"草稿与当前的裁切矩形不同" —— `beginCrop()` 把草稿设成**当前的**裁切矩形，
    /// 所以刚拿起裁切刀那一刻它是 `false`（框还没动过）。
    /// 拿 `cropDraft != nil` 当判据是错的：那个从头到尾都是真的，
    /// 两张脸会合成一张 —— 用户永远等不到"可以按 ⏎ 了"那句话。
    public var isCropFrameAdjusted: Bool {
        guard let cropDraft else { return false }
        return cropDraft != document.cropRect
    }

    public mutating func beginCrop() {
        guard gesture == nil else { return }
        cropDraft = document.cropRect
        selection = []
    }

    /// 拖裁切框的某个角。结果**夹在图像范围内** —— 拖出图外会得到一张带透明边的图。
    public mutating func updateCrop(handle: AnnotationHandle, to point: CGPoint) {
        guard let draft = cropDraft else { return }
        let bounds = CGRect(origin: .zero, size: document.pixelSize)
        let clamped = CGPoint(x: min(max(bounds.minX, point.x), bounds.maxX),
                              y: min(max(bounds.minY, point.y), bounds.maxY))
        cropDraft = AnnotationDocument.resized(draft, handle: handle, to: clamped)
    }

    /// 整体平移裁切框（拖动框内部）。同样夹在图像范围内。
    public mutating func moveCrop(by delta: CGPoint) {
        guard let draft = cropDraft else { return }
        let bounds = CGRect(origin: .zero, size: document.pixelSize)
        var moved = draft.offsetBy(dx: delta.x, dy: delta.y)
        moved.origin.x = min(max(bounds.minX, moved.origin.x), max(bounds.minX, bounds.maxX - moved.width))
        moved.origin.y = min(max(bounds.minY, moved.origin.y), max(bounds.minY, bounds.maxY - moved.height))
        cropDraft = moved
    }

    public mutating func cancelCrop() {
        cropDraft = nil
    }

    /// 应用裁切。框太小（<8 像素）视为误操作，返回 `false` 并保持裁切模式。
    @discardableResult
    public mutating func commitCrop() -> Bool {
        guard let draft = cropDraft else { return false }
        guard draft.width >= 8, draft.height >= 8 else { return false }
        applyCrop(draft)
        cropDraft = nil
        return true
    }

    public mutating func undo() {
        guard canUndo, let command = undoStack.popLast() else { return }
        revert(command)
        redoStack.append(command)
    }

    public mutating func redo() {
        guard canRedo, let command = redoStack.popLast() else { return }
        apply(command)
        undoStack.append(command)
    }

    // MARK: - 私有

    private enum Gesture: Equatable {
        case drawing(start: CGPoint, draft: Annotation)
        case moving(origin: CGPoint, original: [Annotation], current: [Annotation])
        case resizing(handle: AnnotationHandle, original: Annotation, current: Annotation)
    }

    private struct RemovedAnnotation: Equatable {
        var index: Int
        var annotation: Annotation
    }

    private enum EditorCommand: Equatable {
        case add(Annotation)
        case remove([RemovedAnnotation])
        case update(before: [Annotation], after: [Annotation])
        case crop(before: CGRect, after: CGRect)
    }

    private func nextZIndex() -> Int {
        (document.annotations.map(\.zIndex).max() ?? 0) + 1
    }

    private func selectedAnnotations() -> [Annotation] {
        document.annotations.filter { selection.contains($0.id) }
    }

    private func overlay(_ items: inout [Annotation], with updates: [Annotation]) {
        for annotation in updates {
            if let index = items.firstIndex(where: { $0.id == annotation.id }) {
                items[index] = annotation
            }
        }
    }

    private mutating func commitFrameChange(_ current: [Annotation]) {
        let ids = Set(current.map(\.id))
        let before = document.annotations.filter { ids.contains($0.id) }
        let afterByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        // 比整个对象而不是只比 frame：拖控制点时箭头/画笔的 path 会一起变，
        // 文字的字号也会变 —— 只看 frame 会漏掉这些（虽然它们的 frame 也在动，
        // 但依赖"顺带也变了"是巧合，不是保证）。
        let changed = before.contains { annotation in
            afterByID[annotation.id] != annotation
        }
        guard changed else { return }
        push(.update(before: before, after: current))
        replace(current)
    }

    private mutating func replace(_ updates: [Annotation]) {
        for annotation in updates {
            if let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) {
                document.annotations[index] = annotation
            }
        }
    }

    private mutating func push(_ command: EditorCommand) {
        undoStack.append(command)
        redoStack.removeAll()
    }

    private mutating func apply(_ command: EditorCommand) {
        switch command {
        case .add(let annotation):
            document.annotations.append(annotation)
        case .remove(let items):
            let ids = Set(items.map(\.annotation.id))
            document.annotations.removeAll { ids.contains($0.id) }
        case .update(_, let after):
            replace(after)
        case .crop(_, let after):
            document.cropRect = after
        }
    }

    private mutating func revert(_ command: EditorCommand) {
        switch command {
        case .add(let annotation):
            document.annotations.removeAll { $0.id == annotation.id }
            selection.remove(annotation.id)
        case .remove(let items):
            for item in items.sorted(by: { $0.index < $1.index }) {
                let insertAt = min(item.index, document.annotations.count)
                document.annotations.insert(item.annotation, at: insertAt)
            }
        case .update(let before, _):
            replace(before)
        case .crop(let before, _):
            document.cropRect = before
        }
    }
}

public enum AnnotationEditorTool: Equatable, Sendable {
    case select
    case rectangle
    case ellipse
    case arrow
    /// 自由画笔（折线）
    case pen
    /// 文字；配 `TextPreset.counter` 就是序号标记（**不占独立工具位**）
    case text
    /// 马赛克（涂抹敏感信息）
    case mosaic
    /// 毛玻璃模糊
    case blur

    /// 这个工具画出来的标注类型。`.select` 没有对应类型。
    public var annotationKind: AnnotationKind? {
        switch self {
        case .select: nil
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .pen: .pen
        case .text: .text
        case .mosaic: .mosaic
        case .blur: .blur
        }
    }
}

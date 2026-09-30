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
        case .rectangle, .ellipse:
            let kind: AnnotationKind = tool == .rectangle ? .rectangle : .ellipse
            let draft = Annotation(kind: kind,
                                   frame: CGRect(origin: point, size: .zero),
                                   style: style,
                                   zIndex: nextZIndex())
            gesture = .drawing(start: point, draft: draft)
            selection = []
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

    public mutating func pointerMoved(to point: CGPoint) {
        switch gesture {
        case .drawing(let start, var draft):
            draft.frame = CGRect(x: min(start.x, point.x),
                                 y: min(start.y, point.y),
                                 width: abs(point.x - start.x),
                                 height: abs(point.y - start.y))
            gesture = .drawing(start: start, draft: draft)
        case .moving(let origin, let original, _):
            let deltaX = point.x - origin.x
            let deltaY = point.y - origin.y
            let moved = original.map { annotation -> Annotation in
                var copy = annotation
                copy.frame.origin.x += deltaX
                copy.frame.origin.y += deltaY
                return copy
            }
            gesture = .moving(origin: origin, original: original, current: moved)
        case .resizing(let handle, let original, _):
            var updated = original
            updated.frame = AnnotationDocument.resized(original.frame, handle: handle, to: point)
            gesture = .resizing(handle: handle, original: original, current: updated)
        case nil:
            break
        }
    }

    public mutating func pointerUp() {
        switch gesture {
        case .drawing(_, let draft):
            let box = draft.frame.standardized
            if box.width >= 2, box.height >= 2 {
                var committed = draft
                committed.frame = box
                committed.zIndex = nextZIndex()
                push(.add(committed))
                document.annotations.append(committed)
                selection = [committed.id]
                tool = .select
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
        let changed = before.contains { annotation in
            afterByID[annotation.id]?.frame != annotation.frame
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
}

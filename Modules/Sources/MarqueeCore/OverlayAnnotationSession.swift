import CoreGraphics
import Foundation

/// 覆盖层里"就地画标注"的状态机：选工具、落笔、收笔、撤销、重做。
///
/// ## 坐标
///
/// 一律用**选区局部点**：原点 = 选区的左上角，x 向右、y **向下**。
/// 于是它和 `Annotation` 的坐标系（原点左上、y 向下）完全一致，
/// 只有"单位是点还是像素"一处差别 —— 栅格化时按选区尺寸乘一次就完事。
///
/// 为什么不直接存像素：覆盖层是逐屏点坐标工作的，画的时候 1 点 = 1 屏幕点，
/// 线宽与字号按"看起来多粗"来定才对。存像素就得在每次鼠标移动时反向换算，
/// 一旦屏幕 scale 变了（换屏、改分辨率）已有的标注还得重算。
///
/// ## 为什么放 Core
///
/// 落笔 / 收笔 / 最小尺寸 / 撤销栈这些全是纯逻辑，脱机就能测。
/// 放在 `MarqueeOverlay` 里就只能靠人手点 —— 而"一次误点留下了一个点"
/// 这种问题恰恰是最不容易在手工点击中稳定复现的。
public struct OverlayAnnotationSession: Equatable, Sendable {

    /// 一笔至少要多长才算数（点）。
    ///
    /// 一次误点（按下、手抖 1 点、松开）不该在图上留下任何东西 ——
    /// 而留下的往往是一个 1×1 的点，用户得先放大才找得到它，
    /// 却会一直看到导出图里多一个脏点。
    public static let minimumExtent: CGFloat = 3

    /// 画笔相邻两点的最小间距（点）。鼠标事件很密，不去重会存下成百上千个几乎重合的点。
    public static let penMinimumStep: CGFloat = 1.5

    /// 已提交的标注（按画的先后）。
    public private(set) var annotations: [Annotation] = []
    /// 正在画的那一笔。`nil` = 没在画。
    public private(set) var draft: Annotation?

    /// 正在**输入内容**的那个文字标注。`nil` = 没在输入。
    ///
    /// 它和 `draft` 分开，而不是复用 `draft`，因为两者的"完成"条件完全不同：
    /// 一笔的完成看**几何**（够不够长），文字的完成看**内容**（有没有字）。
    /// 塞在一起的话，`endStroke` 里就要分两种判据 —— 那正是"一段代码管两件事"。
    public private(set) var textEditor: Annotation?

    /// 当前工具。`nil` = 没选工具（拖拽 = 改选区几何）。
    public private(set) var tool: OverlayTool?

    /// 选中的标注（"画完还能改"）。空集 = 没选中任何东西。
    public private(set) var selection: Set<UUID> = []
    /// 正在拖动的那一次移动：按下点 + **按下那一刻的完整快照**。
    ///
    /// 存快照而不是"每帧累加位移"：后者会累积浮点误差，而且中途改选中集合时
    /// 基准就错了（已经挪过的那些会被再挪一次）。
    ///
    /// 用一个具名类型而不是元组：**元组不满足 `Equatable`**，
    /// 而本类型是 `Equatable` 的 —— 加一个元组属性会让整个类型直接编不过。
    private struct MoveAnchor: Equatable {
        var point: CGPoint
        var before: [Annotation]
    }
    private var moveAnchor: MoveAnchor?

    /// 正在拖动的那一次**缩放**：按下那一刻的整个标注 + 抓的是哪个控制点。
    ///
    /// 存整个标注快照（而不是只存框）是因为 `Annotation.applyFrame` 对箭头 / 画笔
    /// 要"从旧框缩到新框"——每帧以**快照**为基准才不累积误差（与移动同一条理由）。
    private struct ResizeAnchor: Equatable {
        var before: Annotation
        var handle: SelectionGeometry.Handle
    }
    private var resizeAnchor: ResizeAnchor?

    /// `⇧` 是否按着（拖角时锁宽高比）。
    ///
    /// 由控制层推进来：标注会话在 Core 里，**不认识 `NSEvent`** —— 自己读修饰键就没法脱机测。
    public var isShiftDown: Bool = false

    /// 下一个标注用的样式（颜色 / 线宽）。改它**不入撤销栈** —— 它不影响已有内容。
    public var style: AnnotationStyle

    private var strokeStart: CGPoint?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    public init(style: AnnotationStyle = AnnotationStyle(stroke: AnnotationPalette.defaultColor,
                                                         lineWidth: AnnotationPalette.defaultLineWidth,
                                                         fontSize: AnnotationPalette.defaultOverlayFontSize,
                                                         effectStrength: AnnotationPalette.defaultRedactionStrength)) {
        self.style = style
    }

    // MARK: - 状态

    public var isEmpty: Bool { annotations.isEmpty && draft == nil && textEditor == nil }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// 是否正处在"画标注"模式（＝选了任一工具）。
    ///
    /// 与"能不能改已有标注"**不是同一个问题**：没选工具时是"改已有标注"的模式，
    /// 那时拖动是改**选区几何**、按在某个标注上就选中它。
    /// 两者混在一个判据里的话，"拖动 = 画一笔"会在没选工具时也成立，
    /// 于是用户想点选一个箭头，结果在它旁边画了个新矩形。
    public var isDrawing: Bool { tool != nil }

    /// 是否处在"改已有标注 / 改选区几何"的模式 —— 即**没选任何工具**。
    ///
    /// 「选择」原先是工具条上的一个显式格子（ticket 22）。收掉它之后，
    /// "未选工具"就承担了那个角色：按在标注上＝选中并拖动，按在别处＝动选区。
    public var isSelecting: Bool { tool == nil }

    /// 选中的那些标注（按画的先后）。
    public var selectedAnnotations: [Annotation] {
        annotations.filter { selection.contains($0.id) }
    }

    /// 是否正在输入文字。
    public var isEditingText: Bool { textEditor != nil }

    /// 那三档尺寸此刻代表什么（线宽 / 打码强度 / 字号）。
    ///
    /// 没选工具时按线宽算 —— 那时工具条上的三档仍然是可点的（用户会先调再选工具）。
    public var sizeMeaning: OverlaySizeMeaning { tool?.sizeMeaning ?? .lineWidth }

    /// 当前工具是否需要底图像素（马赛克 / 模糊）。
    ///
    /// 控制层用它决定"要不要去准备打码底图"。做成会话上的一个查询，而不是让界面
    /// 各自去判断 `tool == .mosaic || tool == .blur` —— 那种判断散开之后，
    /// 加第三类需要底图的工具时一定会漏掉一处。
    public var usesRedaction: Bool { tool?.needsBackdrop == true }

    /// 该画到屏幕上的全部标注（已提交的 + 正在画的草稿）。
    ///
    /// 草稿也要画：用户拖的时候必须看到框跟着走，否则工具像是没反应。
    public var visibleAnnotations: [Annotation] {
        var visible = annotations
        if let draft { visible.append(draft) }
        // 待输入的文字也要画：用户点完必须**立刻看见**那个落脚点，
        // 否则"点了没反应"与"这个工具没做"完全一样。
        if let textEditor { visible.append(textEditor) }
        return visible
    }

    // MARK: - 工具

    /// 选中某个工具；**再选一次同一个工具 = 取消选中**。
    ///
    /// 取消选中要能一步做到：画完几个箭头想改选区大小，不该先去别处点一下。
    public mutating func toggle(tool: OverlayTool) {
        cancelStroke()
        cancelText()
        selection = []
        moveAnchor = nil
        self.tool = (self.tool == tool) ? nil : tool
    }

    /// 取消工具选择（回到"调整选区"的模式）。
    public mutating func clearTool() {
        cancelStroke()
        cancelText()
        selection = []
        moveAnchor = nil
        tool = nil
    }

    // MARK: - 选择 / 移动 / 删除（ticket 22）

    /// 最上面那个"包含这个点"的标注。
    ///
    /// 判据走 `Annotation.contains`（箭头与画笔按**到路径的距离**判，不按包围盒 ——
    /// 斜线的包围盒里有大片空白，用包围盒会"点空白处却选中了箭头"）。
    /// 顺序与 `AnnotationDocument.orderedFrontToBack` 一致：后画的在上面。
    public func annotation(at point: CGPoint) -> Annotation? {
        for annotation in orderedFrontToBack() where annotation.contains(point) {
            return annotation
        }
        return nil
    }

    /// 点一下：命中就选中它；没命中就清空选择。
    ///
    /// - Returns: 是否命中了某个标注。
    @discardableResult
    public mutating func select(at point: CGPoint) -> Bool {
        guard let hit = annotation(at: point) else {
            selection = []
            return false
        }
        selection = [hit.id]
        return true
    }

    public mutating func clearSelection() { selection = [] }

    /// 这一按要不要交给「改已有标注」处理（隐式选择，ticket 24）。
    ///
    /// - Parameter local: 落在**标注坐标系**里的点；`nil` = 现在**没有画布**（还没落点）。
    ///
    /// ⚠️ **`local == nil` 必须返回 `false`** —— 这是回归测试钉住的一条（ticket 25）。
    ///
    /// 上一版把判据写成"只看 `isSelecting`（＝没选任何工具）"，而**没选工具是默认状态** ——
    /// 于是每一次按下都被这里接走：`dragMode` 被占成"画一笔"，可草稿根本没开始。
    /// 表现是**拖着鼠标，选区和标注什么也不出现**，而它坏掉的样子与"功能没做"一模一样。
    ///
    /// 判据放在会话里（而不是散在控制层的 `if` 里），就是为了让这条能被单测钉住。
    public func takesPressForAnnotationEditing(local: CGPoint?) -> Bool {
        guard isSelecting, let local else { return false }
        // 与 `beginResize` 用同一个控制点判据：能缩放的，按下也算"改已有标注"
        if let target = selectedAnnotations.first, selectedAnnotations.count == 1,
           handle(at: local, on: target.frame.standardized) != nil {
            return true
        }
        return annotation(at: local) != nil
    }

    /// 按下：点在某个标注上就开始拖动它（顺带把它选中）。
    ///
    /// - Returns: 是否开始了拖动。
    @discardableResult
    public mutating func beginMove(at point: CGPoint) -> Bool {
        guard let hit = annotation(at: point) else { return false }
        if !selection.contains(hit.id) { selection = [hit.id] }
        moveAnchor = MoveAnchor(point: point, before: annotations)
        cancelStroke()
        return true
    }

    public var isMovingAnnotations: Bool { moveAnchor != nil }

    // MARK: - 拖控制点缩放（ticket 22 收尾）

    /// 选中标注的 8 个控制点（**选区局部点**，与 `annotations` 同一坐标系）。
    ///
    /// 只有**恰好选中一个**时才给：多个选中时"缩哪一个"没有明确答案，
    /// 而缩"整体的包围盒"会让每个对象各自被拉伸 —— 那是另一个功能。
    /// 视图只负责把这些矩形画出来，换算留在这里（翻错 y 的表现是"拖上边动下边"，视图里看不出来）。
    public var selectedHandles: [(handle: SelectionGeometry.Handle, frame: CGRect)] {
        guard let box = resizableframe else { return [] }
        // 标注是 y 向下，`Handle` 是 Cocoa 那套 —— 进去与出来都翻一次
        let flipped = SelectionGeometry.YDown.flip(box)
        return SelectionGeometry.Handle.allCases.map { handle in
            (handle, SelectionGeometry.YDown.flip(SelectionGeometry.handleFrame(handle, on: flipped)))
        }
    }

    /// 能被缩放的那个标注的框（恰好选中一个时）。
    private var resizableframe: CGRect? {
        let selected = selectedAnnotations
        guard selected.count == 1, let only = selected.first else { return nil }
        return only.frame.standardized
    }

    public var isResizingAnnotations: Bool { resizeAnchor != nil }

    /// 正在拖的那个控制点（`nil` = 没在缩）。给光标用：拖着哪个角就该显示哪个角的箭头。
    public var resizingHandle: SelectionGeometry.Handle? { resizeAnchor?.handle }

    /// 按下：抓在控制点上就开始缩放。
    ///
    /// - Returns: 是否真的开始了。
    @discardableResult
    public mutating func beginResize(at point: CGPoint) -> Bool {
        let selected = selectedAnnotations
        guard selected.count == 1, let target = selected.first,
              let handle = handle(at: point, on: target.frame.standardized) else { return false }
        cancelStroke()
        moveAnchor = nil
        resizeAnchor = ResizeAnchor(before: target, handle: handle)
        return true
    }

    /// 拖到哪。
    ///
    /// 基准永远是**按下那一刻那一版**（`anchor.before`），不是上一帧 ——
    /// `applyFrame` 对箭头 / 画笔是"从旧框缩到新框"，按上一帧算会累积误差。
    public mutating func updateResize(to point: CGPoint) {
        guard let anchor = resizeAnchor,
              let index = annotations.firstIndex(where: { $0.id == anchor.before.id }) else { return }
        let box = anchor.before.frame.standardized
        let aspect = isShiftDown ? box.width / max(1, box.height) : nil
        let next = SelectionGeometry.resized(SelectionGeometry.YDown.flip(box),
                                            handle: anchor.handle,
                                            to: SelectionGeometry.YDown.flip(point),
                                            aspect: aspect)
        var updated = anchor.before
        updated.applyFrame(SelectionGeometry.YDown.flip(next))
        annotations[index] = updated
    }

    /// 松手。
    ///
    /// - Returns: 是否真的改过（拖回原处不算一步改动 —— 与移动同一条规则）。
    @discardableResult
    public mutating func endResize(to point: CGPoint) -> Bool {
        guard let anchor = resizeAnchor else { return false }
        updateResize(to: point)
        resizeAnchor = nil
        return commitResize(from: anchor.before)
    }

    /// 放弃这次缩放，退回按下时那一版（`Esc` 拖到一半用）。没在缩放时是空操作。
    public mutating func cancelResize() {
        guard let anchor = resizeAnchor else { return }
        resizeAnchor = nil
        guard let index = annotations.firstIndex(where: { $0.id == anchor.before.id }) else { return }
        annotations[index] = anchor.before
    }

    /// 缩放一步的收尾：把那一版（按下前的）进撤销栈。
    ///
    /// - Returns: 是否真的变了。
    private mutating func commitResize(from before: Annotation) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == before.id }) else { return false }
        guard annotations[index] != before else {
            // 拖回原处：显式写回，免得留下浮点残差（"看起来一样但比不出来"）
            annotations[index] = before
            return false
        }
        var previous = annotations
        previous[index] = before
        commit(previous, replacing: annotations)
        return true
    }

    /// 点上的控制点（`nil` = 不在任何控制点上）。
    ///
    /// 走 `selectedHandles`（而不是自己再算一遍中心）—— 命中与绘制必须是同一份几何，
    /// 各算各的会偏出去几个点，而那种偏差的表现是"控制点看着在这儿、拖它没反应"。
    private func handle(at point: CGPoint,
                        on frame: CGRect) -> SelectionGeometry.Handle? {
        selectedHandles.first { $0.frame.contains(point) }?.handle
    }

    /// 拖到哪。整框平移 —— 框与路径一起走（`translated(by:)` 已经处理了这一点）。
    public mutating func updateMove(to point: CGPoint) {
        guard let anchor = moveAnchor else { return }
        let delta = CGPoint(x: point.x - anchor.point.x, y: point.y - anchor.point.y)
        let ids = selection
        annotations = anchor.before.map { ids.contains($0.id) ? $0.translated(by: delta) : $0 }
    }

    /// 松手。
    ///
    /// - Returns: 是否真的动过（动了才进撤销栈 —— 点一下不该算一步改动）。
    @discardableResult
    public mutating func endMove(at point: CGPoint) -> Bool {
        guard let anchor = moveAnchor else { return false }
        updateMove(to: point)
        moveAnchor = nil

        let delta = CGPoint(x: point.x - anchor.point.x, y: point.y - anchor.point.y)
        guard hypot(delta.x, delta.y) >= 1 else {
            annotations = anchor.before
            return false
        }
        commit(anchor.before, replacing: annotations)
        return true
    }

    /// 删掉选中的那些。
    @discardableResult
    public mutating func deleteSelected() -> Bool {
        guard !selection.isEmpty else { return false }
        let remaining = annotations.filter { !selection.contains($0.id) }
        guard remaining.count != annotations.count else { return false }
        commit(annotations, replacing: remaining)
        selection = []
        cancelStroke()
        return true
    }

    // MARK: - 一笔

    /// 落笔。返回是否真的开始了（没选工具 / 工具不是"画一笔"的那类 / 已有草稿时为 `false`）。
    ///
    /// ⚠️ `isStrokeBased` 这道闸必须有：文字也是"有 kind 的工具"，放它进来就会
    /// 得到一个"宽度等于拖拽距离"的空文字框（见 `OverlayTool.isStrokeBased`）。
    @discardableResult
    public mutating func beginStroke(at point: CGPoint) -> Bool {
        guard let tool, tool.isStrokeBased, draft == nil else { return false }
        strokeStart = point
        draft = makeAnnotation(kind: tool.kind, at: point)
        return true
    }

    /// 拖到哪。没在画时是空操作。
    public mutating func updateStroke(to point: CGPoint) {
        guard var current = draft, let start = strokeStart else { return }
        switch current.kind {
        case .rectangle, .ellipse, .mosaic, .blur:
            // 用 union 而不是自己算 min/max：反向拖拽（右下往左上）时
            // `CGRect(x:y:width:height:)` 会得到一个负尺寸的框，
            // 描边在有的路径上画不出来 —— 表现是"往回拖就什么都没有"。
            current.frame = CGRect(origin: start, size: .zero)
                .union(CGRect(origin: point, size: .zero))
        case .arrow:
            current.path = [start, point]
            current.frame = Self.boundingBox(current.path)
        case .pen:
            if let last = current.path.last,
               hypot(point.x - last.x, point.y - last.y) < Self.penMinimumStep {
                return
            }
            current.path.append(point)
            current.frame = Self.boundingBox(current.path)
        case .text:
            // 覆盖层的工具条上暂时没有文字（要输入框，见 ticket 22）
            return
        }
        draft = current
    }

    /// 收笔。太短的一笔会被丢掉。
    ///
    /// - Returns: 是否真的产出了一个标注。
    @discardableResult
    public mutating func endStroke(at point: CGPoint) -> Bool {
        guard draft != nil else { return false }
        updateStroke(to: point)
        defer {
            draft = nil
            strokeStart = nil
        }
        guard let candidate = draft, Self.isUsable(candidate) else { return false }
        commit(candidate)
        return true
    }

    /// 丢掉正在进行的那一笔**或那一次缩放**（`Esc` / 工具被换掉时用）。已提交的标注不动。
    ///
    /// 收尾只留这一处：`toggle` / `clearTool` / `undo` / `redo` / `deleteSelected` /
    /// `beginMove` / `beginResize` 都走它 —— 各写各的话，加第三种手势时一定会漏一处，
    /// 而漏掉的表现是"某个东西一直挂着"（PITFALLS 66 的同一族）。
    public mutating func cancelStroke() {
        draft = nil
        strokeStart = nil
        cancelResize()
    }

    // MARK: - 文字输入（ticket 22）

    /// 在 `point`（选区局部点）放下一个待输入的文字，进入输入状态。
    ///
    /// - Returns: 落下的那个标注（视图拿它定位输入框）；没选文字工具时为 `nil`。
    ///
    /// 内容此时是空的 —— 提交时才判定它成不成立（空内容直接丢弃，见 `commitText`）。
    @discardableResult
    public mutating func beginText(at point: CGPoint) -> Annotation? {
        guard tool == .text else { return nil }
        cancelStroke()
        let annotation = Annotation(kind: .text,
                                    frame: AnnotationText.frame(text: "",
                                                                fontSize: style.fontSize,
                                                                origin: point),
                                    style: style,
                                    zIndex: annotations.count)
        textEditor = annotation
        return annotation
    }

    /// 输入框里的内容变了。框跟着**重新量**：命中、选中框、导出都按这个框算。
    public mutating func updateText(_ text: String) {
        guard var editing = textEditor else { return }
        editing.text = text
        // 字号也可能在输入途中被工具条改过，跟着最新样式走
        editing.style = style
        editing.frame = AnnotationText.frame(text: text,
                                             fontSize: style.fontSize,
                                             origin: editing.frame.origin)
        textEditor = editing
    }

    /// 提交输入。
    ///
    /// - Returns: 是否真的产出了一个标注（**空内容一律丢弃**）。
    ///
    /// 空内容必须丢掉：用户点了一下又按回车（或点了别处），
    /// 在图上留一个 0 宽的空文字，谁也看不见、谁也删不掉 ——
    /// 而它会一直参与导出与"有标注"的判断。
    @discardableResult
    public mutating func commitText(_ text: String) -> Bool {
        guard var pending = textEditor else { return false }
        textEditor = nil
        guard !text.isEmpty else { return false }
        // 用**提交这一刻**的样式（输入途中用户可能改过颜色或字号）
        pending.style = style
        pending.text = text
        pending.frame = AnnotationText.frame(text: text,
                                             fontSize: style.fontSize,
                                             origin: pending.frame.origin)
        commit(pending)
        return true
    }

    /// 丢掉正在输入的文字（`Esc` / 换工具 / 收场时用）。已提交的标注不动。
    public mutating func cancelText() {
        textEditor = nil
    }

    // MARK: - 表情贴纸（ticket 24）

    /// 落一个表情。**点一下**就有，不拖一笔 —— 内容在选工具时就定好了。
    ///
    /// 产出的标注**就是 `.text`**：绘制、导出、缩放、移动、撤销全部复用现成路径，
    /// 一行新的渲染分支都不用加。表情只解决"怎么选到那一枚"，那是交互问题。
    ///
    /// - Returns: 是否真的落上了一个。空串与"当前不是表情工具"都返回 `false`
    ///   （在图上留一个看不见的空文字，用户既看不到也删不掉）。
    @discardableResult
    public mutating func stampEmoji(_ emoji: String, at point: CGPoint) -> Bool {
        guard tool == .emoji, !emoji.isEmpty else { return false }
        cancelStroke()
        var annotation = Annotation(kind: .text,
                                    frame: AnnotationText.frame(text: emoji,
                                                                fontSize: style.fontSize,
                                                                origin: point),
                                    style: style,
                                    zIndex: annotations.count)
        annotation.text = emoji
        commit(annotation)
        return true
    }

    // MARK: - 撤销

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        // 撤销可能把"被删掉的标注"带回来，也可能把"刚画的"收走 ——
        // 两种情况下选中集合都可能指向不存在的东西，必须一起收拾。
        //
        // 注意这条**没有可见症状**（现有的几处 guard 恰好挡住了后果），
        // 所以它靠"断言不变量"守着，而不是靠某个行为断言 —— 见会话测试里那条用例的注释。
        pruneSelection()
        cancelStroke()
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(annotations)
        annotations = next
        pruneSelection()
        cancelStroke()
        return true
    }

    /// 全部清掉（连同撤销栈）。
    public mutating func removeAll() {
        annotations = []
        draft = nil
        textEditor = nil
        strokeStart = nil
        selection = []
        moveAnchor = nil
        resizeAnchor = nil
        undoStack = []
        redoStack = []
    }

    // MARK: - 内部

    private mutating func commit(_ annotation: Annotation) {
        undoStack.append(annotations)
        redoStack.removeAll()
        annotations.append(annotation)
    }

    private func makeAnnotation(kind: AnnotationKind, at point: CGPoint) -> Annotation {
        // zIndex 用序号递增：后画的盖在上面，与数组顺序一致
        let zIndex = annotations.count
        switch kind {
        case .rectangle, .ellipse, .mosaic, .blur:
            return Annotation(kind: kind,
                              frame: CGRect(origin: point, size: .zero),
                              style: style,
                              zIndex: zIndex)
        case .arrow:
            return Annotation(kind: .arrow,
                              frame: CGRect(origin: point, size: .zero),
                              style: style,
                              zIndex: zIndex,
                              path: [point, point])
        case .pen:
            return Annotation(kind: .pen,
                              frame: CGRect(origin: point, size: .zero),
                              style: style,
                              zIndex: zIndex,
                              path: [point])
        case .text:
            // 到不了这里：文字不走 `beginStroke`（见 `isStrokeBased`）。
            // 保留分支只为让 switch 完整 —— 框由字数量出来，不是零尺寸。
            return Annotation(kind: .text,
                              frame: AnnotationText.frame(text: "",
                                                          fontSize: style.fontSize,
                                                          origin: point),
                              style: style,
                              zIndex: zIndex)
        }
    }

    /// 前后顺序：`zIndex` 大的在上；相同则数组里靠后的在上（后画的盖住先画的）。
    private func orderedFrontToBack() -> [Annotation] {
        annotations.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.zIndex != rhs.element.zIndex {
                    return lhs.element.zIndex > rhs.element.zIndex
                }
                return lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    /// 一步改动的统一收口：进撤销栈、清重做栈、清掉已经不存在的选中项。
    ///
    /// 三件事必须一起做 —— 只做前两件的话，删掉一个标注再撤销回来时
    /// 选中集合里会留着一个**已经不存在的 id**，而它会让"下次删"什么都没发生。
    private mutating func commit(_ before: [Annotation], replacing after: [Annotation]) {
        undoStack.append(before)
        redoStack.removeAll()
        annotations = after
        pruneSelection()
    }

    private mutating func pruneSelection() {
        guard !selection.isEmpty else { return }
        selection.formIntersection(Set(annotations.map(\.id)))
    }

    /// 一笔是否够格成为标注。
    static func isUsable(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle, .ellipse, .mosaic, .blur:
            let box = annotation.frame.standardized
            return box.width >= minimumExtent && box.height >= minimumExtent
        case .arrow:
            guard annotation.path.count >= 2 else { return false }
            return distance(annotation.path[0], annotation.path[1]) >= minimumExtent
        case .pen:
            guard annotation.path.count >= 2 else { return false }
            var total: CGFloat = 0
            for index in 1..<annotation.path.count {
                total += distance(annotation.path[index - 1], annotation.path[index])
            }
            return total >= minimumExtent
        case .text:
            return true
        }
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}

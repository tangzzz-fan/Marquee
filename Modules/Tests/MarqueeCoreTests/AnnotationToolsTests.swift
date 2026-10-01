import CoreGraphics
import Foundation
import MarqueeTestSupport
import Testing
@testable import MarqueeCore

@Suite("箭头与画笔的几何")
struct AnnotationGeometryTests {

    @Test("点到线段：线段上为 0，线段外取到最近端点（不是到无限远的直线）")
    func distanceToSegment() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)

        #expect(AnnotationGeometry.distance(from: CGPoint(x: 50, y: 0), toSegment: start, end: end) == 0)
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 50, y: 7), toSegment: start, end: end) == 7)
        // 关键：越过端点后距离要"绕着端点量"，直线距离公式会给出 0（点在直线延长线上）
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 130, y: 0), toSegment: start, end: end) == 30)
        #expect(AnnotationGeometry.distance(from: CGPoint(x: -30, y: 0), toSegment: start, end: end) == 30)
        // 起点终点重合：退化成点
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 3, y: 4), toSegment: start, end: start) == 5)
    }

    @Test("点到折线：取所有线段里最近的一条")
    func distanceToPolyline() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 50, y: 5), toPolyline: points) == 5)
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 95, y: 50), toPolyline: points) == 5)
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 0, y: 0), toPolyline: []) == .greatestFiniteMagnitude)
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 3, y: 4), toPolyline: [.zero]) == 5)
    }

    @Test("箭头头部：尖端在终点，两翼对称且朝起点方向收")
    func arrowHeadShape() {
        // 水平箭头，向右
        let head = AnnotationGeometry.arrowHead(from: CGPoint(x: 0, y: 0),
                                               to: CGPoint(x: 100, y: 0),
                                               lineWidth: 4)
        #expect(head.count == 3)
        #expect(head[0] == CGPoint(x: 100, y: 0), "尖端必须正好落在终点")
        #expect(head[1].x == head[2].x, "两翼到尖端的水平距离应当相同")
        #expect(head[1].x < 100, "两翼应当在尖端后面")
        #expect(abs(head[1].y + head[2].y) < 0.001, "两翼应当关于轴线对称")
        #expect(head[1].y != head[2].y, "两翼不能重合")

        // 竖直箭头，向下：对称轴换成 x
        let down = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 0, y: 100), lineWidth: 4)
        #expect(abs(down[1].x + down[2].x) < 0.001)
        #expect(down[1].x != down[2].x)
    }

    @Test("零长度箭头不产生头部 —— 归一化零向量会得到 NaN，画出来是静默的空白")
    func zeroLengthArrowHasNoHead() {
        let head = AnnotationGeometry.arrowHead(from: CGPoint(x: 5, y: 5),
                                               to: CGPoint(x: 5, y: 5),
                                               lineWidth: 4)
        #expect(head.isEmpty)
    }

    @Test("线宽越粗，箭头头部越大（细线配大头会像个图钉）")
    func headGrowsWithLineWidth() {
        let thin = AnnotationGeometry.arrowHeadLength(forLineWidth: 2)
        let thick = AnnotationGeometry.arrowHeadLength(forLineWidth: 12)
        #expect(thin >= 10, "再细也要有个最小尺寸，否则看不清箭头")
        #expect(thick > thin)

        // 头部长度不能超过线本身，否则短箭头会被头部整个吃掉
        let short = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 8, y: 0), lineWidth: 20)
        #expect(short[1].x >= 0 && short[1].x <= 8)
    }

    @Test("包围盒含线宽与箭头头部 —— 否则导出时头部会被裁掉")
    func frameIncludesHeadAndWidth() {
        let frame = AnnotationGeometry.frame(forPath: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
                                             lineWidth: 8,
                                             headFrom: CGPoint(x: 0, y: 0),
                                             headTo: CGPoint(x: 100, y: 0))
        #expect(frame.contains(CGPoint(x: 100, y: 0)))
        // 两翼会超出中心线，必须被框住
        let head = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 8)
        for point in head {
            #expect(frame.contains(point), "头部顶点 \(point) 落在包围盒外")
        }
        #expect(frame.minX <= -4, "左边要留出半个线宽")
        #expect(frame.width >= 100 + 8)
    }

    @Test("路径等比映射到新框；框退化成零宽时不除零")
    func scalePathIntoNewFrame() {
        let old = CGRect(x: 0, y: 0, width: 100, height: 50)
        let new = CGRect(x: 10, y: 20, width: 200, height: 100)
        let scaled = AnnotationGeometry.scale(points: [CGPoint(x: 50, y: 25)], from: old, to: new)
        #expect(scaled == [CGPoint(x: 110, y: 70)], "中心点应当映射到新框中心")

        // 宽度为 0：那个轴只跟随平移
        let flat = AnnotationGeometry.scale(points: [CGPoint(x: 5, y: 5)],
                                           from: CGRect(x: 0, y: 0, width: 0, height: 10),
                                           to: CGRect(x: 7, y: 0, width: 30, height: 10))
        #expect(flat[0].x == 12, "零宽时该轴应当退化为平移（+7）")
        #expect(flat[0].y == 5)
    }
}

@Suite("箭头 / 画笔 / 文字 / 序号")
struct AnnotationToolTests {

    private func makeSession() -> AnnotationEditorSession {
        AnnotationEditorSession(pixelSize: CGSize(width: 800, height: 600))
    }

    private func draw(_ session: inout AnnotationEditorSession,
                      from start: CGPoint,
                      through points: [CGPoint]) {
        session.pointerDown(at: start, shift: false, handleRadius: 6)
        for point in points { session.pointerMoved(to: point) }
        session.pointerUp()
    }

    // MARK: - 箭头

    @Test("画箭头：路径就是起点到终点，包围盒含头部")
    func drawsArrow() {
        var session = makeSession()
        session.tool = .arrow
        draw(&session, from: CGPoint(x: 100, y: 100), through: [CGPoint(x: 300, y: 200)])

        #expect(session.document.annotations.count == 1)
        let arrow = session.document.annotations[0]
        #expect(arrow.kind == .arrow)
        #expect(arrow.path == [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)])
        #expect(arrow.frame.contains(CGPoint(x: 300, y: 200)))
        #expect(session.tool == .select, "画一个就回到选择工具（想调整时不要再画一个）")
    }

    @Test("拖太短的箭头不算数 —— 手抖点一下不该留下看不见的对象")
    func ignoresTinyArrow() {
        var session = makeSession()
        session.tool = .arrow
        draw(&session, from: CGPoint(x: 100, y: 100), through: [CGPoint(x: 102, y: 101)])
        #expect(session.document.annotations.isEmpty)
    }

    @Test("箭头只在靠近线的地方可点中 —— 包围盒里的空白不该选中它")
    func arrowHitTestFollowsTheLine() {
        var session = makeSession()
        session.tool = .arrow
        // 左上 → 右下 的对角线
        draw(&session, from: CGPoint(x: 100, y: 100), through: [CGPoint(x: 300, y: 300)])
        let arrow = session.document.annotations[0]

        #expect(arrow.contains(CGPoint(x: 200, y: 200)), "线上应当点得中")
        // 右上角落在包围盒内、但离对角线很远
        #expect(!arrow.contains(CGPoint(x: 290, y: 110)), "包围盒的空白角落不该点得中")
    }

    @Test("移动箭头：路径跟着走（只挪 frame 会「框走了线还在原地」）")
    func movingArrowMovesPath() {
        var session = makeSession()
        session.tool = .arrow
        draw(&session, from: .zero, through: [CGPoint(x: 100, y: 0)])
        let before = session.document.annotations[0]

        session.tool = .select
        session.pointerDown(at: CGPoint(x: 50, y: 0), shift: false, handleRadius: 6)
        session.pointerMoved(to: CGPoint(x: 80, y: 10))
        session.pointerUp()

        let arrow = session.document.annotations[0]
        #expect(arrow.path[0] == CGPoint(x: 30, y: 10))
        #expect(arrow.path[1] == CGPoint(x: 130, y: 10))
        // 框含半个线宽与翼展，不等于起点；判据是"整体位移量与拖拽一致"
        #expect(arrow.frame.minX == before.frame.minX + 30)
        #expect(arrow.frame.minY == before.frame.minY + 10)
    }

    @Test("拖箭头控制点：路径等比缩放")
    func resizingArrowScalesPath() {
        var session = makeSession()
        session.tool = .arrow
        draw(&session, from: .zero, through: [CGPoint(x: 100, y: 0)])

        session.tool = .select
        let arrow = session.document.annotations[0]
        // 抓住右下角往外拖一倍
        let corner = AnnotationHandle.bottomRight.point(on: arrow.frame)
        session.pointerDown(at: corner, shift: false, handleRadius: 8)
        session.pointerMoved(to: CGPoint(x: corner.x + 100, y: corner.y))
        session.pointerUp()

        let resized = session.document.annotations[0]
        #expect(resized.path.count == 2)
        #expect(resized.path[1].x > 150, "箭头应当被拉长，实际 \(resized.path)")
    }

    // MARK: - 画笔

    @Test("画笔：按间隔采点，框包住所有点")
    func drawsPen() {
        var session = makeSession()
        session.tool = .pen
        draw(&session, from: .zero, through: [CGPoint(x: 50, y: 0),
                                             CGPoint(x: 100, y: 50),
                                             CGPoint(x: 150, y: 0)])

        #expect(session.document.annotations.count == 1)
        let pen = session.document.annotations[0]
        #expect(pen.kind == .pen)
        #expect(pen.path.count == 4)
        #expect(pen.path.last == CGPoint(x: 150, y: 0))
        for point in pen.path {
            #expect(pen.frame.contains(point), "点 \(point) 不在框里")
        }
        #expect(session.tool == .pen, "画笔留在原工具上：连着画几笔是常态")
    }

    /// 不设间隔的话一次拖动能收上千个点，序列化/命中测试/重绘全跟着变慢，而画出来一样。
    @Test("画笔采点有最小间隔")
    func penSkipsTinyMovements() {
        var session = makeSession()
        session.tool = .pen
        session.pointerDown(at: .zero, shift: false, handleRadius: 6)
        session.pointerMoved(to: CGPoint(x: 0.5, y: 0))   // 太近，丢掉
        session.pointerMoved(to: CGPoint(x: 1.0, y: 0))   // 仍太近
        session.pointerMoved(to: CGPoint(x: 20, y: 0))    // 够远，收下
        session.pointerUp()

        let pen = session.document.annotations[0]
        #expect(pen.path == [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0)])
    }

    @Test("只点一下的画笔不算数（单点等于一个圆点，没有信息量）")
    func ignoresSinglePointPen() {
        var session = makeSession()
        session.tool = .pen
        draw(&session, from: CGPoint(x: 10, y: 10), through: [])
        #expect(session.document.annotations.isEmpty)
    }

    // MARK: - 文字

    @Test("落文字：先落一个可点中的空框，并请求输入")
    func placesTextAndRequestsInput() {
        var session = makeSession()
        session.tool = .text
        session.pointerDown(at: CGPoint(x: 100, y: 200), shift: false, handleRadius: 6)

        #expect(session.document.annotations.count == 1)
        let text = session.document.annotations[0]
        #expect(text.kind == .text)
        #expect(text.text.isEmpty)
        #expect(text.frame.origin == CGPoint(x: 100, y: 200))
        #expect(text.frame.width >= 1, "空文字的框也要有宽度，否则看不见也点不中")
        #expect(text.frame.height >= 1)
        #expect(session.pendingTextEditID == text.id)
        #expect(session.tool == .text, "文字工具留在原地：连着放几个是常态")

        session.endTextEditing()
        #expect(session.pendingTextEditID == nil)
    }

    @Test("输入内容后：框按新内容重量，左上角不动（否则打字时框会一边长一边跑）")
    func settingTextRemeasuresFrame() {
        var session = makeSession()
        session.tool = .text
        session.pointerDown(at: CGPoint(x: 100, y: 200), shift: false, handleRadius: 6)
        let id = session.document.annotations[0].id
        let emptyWidth = session.document.annotations[0].frame.width

        session.setText("这是一段比较长的标注文字", for: id)
        let text = session.document.annotations[0]
        #expect(text.text == "这是一段比较长的标注文字")
        #expect(text.frame.origin == CGPoint(x: 100, y: 200), "左上角必须不动")
        #expect(text.frame.width > emptyWidth, "内容变长，框要跟着变宽")
    }

    @Test("改文字内容可撤销")
    func settingTextIsUndoable() {
        var session = makeSession()
        session.tool = .text
        session.pointerDown(at: CGPoint(x: 10, y: 10), shift: false, handleRadius: 6)
        let id = session.document.annotations[0].id
        session.endTextEditing()
        session.setText("hello", for: id)

        session.undo()
        #expect(session.document.annotations[0].text.isEmpty)
        session.redo()
        #expect(session.document.annotations[0].text == "hello")
    }

    @Test("拖文字的控制点 = 缩放字号，框跟着重量")
    func resizingTextScalesFontSize() {
        var session = makeSession()
        session.tool = .text
        session.pointerDown(at: CGPoint(x: 100, y: 100), shift: false, handleRadius: 6)
        let id = session.document.annotations[0].id
        session.setText("Ag", for: id)
        session.endTextEditing()
        let before = session.document.annotations[0]
        let originalFontSize = before.style.fontSize

        session.tool = .select
        let corner = AnnotationHandle.bottomRight.point(on: before.frame)
        session.pointerDown(at: corner, shift: false, handleRadius: 8)
        session.pointerMoved(to: CGPoint(x: corner.x, y: corner.y + before.frame.height))
        session.pointerUp()

        let after = session.document.annotations[0]
        #expect(after.style.fontSize > originalFontSize, "往下拖应当放大字号")
        #expect(after.frame.origin == before.frame.origin, "左上角不动")
        #expect(after.frame.height > before.frame.height)
    }

    // MARK: - 序号

    @Test("序号预设：内容自动递增，不新建工具位")
    func counterIncrements() {
        var session = makeSession()
        session.tool = .text
        session.textPreset = .counter

        session.pointerDown(at: CGPoint(x: 10, y: 10), shift: false, handleRadius: 6)
        session.pointerDown(at: CGPoint(x: 10, y: 60), shift: false, handleRadius: 6)
        session.pointerDown(at: CGPoint(x: 10, y: 110), shift: false, handleRadius: 6)

        #expect(session.document.annotations.map(\.text) == ["1.", "2.", "3."])
        #expect(session.document.annotations.allSatisfy { $0.kind == .text })
        #expect(session.pendingTextEditID == nil, "序号不需要用户打字，不要弹输入框")
        #expect(session.nextCounter == 4)
    }

    @Test("序号可手动改起始值")
    func counterStartIsConfigurable() {
        var session = makeSession()
        session.tool = .text
        session.textPreset = .counter
        session.setCounterStart(7)

        session.pointerDown(at: CGPoint(x: 10, y: 10), shift: false, handleRadius: 6)
        #expect(session.document.annotations[0].text == "7.")
        #expect(session.nextCounter == 8)

        session.setCounterStart(0)
        #expect(session.nextCounter == 1, "起始值至少为 1")
    }

    @Test("序号只增不重排：删掉中间那个，后面的编号保持不变")
    func counterDoesNotRenumber() {
        var session = makeSession()
        session.tool = .text
        session.textPreset = .counter
        session.pointerDown(at: CGPoint(x: 10, y: 10), shift: false, handleRadius: 6)
        session.pointerDown(at: CGPoint(x: 10, y: 60), shift: false, handleRadius: 6)

        session.selection = [session.document.annotations[0].id]
        session.deleteSelection()
        session.pointerDown(at: CGPoint(x: 10, y: 110), shift: false, handleRadius: 6)

        #expect(session.document.annotations.map(\.text) == ["2.", "3."])
    }

    // MARK: - 撤销

    @Test("每一类新标注的创建都能撤销与重做")
    func everyKindIsUndoable() {
        for kind in [AnnotationKind.arrow, .pen, .text] {
            var session = makeSession()
            switch kind {
            case .arrow:
                session.tool = .arrow
                draw(&session, from: .zero, through: [CGPoint(x: 100, y: 50)])
            case .pen:
                session.tool = .pen
                draw(&session, from: .zero, through: [CGPoint(x: 50, y: 50)])
            case .text:
                session.tool = .text
                session.pointerDown(at: CGPoint(x: 20, y: 20), shift: false, handleRadius: 6)
                session.endTextEditing()
            case .rectangle, .ellipse:
                continue
            }

            #expect(session.document.annotations.count == 1, "\(kind) 应当已创建")
            session.undo()
            #expect(session.document.annotations.isEmpty, "\(kind) 应当能撤销")
            #expect(session.selection.isEmpty)
            session.redo()
            #expect(session.document.annotations.count == 1, "\(kind) 应当能重做")
        }
    }

    @Test("移动之后撤销，位置与路径一起回到原处")
    func undoRestoresPath() {
        var session = makeSession()
        session.tool = .arrow
        draw(&session, from: .zero, through: [CGPoint(x: 100, y: 0)])
        let original = session.document.annotations[0]

        session.tool = .select
        session.pointerDown(at: CGPoint(x: 50, y: 0), shift: false, handleRadius: 6)
        session.pointerMoved(to: CGPoint(x: 200, y: 100))
        session.pointerUp()
        #expect(session.document.annotations[0].path != original.path)

        session.undo()
        #expect(session.document.annotations[0] == original)
    }
}

@Suite("标注的序列化与导出")
struct AnnotationSerializationTests {

    private func makeDocument() -> AnnotationDocument {
        var document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300))
        let style = AnnotationStyle(stroke: .red, lineWidth: 4, fontSize: 28)
        document.annotations = [
            Annotation(kind: .rectangle,
                       frame: CGRect(x: 20, y: 20, width: 80, height: 60),
                       style: style, zIndex: 1),
            Annotation(kind: .arrow,
                       frame: CGRect(x: 120, y: 40, width: 120, height: 60),
                       style: style, zIndex: 2,
                       path: [CGPoint(x: 120, y: 40), CGPoint(x: 240, y: 100)]),
            Annotation(kind: .pen,
                       frame: CGRect(x: 30, y: 150, width: 120, height: 60),
                       style: style, zIndex: 3,
                       path: [CGPoint(x: 30, y: 150), CGPoint(x: 90, y: 210), CGPoint(x: 150, y: 150)]),
            Annotation(kind: .text,
                       frame: AnnotationText.frame(text: "1.",
                                                   fontSize: style.fontSize,
                                                   origin: CGPoint(x: 260, y: 200)),
                       style: style, zIndex: 4,
                       text: "1."),
        ]
        return document
    }

    /// ticket 08 明确要求的一条：文字与画笔的几何/样式"存-取-再渲染一致"。
    /// 光有 `Codable` 不够 —— 序列化漏掉 `path`、丢掉 `fontSize` 都编得过，只是渲染变了。
    @Test("存 → 取 → 再栅格化：文档相等，像素也相等")
    func roundTripKeepsRendering() throws {
        let document = makeDocument()
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        #expect(decoded == document, "取回来的文档必须与存进去的完全相等")

        let source = TestImage.solid(width: 400, height: 300, red: 1, green: 1, blue: 1)
        guard let before = AnnotationRasterizer.image(document: document, source: source),
              let after = AnnotationRasterizer.image(document: decoded, source: source) else {
            Issue.record("栅格化失败")
            return
        }
        #expect(before.width == after.width && before.height == after.height)
        #expect(BitmapReader.meanAbsoluteError(before, after) == 0,
                "同样的文档栅格化两次必须逐像素一致")
    }

    @Test("导出：四类标注都真的画上了（白底上留下对应位置的墨）")
    func rasterizerDrawsEveryKind() {
        let document = makeDocument()
        let source = TestImage.solid(width: 400, height: 300, red: 1, green: 1, blue: 1)
        guard let rendered = AnnotationRasterizer.image(document: document, source: source),
              let bitmap = BitmapReader.read(rendered) else {
            Issue.record("栅格化失败")
            return
        }

        func isInk(_ x: Int, _ y: Int) -> Bool {
            let pixel = bitmap.rgba(x: x, y: y)
            return Int(pixel.red) + Int(pixel.green) + Int(pixel.blue) < 600
        }

        #expect(isInk(20, 40), "矩形的左边应当有线（纵向中线附近）")
        #expect(isInk(240, 100), "箭头尖端附近应当有墨")
        #expect(isInk(90, 210), "画笔的最低点应当有墨")
        #expect(!isInk(200, 20), "空白处不该有墨")

        // 文字：在它的框里找一点墨
        let textFrame = document.annotations[3].frame
        var foundTextInk = false
        for y in Int(textFrame.minY)..<Int(textFrame.maxY) {
            for x in Int(textFrame.minX)..<Int(textFrame.maxX) where isInk(x, y) {
                foundTextInk = true
            }
        }
        #expect(foundTextInk, "文字区域里应当有墨：\(textFrame)")
    }

    /// 文字上下颠倒过一次（底图那个坑的同源）：字形的局部翻转写错方向，
    /// 文字就会镜像，而"有没有墨"这类断言完全看不出来。
    @Test("文字不镜像：'L' 的墨在左侧与底部，右上角是空的")
    func textIsNotMirrored() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 120, height: 120))
        let style = AnnotationStyle(stroke: .red, lineWidth: 2, fontSize: 80)
        document.annotations = [Annotation(kind: .text,
                                          frame: AnnotationText.frame(text: "L",
                                                                      fontSize: style.fontSize,
                                                                      origin: CGPoint(x: 20, y: 20)),
                                          style: style, zIndex: 1,
                                          text: "L")]
        let source = TestImage.solid(width: 120, height: 120, red: 1, green: 1, blue: 1)
        guard let rendered = AnnotationRasterizer.image(document: document, source: source),
              let bitmap = BitmapReader.read(rendered) else {
            Issue.record("栅格化失败")
            return
        }
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let pixel = bitmap.rgba(x: x, y: y)
            return Int(pixel.red) + Int(pixel.green) + Int(pixel.blue) < 600
        }

        // "L" 的竖笔在左、横笔在底：左侧中部与底部应当有墨
        var leftColumnInk = false
        for y in 40..<70 where isInk(26, y) { leftColumnInk = true }
        var bottomInk = false
        for x in 30..<60 where isInk(x, 88) { bottomInk = true }
        // 镜像（上下翻）后横笔会跑到顶部、竖笔仍在左 —— 这一条就是抓它的
        var topInk = false
        for x in 30..<60 where isInk(x, 30) { topInk = true }

        #expect(leftColumnInk, "L 的竖笔应当在左侧中部")
        #expect(bottomInk, "L 的横笔应当在底部")
        #expect(!topInk, "顶部不该有墨 —— 有的话说明文字被上下镜像了")
    }

    @Test("文字的测量：内容越长框越宽，高度只由字号决定")
    func textMeasurement() {
        let short = AnnotationText.measure("A", fontSize: 30)
        let long = AnnotationText.measure("AAAA", fontSize: 30)
        #expect(long.width > short.width)
        #expect(long.height == short.height)

        let big = AnnotationText.measure("A", fontSize: 60)
        #expect(big.height > short.height)
        #expect(big.width > short.width)

        let empty = AnnotationText.measure("", fontSize: 30)
        #expect(empty.width >= 1 && empty.height >= 1, "空文字也要有个能点中的框")
    }
}

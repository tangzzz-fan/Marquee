import CoreGraphics
import Foundation
import Testing
@testable import MarqueeCore

@Suite("标注对象与撤销")
struct AnnotationEditorTests {

    private let canvas = CGSize(width: 200, height: 120)

    private func annotation(_ kind: AnnotationKind,
                            _ frame: CGRect,
                            zIndex: Int,
                            id: UUID = UUID(),
                            lineWidth: CGFloat = 4) -> Annotation {
        Annotation(id: id,
                   kind: kind,
                   frame: frame,
                   style: AnnotationStyle(stroke: .red, lineWidth: lineWidth),
                   zIndex: zIndex)
    }

    @Test("叠在上面的对象先被点中；椭圆框角点不中")
    func hitTestingRespectsZOrderAndShape() {
        let back = annotation(.rectangle, CGRect(x: 0, y: 0, width: 100, height: 100), zIndex: 1, lineWidth: 1)
        let front = annotation(.ellipse, CGRect(x: 0, y: 0, width: 100, height: 100), zIndex: 2, lineWidth: 1)
        var document = AnnotationDocument(pixelSize: canvas, annotations: [back, front])

        let center = document.hitTest(CGPoint(x: 50, y: 50), selected: [], handleRadius: 4)
        #expect(center == .body(front.id))

        // 椭圆包围盒的角在椭圆外面，应当落到后面的矩形上。
        let corner = document.hitTest(CGPoint(x: 2, y: 2), selected: [], handleRadius: 4)
        #expect(corner == .body(back.id))

        // 层数更低但画得更晚的对象，在层数相同的另一个对象之上。
        let earlier = annotation(.rectangle, CGRect(x: 0, y: 0, width: 40, height: 40), zIndex: 5, lineWidth: 1)
        let later = annotation(.rectangle, CGRect(x: 0, y: 0, width: 40, height: 40), zIndex: 5, lineWidth: 1)
        document.annotations = [earlier, later]
        #expect(document.hitTest(CGPoint(x: 10, y: 10), selected: [], handleRadius: 4) == .body(later.id))
    }

    @Test("已选中对象的角点优先于对象本身")
    func handlesWinOverBodies() {
        let shape = annotation(.rectangle, CGRect(x: 10, y: 10, width: 40, height: 30), zIndex: 1, lineWidth: 1)
        let document = AnnotationDocument(pixelSize: canvas, annotations: [shape])
        let hit = document.hitTest(CGPoint(x: 10, y: 10), selected: [shape.id], handleRadius: 4)
        #expect(hit == .handle(shape.id, .topLeft))
    }

    @Test("画矩形、拖动、拖角、改色改线宽，撤销各退一步")
    func drawsMovesResizesAndRestyles() {
        var session = AnnotationEditorSession(pixelSize: canvas)
        session.tool = .rectangle
        session.pointerDown(at: CGPoint(x: 20, y: 30), shift: false, handleRadius: 4)
        session.pointerMoved(to: CGPoint(x: 120, y: 90))
        session.pointerUp()

        let drawn = session.document.annotations
        #expect(drawn.count == 1)
        #expect(drawn[0].kind == .rectangle)
        #expect(drawn[0].frame == CGRect(x: 20, y: 30, width: 100, height: 60))
        #expect(session.selection == [drawn[0].id])
        #expect(session.tool == .select)

        let id = drawn[0].id
        // 点在框内、离角点远，才是移动而不是拖角。
        session.pointerDown(at: CGPoint(x: 50, y: 50), shift: false, handleRadius: 4)
        session.pointerMoved(to: CGPoint(x: 70, y: 50))
        session.pointerUp()
        #expect(session.document.annotations[0].frame == CGRect(x: 40, y: 30, width: 100, height: 60))

        session.pointerDown(at: CGPoint(x: 140, y: 90), shift: false, handleRadius: 4)
        session.pointerMoved(to: CGPoint(x: 160, y: 110))
        session.pointerUp()
        #expect(session.document.annotations[0].frame == CGRect(x: 40, y: 30, width: 120, height: 80))

        let blue = AnnotationColor(red: 0, green: 0, blue: 1)
        session.setStrokeColor(blue)
        session.setLineWidth(8)
        #expect(session.document.annotations[0].style.stroke == blue)
        #expect(session.document.annotations[0].style.lineWidth == 8)

        session.undo()
        #expect(session.document.annotations[0].style.lineWidth == 4)
        session.undo()
        #expect(session.document.annotations[0].style.stroke == .red)
        session.undo()
        #expect(session.document.annotations[0].frame == CGRect(x: 40, y: 30, width: 100, height: 60))
        #expect(session.document.annotations[0].id == id)
    }

    @Test("按住 Shift 多选后一起移动、一起改色，Delete 一起删除")
    func shiftSelectsBatchEdits() {
        var session = AnnotationEditorSession(pixelSize: canvas)
        func addRect(at origin: CGPoint) {
            session.tool = .rectangle
            session.pointerDown(at: origin, shift: false, handleRadius: 4)
            session.pointerMoved(to: CGPoint(x: origin.x + 20, y: origin.y + 20))
            session.pointerUp()
        }
        addRect(at: CGPoint(x: 10, y: 10))
        addRect(at: CGPoint(x: 50, y: 10))
        let first = session.document.annotations[0]
        let second = session.document.annotations[1]

        session.pointerDown(at: CGPoint(x: 15, y: 15), shift: false, handleRadius: 4)
        session.pointerUp()
        session.pointerDown(at: CGPoint(x: 55, y: 15), shift: true, handleRadius: 4)
        session.pointerUp()
        #expect(session.selection == [first.id, second.id])

        session.pointerDown(at: CGPoint(x: 15, y: 15), shift: false, handleRadius: 4)
        session.pointerMoved(to: CGPoint(x: 25, y: 15))
        session.pointerUp()
        #expect(session.document.annotations[0].frame.origin == CGPoint(x: 20, y: 10))
        #expect(session.document.annotations[1].frame.origin == CGPoint(x: 60, y: 10))

        session.setStrokeColor(AnnotationColor(red: 0, green: 1, blue: 0))
        #expect(session.document.annotations.allSatisfy { $0.style.stroke.green == 1 })

        session.deleteSelection()
        #expect(session.document.annotations.isEmpty)
        session.undo()
        #expect(session.document.annotations.count == 2)
        #expect(session.document.annotations[0].id == first.id)
        #expect(session.document.annotations[1].id == second.id)
    }

    @Test("标注、裁切、再标注可以逐级撤销和重做")
    func interleavedCropUndo() {
        var session = AnnotationEditorSession(pixelSize: canvas)
        session.tool = .rectangle
        session.pointerDown(at: CGPoint(x: 10, y: 10), shift: false, handleRadius: 4)
        session.pointerMoved(to: CGPoint(x: 30, y: 30))
        session.pointerUp()
        let first = session.document.annotations[0].id

        let crop = CGRect(x: 8, y: 8, width: 40, height: 40)
        session.applyCrop(crop)

        session.tool = .ellipse
        session.pointerDown(at: CGPoint(x: 12, y: 12), shift: false, handleRadius: 4)
        session.pointerMoved(to: CGPoint(x: 28, y: 36))
        session.pointerUp()
        #expect(session.document.annotations.count == 2)
        #expect(session.document.annotations[1].kind == .ellipse)

        session.undo()
        #expect(session.document.annotations.map(\.id) == [first])
        #expect(session.document.cropRect == crop)

        session.undo()
        #expect(session.document.cropRect == CGRect(origin: .zero, size: canvas))
        #expect(session.document.annotations.map(\.id) == [first])

        session.undo()
        #expect(session.document.annotations.isEmpty)

        session.redo()
        session.redo()
        session.redo()
        #expect(session.document.annotations.count == 2)
        #expect(session.document.cropRect == crop)
        #expect(session.canRedo == false)
    }

    @Test("导出尺寸等于裁切区，描边画进图里，裁切外的像素不在")
    func exportMatchesCropAndPaintsStroke() {
        let source = TestImage.solid(width: 20, height: 16, red: 1, green: 0, blue: 0)
        var document = AnnotationDocument(pixelSize: CGSize(width: 20, height: 16),
                                          cropRect: CGRect(x: 2, y: 4, width: 10, height: 8))
        var shape = annotation(.rectangle,
                               CGRect(x: 4, y: 6, width: 6, height: 4),
                               zIndex: 1,
                               lineWidth: 2)
        shape.style.stroke = AnnotationColor(red: 1, green: 1, blue: 1)
        document.annotations = [shape]
        let exported = AnnotationRasterizer.image(document: document, source: source)
        #expect(exported?.width == 10)
        #expect(exported?.height == 8)

        let background = TestImage.pixel(exported!, x: 0, y: 0)
        #expect(background.red > 200)
        #expect(background.green < 40)

        // 顶边中点：图像 (7, 6) = 裁切区内 (5, 2)。线宽 2，描边中心就在这条边上。
        let stroke = TestImage.pixel(exported!, x: 5, y: 2)
        #expect(stroke.red > 200)
        #expect(stroke.green > 200)
        #expect(stroke.blue > 200)
    }

    @Test("导出时底图不许上下颠倒 —— 用上下不同的底图抓翻转")
    func exportKeepsImageOrientation() {
        // 纯色底图看不出翻转：这正是底图颠倒 bug 潜伏下来的原因，所以这里必须用上下不同的图
        let source = TestImage.topBlackBottomWhite(width: 24, height: 16)
        let document = AnnotationDocument(pixelSize: CGSize(width: 24, height: 16))

        guard let exported = AnnotationRasterizer.image(document: document, source: source) else {
            Issue.record("导出失败")
            return
        }
        #expect(exported.width == 24)
        #expect(exported.height == 16)

        let top = TestImage.pixel(exported, x: 12, y: 1)
        #expect(top.red < 40, "顶部应当是黑的；读到 \(top) 说明底图被上下颠倒了")
        let bottom = TestImage.pixel(exported, x: 12, y: 14)
        #expect(bottom.red > 200, "底部应当是白的；读到 \(bottom) 说明底图被上下颠倒了")

        // 裁切后的方向也要对：只取下半（白），且裁切原点不能错位
        let cropped = AnnotationDocument(pixelSize: CGSize(width: 24, height: 16),
                                         cropRect: CGRect(x: 0, y: 8, width: 24, height: 8))
        guard let croppedExport = AnnotationRasterizer.image(document: cropped, source: source) else {
            Issue.record("裁切导出失败")
            return
        }
        #expect(croppedExport.height == 8)
        for y in [0, 3, 7] {
            #expect(TestImage.pixel(croppedExport, x: 12, y: y).red > 200,
                    "裁到下半应当整段是白的，第 \(y) 行不是")
        }
    }

    @Test("100 个标注的导出低于 4 毫秒")
    func rasterizesOneHundredWithinBudget() {
        var annotations: [Annotation] = []
        for index in 0..<100 {
            let origin = CGFloat(index % 20) * 18
            annotations.append(annotation(index.isMultiple(of: 2) ? .rectangle : .ellipse,
                                          CGRect(x: origin, y: CGFloat(index % 10) * 24, width: 28, height: 18),
                                          zIndex: index,
                                          lineWidth: 2))
        }
        let document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300), annotations: annotations)
        let source = TestImage.solid(width: 400, height: 300, red: 0.1, green: 0.1, blue: 0.1)
        _ = AnnotationRasterizer.image(document: document, source: source)

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = ContinuousClock.now
            _ = AnnotationRasterizer.image(document: document, source: source)
            let elapsed = start.duration(to: .now)
            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            best = min(best, milliseconds)
        }
        #expect(best < 4, "100 个标注导出最快一帧 \(best) ms，预算 4 ms")
    }

    @Test("缩放锚点下的图像像素不动，平移只改偏移")
    func viewportZoomKeepsAnchor() {
        var viewport = CanvasViewport(scale: 1, pan: CGPoint(x: 12, y: 8))
        let anchor = CGPoint(x: 40, y: 50)
        let before = viewport.imagePoint(forView: anchor, cropOrigin: .zero)
        viewport.zoom(by: 2, around: anchor)
        let after = viewport.imagePoint(forView: anchor, cropOrigin: .zero)
        #expect(abs(before.x - after.x) < 0.001)
        #expect(abs(before.y - after.y) < 0.001)
        #expect(abs(viewport.scale - 2) < 0.001)

        viewport.pan(by: CGPoint(x: 5, y: -3))
        let panned = viewport.imagePoint(forView: anchor, cropOrigin: .zero)
        #expect(abs(panned.x - (after.x - 5 / 2)) < 0.001)
        #expect(abs(panned.y - (after.y + 3 / 2)) < 0.001)
    }
}

import CoreGraphics
import Foundation
import MarqueeTestSupport
import Testing
@testable import MarqueeCore

/// 打码（马赛克 / 毛玻璃）。
///
/// 「打码生效了没有」这件事不能靠肉眼看断言，所以这里用两个可量化的指标：
/// - **马赛克**：相邻像素"变脸"的次数应当断崖式下降（1 像素细节被并成大块）
/// - **模糊**：相邻像素的**平均差异**应当明显变小（对比度被抹平）
@Suite("打码：马赛克与毛玻璃")
struct RedactionFilterTests {

    private func detailImage() -> CGImage {
        // 1 像素棋盘：细节量最大，最适合量"被打掉多少"
        TestImage.checkerboard(width: 64, height: 64)
    }

    /// 中间一行里相邻像素不同的次数（细节量的直接度量）
    private func horizontalTransitions(_ image: CGImage, y: Int) -> Int {
        var count = 0
        for x in 0..<(image.width - 1) {
            let a = TestImage.pixel(image, x: x, y: y)
            let b = TestImage.pixel(image, x: x + 1, y: y)
            if a.red != b.red || a.green != b.green || a.blue != b.blue { count += 1 }
        }
        return count
    }

    /// 中间一行相邻像素的平均差异（对比度的直接度量）
    private func meanHorizontalDelta(_ image: CGImage, y: Int) -> Double {
        var total = 0
        for x in 0..<(image.width - 1) {
            let a = TestImage.pixel(image, x: x, y: y)
            let b = TestImage.pixel(image, x: x + 1, y: y)
            total += abs(Int(a.red) - Int(b.red)) + abs(Int(a.green) - Int(b.green)) + abs(Int(a.blue) - Int(b.blue))
        }
        return Double(total) / Double(image.width - 1)
    }

    @Test("马赛克：细节被并成大块，相邻像素变脸次数断崖式下降")
    func mosaicPixelates() throws {
        let source = detailImage()
        let before = horizontalTransitions(source, y: 32)
        guard let mosaic = RedactionFilter.apply(.mosaic, to: source, strength: 8) else {
            Issue.record("马赛克失败")
            return
        }
        let after = horizontalTransitions(mosaic, y: 32)

        #expect(mosaic.width == source.width && mosaic.height == source.height, "尺寸必须不变")
        #expect(before > 50, "源图本身要够细，否则这条测不出东西（实际 \(before)）")
        #expect(after <= 12, "8 像素一块时每行最多变脸 8 次左右，实际 \(after)")
    }

    /// ⚠️ 度量图案必须与块长大致同量级。
    ///
    /// 1 像素棋盘在 8 像素块里就被平均成**纯灰**了，8 与 32 档看起来一模一样 ——
    /// 用那种源图测"强度越大越糊"会得到 0 == 0，什么都测不出来。
    /// 所以这里用 16 像素的方块：8 档还留得住结构，32 档才被抹掉。
    @Test("强度越大，块越大（细节越少）")
    func strongerMosaicMeansFewerTransitions() throws {
        let source = TestImage.checkerboard(width: 64, height: 64, squareSize: 16)
        guard let fine = RedactionFilter.apply(.mosaic, to: source, strength: 8),
              let coarse = RedactionFilter.apply(.mosaic, to: source, strength: 32) else {
            Issue.record("马赛克失败")
            return
        }
        let fineTransitions = horizontalTransitions(fine, y: 32)
        let coarseTransitions = horizontalTransitions(coarse, y: 32)
        #expect(coarseTransitions < fineTransitions,
                "32 块应当比 8 块更糊（\(coarseTransitions) vs \(fineTransitions)）")
    }

    @Test("毛玻璃：对比度被抹平")
    func blurReducesContrast() throws {
        let source = detailImage()
        let before = meanHorizontalDelta(source, y: 32)
        guard let blurred = RedactionFilter.apply(.blur, to: source, strength: 12) else {
            Issue.record("模糊失败")
            return
        }
        let after = meanHorizontalDelta(blurred, y: 32)

        #expect(blurred.width == source.width && blurred.height == source.height)
        #expect(before > 200, "源图对比度要够高（实际 \(before)）")
        #expect(after < before / 2, "模糊后相邻差异应当明显变小（\(after) vs \(before)）")
    }

    @Test("强度被夹在合理范围内：0 或天文数字都不会把打码弄失效")
    func strengthIsClamped() {
        #expect(RedactionFilter.clampStrength(0, for: .mosaic) == RedactionFilter.mosaicRange.lowerBound)
        #expect(RedactionFilter.clampStrength(1e9, for: .mosaic) == RedactionFilter.mosaicRange.upperBound)
        #expect(RedactionFilter.clampStrength(-5, for: .blur) == RedactionFilter.blurRange.lowerBound)
        #expect(RedactionFilter.clampStrength(.nan, for: .blur) == RedactionFilter.blurRange.lowerBound)
        // 非打码类型原样返回，不参与夹取
        #expect(RedactionFilter.clampStrength(7, for: .rectangle) == 7)
    }

    @Test("不支持的标注类型返回 nil，而不是给一张没处理的图")
    func nonRedactionKindsReturnNil() {
        let source = detailImage()
        #expect(RedactionFilter.apply(.rectangle, to: source, strength: 8) == nil)
        #expect(RedactionFilter.apply(.text, to: source, strength: 8) == nil)
    }

    /// 单次打码的实测耗时。ticket 09 的目标是 ≤ 5 ms（全画布 2.64 ms 是 CoreImage 的水平），
    /// 这里对一个真实大小的补丁量一次并打印 —— 测试只卡一个宽松上限，避免 CI 上偶发抖动。
    @Test("单次打码耗时实测")
    func redactionTiming() throws {
        let patch = TestImage.checkerboard(width: 400, height: 300)
        // 预热：第一次调用要建 CIContext 并编译着色器（实测冷启动 46 ms，稳定后是个位数），
        // 不预热等于在量初始化开销，不是量打码本身。
        _ = RedactionFilter.apply(.mosaic, to: patch, strength: 12)
        _ = RedactionFilter.apply(.blur, to: patch, strength: 12)

        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000
                + Double(duration.components.attoseconds) / 1e15
        }

        /// 取**多次里最快的一次**，而不是随便抽一次。
        ///
        /// ⚠️ 这条用例曾因为"跑测试的同时还在编译别的东西"而偶发变红（实测抖动到 >50 ms，
        /// 而单独跑是 0.2 ms）。墙钟断言在别人机器上忙的时候一定会红，
        /// 而"红了一次又自己变绿"会让人开始不信任整个测试套件 —— 那比少一条用例糟得多。
        /// 取最小值是微基准的通行做法：最小值里没有"被打断"的成分。
        func fastest(_ body: () -> Void, rounds: Int = 5) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<rounds {
                let clock = ContinuousClock()
                best = min(best, milliseconds(clock.measure(body)))
            }
            return best
        }

        let mosaicMS = fastest { _ = RedactionFilter.apply(.mosaic, to: patch, strength: 12) }
        let blurMS = fastest { _ = RedactionFilter.apply(.blur, to: patch, strength: 12) }
        print("打码实测（400×300，取 5 次最快）：马赛克 \(String(format: "%.2f", mosaicMS)) ms，模糊 \(String(format: "%.2f", blurMS)) ms")

        #expect(mosaicMS < 50, "马赛克单次最快耗时 \(mosaicMS) ms")
        #expect(blurMS < 50, "模糊单次最快耗时 \(blurMS) ms")
    }
}

@Suite("打码与裁切在编辑器里的行为")
struct RedactionEditorTests {

    private func makeSession() -> AnnotationEditorSession {
        AnnotationEditorSession(pixelSize: CGSize(width: 200, height: 150))
    }

    private func drag(_ session: inout AnnotationEditorSession, from: CGPoint, to: CGPoint) {
        session.pointerDown(at: from, shift: false, handleRadius: 6)
        session.pointerMoved(to: to)
        session.pointerUp()
    }

    // MARK: - 打码对象

    @Test("拖出一个打码框，工具留在原地（要连着涂好几块）")
    func createsRedactionAndStaysOnTool() {
        for tool in [AnnotationEditorTool.mosaic, .blur] {
            var session = makeSession()
            session.tool = tool
            drag(&session, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 90))

            #expect(session.document.annotations.count == 1)
            let annotation = session.document.annotations[0]
            #expect(annotation.kind == tool.annotationKind)
            #expect(annotation.frame == CGRect(x: 20, y: 20, width: 100, height: 70))
            #expect(session.tool == tool, "打码工具不该跳回选择")

            // 再涂一块
            drag(&session, from: CGPoint(x: 30, y: 100), to: CGPoint(x: 80, y: 130))
            #expect(session.document.annotations.count == 2)
        }
    }

    @Test("太小的打码框不算数（手抖不该留下一个没盖住的洞）")
    func ignoresTinyRedaction() {
        var session = makeSession()
        session.tool = .mosaic
        drag(&session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11))
        #expect(session.document.annotations.isEmpty)
    }

    @Test("打码对象可被选中、移动、删除")
    func redactionIsSelectableMovableDeletable() {
        var session = makeSession()
        session.tool = .mosaic
        drag(&session, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 90))
        session.tool = .select

        // 框内任意一点都点得中（它是"区域"，不是"描边"）
        session.pointerDown(at: CGPoint(x: 70, y: 55), shift: false, handleRadius: 6)
        #expect(session.selection.count == 1)
        session.pointerMoved(to: CGPoint(x: 90, y: 75))
        session.pointerUp()
        #expect(session.document.annotations[0].frame.origin == CGPoint(x: 40, y: 40))

        session.deleteSelection()
        #expect(session.document.annotations.isEmpty)
        session.undo()
        #expect(session.document.annotations.count == 1, "删除可撤销")
    }

    @Test("可调强度，且可撤销；对非打码对象没有副作用")
    func strengthIsAdjustableAndScoped() {
        var session = makeSession()
        session.tool = .rectangle
        drag(&session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        session.tool = .mosaic
        drag(&session, from: CGPoint(x: 80, y: 10), to: CGPoint(x: 180, y: 60))

        // 选中矩形时改强度：不该碰任何东西
        session.tool = .select
        session.selection = [session.document.annotations[0].id]
        session.setEffectStrength(32)
        #expect(session.document.annotations[0].kind == .rectangle)

        // 选中打码时改强度：生效
        let mosaicID = session.document.annotations[1].id
        session.selection = [mosaicID]
        session.setEffectStrength(32)
        #expect(session.document.annotations[1].style.effectStrength == 32)

        session.undo()
        #expect(session.document.annotations[1].style.effectStrength == AnnotationStyle.default.effectStrength,
                "改强度应当可撤销")
    }

    @Test("强度被夹在范围内，避免一键把马赛克调成「什么都没打」")
    func strengthIsClampedInSession() {
        var session = makeSession()
        session.tool = .blur
        drag(&session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 80))
        session.tool = .select
        session.selection = [session.document.annotations[0].id]

        session.setEffectStrength(0)
        #expect(session.document.annotations[0].style.effectStrength == RedactionFilter.blurRange.lowerBound)
    }

    // MARK: - 裁切模式

    @Test("进入裁切模式后拖角：夹在图像范围内，不会拖出图外")
    func cropDraftStaysInsideImage() {
        var session = makeSession()
        session.beginCrop()
        #expect(session.isCropping)
        #expect(session.cropDraft == session.document.cropRect, "初始框就是当前裁切区")

        session.updateCrop(handle: .bottomRight, to: CGPoint(x: 999, y: 999))
        #expect(session.cropDraft == CGRect(x: 0, y: 0, width: 200, height: 150), "不该超出图像")

        session.updateCrop(handle: .topLeft, to: CGPoint(x: -50, y: -50))
        let draft = try? #require(session.cropDraft)
        #expect(draft?.minX == 0 && draft?.minY == 0)
    }

    @Test("整体平移裁切框同样被夹住")
    func cropDraftCanBeMoved() {
        var session = makeSession()
        session.beginCrop()
        session.updateCrop(handle: .bottomRight, to: CGPoint(x: 100, y: 100))

        session.moveCrop(by: CGPoint(x: 500, y: 0))
        let draft = try? #require(session.cropDraft)
        #expect(draft?.maxX == 200, "右边界顶到头（实际 \(String(describing: draft))）")
        #expect(draft?.width == 100, "尺寸不该变")
    }

    @Test("回车应用：画布尺寸随之改变，且可撤销回完整原图")
    func commitCropAppliesAndUndoes() {
        var session = makeSession()
        session.beginCrop()
        session.updateCrop(handle: .bottomRight, to: CGPoint(x: 100, y: 80))
        // `#expect` 的宏展开里不能调 mutating 方法（MEMORY 陷阱 12），先落到局部变量
        let applied = session.commitCrop()
        #expect(applied)
        #expect(session.isCropping == false)
        #expect(session.document.canvasPixelSize == CGSize(width: 100, height: 80))

        session.undo()
        #expect(session.document.canvasPixelSize == CGSize(width: 200, height: 150))
    }

    @Test("Esc 取消：不产生任何撤销记录")
    func cancelCropDiscards() {
        var session = makeSession()
        session.beginCrop()
        session.updateCrop(handle: .bottomRight, to: CGPoint(x: 60, y: 60))
        session.cancelCrop()

        #expect(session.isCropping == false)
        #expect(session.document.cropRect == CGRect(x: 0, y: 0, width: 200, height: 150))
        #expect(session.canUndo == false, "拖框期间不该进撤销栈")
    }

    @Test("框太小不应用（免得把图裁成一条缝），且留在裁切模式让用户继续调")
    func tinyCropIsRejected() {
        var session = makeSession()
        session.beginCrop()
        session.updateCrop(handle: .bottomRight, to: CGPoint(x: 3, y: 3))
        let applied = session.commitCrop()
        #expect(applied == false)
        #expect(session.isCropping, "还应当在裁切模式里")
        #expect(session.document.canvasPixelSize == CGSize(width: 200, height: 150))
    }

    /// 「裁切边界外的标注如何处理」：**保留不动**，只是暂时看不到。
    ///
    /// 不做删除的理由：撤销裁切要能完整恢复 —— 删掉再补回来是"两处状态要对齐"，
    /// 而保留原件只有一处状态（`cropRect`），撤销天然正确。
    @Test("裁切外的标注被保留，重新导出时又回来")
    func annotationsOutsideCropSurvive() {
        var session = makeSession()
        session.tool = .rectangle
        drag(&session, from: CGPoint(x: 120, y: 100), to: CGPoint(x: 180, y: 140))
        let original = session.document.annotations[0]

        session.applyCrop(CGRect(x: 0, y: 0, width: 100, height: 80))
        #expect(session.document.annotations.count == 1, "标注不该被删掉")
        #expect(session.document.annotations[0] == original, "位置也不该被改动")

        let source = TestImage.solid(width: 200, height: 150, red: 1, green: 1, blue: 1)
        let cropped = AnnotationRasterizer.image(document: session.document, source: source)
        #expect(cropped?.width == 100 && cropped?.height == 80, "画布尺寸跟着裁切")
        if let cropped {
            var hasInk = false
            for y in 0..<cropped.height {
                for x in 0..<cropped.width {
                    let pixel = TestImage.pixel(cropped, x: x, y: y)
                    if Int(pixel.red) + Int(pixel.green) + Int(pixel.blue) < 600 { hasInk = true }
                }
            }
            #expect(!hasInk, "裁掉的区域里不该还有标注的墨")
        }

        session.undo()
        let restored = AnnotationRasterizer.image(document: session.document, source: source)
        #expect(restored?.width == 200 && restored?.height == 150)
        // 采样点要落在**描边**上：矩形只描边不填充，取框内一点只会读到背景
        let inked = TestImage.pixel(try! #require(restored), x: 120, y: 120)
        #expect(inked.red > 200 && inked.green < 120, "撤销裁切后标注应当回到原位（实际 \(inked)）")
    }

    @Test("标注 → 裁切 → 打码 → 撤销三次：语义逐级正确")
    func interleavedUndoWithRedaction() {
        var session = makeSession()
        session.tool = .rectangle
        drag(&session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 50))
        session.beginCrop()
        session.updateCrop(handle: .bottomRight, to: CGPoint(x: 150, y: 120))
        let applied = session.commitCrop()
        #expect(applied)
        session.tool = .mosaic
        drag(&session, from: CGPoint(x: 70, y: 60), to: CGPoint(x: 120, y: 100))

        #expect(session.document.annotations.count == 2)
        #expect(session.document.canvasPixelSize == CGSize(width: 150, height: 120))

        session.undo()   // 撤销打码
        #expect(session.document.annotations.count == 1)
        #expect(session.document.canvasPixelSize == CGSize(width: 150, height: 120), "裁切还在")

        session.undo()   // 撤销裁切
        #expect(session.document.canvasPixelSize == CGSize(width: 200, height: 150))
        #expect(session.document.annotations.count == 1, "裁切前画的矩形还在")

        session.undo()   // 撤销矩形
        #expect(session.document.annotations.isEmpty)

        session.redo()
        session.redo()
        #expect(session.document.canvasPixelSize == CGSize(width: 150, height: 120))
        #expect(session.document.annotations.count == 1)
    }
}

@Suite("打码的导出渲染")
struct RedactionRasterizerTests {

    /// ⚠️ 这两条盯的是"在已经翻转的 CTM 里画补丁会上下颠倒"。
    ///
    /// 打码必须把源图的一小块抠出来做滤镜再贴回去，而贴回去时当前 CTM 已经是
    /// "左上原点、y 向下" —— `draw(image, in:)` 在那种上下文里会把图**上下颠倒**。
    ///
    /// 底图必须**不对称**：一开始用"上黑下白各一半"，那种图关于水平中线镜像对称，
    /// 翻转后逐像素相同 —— 变异测试（去掉反向翻转）**没抓住**，才发现测试图选错了。
    /// 现在用"顶部一条黑带、其余全白"。
    private func flippedPatchWouldBeVisible(kind: AnnotationKind, strength: CGFloat) throws {
        let source = TestImage.topBandBlack(width: 64, height: 48, bandHeight: 16)
        let document = AnnotationDocument(
            pixelSize: CGSize(width: 64, height: 48),
            annotations: [Annotation(kind: kind,
                                     frame: CGRect(x: 0, y: 0, width: 64, height: 48),
                                     style: AnnotationStyle(stroke: .red, lineWidth: 1, effectStrength: strength),
                                     zIndex: 1)]
        )
        guard let rendered = AnnotationRasterizer.image(document: document, source: source) else {
            Issue.record("栅格化失败")
            return
        }
        // 黑带在顶部 16 行里，取它的中部（8）与下半部（40）比较 —— 与模糊半径无关
        let inBand = TestImage.pixel(rendered, x: 32, y: 8).red
        let below = TestImage.pixel(rendered, x: 32, y: 40).red
        #expect(Int(inBand) + 80 < Int(below),
                "\(kind) 应当上暗下亮（带内=\(inBand) 下方=\(below)）—— 反了说明补丁被上下颠倒")
    }

    @Test("马赛克补丁不会画颠倒")
    func mosaicDoesNotFlipThePatch() throws {
        try flippedPatchWouldBeVisible(kind: .mosaic, strength: 16)
    }

    @Test("模糊补丁不会画颠倒")
    func blurDoesNotFlipThePatch() throws {
        try flippedPatchWouldBeVisible(kind: .blur, strength: 8)
    }

    /// 马赛克与模糊必须是**两种不同的效果**。
    ///
    /// 只测"细节变少了"是不够的：两种滤镜都能让细节变少，把实现互换也照样通过
    /// （变异测试验证过，第一次就是这么漏的）。试过"块内相邻像素完全相等"这个度量也不行 ——
    /// 大色块模糊后中间会出现**饱和平台**，同样成片相等。
    ///
    /// 真正稳定的差别是**边缘的形状**：
    /// - 马赛克是**台阶**（块内恒定、块界处整段跳过去）
    /// - 模糊是**斜坡**（处处都有一点点差）
    ///
    /// 所以量"相邻像素跳变的最大幅度"：马赛克能跳到接近满量程，模糊被摊薄到几十。
    @Test("马赛克与模糊是两种不同的效果，不是同一个滤镜换个名字")
    func mosaicAndBlurDifferStructurally() throws {
        // 16 像素方块：与块长同量级，马赛克还能保住"台阶"，模糊一定抹成斜坡
        let source = TestImage.checkerboard(width: 64, height: 64, squareSize: 16)

        func maxNeighbourDelta(_ image: CGImage) -> Int {
            var maximum = 0
            for y in 0..<image.height {
                for x in 0..<(image.width - 1) {
                    let a = TestImage.pixel(image, x: x, y: y)
                    let b = TestImage.pixel(image, x: x + 1, y: y)
                    let delta = abs(Int(a.red) - Int(b.red))
                        + abs(Int(a.green) - Int(b.green))
                        + abs(Int(a.blue) - Int(b.blue))
                    maximum = max(maximum, delta)
                }
            }
            return maximum
        }

        guard let mosaic = RedactionFilter.apply(.mosaic, to: source, strength: 16),
              let blur = RedactionFilter.apply(.blur, to: source, strength: 16) else {
            Issue.record("滤镜失败")
            return
        }
        let mosaicDelta = maxNeighbourDelta(mosaic)
        let blurDelta = maxNeighbourDelta(blur)
        #expect(mosaicDelta > 150, "马赛克应当留下明显台阶（实测最大跳变 \(mosaicDelta)）")
        #expect(blurDelta < 80, "模糊应当是斜坡，单像素跳变不会很大（实测 \(blurDelta)）")
        #expect(mosaicDelta > blurDelta * 2, "两者必须能区分开（\(mosaicDelta) vs \(blurDelta)）")
    }

    @Test("马赛克真的作用到了导出图上（不是只有预览生效）")
    func mosaicAffectsExport() throws {
        let source = TestImage.checkerboard(width: 64, height: 64)
        let document = AnnotationDocument(
            pixelSize: CGSize(width: 64, height: 64),
            annotations: [Annotation(kind: .mosaic,
                                     frame: CGRect(x: 16, y: 16, width: 32, height: 32),
                                     style: AnnotationStyle(stroke: .red, lineWidth: 1, effectStrength: 16),
                                     zIndex: 1)]
        )
        guard let rendered = AnnotationRasterizer.image(document: document, source: source) else {
            Issue.record("栅格化失败")
            return
        }

        func transitions(_ y: Int, from: Int, to: Int) -> Int {
            var count = 0
            for x in from..<to {
                let a = TestImage.pixel(rendered, x: x, y: y)
                let b = TestImage.pixel(rendered, x: x + 1, y: y)
                if a.red != b.red { count += 1 }
            }
            return count
        }
        // 打码区之外仍是 1 像素棋盘，之内应当明显变少
        #expect(transitions(32, from: 0, to: 15) > 8, "框外的细节不该被抹掉")
        #expect(transitions(32, from: 16, to: 47) <= 4, "框内应当已经被像素化")
    }

    @Test("打码对象可被移动与撤销，位置随框走")
    func redactionFollowsItsFrame() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100))
        document.annotations = [Annotation(kind: .mosaic,
                                          frame: CGRect(x: 10, y: 10, width: 30, height: 30),
                                          zIndex: 1)]
        let moved = document.annotations[0].translated(by: CGPoint(x: 20, y: 5))
        #expect(moved.frame == CGRect(x: 30, y: 15, width: 30, height: 30))
    }
}

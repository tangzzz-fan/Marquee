import CoreGraphics
import Foundation
import MarqueeCore
import Testing

/// 文字识别（ticket 13）。
///
/// 这里测的是**编排**：结果怎么拼、空结果与失败怎么说、预热有没有真的跑且只跑一次。
/// 真正的 Vision 调用与「首次 25 秒」只能靠人眼在应用里验，但
/// 「预热逻辑有没有接线」是可以在脱机环境下钉死的 —— 恰恰是它最容易漏。
@MainActor
@Suite("文字识别")
struct TextRecognitionTests {

    // MARK: - 结果模型

    @Test("整段文本按行拼接：保留断行，不粘成一坨")
    func fullTextKeepsLineBreaks() {
        let result = TextRecognitionResult(lines: [
            line("第一行"),
            line("second line"),
            line("第三行"),
        ])

        #expect(result.fullText == "第一行\nsecond line\n第三行")
        #expect(result.characterCount == 3 + 11 + 3, "第一行 / second line / 第三行")
        #expect(!result.isEmpty)
    }

    @Test("空结果：isEmpty 为真，整段文本为空串")
    func emptyResult() {
        let result = TextRecognitionResult(lines: [])

        #expect(result.fullText.isEmpty)
        #expect(result.isEmpty)
        #expect(result.characterCount == 0)
    }

    @Test("Vision 的包围盒要翻成「像素 + 原点左上」—— 翻错了不报错也看不见")
    func convertsVisionBoundingBox() {
        // Vision：归一化、原点**左下**。取一个「靠上、靠左」的框：y 从 0.5 到 0.75
        let box = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.25)

        let frame = RecognizedTextLine.frame(fromNormalized: box,
                                             imageSize: CGSize(width: 400, height: 200))

        #expect(frame.minX == 0)
        #expect(frame.width == 200)
        #expect(frame.height == 50)
        // 左下原点的 0.5...0.75 是"上半部分"，换到左上原点应当是 50...100
        #expect(frame.minY == 50)
        #expect(frame.maxY == 100)
    }

    // MARK: - 服务

    @Test("识别成功：状态带上行数与耗时，提示里说清楚识别到多少")
    func reportsSuccess() async {
        let service = makeService(FakeTextRecognizer(lines: [line("你好"), line("world")]))

        await service.recognize(blank)

        guard case .ready(let result) = service.state else {
            Issue.record("期望 ready，实际 \(service.state)")
            return
        }
        #expect(result.lines.count == 2)
        #expect(result.elapsedMilliseconds > 0, "耗时是预热有没有生效的证据，必须记下来")
        #expect(service.message?.contains("2 行") == true)
    }

    @Test("识别用的语言是中英双语 —— 只给英文会把中文整段漏掉")
    func requestsChineseAndEnglish() async {
        let recognizer = FakeTextRecognizer(lines: [line("x")])
        let service = makeService(recognizer)

        await service.recognize(blank)

        #expect(recognizer.seenLanguages.contains("zh-Hans"))
        #expect(recognizer.seenLanguages.contains("en-US"))
    }

    @Test("图里没有文字：单独一档 + 说人话，不留白")
    func reportsEmptyExplicitly() async {
        let service = makeService(FakeTextRecognizer(lines: []))

        await service.recognize(blank)

        #expect(service.state == .empty)
        #expect(service.message?.contains("没有") == true, "留白会让人以为是坏了")
    }

    @Test("识别失败：把原因交出来，而不是沉默")
    func reportsFailure() async {
        let recognizer = FakeTextRecognizer(lines: [])
        recognizer.failure = StubCaptureError(message: "模型没加载起来")
        let service = makeService(recognizer)

        await service.recognize(blank)

        guard case .failed(let reason) = service.state else {
            Issue.record("期望 failed，实际 \(service.state)")
            return
        }
        #expect(reason.contains("模型没加载起来"))
        #expect(service.message?.contains("失败") == true)
    }

    @Test("识别中：状态是 running，界面据此禁掉按钮并给等待反馈")
    func reportsRunning() async {
        let recognizer = FakeTextRecognizer(lines: [line("x")])
        recognizer.delay = .milliseconds(150)
        let service = makeService(recognizer)

        #expect(service.state == .idle)
        #expect(service.message == nil)

        let task = Task { await service.recognize(blank) }
        try? await Task.sleep(for: .milliseconds(40))

        #expect(service.state == .running)
        #expect(service.message?.contains("识别") == true)

        await task.value
        #expect(service.state != .running)
    }

    @Test("重置：回到 idle，可以重新识别同一张图")
    func resetClearsState() async {
        let service = makeService(FakeTextRecognizer(lines: [line("x")]))
        await service.recognize(blank)
        #expect(service.state != .idle)

        service.reset()

        #expect(service.state == .idle)
        #expect(service.message == nil)
    }

    // MARK: - 预热

    @Test("预热真的调用了识别器 —— 否则等于没热")
    func preheats() async {
        let recognizer = FakeTextRecognizer(lines: [])
        let preheater = TextRecognitionPreheater(recognizer: recognizer)

        preheater.startIfNeeded()
        await preheater.waitUntilFinished()

        #expect(recognizer.callCount == 1)
        #expect(preheater.state == .ready)
    }

    @Test("预热是幂等的：重复启动只真的跑一次（否则每次截图都会重新热一遍）")
    func preheatRunsOnce() async {
        let recognizer = FakeTextRecognizer(lines: [])
        let preheater = TextRecognitionPreheater(recognizer: recognizer)

        preheater.startIfNeeded()
        preheater.startIfNeeded()
        await preheater.waitUntilFinished()
        preheater.startIfNeeded()
        await preheater.waitUntilFinished()

        #expect(recognizer.callCount == 1)
    }

    @Test("预热失败不影响主流程：状态记下来，用户点识别时仍然独立走一遍")
    func preheatFailureIsNotFatal() async {
        let recognizer = FakeTextRecognizer(lines: [])
        recognizer.failure = StubCaptureError(message: "预热时模型没起来")
        let preheater = TextRecognitionPreheater(recognizer: recognizer)

        preheater.startIfNeeded()
        await preheater.waitUntilFinished()

        guard case .failed = preheater.state else {
            Issue.record("期望 failed，实际 \(preheater.state)")
            return
        }

        // 预热失败之后，真正那次识别不该被它牵连
        recognizer.failure = nil
        recognizer.lines = [line("还是能识别")]
        let service = TextRecognitionService(recognizer: recognizer, clock: FakeClock())
        await service.recognize(blank)

        guard case .ready(let result) = service.state else {
            Issue.record("预热失败不该拖垮真正的识别，实际 \(service.state)")
            return
        }
        #expect(result.fullText == "还是能识别")
    }

    @Test("预热用的图不是 1×1：太小会被框架当无效请求直接拒掉，那样等于什么都没热")
    func preheatImageIsNotDegenerate() {
        let image = TextRecognitionPreheater.blankImage()

        #expect(image.width >= 16)
        #expect(image.height >= 16)
    }

    // MARK: - 装置

    private var blank: CGImage {
        TestImage.solid(width: 40, height: 20, red: 1, green: 1, blue: 1)
    }

    private func line(_ text: String) -> RecognizedTextLine {
        RecognizedTextLine(text: text, frame: CGRect(x: 0, y: 0, width: 40, height: 12))
    }

    private func makeService(_ recognizer: FakeTextRecognizer) -> TextRecognitionService {
        TextRecognitionService(recognizer: recognizer, clock: FakeClock())
    }
}

// MARK: - 替身

/// 可控的文字识别替身。
///
/// 真实 Vision 在这里跑不了（首次调用几十秒，而且结果不可控），
/// 但「编排有没有把它接上、接上之后走哪条分支」完全是本层的事。
final class FakeTextRecognizer: TextRecognizing, @unchecked Sendable {

    private let lock = NSLock()
    private var storedLines: [RecognizedTextLine]
    private var storedFailure: StubCaptureError?
    private var storedCallCount = 0
    private var storedLanguages: [String] = []
    private var storedDelay: Duration = .zero

    init(lines: [RecognizedTextLine]) {
        storedLines = lines
    }

    var lines: [RecognizedTextLine] {
        get { withLocked(lock) { storedLines } }
        set { withLocked(lock) { storedLines = newValue } }
    }

    var failure: StubCaptureError? {
        get { withLocked(lock) { storedFailure } }
        set { withLocked(lock) { storedFailure = newValue } }
    }

    var callCount: Int { withLocked(lock) { storedCallCount } }
    var seenLanguages: [String] { withLocked(lock) { storedLanguages } }

    /// 让「识别中」这个瞬间可被观测。真实 Vision 是几百毫秒，这里按毫秒给。
    var delay: Duration {
        get { withLocked(lock) { storedDelay } }
        set { withLocked(lock) { storedDelay = newValue } }
    }

    func recognize(in image: CGImage, languages: [String]) async throws -> [RecognizedTextLine] {
        let outcome = withLocked(lock) { () -> (StubCaptureError?, [RecognizedTextLine], Duration) in
            storedCallCount += 1
            storedLanguages = languages
            return (storedFailure, storedLines, storedDelay)
        }

        if outcome.2 != .zero { try? await Task.sleep(for: outcome.2) }
        if let failure = outcome.0 { throw failure }
        return outcome.1
    }
}

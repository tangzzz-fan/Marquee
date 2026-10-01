import CoreGraphics
import Foundation

// MARK: - 值类型

/// 识别出来的一行文字。
public struct RecognizedTextLine: Equatable, Sendable {
    public let text: String
    /// 在原图**像素**坐标里的包围盒（原点左上，与标注模型同一套坐标）。
    /// 现在只做记录 —— 以后要"点某一行就高亮原图上那块"时直接用。
    public let frame: CGRect
    /// 0...1
    public let confidence: Double

    public init(text: String, frame: CGRect, confidence: Double = 1) {
        self.text = text
        self.frame = frame
        self.confidence = confidence
    }

    /// 把 Vision 那种「归一化 + 原点左下」的包围盒，换算成标注模型用的
    /// 「像素 + 原点左上」。
    ///
    /// 翻 y 这一步不能省，而且它属于"现在不翻也不会立刻出问题"的那类：
    /// OCR 面板眼下只显示文本、不画框，所以翻错了**既不报错也看不见** ——
    /// 要等以后拿这个 `frame` 去做"点某一行就高亮原图上那块"时才暴露。
    /// 放在 Core 里就是为了让这一步现在就有测试钉着。
    public static func frame(fromNormalized box: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: box.minX * imageSize.width,
               y: (1 - box.maxY) * imageSize.height,
               width: box.width * imageSize.width,
               height: box.height * imageSize.height)
    }
}

/// 一次识别的结果。
public struct TextRecognitionResult: Equatable, Sendable {
    public let lines: [RecognizedTextLine]
    /// 识别耗时（毫秒）。
    ///
    /// **首次会非常大**（模型未缓存时约 25 秒），所以这个数字不是性能装饰，
    /// 而是"启动预热有没有生效"的第一手证据 —— 正常情况下它应该在几百毫秒以内。
    public let elapsedMilliseconds: Double

    public init(lines: [RecognizedTextLine], elapsedMilliseconds: Double = 0) {
        self.lines = lines
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    /// 整段文本：按识别顺序逐行拼接。
    ///
    /// 用换行而不是空格连接：中文没有词间空格，而视觉上分开的两行本来就该分开 ——
    /// 粘成一段会让用户再也分不出原文在哪里断行。
    public var fullText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    public var isEmpty: Bool { lines.isEmpty }

    public var characterCount: Int {
        lines.reduce(0) { $0 + $1.text.count }
    }
}

// MARK: - 接缝

/// 文字识别。
///
/// 抽成协议的理由与其它接缝一致：「什么时候识别、结果怎么呈现、空结果怎么说」
/// 必须能在没有 Vision、没有真实图片的环境下断言。
/// 真实实现见 `MarqueeCapture.VisionTextRecognizer`。
public protocol TextRecognizing: Sendable {
    /// - Parameters:
    ///   - image: 原图像素
    ///   - languages: 识别语言（按优先级）。只给英文会把中文整段漏掉。
    /// - Returns: 按阅读顺序排好的行
    func recognize(in image: CGImage, languages: [String]) async throws -> [RecognizedTextLine]
}

// MARK: - 编辑器用的服务

/// 一次识别的状态机。编辑器只看这个状态画界面。
@MainActor
public final class TextRecognitionService {

    public enum State: Equatable, Sendable {
        case idle
        case running
        case ready(TextRecognitionResult)
        /// 图里没有文字。
        ///
        /// **单独一档而不是"空的 ready"**：界面必须说人话。
        /// 什么都不显示会让人以为是功能坏了（"点了没反应"是这类工具最费的反馈）。
        case empty
        case failed(String)
    }

    /// 中英双语。顺序有意义：Vision 按给定顺序决定优先级。
    public static let defaultLanguages = ["zh-Hans", "en-US"]

    public private(set) var state: State = .idle

    private let recognizer: TextRecognizing
    private let languages: [String]
    private let clock: MonotonicClock

    public init(recognizer: TextRecognizing,
                languages: [String] = TextRecognitionService.defaultLanguages,
                clock: MonotonicClock = SystemMonotonicClock()) {
        self.recognizer = recognizer
        self.languages = languages
        self.clock = clock
    }

    public var isRunning: Bool { state == .running }

    /// 结果文本（`ready` 之外为空）。
    public var text: String {
        if case .ready(let result) = state { return result.fullText }
        return ""
    }

    /// 给界面用的一句话。`nil` = 没什么可说（还没开始）。
    public var message: String? {
        switch state {
        case .idle:
            nil
        case .running:
            L10n.t("正在识别文字…")
        case .ready(let result):
            L10n.t("识别到 \(result.lines.count) 行 · \(result.characterCount) 字 · ")
                + String(format: "%.0f ms", result.elapsedMilliseconds)
        case .empty:
            L10n.t("这张图里没有识别到文字")
        case .failed(let reason):
            L10n.t("识别失败：\(reason)")
        }
    }

    /// 识别。识别中重复调用会被忽略（连点按钮不该叠出两趟识别）。
    public func recognize(_ image: CGImage) async {
        guard state != .running else { return }

        state = .running
        let startedAt = clock.now()
        do {
            let lines = try await recognizer.recognize(in: image, languages: languages)
            let elapsed = (clock.now() - startedAt) * 1000
            state = lines.isEmpty
                ? .empty
                : .ready(TextRecognitionResult(lines: lines, elapsedMilliseconds: elapsed))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 换一张图之前清掉上一次的结果，免得旧文本留在面板里被误当成新图的。
    public func reset() {
        state = .idle
    }
}

// MARK: - 启动预热

/// 启动时把 Vision 的文字识别模型热起来。
///
/// ## 为什么必须有（不是优化）
///
/// `docs/PRD.md` R10 实测：**首次调用约 25 秒**（模型未缓存），
/// 缓存之后冷启动 177 ms、稳态 p50 60 ms。
/// 不做预热的话，用户第一次点「识别文字」会盯着一个几十秒不动的界面 ——
/// 那与"应用卡死"没有区别，而且他不会再点第二次。
///
/// ## 预热的原理
///
/// 成本几乎全在 **Vision 加载 / 编译模型**那一步，与图片内容无关。
/// 所以预热就是"拿一张小图跑一次完整请求"，识别不出任何东西才是正常的。
@MainActor
public final class TextRecognitionPreheater {

    public enum State: Equatable, Sendable {
        case idle
        case warming
        case ready
        /// 预热失败。
        ///
        /// **不是致命的**：真到用户点识别时那次调用会自己再走一遍。
        /// 这里只记状态，供排障看 —— 绝不能因此挡住任何主流程。
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let recognizer: TextRecognizing
    private var task: Task<Void, Never>?

    public init(recognizer: TextRecognizing) {
        self.recognizer = recognizer
    }

    /// 幂等：重复调用（每次截图都调一次也没关系）只会在第一次真的跑。
    public func startIfNeeded() {
        guard state == .idle else { return }
        state = .warming
        let recognizer = self.recognizer
        task = Task { [weak self] in
            do {
                _ = try await recognizer.recognize(in: Self.blankImage(),
                                                   languages: TextRecognitionService.defaultLanguages)
                self?.state = .ready
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// 等预热收尾。测试用；应用里不需要等（预热本来就是后台的）。
    public func waitUntilFinished() async {
        await task?.value
    }

    /// 预热用的空白图。
    ///
    /// 刻意**不用 1×1**：太小会被 Vision 当无效请求直接拒掉，
    /// 那样预热就变成了"什么都没热"，而且要等到用户第一次点才发现。
    /// 尺寸取一个不会被拒绝的小图即可 —— 成本在模型加载，不在像素多少。
    ///
    /// 公开它只为了能被测试断言"不是 1×1"（那是预热失效最容易踩的一种）。
    public static func blankImage(side: Int = 64) -> CGImage {
        let size = max(16, side)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: size,
                                      height: size,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            // 参数是固定常量，走到这里说明 CG 环境本身出了问题 —— 与其悄悄返回一张错图，
            // 不如在这里说清楚（调用方是预热，它本来也不该改变任何主流程）。
            preconditionFailure("预热用的空白图建不出来（\(size)×\(size) sRGB 8 位）")
        }
        return image
    }
}

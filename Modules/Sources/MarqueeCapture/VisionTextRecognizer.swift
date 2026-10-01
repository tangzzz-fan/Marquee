import CoreGraphics
import Foundation
import MarqueeCore
import Vision

/// 用系统 Vision 做文字识别（ticket 13）。
///
/// 全程本地：不联网、不下载模型 —— PRD 决策 8「本地 AI 只做系统级」。
///
/// ## 耗时（实测，见 `docs/PRD.md` R10）
///
/// 首次约 **25 秒**（模型未缓存），缓存后冷启动 177 ms、稳态 p50 60 ms（900×260，accurate，中英）。
/// 所以第一次调用必须被 `TextRecognitionPreheater` 在启动时替用户吃掉。
public struct VisionTextRecognizer: TextRecognizing {

    private let level: VNRequestTextRecognitionLevel
    private let usesLanguageCorrection: Bool

    public init(level: VNRequestTextRecognitionLevel = .accurate,
                usesLanguageCorrection: Bool = true) {
        self.level = level
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognize(in image: CGImage, languages: [String]) async throws -> [RecognizedTextLine] {
        let box = SendableImage(image)
        let accurate = level == .accurate
        let corrects = usesLanguageCorrection

        // `VNImageRequestHandler.perform` 是**同步阻塞**的，而调用方是 MainActor
        // （编辑器在点按钮的那条链上）。整趟扔到后台，界面该转的等待反馈才转得起来。
        //
        // 闭包里只捕获值类型 + 一个显式承担 Sendable 的图 —— Vision 对象一律在闭包内
        // 创建与销毁，不跨边界。
        return try await Task.detached(priority: .userInitiated) {
            try Self.perform(image: box.value,
                             languages: languages,
                             accurate: accurate,
                             corrects: corrects)
        }.value
    }

    private static func perform(image: CGImage,
                                languages: [String],
                                accurate: Bool,
                                corrects: Bool) throws -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = corrects

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let imageSize = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(
                text: candidate.string,
                // Vision 的包围盒是归一化 + 原点左下，要翻成像素 + 原点左上。
                // 换算在 Core（`RecognizedTextLine.frame(fromNormalized:imageSize:)`），那里有测试钉着。
                frame: RecognizedTextLine.frame(fromNormalized: observation.boundingBox,
                                                imageSize: imageSize),
                confidence: Double(candidate.confidence))
        }
    }
}

/// `CGImage` 创建后不可变、跨线程只读安全 —— Swift 6 不会为 Core Foundation 类型
/// 自动推导，这里显式承担该保证（与 `CapturedImage` 同一套理由）。
private struct SendableImage: @unchecked Sendable {
    let value: CGImage

    init(_ value: CGImage) {
        self.value = value
    }
}

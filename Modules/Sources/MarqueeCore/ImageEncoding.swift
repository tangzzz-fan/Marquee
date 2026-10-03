import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图像编码。
///
/// 归属：`MarqueeCore`（PRD 5.2 把"编码"划给 Core）。
/// 用 ImageIO 而不是 `NSBitmapImageRep`：前者是跨平台图像层，
/// 不依赖 AppKit，也不会有 Apple 私有色彩空间处理的意外。
public enum ImageEncoding {

    /// 把 `CGImage` 编码成 PNG 数据。
    ///
    /// 这是写剪贴板与落盘共用的唯一编码入口。
    /// **不要**改成"先包成 `NSImage` 再取 TIFF" —— 那条路会丢分辨率元数据，
    /// Retina 下粘贴出来直接变半尺寸（`docs/SPIKE-PLAN.md` F2/F3）。
    public static func pngData(from image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    /// 按输出格式编码。剪贴板始终走 `pngData`；落盘才用 JPEG / HEIC。
    ///
    /// `quality` 只对 JPEG / HEIC 生效，范围 0...1。PNG 忽略它。
    public static func data(from image: CGImage, format: ImageFileFormat, quality: Double) -> Data? {
        switch format {
        case .png:
            return pngData(from: image)
        case .jpeg, .heic:
            return lossyData(from: image, type: format.utType, quality: quality)
        }
    }

    private static func lossyData(from image: CGImage, type: UTType, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, type.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let clamped = min(1, max(0, quality))
        let properties = [kCGImageDestinationLossyCompressionQuality: clamped] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}

public enum ImageFileFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case png
    case jpeg
    case heic

    public var pathExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    /// 界面上显示的名字。**不本地化** —— `PNG` / `JPEG` / `HEIC` 是格式的正式名，
    /// 在中文界面里也是这三个字母（翻译了反而没人认得出）。
    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    /// 这个格式**是不是有损的**。
    ///
    /// 决定两件界面上看得见的事（稿子 §C.3）：
    ///
    /// 1. 「质量」那一行的说明句换成哪一句；
    /// 2. 那根滑块**可不可用**。
    ///
    /// ⚠️ 注意置灰的是**滑块**，不是这一行 —— 行标题与说明句照常读得出。
    /// 稿子的原话：「『这里有一项、它现在不适用』和『这里没有这一项』必须分开，
    /// 否则用户会以为 PNG 下能换个地方调质量。」
    public var isLossy: Bool {
        switch self {
        case .png: false
        case .jpeg, .heic: true
        }
    }

    /// 「质量」那一行的说明句。
    ///
    /// 无损时说的是**为什么现在不能调**（而不是"质量不可用"这种没有下一步的话）。
    public var qualityExplanation: String {
        guard isLossy else {
            return L10n.t("PNG 是无损格式，没有质量可调 —— 换成 JPEG 或 HEIC 才有")
        }
        return L10n.t("\(displayName) 的压缩质量 · 越低文件越小、细节越少")
    }

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}

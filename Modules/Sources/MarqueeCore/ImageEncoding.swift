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

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}

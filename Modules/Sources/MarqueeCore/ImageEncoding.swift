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
}

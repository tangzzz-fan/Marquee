import Foundation
import CoreGraphics
import MarqueeCore

/// 截图历史模块。
///
/// 归属 ticket：16（最近截图面板）。
///
/// 关键设计约束：历史条目必须同时保存**原始图 + 标注向量**，
/// 这样从历史重新进入编辑器时标注仍然可编辑。只存栅格化结果会让"重新编辑"退化成"再画一遍"。
public struct CaptureRecord: Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let pixelSize: CGSize
    /// 是否已落盘（未落盘的只存在于剪贴板，不进历史）
    public let fileURL: URL?

    public init(id: UUID = UUID(), capturedAt: Date, pixelSize: CGSize, fileURL: URL?) {
        self.id = id
        self.capturedAt = capturedAt
        self.pixelSize = pixelSize
        self.fileURL = fileURL
    }
}

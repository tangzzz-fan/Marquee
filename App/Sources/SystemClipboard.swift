import AppKit
import MarqueeCore

/// 系统剪贴板。
///
/// 写**原始 PNG 数据**而不是 `NSImage`：粘贴端拿到的是原始字节，
/// 不依赖 scale 元数据的传递，Retina 下不会退化成半分辨率
/// （`docs/SPIKE-PLAN.md` F2/F3）。
struct SystemClipboard: ClipboardWriting, Sendable {

    func writePNG(_ data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }
}

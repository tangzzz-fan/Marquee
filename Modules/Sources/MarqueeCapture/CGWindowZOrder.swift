import CoreGraphics
import Foundation

/// `CGWindowListCopyWindowInfo` 给出的在屏窗口，**前台 → 后台**。
///
/// ScreenCaptureKit 的 `windows` 没有稳定的叠放顺序，同层窗口会按框相交就命中，
/// 把已经被挡住、区域内看不见的窗也选上。这份列表才是合成器的真实顺序，并带 alpha。
enum CGWindowZOrder {

    struct Entry: Equatable {
        let id: UInt32
        let alpha: Double
    }

    static func frontToBack() -> [Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var seen = Set<UInt32>()
        var result: [Entry] = []
        result.reserveCapacity(info.count)
        for item in info {
            guard let id = uint32(item[kCGWindowNumber as String]) else { continue }
            guard seen.insert(id).inserted else { continue }
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            result.append(Entry(id: id, alpha: alpha))
        }
        return result
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        switch value {
        case let number as NSNumber:
            return number.uint32Value
        case let number as UInt32:
            return number
        default:
            return nil
        }
    }
}

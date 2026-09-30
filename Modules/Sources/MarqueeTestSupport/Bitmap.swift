import CoreGraphics
import Foundation

/// 位图的读法。**测试专用**，与产品代码分开放。
///
/// ## 这里刻意不放 `CGImage` 扩展，而是走自己的缓冲
///
/// `CGImage` 常常是"共享同一个 dataProvider 的裁剪视图"（`cropping(to:)` 就是），
/// 直接读它的 `dataProvider` 拿到的是**整页**的字节，行号还要自己加偏移。
/// 统一重绘进一块自己的 sRGB 缓冲，行号就等于图像行号，断言才好写。
///
/// ## ⚠️ 两个已经踩过的坑
///
/// 1. **行步长必须用 `ctx.bytesPerRow`（字节）**。用 `bytesPerRow / 4` 再乘像素下标
///    是单位混用，会读出完全无关的字节 —— 而且不报错，只是断言在胡说。
/// 2. 缓冲要用 `ctx.bytesPerRow` 对齐后的实际值跨行；`width * 4` 作为步长在宽度不是
///    16 的倍数时会被 CG 填充，整行读成垃圾。
public struct Bitmap: Sendable {

    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bytes: [UInt8]

    public func rgba(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let index = y * bytesPerRow + x * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }

    /// 亮度（0...255），与 `CGColorSpaceCreateDeviceGray` 的重绘结果同量级
    public func luma(x: Int, y: Int) -> Int {
        let pixel = rgba(x: x, y: y)
        return (Int(pixel.red) * 299 + Int(pixel.green) * 587 + Int(pixel.blue) * 114) / 1000
    }

    public func rowLuma(y: Int) -> [Int] {
        (0..<width).map { luma(x: $0, y: y) }
    }
}

public enum BitmapReader {

    /// 重绘进 sRGB + premultipliedLast 的缓冲后读出。
    public static func read(_ image: CGImage) -> Bitmap? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bytesPerRow = context.bytesPerRow
        let raw = base.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { destination in
            if let pointer = destination.baseAddress {
                pointer.copyMemory(from: raw, byteCount: bytesPerRow * height)
            }
        }
        return Bitmap(width: width, height: height, bytesPerRow: bytesPerRow, bytes: bytes)
    }

    /// 两张图的**平均绝对误差**，单位是 0...255。
    ///
    /// 只在公共区域上比（高度与宽度取较小值），便于把"长图比真值矮一行"这种情况
    /// 单独用高度断言，而不是混成一个巨大的误差值。
    public static func meanAbsoluteError(_ lhs: CGImage, _ rhs: CGImage) -> Double? {
        guard let a = read(lhs), let b = read(rhs) else { return nil }
        let width = min(a.width, b.width)
        let height = min(a.height, b.height)
        guard width > 0, height > 0 else { return nil }
        var total = 0
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                total += abs(a.luma(x: x, y: y) - b.luma(x: x, y: y))
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : nil
    }
}

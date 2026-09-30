import CoreGraphics
import Foundation

/// 确定性伪随机（LCG）。合成数据的"随机"必须可复现，否则测试失败无从复现。
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((state >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
    }

    public mutating func value(_ lower: Double, _ upper: Double) -> Double {
        lower + next() * (upper - lower)
    }

    public mutating func integer(_ lower: Int, _ upper: Int) -> Int {
        lower + Int(next() * Double(upper - lower + 1)) % max(1, upper - lower + 1)
    }
}

/// 合成"长页面"。**测试专用**。
///
/// 用来做滚动配准的**装置自检**：配准是"不崩、不报错、只会悄悄错"的典型模块
/// （`docs/SPIKE-PLAN.md` 的 K1/K2/K3 三个坑全是靠它才发现的），所以必须有一份
/// 已知真值的长页，让"取帧 → 配准 → 拼接 → 与真值比对"整条链路可回归。
///
/// 内容刻意做成**逐行可区分**：密集的短行块 + 少量高对比实心块。
/// 纯色或规律性太强的内容会让平移配准解出多义结果，那是装置的问题不是实现的问题。
public struct SyntheticPage: Sendable {

    public let width: Int
    public let height: Int
    public let image: CGImage

    public init(width: Int = 600, height: Int = 6000, seed: UInt64 = 0xC0FFEE) {
        self.width = width
        self.height = height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var random = SeededRandom(seed: seed)

        // ── 文本行块：每行由若干灰度小段组成，行高与间隔随机
        var top = 20
        while top < height - 60 {
            let lineHeight = random.integer(12, 30)
            var x = 30.0
            while x < Double(width - 60) {
                let segmentWidth = random.value(30, 160)
                if random.next() > 0.2 {
                    let value = random.value(0.05, 0.6)
                    context.setFillColor(CGColor(colorSpace: colorSpace, components: [value, value, value, 1])!)
                    context.fill(CGRect(x: x,
                                        y: Double(height - top - lineHeight),
                                        width: segmentWidth,
                                        height: Double(lineHeight)))
                }
                x += segmentWidth + random.value(8, 18)
            }
            top += lineHeight + random.integer(4, 16)
        }

        // ── 高对比实心块：给配准提供强特征
        let blockCount = max(8, height / 150)
        for _ in 0..<blockCount {
            let blockX = random.value(40, Double(width - 200))
            let blockY = random.value(40, Double(height - 200))
            let value = random.value(0, 0.3)
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [value, value, value, 1])!)
            context.fill(CGRect(x: blockX,
                                y: blockY,
                                width: random.value(60, 180),
                                height: random.value(24, 120)))
        }

        image = context.makeImage()!
    }

    /// 取一帧。`offsetY` 是**自上而下**的行偏移（图像坐标系原点在左上）。
    ///
    /// 用 `cropping(to:)` 而不是负坐标 rect 的 `draw` —— 后者正是 SPIKE K2 那个坑，
    /// 结果与预期不符且不报错。
    public func frame(offsetY: Int, viewHeight: Int) -> CGImage? {
        guard offsetY >= 0, viewHeight >= 1, offsetY + viewHeight <= height else { return nil }
        return image.cropping(to: CGRect(x: 0, y: offsetY, width: width, height: viewHeight))
    }

    /// 取一帧，允许**小数**偏移 —— 用来造"亚像素滚动"这种真实屏幕上很常见、
    /// 但用整数裁剪造不出来的输入。
    ///
    /// 做法与 `docs/SPIKE-PLAN.md` 的 D4 一致：先按整数行裁一块（多要 2 行备料），
    /// 再把它按小数相位重绘进视口。这样帧本身是"被重采样过的真实观感"，
    /// 而不是"整数帧 + 事后偏移"。
    public func frame(offsetY: Double, viewHeight: Int) -> CGImage? {
        let integer = Int(offsetY.rounded(.down))
        let fraction = offsetY - Double(integer)
        // 相位非 0 时要多要 1 行备料，否则视口底边会缺一条
        guard integer >= 0, viewHeight >= 1, integer + viewHeight + 1 <= height else { return nil }
        if fraction < 1e-9 {
            return frame(offsetY: integer, viewHeight: viewHeight)
        }

        let sourceHeight = min(viewHeight + 2, height - integer)
        guard let cropped = image.cropping(to: CGRect(x: 0,
                                                      y: integer,
                                                      width: width,
                                                      height: sourceHeight)) else {
            return frame(offsetY: integer, viewHeight: viewHeight)
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: viewHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: viewHeight))
        // 上下文原点在左下：把裁剪块贴着顶边放，再往下挪一个相位 ——
        // 等效于视口多滚了 fraction 行
        context.draw(cropped, in: CGRect(x: 0,
                                         y: Double(viewHeight - sourceHeight) + fraction,
                                         width: Double(width),
                                         height: Double(sourceHeight)))
        return context.makeImage()
    }

    /// 真值：长页顶部 `height` 行。
    public func truth(height: Int) -> CGImage? {
        frame(offsetY: 0, viewHeight: height)
    }
}

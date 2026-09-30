import CoreGraphics
import Foundation

/// 长图里的一段：取自某一帧的连续若干行，整段一起落到长图上。
public struct ScrollSlice: Equatable, Sendable {
    /// 取自第几帧
    public let frameIndex: Int
    /// 在长图里占的整数行区间（半开）
    public let canvasRows: Range<Int>
    /// 该帧里取的行区间（半开，整数行）
    public let sourceRows: Range<Int>
    /// `sourceRows.lowerBound` 落在长图第几行。**允许小数 = 亚像素相位**。
    public let destinationTop: Double
}

/// 一次拼接的完整排布。**纯数据**；渲染是另一件事（`ScrollStitchRenderer`）。
public struct ScrollStitchPlan: Equatable, Sendable {
    public let pixelWidth: Int
    public let totalHeight: Int
    /// 按长图行递增
    public let slices: [ScrollSlice]
    /// 逐帧的**累计精确位移**（第 0 帧恒为 0）。诊断与断言用。
    public let offsets: [Double]

    public var frameCount: Int { offsets.count }
    public var accumulatedRows: Double { offsets.last ?? 0 }
    public var isPixelExact: Bool { offsets.allSatisfy { $0 == $0.rounded() } }
}

/// 增量拼接器。
///
/// 责任只有一件：把「每帧滚了多少」翻译成「每帧的哪几行放到长图的哪几行」。
/// **它不碰像素**，所以整条排布公式可以被完整断言 —— 这是本 ticket 里最容易
/// 悄悄出错（不崩、不报错、只是长图错位）也最值得单测的地方。
///
/// ## 三条已实测的约定（改动前先看 `docs/SPIKE-PLAN.md` 的 K1/K2/K3）
///
/// 1. 向下滚 `d` 行，新露出来的是视口**底部**的 `d` 行 —— 用自上而下的行号说
///    是本帧 `[viewH - d, viewH)`。内容向上跑，新的从下面进来。
/// 2. 行号一律按「自上而下」处理，与 `CGImage` 内存行序一致，**不要**再翻一次。
/// 3. 累计位移保留小数，落位时按片统一做亚像素偏移（见下）。
///
/// ## 排布规则
///
/// 长图第 `y` 行归**包含它的最早那一帧**所有（源行 = `y - 该帧累计位移`）。
/// 之所以归最早的那一帧：吸顶标题栏污染的是每帧的**顶部**，而重叠区在较早那帧里
/// 位于靠下的位置，离污染源最远。这是免费的抗吸顶收益。
///
/// ## 为什么用 `floor` 而不是 `ceil` 定总高
///
/// 累计位移 600.5 时内容真实下沿在 1400.5。取 `ceil` 会得到 1401 行，而最后一行
/// 只有一半有内容 —— 渲染出来是一条**半透明的边**。取 `floor` = 1400 行，
/// 每行都被完整覆盖，半行信息本来也不值得留。
public struct ScrollStitcher: Equatable, Sendable {

    public let pixelWidth: Int
    public let viewHeight: Int
    /// 每帧累计精确位移，第 0 帧恒为 0
    public private(set) var offsets: [Double] = []

    public init(pixelWidth: Int, viewHeight: Int) {
        self.pixelWidth = max(1, pixelWidth)
        self.viewHeight = max(1, viewHeight)
    }

    public var frameCount: Int { offsets.count }

    /// 当前长图应有的高度（行）
    public var totalHeight: Int {
        guard let last = offsets.last else { return 0 }
        return max(viewHeight, Int(floor(last + Double(viewHeight) + 1e-9)))
    }

    /// 累计精确位移（小数）
    public var accumulatedRows: Double { offsets.last ?? 0 }

    /// 接受一帧。第 0 帧只是基线，位移被忽略。
    public mutating func append(rows: Double) {
        let exact = offsets.last.map { $0 + rows } ?? 0
        offsets.append(exact)
    }

    public var plan: ScrollStitchPlan {
        let height = totalHeight
        guard height > 0 else {
            return ScrollStitchPlan(pixelWidth: pixelWidth,
                                    totalHeight: 0,
                                    slices: [],
                                    offsets: offsets)
        }

        var slices: [ScrollSlice] = []
        slices.reserveCapacity(offsets.count)
        var cursor = 0

        for index in offsets.indices {
            guard cursor < height else { break }
            let top = offsets[index]
            // 本帧能覆盖到长图哪一行（连续坐标）
            let reach = min(Double(height), top + Double(viewHeight))
            guard reach > Double(cursor) else { continue }

            var sourceStart = Int(floor(Double(cursor) - top))
            var sourceEnd = Int(ceil(reach - top))
            sourceStart = max(0, sourceStart)
            sourceEnd = min(viewHeight, sourceEnd)
            guard sourceStart < sourceEnd else { continue }

            // 本片**真正**覆盖到的长图行。
            //
            // 这里必须取 floor 而不是 ceil：本片画出来的下沿是连续坐标
            // `sourceEnd + top`（可能带小数），ceil 会把它算大一行 ——
            // 那一行只是被本片糊了不到一半，于是谁都不完整覆盖它，
            // 长图上就会留下一条**半透明横线**。
            // 取 floor 后这一行交给下一帧去完整覆盖（下一帧的源行同样对得上）。
            let bottom = min(height, Int(floor(Double(sourceEnd) + top + 1e-9)))
            guard bottom > cursor else { continue }

            slices.append(ScrollSlice(frameIndex: index,
                                      canvasRows: cursor..<bottom,
                                      sourceRows: sourceStart..<sourceEnd,
                                      destinationTop: Double(sourceStart) + top))
            cursor = bottom
        }

        return ScrollStitchPlan(pixelWidth: pixelWidth,
                                totalHeight: height,
                                slices: slices,
                                offsets: offsets)
    }
}

/// 按 `ScrollStitchPlan` 把帧拼成长图。
///
/// ## ⚠️ 画图时**不要**翻转 CTM（实测，别改回去）
///
/// "翻成左上原点再 `draw` 图像"是常见写法，但**它会把图上下颠倒**：
/// 翻转后 `draw(image, in: rect)` 仍然把图像的顶行放在 `rect.maxY`，
/// 而翻转后 `rect.maxY` 是视觉上的**下**边。实测：把自上而下为 10/20/30/40
/// 的四行图落在第 2 行，翻转得到 `40,30,20,10`，不翻转才是 `10,20,30,40`。
///
/// 所以这里保持 CG 默认的 y 向上坐标系，用
/// `y = 长图高度 - 落位 - 片高` 把"自上而下的行号"折算过去。
/// 标注栅格化（`AnnotationRasterizer`）踩的是同一个坑，注释见那边。
///
/// ## 亚像素处理
///
/// 同一片里每一行的相位是同一个（长图行是整数、片内累计位移固定），
/// 所以整片就是一次**统一的竖直小数偏移** —— 交给 `CGContext` 的高质量插值一次画完即可，
/// 不必逐行手写插值。这也是为什么相位挂在片（slice）上而不是行上。
///
/// 相邻片子最多重叠一行，后画的会盖住前一行的亚像素混合 —— 两者代表同一段内容、
/// 只差不到 1 像素，正是重采样本该给出的结果。
public enum ScrollStitchRenderer {

    public static func render(plan: ScrollStitchPlan, frames: [CGImage]) -> CGImage? {
        guard plan.pixelWidth >= 1, plan.totalHeight >= 1, !plan.slices.isEmpty else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: plan.pixelWidth,
                                      height: plan.totalHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high

        for slice in plan.slices {
            guard frames.indices.contains(slice.frameIndex) else { return nil }
            let frame = frames[slice.frameIndex]
            guard frame.width == plan.pixelWidth else { return nil }
            let crop = CGRect(x: 0,
                              y: slice.sourceRows.lowerBound,
                              width: frame.width,
                              height: slice.sourceRows.count)
            guard let piece = frame.cropping(to: crop) else { return nil }

            let height = CGFloat(slice.sourceRows.count)
            // 整数落位时 CG 走直通路径、不糊；小数落位时这一整片做亚像素重采样
            context.draw(piece, in: CGRect(x: 0,
                                           y: CGFloat(plan.totalHeight) - CGFloat(slice.destinationTop) - height,
                                           width: CGFloat(frame.width),
                                           height: height))
        }

        return context.makeImage()
    }
}

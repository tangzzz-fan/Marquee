import CoreGraphics
import Foundation
import MarqueeCore
import Vision

/// Vision 平移配准（ticket 11 的主方案）。
///
/// ## 为什么是 Vision 而不是自研 SAD
///
/// `docs/SPIKE-PLAN.md` D 组实测：自研 SAD 的结论正确，但**单次 258 ms**，
/// 10 帧就是 2.6 秒卡顿；Vision 给出精确无误差的结果且快得多。自研版还要自己处理
/// 内容稀疏性、最小重叠、亚像素等一堆细节，收益为零。
///
/// ## 符号约定（已实测钉死，改动前先看探针结论）
///
/// `targetedCGImage:` = **上一帧**，handler 的图 = **当前帧**，此时
/// `alignmentTransform.ty` 就是「内容向上移动的行数」，也就是视口向下滚了多少行：
/// `rows = +ty`。
///
/// 不需要按"Vision 原点在左下"的说法取负。取负后的症状是**所有位移变负**，
/// 于是每一帧都被判成"没动"，长图永远只有一屏 —— 不崩、不报错、只是没有内容，
/// 属于最难查的那一类。因此这条由 `VisionScrollRegistrarTests` 的装置自检钉住。
public struct VisionScrollRegistrar: ScrollFrameRegistering {

    /// 配准前把帧缩小到 1/`downscale` 再做粗配准，然后按比例还原。
    ///
    /// 默认为 1（不降采样）：先按 SPIKE 的建议测出真实耗时，够用就不要引入
    /// 额外的缩放误差。若实测超预算，把它改成 2 或 4 即可。
    public let downscale: Int

    public init(downscale: Int = 1) {
        self.downscale = max(1, downscale)
    }

    public func register(previous: CGImage, current: CGImage) async throws -> ScrollShift {
        let previousImage = downscale > 1 ? Self.scaled(previous, by: downscale) : previous
        let currentImage = downscale > 1 ? Self.scaled(current, by: downscale) : current

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previousImage)
        let handler = VNImageRequestHandler(cgImage: currentImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScrollRegistrationFailure.failed(error.localizedDescription)
        }

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            throw ScrollRegistrationFailure.failed(L10n.t("Vision 没有返回平移观测值"))
        }

        let transform = observation.alignmentTransform
        let rows = Double(transform.ty) * Double(downscale)
        let horizontalDrift = abs(Double(transform.tx) * Double(downscale))

        // 平移配准理论上可以吃掉任意位移，所以置信度不能用"误差"表达。
        // 这里用两条能真正反映"这一帧能不能要"的判据：
        //   1. 横向漂移：竖直滚动不该伴随明显横向位移，出现了说明页面在动别的
        //   2. 位移本身的数值合理性：NaN / 无穷（画面几乎全同色时会出现）
        guard rows.isFinite, horizontalDrift.isFinite else {
            throw ScrollRegistrationFailure.unreliable(L10n.t("位移不是有限数值"))
        }
        let width = Double(currentImage.width)
        if horizontalDrift > max(8, width * 0.1) {
            throw ScrollRegistrationFailure.unreliable(
                L10n.t("横向漂移 \(Int(horizontalDrift.rounded())) px，画面不在做竖直滚动"))
        }

        // 置信度：横向漂移越小越高。竖直滚动不该伴随横向位移，
        // 它一旦出现就说明画面在动别的（横向动画、页面切换），这一帧不该要。
        let driftPenalty = min(1, horizontalDrift / max(1, width * 0.1))
        let confidence = max(0, 1 - driftPenalty)
        return ScrollShift(rows: rows, confidence: confidence)
    }

    /// 按整数比例缩小（只用于粗配准）。失败时退回原图 —— 配准宁可慢也不要拿不到。
    static func scaled(_ image: CGImage, by factor: Int) -> CGImage {
        let width = max(1, image.width / factor)
        let height = max(1, image.height / factor)
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

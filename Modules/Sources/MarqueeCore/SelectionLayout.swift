import CoreGraphics
import Foundation

/// 一块屏在最终输出图里承担的那一片。
public struct SelectionSlice: Equatable, Sendable {
    /// 该片的来源屏
    public let display: DisplayGeometry
    /// 该屏与选区的交集，**Quartz 全局点坐标**（交给采集层的就是它）
    public let globalPointRect: CGRect
    /// 该片在输出图中的落位，**像素、原点左上**
    public let targetPixelRect: CGRect

    public init(display: DisplayGeometry, globalPointRect: CGRect, targetPixelRect: CGRect) {
        self.display = display
        self.globalPointRect = globalPointRect
        self.targetPixelRect = targetPixelRect
    }
}

/// 一次跨屏选区在输出图上的布局方案。
public struct SelectionLayout: Equatable, Sendable {

    /// 输出图像的像素尺寸
    public let outputPixelSize: CGSize
    /// 逐屏切片，已按 (minY, minX) 排序，保证结果确定
    public let slices: [SelectionSlice]

    /// 输出图实际使用的像素/点比
    public let outputScale: CGFloat

    public init(outputPixelSize: CGSize, slices: [SelectionSlice], outputScale: CGFloat) {
        self.outputPixelSize = outputPixelSize
        self.slices = slices
        self.outputScale = outputScale
    }

    /// 规划一次采集。
    ///
    /// 返回 `nil` 表示这次选区采不出东西（面积为 0，或落在所有屏之外）。
    ///
    /// **输出分辨率取"参与屏里最大的那个 backing scale"**，而不是发起屏的：
    /// 取小的会把 2x 屏的内容降采样丢掉细节；取大的最坏只是把 1x 屏的内容放大，
    /// 属于"不丢信息"的保守选择。混合 DPI 下这一点决定输出是否"尺寸错乱"。
    public static func plan(selection: CGRect, displays: [DisplayGeometry]) -> SelectionLayout? {
        let normalized = Selection.rect(anchor: selection.origin,
                                        current: CGPoint(x: selection.maxX, y: selection.maxY))
        guard normalized.width > 0, normalized.height > 0 else { return nil }

        let intersected = displays.compactMap { display -> (DisplayGeometry, CGRect)? in
            guard let clipped = Selection.clipped(normalized, to: display.frame) else { return nil }
            return (display, clipped)
        }
        guard !intersected.isEmpty else { return nil }

        let scale = intersected.map(\.0.backingScale).max() ?? 1

        // 输出尺寸按**边**算，逐片也按边算：这样相邻两片的边界像素严格相邻，
        // 不会因为各自四舍五入而出现 1 像素的缝或 1 像素的重叠。
        let outputWidth = ((normalized.maxX - normalized.minX) * scale).rounded()
        let outputHeight = ((normalized.maxY - normalized.minY) * scale).rounded()

        var slices: [SelectionSlice] = []
        slices.reserveCapacity(intersected.count)
        for (display, clipped) in intersected {
            let minX = ((clipped.minX - normalized.minX) * scale).rounded()
            let maxX = ((clipped.maxX - normalized.minX) * scale).rounded()
            let minY = ((clipped.minY - normalized.minY) * scale).rounded()
            let maxY = ((clipped.maxY - normalized.minY) * scale).rounded()
            slices.append(SelectionSlice(
                display: display,
                globalPointRect: clipped,
                targetPixelRect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            ))
        }
        slices.sort(by: SelectionSlice.readOrderPrecedes)

        return SelectionLayout(outputPixelSize: CGSize(width: outputWidth, height: outputHeight),
                               slices: slices,
                               outputScale: scale)
    }
}

extension SelectionSlice {
    /// 稳定的阅读顺序（自上而下、自左而右）。
    ///
    /// 单独写成函数而不是塞进 `sort` 的闭包里：那个三元表达式会让
    /// 类型检查器爆炸（已实测 "unable to type-check in reasonable time"）。
    static func readOrderPrecedes(_ lhs: SelectionSlice, _ rhs: SelectionSlice) -> Bool {
        if lhs.targetPixelRect.minY != rhs.targetPixelRect.minY {
            return lhs.targetPixelRect.minY < rhs.targetPixelRect.minY
        }
        return lhs.targetPixelRect.minX < rhs.targetPixelRect.minX
    }
}

import CoreGraphics

/// 覆盖层里打码（马赛克 / 模糊）要用的**底图像素**。
///
/// ## 为什么需要它
///
/// 覆盖层刻意不铺整屏截图（PRD 5.5）：它只是一层变暗蒙层 + 挖洞，屏幕上的内容
/// 是**穿透看到的真东西**，不在我们手里。而马赛克必须拿到那块像素才能算。
///
/// 放大镜（ticket 10）已经在覆盖层出现时取过一屏冻结像素（`LensFrameProviding`），
/// 正好复用：**不额外采一次屏**，也就不会因为"再采一次"而让覆盖层自己被拍进去。
///
/// ## 为什么不是"从选区所在那屏裁一块"
///
/// 因为导出的底图不是那样来的：导出走 `SelectionLayout`（逐屏取交集、输出倍率取
/// 参与屏里最大的那个），再 `ImageCompositing` 拼起来。
/// 预览要是自己裁一块，跨屏选区下**尺寸与对齐都会跟导出的不一样** ——
/// 而马赛克看起来"差不多"，这种不一致极难被发现，等用户拿导出图去核对时才知道。
///
/// 所以这里**共用同一套布局与拼接**：预览和导出只能是同一张图。
public enum OverlayRedactionSource {

    /// 拼出选区的底图。
    ///
    /// - Parameter selection: **Quartz 全局点**下的选区（与 `SelectionLayout` 同一空间）
    /// - Parameter frames: 每块屏的冻结整屏像素，按 `displayID` 索引
    /// - Returns: 底图 + **底图每点对应多少像素**（＝ `layout.outputScale`）。
    ///   调用方要用这个倍率把"点"换算成"底图像素"，否则马赛克格子会小一半。
    ///
    /// **缺任何一块屏的冻结帧就整体返回 `nil`**，不给一张残缺的底图：
    /// 缺的那块会被 `AnnotationDrawing` 跳过、显示成原图 —— 那看起来像"打码没生效"，
    /// 比"这次预览不显示打码"危险得多（用户可能就这么发出去了）。
    public static func make(selection: CGRect,
                            displays: [DisplayGeometry],
                            frames: [UInt32: CGImage]) -> (image: CGImage, scale: CGFloat)? {
        guard let layout = SelectionLayout.plan(selection: selection, displays: displays) else { return nil }

        var slices: [ImageSlice] = []
        slices.reserveCapacity(layout.slices.count)
        for slice in layout.slices {
            guard let frame = frames[slice.display.displayID] else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            // `pixelRect` 已经取整过；再与图像边界求交，避免边缘那 1 像素因舍入越界
            let rect = slice.display.pixelRect(for: slice.globalPointRect).intersection(bounds)
            guard rect.width >= 1, rect.height >= 1,
                  let cropped = frame.cropping(to: rect) else { return nil }
            slices.append(ImageSlice(image: cropped, target: slice.targetPixelRect))
        }

        guard let composed = ImageCompositing.compose(outputSize: layout.outputPixelSize,
                                                      slices: slices) else { return nil }
        return (composed, layout.outputScale)
    }
}

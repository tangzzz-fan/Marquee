import CoreGraphics

/// 一张钉在屏幕上的图的**状态**：多大、在哪、多透明、穿不穿透。
///
/// ## 为什么这一层要在 Core
///
/// 缩放锚点、边界夹取、透明度循环这几条都只能"试出来"——
/// 比如"放大时图片的左上角该不该动"，手试三次也说不清，而它一旦定错，
/// 用户每次滚轮都会觉得图在往某个方向跑。抽成纯函数就能脱机断言。
///
/// ## 坐标
///
/// 一律 **Cocoa 全局点**（原点左下、y 向上），与 `NSPanel.frame` 同一套 ——
/// 中间不再翻一次，少一处能写反的地方。
public struct PinState: Equatable, Sendable {

    /// 1:1 显示尺寸（点）。像素尺寸除以屏幕倍率得来 —— 这样"100% 缩放"在
    /// 2x 屏上看起来与截下来的那块**一样大**，而不是小一半。
    public var baseSize: CGSize
    /// 相对 1:1 的缩放倍率。
    public private(set) var scale: CGFloat
    /// 不透明度档位的下标（见 `PinGeometry.opacitySteps`）。
    public private(set) var opacityIndex: Int
    /// 鼠标穿透（点击落到下面的应用）。
    public private(set) var isClickThrough: Bool
    /// 左下角（Cocoa 全局点）。
    public var origin: CGPoint

    public init(baseSize: CGSize,
                scale: CGFloat = 1,
                opacityIndex: Int = 0,
                isClickThrough: Bool = false,
                origin: CGPoint = .zero) {
        self.baseSize = baseSize
        self.scale = scale
        self.opacityIndex = opacityIndex
        self.isClickThrough = isClickThrough
        self.origin = origin
    }

    public var size: CGSize {
        CGSize(width: max(1, baseSize.width * scale), height: max(1, baseSize.height * scale))
    }

    public var frame: CGRect { CGRect(origin: origin, size: size) }

    public var opacity: CGFloat {
        PinGeometry.opacitySteps[min(opacityIndex, PinGeometry.opacitySteps.count - 1)]
    }

    /// 滚轮缩放一格。
    ///
    /// **锚点是左上角**：放大时图片往右下长，用户"盯着的那一角"不动。
    /// 用中心当锚点的话，每次滚轮图都会同时往四个方向跑 —— 连滚几次就找不着北了。
    /// （Cocoa 的 `frame` 原点在**左下**，所以改高度时要同步挪 y。）
    public mutating func zoom(by factor: CGFloat, screenFrame: CGRect) {
        let next = PinGeometry.clampedScale(scale * factor)
        guard next != scale else { return }
        let topLeftY = frame.maxY
        scale = next
        origin = CGPoint(x: origin.x, y: topLeftY - size.height)
        clampInto(screenFrame)
    }

    /// 换下一档不透明度（循环）。
    public mutating func cycleOpacity() {
        opacityIndex = PinGeometry.nextOpacityIndex(after: opacityIndex)
    }

    /// 切鼠标穿透。
    public mutating func toggleClickThrough() {
        isClickThrough.toggle()
    }

    /// 挪到某个左下角，并夹进屏幕。
    public mutating func move(to newOrigin: CGPoint, screenFrame: CGRect) {
        origin = newOrigin
        clampInto(screenFrame)
    }

    /// 夹进屏幕（**至少留一角在屏内**）。
    ///
    /// 夹取规则比"整个框都得在屏内"松：钉图常常比屏幕还大（放大到 400% 参考细节），
    /// 那种情况下要求整框在屏内会让它被硬缩回去 —— 而用户要的正是放大看局部。
    /// 所以只保证**左上角不漏出屏外**（那样连拖都拖不回来）。
    public mutating func clampInto(_ screenFrame: CGRect) {
        let current = frame
        var x = current.minX
        var y = current.minY
        // 至少留 40 点可见，否则用户抓不住它
        let keep: CGFloat = 40
        x = min(max(screenFrame.minX - current.width + keep, x), screenFrame.maxX - keep)
        y = min(max(screenFrame.minY - current.height + keep, y), screenFrame.maxY - keep)
        origin = CGPoint(x: x, y: y)
    }
}

/// 钉图的几何与档位常量。
public enum PinGeometry {

    /// 缩放范围。上限给到 4 是为了"放大看细节"，下限 0.2 是为了"缩成小参照"。
    public static let zoomRange: ClosedRange<CGFloat> = 0.2...4

    /// 滚轮一格的缩放倍率。**必须留一点"手感"**：一步到位（比如每格 ×2）
    /// 会让用户永远停不到想要的大小。
    public static let zoomStep: CGFloat = 1.08

    /// 不透明度档位。四档够用，而且每一档都一眼看得出区别 ——
    /// 用滑块的话得再加一套拖拽几何，而这里只需要"循环"。
    public static let opacitySteps: [CGFloat] = [1, 0.75, 0.5, 0.25]

    /// 控制条尺寸：三个按钮 + 内边距。
    public static let stripButtonSize: CGFloat = 24
    public static let stripItemGap: CGFloat = 2
    public static let stripPadding: CGFloat = 5

    public static var stripSize: CGSize {
        let width = stripButtonSize * 3 + stripItemGap * 2 + stripPadding * 2
        return CGSize(width: width, height: stripButtonSize + stripPadding * 2)
    }

    /// 控制条贴在钉图的**右上角内侧**。
    ///
    /// 为什么不贴在外侧：外侧会被屏幕边缘吃掉（钉图常常贴着屏幕边），
    /// 而"控制条不见了"与"这个功能没做"完全一样。
    /// 放内侧时它盖住图的一小块 —— 这是有意的代价（图可以拖走，控制条不能丢）。
    public static func stripFrame(pinFrame: CGRect,
                                 screenFrame: CGRect,
                                 size: CGSize = stripSize) -> CGRect {
        let inset: CGFloat = 6
        var x = pinFrame.maxX - size.width - inset
        var y = pinFrame.maxY - size.height - inset
        // 钉图很小的时候会跟它的左上角重叠，那时退到框外右侧
        if pinFrame.width < size.width + inset * 2 {
            x = pinFrame.maxX + inset
        }
        if pinFrame.height < size.height + inset * 2 {
            y = pinFrame.minY - size.height - inset
        }
        // 最后还是夹进屏幕：控制条被推出屏幕就点不到了
        x = min(max(screenFrame.minX + 2, x), screenFrame.maxX - size.width - 2)
        y = min(max(screenFrame.minY + 2, y), screenFrame.maxY - size.height - 2)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    public static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
    }

    public static func nextOpacityIndex(after index: Int) -> Int {
        (index + 1) % opacitySteps.count
    }

    /// 把一个图像的**像素尺寸**换成 1:1 的**显示点尺寸**。
    ///
    /// 不除这个倍率的话，2x 屏上钉出来的图会**只有原尺寸的一半大** ——
    /// 而用户看到的只是"钉出来比截的那块小"，不会想到是倍率。
    public static func displaySize(pixelSize: CGSize, backingScale: CGFloat) -> CGSize {
        let scale = backingScale > 0 ? backingScale : 1
        return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }
}

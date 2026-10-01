import CoreGraphics
import Foundation

// 本文件是「接缝」的定义处：采集 / 剪贴板 / 显示器定位 / 计时 四件事的协议与值类型。
//
// 为什么协议放在 Core 而不是各自的实现模块：
// 编排逻辑（`FullScreenCaptureFlow`）必须能脱离真实 TCC、真实屏幕和真实剪贴板单测，
// 而 SwiftPM 的依赖方向是单向的（实现模块 → Core）。协议若放在实现模块里，
// Core 就反过来要依赖它们，形成环。
//
// 所以约定：**Core 定义接缝与编排，实现模块只提供 OS 实现。**

// MARK: - 采集

/// 采集结果。
///
/// `CGImage` 创建后不可变，跨线程只读安全，因此这里用 `@unchecked Sendable`
/// 显式承担该保证（Swift 6 不会为 Core Foundation 类型自动推导）。
public struct CapturedImage: @unchecked Sendable {
    public let image: CGImage
    public let displayID: UInt32
    /// 采集时的 backing scale，用于断言"输出像素 = 点 × scale"
    public let backingScale: CGFloat

    public init(image: CGImage, displayID: UInt32, backingScale: CGFloat) {
        self.image = image
        self.displayID = displayID
        self.backingScale = backingScale
    }

    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

/// 采集模块对外的能力面。
///
/// 归属 ticket：02（全屏）、03（区域）、04（窗口）、11 / 12（滚动）。
public protocol ScreenCapturing: Sendable {
    /// 截取指定显示器的整屏内容（ticket 02）
    func captureFullScreen(_ display: DisplayGeometry) async throws -> CapturedImage

    /// 截取全局点坐标下的一个区域（ticket 03）
    func captureRegion(_ rect: CGRect, on display: DisplayGeometry) async throws -> CapturedImage

    /// 截取一扇窗口（ticket 04）。
    ///
    /// - Parameter includeShadow: `true` 带系统投影；`false` 无阴影、无背景
    /// - Parameter backingScale: 该窗所在屏的 scale，用来定输出像素
    func captureWindow(_ window: WindowInfo,
                       includeShadow: Bool,
                       backingScale: CGFloat) async throws -> CapturedImage
}

/// 当前可见窗口清单。抽成协议是为了让覆盖层的悬停命中能脱离真实 SCK 单测。
public protocol WindowListing: Sendable {
    /// 返回**前台到后台**顺序的窗口。失败时给空数组，不要抛 ——
    /// 覆盖层没有清单仍然可以拖选区，不能因为枚举失败就把截屏入口废掉。
    func listWindows() async -> [WindowInfo]
}

// MARK: - 剪贴板

/// 剪贴板写入。
public protocol ClipboardWriting: Sendable {
    /// 写入**原始 PNG 数据**。
    ///
    /// 不要改成"写 `NSImage`"：那条路依赖 scale 元数据，跨应用粘贴更容易退化成半分辨率
    /// （`docs/SPIKE-PLAN.md` F2/F3 已实测对比）。
    func writePNG(_ data: Data)

    /// 写入纯文本（ticket 10：复制像素色值，如 `#1A2B3C`）。
    ///
    /// 单独一个方法而不是"把色值包成 PNG"：粘到代码编辑器里要的是能直接用的
    /// 文本字面量，不是一张图。
    func writeText(_ string: String)
}

// MARK: - 显示器定位

/// 找到"当前该截哪块屏"。
///
/// 抽成协议是为了让编排逻辑能在没有真实屏幕的环境下单测；
/// 真实实现见 `App/Sources/SystemDisplayLocator.swift`。
public protocol DisplayLocating: Sendable {
    /// 鼠标指针所在的那块屏；找不到时返回 `nil`
    func displayUnderPointer() -> DisplayGeometry?

    /// 全部活动显示器（覆盖层要给每块屏都开一个面板、跨屏选区要逐屏取片）
    func allDisplays() -> [DisplayGeometry]
}

// MARK: - 计时

/// 单调时钟，单位秒。
///
/// 抽成协议纯粹是为了让耗时断言可复现（测试里给一个"每次调用 +0.02 秒"的假时钟），
/// 否则性能预算只能靠人工看日志。
public protocol MonotonicClock: Sendable {
    func now() -> Double
}

/// 真实时钟：`DispatchTime` 的 uptime，不受系统时间调整影响。
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}


/// 记录"最近截图"的接缝（ticket 16）。
///
/// ## 为什么协议在 Core、仓库在 `MarqueeHistory`
///
/// `CaptureOutput` 在 Core，它是那条"剪贴板 → 落盘 → 收尾"的编排者；
/// 而真正的仓库要碰文件系统与 `CGImage` 编码，属于实现层。
/// Core 不能反向依赖 `MarqueeHistory`（那会破坏"只有 Core 无依赖"这条模块规则），
/// 所以接缝留在 Core、实现留在 History —— 与 `ClipboardWriting` / `ScreenCapturing` 同一套做法。
public protocol CaptureHistoryWriting: Sendable {
    /// 记一条。**绝不抛错、也绝不因为失败中断截图** ——
    /// 历史丢了是小事，为此让用户拿不到图是大事。
    ///
    /// - Parameter originalPNG: 调用方**手上已经有**这张原图的 PNG 字节时传进来，
    ///   省掉一次编码。"没有标注"是最常见的情况，那时拍平后的图**就是**原图、
    ///   编码结果可以直接复用 —— 重新编码一张 2560×1600 要几十毫秒，
    ///   而这条路上每一毫秒都在"按下快捷键 → 能粘贴"的预算里。
    /// - Returns: 新条目的 id（记不下时为 `nil`）。
    @discardableResult
    func record(original: CGImage,
                originalPNG: Data?,
                annotations: [Annotation],
                at date: Date) -> UUID?
}

extension CaptureHistoryWriting {
    /// 手上没有现成 PNG 字节时用这个（它会自己编码一次）。
    @discardableResult
    public func record(original: CGImage, annotations: [Annotation], at date: Date) -> UUID? {
        record(original: original, originalPNG: nil, annotations: annotations, at: date)
    }
}

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
}

// MARK: - 剪贴板

/// 剪贴板写入。
public protocol ClipboardWriting: Sendable {
    /// 写入**原始 PNG 数据**。
    ///
    /// 不要改成"写 `NSImage`"：那条路依赖 scale 元数据，跨应用粘贴更容易退化成半分辨率
    /// （`docs/SPIKE-PLAN.md` F2/F3 已实测对比）。
    func writePNG(_ data: Data)
}

// MARK: - 显示器定位

/// 找到"当前该截哪块屏"。
///
/// 抽成协议是为了让编排逻辑能在没有真实屏幕的环境下单测；
/// 真实实现见 `App/Sources/SystemDisplayLocator.swift`。
public protocol DisplayLocating: Sendable {
    /// 鼠标指针所在的那块屏；找不到时返回 `nil`
    func displayUnderPointer() -> DisplayGeometry?
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

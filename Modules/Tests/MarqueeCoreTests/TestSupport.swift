import CoreGraphics
import Foundation
import MarqueeCore

// 测试替身与图像工具。所有采集/剪贴板/时钟/权限的替身都集中在这里，
// 免得每个测试文件各造一套、行为还悄悄不一致。

// MARK: - 图像工具

enum TestImage {

    /// 显式 sRGB。
    ///
    /// **不要**用 `CGColorSpaceCreateDeviceRGB()`：本机是 P3 屏，设备 RGB 就是 Display P3，
    /// 于是"纯红"读回来会是 (255, 38, 0)，颜色断言会变成碰运气。
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!
    }

    /// 纯色图
    static func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        makeContext(width: width, height: height) { context in
            context.setFillColor(color(red, green, blue))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 2×2 四色图：左上红、右上绿、左下蓝、右下白。
    ///
    /// 刻意做成上下左右都不同 —— 拼接时把 y 翻错、把行列搞反，一眼就能看出来。
    static func fourQuadrants() -> CGImage {
        makeContext(width: 2, height: 2) { context in
            // CGContext 的坐标系原点在左下
            context.setFillColor(color(1, 0, 0))
            context.fill(CGRect(x: 0, y: 1, width: 1, height: 1)) // 左上
            context.setFillColor(color(0, 1, 0))
            context.fill(CGRect(x: 1, y: 1, width: 1, height: 1)) // 右上
            context.setFillColor(color(0, 0, 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) // 左下
            context.setFillColor(color(1, 1, 1))
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1)) // 右下
        }
    }

    /// 棋盘格。纯色 JPEG 在高低质量下体积几乎一样，质量断言要用有细节的图。
    /// 棋盘格。`squareSize` 是每格边长（默认 1 像素）。
    ///
    /// 加这个参数是因为"细节量"的度量必须与要测的尺度匹配：
    /// 1 像素的棋盘在任何 ≥2 的块长下都会被平均成纯灰，用它测"块越大越糊"会什么都测不出来。
    static func checkerboard(width: Int, height: Int, squareSize: Int = 1) -> CGImage {
        let size = max(1, squareSize)
        return makeContext(width: width, height: height) { context in
            for y in 0..<height {
                for x in 0..<width {
                    let on = ((x / size) + (y / size)).isMultiple(of: 2)
                    context.setFillColor(color(on ? 1 : 0, on ? 0.15 : 0.85, on ? 0.4 : 0.1))
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }

    /// 顶部一条黑带、其余全白。**刻意不对称**。
    ///
    /// 用它而不是"上黑下白各一半"：那种图关于**水平中线镜像对称**，
    /// 上下翻转后与原图逐像素相同 —— 拿它测翻转等于什么都没测
    /// （这正是"纯色图看不出翻转"的变体，踩过一次）。
    static func topBandBlack(width: Int, height: Int, bandHeight: Int) -> CGImage {
        makeContext(width: width, height: height) { context in
            context.setFillColor(color(1, 1, 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // CG 用户空间 y 向上：想落在"自上而下 0..<bandHeight"行，需要 y = height - bandHeight
            context.setFillColor(color(0, 0, 0))
            context.fill(CGRect(x: 0, y: height - bandHeight, width: width, height: bandHeight))
        }
    }

    /// 上黑下白（上半 `0.5` 以上为黑）。
    ///
    /// 专用来抓"画进去的图被上下颠倒"这类错误：**纯色图上看不出翻转**，
    /// 这正是 `AnnotationRasterizer` 那个底图颠倒 bug 一直没被发现的原因。
    static func topBlackBottomWhite(width: Int, height: Int) -> CGImage {
        makeContext(width: width, height: height) { context in
            let half = height / 2
            context.setFillColor(color(0, 0, 0))
            context.fill(CGRect(x: 0, y: half, width: width, height: height - half))
            context.setFillColor(color(1, 1, 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: half))
        }
    }

    /// 读像素。**以左上角为原点**（y 向下），与 `targetPixelRect` 同一空间。
    ///
    /// 两条实测出来的硬约束（都踩过）：
    /// 1. 内存第 0 行就是图像**顶**行，所以 `y * stride + x` 直接可用，不需要翻
    /// 2. `bytesPerRow` 必须对齐（取 16 的倍数）。给 `width * 4` 这种未对齐的值时，
    ///    窄图（如 2 px 宽 = 8 字节）会读出整行垃圾且**不报错**
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let width = image.width
        let height = image.height
        let bytesPerRow = max(16, ((width * 4) + 15) / 16 * 16)
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let stride = bytesPerRow / 4
        let index = (y * stride + x) * 4
        return (buffer[index], buffer[index + 1], buffer[index + 2])
    }

    /// 颜色比较。sRGB 上往返是精确的，留一点容差只为防止插值边缘的舍入
    static func matches(_ pixel: (red: UInt8, green: UInt8, blue: UInt8),
                        red: CGFloat, green: CGFloat, blue: CGFloat,
                        tolerance: Int = 2) -> Bool {
        func close(_ value: UInt8, _ expected: CGFloat) -> Bool {
            abs(Int(value) - Int((expected * 255).rounded())) <= tolerance
        }
        return close(pixel.red, red) && close(pixel.green, green) && close(pixel.blue, blue)
    }

    private static func makeContext(width: Int,
                                    height: Int,
                                    _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }
}

// MARK: - 锁工具

/// 显式加解锁。
///
/// 不用 `NSLock.withLock`：它的闭包在新 SDK 里带了并发标注，
/// 而这里的替身需要就地改自己的存储属性，用显式锁最不容易踩到编译器的隔离检查。
func withLocked<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

// MARK: - 权限探针

/// 可控的权限探针。真实 TCC 状态无法在测试里摆布，这正是把它抽成协议的原因。
final class FakePermissionProbe: ScreenRecordingPermissionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: ScreenRecordingPermission
    private var storedGrantsOnRequest: Bool
    private var storedRequestCount = 0

    init(status: ScreenRecordingPermission, grantsOnRequest: Bool = false) {
        storedStatus = status
        storedGrantsOnRequest = grantsOnRequest
    }

    var status: ScreenRecordingPermission {
        get { withLocked(lock) { storedStatus } }
        set { withLocked(lock) { storedStatus = newValue } }
    }

    var grantsOnRequest: Bool {
        get { withLocked(lock) { storedGrantsOnRequest } }
        set { withLocked(lock) { storedGrantsOnRequest = newValue } }
    }

    var requestCount: Int { withLocked(lock) { storedRequestCount } }

    func currentPermission() -> ScreenRecordingPermission { status }

    func requestPermission() async -> Bool {
        withLocked(lock) {
            storedRequestCount += 1
            if storedGrantsOnRequest {
                storedStatus = .granted
                return true
            }
            // 与真实探针对齐：问过一次还没过，后续就按 denied 走，
            // 否则 CaptureGate 会把每次快捷键都当成"还没问过"再弹系统框。
            storedStatus = .denied
            return false
        }
    }
}

// MARK: - 采集器

/// 采集错误替身。刻意不用 `MarqueeCapture.CaptureError`：Core 的测试不该依赖实现模块。
struct StubCaptureError: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// 采集器替身：记录每次调用的矩形与屏，按请求的像素尺寸返回一张纯色图。
actor RecordingCapturer: ScreenCapturing {

    struct Call: Equatable, Sendable {
        let rect: CGRect
        let displayID: UInt32
    }

    private(set) var regionCalls: [Call] = []
    private(set) var fullScreenCalls: [Call] = []
    private(set) var windowCalls: [WindowCall] = []
    private var failure: StubCaptureError?

    struct WindowCall: Equatable, Sendable {
        let windowID: UInt32
        let includeShadow: Bool
        let backingScale: CGFloat
    }

    init(failure: StubCaptureError? = nil) {
        self.failure = failure
    }

    func setFailure(_ failure: StubCaptureError?) {
        self.failure = failure
    }

    func captureFullScreen(_ display: DisplayGeometry) async throws -> CapturedImage {
        fullScreenCalls.append(Call(rect: display.frame, displayID: display.displayID))
        if let failure { throw failure }
        return makeImage(for: display, pixelSize: display.pixelSize)
    }

    func captureRegion(_ rect: CGRect, on display: DisplayGeometry) async throws -> CapturedImage {
        regionCalls.append(Call(rect: rect, displayID: display.displayID))
        if let failure { throw failure }
        return makeImage(for: display, pixelSize: display.pixelRect(for: rect).size)
    }

    func captureWindow(_ window: WindowInfo,
                       includeShadow: Bool,
                       backingScale: CGFloat) async throws -> CapturedImage {
        windowCalls.append(WindowCall(windowID: window.windowID,
                                      includeShadow: includeShadow,
                                      backingScale: backingScale))
        if let failure { throw failure }
        let pixelSize = CGSize(width: max(1, (window.frame.width * backingScale).rounded()),
                               height: max(1, (window.frame.height * backingScale).rounded()))
        let image = TestImage.solid(width: Int(pixelSize.width),
                                    height: Int(pixelSize.height),
                                    red: includeShadow ? 1 : 0,
                                    green: includeShadow ? 0 : 1,
                                    blue: 0)
        return CapturedImage(image: image, displayID: 1, backingScale: backingScale)
    }

    /// 2x 屏给红、1x 屏给蓝，方便断言"哪一片画到了哪"
    private func makeImage(for display: DisplayGeometry, pixelSize: CGSize) -> CapturedImage {
        let isRetina = display.backingScale > 1
        let image = TestImage.solid(width: max(1, Int(pixelSize.width)),
                                    height: max(1, Int(pixelSize.height)),
                                    red: isRetina ? 1 : 0,
                                    green: 0,
                                    blue: isRetina ? 0 : 1)
        return CapturedImage(image: image,
                             displayID: display.displayID,
                             backingScale: display.backingScale)
    }
}

// MARK: - 剪贴板

final class FakeClipboard: ClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    private var storedTexts: [String] = []

    var written: [Data] { withLocked(lock) { stored } }
    var writtenTexts: [String] { withLocked(lock) { storedTexts } }

    func writePNG(_ data: Data) {
        withLocked(lock) { stored.append(data) }
    }

    func writeText(_ string: String) {
        withLocked(lock) { storedTexts.append(string) }
    }
}

// MARK: - 显示器

struct FakeDisplays: DisplayLocating {
    let all: [DisplayGeometry]
    let pointer: DisplayGeometry?

    init(all: [DisplayGeometry], pointer: DisplayGeometry? = nil) {
        self.all = all
        self.pointer = pointer ?? all.first
    }

    func displayUnderPointer() -> DisplayGeometry? { pointer }

    func allDisplays() -> [DisplayGeometry] { all }
}

// MARK: - 时钟

/// 每次调用返回一个递增的假时间，让耗时断言可复现。
///
/// 步长取 0.125 秒（= 1/8，二进制可精确表示）而不是 0.02：
/// 0.02 不是精确的二进制小数，`(100.02 - 100.00) * 1000` 会得到 19.999999999996，
/// 断言相等就会假报失败。
final class FakeClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    private let step: Double

    init(start: Double = 100, step: Double = 0.125) {
        self.value = start
        self.step = step
    }

    func now() -> Double {
        withLocked(lock) {
            let current = value
            value += step
            return current
        }
    }
}

// MARK: - 常用屏

enum TestDisplays {
    /// 1440×900 @2x 主屏
    static let retina = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        backingScale: 2,
                                        displayID: 1)
    /// 1920×1080 @1x，挂在主屏右侧
    static let plainRight = DisplayGeometry(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                            backingScale: 1,
                                            displayID: 2)
}

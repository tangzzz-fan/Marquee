import CoreGraphics
import Foundation

// MARK: - 接缝

/// 两帧之间的竖直位移。
///
/// **符号约定（已实测钉死，别改）**：`rows` 为正数 = 视口向下滚了 `rows` 行，
/// 也就是画面内容向上移动了 `rows` 行。
///
/// 验证方式见 `MarqueeCaptureTests.VisionScrollRegistrarTests` 的装置自检：
/// 用已知位移的合成页取两帧，像素真值给 +600，Vision 给 ty = +600.0。
///
/// > 踩坑记录：`VNTranslationalImageRegistrationRequest(targetedCGImage: 上一帧)`
/// > 配 `VNImageRequestHandler(cgImage: 当前帧)` 时 **ty 就是自顶向下位移**，
/// > 不需要按"Vision 原点在左下"的说法取负。取负会让所有位移变成负值，
/// > 表现为"拼接高度只有一屏、没有任何新内容"，不崩不报错。
public struct ScrollShift: Equatable, Sendable {
    /// 位移行数，允许小数（亚像素）
    public let rows: Double
    /// 0...1 的置信度，用于决定"这一帧能不能信"
    public let confidence: Double

    public init(rows: Double, confidence: Double = 1) {
        self.rows = rows
        self.confidence = confidence
    }
}

public enum ScrollRegistrationFailure: Error, Equatable, Sendable {
    /// 相邻两帧几乎没有重叠，谈位移没有意义
    case notEnoughOverlap(rows: Double)
    /// 配准跑完了但结果不可信（置信度不足）
    case unreliable(String)
    /// 配准本身失败（框架抛错、拿不到观测值）
    case failed(String)

    public var localizedDescription: String {
        switch self {
        case .notEnoughOverlap(let rows):
            "这一帧滚动幅度过大（\(Int(rows.rounded())) 行），与前帧几乎不重叠，没法对齐"
        case .unreliable(let detail):
            "这一帧没对齐：\(detail)"
        case .failed(let detail):
            "配准失败：\(detail)"
        }
    }
}

/// 相邻帧配准。
///
/// 抽成协议的理由与其它接缝一致：`ScrollCaptureSession` 的编排（什么时候追加、
/// 什么时候判定到底、什么时候停下来报警）必须能脱机单测。
/// 真实实现走 Vision（`MarqueeCapture.VisionScrollRegistrar`）。
public protocol ScrollFrameRegistering: Sendable {
    /// - Returns: 从 `previous` 到 `current` 的内容位移；正数 = 向下滚动
    /// - Throws: `ScrollRegistrationFailure`
    func register(previous: CGImage, current: CGImage) async throws -> ScrollShift
}

// MARK: - 阈值策略

/// 一帧该怎么办。由 `ScrollRegistrationPolicy` 判定，会话只执行。
public enum ScrollFrameVerdict: Equatable, Sendable {
    /// 有新增内容，追加 `rows` 行
    case append(rows: Double)
    /// 基本没动 —— 到底了，或者用户停手了
    case stationary(rows: Double)
    /// 滚动幅度太大，与前帧没有足够重叠，无法对齐
    case noOverlap(rows: Double)
}

/// 判定阈值。集中在一处，便于按真实场景调（这些值都会在人工验收里被现实检验）。
public struct ScrollRegistrationPolicy: Equatable, Sendable {
    /// 小于这个位移视为"没动"。1.5 行给亚像素配准的抖动留余量。
    public var minimumScrollRows: Double
    /// 至少要有多少行重叠才认这次配准
    public var minimumOverlapRows: Int
    /// 连续多少帧判定"没动"就认为滚到底
    public var stationaryFramesBeforeStop: Int
    /// 连续多少帧配准失败就停下来提示用户，而不是继续堆积错图
    public var failuresBeforeStall: Int
    /// 低于这个置信度视为不可信
    public var minimumConfidence: Double

    public init(minimumScrollRows: Double = 1.5,
                minimumOverlapRows: Int = 48,
                stationaryFramesBeforeStop: Int = 3,
                failuresBeforeStall: Int = 3,
                minimumConfidence: Double = 0.15) {
        self.minimumScrollRows = minimumScrollRows
        self.minimumOverlapRows = minimumOverlapRows
        self.stationaryFramesBeforeStop = stationaryFramesBeforeStop
        self.failuresBeforeStall = failuresBeforeStall
        self.minimumConfidence = minimumConfidence
    }

    public static let `default` = ScrollRegistrationPolicy()

    /// 判定一帧。
    ///
    /// 判定顺序刻意是「先看有没有重叠 → 再看动没动」：
    /// 位移极大时也可能被误判成"没动"（不重叠区域全黑/全白时配准会退化成 0），
    /// 所以重叠检查必须在前。
    public func verdict(for shift: ScrollShift, frameHeight: Int) -> ScrollFrameVerdict {
        let rows = shift.rows
        let maximumRows = Double(frameHeight - minimumOverlapRows)
        if rows > maximumRows {
            return .noOverlap(rows: rows)
        }
        if rows < minimumScrollRows {
            return .stationary(rows: rows)
        }
        return .append(rows: rows)
    }
}

// MARK: - 兜底实现

/// 恒定位移的替身配准器。只用在一个地方：**合成装置的装置自检**。
///
/// 它让「累计位移 → 排布 → 渲染」这条链路能在完全不碰 Vision 的情况下被断言，
/// 从而把"拼接公式错了"和"配准错了"这两类问题分开定位 ——
/// 这两者症状一模一样（长图错位），混在一起排查会非常慢。
public struct FixedShiftRegistrar: ScrollFrameRegistering {
    private let rows: Double

    public init(rows: Double) {
        self.rows = rows
    }

    public func register(previous: CGImage, current: CGImage) async throws -> ScrollShift {
        ScrollShift(rows: rows)
    }
}

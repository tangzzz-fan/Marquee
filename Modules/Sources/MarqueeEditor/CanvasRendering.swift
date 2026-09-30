import CoreGraphics
import MarqueeCore

/// 编辑器模块：文档模型、标注对象、撤销栈、SwiftUI Canvas 画布。
///
/// 归属 ticket：07（对象模型）、08（文字/箭头/画笔/序号）、09（马赛克/裁切）、13（OCR）、14（钉图）。
///
/// 画布后端边界。首期**只有 SwiftUI Canvas 一个实现**（实测依据见 `docs/RENDER-BENCH.md`：
/// 真实标注量级下 Canvas 0.08 ms/帧，比 Metal 更快，因为 Metal 每帧有固定的提交流水线开销）。
///
/// 保留这个协议不是为了"将来可能要换"，而是因为已经写明了推翻当前结论的**触发条件**：
/// 单文档常态超过 5000 个标注对象，或需要逐像素实时效果（液化、自由形变）。
/// 到那时新增一个 Metal 实现即可，上层不动。
public protocol CanvasRendering: Sendable {
    /// 后端标识，用于性能日志与基准对照
    static var backendName: String { get }
}

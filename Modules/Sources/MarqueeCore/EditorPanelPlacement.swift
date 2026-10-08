import CoreGraphics
import Foundation

/// 编辑器里**浮在画布上的那张纸**（识别文字面板）该落在哪。
///
/// ## 为什么是"纸"而不是侧栏
///
/// 设计稿的判断 5：侧栏会**永久吃掉 260 宽**，而画布宽度是这扇窗存在的全部理由。
/// 识别结果只是"顺手看一眼"的东西，所以它是一张**默认贴右下角、可以拖走、可以关掉**的纸。
///
/// ## 为什么几何要进 Core
///
/// "拖到哪算越界"是纯几何，而它的失败长相是**面板被拖出窗口** ——
/// 那是一条**有去无回**的路：`✕` 也在被拖出去的那一半上，
/// 用户唯一的出口是关掉整扇窗（丢掉刚画的标注）。这种错不该靠手拖去发现。
public enum EditorPanelPlacement {

    /// 距画布右下角的距离。稿子 §07：「距右下 16」。
    public static let inset: CGFloat = 16

    /// 默认位置：**右下角**。
    ///
    /// 为什么是右下：长图阅读时目光最少停留的角（稿子 §04）——
    /// 面板挡住的永远是"可以再挪一下"的东西，而右下通常不是正文的起点。
    ///
    /// ⚠️ **它走的是同一个 `clamp`**，不是另算一套。画布比面板还小时，
    /// `width - panel - inset` 会算出负数 —— 而那正是"面板一半在窗口外"的成因。
    public static func defaultOrigin(panel: CGSize, canvas: CGSize) -> CGPoint {
        clamp(origin: CGPoint(x: canvas.width - panel.width - inset,
                              y: canvas.height - panel.height - inset),
              panel: panel,
              canvas: canvas)
    }

    /// 把面板整体夹进画布：**四条边都不许出去**。
    ///
    /// 夹完之后 `origin` 与 `panel` 构成的矩形完整落在 `(0, 0, canvas)` 里；
    /// 画布小于面板时返回 `(0, 0)`（宁可"面板盖满画布"，也不许半个面板在窗口外）。
    public static func clamp(origin: CGPoint, panel: CGSize, canvas: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, origin.x), max(0, canvas.width - panel.width)),
                y: min(max(0, origin.y), max(0, canvas.height - panel.height)))
    }

    /// 拖动：从 `start` 起按 `translation` 走，再夹一次。
    ///
    /// 按"起点 + 位移"算而不是按"上一帧 + 增量"：后者在夹取之后会把
    /// "被吃掉的那一段"累进下一次移动，表现是**面板越拖越贴边、再也拽不回来**。
    public static func dragged(from start: CGPoint,
                               by translation: CGSize,
                               panel: CGSize,
                               canvas: CGSize) -> CGPoint {
        clamp(origin: CGPoint(x: start.x + translation.width,
                              y: start.y + translation.height),
              panel: panel,
              canvas: canvas)
    }
}

import CoreGraphics
import Foundation
import Testing

@testable import MarqueeCore

/// 编辑器里那张**浮着的纸**（识别文字面板）该落在哪。
///
/// ## 为什么这件事要进 Core
///
/// 面板是"可以挪走的纸"（设计稿 §04/§07）：默认贴右下角、拖走之后**必须还在画布内**。
/// 而"拖到哪算越界"是纯几何 —— 放在视图里就只能靠手拖去试，
/// 而它的失败长相是**面板被拖出窗口、再也点不到**（尤其那枚 `✕`），
/// 那是一条**有去无回**的路：没有别的入口能把它拿回来。
@Suite("编辑器浮层的位置（识别面板）")
struct EditorPanelPlacementTests {

    /// 画布（= 窗口 1200 × 760 减掉工具条 48 与状态行 22）。
    private let canvas = CGSize(width: 1200, height: 690)
    /// 面板：稿子「260 宽 · 高 90–172」，这里取中段。
    private let panel = CGSize(width: 260, height: 120)

    @Test("默认落**右下角**，距右下各 16")
    func defaultSitsBottomTrailing() {
        let origin = EditorPanelPlacement.defaultOrigin(panel: panel, canvas: canvas)
        #expect(origin.x == canvas.width - panel.width - EditorPanelPlacement.inset)
        #expect(origin.y == canvas.height - panel.height - EditorPanelPlacement.inset)
        #expect(EditorPanelPlacement.inset == 16)

        // 为什么是右下角：长图阅读时目光最少停留的角（稿子 §04）。
        // 换句话说它必须在**右下那一半**，不是在中间 —— 中间正好压着正文。
        #expect(origin.x > canvas.width / 2, "默认位置没有偏右：\(origin)")
        #expect(origin.y > canvas.height / 2, "默认位置没有偏下：\(origin)")
    }

    @Test("拖走之后必须**整体**留在画布内")
    func clampKeepsWholePanelInside() {
        // 往右下拖出去
        let clamped = EditorPanelPlacement.clamp(origin: CGPoint(x: 5000, y: 5000),
                                                 panel: panel,
                                                 canvas: canvas)
        #expect(clamped == CGPoint(x: canvas.width - panel.width,
                                   y: canvas.height - panel.height))
        // 往左上拖出去
        #expect(EditorPanelPlacement.clamp(origin: CGPoint(x: -300, y: -80),
                                           panel: panel,
                                           canvas: canvas) == .zero)
        // 已经在里面 → 一点都不许动（拖拽跟手的唯一保证）
        let inside = CGPoint(x: 40, y: 60)
        #expect(EditorPanelPlacement.clamp(origin: inside, panel: panel, canvas: canvas) == inside)
    }

    @Test("画布比面板还小时给 (0,0)，不许出现负坐标")
    func clampWithTinyCanvas() {
        // 窗口被拉到下限以下（理论上被 `minSize` 挡住，但判据不许依赖那个前提）：
        // 负坐标的表现是"面板有一半在窗口外"，而用户看到的是**面板被切掉了**。
        let tiny = CGSize(width: 100, height: 60)
        let origin = EditorPanelPlacement.clamp(origin: CGPoint(x: 30, y: 20),
                                                panel: panel,
                                                canvas: tiny)
        #expect(origin == .zero)
    }

    @Test("**默认位置本身就是夹取之后的结果** —— 两条路不许各算一遍")
    func defaultGoesThroughSameClamp() {
        // 这条是给未来的路障：默认位置若自己写一套 `width - panel - 16`，
        // 画布一小就会算出负数，而"夹取"那条路是对的 —— 两边分叉只在画布很小时才现形。
        let tiny = CGSize(width: 200, height: 100)
        let viaDefault = EditorPanelPlacement.defaultOrigin(panel: panel, canvas: tiny)
        #expect(viaDefault.x >= 0 && viaDefault.y >= 0, "默认位置算出了负坐标：\(viaDefault)")

        // 与"把右下角那个点夹一遍"必须一致
        let naive = CGPoint(x: tiny.width - panel.width - EditorPanelPlacement.inset,
                            y: tiny.height - panel.height - EditorPanelPlacement.inset)
        #expect(viaDefault == EditorPanelPlacement.clamp(origin: naive, panel: panel, canvas: tiny))
    }

    @Test("拖动 = 起点 + 位移，再夹一次")
    func dragAppliesClamp() {
        let start = CGPoint(x: 800, y: 400)
        // 小幅移动：原样跟手
        #expect(EditorPanelPlacement.dragged(from: start,
                                             by: CGSize(width: 12, height: -30),
                                             panel: panel,
                                             canvas: canvas)
                == CGPoint(x: 812, y: 370))
        // 大幅移动：被夹在画布内，而不是跑到外面
        let far = EditorPanelPlacement.dragged(from: start,
                                              by: CGSize(width: 900, height: 900),
                                              panel: panel,
                                              canvas: canvas)
        #expect(far == CGPoint(x: canvas.width - panel.width, y: canvas.height - panel.height))
    }
}

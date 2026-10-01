import CoreGraphics
import Foundation
import MarqueeCore
import Testing

/// 覆盖层浮动工具栏的**位置计算**（ticket 20）。
///
/// 为什么把这个小计算单独抽出来测：贴边、翻面、跨屏这几种情况**靠肉眼试不全**，
/// 而一旦算错，表现是"工具栏跑出屏幕了"或"它盖住了选区" ——
/// 用户只会说"那个条没了"，不会告诉你它跑到哪去了。
@Suite("覆盖层工具栏位置")
struct OverlayToolbarTests {

    /// 1440×900 的主屏（Cocoa 全局点，y 向上）
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = OverlayToolbar.toolbarSize

    // MARK: - 默认位置

    @Test("默认贴在选区**下方**，且与选区左对齐")
    func sitsBelowSelection() {
        let selection = CGRect(x: 400, y: 400, width: 300, height: 200)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(bar.maxY <= selection.minY, "Cocoa 坐标 y 向上，『下方』指 y 更小")
        #expect(bar.minX == selection.minX, "默认与选区左边缘对齐")
    }

    @Test("永远不遮选区 —— 这是「不阻断」的前提")
    func neverCoversSelection() {
        let selections = [
            CGRect(x: 400, y: 400, width: 300, height: 200),
            CGRect(x: 100, y: 100, width: 200, height: 150),   // 贴左下
            CGRect(x: 1000, y: 700, width: 300, height: 150),  // 贴右上
            CGRect(x: 600, y: 20, width: 400, height: 300),    // 贴下边
            CGRect(x: 600, y: 580, width: 400, height: 300),   // 贴上边
        ]

        for selection in selections {
            let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)
            #expect(!bar.intersects(selection),
                    "选区 \(selection) 的工具栏 \(bar) 盖住了它")
        }
    }

    // MARK: - 翻面

    @Test("选区贴到屏幕底边时，工具栏翻到**上方**")
    func flipsAboveWhenNoRoomBelow() {
        // 选区底边离屏底只有 20 点，放不下 44 高的工具栏
        let selection = CGRect(x: 400, y: 20, width: 300, height: 200)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(bar.minY >= selection.maxY, "下方放不下就该翻到上方")
        #expect(!bar.intersects(selection))
    }

    @Test("上下都放不下（选区几乎占满屏）时，仍然完整留在屏幕内")
    func staysOnScreenWhenSelectionIsHuge() {
        let selection = screen.insetBy(dx: 4, dy: 4)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(screen.contains(bar), "工具栏不能被推出屏幕：\(bar)")
        #expect(bar.width == size.width)
        #expect(bar.height == size.height)
    }

    // MARK: - 水平夹取

    @Test("选区贴左边缘：工具栏不越出屏幕左侧")
    func clampsAtLeadingEdge() {
        let selection = CGRect(x: 0, y: 400, width: 200, height: 150)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(bar.minX >= screen.minX)
        #expect(screen.contains(bar))
    }

    @Test("选区贴右边缘：工具栏不越出屏幕右侧")
    func clampsAtTrailingEdge() {
        let selection = CGRect(x: 1240, y: 400, width: 200, height: 150)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(bar.maxX <= screen.maxX, "工具栏被推到屏幕外了：\(bar)")
    }

    // MARK: - 多屏

    @Test("副屏（屏幕原点不是 0,0）上同样成立")
    func worksOnSecondaryDisplay() {
        // 挂在主屏右侧的副屏
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 1500, y: 100, width: 300, height: 200)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: second)

        #expect(second.contains(bar), "工具栏应当留在**它所在的那块屏**上：\(bar)")
        #expect(bar.maxY <= selection.minY, "空间够时仍应贴在下方")
    }

    @Test("屏幕可见区比工具栏还矮时也不崩（夹取顺序不能反）")
    func survivesTinyScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 30)
        let selection = CGRect(x: 10, y: 10, width: 50, height: 10)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: tiny)

        #expect(bar.width == size.width, "尺寸不该被改")
        #expect(bar.height == size.height)
    }

    // MARK: - 尺寸约定

    @Test("每个按钮都落在工具条内、彼此不重叠 —— 绘制与命中必须用同一套推导")
    func buttonsFitInsideToolbar() {
        let toolbar = CGRect(origin: .zero, size: OverlayToolbar.toolbarSize)
        let frames = OverlayToolbar.Button.allCases.map { OverlayToolbar.hitFrame(of: $0, in: toolbar) }

        for frame in frames {
            #expect(toolbar.contains(frame), "按钮 \(frame) 超出了工具条 \(toolbar)")
        }
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(!previous.intersects(next), "按钮重叠：\(previous) 与 \(next)")
        }
        // 从左到右的语义顺序也要对：edit 在最左，confirm 在最右
        #expect(frames[0].minX < frames[1].minX)
        #expect(frames[1].minX < frames[2].minX)
    }

    @Test("命中测试：点在各按钮中心能认出来，点在空隙上认不出来")
    func hitTestPicksTheRightButton() {
        let toolbar = OverlayToolbar.frame(for: CGRect(x: 400, y: 400, width: 300, height: 200),
                                           screenFrame: screen)

        for button in OverlayToolbar.Button.allCases {
            let frame = OverlayToolbar.hitFrame(of: button, in: toolbar)
            #expect(OverlayToolbar.button(at: CGPoint(x: frame.midX, y: frame.midY), in: toolbar) == button)
        }
        // 工具条内部、但落在按钮之间的空隙上
        let gap = CGPoint(x: toolbar.midX, y: toolbar.minY + 3)
        #expect(OverlayToolbar.button(at: gap, in: toolbar) == nil)
        // 工具条之外
        #expect(OverlayToolbar.button(at: CGPoint(x: toolbar.maxX + 20, y: toolbar.midY), in: toolbar) == nil)
    }

    @Test("工具栏尺寸是给绘图层与命中测试共用的同一份常量")
    func sizeIsShared() {
        // 这条看着像废话，但它钉住的是"视图画的框"与"Core 算的框"用的是同一个数 ——
        // 两边各写一份的话，命中测试会偏出去几个点，表现是"按钮点不准"。
        #expect(OverlayToolbar.toolbarSize.width > 0)
        #expect(OverlayToolbar.toolbarSize.height > 0)
        #expect(OverlayToolbar.buttonSize < OverlayToolbar.toolbarSize.height)
    }
}

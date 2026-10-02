import Foundation
import Testing

@testable import MarqueeCore

/// 升级卡片的几何与入口映射（ticket 31 界面收尾）。
///
/// 这一套守的是两类"看着没事、其实很糟"的错：
/// **卡片跑到屏幕外面**（用户只会说"那东西没出来"）与
/// **入口映射漏了一格**（表现是某一格在免费版里照样能用）。
@Suite("升级卡片的几何与入口映射")
struct ProCardLayoutTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - 尺寸与内部布局

    @Test("卡片内部几块都在卡片里，两个按钮不重叠且主按钮在右")
    func contentFitsInsideCard() {
        let card = CGRect(origin: .zero, size: ProCardLayout.size)
        let c = ProCardLayout.content(in: card)

        for (label, rect) in [("标题", c.title), ("正文", c.body),
                              ("主按钮", c.primary), ("次按钮", c.secondary)] {
            #expect(card.contains(rect), "\(label) 跑到卡片外面了")
        }
        #expect(!c.primary.intersects(c.secondary), "两个按钮叠在一起了")
        #expect(!c.title.intersects(c.body), "标题压在正文上")
        #expect(!c.body.intersects(c.primary), "正文压在按钮上")

        // macOS 的惯例：主按钮在右。
        #expect(c.primary.minX > c.secondary.minX)
        #expect(c.primary.minX >= c.secondary.maxX, "两个按钮之间没留间距")
    }

    @Test("两个按钮等宽，且左右都留了内边距")
    func buttonsAreSymmetric() {
        let card = CGRect(origin: .zero, size: ProCardLayout.size)
        let c = ProCardLayout.content(in: card)

        #expect(abs(c.primary.width - c.secondary.width) < 0.001)
        #expect(abs(c.secondary.minX - ProCardLayout.padding) < 0.001)
        #expect(abs((card.maxX - c.primary.maxX) - ProCardLayout.padding) < 0.001)
    }

    // MARK: - 命中

    @Test("点按钮中心能命中，并且返回的是**角色对应的那个动作**")
    func hitTestsResolveToTheRightAction() {
        let card = CGRect(x: 500, y: 300, width: ProCardLayout.size.width, height: ProCardLayout.size.height)
        let buttons = ProCardContent(feature: .textRecognition,
                                     reason: .neverPurchased,
                                     primary: .startTrial,
                                     secondary: .purchase)
        let c = ProCardLayout.content(in: card)

        let primaryCenter = CGPoint(x: card.minX + c.primary.midX, y: card.minY + c.primary.midY)
        let secondaryCenter = CGPoint(x: card.minX + c.secondary.midX, y: card.minY + c.secondary.midY)

        #expect(ProCardLayout.action(at: primaryCenter, in: card, buttons: buttons) == .startTrial)
        #expect(ProCardLayout.action(at: secondaryCenter, in: card, buttons: buttons) == .purchase)
    }

    @Test("点正文与卡片外都不算按钮 —— 卡片其余部分不接受点击")
    func nonButtonAreasAreInert() {
        let card = CGRect(x: 500, y: 300, width: ProCardLayout.size.width, height: ProCardLayout.size.height)
        let buttons = ProCardContent(feature: .pin,
                                     reason: .trialEnded,
                                     primary: .purchase,
                                     secondary: .restore)
        let c = ProCardLayout.content(in: card)

        let bodyCenter = CGPoint(x: card.minX + c.body.midX, y: card.minY + c.body.midY)
        #expect(ProCardLayout.action(at: bodyCenter, in: card, buttons: buttons) == nil)

        // 空白处不该关掉卡片，更不该误触某个按钮 ——
        // 手抖一下变成"买了"，是这里最贵的错误。
        #expect(ProCardLayout.action(at: CGPoint(x: 10, y: 10), in: card, buttons: buttons) == nil)
    }

    // MARK: - 位置

    @Test("屏幕下方有地方时，卡片弹在工具条下面并水平居中")
    func sitsBelowWhenThereIsRoom() {
        let toolbar = CGRect(x: 400, y: 500, width: 545, height: 40)
        let card = ProCardLayout.frame(toolbar: toolbar, screenFrame: screen)

        #expect(card.maxY < toolbar.minY, "卡片应该在工具条下方")
        #expect(abs(card.midX - toolbar.midX) < 0.001, "应该水平居中于工具条")
        #expect(card.width == ProCardLayout.width)
    }

    @Test("工具条贴着屏幕底部时，卡片翻到上面 —— 不能有一半在屏幕外")
    func flipsAboveWhenBottomIsTight() {
        let toolbar = CGRect(x: 400, y: 30, width: 545, height: 40)
        let card = ProCardLayout.frame(toolbar: toolbar, screenFrame: screen)

        #expect(card.minY > toolbar.maxY, "放不下就该翻到工具条上方")
        #expect(screen.contains(card), "翻面之后仍然必须完整在屏幕里")
    }

    @Test("屏幕小到两边都放不下时，夹进屏幕而不是露在外面")
    func clampsIntoSmallScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 200)
        let toolbar = CGRect(x: 100, y: 100, width: 200, height: 40)
        let card = ProCardLayout.frame(toolbar: toolbar, screenFrame: tiny)

        #expect(tiny.contains(card), "夹取必须最后做，否则卡片会露在屏幕外")
        #expect(card.minX >= tiny.minX + ProCardLayout.screenMargin - 0.001)
        #expect(card.maxY <= tiny.maxY - ProCardLayout.screenMargin + 0.001)
    }

    // MARK: - 入口映射

    @Test("工具栏格到 Pro 能力的映射：识别文字与钉图各归各的")
    func toolbarSlotsMapToFeatures() {
        #expect(OverlayToolbarSlot.ocr.proFeature == .textRecognition)
        #expect(OverlayToolbarSlot.pin.proFeature == .pin)
    }

    @Test("免费的格子一个都不能被映射成 Pro —— 否则免费版会平白锁掉功能")
    func freeSlotsHaveNoFeature() {
        let free: [OverlayToolbarSlot] = [
            .tool(.rectangle), .tool(.emoji), .style,
            .undo, .redo, .save, .cancel, .confirm,
        ]
        for slot in free {
            #expect(slot.proFeature == nil, "\(slot) 不该被当成 Pro 入口")
        }
    }
}

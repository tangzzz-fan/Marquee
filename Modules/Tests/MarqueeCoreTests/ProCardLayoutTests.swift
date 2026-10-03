import Foundation
import Testing

@testable import MarqueeCore

/// 升级卡片的几何与入口映射（ticket 31 · 2026-10-04 对齐稿子）。
///
/// 这一套守的是三类"看着没事、其实很糟"的错：
/// **卡片跑到屏幕外面**（用户只会说"那东西没出来"）、
/// **卡片压住选区**（用户要截的东西被它盖住），
/// 以及**入口映射漏了一格**（表现是某一格在免费版里照样能用）。
///
/// 数字全部来自稿子 `docs/design/2026-10-03-引导与升级卡片/pro-upgrade-card.html`：
/// 五个槽、两条高度（140 / 115）、以及那句「卡片左缘 = 工具条外缘 + 8 pt」。
@Suite("升级卡片的几何与入口映射")
struct ProCardLayoutTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// 量好的宽度：主按钮 96 / 次按钮 72 / 键帽 22（稿子 §01 表里那几个示意值）。
    private let measures = ProCardLayout.Measures(primaryButtonWidth: 96,
                                                  secondaryButtonWidth: 72,
                                                  escKeyCapWidth: 22)

    private func card(includesMicro: Bool = true) -> CGRect {
        CGRect(origin: .zero, size: ProCardLayout.size(includesMicro: includesMicro))
    }

    private func layout(includesMicro: Bool = true) -> ProCardLayout.Content {
        ProCardLayout.content(in: card(includesMicro: includesMicro),
                              includesMicro: includesMicro,
                              measures: measures)
    }

    // MARK: - 两条高度：同一行加法

    @Test("载体 A 140 / 载体 B 115，而两者只差**微行那一档**")
    func twoHeightsComeFromOneSum() {
        // 稿子把两个数写成同一行加法：
        //   16 + 18 + 6 + 18 + 17 + 24 [ + 11 + 14 ] + 16
        // 下面把**每一档都钉成字面值**。这不是洁癖 —— 算式写成
        // `padding + head + …` 那种形式的话，它只在"实现与它自己一致"时成立，
        // 改了某一档而没改测试，断言还是绿的（PITFALLS 156）。
        #expect(ProCardLayout.padding == 16)
        #expect(ProCardLayout.headHeight == 18)
        #expect(ProCardLayout.headBodyGap == 6)
        #expect(ProCardLayout.bodyHeight == 18)
        #expect(ProCardLayout.bodyButtonGap == 17)
        #expect(ProCardLayout.buttonHeight == 24)
        #expect(ProCardLayout.buttonMicroGap == 11)
        #expect(ProCardLayout.microHeight == 14)
        #expect(ProCardLayout.width == 300)

        #expect(ProCardLayout.height(includesMicro: true) == 140, "载体 A")
        #expect(ProCardLayout.height(includesMicro: false) == 115, "载体 B")

        // 两者之差**必须正好**是微行那一档（11 的间距 + 14 的行高 = 25）。
        // 少了这条，"顺手给 B 也加上微行"或"改宽度忘了改另一档"都不会被发现。
        #expect(ProCardLayout.height(includesMicro: true)
                    - ProCardLayout.height(includesMicro: false) == 25)
    }

    // MARK: - 五个槽

    @Test("五个槽都在卡里，从上到下不打乱，谁也不压谁")
    func fiveSlotsStackInOrder() {
        let box = card()
        let c = layout()

        for (label, rect) in [("图标", c.glyph), ("标题", c.title), ("正文", c.body),
                              ("主按钮", c.primary), ("次按钮", c.secondary)] {
            #expect(box.contains(rect), "\(label) 跑到卡片外面了")
        }
        // 自上而下的顺序：标题行 → 正文 → 按钮行（y 向上，所以用 maxY 比）
        #expect(c.title.maxY > c.body.maxY, "标题与正文顺序反了")
        #expect(c.body.maxY > c.primary.maxY, "正文与按钮顺序反了")
        #expect(!c.title.intersects(c.body), "标题压在正文上")
        #expect(!c.body.intersects(c.primary), "正文压在按钮上")
        #expect(!c.primary.intersects(c.secondary), "两个按钮叠在一起了")

        // ③ 正文是**一行**：它的高就是行高本身，不是"两行那 36"
        #expect(c.body.height == ProCardLayout.bodyHeight)
    }

    @Test("① 图标与 ② 标题同行，标题从图标右边 8 点开始")
    func glyphAndTitleShareTheHeaderRow() {
        // 稿子：`.card__head{display:flex;align-items:center;gap:8px}` +
        //       `.card__glyph{width:16px;height:16px}`
        let c = layout()

        #expect(c.glyph.size == CGSize(width: 16, height: 16))
        #expect(abs(c.glyph.midY - c.title.midY) < 0.001, "图标没在标题行里竖直居中")
        #expect(abs(c.glyph.minX - ProCardLayout.padding) < 0.001)
        #expect(abs(c.title.minX - (ProCardLayout.padding + 16 + 8)) < 0.001)
        // 标题一直排到右内边距
        #expect(abs(c.title.maxX - (ProCardLayout.width - ProCardLayout.padding)) < 0.001)
    }

    @Test("④ 按钮组**右对齐**，主按钮贴右下角；两个按钮之间留 10")
    func buttonsHugTheBottomRight() {
        // 稿子 §06：「色块承担『推荐』，位置承担『顺序』（**主按钮贴右下角**）」
        let box = card()
        let c = layout()

        #expect(abs(c.primary.maxX - (box.maxX - ProCardLayout.padding)) < 0.001,
                "主按钮没有贴右内边距")
        #expect(abs(c.secondary.maxX - (c.primary.minX - ProCardLayout.buttonGap)) < 0.001,
                "次按钮与主按钮之间的间距不是 10")
        // 两个按钮的下缘对齐（同一行）
        #expect(abs(c.primary.minY - c.secondary.minY) < 0.001)
        #expect(c.primary.height == 24)
        #expect(c.secondary.height == 24)
        // ⚠️ **不是等宽**：宽度随文案（稿子：主 96 / 次 72）。等宽那条规则已经作废。
        #expect(c.primary.width != c.secondary.width)
    }

    @Test("按钮宽了，**次按钮跟着往左让**，右缘不动")
    func widerPrimaryPushesTheSecondaryLeft() {
        // 150 + 10 + 72 = 232 ≤ 内宽 268 —— 放得下的情况
        let wide = ProCardLayout.Measures(primaryButtonWidth: 150,
                                          secondaryButtonWidth: 72,
                                          escKeyCapWidth: 22)
        let box = card()
        let c = ProCardLayout.content(in: box, includesMicro: true, measures: wide)

        #expect(abs(c.primary.maxX - (box.maxX - ProCardLayout.padding)) < 0.001)
        #expect(abs(c.secondary.maxX - (c.primary.minX - ProCardLayout.buttonGap)) < 0.001)
        #expect(c.secondary.minX >= ProCardLayout.padding - 0.001)
    }

    @Test("文案长到放不下时：**变窄**，不是重叠、也不是画到卡片外面")
    func overlongTitlesShrinkInsteadOfOverflowing() {
        // 这是为长英文准备的兜底。两种坏结果都要挡住：
        // 两个按钮叠在一起（点谁？）、或者次按钮画到卡片外面（渲染事故）。
        let overlong = ProCardLayout.Measures(primaryButtonWidth: 220,
                                             secondaryButtonWidth: 200,
                                             escKeyCapWidth: 22)
        let box = card()
        let c = ProCardLayout.content(in: box, includesMicro: true, measures: overlong)

        #expect(!c.primary.intersects(c.secondary), "两个按钮叠在一起了")
        #expect(box.contains(c.secondary), "次按钮画到卡片外面了")
        #expect(c.secondary.width < 200, "该变窄的没变窄")
        #expect(abs(c.primary.maxX - (box.maxX - ProCardLayout.padding)) < 0.001,
                "主按钮的右缘不该动 —— 它承载\"推荐\"")
    }

    @Test("⑤ 微行只在载体 A；B 的那两格是 `nil` 而不是空矩形")
    func microSlotOnlyOnCarrierA() {
        let a = layout(includesMicro: true)
        let b = layout(includesMicro: false)

        let cap = try? #require(a.escKeyCap)
        let micro = try? #require(a.micro)
        #expect(cap != nil && micro != nil, "载体 A 必须有微行")
        #expect(b.escKeyCap == nil, "载体 B 没有微行 —— 键帽也不该在")
        #expect(b.micro == nil, "载体 B 没有微行")

        // 键帽在左内边距起，文字从键帽右边 5 点起（稿子 `.card__micro{gap:5px}`）
        if let cap, let micro {
            #expect(abs(cap.minX - ProCardLayout.padding) < 0.001)
            #expect(abs(micro.minX - (cap.maxX + ProCardLayout.microGap)) < 0.001)
            #expect(cap.height == ProCardLayout.escKeyCapHeight)
            // 键帽比微行行高高 1 点（稿子就是这么给的），但它仍然落在卡片里
            #expect(cap.height > ProCardLayout.microHeight)
            #expect(card(includesMicro: true).contains(cap), "键帽探出卡片了")
        }
        // 微行整块在按钮行**下方**（y 向上：它的上边比按钮的下边更低）
        if let micro {
            #expect(micro.maxY <= a.primary.minY, "微行压到按钮上了")
        }
    }

    // MARK: - 命中

    @Test("点按钮中心能命中，返回的是**角色对应的那个动作**")
    func hitTestsResolveToTheRightAction() {
        let box = card()
        let c = layout()
        let buttons = ProCardContent(feature: .textRecognition,
                                     reason: .neverPurchased,
                                     primary: .startTrial,
                                     secondary: .purchase)
        // 相对坐标要换成全局（`action` 的入参是全局点，内部减 `card.origin`）
        let origin = CGPoint(x: 500, y: 300)
        let primaryCenter = CGPoint(x: origin.x + c.primary.midX, y: origin.y + c.primary.midY)
        let secondaryCenter = CGPoint(x: origin.x + c.secondary.midX, y: origin.y + c.secondary.midY)

        let box2 = CGRect(origin: origin, size: box.size)
        #expect(ProCardLayout.action(at: primaryCenter, in: box2,
                                     layout: c, buttons: buttons) == .startTrial)
        #expect(ProCardLayout.action(at: secondaryCenter, in: box2,
                                     layout: c, buttons: buttons) == .purchase)
    }

    @Test("按钮**边缘**也算命中，但出去 1 点就不算 —— 画到哪就点到哪")
    func hitAreaMatchesWhatIsDrawn() {
        let c = layout()
        let buttons = ProCardContent(feature: .pin, reason: .trialEnded,
                                     primary: .purchase, secondary: .restore)
        let origin = CGPoint(x: 500, y: 300)
        let box = CGRect(origin: origin, size: card().size)

        func hit(_ local: CGPoint) -> ProCardAction? {
            ProCardLayout.action(at: CGPoint(x: origin.x + local.x, y: origin.y + local.y),
                                 in: box, layout: c, buttons: buttons)
        }
        // 主按钮右上角之内
        #expect(hit(CGPoint(x: c.primary.maxX - 0.5, y: c.primary.maxY - 0.5)) == .purchase)
        // 出去 1 点 —— 那里画的是卡片底，不该有反应
        #expect(hit(CGPoint(x: c.primary.maxX + 1, y: c.primary.midY)) == nil)
        #expect(hit(CGPoint(x: c.primary.midX, y: c.primary.minY - 1)) == nil)
    }

    @Test("点正文与卡片外都不算按钮 —— 卡片其余部分不接受点击")
    func nonButtonAreasAreInert() {
        let c = layout()
        let buttons = ProCardContent(feature: .pin, reason: .trialEnded,
                                     primary: .purchase, secondary: .restore)
        let origin = CGPoint(x: 500, y: 300)
        let box = CGRect(origin: origin, size: card().size)

        func hit(_ local: CGPoint) -> ProCardAction? {
            ProCardLayout.action(at: CGPoint(x: origin.x + local.x, y: origin.y + local.y),
                                 in: box, layout: c, buttons: buttons)
        }
        #expect(hit(CGPoint(x: c.body.midX, y: c.body.midY)) == nil)
        // ① / ② 那两行同样不接受点击
        #expect(hit(CGPoint(x: c.title.midX, y: c.title.midY)) == nil)
        #expect(hit(CGPoint(x: c.glyph.midX, y: c.glyph.midY)) == nil)
        // 卡片左上角那片空白、以及卡片外面
        #expect(hit(CGPoint(x: 4, y: box.height - 4)) == nil)
        #expect(ProCardLayout.action(at: CGPoint(x: 10, y: 10), in: box,
                                     layout: c, buttons: buttons) == nil)
    }

    // MARK: - 位置：贴工具条外缘，且不覆盖选区

    private func toolbar(y: CGFloat = 500) -> CGRect {
        CGRect(x: 400, y: y, width: 545, height: 40)
    }

    @Test("卡片左缘 = 工具条**外缘** + 8（稿子 §03 的原话）")
    func sitsBesideTheToolbar() {
        let bar = toolbar()
        let selection = CGRect(x: 400, y: 600, width: 545, height: 200)
        let frame = ProCardLayout.frame(toolbar: bar, selection: selection,
                                        screenFrame: screen, includesMicro: true)

        #expect(abs(frame.minX - (bar.maxX + ProCardLayout.gapFromToolbar)) < 0.001)
        #expect(frame.width == ProCardLayout.width)
        #expect(frame.height == 140)
    }

    @Test("⚠️ 卡片**不覆盖选区** —— 工具条在选区下方时，卡片顶边与工具条顶边对齐")
    func neverCoversTheSelectionWhenBelow() {
        // 真实几何：工具条由 `OverlayToolbar.frame` 摆在选区下方 10 点
        // ⇒ 选区的下边正好是工具条的上边。
        //
        // ⚠️ 选区取**整屏宽**：卡片在工具条右边 8 点处，若选区只有工具条那么宽，
        // 两者在 x 上根本不重叠 —— 那样这条断言就测不到"竖向对齐"这件事了。
        let selection = CGRect(x: 0, y: 600, width: 1440, height: 200)
        let bar = CGRect(x: 400, y: 550, width: 545, height: 40)
        let frame = ProCardLayout.frame(toolbar: bar, selection: selection,
                                        screenFrame: screen, includesMicro: true)

        // 顶边对齐 ⇒ 整张卡都在选区下面
        #expect(abs(frame.maxY - bar.maxY) < 0.001)
        #expect(!frame.intersects(selection), "卡片压住了用户要截的东西")
        // ⚠️ 反例：写成"与工具条竖直居中"就会往选区那侧探出去 50 点。
        // 这条断言就是为那个写法准备的（它看起来完全合理）。
        let centered = bar.midY - frame.height / 2
        #expect(CGRect(x: frame.minX, y: centered,
                       width: frame.width, height: frame.height).intersects(selection),
                "前提变了：竖直居中在现在这套数下不再压住选区 —— 那这条注释要重写")
    }

    @Test("⚠️ 工具条翻到选区上方时，卡片也跟着翻（否则它会被推进选区里）")
    func growsUpwardWhenTheToolbarIsAboveTheSelection() {
        // 选区贴屏底 ⇒ 工具条只能放上面
        let selection = CGRect(x: 300, y: 40, width: 545, height: 200)
        let bar = CGRect(x: 300, y: 260, width: 545, height: 40)
        let frame = ProCardLayout.frame(toolbar: bar, selection: selection,
                                        screenFrame: screen, includesMicro: true)

        // 底边对齐 ⇒ 整张卡都在选区上面
        #expect(abs(frame.minY - bar.minY) < 0.001)
        #expect(!frame.intersects(selection), "卡片压住了选区")
        #expect(screen.contains(frame))
    }

    @Test("右边放不下就翻到工具条**左侧**，两边都放不下才夹进屏幕")
    func flipsLeftWhenTheRightIsTight() {
        let selection = CGRect(x: 1000, y: 600, width: 400, height: 200)
        // 工具条在屏幕右端：右缘 + 8 + 300 一定出屏
        let bar = CGRect(x: 860, y: 500, width: 545, height: 40)
        let frame = ProCardLayout.frame(toolbar: bar, selection: selection,
                                        screenFrame: screen, includesMicro: true)

        #expect(abs(frame.maxX - (bar.minX - ProCardLayout.gapFromToolbar)) < 0.001,
                "右边放不下时应该翻到左侧")

        // 两边都放不下（工具条在屏中间，左右都塞不进一张 300 宽的卡）→ 夹进屏幕。
        // ⚠️ 屏幕必须**比卡片宽**，否则"在屏内"这件事物理上就不成立
        // （那属于屏幕太小，不是夹取错了）。
        let narrow = CGRect(x: 0, y: 0, width: 620, height: 200)
        let centered = CGRect(x: 150, y: 80, width: 300, height: 40)
        let clamped = ProCardLayout.frame(toolbar: centered, selection: nil,
                                          screenFrame: narrow, includesMicro: true)
        #expect(narrow.contains(clamped), "夹取必须最后做，否则卡片会露在屏幕外")
        #expect(abs(clamped.maxX - (narrow.maxX - ProCardLayout.screenMargin)) < 0.001,
                "夹取的判据是贴着右内边距")
    }

    @Test("无论工具条在哪、选多大，卡片永远整块在屏幕里")
    func alwaysFullyOnScreen() {
        let toolbars = [CGRect(x: 0, y: 0, width: 545, height: 40),
                        CGRect(x: 0, y: 860, width: 545, height: 40),
                        CGRect(x: 895, y: 400, width: 545, height: 40),
                        CGRect(x: 500, y: 430, width: 545, height: 40),
                        CGRect(x: 0, y: 0, width: 1440, height: 40)]
        let selections = [CGRect(x: 0, y: 100, width: 1440, height: 700),
                          CGRect(x: 600, y: 600, width: 800, height: 200),
                          CGRect(x: 100, y: 40, width: 300, height: 200),
                          nil]
        for bar in toolbars {
            for selection in selections {
                let frame = ProCardLayout.frame(toolbar: bar, selection: selection,
                                                screenFrame: screen, includesMicro: true)
                #expect(screen.contains(frame),
                        "工具条 \(bar) / 选区 \(String(describing: selection)) → \(frame)")
            }
        }
    }

    @Test("没有选区信息时退回\"与工具条竖直居中\" —— 不赌也没关系")
    func centersVerticallyWithoutSelection() {
        let bar = toolbar()
        let frame = ProCardLayout.frame(toolbar: bar, selection: nil,
                                        screenFrame: screen, includesMicro: true)
        #expect(abs(frame.midY - bar.midY) < 0.001)
        #expect(screen.contains(frame))
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

    @Test("要开另一个窗口的动作才让覆盖层退场 —— 恢复购买是原地完成的")
    func onlyWindowOpeningActionsStepAside() {
        // 这一条守的是 2026-10-04 用户报的那个 bug：点在卡片上的按钮**没有任何反应**，
        // 因为覆盖层（`.screenSaver` 层的非激活面板）一直压在要开的窗口上面。
        #expect(ProCardAction.purchase.needsAnotherWindow)
        #expect(ProCardAction.startTrial.needsAnotherWindow)
        #expect(!ProCardAction.restore.needsAnotherWindow,
                "恢复购买是静默的、原地就能完成 —— 让覆盖层退场会白白丢掉用户的选区")
    }

    // MARK: - 正文说哪一句

    @Test("可试用与试用已结束说的是**两句不同的话** —— 判据看主按钮，不看 reason")
    func bodyVariantFollowsThePrimaryButton() {
        // ⚠️ 这一个判据原先写在视图层（`ProCardRenderer.body`），变异测试证明
        // **没有任何断言拦得住它**：把 `primary == .startTrial` 换成恒真，
        // 全套测试照绿 —— 而那时的表现是**对着一个已经用过试用的人说
        // "可以试用 7 天"**，一句明确的假话。
        let trial = ProCardContent(feature: .textRecognition, reason: .neverPurchased,
                                   primary: .startTrial, secondary: .purchase)
        let usedUp = ProCardContent(feature: .textRecognition, reason: .neverPurchased,
                                    primary: .purchase, secondary: .restore)
        #expect(ProCard.bodyVariant(for: trial, priceAvailable: false) == .trial)
        #expect(ProCard.bodyVariant(for: usedUp, priceAvailable: false) == .trialEnded)

        // 试用已经明确结束的那一档，无论主按钮是什么都说"已结束"
        let ended = ProCardContent(feature: .pin, reason: .trialEnded,
                                   primary: .purchase, secondary: .restore)
        #expect(ProCard.bodyVariant(for: ended, priceAvailable: false) == .trialEnded)

        // 撤销的两档分开：对"被移出家人共享"的人说"你退款了"会让他以为账号被盗
        let revoked = ProCardContent(feature: .scrollCapture,
                                     reason: .revoked(.storeRevoked),
                                     primary: .restore, secondary: .purchase)
        let notFound = ProCardContent(feature: .scrollCapture,
                                      reason: .revoked(.purchaseNotFound),
                                      primary: .restore, secondary: .purchase)
        #expect(ProCard.bodyVariant(for: revoked, priceAvailable: false) == .revokedByStore)
        #expect(ProCard.bodyVariant(for: notFound, priceAvailable: false) == .purchaseNotFound)
        #expect(ProCard.bodyVariant(for: revoked, priceAvailable: false)
                    != ProCard.bodyVariant(for: notFound, priceAvailable: false))
    }

    @Test("**只有试用那一档**会因为拿到价格而换一句话（3.1.1 的「后续费用」）")
    func onlyTheTrialVariantReportsPrice() {
        let trial = ProCardContent(feature: .textRecognition, reason: .neverPurchased,
                                   primary: .startTrial, secondary: .purchase)
        #expect(ProCard.bodyVariant(for: trial, priceAvailable: true) == .trialWithPrice)
        #expect(ProCard.bodyVariant(for: trial, priceAvailable: false) == .trial)

        // ⚠️ 其余各档**不许**因为"有价格"就改口：它们说的不是"试用会怎样"，
        // 报价格只会让"试用已结束"那张卡片看起来像在推销而不是在解释。
        let others = [
            ProCardContent(feature: .textRecognition, reason: .neverPurchased,
                           primary: .purchase, secondary: .restore),
            ProCardContent(feature: .pin, reason: .trialEnded,
                           primary: .purchase, secondary: .restore),
            ProCardContent(feature: .scrollCapture, reason: .revoked(.storeRevoked),
                           primary: .restore, secondary: .purchase),
            ProCardContent(feature: .scrollCapture, reason: .revoked(.purchaseNotFound),
                           primary: .restore, secondary: .purchase),
        ]
        for content in others {
            #expect(ProCard.bodyVariant(for: content, priceAvailable: true)
                        == ProCard.bodyVariant(for: content, priceAvailable: false),
                    "\(content.reason) 这一档不该因为价格而换句子")
        }
    }

    @Test("五种正文互不相同 —— 少一种就是两档说了同一句话")
    func bodyVariantsAreDistinct() {
        #expect(Set([ProCard.BodyVariant.trialWithPrice, .trial, .trialEnded,
                     .revokedByStore, .purchaseNotFound]).count == 5)
    }
}

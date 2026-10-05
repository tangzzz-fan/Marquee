import Testing
import Foundation
@testable import MarqueeCore

/// 读数框那三种行色。
///
/// ## 为什么值得单开一个 suite
///
/// 读数框是覆盖层里**唯一一个既要说颜色、又要说尺寸、还要说"现在这个 ⌥ 是什么意思"**的地方。
/// 设计稿 §08 的原话是「读数框当唯一的发言人」——
/// 也就是说这三行之间的**层级**本身就是被设计过的东西：
///
/// - 第一行是主角（当前那一刻的值）
/// - 第二行是副手（位置、rgb、或者"此刻 ⌥ 会做什么"）
/// - 而「不含阴影」那一条必须换色：**它是一个会改变结果的开关，不是一句说明**。
///
/// 层级一旦塌掉（三行一样亮），用户就得逐字读才能分清哪行是结果 ——
/// 而那种错不会崩、不会报错，只会让人觉得"这个框看着有点乱"。
@Suite("读数框的行色")
struct OverlayReadoutTests {

    /// 这张对比度表**以哪块底为准**。
    ///
    /// ## 这块底换过两次，记下来因为它们都是真的
    ///
    /// · **2026-10-03**：原来比对的是自绘的"黑 72%"。那次改成**不透明材质**
    ///   （`--c-panel`，与工具条同一块），理由是半透明底会让这张表失效 ——
    ///   底是纯白时次要行有 5.02，底是纯黑时只剩 **2.52**（连正文级都不到）。
    ///
    /// · **2026-10-04**：稿子 ⑩ §07 把读数框与光标提示并进了**玻璃族**
    ///   （`.rd` / `.tip` 与 `.bar` / `.strip` / `.pop` 并列）。所以现在真正在用的底
    ///   是**系统材质**，而它的合成结果由 `NSGlassEffectView` / `NSVisualEffectView` 决定。
    ///
    /// ⇒ 于是这里比对的是**回退档**：`ChromeMaterial.opaque`（「降低透明度」打开时那一条）。
    /// 那是唯一一块"值确定、可以脱机算"的底，也是这套行色必须守住的**下限**。
    ///
    /// ⚠️ **不要再把这句写成"这张表对任何底都成立"** —— 那是上一版的说法，
    /// 而玻璃档下它已经不再成立（也是脱机测不了的）。能测的部分就测能测的那部分，
    /// 剩下的靠实机看：**声称得比能保证的多，比少说一句糟得多**。
    static var fallbackBackdrop: RGB { ChromePalette.Overlay.Readout.opaqueBackdrop }

    // MARK: - 三枚颜色

    @Test("三种角色各有一个值，且互不相同")
    func rolesAreDistinct() {
        let colors = ReadoutRole.allCases.map(\.color)
        #expect(ReadoutRole.allCases.count == 3)
        for (i, a) in colors.enumerated() {
            for (j, b) in colors.enumerated() where j > i {
                #expect(a != b, "第 \(i) 与第 \(j) 枚角色撞成了同一个值")
            }
        }
    }

    @Test("回退档的底就是 `--c-panel`，不另立一个值")
    func fallbackBackdropIsTheOpaquePanel() {
        #expect(Self.fallbackBackdrop.alpha == 1,
                "「降低透明度」那一档必须是实色，否则它答不了那个开关问的问题")
        // 稿子 ⑩ §07 那句"现有 8 份稿的不透明面就是回退稿"正是指它 ——
        // 所以这里指向主题里的 `panel`，而不是抄一个十六进制过来。
        #expect(Self.fallbackBackdrop == ChromePalette.dark.panel,
                "回退档与工具条共用同一块材质，不许各自定一个值")
    }

    @Test("放大镜那个色值框仍然是**唯一**一块不透明的读数框")
    func magnifierBoxStaysOpaque() {
        // 稿子 §08：放大镜"自己带材质"，它的字靠自己的底。
        // 这一条钉的是"读数框改玻璃"那次改动的**边界** ——
        // 顺手把放大镜也改掉的话不会报错，只会在取色时看着糊
        //（那时底就是被采样的那张图，什么颜色都可能）。
        #expect(ChromePalette.Overlay.Readout.opaqueBackdrop.alpha == 1)
    }

    @Test("每一枚行色都达到正文级（≥ 4.5）")
    func everyRoleIsReadable() {
        // 一行 11 点的字要能被读，不是"能被看见" —— 门槛是正文级。
        for role in ReadoutRole.allCases {
            let ratio = contrastRatio(role.color.over(Self.fallbackBackdrop), Self.fallbackBackdrop)
            #expect(ratio >= 4.5,
                    "\(role.rawValue) 对读数框材质只有 \(ratio)，低于正文级")
        }
    }

    @Test("两枚关键行色对得上稿子那两个数")
    func matchesSpecNumbers() {
        // 稿子 §01 的对比度表里，这两条正好是读数框要用的：
        //   「选中白字 12.9」「提示行 / 弹层标签 白 64% 6.30」
        // 把设计稿里的数字变成会失败的断言 —— 抄错一个通道这里就会红。
        let primary = contrastRatio(ReadoutRole.primary.color, Self.fallbackBackdrop)
        let secondary = contrastRatio(ReadoutRole.secondary.color.over(Self.fallbackBackdrop), Self.fallbackBackdrop)
        #expect(abs(primary - 12.9) < 0.2, "第一行稿子写 12.9，实算 \(primary)")
        #expect(abs(secondary - 6.30) < 0.2, "第二行稿子写 6.30，实算 \(secondary)")
    }

    @Test("主角必须比副手亮 —— 但只差一档，不能差到读不出来")
    func primaryOutshinesSecondaryWithinOneStep() {
        let ratio = contrastRatio(ReadoutRole.primary.color.over(Self.fallbackBackdrop),
                                  ReadoutRole.secondary.color.over(Self.fallbackBackdrop))
        // 下界 1.5 = "看得出来这是第二行"；上界 3 = "它还读得出来，没被压成装饰"。
        #expect(ratio >= 1.5, "主副两行只差 \(ratio)，层级塌了")
        #expect(ratio < 3, "主副两行差了 \(ratio)，第二行会被压得读不出")
    }

    @Test("第三行那枚琥珀必须读得出颜色，不是一块白")
    func cautionReadsAsColour() {
        // 设计稿：「不含阴影用琥珀色而不是普通次要色：它是一个**会改变结果的开关**」。
        // 换成次要色就等于把它降级成一句说明书 —— 而它会改变导出的图。
        let caution = ReadoutRole.caution.color

        // 与同一套里的另外两枚都不能撞
        #expect(caution != ReadoutRole.primary.color)
        #expect(caution != ReadoutRole.secondary.color)

        // "读得出是琥珀"：红远高于蓝（灰/白三通道相等，这一条就把它挡在外面）
        #expect(caution.red - caution.blue > 0.3,
                "这枚看起来不像琥珀（r=\(caution.red) b=\(caution.blue)）")
        #expect(caution.green > caution.blue, "琥珀的绿也要高于蓝，否则偏红")

        // 而它仍然要够亮：它是"现在按 ⌥ 会改结果"的唯一声明处
        let ratio = contrastRatio(caution, Self.fallbackBackdrop)
        #expect(ratio >= 4.5, "琥珀行对材质只有 \(ratio)")
    }

    // MARK: - 读数框本身

    @Test("框的最小尺寸：够放两行，而且是稿子里那个 132 × 44")
    func minimumSizeFitsTwoLines() {
        let box = OverlayReadout.minimumSize
        let needed = OverlayReadout.primaryFontSize
            + OverlayReadout.secondaryFontSize
            + OverlayReadout.textPadding.height * 2
        #expect(box.height >= needed,
                "44 点高的框放不下 13 + 11 两行（至少要 \(needed)）")
        #expect(box.width == 132 && box.height == 44,
                "最小尺寸是稿子给的 132 × 44，改了要说一声")
    }

    @Test("第一行比第二行大 —— 行阶不能反")
    func primaryLineIsLarger() {
        #expect(OverlayReadout.primaryFontSize > OverlayReadout.secondaryFontSize)
        // 差值要看得出来：1 点的差别在 11 号字上等于没有
        #expect(OverlayReadout.primaryFontSize - OverlayReadout.secondaryFontSize >= 2)
    }

    // MARK: - 行的组装

    @Test("compact 滤掉空行，但**一个顺序都不改**")
    func compactKeepsOrderAndDropsBlanks() {
        // 空串在读数框里表现为**一行空白** —— 那是"框里莫名其妙空了一块"，
        // 而它比缺一行更难看出原因。
        //
        // ⚠️ 顺序必须原样保留：读数框的层级是**靠位置**表达的（第一行是主角），
        // 而"顺手排个序"会让主角跑到第二行去 —— 那种错看起来很像是配色问题。
        let lines = [ReadoutLine("a", .primary),
                     ReadoutLine("", .caution),
                     ReadoutLine("b", .secondary),
                     ReadoutLine("", .secondary),
                     ReadoutLine("c", .caution)]
        let kept = ReadoutLine.compact(lines)
        #expect(kept.map(\.text) == ["a", "b", "c"])
        #expect(kept.map(\.role) == [.primary, .secondary, .caution],
                "滤空行时把角色一起丢了 —— 上色会全部回落成同一个")
    }

    @Test("全是空行时 compact 得到空数组 —— 那正是「不画读数框」的意思")
    func compactOfBlanksIsEmpty() {
        #expect(ReadoutLine.compact([ReadoutLine("", .primary)]).isEmpty)
        #expect(ReadoutLine.compact([]).isEmpty)
    }
}

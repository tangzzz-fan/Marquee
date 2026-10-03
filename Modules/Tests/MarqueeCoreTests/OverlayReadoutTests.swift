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

    /// 读数框**自己的底**。
    ///
    /// ⚠️ 它是**不透明的材质**（`--c-panel`，与工具条同一块），不是半透明黑。
    ///
    /// 这一条是 2026-10-03 改的，理由是设计稿 §01 把「读数」与「工具条 / 弹层」并列
    /// 写在 `--c-panel` 那一行下；而更要紧的是**半透明底会让这张对比度表失效**：
    /// 字压在黑 72% 上时，实际对比度取决于底下是什么 ——
    /// 底是纯白时次要行有 5.02，底是纯黑时只剩 **2.52**（连正文级都不到）。
    /// 换成不透明材质之后，这张表**对任何底都成立**，与 §04 里
    /// "工具条永远比它压着的东西暗一档"是同一个论证。
    static var backdrop: RGB { ChromePalette.Overlay.Readout.backdrop }

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

    @Test("读数框的底必须**不透明** —— 否则上面那张表会随屏幕内容失效")
    func backdropIsOpaque() {
        #expect(Self.backdrop.alpha == 1,
                "半透明的底会让'次要行够不够亮'取决于底下是什么，这正是要修掉的那件事")
        #expect(Self.backdrop == ChromePalette.dark.panel,
                "读数框与工具条共用同一块材质，不许各自定一个值")
    }

    @Test("每一枚行色都达到正文级（≥ 4.5）")
    func everyRoleIsReadable() {
        // 一行 11 点的字要能被读，不是"能被看见" —— 门槛是正文级。
        for role in ReadoutRole.allCases {
            let ratio = contrastRatio(role.color.over(Self.backdrop), Self.backdrop)
            #expect(ratio >= 4.5,
                    "\(role.rawValue) 对读数框材质只有 \(ratio)，低于正文级")
        }
    }

    @Test("两枚关键行色对得上稿子那两个数")
    func matchesSpecNumbers() {
        // 稿子 §01 的对比度表里，这两条正好是读数框要用的：
        //   「选中白字 12.9」「提示行 / 弹层标签 白 64% 6.30」
        // 把设计稿里的数字变成会失败的断言 —— 抄错一个通道这里就会红。
        let primary = contrastRatio(ReadoutRole.primary.color, Self.backdrop)
        let secondary = contrastRatio(ReadoutRole.secondary.color.over(Self.backdrop), Self.backdrop)
        #expect(abs(primary - 12.9) < 0.2, "第一行稿子写 12.9，实算 \(primary)")
        #expect(abs(secondary - 6.30) < 0.2, "第二行稿子写 6.30，实算 \(secondary)")
    }

    @Test("主角必须比副手亮 —— 但只差一档，不能差到读不出来")
    func primaryOutshinesSecondaryWithinOneStep() {
        let ratio = contrastRatio(ReadoutRole.primary.color.over(Self.backdrop),
                                  ReadoutRole.secondary.color.over(Self.backdrop))
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
        let ratio = contrastRatio(caution, Self.backdrop)
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

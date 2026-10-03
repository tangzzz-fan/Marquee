import Testing
import Foundation
@testable import MarqueeCore

/// 色板与对比度。
///
/// 这里钉的是**设计稿里那些数字**（"4.66:1""6.44:1""9.30:1"）——
/// 让它们从文档里的一句话变成会失败的断言。颜色改错不会崩、不会报错，
/// 只会让某个字在某种底上看不清；而"看不清"靠肉眼在开发机上试不全。
@Suite("色板与对比度")
struct ChromePaletteTests {

    /// 稿子的数字是按 **oklch 原值**算的，而代码里存的是它量化到 8 位后的 hex
    /// ⇒ 两者会有千分位级的小差。这个容差就是为它留的。
    ///
    /// ⚠️ 它**只用来发现"抄错了一个色"**（那会差一大截），不用来追精确相等。
    /// "够不够清楚"这件事由上一条阈值断言负责。
    static let specTolerance = 0.2

    // MARK: - 设计稿数字 → 断言

    @Test("深色：稿子给的对比度数字逐条对得上")
    func darkMatchesSpec() {
        let t = ChromePalette.dark
        // (名字, 前景, 底, 稿子写的值, 出处)
        let spec: [(String, RGB, RGB, Double, String)] = [
            ("主文字 / 窗底", t.label, t.background, 15.3, "①"),
            ("次要文字 / 窗底", t.label2.over(t.background), t.background, 7.10, "①"),
            ("次要文字 / 面板", t.label2.over(t.panel), t.panel, 6.30, "①"),
            ("告警 · 去系统里办 / 窗底", t.caution, t.background, 9.30, "①③"),
            ("取消红 / 面板", ChromePalette.Overlay.cancel, t.panel, 4.66, "④"),
            ("完成绿 / 面板", ChromePalette.Overlay.done, t.panel, 6.44, "④"),
            ("取消红 / 窗底", t.danger, t.background, 5.49, "③"),
        ]
        for (name, fg, bg, expected, src) in spec {
            let got = contrastRatio(fg, bg)
            #expect(abs(got - expected) < Self.specTolerance,
                    "\(name)（出处 \(src)）稿子写 \(expected)，实算 \(got)")
        }
    }

    @Test("浅色：稿子给的对比度数字逐条对得上")
    func lightMatchesSpec() {
        let t = ChromePalette.light
        let spec: [(String, RGB, RGB, Double)] = [
            ("主文字 / 窗底", t.label.over(t.background), t.background, 12.8),
            ("次要文字 / 窗底", t.label2.over(t.background), t.background, 5.00),
            ("次要文字 / 面板", t.label2.over(t.panel), t.panel, 5.30),
            ("去系统里办 / 窗底", t.caution, t.background, 6.34),
            ("刚才没成 / 窗底", t.danger, t.background, 5.28),
            ("白字 / 强调填充", RGB(hex: 0xFFFFFF), t.fill, 5.62),
        ]
        for (name, fg, bg, expected) in spec {
            let got = contrastRatio(fg, bg)
            #expect(abs(got - expected) < Self.specTolerance,
                    "\(name) 稿子写 \(expected)，实算 \(got)")
        }
    }

    // MARK: - 阈值（"够不够清楚"这件事本身）

    @Test("每一套里，所有前景对它的底都达到正文级（≥ 4.5）")
    func everythingMeetsBodyTextThreshold() {
        for (label, theme) in [("深色", ChromePalette.dark), ("浅色", ChromePalette.light)] {
            for pair in theme.foregroundPairs {
                let ratio = contrastRatio(pair.foreground.over(pair.against), pair.against)
                #expect(ratio >= 4.5,
                        "\(label) \(pair.name) 只有 \(ratio)，低于正文级 4.5")
            }
        }
    }

    @Test("状态点这类图形只要图形级（≥ 3）—— 门槛与文字不同")
    func graphicalElementsMeetGraphicalThreshold() {
        for (label, theme) in [("深色", ChromePalette.dark), ("浅色", ChromePalette.light)] {
            for pair in theme.graphicalPairs {
                let ratio = contrastRatio(pair.foreground.over(pair.against), pair.against)
                #expect(ratio >= 3,
                        "\(label) \(pair.name) 只有 \(ratio)，低于图形级 3")
            }
        }
    }

    @Test("琥珀有两枚，而且它们**不是**同一个值（浅色下）")
    func cautionIsDeeperThanWarningInLightMode() {
        // 稿子原话：「点只要 3:1，字要 4.5:1」。深色那枚够亮，两者恰好同值；
        // 浅色那枚如果照抄，当字用只有 3.89 —— 不够正文级。
        // 这条钉的是"别顺手把两者合并成一个字段"。
        let d = ChromePalette.dark
        #expect(d.warning == d.caution, "深色里这两枚本来就是同一个值")

        let l = ChromePalette.light
        #expect(l.warning != l.caution, "浅色里必须是两个值")
        let asText = contrastRatio(l.warning, l.background)
        #expect(asText < 4.5, "浅色那枚状态点当**字**用本来就该不够（实算 \(asText)）")
        #expect(contrastRatio(l.caution, l.background) >= 4.5, "而文字版必须够")
    }

    @Test("取消是红的、完成是绿的 —— 方向与对比度都要对")
    func overlayAccentsReadCorrectly() {
        // 参考工具条里 ✗ 是红的、✓ 是绿的 —— 这两个是"结束这次截图"的两种结果，
        // 一眼分得出才有意义。初版我们两个都是白的（用户的原话是"取消按钮使用红色，有对比度"）。
        let cancel = ChromePalette.Overlay.cancel
        let done = ChromePalette.Overlay.done

        #expect(cancel.red > cancel.green, "取消得是红的")
        #expect(cancel.green < 0.5 && cancel.blue < 0.5,
                "得真的读得出是红，不是一块偏暖的白")
        #expect(done.green > done.red, "完成得是绿的")

        // ⚠️ 尺子必须对准**它们实际坐着的那个底** —— 工具条材质。
        // 这里原来量的是更暗的 `#1C1C1C`，于是那枚只有 3.98 的红被判成了"合格"。
        // 尺子选错，结论就跟着错；而"这块颜色坐在哪"本来是有确切答案的。
        let material = ChromePalette.dark.panel
        #expect(contrastRatio(cancel, material) >= 4.5,
                "取消红对工具条材质只有 \(contrastRatio(cancel, material))")
        #expect(contrastRatio(done, material) >= 4.5,
                "完成绿对工具条材质只有 \(contrastRatio(done, material))")
    }

    @Test("格图标 82% 与置灰 30% —— 稿子量过的两个数")
    func iconAndDisabledMatchSpec() {
        let t = ChromePalette.dark

        // 图标压低一档是刻意的：一排 15 个纯白图标会**糊成一片亮**，
        // 而压低之后，「选中态」那份纯白才有地方可亮。
        let icon = contrastRatio(t.icon.over(t.panel), t.panel)
        #expect(abs(icon - 9.31) < 0.05, "格图标对材质稿子写 9.31，实算 \(icon)")
        #expect(contrastRatio(t.label, t.panel) > icon,
                "主文字（纯白）必须比格图标更亮 —— 否则'图标压低一档'就没有意义了")

        // 置灰**无下限**（它本来就该看起来不活跃），但也不能低到看不见：
        // 用户得知道"那里有个格子，只是现在没得撤"。
        // 2.58 是稿子量的 —— 这条钉的是"它是个量出来的中间值"，不是随手调的数。
        let dim = contrastRatio(t.disabled.over(t.panel), t.panel)
        #expect(abs(dim - 2.58) < 0.05, "置灰对材质稿子写 2.58，实算 \(dim)")
        #expect(dim < 3, "禁用态本来就不该到图形级")
        #expect(dim > 1.5, "但也不能低到看不见")
    }

    @Test("覆盖层那两枚承担判断的颜色：替换掉系统色是**必要**的")
    func overlaySemanticColorsEarnTheirValues() {
        // 这条不是在测常量，是在钉住「为什么不能用系统红/绿」。
        // 系统红压在这块材质上够不上正文级 —— 所以那枚提亮过的红是约束倒逼的，
        // 不是审美偏好。哪天有人想"换回系统红更原生"，这条会拦住他。
        let panel = ChromePalette.dark.panel
        let systemRed = RGB(hex: 0xFF453A)
        #expect(contrastRatio(systemRed, panel) < 4.5,
                "系统红竟然达标了？那这条记录的前提就不成立了，请重新量")
        #expect(contrastRatio(ChromePalette.Overlay.cancel, panel) >= 4.5,
                "提亮后的取消红必须达标")

        // 绿反过来：系统绿本来就够，不需要提亮。
        // 两个值不对称（红提了、绿没提）是有据可依的 —— 这条把它写下来。
        #expect(contrastRatio(ChromePalette.Overlay.done, panel) >= 4.5,
                "完成绿要达标")
    }

    @Test("白芯黑边：两个极端下都成立")
    func strokeWorksOnBothExtremes() {
        // 覆盖层的线画在**别人的内容**上 —— 底是什么颜色不由我们决定。
        // 一条线要同时在纯黑内容与纯白内容上看得见，只能靠"芯 + 边"。
        let white = RGB(hex: 0xFFFFFF)
        let black = RGB(hex: 0x000000)
        let core = ChromePalette.Overlay.strokeCore
        let edge = ChromePalette.Overlay.strokeEdge

        // 深色内容上：白芯自己就跳出来
        #expect(contrastRatio(core, black) > 15, "白芯要能在纯黑内容上跳出来")

        // 纯白内容上：白芯**不可能**跟白底有对比 —— 所以它靠黑边托住。
        // 用户看到的是"白线夹在黑线中间"，真正要可辨的是**芯对边**。
        // （一开始把这条写成"黑边对白底要低对比"，那是错的：黑 45% 压白得到的是
        //   #8c8c8c，对白有 3.36 —— 它不低，它正好够垫。）
        let edgeOnWhite = edge.over(white)
        let coreAgainstEdge = contrastRatio(core, edgeOnWhite)
        #expect(coreAgainstEdge >= 3,
                "白芯对垫着黑边的自己只有 \(coreAgainstEdge)，白底上这条线会消失")

        // 黑边只是衬底，不该抢到正文级
        #expect(contrastRatio(edgeOnWhite, white) < 4,
                "黑边压在白底上不该到正文级 —— 它不是要读的东西")

        #expect(ChromePalette.Overlay.strokeCoreWidth >= 1)
        #expect(ChromePalette.Overlay.strokeEdgeWidth >= 1)
    }

    // MARK: - 颜色本身的语义

    @Test("相对亮度的两个端点")
    func luminanceEndpoints() {
        #expect(abs(RGB(hex: 0x000000).relativeLuminance - 0) < 1e-9)
        #expect(abs(RGB(hex: 0xFFFFFF).relativeLuminance - 1) < 1e-9)
        // 同一色的对比度对调不变
        #expect(contrastRatio(RGB(hex: 0xFFFFFF), RGB(hex: 0x000000))
                == contrastRatio(RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)))
        #expect(contrastRatio(RGB(hex: 0xFFFFFF), RGB(hex: 0x000000)) == 21)
    }

    @Test("over：不透明的自己原样返回，半透明的按 alpha 合")
    func compositing() {
        let opaque = RGB(hex: 0x123456)
        #expect(opaque.over(RGB(hex: 0xFFFFFF)) == opaque, "不透明的色不该被底影响")

        // 全透明 = 完全是底
        let clear = RGB(hex: 0xFF0000, alpha: 0)
        #expect(clear.over(RGB(hex: 0x00FF00)) == RGB(hex: 0x00FF00))

        // 一半红一半白 = 浅红
        let half = RGB(hex: 0xFF0000, alpha: 0.5).over(RGB(hex: 0xFFFFFF))
        #expect(abs(half.red - 1) < 1e-9)
        #expect(abs(half.green - 0.5) < 1e-9)
        #expect(half.alpha == 1, "合成之后是不透明的，对比度才有意义")
    }

    @Test("外观分派：入参化，不读系统")
    func resolvedByParameter() {
        #expect(ChromePalette.resolved(isDark: true) == ChromePalette.dark)
        #expect(ChromePalette.resolved(isDark: false) == ChromePalette.light)
    }

    @Test("两套的字段逐项都有值，且深浅确实不同")
    func twoSetsAreDistinct() {
        let d = ChromePalette.dark
        let l = ChromePalette.light
        #expect(d != l, "深浅两套不该是同一份")
        #expect(d.background != l.background)
        #expect(d.panel != l.panel)
        #expect(d.fill != l.fill)
        // 反面对照：两套里"完成绿"刻意不是同一个值（深色那枚是覆盖层量过的）
        #expect(ChromePalette.Overlay.done != l.success,
                "覆盖层的完成绿与浅色窗口里的绿是两处不同的量，别顺手合并")
    }
}

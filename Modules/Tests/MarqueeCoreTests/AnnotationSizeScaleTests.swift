import CoreGraphics
import Foundation
import Testing

@testable import MarqueeCore

/// 尺寸三档的**两套数**：覆盖层用点、编辑器用原图像素（设计稿 §08）。
@Suite("尺寸三档：两套单位")
struct AnnotationSizeScaleTests {

    @Test("每一组都是三档、都在长 —— 两套都是")
    func bothScalesAreThreeIncreasingTiers() {
        for meaning in OverlaySizeMeaning.allCases {
            for (name, values) in [("覆盖层", meaning.values), ("编辑器", meaning.editorValues)] {
                #expect(values.count == 3, "\(name) 的 \(meaning) 不是三档：\(values)")
                #expect(values == values.sorted(), "\(name) 的 \(meaning) 没按从小到大排：\(values)")
                #expect(Set(values).count == values.count, "\(name) 的 \(meaning) 有重复档：\(values)")
            }
        }
    }

    @Test("默认值**必须落在档位里** —— 不在的话一进来三档全不亮")
    func defaultsLandOnATier() {
        // 这一条不是洁癖：`AnnotationStyle` 的默认值（线宽 4 / 字号 36 / 打码 12）
        // 与档位表是**两处**数据。而那两处一旦对不上，界面上的表现是
        // "三档芯片一个都不高亮" —— 用户看到的是"当前尺寸未知"，
        // 而那个状态在界面上长得像"坏了"。
        //
        // 编辑器原先真的踩了这一条：打码默认 12，而档位是 8 / 16 / 32。
        for meaning in OverlaySizeMeaning.allCases {
            #expect(meaning.values.contains(meaning.defaultValue),
                    "覆盖层的 \(meaning) 默认值 \(meaning.defaultValue) 不在 \(meaning.values) 里")
            #expect(meaning.editorValues.contains(meaning.editorDefaultValue),
                    "编辑器的 \(meaning) 默认值 \(meaning.editorDefaultValue) 不在 \(meaning.editorValues) 里")
        }
    }

    @Test("两套**刻意不是同一组数** —— 同一套的话说明有人把它们合并了")
    func theTwoScalesDiffer() {
        // 稿子 §10 把这条列为登记过的偏离：「单位制度：编辑器 px、覆盖层 pt。
        // 三档真值全部重算（4/8/16 · 8/16/32 · 36/56/88 px），芯片画法逐字复用」。
        //
        // 为什么不能合并：覆盖层的数字描述"屏幕上的笔"，编辑器的数字描述"图里的笔"。
        // 4 点在 2x 屏上就是 8 原图像素 —— 同一个视觉粗细，两套数。
        for meaning in OverlaySizeMeaning.allCases {
            #expect(meaning.values != meaning.editorValues,
                    "\(meaning) 的两套值一样了 —— 那它们就不是两套数的根，而是同一个被复用了")
        }
        #expect(AnnotationPalette.editorLineWidths == [4, 8, 16])
        #expect(AnnotationPalette.editorRedactionStrengths == [8, 16, 32])
        #expect(AnnotationPalette.editorFontSizes == [36, 56, 88])
        #expect(AnnotationPalette.overlayLineWidths == [2, 4, 8])
    }

    @Test("编辑器的三档 = 覆盖层的三档 × 2 —— 同一组视觉粗细，两套单位")
    func editorTiersAreTheOverlayTiersAtTwoX() {
        // 这条是量出来的，不是我推的：三组都对得上。
        //
        // | | 覆盖层（点） | 编辑器（原图像素） |
        // | --- | --- | --- |
        // | 线宽 | 2 / 4 / 8 | 4 / 8 / 16 |
        // | 打码 | 4 / 8 / 16 | 8 / 16 / 32 |
        // | 字号 | 18 / 28 / 44 | 36 / 56 / 88 |
        //
        // 所以"重算一遍"并不是换了一组粗细 —— **看起来一样粗**，
        // 只是覆盖层在描述"屏幕上的笔"、编辑器在描述"图里的笔"，
        // 而目标机器是 Retina，2x 正好是两套数之间的桥。
        //
        // ⚠️ 这条断言的价值不在"证明 2 倍"，而在**把两套数拴在一起**：
        // 谁改了其中一套而不管另一套，这里会红一次，逼人想一下"视觉上还一样粗吗"。
        // 它与上面那条"两套不许相同"是配对的：同值不行、错位也不行。
        for meaning in OverlaySizeMeaning.allCases {
            let doubled = meaning.values.map { $0 * 2 }
            #expect(meaning.editorValues == doubled,
                    Comment(rawValue: "\(meaning)：覆盖层 \(meaning.values) 的两倍是 \(doubled)，"
                        + "而编辑器是 \(meaning.editorValues) —— 两者的视觉粗细不再相同"))
        }
    }

    @Test("两套默认值都是**中间那档**")
    func defaultsAreTheMiddleTier() {
        // 三档里中间那档是"不激进也不保守"的位置，两组界面都从这里起步。
        // 写成 `values[1]` 而不是各自写死一个数：换档位时默认值跟着走。
        for meaning in OverlaySizeMeaning.allCases {
            #expect(meaning.defaultValue == meaning.values[1])
            #expect(meaning.editorDefaultValue == meaning.editorValues[1])
        }
    }

    @Test("编辑器的默认样式用的是**编辑器**那三档，不是 `AnnotationStyle.default`")
    func editorDefaultStyleUsesEditorTiers() {
        let style = AnnotationPalette.editorDefaultStyle
        #expect(style.lineWidth == AnnotationPalette.defaultEditorLineWidth)
        #expect(style.fontSize == AnnotationPalette.defaultEditorFontSize)
        #expect(style.effectStrength == AnnotationPalette.defaultEditorRedactionStrength)
        // 与覆盖层那套默认值刻意不同（至少线宽与字号不同）
        #expect(style.lineWidth != AnnotationStyle.default.lineWidth
                    || style.fontSize != AnnotationStyle.default.fontSize,
                "编辑器默认样式与覆盖层那个一模一样 —— 那宿主多半还在用 `AnnotationStyle.default`")
    }
}

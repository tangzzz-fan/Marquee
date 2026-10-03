import CoreGraphics
import Testing
@testable import MarqueeCore

/// 常规窗口里那几件控件的几何。
///
/// ## 这组断言在防什么
///
/// 每一条都是"**改错了不会报错、只是看着有点怪**"的那种错 ——
/// 而"有点怪"在开发机上用眼睛是试不完的（浅色 / 深色 / 不同字号 / 不同语言长度）。
/// 所以判据写在这里，而不是留给"到时候看一眼"。
@Suite("窗口控件几何")
struct ChromeControlTests {

    // MARK: - 开关

    @Test("开关的钮在轨里，而且**四周留边相等**")
    func switchKnobFitsTrack() {
        let track = ChromeControl.switchTrackSize
        let knob = ChromeControl.switchKnobDiameter
        let inset = ChromeControl.switchKnobInset

        // ⚠️ 这里必须钉**字面值**，不能只写 `knob + inset * 2 == track.height` ——
        // 留边就是从这两个数推出来的，那条等式**恒真**：把轨高改成 24 它照样绿。
        // （变异不变红有两种可能：断言是盲的，或者那段代码是死的 —— 这条是前者。）
        #expect(track == CGSize(width: 38, height: 22), "稿子给的是 38 × 22")
        #expect(knob == 18, "稿子给的是钮 18")

        #expect(knob < track.height, "钮比轨高 —— 上下两条边会被切掉")
        #expect(inset >= 1, "留边小于 1 点，钮会贴着轨边 —— 开/关两态看不出位移")
        // 关态时钮在左、开态时在右。行程 = 轨宽 − 钮径 − 两侧留边。
        //
        // ⚠️ 判据不能写成"行程 ≥ 钮径"：稿子给的 38 / 22 / 18 算出来只有 **16 点**，
        // 而那是**对的** —— 系统开关本来就这样（钮挪动的距离大约是自身直径的 89%）。
        // 真正要保证的是"两个位置一眼分得开"，所以下界取钮径的六成。
        let travel = track.width - knob - inset * 2
        #expect(travel >= knob * 0.6,
                "开态与关态之间钮只挪 \(travel) 点（钮径 \(knob)），两态看不出区别")
    }

    // MARK: - 滑块

    @Test("滑块的钮必须比轨**粗** —— 否则那不是滑块，是一根进度条")
    func sliderKnobIsChunkierThanTrack() {
        #expect(ChromeControl.sliderTrackHeight < ChromeControl.sliderKnobDiameter,
                "轨 \(ChromeControl.sliderTrackHeight) 不比钮 \(ChromeControl.sliderKnobDiameter) 细")
        #expect(ChromeControl.sliderKnobDiameter + 2 <= ChromeControl.sliderSize.height,
                "钮放不进滑块占的那块地方（上下要留出余量给拖动时的按下态）")
        // 拖动行程：150 宽的滑块减去一个钮，还剩一大截
        #expect(ChromeControl.sliderSize.width - ChromeControl.sliderKnobDiameter >= 100,
                "行程不到 100 点 —— 0–100% 分不开")
    }

    // MARK: - 行

    @Test("行放得下两行字：标题 + 说明 + 上下留边")
    func rowFitsTitleAndSubtitle() {
        let needed = ChromeControl.rowMinHeight
        // 字号在 Core 里没有字体度量，所以这里按"字号 ≈ 行高"这个保守估法：
        // 13 点的标题与 11 点的说明各占一行，再加上下留边。
        let content = ChromeControl.rowVerticalPadding * 2 + 13 + 11
        #expect(needed >= content, "58 点装不下 12 + 13 + 11 + 12 = \(content)")
    }

    // MARK: - 标签条

    @Test("标签条放得下 14 点图标，且图标不是贴着上下边")
    func tabFitsItsIcon() {
        #expect(ChromeControl.tabBarHeight > ChromeControl.tabIconSize + 6,
                "28 高的标签条里放 14 点图标只剩 \(ChromeControl.tabBarHeight - ChromeControl.tabIconSize) 点余量")
        #expect(ChromeControl.tabCornerRadius < ChromeControl.tabBarHeight / 2,
                "圆角到了高度的一半就成了胶囊 —— 四个胶囊并排像一排开关，不像标签")
        #expect(ChromeControl.tabSpacing < ChromeControl.tabHorizontalPadding,
                "标签之间的缝比内边距还大，读起来会像「四个按钮」而不是「一个标签条」")
    }

    // MARK: - Pro 状态区

    @Test("Pro 面板的圆角不过半 —— 过了就会啃掉内容区的左右两端")
    func proPanelCornerRadiusIsModest() {
        #expect(ChromeControl.proPanelCornerRadius > 0)
        #expect(ChromeControl.proPanelCornerRadius <= ChromeControl.segmentedHeight / 2,
                "圆角比一行分段控件的一半还大，面板里的第一行会被啃掉两角")
    }

    // MARK: - 分段控件

    @Test("分段控件比行矮 —— 它是行里的一件控件，不是一行")
    func segmentedIsShorterThanARow() {
        #expect(ChromeControl.segmentedHeight < ChromeControl.rowMinHeight)
        #expect(ChromeControl.segmentHorizontalPadding * 2 < ChromeControl.segmentedHeight * 2,
                "左右内边距比控件本身还夸张 —— 每一段会变成一个方块")
    }

    // MARK: - 「质量」那一行的两种说明

    @Test("无损格式说的是**为什么不能调**，不是「不可用」")
    func losslessExplainsWhy() {
        // 稿子 §04：「『这里有一项、它现在不适用』和『这里没有这一项』必须分开。」
        // 所以无损时那句必须**给出下一步**（换成有损格式），而不是一句"质量不可用"。
        #expect(!ImageFileFormat.png.isLossy)
        #expect(ImageFileFormat.jpeg.isLossy)
        #expect(ImageFileFormat.heic.isLossy)

        let png = ImageFileFormat.png.qualityExplanation
        #expect(png.contains("JPEG") && png.contains("HEIC"),
                "PNG 那句没告诉用户换成什么才有 —— 那就是一句没有下一步的话")

        // 有损时的句子要点名格式，而且两位都要包含"质量"这个关键词
        for format in ImageFileFormat.allCases where format.isLossy {
            let text = format.qualityExplanation
            #expect(text.contains(format.displayName),
                    "\(format.displayName) 的说明句里没点名格式：\(text)")
            #expect(text.contains("质量"))
        }
        #expect(ImageFileFormat.jpeg.qualityExplanation != ImageFileFormat.heic.qualityExplanation,
                "两个有损格式的句子一模一样 —— 那点不点名格式就无所谓了，说明 %@ 没被替换")
    }

    // MARK: - 延时那一行的四档说明句

    @Test("延时四档四句，而且都带上**当前**的快捷键")
    func delayExplanationFollowsTheSlotAndTheShortcut() {
        // 稿子 §04：「说明句随档位改写」—— 它是这一项唯一的回执
        //（改了当场看不出效果，要等下一次按快捷键）。
        let combo = KeyCombo(keyCode: 12, modifiers: [.control], keyLabel: "Q")
        let sentences = CapturePreferences.delayOptions.map {
            CapturePreferences.delayExplanation(seconds: $0, combo: combo)
        }
        #expect(Set(sentences).count == sentences.count, "四档里有两句是同一句 —— 换档看不出来")

        for (seconds, text) in zip(CapturePreferences.delayOptions, sentences) {
            #expect(text.contains(combo.displayString),
                    "\(seconds) 秒那句没带上当前快捷键（写死的话，用户改了键它就成了一句反话）：\(text)")
        }
        #expect(!sentences[0].contains("秒"), "「不延时」那一句里不该出现「秒」")

        // 「那几秒是留给你摆屏幕的」只该出现在 3 秒那一档 —— 说一遍就够
        let withReason = sentences.filter { $0.contains("摆屏幕") }
        #expect(withReason.count == 1, "由来那句出现了 \(withReason.count) 次")
        #expect(withReason.first == CapturePreferences.delayExplanation(seconds: 3, combo: combo))
    }

    @Test("非法档位按「不延时」处理 —— 与 `normalize` 同一套判据")
    func delayExplanationClampsIllegalSlots() {
        let combo = KeyCombo(keyCode: 12, modifiers: [.control], keyLabel: "Q")
        #expect(CapturePreferences.delayExplanation(seconds: 999, combo: combo)
                    == CapturePreferences.delayExplanation(seconds: 0, combo: combo))
    }
}

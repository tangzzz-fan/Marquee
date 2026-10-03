import Foundation

/// 一个带 alpha 的 **sRGB** 颜色。
///
/// ⚠️ 按 sRGB 存、**不按 Display P3**：设计稿给的是一组 sRGB 十六进制值。
/// 混进 P3 会让同一个色号在不同屏幕上偏色，而那种偏差肉眼很难判断"谁对"
/// （`docs/PITFALLS.md` 里已经有这条前科）。
public struct RGB: Equatable, Sendable {

    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 从 `0xRRGGBB` 建。`alpha` 表示"这个颜色本身是半透明的"。
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// 把半透明色压到一块不透明底上 —— 这才是它在屏幕上**实际呈现**的样子。
    ///
    /// 对比度必须按合成之后算：`rgba(255,255,255,.64)` 单独拿去量是没有意义的，
    /// 它的对比度取决于底下垫的是什么。设计稿里同一个「次要文字」在窗底是 7.10:1、
    /// 在卡片材质上是 6.30:1 —— 那个差别就是这条规则的证据。
    ///
    /// 这也是为什么本文件存的是**带 alpha 的原色**而不是预先混好的实色：
    /// 同一个半透明文字要压在好几种底上，混死了就只能一种底用一个色。
    public func over(_ base: RGB) -> RGB {
        guard alpha < 1 else { return self }
        return RGB(red: red * alpha + base.red * (1 - alpha),
                   green: green * alpha + base.green * (1 - alpha),
                   blue: blue * alpha + base.blue * (1 - alpha))
    }

    /// WCAG 相对亮度（0…1）。
    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.039_28 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// WCAG 对比度（1…21）：`(亮 + 0.05) / (暗 + 0.05)`。
///
/// 判据：**正文级 ≥ 4.5，图形与大字 ≥ 3**。
///
/// 把它写成一个函数而不是"看着差不多"，是为了让设计稿里那些
/// "4.66:1""6.44:1"变成**可执行**的东西 —— 见 `ChromePaletteTests`。
/// 颜色的错不会崩、不会报错，只会让某个字在某种底上看不清；
/// 而"看不清"这件事，靠肉眼在开发机上试不全。
public func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
    let la = a.relativeLuminance
    let lb = b.relativeLuminance
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// 界面色板 —— 设计稿里 `--c-*` 那一组的 Swift 版，**唯一的颜色来源**。
///
/// ## 为什么要有它
///
/// 在这之前，颜色是散着写的（编辑器与覆盖层各 30 多处 `NSColor(...)`）。
/// 那带来的问题不是"不好看"，而是**改不动**：
///
/// - 深浅两套靠人记得改两处，漏掉的那处不报错 —— 只表现为"切到浅色有个字看不见"；
/// - 设计稿与实现之间没有对照物，改完之后**没人知道差在哪**；
/// - 对比度是设计稿里的数字，而代码里没有任何东西记得它。
///
/// ## 三条用法
///
/// 1. 控件层**只读这里**，不许写死颜色。
/// 2. 半透明色一律 `over(_:)` 到它实际所在的底上再谈对比度。
/// 3. **哪个界面用哪一套是产品决定，不是"跟系统"**：
///    - 覆盖层永远深色（它压在别人的内容上，颜色不由我们决定）；
///    - 编辑器固定深色（它是"看图的台面"，图可能是任意颜色，深台面让图突出）；
///    - 只有**常驻窗口**（偏好设置 / 最近截图 / 引导页）跟系统外观走。
public enum ChromePalette {

    /// 一套完整的界面色板。深浅各一份，字段逐项对应。
    ///
    /// 字段名对应设计稿的 `--c-*`：`background` = `--c-bg`、`panel` = `--c-panel`、
    /// `inset` = `--c-inset`、`cap` = `--c-cap`、`fill` = `--c-fill`……
    public struct Theme: Equatable, Sendable {

        // ── 底与材质 ──────────────────────────────────────────────
        /// 窗口底。
        public let background: RGB
        /// 卡片 / 面板材质。工具条、弹层、Pro 状态区都坐在它上面。
        public let panel: RGB
        /// **内凹**底：输入框、分段轨、滑块轨、键帽内底、色板托盘。
        public let inset: RGB
        /// 键帽 / 分段控件里被选中的那一段。
        public let cap: RGB
        /// 键帽描边。
        public let capBorder: RGB
        /// 控件描边。
        public let border: RGB
        /// 悬停时的控件描边。
        public let borderHover: RGB

        // ── 文字 ─────────────────────────────────────────────────
        /// 主文字。
        public let label: RGB
        /// 次要文字：每一行下面那句说明就是它。
        public let label2: RGB

        // ── 强调 ─────────────────────────────────────────────────
        /// 强调填充：开关「开」、滑块已选、主按钮。
        public let fill: RGB
        public let fillHover: RGB
        public let fillPressed: RGB
        /// 图标强调色（比 `fill` 亮一档，用于深底上的图标）。
        public let glyph: RGB
        /// 焦点环。
        public let ring: RGB

        // ── 语义 ─────────────────────────────────────────────────
        /// 「有一件事需要你去系统设置里办」（可能有救）：缺权限、登录项加不进去。
        /// 覆盖层里它还兼「告警」（已经滚到底了 / 这一帧没对齐）。
        ///
        /// ⚠️ 这枚是**状态点 / 图形**级的（≥ 3:1）。**要当文字用请用 `caution`。**
        public let warning: RGB
        /// 同一条消息的**文字版**。
        ///
        /// 深色里它与 `warning` 恰好同值 —— 那一枚本身就够亮，当字用有 9.28:1。
        /// **浅色里却是两个不同的值**：稿子的原话是「点只要 3:1，字要 4.5:1」，
        /// 所以文字那枚必须更深。这个不对称是**量出来的**，不是偏好 ——
        /// 一开始把两者合成一个字段，浅色那枚当字用只有 3.89，直接被测试拦下。
        public let caution: RGB
        /// 「你刚才这一下没成」（现在就要改）：快捷键冲突、恢复购买失败。
        /// 覆盖层里它还兼「取消」（那颗珊瑚红的 ✗）。
        public let danger: RGB
        /// 完成（那颗绿 ✓）。
        public let success: RGB

        // ── 叠在任意底上的半透明层 ────────────────────────────────
        /// 1px 分隔线的颜色（半透明，压在什么底上就取什么底）。
        public let hairline: RGB
        /// 描边按钮的底。
        public let soft: RGB
        public let softHover: RGB
        public let softPressed: RGB
        /// 文字按钮的悬停底。
        public let ghost: RGB
        public let ghostPressed: RGB

        /// **必须达到正文级（≥ 4.5）**的「前景 → 底」组合 —— 供测试遍历。
        ///
        /// 把"哪些组合必须达标"写成数据而不是散在测试里：加一个颜色时，
        /// 这里不填就**编译不过**（元组里是写死的字段名），而不是默默少测一条。
        ///
        /// ⚠️ **这个表里只放"字与图标"**。两样刻意不在：
        /// - **描边**（`border` / `capBorder`）：稿子自己标着「对底 1.9:1」——
        ///   细线靠形状与位置识别，不靠对比度，硬套 4.5 会把整套描边逼亮到失真。
        /// - **填充色当底**（`fill` / `cap`）：它们是**底**，字压在上面才算对比度，
        ///   所以下面列的是「白字 / fill」而不是 `fill` 本身。
        ///
        /// 禁用态（稿子里的"置灰 白 30% 2.58:1"）也不在这里：它**无下限**，
        /// 而且只在"暂时没内容可撤"时出现 —— 那种"看起来就该是灰的"是刻意的。
        /// ⚠️ 这里的 `name` **不是文案**，只出现在测试失败的诊断信息里 ——
        /// 所以一律用 ASCII：`LocalizationScanTests` 会把任何生产代码里的
        /// 中文字面量当成"漏翻的用户文案"拦下来（它拦得对，别为这个开豁免）。
        public var foregroundPairs: [(name: String, foreground: RGB, against: RGB)] {
            [(name: "label", foreground: label, against: background),
             (name: "label / panel", foreground: label, against: panel),
             (name: "label2", foreground: label2, against: background),
             (name: "label2 / panel", foreground: label2, against: panel),
             // 强调按钮上的字是白的（稿子：「强调填充，白字 4.93:1」）
             (name: "white on fill", foreground: RGB(hex: 0xFFFFFF), against: fill),
             (name: "glyph / panel", foreground: glyph, against: panel),
             (name: "caution", foreground: caution, against: background),
             (name: "danger", foreground: danger, against: background)]
        }

        /// **图形级（≥ 3）**的组合：状态点、指示点这类"不需要读"的东西。
        ///
        /// 与上面那张表分开，是因为**门槛不一样**：一个 8 点的状态点只要能被看见，
        /// 一行 13 点的字要能被读。混在一起就会出现"为了迁就小点把字色定浅了"，
        /// 或者反过来 —— 两种错都在浅色下才显形。
        public var graphicalPairs: [(name: String, foreground: RGB, against: RGB)] {
            [(name: "warning dot", foreground: warning, against: background),
             (name: "warning dot / panel", foreground: warning, against: panel)]
        }
    }

    // MARK: 深色

    public static let dark = Theme(
        background: RGB(hex: 0x252525),
        panel: RGB(hex: 0x313131),
        inset: RGB(hex: 0x1C1C1C),
        cap: RGB(hex: 0x424242),
        capBorder: RGB(hex: 0x585858),
        border: RGB(hex: 0x505050),
        borderHover: RGB(hex: 0x636363),
        label: RGB(hex: 0xFFFFFF),
        label2: RGB(hex: 0xFFFFFF, alpha: 0.64),
        fill: RGB(hex: 0x006FDC),
        fillHover: RGB(hex: 0x0072DF),
        fillPressed: RGB(hex: 0x0059C4),
        glyph: RGB(hex: 0x62A7FA),
        ring: RGB(hex: 0x2D87E9),
        warning: RGB(hex: 0xF8C20D),
        // 深色里两者同值：这一枚够亮，既当点（7.88:1）也当字（9.28:1）。
        caution: RGB(hex: 0xF8C20D),
        danger: RGB(hex: 0xFF6B60),
        success: RGB(hex: 0x30D158),
        hairline: RGB(hex: 0xFFFFFF, alpha: 0.10),
        soft: RGB(hex: 0xFFFFFF, alpha: 0.07),
        softHover: RGB(hex: 0xFFFFFF, alpha: 0.11),
        softPressed: RGB(hex: 0xFFFFFF, alpha: 0.15),
        ghost: RGB(hex: 0xFFFFFF, alpha: 0.10),
        ghostPressed: RGB(hex: 0xFFFFFF, alpha: 0.16))

    // MARK: 浅色

    public static let light = Theme(
        background: RGB(hex: 0xE7E7E7),
        panel: RGB(hex: 0xFCFCFC),
        inset: RGB(hex: 0xFFFFFF),
        cap: RGB(hex: 0xF3F3F3),
        capBorder: RGB(hex: 0xBEBEBE),
        border: RGB(hex: 0xBEBEBE),
        borderHover: RGB(hex: 0xA4A4A4),
        label: RGB(hex: 0x000000, alpha: 0.85),
        label2: RGB(hex: 0x000000, alpha: 0.58),
        fill: RGB(hex: 0x0065D2),
        fillHover: RGB(hex: 0x0072DF),
        fillPressed: RGB(hex: 0x004FBA),
        glyph: RGB(hex: 0x0065D2),
        ring: RGB(hex: 0x1980E8),
        // ⚠️ 浅色的琥珀只用来当**文字**（"去系统里办"），比深色那枚更深 ——
        // 深色那枚是**状态点**（只要 3:1），浅色这枚要当字用（要 4.5:1）。
        warning: RGB(hex: 0xA96000),
        // 与上面那枚**不是同一个值**：点只要 3:1（3.89 够），字要 4.5:1（那枚只有 3.89）。
        caution: RGB(hex: 0x7A4500),
        danger: RGB(hex: 0xB3261E),
        // ⚠️ 这一枚是**补出来的**：设计稿的覆盖层只有深色，浅色窗口里暂时
        // 没有需要"完成绿"的地方。真用到时（比如偏好页里的成功回执）再校。
        success: RGB(hex: 0x248A3D),
        hairline: RGB(hex: 0x000000, alpha: 0.10),
        soft: RGB(hex: 0xFFFFFF, alpha: 0.92),
        softHover: RGB(hex: 0xFFFFFF),
        softPressed: RGB(hex: 0xEEEEEE),
        ghost: RGB(hex: 0x000000, alpha: 0.06),
        ghostPressed: RGB(hex: 0x000000, alpha: 0.10))

    /// 按外观取一套。**入参化**（而不是在里面读 `NSApp.effectiveAppearance`）
    /// 是为了能脱机单测，与 `ChromeMaterial.resolved(glassAvailable:)` 同一套路。
    public static func resolved(isDark: Bool) -> Theme {
        isDark ? dark : light
    }

    // MARK: 覆盖层专用

    /// 覆盖层那几样**只在"压在别人的内容上"时才成立**的颜色。
    ///
    /// 它们不在 `Theme` 里，因为它们跟深浅无关 —— 覆盖层永远深色。
    public enum Overlay {

        /// 暗幕：冻住的部分。**选区是"挖掉的洞"，不是画上去的框。**
        public static let veil = RGB(hex: 0x000000, alpha: 0.32)

        /// 取消（那颗珊瑚红的 ✗）。
        ///
        /// ⚠️ 比系统红 `#ff453a` **提亮一档** —— 后者压在这块材质上只有 3.67:1，
        /// 够不上"压在白底网页上也读得清"那条验收项。这不是绕开约束，是约束倒逼的值。
        public static let cancel = RGB(hex: 0xFF6B60)

        /// 完成（那颗绿 ✓）。绿不用提亮 —— 它对材质有 6.44:1。
        /// **红要提一档、绿不用，这个不对称是量出来的，不是偏好。**
        public static let done = RGB(hex: 0x30D158)

        /// 「白芯黑边」：凡是画在内容之上、不能被材质托住的线
        /// （选区描边、控制点、吸附线、放大镜准心），一律**白芯 + 黑边**。
        ///
        /// 理由：屏幕底下是什么颜色不由我们决定。白芯在深色内容上跳出来，
        /// 黑边在纯白内容上把白芯托住 —— **一条线同时通过两个极端**，
        /// 比"挑一个够亮的颜色"可靠。
        public static let strokeCore = RGB(hex: 0xFFFFFF)
        public static let strokeEdge = RGB(hex: 0x000000, alpha: 0.45)

        /// 白芯那条线的宽度（点）。
        public static let strokeCoreWidth: Double = 1
        /// 黑边的**额外**宽度（点）。画成"总宽 3、芯 1"而不是两条 1 点线。
        public static let strokeEdgeWidth: Double = 1
    }
}

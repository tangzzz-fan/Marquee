import CoreGraphics
import Foundation

/// 常规窗口（偏好设置 / 最近截图 / 菜单栏面板 / 引导页）里那几件控件的**几何**。
///
/// ## 为什么这些数要放 Core
///
/// 它们全都是设计稿 §01 那张表上的值，而且**每一个单独看都很普通、
/// 改错了却不会报错**：
///
/// | 数 | 改错了会怎样 |
/// | --- | --- |
/// | 开关钮直径 | 比轨高 → 钮被切掉两条边；比轨矮很多 → 看着像个凹槽 |
/// | 滑块轨厚 | 比钮还粗 → 那就不像滑块了，像一根进度条 |
/// | 行最小高 | 放不下两行字 → 说明句被裁掉半截 |
/// | 面板圆角 | 超过行高一半 → 圆角吃掉内容区的左右两端 |
///
/// 这些偏差都在 1–4 点量级，肉眼看不出来 —— 所以判据写在这里，
/// 由 `ChromeControlTests` 逐条钉住。AppKit 那边只负责照着画。
///
/// ⚠️ 与 `OverlayToolbar` 的分工：那一个是**覆盖层**（永远深色、压在别人内容上），
/// 这一套是**常规窗口**（跟随系统深浅）。两套的数**故意不同**，不要互相"统一"。
public enum ChromeControl {

    // MARK: - 开关（三处布尔项）

    /// 轨的尺寸。稿子 §01：「开关 38 × 22 · 钮 18」。
    public static let switchTrackSize = CGSize(width: 38, height: 22)
    /// 钮的直径。
    public static let switchKnobDiameter: CGFloat = 18

    /// 钮在轨里的**上下留边**。
    ///
    /// 由轨高与钮径**推**出来，不是另写一个数 ——
    /// 写成 `2` 的话，谁改了轨高就会得到一个偏心的钮，而那种偏差只有把开关放大才看得出来。
    public static var switchKnobInset: CGFloat {
        (switchTrackSize.height - switchKnobDiameter) / 2
    }

    // MARK: - 标签条（窗口顶部 · 4 格）

    /// 标签条的高。稿子 §01：「28 高」。
    public static let tabBarHeight: CGFloat = 28
    /// 标签里图标的大小。稿子：「11 / 500 + 14pt 图标」。
    public static let tabIconSize: CGFloat = 14
    /// 图标与文字之间的间距。
    ///
    /// ⚠️ 这个 6 是**从稿子的宽度倒推出来的**：稿子给的标签宽是「示意 66–77」，
    /// 而两个字的「通用」按 14 图标 + 22 文字 + 左右各 12 内边距算正好是 62 ——
    /// 差的那 4 点就是这一段间距（三个字的「快捷键」= 14 + 6 + 33 + 24 = 77 ✓）。
    /// 没有这一段，标签会比稿子窄一圈，而那看起来只是"排得紧了一点"。
    public static let tabIconGap: CGFloat = 6
    /// 选中标签的圆角。稿子：「6 pt」。
    public static let tabCornerRadius: CGFloat = 6
    /// 标签左右的内边距。稿子给的示意宽度是 66–77（随文字），所以这里只定内边距。
    public static let tabHorizontalPadding: CGFloat = 12
    /// 标签之间的间隙。稿子没给，取一个比内边距小的数 ——
    /// 相邻标签的内边距之和必须**大于**标签之间的缝，否则读起来像一列并排的按钮。
    public static let tabSpacing: CGFloat = 4

    // MARK: - 行（每一页的内容单位）

    /// 行的**最小**高。稿子 §01：「最小 58 高（12 上 12 下）」。
    public static let rowMinHeight: CGFloat = 58
    /// 行的上下内边距。
    public static let rowVerticalPadding: CGFloat = 12

    // MARK: - 分段控件（延时 4 档 · 格式 3 档）

    /// 分段控件的高。稿子 §01：「24 高」。
    public static let segmentedHeight: CGFloat = 24
    /// 每一段左右的内边距。稿子：「段内边距 0 / 8」。
    public static let segmentHorizontalPadding: CGFloat = 8

    // MARK: - 滑块（质量 · 只用在有损格式下）

    /// 滑块占的地方。稿子 §01：「150 × 24」。
    public static let sliderSize = CGSize(width: 150, height: 24)
    /// 轨的粗细。稿子：「轨 4」。
    public static let sliderTrackHeight: CGFloat = 4
    /// 钮的直径。稿子：「钮 14」。
    public static let sliderKnobDiameter: CGFloat = 14

    // MARK: - Pro 状态区（通用页底部）

    /// 面板圆角。稿子 §01：「8 pt」。
    public static let proPanelCornerRadius: CGFloat = 8
    /// 面板内边距。
    public static let proPanelPadding: CGFloat = 12

    /// 面板里**文字可用宽度**：`440（窗宽）− 20×2（页边距）− 12×2（面板内边距）＝ 376`。
    ///
    /// 为什么这个数在 Core 而不是在视图里：**"文案够不够宽"那条断言要跟视图读同一个数**。
    /// 两处各写一份的话，改了窗宽而忘了改断言，那条约束就悄悄失效 ——
    /// 而失效的表现只是"某句英文被截断了尾巴"，中文开发机上永远看不见
    ///（`RecentPanel.width` / `OverlayToolbar.toolbarSize` 都是这个做法）。
    public static let proPanelTextWidth: CGFloat = 376

    /// 面板上那些"回执"最多折几行。
    ///
    /// 定成 2 而不是 1：开发版那条"商店里没有这个商品"要带上可执行的下一步，
    /// 一句话说不完。也定成 2 而不是无上限 —— 回执可以长，但不该把面板撑成一堵墙。
    public static let proPanelOutcomeLineLimit = 2
}

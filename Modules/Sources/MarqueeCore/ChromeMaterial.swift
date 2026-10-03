import CoreGraphics

/// 悬浮面板（覆盖层工具条 / 钉图控制条 / 倒计时 / 编辑器工具条）的背景材质（ticket 17）。
///
/// ## 为什么"选哪种材质"要放在 Core
///
/// 真正的分叉点在 `if #available(macOS 26.0, *)` 上，而**我手上不一定有 26 的系统**。
/// 把"可用性"作为**入参**传进来，"26 用玻璃、15 用 HUD 材质"这条规则就能脱机单测，
/// 不必等到在 26 的机器上肉眼验。
///
/// 视图侧只做一件事：`ChromeMaterial.resolved(glassAvailable: isGlassAvailable).build(cornerRadius:)`。
public enum ChromeMaterial: String, CaseIterable, Sendable {

    /// macOS 26+ 的原生 Liquid Glass（`NSGlassEffectView`）。
    case glass

    /// 15.x 降级：`NSVisualEffectView` 的 `.hudWindow` 材质。
    ///
    /// 选它而不是 `.popover` / `.menu`：那两种是**浅色**材质，
    /// 而这块面板要压在任意屏幕内容上、并且始终是深色的（文字是白的）。
    /// 深色材质在浅色模式下被系统切换掉的表现是"文字突然看不见了"，
    /// 而 `.hudWindow` 在两种外观下都是深的。
    case hud

    /// 按"玻璃是否可用"决定用哪种。**唯一的决策点**。
    public static func resolved(glassAvailable: Bool) -> ChromeMaterial {
        glassAvailable ? .glass : .hud
    }
}

/// 悬浮面板的背景参数。两个分支共用同一套值，
/// 免得"26 上看着挺好、15 上字看不清"这种只在某一台机器上出现的差别。
public enum ChromeStyle {

    /// 15.x（`NSVisualEffectView(.hudWindow)`）那条路的衬底不透明度。
    ///
    /// 材质是半透明的：压在一张纯白网页上时，白字会掉到几乎看不见。
    /// 垫一层黑衬底是"这块面板始终可读"的保证 —— 验收项里就有"两种系统上文字对比度足够"。
    public static let scrimAlpha: CGFloat = 0.35

    /// 26+ **玻璃**的着色强度。**必须明显轻于衬底**。
    ///
    /// ⚠️ 这一条是实测调出来的：初版给 0.6，结果玻璃被压成一块几乎不透光的黑板，
    /// 用户的原话是"要玻璃质感"—— 也就是说**为了让文字更清楚而加的着色，
    /// 恰好把要做的那个效果消掉了**。玻璃的透光感来自"底下画面能透上来"，
    /// 着色一重就没得透。对比度改由 `.regular` 风格自身的自适应 + 这层轻着色共同兜住。
    public static let glassTintAlpha: CGFloat = 0.25

    // `readoutAlpha`（自绘小框的不透明度，0.72）在 2026-10-03 被**删掉**了，
    // 连同 `ChromeMaterialTests.readoutIsStrongEnough` 那一条。
    //
    // 删的理由不是"改用别的值"，而是**那个做法本身是错的**：
    // 半透明的底会让"读数框里的字够不够亮"取决于屏幕上此刻是什么 ——
    // 黑 72% 压在纯白内容上有 5.02，压在纯黑内容上只剩 2.52，连正文级都不到。
    // 设计稿 §01 把「读数」与「工具条 / 弹层」并列写在 `--c-panel` 那一行下，
    // 也就是**不透明材质**。换过去之后那几条对比度对任何底都成立。
    //
    // 顺带记一笔：那条测试写的是 `alpha >= 0.5`，而 0.72 与 0.5 都能过 ——
    // 它拦得住"忘了设"，拦不住"设得不够"。**断言写成了边界而不是意图**，
    // 于是它给了一件它其实没有提供的保证（见 PITFALLS 98）。
}

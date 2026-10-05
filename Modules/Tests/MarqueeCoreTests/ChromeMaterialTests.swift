import CoreGraphics
import Testing

@testable import MarqueeCore

@Suite("悬浮面板材质（ticket 17）")
struct ChromeMaterialTests {

    @Test("26 的系统上必须用原生玻璃")
    func glassPreferredWhenAvailable() {
        #expect(ChromeMaterial.resolved(glassAvailable: true) == .glass)
    }

    /// 这条是 ticket 17 的降级要求：最低系统 15.0，没有玻璃时**必须**有替代材质，
    /// 不能出现"没有材质"这种第三态（那会表现为一块空白或黑块）。
    @Test("没有玻璃时必须降级到 HUD 材质，且不是「什么都不用」")
    func degradesToHUD() {
        let material = ChromeMaterial.resolved(glassAvailable: false)
        #expect(material == .hud)
    }

    // MARK: - 「降低透明度」（稿子 ⑩ §07）

    /// 稿子 ⑩ §07 的原话：「一开，全部 `.glass` 切回 `--c-panel` 不透明 ——
    /// **现有 8 份稿的不透明面就是回退稿，不需要第二套设计**」。
    @Test("要降低透明度时，玻璃可不可用都得给实色")
    func reduceTransparencyWins() {
        #expect(ChromeMaterial.resolved(glassAvailable: true, reduceTransparency: true) == .opaque)
        #expect(ChromeMaterial.resolved(glassAvailable: false, reduceTransparency: true) == .opaque)
        // 且它**不是** `hud`：`hud` 是 `NSVisualEffectView`，照样半透明。
        // 用一个半透明去答"我要减少透明"，等于没答 —— 而这条恰好是辅助功能开关。
        #expect(ChromeMaterial.resolved(glassAvailable: false, reduceTransparency: true) != .hud)
    }

    /// ⚠️ 判据的顺序会写反，而且**只有在 26 的机器上才看得出来**：
    /// 先问"玻璃可用吗"再问"要降低透明度吗"，在 15.x 上恰好也对（两条都走 hud/opaque），
    /// 到了 26 上就变成"这个开关在新系统上没反应"。
    @Test("降低透明的优先级高于玻璃可用 —— 顺序写反只在 26 上发作")
    func reduceTransparencyOutranksGlass() {
        let ordered = ChromeMaterial.resolved(glassAvailable: true, reduceTransparency: true)
        let glassFirst = ChromeMaterial.resolved(glassAvailable: true) // 不给第二参数 = 不看那个开关
        #expect(ordered != glassFirst,
                "两条判据各问各的、结果却一样，说明有一条根本没起作用")
    }

    /// 汇总一句：不管哪种输入，都只能落在已有的**三种**之一。
    /// 这条断言的是**封闭性**（不会凭空冒出第四种材质），
    /// 上面几条断言的是各自的具体取值 —— 缺了这条，将来加分支时
    /// 只有"新增的那种"没人管。
    @Test("任何输入都必须落在已知的三种材质里")
    func staysWithinKnownMaterials() {
        for available in [true, false] {
            for reduce in [true, false] {
                let material = ChromeMaterial.resolved(glassAvailable: available,
                                                       reduceTransparency: reduce)
                #expect(ChromeMaterial.allCases.contains(material))
            }
        }
        #expect(ChromeMaterial.allCases.count == 3)
    }

    /// 衬底必须**足够不透明**才有意义：它是"压在白色网页上白字仍可读"的保证。
    /// 只断言"大于 0"是盲的（0.02 也能过），而那样等于没衬。
    @Test("衬底与玻璃着色都要足以兜住对比度")
    func backstopsAreStrongEnough() {
        #expect(ChromeStyle.scrimAlpha >= 0.25)
        #expect(ChromeStyle.glassTintAlpha >= 0.1)
    }

    /// ⚠️ 这条是**回归测试**，钉的是一次真实返工。
    ///
    /// 初版把玻璃的着色给到 0.6（比衬底还重），玻璃被压成一块几乎不透光的黑板 ——
    /// 用户的原话是"要玻璃质感"。教训是：**为了让文字更清楚而加的着色，
    /// 恰好会把要做的那个效果消掉**，而且不崩不报错，只有眼睛看得出来。
    ///
    /// 所以判据不能只写"大于 0"（那种断言在 0.6 时也是绿的），
    /// 必须写**两者的大小关系** —— 这才是有意图的那一条。
    @Test("玻璃的着色必须明显轻于衬底，否则玻璃被压成平板")
    func glassTintStaysLighterThanScrim() {
        #expect(ChromeStyle.glassTintAlpha <= ChromeStyle.scrimAlpha - 0.05,
                "玻璃着色 \(ChromeStyle.glassTintAlpha) 与衬底 \(ChromeStyle.scrimAlpha) 太接近：玻璃会失去透光感")
    }

    /// ⚠️ 这里原来还有一条「读数框的深色底也不能太淡」（`readoutAlpha >= 0.5`），
    /// 2026-10-03 连同那个常量一起删了。
    ///
    /// 记一笔教训：那条断言写的是**边界**（`>= 0.5`），而它想保证的是**意图**
    /// （"这些字压在任何内容上都读得出"）—— 0.72 与 0.5 都能过它，
    /// 所以它给的保证比看起来的少。
    ///
    /// ## 后面还发生了一次反转（2026-10-04）
    ///
    /// 当时删它的理由是"读数框改成不透明材质了（设计稿 §01）"。
    /// 而稿子 ⑩ §07 又把读数框与光标提示并回了**玻璃族** ——
    /// 所以"读数框该不该透明"这件事在两天里定了两次，方向相反。
    ///
    /// ⇒ 这条留下的教训不是"哪个答案对"，而是：**不要把随设计变的决定缓存进常量**。
    /// 现在那一层只剩两个能被断言的东西：行色本身（`OverlayReadoutTests`）
    /// 与**回退档**上的对比度（同一份测试）—— 玻璃档的合成结果由系统材质决定，
    /// 脱机测不了，也就**不许**在测试里声称。
}

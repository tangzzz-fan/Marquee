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

    /// 汇总一句：不管哪种输入，都只能落在已有的两种之一。
    /// 这条断言的是**封闭性**（不会凭空冒出第三种材质），
    /// 上面两条断言的是各自的具体取值 —— 缺了这条，将来加分支时
    /// 只有"新增的那种"没人管。
    @Test("任何输入都必须落在已知的两种材质里")
    func staysWithinKnownMaterials() {
        for available in [true, false] {
            let material = ChromeMaterial.resolved(glassAvailable: available)
            #expect(ChromeMaterial.allCases.contains(material))
        }
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

    /// 自绘小框（读数框）也必须是不透光的深色 —— 它是白字压在白底截图上的唯一依靠。
    @Test("读数框的深色底也不能太淡")
    func readoutIsStrongEnough() {
        #expect(ChromeStyle.readoutAlpha >= 0.5)
    }
}

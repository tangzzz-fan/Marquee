import AppKit
import MarqueeCore

/// 悬浮面板背景的 AppKit 实现（ticket 17）。
///
/// 这是一个**工厂**，不是一个统一容器：覆盖层工具条要"玻璃在下、图标在上"，
/// 钉图控制条要"玻璃在下、按钮在上"，各处的子视图结构不一样。
/// 收敛成"给一个圆角、还你一块不含事件的背景视图"，才不会为了统一而把某处的绘制顺序拧反。
@MainActor
enum ChromeBackground {

    /// 当前系统能不能用原生玻璃。**只有这里读版本号**；
    /// 其余分支全由 `ChromeMaterial.resolved(glassAvailable:)` 决定（那部分可在 Core 脱机单测）。
    ///
    /// 留了一个现场开关，用来在 26+ 的机器上**自检降级路径**（否则那条路只有 15.x 的机器能验）：
    /// ```
    /// defaults write dev.tango.Marquee chrome.forceHUD -bool YES   # 强制走 HUD 材质
    /// defaults delete dev.tango.Marquee chrome.forceHUD
    /// ```
    /// 这里用 `bool(forKey:)` 是**对的**（与 PITFALLS 85 的结论不冲突）：
    /// "没写过" 返回 `false`，而这里 `false` 的含义正是"不强制降级" —— 缺省值恰好就是想要的。
    static var isGlassAvailable: Bool {
        if UserDefaults.standard.bool(forKey: "chrome.forceHUD") { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 当前系统该用的材质。
    static var material: ChromeMaterial {
        ChromeMaterial.resolved(glassAvailable: isGlassAvailable)
    }

    /// 造一块背景，**已包在事件透明的容器里**。
    ///
    /// 包一层是必须的：`NSGlassEffectView` / `NSVisualEffectView` 默认会参与命中测试，
    /// 直接当子视图挂上去会把鼠标事件吃掉 —— 表现是"按钮看得见、点它没反应"。
    /// 容器（`ChromeForegroundView`）的 `hitTest` 恒为 nil，事件于是落到它下面的视图上。
    static func makeBackgroundView(cornerRadius: CGFloat) -> NSView {
        let container = ChromeForegroundView()
        let chrome = makeMaterialView(cornerRadius: cornerRadius)
        chrome.frame = container.bounds
        chrome.autoresizingMask = [.width, .height]
        container.addSubview(chrome)
        return container
    }

    // MARK: - 内部

    private static func makeMaterialView(cornerRadius: CGFloat) -> NSView {
        switch material {
        case .glass:
            guard #available(macOS 26.0, *) else {
                // 不可达：`material` 只在 26+ 上返回 `.glass`。
                // 留着是为了万一将来可用性判断被改坏时**安静地退回材质**，
                // 而不是给出一块没有背景的透明面板（那看起来像功能没做）。
                return makeEffectView(cornerRadius: cornerRadius)
            }
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.tintColor = NSColor.black.withAlphaComponent(tintAlpha)
            return glass

        case .hud:
            return makeEffectView(cornerRadius: cornerRadius)
        }
    }

    private static func makeEffectView(cornerRadius: CGFloat) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        // `.behindWindow`：取**窗口背后**的内容做材质，而不是窗口内已画好的东西。
        // 这些面板的窗口都是透明的，底下就是屏幕上的真实画面 —— 它才是有东西可模糊的那层。
        // 用 `.withinWindow` 会把下面那层变暗蒙层当素材，糊出来是一片纯色。
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        // 衬底：材质是半透明的，不垫一层黑的话压在白底内容上白字会糊掉
        // （验收项里就有"两种系统上文字对比度足够"）。
        effect.layer?.backgroundColor = NSColor.black.withAlphaComponent(scrimAlpha).cgColor
        return effect
    }

    // MARK: - 现场可调
    //
    // "多透一点 / 再多一点"这种观感只能眼睛看着调，代码里猜没用。
    // 沿用 `lens.zoom` 那一套：给一个 defaults 口子，下次唤起覆盖层生效。
    //
    //   defaults write dev.tango.Marquee chrome.tint  -float 0.25   # 玻璃着色
    //   defaults write dev.tango.Marquee chrome.scrim -float 0.35   # 15.x 衬底
    //   defaults delete dev.tango.Marquee chrome.tint

    private static var tintAlpha: CGFloat {
        override("chrome.tint", fallback: ChromeStyle.glassTintAlpha)
    }

    private static var scrimAlpha: CGFloat {
        override("chrome.scrim", fallback: ChromeStyle.scrimAlpha)
    }

    /// 只有**真的写过**才覆盖。
    ///
    /// 用 `object(forKey:) is NSNumber` 而不是 `double(forKey:)`：后者在 key 不存在时返回 0，
    /// 那会把不透明度直接置零（面板变全透明、字全看不见），而表现是"设置读坏了"——
    /// 与 PITFALLS 85 同一条道理。
    private static func override(_ key: String, fallback: CGFloat) -> CGFloat {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else {
            return fallback
        }
        return CGFloat(min(max(number.doubleValue, 0), 1))
    }
}

/// 一块"只负责被看"的视图：**永远不参与命中测试**。
///
/// ## 为什么需要它
///
/// AppKit 的绘制顺序是"自己的 `draw` → 子视图"。所以如果工具条的图标仍由覆盖层自己画，
/// 再往它身上挂玻璃子视图，玻璃会**盖住图标**（图标在父视图那层、玻璃在子视图那层，
/// 子视图永远在上）。把"背景"与"前景"拆成**两个兄弟子视图**（背景先加、前景后加）
/// 才有正确的层叠，又不必把覆盖层整个改成图层树。
final class ChromeForegroundView: NSView {

    /// 前景画法。传进来的矩形就是这个视图的 `bounds`（调用方已经把 frame 摆好了）。
    var render: ((NSRect) -> Void)?

    /// **必须为 nil**。覆盖层的命中判定在父视图里（`OverlayToolbar.contains`）——
    /// 这层一旦吃掉 `mouseDown`，表现就是"工具条看得见、点它没反应"。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        render?(bounds)
    }
}

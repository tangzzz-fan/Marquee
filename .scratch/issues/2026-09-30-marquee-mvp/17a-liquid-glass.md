# 17a: Liquid Glass 视觉（悬浮面板的材质）与降级

**What to build:** 把悬浮在屏幕内容之上的几块面板（覆盖层工具条、钉图控制条、延时倒计时）
从"自绘的一块半透明黑"换成**系统材质**：macOS 26+ 用原生 Liquid Glass，
15.x 用 `NSVisualEffectView` 的 HUD 材质，两条路上文字都必须清晰可读。

> 原 ticket 17「Liquid Glass 视觉与本地化」在 2026-10-01 **拆成两条**。
> 拆的理由：本地化是一个**独立的基础设施改动**（机制 + 205 条 catalog + 220 处调用点 + 扫描测试，
> 其中 40 处是插值串，必须改成 `String(format:)` 才不会**静默失效**），
> 混在视觉这一票里做，会把"哪里还没翻译"藏在一次巨大的 diff 里。
> 本地化见 `17b-localization.md`。

**Blocked by:** 07、15

**Status:** ✅ done（2026-10-01）

## 已提前验证的结论（直接用，不要重新试）

- `NSGlassEffectView` / `NSGlassEffectContainerView` = **macOS 26.0+**；`effectIsInteractive` = **27.0+**
- 最低系统 15.0 → **所有玻璃效果必须包 `if #available(macOS 26.0, *)`**，并为 15.x 提供材质降级

## 做出来的东西

| 决策 | 值 |
| --- | --- |
| 决策点落哪 | `MarqueeCore.ChromeMaterial.resolved(glassAvailable:)` —— 把"可用性"作为**入参**，于是"26 用玻璃 / 15 用 HUD"这条规则**能脱机单测**（本机是 26+，不把判据抽出来就永远只有一条路被测到） |
| 参数 | `ChromeStyle`：`scrimAlpha 0.55` / `glassTintAlpha 0.6` / `readoutAlpha 0.72`。**两个分支共用同一套值** —— 各写各的必然出现"26 上看着挺好、15 上字看不清" |
| 15.x 用哪种材质 | `NSVisualEffectView(.hudWindow)` + `.behindWindow`。**不用 `.popover` / `.menu`**：那两种是浅色材质，而这块面板的文字是白的，浅色模式下会直接看不见。`.hudWindow` 在两种外观下都是深的 |
| 覆盖层工具条 | 拆成**两个兄弟子视图**：`toolbarChrome`（材质底）+ `toolbarForeground`（描边 / 分隔线 / 图标）。见 PITFALLS 89 |
| 钉图控制条 | 面板 `contentView` 换成一个容器：`[材质底, PinStripView]`，顺序不能反 |
| 倒计时 HUD | 同上：`[材质底, NSTextField]` |
| 读数框 / 提示框 | **刻意保持自绘的平深色**（`ChromeStyle.readoutAlpha`）。它们是贴着选区、尺寸随内容变、位置跟着光标跑的小读数，做成视图既难对齐也不划算；系统自带的截图工具在同一位置也是平的深色小条 |
| 编辑器窗口 | **本轮不动**。它是普通带标题栏的窗口（系统已经给了标题栏材质），内容是一块刻意中性的深色画布；玻璃要解决的是"面板压在任意屏幕内容上"，那是悬浮面板的问题 |
| 自检开关 | `defaults write dev.tango.Marquee chrome.forceHUD -bool YES` → 在 26+ 机器上强制走降级路径（否则那条路只有 15.x 的机器能验） |

## Acceptance criteria

- [x] 在 macOS 26+ 上悬浮面板使用原生玻璃材质（`NSGlassEffectView`，深色着色）
- [x] 在 macOS 15 上使用降级材质，**不出现空白、黑块或崩溃**（代码路径 + 单测钉住；肉眼需 15.x 机器或 `chrome.forceHUD`）
- [x] 面板文字对比度足够（材质之上垫一层黑衬底 + 玻璃再加 `tintColor`）
- [x] 深色/浅色模式都正确（`.hudWindow` 在两种外观下都是深的 → 白字始终可读）
- [x] 有一份"材质选哪种"的可执行判据（`ChromeMaterialTests`，两个变异分别能变红）
- [ ] **人工**：在 26+ 上拖一次选区，确认工具条是玻璃质感的、图标与文字都看得清
- [ ] **人工**：`chrome.forceHUD` 打开后，确认降级路径同样可读（没有白屏 / 黑块）

## 实现记录

- `Modules/Sources/MarqueeCore/ChromeMaterial.swift`（新）：`ChromeMaterial` + `ChromeStyle`
- `Modules/Sources/MarqueeOverlay/ChromeBackground.swift`（新）：材质工厂 `makeBackgroundView(cornerRadius:)`
  + `ChromeForegroundView`（`hitTest` 恒为 nil 的"只给人看"层）
- `SelectionOverlayView`：删掉工具条的自绘黑底与两处 `drawToolbar` 调用；
  改成 `syncToolbarChrome()` 摆位 + `drawToolbarForeground(in:)` 画前景
- `PinWindow`：`PinStripView.draw` 不再铺黑底（铺了会把材质整个盖掉）；`PinStripStyle.cornerRadius` 单一来源
- `CountdownHUD`：`container[材质底, label]`
- `Modules/Tests/MarqueeCoreTests/ChromeMaterialTests.swift`（新）：4 条

## 变异测试（断言没空跑的证据）

| 变异 | 结果 |
| --- | --- |
| `resolved` 永远返回 `.hud` | ✘「26 的系统上必须用原生玻璃」变红 ✔ |
| `scrimAlpha` 0.55 → 0.08 | ✘「衬底不透明度要足以保证对比度」变红 ✔ |

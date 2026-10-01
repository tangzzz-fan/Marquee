# Marquee · 项目长期记忆

> 工作目录 `/Users/tango/Developments/Marquee`（2026-09-30 由 `Snipo` 改名，git 历史连续）；
> 远端 `git@github.com:tangzzz-fan/Marquee.git`；开发机 **macOS 27**（⇒ 玻璃那条路实际生效）。
> 定位：复刻腾讯 Snip 的 macOS 原生截屏工具。纯本地、无账号、键盘驱动。
>
> ⚠️ **写代码之前先扫 `docs/PITFALLS.md`**（92 条实测陷阱，多为"不崩溃、不报错、只悄悄错"）。
> 本文件只记**决策**与**索引**；理由与实现细节在 `docs/` 与 ticket 里。

## 已固化决策（勿随意推翻）

| 项 | 值 |
| --- | --- |
| 产品 / 最低系统 | **Marquee**（`dev.tango.Marquee`），**macOS 15.0**；26/27 专属能力走 `if #available` + 降级 |
| 采集 / 覆盖层 | ScreenCaptureKit（不用弃用的 `CGWindowListCreateImage`）；覆盖层＝逐屏 `NSPanel`（变暗蒙层 + 镂空 + 描边），**不铺整屏截图** |
| 画布渲染 | SwiftUI Canvas；CG 只做导出/剪贴板/降采样，滤镜走 CoreImage；**Metal 首期不引入**，留 `CanvasRendering` 协议边界 |
| 分发 | Developer ID 公证，**非 MAS**（沙盒会约束滚动截屏） |
| 工程 | XcodeGen（`project.yml`）+ SPM 6 模块 + 宿主 `App`；**Run 走 Release**（性能预算只在优化构建下有意义） |
| 模块依赖 | 只有 `MarqueeCore` 无依赖，其余只依赖 Core。**Core 持「接缝 + 编排」**，实现模块只给 OS 实现（编排才能脱机单测） |
| 签名 | **由 `project.yml` 负责**（Apple Development + `DEVELOPMENT_TEAM: UKXWZ3FS84`），不是构建脚本重签 |
| 任务管理 | matt pocock `to-tickets`；本地 markdown tracker 在 `.scratch/issues/`（**刻意入库**） |
| 快捷键 | 可配置（`shortcut.fullScreenCapture` 默认 **`⌃Q`**；⌃⌘A 被微信独占）。入口＝菜单栏「快捷键…」 |
| 截屏入口 | 覆盖层：拖拽＝区域（松开停住，方向键微调，`⏎` 提交）；单击/`⏎` 高亮窗口＝先停住再 `⏎` 截窗（`⌥` 去阴影）；无目标 `⏎`/双击＝整屏、`Esc` 取消 |
| **选区几何编辑（19）** | 落点后出 **8 控制点**。**按下分派顺序「控制点→框内→框外」不能换**；基准取**按下那一刻**那一版；最小 8 点停住不翻转；`⇧` 锁比例取位移大的轴；吸附 6 点、**只取屏幕 + 与选区相邻的窗口**、一方向只取最近一条、画贯穿全屏提示线 |
| 滚动截屏 | 菜单「滚动截屏」（**菜单已 5 项，PRD 上限 6，再加要先合并**）。拖区域/点窗口＝立刻抓帧；`空格`＝自动滚动开关；`⏎` 结束、`⌘S` 结束并落盘、`Esc` 取消。**已知限制：面板失去 key 焦点后键盘失效** |
| 自动滚动要辅助功能授权 | **本项目唯一一处**。按需申请（按空格才问），拒绝即退回手动 |
| 滚动到底 | **"没动"只有在"真的滚过"之后才算"到底"**；`atBottom` 只是提示、不停抓帧；自动滚动另看长图高度有无增长 |
| 放大镜取色 | **只活在落点之前**。`⌥`＝悬停显示 HEX/RGB、点击复制；落点后 `⌥` 归「无阴影」。像素＝覆盖层出现后**取一屏冻结**。盒子＝采样 40 点 × 3 倍 = 120 点；能对准靠十字线 + 中心像素框 |
| **确认之后（21 起）** | 原图立刻进剪贴板（`⌘S` 才落盘），**就地出图、不开窗口**。标注由 `CaptureOutput.finish(inline:)` 栅格化，**失败必须让整次截图失败**（可能含打码）。**编辑器只从长截图进入** + `-marqueeDemoEditor` 自检入口 |
| **覆盖层工具栏＝标注工具条（24 已重排）** | **15 格 / 545×40 点**，四组：`[矩形][椭圆][表情][箭头][画笔][马赛克][文字] │ [样式] │ [识别文字] │ [撤销][重做][保存][钉图][✗][✓]`。**✗ 珊瑚红 / ✓ 绿**（对比度按 WCAG 算过）。**「选择」不再是工具位** ⇒ 没选工具时按在标注上＝选中拖动（`isSelecting: tool == nil`）；**「模糊」不再占格**，但 `AnnotationKind.blur` 与渲染/导出/编辑器一字未动。**色板×6 与尺寸×3 收进「样式」弹层**。`Esc` 分四级（弹层→草稿→工具→整次）。**硬约束：整条必须放得进 1024 点的屏** |
| 覆盖层里的对象编辑 | 点选走 `Annotation.contains`（箭头/画笔按**到路径距离**）；移动基准＝**按下那一刻的完整快照**；点一下不动不进撤销栈；`Delete` 删、`⌘Z`/`⇧⌘Z`；**选了任何工具都不显示选区控制点**；**`Esc` 退出任何工具** |
| 三个尺寸档按工具换意义 | 图形＝线宽（圆点）/ 打码＝强度（方块）。强度用**另一组值** `overlayRedactionStrengths = [4,8,16]` **点**（编辑器那三档单位是原图像素，复用会在 2x 屏差一倍） |
| 覆盖层打码底图 | 复用放大镜的**冻结整屏帧**（`OverlayRedactionSource`），必须复用 `SelectionLayout` + `ImageCompositing`（自己裁会在跨屏错位）。`AnnotationDrawing.sourceScale` **同时作用于裁图矩形与滤镜强度**。缺任一块屏的帧→**整体放弃** |
| 标注只在 Core 一份 | `AnnotationPalette`（色板/线宽）· `AnnotationDrawing`（**覆盖层与导出共用**）· `OverlayToolbar.layout()`（尺寸/位置/命中单一来源）· `OverlayAnnotationSession`（会话） |
| 标注坐标空间 | 覆盖层存**选区局部点**（原点＝选区**视觉左上角**，y 向下 ⇒ 取 Cocoa 矩形的 **`maxY`**）。只在栅格化那一刻换算，**线宽/字号/打码强度跟位置一起缩放** |
| 标注对象模型 | `Annotation.path: [CGPoint]` + `text`；路径不塞进 `AnnotationKind` 关联值；移动 `translated(by:)`、缩放 `applyFrame(_:)`。序号是文字工具的一个预设，只增不重排 |
| 覆盖层里的输入框 | 已实测可用（`panel.isKeyWindow=true`）⇒ 用真 `NSTextField`，中文输入法白拿。**编辑期间键盘整条让行**（只拦 `Esc`）。**「结算」≠「丢弃」**：点别处/`⏎` 结算，只 `Esc` 丢；改色/改尺寸/撤销连结算都不做（`Slot.preservesTextEditing`）。输入框固定 14 点 |
| 偏好设置（15） | 四页（通用/截屏/输出/快捷键），**改一下立刻生效、立刻落盘**（无「应用」）。延时＝覆盖层出现**之前**那几秒。`includeCursor` 用**闭包**注入采集器。阴影：偏好给默认、`⌥` 临时取反。**刻意没做"是否自动复制到剪贴板"** |
| 最近截图（16） | 仓库 `MarqueeHistory`：`index.json` + 原图 PNG + 标注 JSON（**分开存**，否则重编辑退化成在成品上再画）。接缝 `CaptureHistoryWriting` **在 Core**。复制＝重新栅格化。上限 20 / 面板 12；**只删自己写的文件** |
| 打包分发（18） | `scripts/package.sh` 七步出 DMG（**签名核验不过就停**）；DMG 本身也签 + 公证 + 装订。更新走**手动指引**（引入 Sparkle 不值） |
| 钉图（14） | 动作格 → 钉在最顶层、**钉在原位**（`anchor`）。**两个窗口**：本体 + 控制条（穿透 `ignoresMouseEvents` 后本体点不到自己）。滚轮缩放（**锚点左上角**）、四档不透明度、多张共存；`canBecomeKey = false`；`.canJoinAllSpaces`。状态在 `PinState`/`PinGeometry` |
| **鼠标光标（26）** | 规则在 Core `OverlayCursor.kind(at:in:)` + `kind(for:)`，**按点分派、不用 cursor rect**（cursor rect 只能表达矩形，而"压着标注"要按形状判）。分派顺序＝`mouseDown` 那条：拖拽中→弹层→工具条（**灰格给箭头**）→文字输入框→控制点→长截图(箭头)→选了工具(内十字/外箭头)→没选工具(框内 openHand / 框外 crosshair)。视图在 **三处**问一次：`mouseMoved`、**`mouseDragged`**（拖拽期没有 mouseMoved）、presentation 变化时用 `NSEvent.mouseLocation` 补一次；多屏时**只由包含该点的那个视图**设，且同一值不重复 `set()` |
| 选中标注的控制点（22） | 8 点，与选区控制点同一套样子/光标；**只有恰好选中一个**时才出。复用 `SelectionGeometry` 但**必须先过 `YDown.flip`**（不翻的表现是"拖上边动下边"）。`cancelStroke()` 是所有手势收尾的**唯一一处** |
| 打码 / 裁切 | 打码走 **CoreImage**（比手写快 6 倍）。裁切只改 `cropRect`，**裁切外的标注保留不动**；拖框期间不进撤销栈 |
| 窗口截图 + 就地标注 | **强制 `includeShadow: false`**（带阴影的图比窗口矩形大一圈 ⇒ 标注整体偏移） |
| 文字渲染 | 编辑器与导出**共用 `AnnotationText`**（CoreText）。**文字是点放式**（`isStrokeBased = draws && self != .text`）；三档含义由 `OverlaySizeMeaning` 给（线宽 2/4/8 · 打码 4/8/16 · 字号 18/28/44） |
| 测试目标结构 | `MarqueeCoreTests`（纯逻辑）+ `MarqueeHistoryTests` + `MarqueeCaptureTests`（真实 Vision 自检）+ `MarqueeTestSupport`（**测试专用**） |
| 权限探针 | granted / notDetermined / **进程内 denied**（**不要**写 UserDefaults）。`requestPermission()` 必须碰一次 `SCShareableContent` **枚举** |
| 坐标空间 | **覆盖层内部一律用 Cocoa 全局点坐标**，只在提交采集时经 `ScreenCoordinateConversion` 转 Quartz（y 相反，混用静默错位） |
| 跨屏选区 | 逐屏取交集后拼接，输出 scale 取参与屏里**最大**的 |
| OCR（13） | 入口是**动作**不是工具；**启动必须预热**（首次 25 s）。⚠️ ticket 21 曾因此把它的唯一入口藏了（PITFALLS 69）。**23 已接进覆盖层工具栏**；编辑器里那份保留。**两处共用同一识别器实例** |
| **悬浮面板材质（17a）** | 覆盖层工具条 / 钉图控制条 / 倒计时 HUD 换系统材质。**决策点＝`ChromeMaterial.resolved(glassAvailable:)`（入参化 ⇒ 可脱机单测）**；参数在 `ChromeStyle`，两分支**同源**。15.x 退 `NSVisualEffectView(.hudWindow)`（深色，浅色模式下白字才不糊）。自检 `defaults write dev.tango.Marquee chrome.forceHUD -bool YES`。**工具条＝两个兄弟子视图**（材质底 + 前景）；读数框/提示框**留平深色**；编辑器窗口不动（PITFALLS 89–92） |
| **本地化（17b）** | **单一 catalog**：`App/Resources/Localizable.xcstrings`（`project.yml` 里**显式** `buildPhase: resources`，不走 syncedFolder）+ `options.developmentLanguage: zh-Hans`。**key ＝中文原句**；`L10n.t` 收 `String.LocalizationValue`（插值直接写在字面量里 —— 拼好再传 `String` 会**静默失效**）。**说明符按类型**：`Int`→`%lld`、`Int32`/`OSStatus`→`%d`、`UInt32`→`%u`、`String`→`%@`、`Double`/`CGFloat`→`%lf`（实测，勿靠记忆）。不翻的用 `// L10N-EXEMPT[-START/-END]: 理由`。**6 条扫描测试**（含扫描器自检）。188 key / 197 处 |

## 构建与测试（走脚本，不要手敲裸命令）

```bash
./scripts/build.sh   # XcodeGen 生成 + xcodebuild；含必需设置前置检查
./scripts/test.sh    # swift test --disable-sandbox（参数是必需的）→ 当前 450 全绿
./scripts/package.sh # 打包公证（七步，需要 Developer ID 证书）
```

**必需的一次性设置**（见 `docs/DEV-NOTES.md` 4）：
```bash
defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
```

## 不可砍 / 明确砍掉

1. **窗口自动识别 + 悬停高亮**；2. **滚动截屏 / 长截图**；3. **标注为对象、可反复编辑**（导出时才栅格化）。
砍掉：QQ 邮箱分享、QQ 邮箱网页插件。

## 设计硬约束（用户明确要求「功能简洁 + 交互流畅」）

菜单栏下拉 ≤ 6 项；编辑器工具栏 ≤ 9 工具；首选项 ≤ 4 页；模式弹窗 0 个。
**覆盖层工具栏整条必须放得进 1024 点的屏**（超出时贴边夹取会把最右按钮推出屏幕，而它看起来只是"有点长"）。
性能：编辑器重绘（≤100 标注）≤ 4 ms；选区拖拽 120 fps；模糊/马赛克 ≤ 5 ms；落点→剪贴板 ≤ 150 ms。

## 核心风险

- **R1 滚动截屏**：中（可行性已验证）。剩余全在**真实场景**：sticky header / 惯性 / 动态内容
- **R10 OCR 首次约 25 s** → 启动预热；**R11 超长图（1200×9000）画布渲染**（瓶颈可能是画布尺寸）
- ~~R4 全局快捷键~~、~~R7 标注对象模型~~：已消除

## 最狠的几条陷阱（全量见 `docs/PITFALLS.md`）

- **不崩不报错、只悄悄错**：位图行序/CTM 翻转、`bytesPerRow` 未对齐、P3 vs sRGB、拼接取行区间与 `floor`；AppKit 里**子视图永远盖在父视图自己画的东西之上**（PITFALLS 89）。
- **用户说"点了没反应"**：先验入口通不通（可选回调漏接线＝静默 no-op），再看下游渲染。
- **瞬时标志位不许决定常驻 UI 的可见性**：收尾只能有一处（一个 `defer`），判据只用会话状态（PITFALLS 66：我这样丢过一次工具栏）。
- **误判不能做成终局**：降级为"提示 + 可恢复"；判定先验前提（"没动"只有在"真的滚过"之后才算"到底"）。
- **断言要写「意图」**：只写边界的测试是盲的（组间距 9→1 全绿通过，补"组间明显大于组内"才抓住）。
- **变异测试**是"断言有没有空跑"的唯一证据；变异要**模拟真实会写错的实现**（PITFALLS 65/68/73）。

## 文档与资产

| 路径 | 内容 |
| --- | --- |
| **`docs/PITFALLS.md`** | **110 条实现陷阱**（写代码前必扫） |
| **`docs/STATUS-AND-ACCEPTANCE.md`** | **进度 / 阻塞项 / 人工验收清单**（A–U 分组 + SPIKE 对应 + 排障速查）。验收与汇报从这份起 |
| `docs/PRD.md` / `docs/SPIKE-PLAN.md` | 产品与方案设计 / 坑点清单 + 提前验证报告（37 项） |
| `docs/DEV-NOTES.md` / `docs/RELEASE.md` | 开发循环的已知摩擦 / 打包公证更新的复现步骤 |
| `docs/SCREEN-RECORDING-PERMISSION.md` / `docs/RENDER-BENCH.md` | 权限完整复盘 / 渲染技术实测 |
| `Modules/Sources/MarqueeTestSupport/` | **测试专用**：合成长页 + 位图读取 / MAE |
| `.scratch/issues/2026-09-30-marquee-mvp/` | **26 条 ticket + INDEX**；**全部落地**（`17` 拆成 `17a` 玻璃 / `17b` 本地化；`24`–`26` 工具条/回归/光标），只剩人工验收 |
| `Tools/Spikes/`、`Tools/RenderBench/` | 独立验证工具，与产品代码分离 |

## 工作流约定

门禁 **spec → solution → test plan → impl → delivery**，逐段确认；TDD 红→绿 + 变异测试，测试永久留仓。
**未经明确指令不 commit/push。** 用户偏好极简编号指令（"1 提交 2 继续下一步"）。

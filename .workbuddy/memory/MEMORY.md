# Marquee · 项目长期记忆

> 工作目录 `/Users/tango/Developments/Marquee`（2026-09-30 由 `Snipo` 改名）；
> 远端 `git@github.com:tangzzz-fan/Marquee.git`；开发机 **macOS 27**。
> 定位：复刻腾讯 Snip 的 macOS 原生截屏工具。纯本地、无账号、键盘驱动。
>
> ⚠️ **写代码之前先扫 `docs/PITFALLS.md`**（140 条实测陷阱，多为"不崩溃、不报错、只悄悄错"）。
> 本文件只记**决策**与**索引**；理由与实现细节在 `docs/` 与 ticket 里。

## 身份 · 分发 · 收费

| 项 | 值 |
| --- | --- |
| 产品 / 最低系统 | **Marquee**，**macOS 15.0**；26/27 专属能力走 `if #available` + 降级 |
| **两个 bundle id** | 正式 `com.tango.Marquee` / 开发 `.dev`。**是不是开发版由后缀推导**（`MarqueeCore/AppIdentity`＝唯一来源）⇒ 偏好、数据、TCC 各一份。**只有 Release 拿正式 id**（"误发开发构建"配置上就不可能，`package.sh` 再核验）。**改名有时间窗**：ASC 上传过构建就不能再改，我们没上传过。见 `docs/DEV-VS-PROD.md` |
| 三个构建配置 | `Dev`＝**Run（默认）**，与 Release **同优化**（性能数字才可比）/ `Debug`＝只要"能用的断点"时用（**别拿它测性能**；断言只在它与 `swift test` 下生效）/ `Release`＝发版 + **内购真实沙盒验证** |
| **分支** | IAP 相关工作在 **`feat/iap`**（2026-10-03 起）；`main` 尚未合并改名 |
| **收费（已定：买断 ¥36）** | 非消耗型 IAP `com.tango.Marquee.pro`（¥36 是合法价格点，CNY ¥10–200 步长 ¥1）。**Pro 只含四项现存能力**：滚动截屏 / 识别文字 / 钉图 / 最近截图不设上限（免费 5）；其余全部免费。⚠️ **不许把没做的功能写成"锁着的"**。试用＝**0 价非消耗型 IAP**（3.1.1 官方路径），7 天、一次 |
| **权益（30 + 31）** | 判定在 Core `LicenseResolver`（纯函数）；**头号判据：`unknown` 必须放行**（否则付费用户启动先看到锁；历史也不许按免费裁剪）。31 两批已完成：`Storefront`（商品/交易/纯映射）· `EntitlementCache`（缓存**输入**而非结果）· `StorefrontSeams`（读取/购买接缝）· `EntitlementCoordinator`（启动编排）· `MarqueeStore`（StoreKit 适配器）。⚠️ 五条硬规则：**未校验的交易不算数** · **撤销可以被撤销** · **「商店里没有」只有真的问过才算证据**（查询失败时 `records` 也为空 ⇒ 断网锁死付费用户）· **启动不等网络** · **核实失败不改动判定** |
| **分发（已定：路线 B，上 MAS）** | **代价已接受：自动滚动砍掉、只留手动长截图**；Developer ID 那条路**并存**作后路。依据（已核实原文）：Apple 文档明文「用 `CGEventPost` 向其它 app 投递输入事件**不允许来自沙盒应用**」，DTS 亦答「沙盒 app 不能用辅助功能 API」⇒ **自动滚动与 MAS 互斥**（Snip 的 App Store 版同样"滚动截屏不可用"）。另：**桌面没有 entitlement** ⇒ `32` 要改 `~/Pictures/Marquee` + 数据迁移 |

## 工程与架构

| 项 | 值 |
| --- | --- |
| 工程 | XcodeGen（`project.yml`）+ SPM **7 个模块** + 宿主 `App`；`Tools/` 下是独立命令行验证工具 |
| 模块依赖 | **只有 `MarqueeCore` 无依赖，其余只依赖 Core，模块之间互不依赖。** **Core 持「接缝 + 编排」**，实现模块只给 OS 实现 —— 编排才能脱机单测 |
| 签名 | **由 `project.yml` 负责**（Apple Development + `DEVELOPMENT_TEAM: UKXWZ3FS84`）；`build.sh` 的 `codesign --identifier` **从产物 plist 读**（写死过一次，漏了就是"屏幕录制授权又留不住"） |
| 任务管理 | matt pocock `to-tickets`；本地 markdown tracker 在 `.scratch/issues/`（**刻意入库**） |
| 测试目标 | `MarqueeCoreTests`（纯逻辑）· `MarqueeHistoryTests` · `MarqueeCaptureTests`（真实 Vision 自检）· `MarqueeStoreTests`（商品配置一致性）· `MarqueeTestSupport`（测试专用） |

## 交互与实现（已固化，勿随意推翻）

| 项 | 值 |
| --- | --- |
| 快捷键 | 可配置（`shortcut.fullScreenCapture` 默认 **`⌃Q`**；⌃⌘A 被微信独占）。入口＝菜单栏「快捷键…」 |
| 截屏入口 | 覆盖层：拖拽＝区域（松开停住，方向键微调，`⏎` 提交）；单击/`⏎` 高亮窗口＝先停住再 `⏎` 截窗（`⌥` 去阴影）；无目标 `⏎`/双击＝整屏、`Esc` 取消 |
| 选区几何编辑（19） | 落点后出 **8 控制点**。**按下分派顺序「控制点→框内→框外」不能换**；基准取**按下那一刻**那一版；最小 8 点停住不翻转；`⇧` 锁比例取位移大的轴 |
| 滚动截屏 | 菜单「滚动截屏」（**菜单已 5 项，上限 6**）。`空格`＝自动滚动开关；`⏎` 结束、`⌘S` 结束并落盘。**已知限制：面板失去 key 焦点后键盘失效**。自动滚动要辅助功能授权（**本项目唯一一处**）、拒绝即退回手动。**"没动"只有在"真的滚过"之后才算"到底"** |
| 放大镜取色 | **只活在落点之前**。`⌥`＝悬停显示 HEX/RGB、点击复制；落点后 `⌥` 归「无阴影」。像素＝覆盖层出现后**取一屏冻结** |
| 确认之后（21 起） | 原图立刻进剪贴板（`⌘S` 才落盘），**就地出图、不开窗口**。标注栅格化**失败必须让整次截图失败**（可能含打码）。**编辑器只从长截图进入** |
| 覆盖层工具条（24） | **15 格 / 545×40 点**：`[矩形][椭圆][表情][箭头][画笔][马赛克][文字] │ [样式] │ [识别文字] │ [撤销][重做][保存][钉图][✗][✓]`。**✗ 珊瑚红 / ✓ 绿**（WCAG ≥4.5:1）。**「选择」不再是工具位**（没选工具时按标注＝选中拖动）；**「模糊」不再占格**但 `AnnotationKind.blur` 未动。色板×6 + 尺寸×3 收进「样式」弹层；`Esc` 四级。**硬约束：整条放得进 1024 点的屏** |
| 图标（28） | **SF Symbol 会自动本地化**（`textformat` 中文下变**「格式」两个字**）⇒ 用 `t.square` 这类语言无关的；多色符号在 `paletteColors` 下**第一层被整片填充** ⇒ `drawSymbol` 必须 `.preferringMonochrome()`。点亮判据＝`OverlayToolbarHighlight.isLit`（**只认自己那个弹层**） |
| 尺寸档的画法（27） | `MarqueeCore/SizeSwatchGeometry`：形状（线宽圆点 / 打码方块 / 字号字母 A）+ 大小**按档位序号均分**，覆盖层与编辑器共用。⚠️ **不许按数值线性映射**（打码 4/8/16 会画成 9.6/15.2/16，后两档看不出区别）。编辑器工具栏已无汉字按钮 |
| 鼠标光标（26） | 规则在 Core `OverlayCursor.kind(at:in:)`，**按点分派、不用 cursor rect**（命中比矩形细时它会骗人）。视图在**三处**问一次：`mouseMoved`、**`mouseDragged`**、presentation 变化时用 `mouseLocation` 补。多屏只由**包含该点**的视图设，同一值不重复 `set()` |
| 标注 | 只在 Core 一份：`AnnotationPalette` · `AnnotationDrawing`（覆盖层与导出**共用**）· `OverlayToolbar.layout()` · `OverlayAnnotationSession`。坐标存**选区局部点**（原点＝视觉左上角、y 向下 ⇒ 取 Cocoa 的 `maxY`），只在栅格化那一刻换算，**线宽/字号/打码强度跟位置一起缩放**。标注＝对象，导出时才栅格化 |
| 覆盖层输入框 | 用真 `NSTextField`（中文输入法白拿）。**编辑期间键盘整条让行**（只拦 `Esc`）。**「结算」≠「丢弃」**：点别处/`⏎` 结算，只 `Esc` 丢 |
| 偏好设置（15） | 四页（通用/截屏/输出/快捷键），**改一下立刻生效、立刻落盘**（无「应用」）。延时＝覆盖层出现**之前**那几秒。**刻意没做"是否自动复制到剪贴板"** |
| 最近截图（16） | `MarqueeHistory`：`index.json` + 原图 PNG + 标注 JSON（**分开存**，否则重编辑退化成在成品上再画）。复制＝重新栅格化。上限 20 / 面板 12；**只删自己写的文件** |
| 钉图（14） | 钉在最顶层、**钉在原位**。**两个窗口**：本体 + 控制条（穿透 `ignoresMouseEvents` 后本体点不到自己）。滚轮缩放（**锚点左上角**）、四档不透明度、多张共存；`canBecomeKey = false` |
| 悬浮面板材质（17a） | 决策点＝`ChromeMaterial.resolved(glassAvailable:)`（入参化 ⇒ 可脱机单测）；参数在 `ChromeStyle`，两分支**同源**。15.x 退 `NSVisualEffectView(.hudWindow)`。**工具条＝两个兄弟子视图**（材质底 + 前景）；读数框留平深色 |
| 本地化（17b） | **单一 catalog**：`App/Resources/Localizable.xcstrings`（显式 `buildPhase: resources`）+ `developmentLanguage: zh-Hans`。**key ＝中文原句**；`L10n.t` 收 `String.LocalizationValue`（**插值必须写在字面量里**，拼好再传会静默失效）。**说明符按类型**（`Int`→`%lld`、`Int32`/`OSStatus`→`%d`、`UInt32`→`%u`、`String`→`%@`、`Double`/`CGFloat`→`%lf`）。不翻的用 `// L10N-EXEMPT[-START/-END]: 理由`。**不要用 Xcode 的 Extract Strings** |
| 打码 / 裁切 | 打码走 CoreImage（比手写快 6 倍）。裁切只改 `cropRect`，**裁切外的标注保留不动**；拖框期间不进撤销栈 |
| 窗口截图 + 就地标注 | **强制 `includeShadow: false`**（带阴影的图比窗口矩形大一圈 ⇒ 标注整体偏移） |
| 坐标空间 | **覆盖层内部一律用 Cocoa 全局点坐标**，只在提交采集时经 `ScreenCoordinateConversion` 转 Quartz（y 相反，混用静默错位）。跨屏＝逐屏取交集后拼接，scale 取最大 |
| 权限探针 | granted / notDetermined / **进程内 denied**（**不要**写 UserDefaults）。`requestPermission()` 必须碰一次 `SCShareableContent` **枚举** |
| OCR（13） | 入口是**动作**不是工具；**启动必须预热**（首次 25 s）。覆盖层与编辑器**共用同一识别器实例** |

## 构建与测试（走脚本，不要手敲裸命令）

```bash
./scripts/build.sh       # XcodeGen 生成 + xcodebuild；默认配置 Dev
./scripts/test.sh        # swift test --disable-sandbox（参数必需）→ 564 全绿
CONFIGURATION=Release ./scripts/build.sh   # 发版 / 内购真实沙盒验证
./scripts/package.sh     # 打包公证（七步，需要 Developer ID 证书）
```

**必需的一次性设置**（`docs/DEV-NOTES.md` 4）：
`defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES`

**构建/测试不用每次重敲**：本机已固化两个技能（用户级 `~/.workbuddy/skills/`）——
`macos-build-test`（macOS 本机 + SwiftPM）与 `ios-build-test`（iOS 模拟器/真机），
各带一个 `scripts/*-run.sh`：**自动判断要不要沙箱逃逸**、自动挑模拟器、
固定 derivedData、日志落文件只回打关键行。先跑 `… probe` 看环境。

⚠️ **被外部沙箱包裹的 shell 里要加 `MARQUEE_DISABLE_COMPILER_SANDBOX=1`**：
那里的 `swift-plugin-server`（宏）无法 apply 自己的沙箱，报 `sandbox_apply: Operation not permitted`
→ 宏展开失败。逃逸口是 `swiftc` 自己的 `-disable-sandbox`（**官方那三个 `IDEPackageSupport*`
参数无效**，它们关的是内层）。已固化进 `build.sh`，默认不开。**有了它我可以自己跑完整构建。**

## 不可砍 / 明确砍掉

1. **窗口自动识别 + 悬停高亮**；2. **滚动截屏 / 长截图**；3. **标注为对象、可反复编辑**。
砍掉：QQ 邮箱分享、QQ 邮箱网页插件。

## 设计硬约束（用户明确要求「功能简洁 + 交互流畅」）

菜单栏下拉 ≤ 6 项；编辑器工具栏 ≤ 9 工具；首选项 ≤ 4 页；模式弹窗 0 个。
**覆盖层工具条整条必须放得进 1024 点的屏**。
性能：编辑器重绘 ≤ 4 ms；选区拖拽 120 fps；模糊/马赛克 ≤ 5 ms；落点→剪贴板 ≤ 150 ms。

## 核心风险

- **R1 滚动截屏**：中。剩余全在**真实场景**（sticky header / 惯性 / 动态内容）
- **R10 OCR 首次约 25 s** → 启动预热；**R11 超长图画布渲染**

## 最狠的几条陷阱（全量见 `docs/PITFALLS.md`）

- **不崩不报错、只悄悄错**：位图行序/CTM 翻转、`bytesPerRow` 未对齐、P3 vs sRGB；AppKit 里**子视图永远盖在父视图自己画的东西之上**（89）。
- **`nil` 兜底会把"不适用"变成"合法值"**，判据从此永远成立（101）。**`lineWidth = 0` 不是"不画线"**（120）。
- **改一个判据常量的「含义」之前先列出它的所有使用者** —— 条件等价 ≠ 运行路径等价（102）。
- **瞬时标志位不许决定常驻 UI 的可见性**；收尾只能有一处（一个 `defer`），判据只用会话状态（66）。
- **误判不能做成终局**：降级为"提示 + 可恢复"。**「商店里没有」只有在真的问过之后才算证据**（126）。
- **断言要写「意图」**：只写边界的测试是盲的；**用例参数要覆盖最坏情况**，不是典型情况（98）。
- **变异不变红有两种可能：断言是盲的，或那段代码是死的** —— 两者处理完全相反（117）。
- **删入口 ≠ 删能力**：模型是数据契约、UI 是入口，生命周期不一样（100）。
- **适配器里不许做判断**：提前过滤掉的东西，那条规则就只剩真机才跑得到（130）。

## 文档与资产

| 路径 | 内容 |
| --- | --- |
| **`docs/PITFALLS.md`** | **140 条实现陷阱**（写代码前必扫） |
| **`docs/MAS-AND-MONETIZATION.md`** | **收费与上架方案（决策已定）**：买断 ¥36 · 路线 B · Pro 边界与**「被挡住时」的界面行为** · ticket 29–33 施工图 |
| **`docs/DEV-VS-PROD.md`** | **开发版与正式版怎么区分**（两个 id · 三个配置 · 改名时间窗 · 波及面） |
| **`docs/STATUS-AND-ACCEPTANCE.md`** | **进度 / 阻塞项 / 人工验收清单**（A–Z 分组 + SPIKE 对应 + 排障速查）。验收与汇报从这份起 |
| `docs/PRD.md` / `docs/SPIKE-PLAN.md` | 产品与方案设计 / 坑点清单 + 提前验证报告 |
| `docs/DEV-NOTES.md` / `docs/RELEASE.md` | 开发循环的已知摩擦 / 打包公证更新的复现步骤 |
| `docs/SCREEN-RECORDING-PERMISSION.md` / `docs/RENDER-BENCH.md` | 权限完整复盘 / 渲染技术实测 |
| `.scratch/issues/2026-09-30-marquee-mvp/` | **33 条 ticket + INDEX**；`01`–`30` 与 `31` 两批已落地，`31` 剩界面，`32`/`33` 沙盒化待开工 |
| `Tools/IconGen/` | **App 图标生成器**：按 Apple 网格逐尺寸原生渲染十档 |
| `Tools/L10nCatalog/` | **文案目录生成器**：唯一能**生成** catalog 的工具（扫描测试只能校验） |
| `Tools/SymbolProbe/` | SF Symbol 探针（en / zh-Hans 各渲一张对照图） |

## 工作流约定

门禁 **spec → solution → test plan → impl → delivery**，逐段确认；TDD 红→绿 + 变异测试，测试永久留仓。
**未经明确指令不 commit/push。** 用户偏好极简编号指令（"1 提交 2 继续下一步"）。

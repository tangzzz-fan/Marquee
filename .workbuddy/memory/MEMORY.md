# Marquee · 项目长期记忆

> 工作目录：`/Users/tango/Developments/Marquee`（2026-09-30 由 `Snipo` 改名，git 历史连续）。
> 定位：复刻腾讯 Snip 的 macOS 原生截屏工具。纯本地、无账号、键盘驱动。
>
> ⚠️ **写任何代码之前先扫一遍 `docs/PITFALLS.md`**（53 条实测陷阱，多为"不崩溃、不报错、只悄悄错"）。
> 本文件只记**决策**与**索引**，实现细节在代码注释与 `docs/`。

## 已固化决策（勿随意推翻）

| 项 | 值 |
| --- | --- |
| 产品名 / 最低系统 | **Marquee**（`dev.tango.Marquee`）；**macOS 15.0**，26/27 专属能力走 `if #available` + 降级 |
| 采集 / 覆盖层 | **ScreenCaptureKit**（不用已弃用的 `CGWindowListCreateImage`）；覆盖层＝**AppKit 逐屏 `NSPanel`**，不铺整屏截图（只做变暗蒙层 + 镂空 + 描边） |
| 画布渲染 | **SwiftUI Canvas**（实测最优）；CG 只用于导出/剪贴板/降采样，滤镜走 CoreImage；**Metal 首期不引入**，留 `CanvasRendering` 协议边界 |
| 分发 | Developer ID 公证，**非 MAS**（沙盒会约束滚动截屏等系统级能力） |
| 工程 | XcodeGen（`project.yml`）+ SPM 本地包 6 模块：Core / Capture / Overlay / Editor / Settings / History；宿主 target `App`。**Run 走 Release**（性能预算只在优化构建下有意义） |
| 模块依赖方向 | 只有 `MarqueeCore` 无依赖，其余只依赖 Core。**Core 额外持有「接缝（协议/值类型）+ 编排逻辑」**，实现模块只提供 OS 实现 —— 编排要能脱机单测，而 SwiftPM 依赖单向 |
| 签名 | **由 `project.yml` 负责**（`Apple Development` + `DEVELOPMENT_TEAM: UKXWZ3FS84`），**不是**构建脚本重签 |
| 任务管理 | matt pocock `to-tickets`；本地 markdown tracker 在 `.scratch/issues/`（**刻意入库**） |
| 快捷键 | **可配置**（`shortcut.fullScreenCapture`，**默认 `⌃Q`**；⌃⌘A 被微信独占）。入口＝菜单栏「快捷键…」 |
| 截屏入口 | **选区覆盖层**：拖拽＝区域（松开停住，方向键微调，`⏎` 提交）；单击/`⏎` 高亮窗口＝先停住，再 `⏎` 截这扇窗（`⌥` 去阴影）；无目标时 `⏎`/双击＝整屏、`Esc`＝取消 |
| 滚动截屏入口 | 菜单栏「滚动截屏」（**菜单 6 项已到 PRD 上限，再加要先合并**）。拖区域/点窗口＝**立刻开始抓帧**；`空格`＝开始/停止**自动滚动**；`⏎` 结束、`⌘S` 结束并落盘、`Esc` 取消（自动滚动中 `Esc` 只停滚动）。**已知限制：面板失去 key 焦点后键盘会失效** |
| **自动滚动要「辅助功能」授权** | **本项目唯一一处**。手动滚动一个事件都不用发；自动滚动必须代发滚轮事件，而 macOS 把"向其它进程注入事件"划进辅助功能。因此**按需**申请（按空格才问），拒绝即退回手动，其余能力一行不受影响 |
| 滚动到底的判定 | **"没动"只有在"真的滚过"之后才算"到底"**；`atBottom` 只是**提示**，不停抓帧。自动滚动的"到底"另看长图高度有没有增长 |
| 放大镜取色 | **只活在落点之前**（落点后与长截图抓帧时都收起）。`⌥`＝悬停显示 HEX/RGB、悬停点击复制色值；落点后 `⌥` 归「无阴影」。像素＝覆盖层出现后**取一屏冻结** |
| 放大镜尺寸 | **采样 40 点 × 3 倍 = 120 点盒子**；`zoom` 是**用户感知倍数**且取整。**"能对准"靠十字线 + 中心像素框，不靠看清像素**。现场调参 `defaults write dev.tango.Marquee lens.zoom -float 4`（下次唤起覆盖层生效） |
| 确认之后 | 原图立刻进剪贴板（`⌘S` 才落盘），同时打开编辑器；编辑器 `Esc` 把标注栅格化后写回剪贴板并关闭 |
| 标注对象模型 | `Annotation.path: [CGPoint]`（箭头 2 点 / 画笔折线）+ `text`；**路径不塞进 `AnnotationKind` 关联值**；移动走 `translated(by:)`（框与路径一起走），缩放走 `applyFrame(_:)`。序号是**文字工具的一个预设**，**只增不重排** |
| 打码 / 裁切 | 打码**走 CoreImage**（比手写快 6 倍），`CIContext` 是共享常量。裁切只改 `cropRect`，**裁切外的标注保留不动**（撤销天然正确）；拖框期间不进撤销栈 |
| 文字渲染 | 编辑器与导出**共用 `MarqueeCore.AnnotationText`**（CoreText）—— 各画各的会出现"编辑器放得下、导出被裁半个字" |
| 编辑器验证入口 | `-marqueeDemoEditor`：合成图 + 八类标注各一个，不自动退出、**不需要屏幕录制权限** |
| 测试目标结构 | `MarqueeCoreTests`（纯逻辑）+ **`MarqueeCaptureTests`**（真实 Vision 装置自检）+ `MarqueeTestSupport`（**测试专用**，不挂宿主 target） |
| 权限探针 | 返回 granted / notDetermined / **进程内 denied**（问过仍未授权；**不要**写 UserDefaults）。`requestPermission()` 必须碰一次 `SCShareableContent` **枚举**（不要截帧） |
| 坐标空间 | **覆盖层内部一律用 Cocoa 全局点坐标**，只在提交采集时经 `ScreenCoordinateConversion` 转 Quartz。两者 y 轴相反，混用会静默错位 |
| 跨屏选区 | 逐屏取交集后拼接，输出 scale 取参与屏里**最大**的 |
| OCR（ticket 13） | 入口是**动作**不是工具（工具栏 9 个位置被 PRD 列满，OCR 不在其中）；**启动必须预热**（首次 25 s，不热则第一次点像卡死）；结果面板用 `Text` + `textSelection`（可划可 ⌘C） |
| 本地 AI / 视觉 | 只做系统级 Vision OCR；Liquid Glass 必须 `if #available(macos 26.0)` |

## 构建与测试（走脚本，不要手敲裸命令）

```bash
./scripts/build.sh   # XcodeGen 生成 + xcodebuild；含必需设置的前置检查
./scripts/test.sh    # swift test --disable-sandbox（参数是必需的）
```

**必需的一次性设置**（原因见 `docs/DEV-NOTES.md` 4）：
```bash
defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
```

## 不可砍的功能（替代旧版的关键）

1. **窗口自动识别 + 悬停高亮**（旧版招牌）
2. **滚动截屏 / 长截图**（11 手动 → 12 自动，均已实现）
3. **标注为对象、可反复编辑**（导出时才栅格化）

明确砍掉：QQ 邮箱分享、QQ 邮箱网页插件。

## 设计硬约束（用户明确要求「功能简洁 + 交互流畅」）

菜单栏下拉 ≤ 6 项；编辑器工具栏 ≤ 9 工具；首选项 ≤ 4 页；模式弹窗 0 个。
编辑器重绘（≤100 标注）≤ 4 ms；选区拖拽 120 fps；模糊/马赛克 ≤ 5 ms；落点→剪贴板 ≤ 150 ms。

## 核心风险

- **R1 滚动截屏**：中（可行性已验证）。剩余全在**真实场景**：sticky header / 惯性 / 动态内容
- **R10 OCR 首次调用约 25 秒** → 必须启动时后台预热
- **R11 超长图（1200×9000）画布渲染**：图元数不是瓶颈，画布尺寸可能是
- ~~R4 全局快捷键~~、~~R7 标注对象模型~~：**已消除**

## 已提前验证的结论（详见 `docs/SPIKE-PLAN.md`）

| 结论 | 细节 |
| --- | --- |
| 配准主方案＝Vision | `VNTranslationalImageRegistrationRequest`；自研 SAD 正确但 **258 ms/次太慢** |
| 端到端拼接 | vs 真值 **MAE 0.000/255**；480×600 帧配准 **8.3 ms/次** → 不需要降采样 |
| Vision 位移符号 | **`rows = +ty`**（targeted = 上一帧、handler = 当前帧） |
| 全局快捷键 | Carbon `RegisterEventHotKey`，无需辅助功能权限；冲突码 `-9878` **只在独占注册时**才出得来 |
| 权限检测 | `CGPreflightScreenCaptureAccess()` / `...ListenEventAccess()` / `...PostEventAccess()` 都能在 Swift 里直接调（**头文件没声明**，符号在 `CoreGraphics.tbd`） |
| Liquid Glass | `NSGlassEffectView` = macos 26.0+（`effectIsInteractive` = 27.0） |
| 合成滚轮事件 | `CGEvent(scrollWheelEvent2Source:units:.pixel,wheelCount:1,wheel1:…)` + `.post(tap: .cghidEventTap)`；**向下滚 `wheel1` 是负值** |

## 最狠的几条陷阱（全量见 `docs/PITFALLS.md`）

- **不崩不报错、只悄悄错**那一类：位图行序/CTM 翻转（图上下颠倒、位移符号反转）、`bytesPerRow` 未对齐、P3 vs sRGB、拼接取行区间与 `floor`。
- **用户说"点了没反应"时，第一件事是验入口通不通**（可选回调漏接线＝静默 no-op），再看下游渲染。
- **误判不能做成终局**：自动判定触发时降级为"提示 + 可恢复"，别停机。
- **判定要先验前提**："没动"只有在"真的滚过"之后才算"到底"。
- **谁改谁推**：改了状态要自己推给视图，别依赖调用方顺手 `refresh()`。
- **断言要写「意图」**，不能只写不能违反的边界；对称的测试图与纯色测试图都是盲的。
- **变异测试**是"断言有没有空跑"的唯一证据（改坏一处 → 必须变红）。

## 文档与资产

| 路径 | 内容 |
| --- | --- |
| **`docs/PITFALLS.md`** | **53 条实现陷阱**（写代码前必扫） |
| **`docs/STATUS-AND-ACCEPTANCE.md`** | **进度 / 阻塞项 / 人工验收清单**（A–J 分组 + SPIKE M1–M20 对应 + 排障速查）。验收与汇报都从这份起 |
| `docs/PRD.md` | 产品与方案设计 |
| `docs/SPIKE-PLAN.md` | 坑点/难点/重点清单 + 提前验证报告（37 项） |
| `docs/DEV-NOTES.md` | 开发循环的已知摩擦（签名、沙箱、工程生成、宏插件被杀） |
| `docs/SCREEN-RECORDING-PERMISSION.md` | 屏幕录制权限完整复盘 |
| `docs/RENDER-BENCH.md` | 渲染技术实测报告 |
| `Modules/Sources/MarqueeTestSupport/` | **测试专用**：合成长页 + 位图读取 / MAE |
| `.scratch/issues/2026-09-30-marquee-mvp/` | **18 条 ticket + INDEX**（本地 tracker） |
| `Tools/Spikes/`、`Tools/RenderBench/` | 独立验证工具，与产品代码分离 |

## 工作流约定

沿用既有门禁：**spec → solution → test plan → impl → delivery**，逐段确认；
TDD 红→实现→绿，测试永久留仓 + 变异测试。**未经明确指令不 commit/push。**
变更记录到 `docs/`。用户偏好极简编号指令（"1 提交 2 继续下一步"）。

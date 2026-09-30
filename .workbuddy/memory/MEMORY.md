# Marquee · 项目长期记忆

> 工作目录：`/Users/tango/Developments/Marquee`（2026-09-30 由 `Snipo` 改名，git 历史连续）。
> 首次提交：`160e524`。

## 项目定位

复刻腾讯 Snip 的 macOS 原生截屏工具（旧版 2012-11-30 v2.0 后实质停更，Cocoa/Intel 架构）。纯本地、无账号、键盘驱动。

## 已固化决策（2026-09-30 确认，勿随意推翻）

| 项 | 值 |
| --- | --- |
| 产品名 | **Marquee**（bundle id `dev.tango.Marquee`） |
| 最低系统版本 | **macOS 15.0**；26/27 专属能力走 `if #available` |
| 采集 | **ScreenCaptureKit**（`SCScreenshotManager` / `SCStream`），不用已弃用的 `CGWindowListCreateImage` |
| 覆盖层 | **AppKit 逐屏 `NSPanel`**，不铺整屏截图（只做变暗蒙层 + 选区镂空 + 高亮描边） |
| 画布渲染 | **SwiftUI Canvas**（实测最优）。CG 仅用于导出/剪贴板/降采样；滤镜走 CoreImage；**Metal 首期不引入**，留 `CanvasRendering` 协议边界 |
| 分发 | Developer ID 公证分发，**非 MAS**（MAS 沙盒会约束滚动截屏等系统级能力） |
| 视觉 | 原生 Liquid Glass（`NSGlassEffectView` = macos 26.0+，必须 `if #available` + 降级） |
| 本地 AI | 只做系统级（Vision OCR），不引入本地视觉模型 |
| 工程 | XcodeGen（`project.yml`）+ SPM 本地包 6 模块：Core / Capture / Overlay / Editor / Settings / History；宿主 target `App` |
| 任务管理 | matt pocock `to-tickets`；本地 markdown tracker 在 `.scratch/issues/`（**刻意入库**） |
| 模块依赖方向 | 只有 `MarqueeCore` 无依赖，其余只依赖 Core。**Core 额外持有"接缝（协议/值类型）+ 编排逻辑"**（`CaptureSeams.swift` / `FullScreenCaptureFlow.swift` / `ShortcutService.swift`），实现模块只提供 OS 实现。理由：编排要能脱机单测，而 SwiftPM 依赖是单向的（ticket 02 定） |
| 快捷键可配置 | **从 ticket 02 起就是可配置的**（用户明确要求"启动后能换键"）。`UserDefaults` 键 `shortcut.fullScreenCapture`，**默认 `⌃Q`**（2026-09-30 由用户从 ⌃⌘A 改过来 —— ⌃⌘A 被微信独占占用）；入口＝菜单栏「快捷键…」 |
| 截屏入口 | **ticket 03 起＝选区覆盖层**。拖拽＝区域（松开后停住，方向键微调，`⏎` 提交）；单击或 `⏎` 高亮窗口＝**先停住**，再 `⏎` 才截这一扇窗（带阴影；`⌥` 无阴影）；叠层画面用拖选区。无目标时 `⏎`/双击＝整屏、`Esc`＝取消。**不另设"直接全屏"菜单项** |
| 签名 | **由 `project.yml` 负责**（`Apple Development` + `DEVELOPMENT_TEAM: UKXWZ3FS84`），**不是**构建脚本重签 —— Xcode Run 不执行脚本，只改脚本等于没修。ad-hoc 会让 TCC 每次都当新应用 → 权限反复索要。见 DEV-NOTES 第 1 节 |
| 权限探针 | `SystemScreenRecordingPermission` 返回 granted / notDetermined / **进程内 denied**（问过一次仍未授权；**不要**写 UserDefaults）。`requestPermission()` 必须碰一次 `SCShareableContent` **枚举**（不要截帧），同一进程只弹一次系统框；刚授权必须重启后 SCK 才可用。见 DEV-NOTES 第 1 / 1.1 / 1.3 节 |
| 坐标空间 | **覆盖层内部一律用 Cocoa 全局点坐标**（`NSEvent`/`NSScreen` 都在这个空间），只在提交采集时经 `ScreenCoordinateConversion` 转 Quartz。`DisplayGeometry.frame` / `CGDisplayBounds` 是 Quartz。两者 y 轴相反，混用会静默错位 |
| 跨屏选区 | 逐屏取交集后拼接（`SelectionLayout` + `ImageCompositing`），输出 scale 取参与屏里**最大**的（不丢信息）。不用 15.2+ 的 `captureImage(in:)`：高于最低系统，且输出分辨率不受控 |

## 构建与测试（走脚本，不要手敲裸命令）

```bash
./scripts/build.sh   # XcodeGen 生成 + xcodebuild；含必需设置的前置检查
./scripts/test.sh    # swift test --disable-sandbox（参数是必需的）
```

**必需的一次性设置**（原因见 `docs/DEV-NOTES.md` 第 4 节）：
```bash
defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
```

## 不可砍的功能（替代旧版的关键）

1. **窗口自动识别 + 悬停高亮**（旧版招牌）
2. **滚动截屏 / 长截图**（分期：ticket 11 手动滚动 → ticket 12 自动滚动）
3. **标注为对象、可反复编辑**（选中/移动/缩放/改色/改线宽，导出时才栅格化）

明确砍掉：QQ 邮箱分享、QQ 邮箱网页插件（依赖腾讯账号体系）。

## 设计原则（用户明确要求）

**功能简洁 + 交互流畅**，量化为硬约束：
- 菜单栏下拉 ≤ 6 项；编辑器工具栏 ≤ 9 工具；首选项 ≤ 4 页；模式弹窗 0 个
- 编辑器重绘（≤100 标注）≤ 4ms；选区拖拽 120fps；模糊/马赛克 ≤ 5ms；落点→剪贴板 ≤ 150ms

## 核心风险

- **R1 滚动截屏**：中风险（已验证可行性，见下）。真实场景（sticky header / 惯性 / 动态内容）待实测
- **R7 标注对象模型做浅了**：会丢掉对旧版的核心优势——对象模型必须先行
- **R10 OCR 首次调用约 25 秒** → 必须启动时后台预热
- **R11 超长图（1200×9000）画布渲染**：图元数不是瓶颈，画布尺寸可能是
- ~~R4 全局快捷键~~：**已消除**（Carbon 无需辅助功能权限）

## 已提前验证的关键结论（SPIKE-PLAN.md）
| 结论 | 细节 |
| --- | --- |
| 滚动配准可行 | 端到端拼接 vs 真值 **MAE 0.000/255**；Vision 平移配准精确无误差 |
| **配准主方案 = Vision** | `VNTranslationalImageRegistrationRequest`；自研 SAD 正确但 **258ms/次太慢** |
| 亚像素必须处理 | 整数累积误差 ±0.5px → 抛物线精化 0.04px，按**累计小数位移重采样** |
| 全局快捷键 | Carbon `RegisterEventHotKey`，无需辅助功能权限；**冲突码 `-9878` 只在"独占注册"时才出得来**（见陷阱 14） |
| 权限检测 | `CGPreflightScreenCaptureAccess()` / `CGPreflightListenEventAccess()` / `AXIsProcessTrusted()`（在 `CoreGraphics.tbd`） |
| Liquid Glass | `NSGlassEffectView` = **macos(26.0)+**（`effectIsInteractive` = 27.0）；`SCScreenshotConfiguration` = 26.0+ |

## ⚠️ 已知实现陷阱（血泪教训，写代码时必须避）

1. **`CGBitmapContext` 内存行序本就自上而下**，不要再"翻转为自上而下"——那是相对各自图像高度的镜像，会让帧间位移**符号反转**，配准静默出错。
2. **取帧用 `CGImage.cropping(to:)`**，不要用负坐标 rect 的 `ctx.draw`。
3. **长图拼接**：新内容 = 本帧顶部 d 行 = `(viewH-d)..<viewH`。
4. **配准模块必须内置"装置自检"**：用已知位移的合成图做回归。上面 3 个坑都是靠自检才发现的，且都属于"不崩溃、不报错、只悄悄错"。
5. **`xcodebuild` 无法解析本地 SPM 包**（deny-default 沙箱在本环境不可应用）→ 见 DEV-NOTES 第 4 节，用 `scripts/build.sh`。
6. **模块缺 `import Foundation` 会让 `Equatable` 静默合成失败**（`URL`/`Date`/`UUID` 场景）。同源：`CGImageDestination*` 要 `import ImageIO`（只 import CoreGraphics 不算）。
7. **`NSEvent.ModifierFlags` 的 ⌘ 是 `1<<20`（0x100000），不是 `1<<16`** —— `1<<16` 是 **Caps Lock**。位值：capsLock `1<<16`、shift `1<<17`、control `1<<18`、option `1<<19`、command `1<<20`（`NSEvent.h:168-172`）。写错不崩，只会让所有 ⌘ 组合静默变成"没按 ⌘"。已用测试钉死。
8. **Carbon 虚拟键码不是顺序的**：`kVK_ANSI_5 = 0x17`、`kVK_ANSI_6 = 0x16`（反序）。键码表一律从 `Events.h` 抄，别按下标推。
9. **Swift 6 的 nonisolated `deinit` 不能碰非 Sendable 的存储属性**（如 `EventHotKeyRef` / `EventHandlerRef`，都是 `OpaquePointer`）→ 编译报错。解法：不写 deinit 做清理，改由显式 `unregister()` 负责（进程退出时系统会回收）。
10. **`CGBitmapContext` 的 `bytesPerRow` 必须对齐**（用 16 的倍数）。给 `width * 4` 这种未对齐值（例如 2px 宽的图 = 8 字节）会**整行读出垃圾且不报错** —— 测试里查了半天。
11. **`CGColorSpaceCreateDeviceRGB()` 在本机（P3 屏）就是 Display P3**：用它建上下文 + 用 `CGColor(red:green:blue:alpha:)` 填色，"纯红"读回来是 `(255,38,0)`，颜色断言变成碰运气。测试里一律用 `CGColorSpace(name: .sRGB)` + `CGColor(colorSpace:components:)`（这样往返是精确的）。
12. **swift-testing 的 `#expect(...)` 宏展开里不能调 `mutating` 方法**（`$0 is immutable`）→ 先赋给局部变量再断言。
13. **`SelectionPhase` / 状态机类的东西放 Core**：`MarqueeOverlay` 里的东西无法自动化测试（需要真实屏幕），只有抽到 Core 才能单测。
14. **Carbon 热键的冲突只能靠「独占注册」探测出来**（2026-09-30 实测，四种情形）：
    - 非独占注册：**永远是 0**，被占也返回成功 → 光看它永远发现不了冲突（微信同时响应就是这么来的）
    - 独占注册 + 同进程内已有自己的注册 → `-9878` → **必须先 `unregister()` 再探测**
    - 独占注册 + **别的进程独占**占着 → `-9878` ✅ 可用的探测手段
    - 独占注册 + 别的进程只是**非独占**占着（跨进程）→ **0**，探测无效；此时双方都收到事件
15. **别用自己持久化的标记去推断 TCC 的 `denied`**：签名身份一变，TCC 状态重置而标记还在，于是再也不敢调 `CGRequestScreenCaptureAccess()`；而 macOS 只在应用调用采集 API 时才把它登记进「屏幕录制」列表 → 用户永远授权不了。见 DEV-NOTES 第 1 节。
16. **`OptionSet` 的 Codable 是 `RawRepresentable` 单值编码**：`ShortcutModifiers`（包一个 `rawValue`）编出来是 `"modifiers":9`，**不是** `{"rawValue":9}`。手写偏好做测试时别猜形状（用等价类型实编一次）。
17. **`os.Logger` 的字符串插值里引用实例属性要写 `self.`**，否则 Swift 6 报 "requires explicit use of 'self'"。
18. **`DEVELOPMENT_TEAM` 要填真正的 team id**（`codesign -dvvv` 里的 `TeamIdentifier`，本机 `UKXWZ3FS84`），**不是**证书名括号里那串（`Apple Development: … (7H6TJ2PN25)` 里的是证书标识）。填错报 `No signing certificate "Mac Development" found`。
19. **macOS 只在应用调用采集 API 时才把它登记进「屏幕录制」列表**。权限门若拦在采集之前，"请求权限"里也必须真的碰一次 `SCShareableContent`，否则列表里没有这个应用 → **用户永远授权不了**（现象是系统设置里找不到 Marquee）。碰一次枚举就够了，**不要再截一帧**：`SCScreenshotManager.captureImage` 在 macOS 15+ 会叠出第二张系统授权框。
20. **bash + `set -u`：中文文案里 `$VAR` 紧跟全角字符会被当成变量名的一部分**（如 `$IDENTITY（team …）`）→ 报 "unbound variable"。写 `${VAR}`。
21. **别依赖 Xcode 自动创建的 user scheme**（在 `xcuserdata/`）。`xcodegen generate` 之后它可能不在了，构建直接报 `does not contain a scheme named …` → 必须在 `project.yml` 里声明**共享** scheme。
22. **屏幕录制授权框连弹**：`requestPermission()` 里截帧 + preflight 在重启前一直是 false 仍报 `.notDetermined` + 刚授权还去采集，三者叠在一起会让每次快捷键都弹系统框。进程内记住"问过一次"（不要写 UserDefaults），刚授权只提示重启。见 DEV-NOTES 第 1.3 节。

## 文档与资产

| 路径 | 内容 |
| --- | --- |
| `docs/PRD.md` | 产品与方案设计 |
| `docs/SCREEN-RECORDING-PERMISSION.md` | 屏幕录制权限完整复盘（四层根因 + 当前设计 + 验证） |
| `docs/RENDER-BENCH.md` | 渲染技术实测报告 |
| `docs/SPIKE-PLAN.md` | **坑点/难点/重点清单 + 提前验证报告（37 项）** |
| `docs/DEV-NOTES.md` | 开发循环的已知摩擦（签名、沙箱、工程生成） |
| `.scratch/issues/2026-09-30-marquee-mvp/` | **18 条 ticket + INDEX**（本地 tracker） |
| `Tools/Spikes/`、`Tools/RenderBench/` | 独立验证工具，与产品代码分离 |


## 工作流约定

沿用用户既有门禁：**spec → solution → test plan → impl → delivery**，逐段确认；TDD 红→实现→绿，测试永久留仓 + TSan 复验。未经明确指令不 commit/push。变更记录到 `docs/`。

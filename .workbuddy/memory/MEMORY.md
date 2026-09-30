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
| 全局快捷键 | Carbon `RegisterEventHotKey`，无需辅助功能权限；冲突码 `-9878` |
| 权限检测 | `CGPreflightScreenCaptureAccess()` / `CGPreflightListenEventAccess()` / `AXIsProcessTrusted()`（在 `CoreGraphics.tbd`） |
| Liquid Glass | `NSGlassEffectView` = **macos(26.0)+**（`effectIsInteractive` = 27.0）；`SCScreenshotConfiguration` = 26.0+ |

## ⚠️ 已知实现陷阱（血泪教训，写代码时必须避）

1. **`CGBitmapContext` 内存行序本就自上而下**，不要再"翻转为自上而下"——那是相对各自图像高度的镜像，会让帧间位移**符号反转**，配准静默出错。
2. **取帧用 `CGImage.cropping(to:)`**，不要用负坐标 rect 的 `ctx.draw`。
3. **长图拼接**：新内容 = 本帧顶部 d 行 = `(viewH-d)..<viewH`。
4. **配准模块必须内置"装置自检"**：用已知位移的合成图做回归。上面 3 个坑都是靠自检才发现的，且都属于"不崩溃、不报错、只悄悄错"。
5. **`xcodebuild` 无法解析本地 SPM 包**（deny-default 沙箱在本环境不可应用）→ 见 DEV-NOTES 第 4 节，用 `scripts/build.sh`。
6. **模块缺 `import Foundation` 会让 `Equatable` 静默合成失败**（`URL`/`Date`/`UUID` 场景）。

## 文档与资产

| 路径 | 内容 |
| --- | --- |
| `docs/PRD.md` | 产品与方案设计 |
| `docs/RENDER-BENCH.md` | 渲染技术实测报告 |
| `docs/SPIKE-PLAN.md` | **坑点/难点/重点清单 + 提前验证报告（37 项）** |
| `docs/DEV-NOTES.md` | 开发循环的已知摩擦（签名、沙箱、工程生成） |
| `.scratch/issues/2026-09-30-marquee-mvp/` | **18 条 ticket + INDEX**（本地 tracker） |
| `Tools/Spikes/`、`Tools/RenderBench/` | 独立验证工具，与产品代码分离 |


## 工作流约定

沿用用户既有门禁：**spec → solution → test plan → impl → delivery**，逐段确认；TDD 红→实现→绿，测试永久留仓 + TSan 复验。未经明确指令不 commit/push。变更记录到 `docs/`。

# 01: 工程骨架与可启动的菜单栏应用

**What to build:** 一个能真正跑起来的 Marquee 空壳：双击构建产物后应用在后台启动（无 Dock 图标），菜单栏出现一个图标，点开是一个简洁菜单（截屏 / 延时截屏 / 最近截图 / 设置 / 退出），点退出能干净退出。同时把工程结构与测试链路立起来，证明"改一行代码 → 跑测试 → 看到红/绿"这条回路可用。

这是后续所有 ticket 的载体，属于 prefactor：先把工程结构做对，后面每条切片只管业务。

**Blocked by:** None (can start immediately)

**Status:** done (2026-09-30) — 除「菜单退出项」需人工点一次确认外，其余全部验证通过

## 设计约束（已定，勿重新争论）

- 工程由 XcodeGen 从 `project.yml` 生成，`.xcodeproj` 不入库
- 依赖用 SPM 本地包模块化，模块边界：`Core`（纯逻辑）/ `Capture`（SCK 封装）/ `Overlay`（AppKit 覆盖层）/ `Editor`（SwiftUI 编辑器）/ `Settings` / `History` / `App`（宿主 target）
- 首期只有 `Core` 有实质代码，其余为可编译的空壳；模块只允许依赖 `Core`，`App` 依赖全部
- 最低系统版本 macOS 15.0
- `LSUIElement = true`，无 Dock 图标
- 验证资产（渲染基准、spike 工具）迁到 `Tools/` 下，与产品代码分开

## Acceptance criteria

- [x] `xcodegen generate` 后可直接 `xcodebuild build` 成功，无警告无报错
- [x] 构建产物启动后无 Dock 图标，菜单栏出现图标
- [ ] 菜单栏菜单项不超过 6 项（当前 5 项 + 1 分隔符）；退出项能干净退出进程 —— **退出项已接线到 `NSApplication.terminate(_:)`，需人工点一次确认**
- [x] `swift test` 可跑，且至少有一条 `Core` 的真实断言（15 个测试 / 3 个 suite 全绿，已做变异测试确认非空跑）
- [x] `Tools/` 下的基准与 spike 工具能独立编译运行，且 `docs/` 中对它们的引用路径已更新
- [x] `.gitignore` 覆盖构建产物、`.xcodeproj`、`.build/`、`DerivedData/`
- [x] README 或 `docs/` 中有"如何构建 / 如何跑测试"的一段说明

## 实施记录（2026-09-30）

**产出**

| 路径 | 内容 |
| --- | --- |
| `project.yml` | XcodeGen 工程定义（app target + SPM 本地包依赖） |
| `Modules/Package.swift` | 6 个模块 + Core 测试 target，依赖规则写在顶部注释 |
| `Modules/Sources/MarqueeCore/` | `DisplayGeometry`（点↔像素换算）、`Selection`（拖拽几何） |
| `Modules/Tests/MarqueeCoreTests/` | 15 个测试 / 3 个 suite |
| `App/` | `main.swift`、`MarqueeAppDelegate`、`MenuBarController`、`Info.plist` |
| `scripts/build.sh`、`scripts/test.sh` | 把必需参数封装死，避免手敲裸命令 |
| `Tools/Spikes/`、`Tools/RenderBench/` | 从 `.scratch/` 迁出 |
| `docs/DEV-NOTES.md` | 开发循环的已知摩擦 |

**踩到的坑（写入 `docs/DEV-NOTES.md` 第 4 节）**

`xcodebuild` 解析本地 SPM 包时套的是 **deny-default** 形态沙箱，而当前宿主环境无法应用该形态的沙箱：

| 命令 | 结果 |
| --- | --- |
| `sandbox-exec -p '(allow default)'` | ✅ |
| `sandbox-exec -p '(deny default)...'` | ❌ `sandbox_apply: Operation not permitted` |

排查结论：**与网络无关**（本地路径包不联网，`proxy_on` 无效）、**与工具沙箱无关**（关闭沙箱后仍失败）。
解法是打开 Xcode 的 manifest 求值沙箱开关，已封装进 `scripts/build.sh` 的前置检查。

**未做的事**

- 未提交 git（等你确认）

# Marquee

一个 macOS 原生截屏与标注工具。纯本地、无账号、键盘驱动。

复刻对象是腾讯 Snip（2012 年 v2.0 之后实质停更、未适配现代 macOS），
但**不是移植**：用 ScreenCaptureKit + AppKit 覆盖层 + SwiftUI 编辑器重新实现，
保住旧版真正值钱的两件事——**窗口自动识别**与**滚动截屏**——并补齐现代系统能力。

## 当前状态

**M1 捕获核心基本完成。** 菜单栏应用可启动；全屏 / 选区 / 窗口 / 滚动截屏、标注编辑器、
`⌘S` 落盘都已实现，**待人工验收**。测试 171 全绿。

| 想做的事 | 看这里 |
| --- | --- |
| 现在到哪了、卡在哪 | **`docs/STATUS-AND-ACCEPTANCE.md`** §1–2 |
| 照着跑一遍验收 | **`docs/STATUS-AND-ACCEPTANCE.md`** §3 |
| 逐条 ticket 状态 | `.scratch/issues/2026-09-30-marquee-mvp/INDEX.md`（18 条） |

## 构建

需要 Xcode 27+、XcodeGen。

```bash
./scripts/build.sh
```

首次使用前需要一次性打开 Xcode 的 manifest 沙箱开关（原因见 `docs/DEV-NOTES.md` 第 4 节，
`scripts/build.sh` 会检查并在缺失时提示）：

```bash
defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
# 回退：
defaults delete com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox
```

跑完脚本后会生成 `Marquee.xcodeproj`，也可以 `open Marquee.xcodeproj` 在 Xcode 里开发。

## 测试

模块的单元测试走 SPM，不需要先生成工程：

```bash
./scripts/test.sh
```

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `App/` | 宿主 target：菜单栏生命周期、模块装配 |
| `Modules/` | SPM 本地包，6 个功能模块 + 测试 |
| `docs/` | 产品方案、实测报告、验证清单 |
| `.scratch/issues/` | ticket（本地 markdown tracker，刻意入库） |
| `Tools/` | 独立命令行验证工具，不属于产品代码 |

模块依赖规则：只有 `MarqueeCore` 无依赖，其余模块只依赖 `Core`，模块之间不互相依赖。
详见 `Modules/Package.swift` 顶部注释。

## 文档

| 文档 | 内容 |
| --- | --- |
| `docs/PRD.md` | 产品定位、功能范围、技术方案、里程碑、决策记录 |
| `docs/STATUS-AND-ACCEPTANCE.md` | **进度 / 阻塞项 / 人工验收清单**（含与 SPIKE M1–M20 的对应） |
| `docs/SCREEN-RECORDING-PERMISSION.md` | 屏幕录制权限：现象、四层根因、当前设计、验证与残留 |
| `docs/RENDER-BENCH.md` | 渲染技术实测：Canvas / Core Graphics / Metal |
| `docs/SPIKE-PLAN.md` | 坑点/难点/重点清单与提前验证报告 |
| `docs/DEV-NOTES.md` | 开发循环中的已知摩擦与注意事项 |

## Tools

```bash
cd Tools/Spikes
swiftc -O -swift-version 5 -o spikes main.swift
./spikes          # 权限 API / 全局快捷键 / OCR / 剪贴板 基础探测
./spikes scroll   # 滚动截屏配准验证（含装置自检）
./spikes dump     # 导出诊断图
```

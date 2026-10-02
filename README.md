# Marquee

一个 macOS 原生截屏与标注工具。**纯本地、无账号、键盘驱动。**

复刻对象是腾讯 Snip（2012 年 v2.0 之后实质停更、未适配现代 macOS），
但**不是移植**：用 ScreenCaptureKit + AppKit 覆盖层 + SwiftUI 重新实现，
保住旧版真正值钱的三件事——**窗口自动识别**、**滚动截屏（长截图）**、
**标注是对象而不是像素**——并补齐现代系统能力。

```
⌃Q  →  拖出选区  →  就地标注  →  ⏎  →  图已在剪贴板
```

---

## 当前状态

**25 条 ticket 全部落地**（`01`–`23`，`17` 拆成 `17a` 玻璃材质 / `17b` 本地化，外加 `24` 覆盖层工具条对齐参考）。
**代码层面没有未开工的东西了**，剩下的是真实桌面上的人工验收。

- `./scripts/test.sh` → **491 测试全绿**（Core 473 + 历史仓库 12 + 真实 Vision 装置自检 6）
- `./scripts/build.sh` → **BUILD SUCCEEDED**
- 大部分条目处于 **"已实现、待人工验收"** —— 自动化测试覆盖不到真实桌面上的手感

| 想做的事 | 看这里 |
| --- | --- |
| 现在到哪了、卡在哪 | **`docs/STATUS-AND-ACCEPTANCE.md`** §1–2 |
| 照着跑一遍验收 | **`docs/STATUS-AND-ACCEPTANCE.md`** §3（A–V 分组） |
| 逐条 ticket 状态与设计理由 | `.scratch/issues/2026-09-30-marquee-mvp/INDEX.md` |
| 写代码前必扫的实现陷阱 | **`docs/PITFALLS.md`**（116 条实测） |

---

## 功能

| 能力 | 说明 |
| --- | --- |
| **全屏截图** | 默认 `⌃Q`（可改）。整屏图**直接进剪贴板**，不落盘、不弹窗 |
| **选区截图** | 拖出选区；松开即停住，方向键微调，`⏎` 提交 |
| **窗口识别** | 悬停高亮整窗（按屏幕前后顺序命中，被挡住的不选）；单击落点，再 `⏎` 截这一扇窗；`⌥` 去掉窗口阴影 |
| **选区几何编辑** | 落点后出 8 个控制点；拖角改大小、框内拖动移动整框、`⇧` 锁比例、边缘吸附（带贯穿全屏的提示线） |
| **就地标注** | 选区下方浮出工具条，四组：`矩形 / 椭圆 / 表情 / 箭头 / 画笔 / 马赛克 / 文字` │ `样式` │ `识别文字` │ `撤销 / 重做 / 保存 / 钉图 / ✗ / ✓`。**不开新窗口**，所见即所得 |
| **样式弹层** | 点「样式」展开色板 ×6 与尺寸 ×3（三档按工具换含义：线宽 / 打码强度 / 字号）。收进弹层是为了让工具条只有一排图标 |
| **会说话的光标** | 十字只在"能拉/重画选区"和"正在画标注"时出现：工具栏给手型（灰掉的格子除外）、选区内部给张开的手、拖动中给合上的手、文字输入框给 I 形 |
| **标注是对象** | **没选工具时**点一个标注就选中它，可移动、缩放（8 个控制点）、`Delete` 删除（`⌘Z` / `⇧⌘Z`）；只有导出那一刻才栅格化 |
| **打码** | 走 CoreImage；尺寸档在打码工具下自动变成"打码强度"。覆盖层只给**马赛克**一个入口，毛玻璃模糊仍能用（编辑器里，以及已有数据） |
| **OCR** | 工具条上的**动作**（不占工具位）：识别选区文字 → 直接进剪贴板。启动时后台预热（首次约 25 s） |
| **放大镜取色** | 落点前 `⌥` 悬停显示 HEX/RGB，点击复制色值 |
| **滚动截屏 / 长截图** | 菜单「滚动截屏」→ 拖区域或点窗口即开始抓帧；手动滚，或 `空格` 自动滚（**唯一需要「辅助功能」授权**的功能，按需申请、拒绝即退回手动）。Vision 配准 + 增量拼接 |
| **表情贴纸** | 选中「表情」弹出 24 枚常用表情，点画布即落一个（产出的就是文字标注，复用现成的绘制/导出/缩放路径） |
| **钉图** | 把截图钉在屏幕最上层当参照物：滚轮缩放、四档不透明度、鼠标穿透、多张共存 |
| **最近截图** | 菜单「最近截图」→ 最近 12 张缩略图；点图复制、可重新编辑（**原图与标注分开存**，所以标注仍然可编辑）、可连文件一起删 |
| **偏好设置** | 四页（通用 / 截屏 / 输出 / 快捷键），**改一下立刻生效、立刻落盘**，没有「应用」按钮 |
| **系统材质** | 悬浮面板用原生 Liquid Glass（macOS 26+），15.x 自动降级到 HUD 材质 |
| **中英双语** | 跟随系统语言。文案集中在单一 String Catalog，**漏翻译会被测试挡住** |

### 新增文案怎么写（务必照做）

1. 把中文原句包成 `L10n.t("…")` —— **插值直接写在字面量里**：

   ```swift
   L10n.t("已复制 \(text)")                     // ✓ 编译器把 key 记成「已复制 %@」
   L10n.t("已复制 " + text)                      // ✗ 查的是渲染后的串，永远匹配不上
   ```

   错法**不崩不报错**，只是在英文环境下那句话仍然是中文。

2. 往 `App/Resources/Localizable.xcstrings` 加一条，`en` 的 `value` 写英文。
   说明符必须与源码类型对上：`Int` → `%lld`，`Int32`/`OSStatus` → `%d`，
   `UInt32` → `%u`，`String` → `%@`，`Double`/`CGFloat` → `%lf`。

3. 确实不该翻的（日志、断言、`DateFormatter` 格式串）用标记声明**并写理由**：

   ```swift
   // L10N-EXEMPT-START: -marqueeDiagnostics 的报告，贴回来给我看，翻译反而看不懂
   …
   // L10N-EXEMPT-END
   ```

`./scripts/test.sh` 会检查漏包、漏翻、孤儿条目与没写理由的豁免 —— 任一不合规**变红**。

---

## 系统要求

- **macOS 15.0+**（26 / 27 的专属能力走 `if #available` + 降级，不会因为系统旧就不可用）
- 构建需要 **Xcode 27+** 与 **XcodeGen**

首次使用需要授予**屏幕录制**权限。撤销后再次截图会走正确的重新申请路径，不会弹主窗口。

---

## 构建

```bash
./scripts/build.sh
```

首次使用前需要一次性打开 Xcode 的 manifest 沙箱开关（原因见 `docs/DEV-NOTES.md` 第 4 节，
`scripts/build.sh` 会检查并在缺失时直接提示）：

```bash
defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
# 回退：
defaults delete com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox
```

脚本会先跑 `xcodegen generate` 生成 `Marquee.xcodeproj`，再 `xcodebuild`。
想看性能预算（编辑器重绘 ≤ 4 ms、选区拖拽 120 fps 这些）请用 **Release**：

```bash
CONFIGURATION=Release ./scripts/build.sh
```

## 测试

模块的单元测试走 SwiftPM，**不需要先生成工程**，比 `xcodebuild test` 快得多：

```bash
./scripts/test.sh          # = cd Modules && swift test --disable-sandbox
```

`--disable-sandbox` 是必需的（SwiftPM 默认给 `Package.swift` 的求值套 deny-default 沙箱，
当前宿主环境无法应用该形态），原因见 `docs/DEV-NOTES.md` 第 4 节。

两条纪律：**TDD（先红 → 再实现 → 转绿）** 与 **变异测试**（把实现改坏一处，断言必须变红）；
测试永久留仓，不允许为了绿灯而删。

## 打包分发

```bash
./scripts/package.sh
```

七步出 DMG（脚本里带编号，每一步都写了"怎么判断它成了"）：

```
0/7 前置检查（Xcode / xcodegen / 证书 / 公证凭据）
1/7 生成工程
2/7 归档（Release）
3/7 导出（Developer ID）
4/7 核验签名 ← 不过就停下（公证的前置条件）
5/7 公证（notarytool）
6/7 装订（staple）
7/7 打包 DMG（DMG 本身也要签 + 公证 + 装订）
```

需要 Developer ID 证书；完整复现步骤与更新指引见 **`docs/RELEASE.md`**。

> 分发方式刻意选了 **Developer ID + 公证（非 MAS）**：App Sandbox 会约束滚动截屏这类系统级能力。
> 更新机制走**手动指引**（引入 Sparkle 会多一个要签名的可执行文件 + 一套签名密钥，不值）。

---

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `App/` | 宿主 target：菜单栏生命周期、权限门、模块装配 |
| `Modules/` | SPM 本地包：6 个功能模块 + 3 个测试 target |
| `docs/` | 产品方案、实测报告、验收清单、陷阱清单 |
| `.scratch/issues/` | ticket（本地 markdown tracker，**刻意入库**） |
| `Tools/` | 独立命令行验证工具，不属于产品代码 |

### 模块依赖规则

**只有 `MarqueeCore` 无依赖，其余模块只依赖 `Core`，模块之间互不依赖。**

```
MarqueeCore  ── 接缝（协议/值类型）+ 编排逻辑，可在没有屏幕、没有权限的机器上单测
   ├── MarqueeCapture    ScreenCaptureKit 采集 / Vision 滚动配准
   ├── MarqueeOverlay    选区覆盖层、浮动工具条、钉图、倒计时 HUD
   ├── MarqueeEditor     标注编辑器窗口（只从长截图进入）
   ├── MarqueeSettings   偏好设置窗口
   └── MarqueeHistory    最近截图的磁盘仓库
```

把"编排"放进 Core 是刻意的：SwiftPM 的依赖是单向的，编排要能脱机单测，
就只能落在唯一没有依赖的那一层；实现模块只提供 OS 实现。

### 为什么覆盖层不铺整屏截图

覆盖层只画**变暗蒙层 + 选区镂空 + 描边**，不铺底图。铺底图会引入色彩偏移与 HDR 色调映射错误，
还会"截屏套娃"。需要真实像素的两处（放大镜、打码预览）另外取**一屏冻结帧**，并复用与导出一套的布局。

---

## 键盘

| 键 | 作用 |
| --- | --- |
| `⌃Q` | 截屏（可在「设置 → 快捷键」改；冲突会明确告诉你） |
| 拖拽 | 拉出选区 |
| `单击` | 高亮一扇窗并停住；再 `⏎` 截这扇窗 |
| `⌥` | 落点前＝取色；落点后＝临时去掉窗口阴影 |
| `⇧` | 拖控制点时锁比例 |
| 方向键 | 微调选区 |
| `⏎` / 双击 | 提交；无目标时＝整屏 |
| `⌘S` | 提交并额外写入磁盘 |
| `空格` | 长截图：开始 / 停止**自动滚动** |
| `⌘Z` / `⇧⌘Z` | 撤销 / 重做 |
| `Delete` | 删除选中的标注 |
| `Esc` | 分三级：草稿 → 工具 → 整次取消 |

---

## 开发约定

沿用固定的门禁，**逐段确认、不跨段推进**：

```
spec → solution → test plan → impl → delivery
```

- **TDD**：先写会变红的测试，再写实现，最后转绿
- **变异测试**：把实现改坏一处，相关断言**必须**变红 —— 这是"断言有没有空跑"的唯一证据
  （改坏之后仍全绿时，先问"这个变异有没有产生用户可见的错误"，再问"用例有没有覆盖到那条路径"）
- **测试永久留仓**，不允许为了绿灯而删；性能类断言跑 5 次取最小值（避免机器抖动变红）
- 新增实现陷阱**直接写进 `docs/PITFALLS.md`**，不要只写在提交信息里
- 遇到平台未知项**先写探针再动手**（覆盖层的键盘焦点、材质可用性都是这么定下来的）

提交信息用 `type(scope): 说明`，scope 指向 ticket（如 `feat(ticket 22): 标注缩放`）。

---

## 文档

| 文档 | 内容 |
| --- | --- |
| **`docs/PITFALLS.md`** | **116 条实现陷阱** —— 大多是「不崩溃、不报错、只悄悄错」那一类，**写代码前必扫** |
| **`docs/STATUS-AND-ACCEPTANCE.md`** | 进度 / 阻塞项 / 人工验收清单（A–U 分组 + 与 SPIKE M1–M20 的对应 + 排障速查） |
| `docs/PRD.md` | 产品定位、功能范围、技术方案、里程碑、决策记录 |
| `docs/SPIKE-PLAN.md` | 坑点/难点/重点清单与提前验证报告（37 项） |
| `docs/DEV-NOTES.md` | 开发循环中的已知摩擦（签名、沙箱、工程生成、宏插件被杀） |
| `docs/RELEASE.md` | 打包 / 公证 / 更新的复现步骤 |
| `docs/SCREEN-RECORDING-PERMISSION.md` | 屏幕录制权限：现象、四层根因、当前设计、验证与残留 |
| `docs/RENDER-BENCH.md` | 渲染技术实测：SwiftUI Canvas / Core Graphics / Metal |

由 API 版本引发的分支全部集中在一处，不在 UI 代码里散落：
`if #available(macOS 26.0, *)` 只出现在 `ChromeBackground.isGlassAvailable`
与 `Tools/Spikes`，其余走 `MarqueeCore.ChromeMaterial` 的可单测判据。

---

## Tools（独立验证工具，与产品代码分离）

```bash
cd Tools/Spikes
swiftc -O -swift-version 5 -o spikes main.swift
./spikes          # 权限 API / 全局快捷键 / OCR / 剪贴板 / 玻璃 API 可用性 基础探测
./spikes scroll   # 滚动截屏配准验证（含装置自检）
./spikes dump     # 导出诊断图
```

`Tools/RenderBench/` 是渲染技术选型的实测程序（`docs/RENDER-BENCH.md` 的数据来源）。

`Tools/SymbolProbe/` 是 **SF Symbol 探针** —— 换图标、加图标之后跑一次：

```bash
Tools/SymbolProbe/run.sh      # 出 out-en.png / out-zh.png 两张对照图
```

两件事**读代码看不出来**，只能渲染出来比：**有些符号有中文本地化变体**
（`textformat` 在中文下会变成两个字「格式」、`character` → 字），
以及**多色符号在 `paletteColors` 下第一层会被整片填充**
（`face.smiling` 会画成一个实心圆点，加 `.preferringMonochrome()` 才对）。
本地化按"应用声明的本地化"判定，裸二进制永远按英文渲染 —— 所以探针要放进
一个声明了 zh-Hans 的 bundle 里才测得到（`run.sh` 会自动拼一个）。

---

## 调试用现场开关

几个不改代码就能调的口子（都是 `defaults`，下次唤起对应界面时生效）：

```bash
defaults write dev.tango.Marquee lens.zoom -float 4            # 放大镜倍数
defaults write dev.tango.Marquee chrome.tint  -float 0.18     # 玻璃着色调淡（越淡越透；默认 0.25）
defaults write dev.tango.Marquee chrome.scrim -float 0.35     # 15.x 材质下的衬底（默认 0.35）
defaults write dev.tango.Marquee chrome.forceHUD -bool YES    # 强制走 15.x 的 HUD 材质（自检降级路径）
defaults write dev.tango.Marquee overlay.traceFrames -bool YES # 拖一次选区，日志出「帧数 / 平均 ms / 最大间隔」
defaults delete dev.tango.Marquee chrome.forceHUD
```

免权限自检入口（覆盖层 / 编辑器的渲染没法在自动化测试里目视确认，用这几个开关冒烟）：

```bash
open -a Marquee.app --args -marqueeDemoEditor        # 合成图 + 八类标注各一个，不自动退出，不需要任何权限
open -a Marquee.app --args -marqueeDiagnostics       # 打印权限 / 快捷键 / 签名状态报告后退出
open -a Marquee.app --args -marqueeRequestPermission # 走一次屏幕录制的申请流程
open -a Marquee.app --args -marqueeSmokeOverlay      # 覆盖层冒烟（1.5 s 后自动退出，不留残影）
open -a Marquee.app --args -marqueeSmokeEditor
open -a Marquee.app --args -marqueeSmokeScrollOverlay
```

> 权限相关的请用 `open -a … --args` 而不是直接 exec 可执行文件：
> LaunchServices 启动才会让 Marquee 成为自己的 "responsible process"，
> 否则 TCC 可能把这次访问算在终端头上（那正是"列表里找不到 Marquee"的一种成因）。

# Marquee · 项目长期记忆

> `/Users/tango/Developments/Marquee`（2026-09-30 由 `Snipo` 改名）；远端 `git@github.com:tangzzz-fan/Marquee.git`；开发机 **macOS 27**。
> 定位：复刻腾讯 Snip 的 macOS 原生截屏工具。纯本地、无账号、键盘驱动。
>
> ⚠️ **写代码之前先扫 `docs/PITFALLS.md`**（189 条实测陷阱，多为「不崩溃、不报错、只悄悄错」）。
> 本文件只记**决策**与**索引**；逐条交互实现见同目录 **`INTERACTION.md`**。

## 身份 · 分发 · 收费

| 项 | 值 |
| --- | --- |
| 产品 / 最低系统 | **Marquee**，**macOS 15.0**；26/27 专属能力走 `if #available` + 降级 |
| **两个 bundle id** | 正式 `com.tango.marquee` / 开发 `.dev`；**是不是开发版由后缀推导**（唯一来源 `MarqueeCore/AppIdentity`）⇒ 偏好、数据、TCC 各一份。**只有 `Release` 与 `MAS` 拿正式 id**（`package.sh` 再核验）。改名有时间窗（ASC 上传过构建就不能改；我们没上传过）。见 `docs/DEV-VS-PROD.md` |
| 四个构建配置 | `Dev`＝**Run（默认）**，与 Release **同优化**（性能数字才可比）/ `Debug`＝只要能用的断点（**别拿它测性能**）/ `Release`＝**Developer ID**、**不带沙盒**（保住自动滚动那条后路）/ **`MAS`＝唯一带沙盒的**（`App/Marquee.entitlements` + hardened runtime）。⚠️「在不在沙盒里」按**运行期判据**分派（`AppIdentity.isSandboxed`），**不许**用编译期开关 —— 没编进去的分支只有发版那天才跑得到 |
| 分支 | `feat/iap`、`feat/onboarding` 均已并入 `main`（2026-10-03）。**合并一律 `--no-ff`** |
| **收费（已定：买断 ¥36）** | 非消耗型 IAP `com.tango.marquee.pro`。**Pro 只含四项现存能力**：滚动截屏 / 识别文字 / 钉图 / 最近截图不设上限（免费 5）；其余全免费。⚠️ **不许把没做的功能写成"锁着的"**。试用＝**0 价非消耗型 IAP**（3.1.1 官方路径），7 天、一次 |
| **权益（ticket 30/31）** | 判定在 Core `LicenseResolver`（纯函数）；**头号判据：`unknown` 必须放行**（否则付费用户启动先看到锁；历史也不许按免费裁剪）。已完成 `Storefront` · `EntitlementCache`（缓存**输入**而非结果）· `StorefrontSeams` · `EntitlementCoordinator` · `MarqueeStore`。五条硬规则：**未校验的交易不算数** · **撤销可以被撤销** · **「商店里没有」只有真的问过才算证据**（查询失败时 `records` 也为空 ⇒ 断网锁死付费用户）· **启动不等网络** · **核实失败不改动判定** |
| **分发（已定：路线 B，上 MAS）** | **代价已接受：自动滚动砍掉、只留手动长截图**；Developer ID **并存**作后路。依据（已核实原文）：Apple 明文「用 `CGEventPost` 向其它 app 投递输入事件**不允许来自沙盒应用**」，DTS 亦答「沙盒 app 不能用辅助功能 API」⇒ **自动滚动与 MAS 互斥**（Snip 的 App Store 版同样"滚动截屏不可用"）。**桌面没有 entitlement** ⇒ 默认落盘改 `~/Pictures/Marquee`。⚠️ **迁移在沙盒内做不到**（读不到容器外的 Application Support）⇒ 沙盒版首发本来就没有老数据。见 PITFALLS 143/144 |

## 工程与架构

| 项 | 值 |
| --- | --- |
| 工程 | XcodeGen（`project.yml`）+ SPM **7 个模块** + 宿主 `App`；`Tools/` 下是独立命令行验证工具 |
| 模块依赖 | **只有 `MarqueeCore` 无依赖，其余只依赖 Core，模块之间互不依赖。** Core 持「接缝 + 编排」，实现模块只给 OS 实现 —— 编排才能脱机单测 |
| 签名 | **由 `project.yml` 负责**（Apple Development + `DEVELOPMENT_TEAM: UKXWZ3FS84`）；`build.sh` 的 `codesign --identifier` **从产物 plist 读**（写死过一次 ⇒ 屏幕录制授权留不住） |
| 任务管理 | matt pocock `to-tickets`；本地 markdown tracker 在 `.scratch/issues/`（**刻意入库**） |
| 测试目标 | `MarqueeCoreTests`（纯逻辑）· `MarqueeHistoryTests` · `MarqueeCaptureTests`（真实 Vision 自检）· `MarqueeStoreTests`（商品配置一致性）· `MarqueeTestSupport` |

## 交互硬规则（逐条细节见 `INTERACTION.md`）

- **`Esc` / `⏎` 是同一架梯子、出口相反**（Core `EscapeLadder`）：覆盖层退到底＝取消；编辑器退到底＝**完成并复制并关闭**。编辑器里「丢弃」只由 `✗` 承担。
- **全局快捷键在录制期间必须挂起**（计数式）：否则用户按**自己正用的那颗键**会被 Carbon 在系统级吃掉 ⇒ 设置无效 + 真的开始截屏。
- **`ChromePalette` 是唯一颜色来源**；**`AnnotationIcon` 是唯一图标源**（SF Symbol 会本地化，只用语言无关的）。
- **编辑器 px vs 覆盖层 pt 正好差 2 倍**（2x 屏上的桥），别合并。
- **覆盖层内部一律 Cocoa 全局点坐标**，只在提交采集时转 Quartz（y 相反，混用静默错位）。
- **本地化 key ＝中文原句**，插值必须写在字面量里；说明符按类型。
- **用户按的删除进废纸篓**；自动淘汰才永久删。
- **钉图钉在原位**；**窗口截图强制 `includeShadow: false`**（否则标注整体偏移）。

## 构建与测试（走脚本，不要手敲裸命令）

```bash
./scripts/build.sh       # XcodeGen 生成 + xcodebuild；默认配置 Dev
./scripts/test.sh        # swift test --disable-sandbox（参数必需）
CONFIGURATION=Release ./scripts/build.sh   # 发版 / 内购真实沙盒验证
./scripts/package.sh     # 打包公证（七步，需要 Developer ID 证书）
```

**必需的一次性设置**（`docs/DEV-NOTES.md` 4）：`defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES`

**构建/测试不用每次重敲**：本机已固化两个技能 `macos-build-test`（macOS 本机 + SwiftPM）与
`ios-build-test`（iOS 模拟器/真机），各带 `scripts/*-run.sh`：**自动判断要不要沙箱逃逸**、
自动挑模拟器、固定 derivedData、日志落文件只回打关键行。先跑 `… probe` 看环境。

⚠️ **被外部沙箱包裹的 shell 里要加 `MARQUEE_DISABLE_COMPILER_SANDBOX=1`**：
`swift-plugin-server`（宏）无法 apply 自己的沙箱，报 `sandbox_apply: Operation not permitted`
⇒ 宏展开失败。逃逸口是 `swiftc` 自己的 `-disable-sandbox`（**官方那三个 `IDEPackageSupport*`
参数无效**，它们关的是内层）。已固化进 `build.sh`。

## 不可砍 / 明确砍掉

1. **窗口自动识别 + 悬停高亮**；2. **滚动截屏 / 长截图**；3. **标注为对象、可反复编辑**。
砍掉：QQ 邮箱分享、QQ 邮箱网页插件。

## 设计硬约束（用户明确要求「功能简洁 + 交互流畅」）

菜单栏下拉 ≤ 6 项；编辑器工具栏 ≤ 9 工具；首选项 ≤ 4 页；模式弹窗 0 个。
**覆盖层工具条整条必须放得进 1024 点的屏**。
性能：编辑器重绘 ≤ 4 ms；选区拖拽 120 fps；模糊/马赛克 ≤ 5 ms；落点→剪贴板 ≤ 150 ms。

## 核心风险

**R1 滚动截屏**：中，剩余全在**真实场景**（sticky header / 惯性 / 动态内容）。
**R10 OCR 首次约 25 s** → 启动预热；**R11 超长图画布渲染**。

## 最狠的几条陷阱（全量见 `docs/PITFALLS.md`）

- **不崩不报错、只悄悄错**：位图行序/CTM 翻转、`bytesPerRow` 未对齐、P3 vs sRGB；AppKit 里**子视图永远盖在父视图自己画的东西之上**（89）。
- **`nil` 兜底会把"不适用"变成"合法值"**（101）。**`lineWidth = 0` 不是"不画线"**（120）。
- **改一个判据常量的「含义」前先列出它的所有使用者** —— 条件等价 ≠ 运行路径等价（102）。
- **瞬时标志位不许决定常驻 UI 的可见性**；收尾只能有一处（66）。
- **误判不能做成终局**：降级为"提示 + 可恢复"。**「商店里没有」只有在真的问过之后才算证据**（126）。
- **断言要写「意图」**：只写边界的测试是盲的；**用例参数要覆盖最坏情况**（98）。
- **变异不变红有两种可能：断言是盲的，或那段代码是死的** —— 两者处理完全相反（117）。
- **删入口 ≠ 删能力**：模型是数据契约、UI 是入口（100）。**适配器里不许做判断**（130）。
- **系统级注册会抢在响应链之前**：全局快捷键在录制时会把按键吃掉 ⇒ 录不进去还真的触发（179）。
- **不知道原因时只说「失败」**：把"用户取消"与"连不上"混成一档，界面就必然对其中一种说错话，去修一个没坏的东西（180）。
- **「点了没反应」= `_ =` 掉结果 + 用瞬时状态决定常驻按钮能否点**（181）。
- **bundle id 的**大小写**也是「对不上」**：商品只在逐字符一致时才会被返回，而 App ID 建了不能改 ⇒ 能动的那侧只有代码（182）。
- **设计稿的「描述」与「数据」会互相矛盾** —— 尺子以数据为准，但那条宽松断言要留着当路障（183）。
- **辅助功能开关不能拿「另一种半透明」去答**；判据的**顺序**也是判据，写反只在 26+ 发作（184）。
- **图标换了来源，「唯一来源」的守卫要从「名字唯一」升级成「来源唯一」**（185）。
- **自绘一枚图形时最危险的是顺手把别处也改掉** —— 放大镜的色值框必须留成不透明，名字里那个 `Opaque` 就是守卫（186）。
- **玻璃任何离屏渲染都拍不到** ⇒ 出图那条路一定拍到回退档，那**不是**故障；玻璃只能实机看（187）。
- **`CGWindowListCreateImage` 在 macOS 15+ 已不可用**（必须 ScreenCaptureKit ⇒ 一定要授权） ⇒ "抓自己的窗口"这条捷径**根本不存在**，玻璃只能由人点一次授权再实机拍（188）。
- **`open -a App --args <flag>` 在被沙箱包裹的 shell 里会静默丢参**（三种写法全试过）⇒ 现象与"这个开关没实现"一模一样；**加命令行开关就顺手加一行启动凭证**（`reports/launch-arguments.txt`），并把 `open -a` 留给用户自己的终端（同时解决"参数送得到"与"TCC 认它是自己"）（189）。
- **`_ =` 掉一个用户主动发起的动作的结果 = 「点了没反应」**；用瞬时状态（`unknown`）决定常驻按钮能否点，会让入口变成出不去的死胡同（181）。

## 文档与资产

| 路径 | 内容 |
| --- | --- |
| **`.workbuddy/memory/INTERACTION.md`** | **逐条交互实现细节**（写 UI 前必读） |
| **`docs/PITFALLS.md`** | **189 条实现陷阱**（写代码前必扫） |
| **`docs/APP-STORE-CONNECT.md`** | **ASC 操作清单**（两个商品怎么建 · 提审前必须补的代码缺口） |
| `docs/review/` · `-marqueeSmokeReview` | **IAP 审核截图**（1280×800，ASC 对 macOS 的硬性尺寸）：真界面 2 倍离屏渲 + 超采样缩进画布 + 运行期算的标注框。**不需要屏幕录制授权** |
| **`docs/MAS-AND-MONETIZATION.md`** | 收费与上架方案（已定）：¥36 · 路线 B · Pro 边界与**「被挡住时」的界面行为** · ticket 29–33 施工图 |
| **`docs/DEV-VS-PROD.md`** | 开发版与正式版怎么区分（两个 id · 三个配置 · 改名时间窗） |
| **`docs/STATUS-AND-ACCEPTANCE.md`** | **进度 / 阻塞项 / 人工验收清单**。验收与汇报从这份起 |
| `docs/PRD.md` · `docs/SPIKE-PLAN.md` | 产品与方案设计 / 坑点清单 + 提前验证报告 |
| `docs/DEV-NOTES.md` · `docs/RELEASE.md` | 开发循环的已知摩擦 / 打包公证复现步骤 |
| `docs/SCREEN-RECORDING-PERMISSION.md` · `docs/RENDER-BENCH.md` | 权限复盘 / 渲染技术实测 |
| **`docs/design/`** | 设计稿快照 + 对照记录。**稿子只是契约，产物是能编译能跑能截图的代码**。⑩ 玻璃材质那轮见 `2026-10-04-玻璃材质/对照.md`（**玻璃已实装但走的是系统原生材质、覆盖面偏 4 处；钉图图标稿子的换图理由在实装里不成立**） |
| `.scratch/issues/2026-09-30-marquee-mvp/` | **33 条 ticket + INDEX**；`01`–`30` 与 `31` 两批已落地，`31` 剩界面，`32`/`33` 沙盒化待开工 |
| `Tools/IconGen` · `Tools/L10nCatalog` · `Tools/SymbolProbe` | App 图标生成器 / 唯一能**生成** catalog 的工具（扫描测试只能校验）/ SF Symbol 探针 |

## 工作流约定

门禁 **spec → solution → test plan → impl → delivery**，逐段确认；TDD 红→绿 + 变异测试，测试永久留仓。
**未经明确指令不 commit/push。** 用户偏好极简编号指令（"1 提交 2 继续下一步"）。

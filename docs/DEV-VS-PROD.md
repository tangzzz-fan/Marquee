# 开发版与正式版的区分（spec）

> 状态：✅ **已实施**（2026-10-03，分支 `feat/iap`）。
> 正式 `com.tango.marquee` / 开发 `com.tango.marquee.dev`；三个配置 `Debug` / `Dev` / `Release`。
> 实施记录见 §9。

---

## 0. 结论

1. **现状**：没有区分，也没有文档。本地构建出来的 app 与将来上架的 app **是同一个身份**。
2. **方向（修订）**：原先我推荐"bundle id 不变，靠数据目录隔离"。用户指出
   **iOS 的常规做法本来就是两个 id（开发 / 正式）** —— 这个意见是对的，
   而且**两个 id 比那个方案隔离得更彻底、代码还更少**：

   | | 两个 id | 我原方案（改数据目录） |
   | --- | --- | --- |
   | 偏好（含调试开关） | **系统按 bundle id 自动隔离** | 要自己搞 suite 名 —— 而我自己把它标成了"最容易做漏" |
   | TCC 授权 | 各自一条，开发时怎么折腾都不动正式那条 | 共用（开发中误撤销会连带正式版） |
   | 数据（历史 / 输出） | 目录名就用 bundle id，**将来任何新变体自动隔离** | 要写死一个 `-dev` 后缀 |
   | 真实沙盒内购 | ⚠️ 要在**正式 id 的构建**上验（见 §3.2） | 同左 |

   ⇒ **采纳两个 id。**
3. **改名要现在做。** Apple 的规则是：**一旦往 App Store Connect 上传过构建，bundle ID 就不能再改**
   （只能新建 app 记录）。我们**一次构建都没上传过** ⇒ 现在改是**免费**的；
   上传之后改 = 新 app（评论、评分、安装量全部清零）。窗口就在这里，见 §3.1。

---

## 1. 现状（有据可查）

| 维度 | 现状 | 依据 |
| --- | --- | --- |
| bundle id | **只有一个** `dev.tango.Marquee` | `project.yml:9, 104` |
| 编译期开关 | **`#if DEBUG` 全仓 0 处** | 全仓 grep |
| 构建配置 | XcodeGen 默认的 `Debug` / `Release`，没有自定义配置 | `project.yml` |
| 本地 Run 的配置 | **`Release`**（性能预算只在优化构建下才有意义） | `project.yml` 的 scheme |
| 签名 | `Apple Development` + team `UKXWZ3FS84`；`scripts/build.sh` 还额外 `codesign --identifier dev.tango.Marquee` 重签一次 | `project.yml` / `scripts/build.sh:98` |
| 最近截图仓库 | `~/Library/Application Support/Marquee/history/`（**硬编码 `Marquee`**，不看 bundle id） | `CaptureHistoryStore.defaultDirectory` |
| 默认保存位置 | `~/Desktop`（另有默认值在别处） | `OutputSettings.desktopDirectory()` |
| 偏好 | `UserDefaults.standard`（域 = bundle id） | `UserDefaultsPreferencesStore` |
| 日志 subsystem | **写死** `"dev.tango.Marquee"` | `SelectionOverlayController:96` |
| 调试开关 | `chrome.forceHUD` / `chrome.tint` / `chrome.scrim` / `overlay.traceFrames`，都走 `UserDefaults` | 各模块 |
| 文档里的 id | **约 20 处** `defaults write dev.tango.Marquee …` / `tccutil reset … dev.tango.Marquee` | `README.md`、`STATUS-AND-ACCEPTANCE.md`、`DEV-NOTES.md`、`SCREEN-RECORDING-PERMISSION.md` |
| 相关文档 | 没有一篇讲开发版与正式版的区分 | `docs/` |

---

## 2. 三类真实风险（不是"理论上的不干净"）

1. **数据。** 开发时随手截的图会进**同一个** history；调试"删除历史"的逻辑，删的是真实历史。
2. **偏好。** 调试开关住在 `UserDefaults`，而**它的域就是 bundle id** ⇒
   开发时敲的 `defaults write …` **会留在正式版里**。而这类开关的表现恰好是"外观不对"，
   很难第一时间联想到"是我上周敲的那条命令"。
3. **授权与交易。** TCC 按「bundle id + 签名身份」记账 ⇒ 开发构建与正式版共用一条授权
   （好处是开发时不用重复授权，坏处是**开发中误撤销，正式版也一起没了**）。
   ticket 31 之后：沙盒交易与本地测试交易会落在同一份权益状态里。

---

## 3. 两条硬约束

### 3.1 改名的时间窗

Apple《Changing the bundle identifier》原文：

> **If you previously uploaded a build to App Store Connect, you can't change the bundle ID.**
> Create a new app record with the bundle ID instead of updating the existing app record.

> If you plan to distribute your app through the App Store and **you've created an app record,
> but haven't uploaded a build yet**, then you can still change the bundle ID in your app record
> to match your Xcode project.

Apple DTS（Quinn）在开发者论坛的回复：

> **If you change the bundle ID then, by definition, you have a new app.**
> …switching the bundle ID after launch is much more painful.

另外两条容易忽略的：

- **删掉 app 记录并不会释放那个 bundle id**（原文：「Deleting an existing app record doesn't
  make its bundle ID available.」）—— 所以"先随便建一个，改了再删"这条路**不通**。
- 第三方一致：bundle id 上线后不可变，改 = 新 app，**丢掉排名、评论、安装量**。

⇒ **我们现在处在免费窗口里，且没有任何东西需要迁移**（没有 app 记录、没有上传、没有 IAP 商品）。

### 3.2 IAP 商品挂 bundle id

Apple **TN3186**（*Troubleshooting In-App Purchases availability in the sandbox*）
把这条列在"商品取不到"原因清单的**第一条**：

> **Your bundle ID doesn't match the bundle ID of an app in App Store Connect.**

并且沙盒测内购**必须**用「在 App Store Connect 注册、且为它开启了 In-App Purchase 能力的
bundle id」。第三方总结：**IAP 商品永久绑定创建时的 bundle id，换 id 之后老商品成为孤儿、
无法转移。**

**⚠️ 我上一版的推论下重了，这里修正：**

我原先写"换 id 会让开发版永远测不到真实沙盒交易，所以方向反了"。**前半句对，后半句错。**
代价不是"放弃支付测试"，而是"**沙盒验证放在正式 id 的构建上做**" —— 而那个构建**本来就要出**
（发版必须出）。分工是明确的：

| 场景 | 用哪个构建 | 怎么测 |
| --- | --- | --- |
| 日常开发 | `.dev` id | 不碰真实交易 |
| 购买流程：购买 / 取消 / **待批准** / **退款** / 家庭共享被移除 / 重复购买 / 恢复购买 | `.dev` id | **`.storekit` 本地配置**（不用网络、不用 App Store Connect，可手动模拟退款与撤销） |
| **真实沙盒交易**（收据、`Transaction.updates`、真实价格与区域、真实账号） | **正式 id** | **沙盒测试账号**（ASC → 用户和访问 → 沙盒测试员） |
| 上线后 | 正式 id | 生产 |

⇒ **"两个 id"与"能测支付"不冲突**，前提是别指望开发构建去验真实交易。

---

## 4. 方案（已定）

| 配置 | 用途 | bundle id | 沙盒 | 优化 |
| --- | --- | --- | --- | --- |
| `Debug` | 要"能用的断点"时临时把 Run 切过来 | `<正式 id>.dev` | 无 | `-Onone` |
| **`Dev`** | **本地运行（scheme 的 Run）** | **`<正式 id>.dev`** | 无 | **照抄 `Release`** |
| `Release` | **Developer ID** 打包（`scripts/package.sh`） | 正式 id | **无** | 优化 |
| **`MAS`** | **上架 App Store**（2026-10-03 加） | 正式 id | **有** | 优化 |

> ⚠️ **「沙盒」那一列是 2026-10-03 才有的第四档**（ticket 32）。四件事要看清：
>
> 1. **只有 `MAS` 带 `CODE_SIGN_ENTITLEMENTS`** —— 也就是说只有它进沙盒。
>    `Release` 不带是刻意的：它是 **Developer ID** 那条路，而那条路存在的
>    **全部价值就是保住自动滚动**（沙盒禁止向其它 app 投递输入事件）。
> 2. **`Debug` 的身份与数据根早已不是"正式 id / 临时目录"**（这张表原先写错了）：
>    它和 `Dev` 一样是 `com.tango.marquee.dev`，**从 Debug 切到 Dev 不会多出一个身份**。
> 3. **bundle id 靠继承**：`settings.base` 里是正式 id，只有 `Debug` / `Dev` 覆盖成 `.dev`。
>    所以"只有 `Release` 与 `MAS` 拿生产 id"这条约束由**继承关系**保证，不靠人记得。
> 4. **`ENABLE_HARDENED_RUNTIME` 四份配置都开**（在 `settings.base` 里）。
>    与"`Dev` 照抄 `Release` 的优化设置"同一条理由：**本地跑的那个与发版行为一致，
>    问题才会在平时暴露**。只给发版配置开的话，硬运行时独有的破坏要等到打包那天
>    才发现 —— 而那正是最不适合发现它的时刻。
>    （历史：2026-10-03 之前这里是 `NO`，而 `scripts/package.sh` 走公证 ⇒
>      那条路**必然**会在公证那步被拒，只是 ticket 18 从没真跑过。）

### 4.1 `Dev` 与 `Debug` 的区别（逐项对比过）

**先说最容易搞错的一点：两者在「身份」上毫无区别。** 都是 `com.tango.marquee.dev`，
于是数据目录、偏好域、TCC 授权都是同一份 —— **从 Debug 切到 Dev 不会多出一个身份**。

真正的差别只在编译器设置。生成工程后把两份 `XCBuildConfiguration` 摊开对比：
**48 项相同、11 项不同**，且那 11 项全是这类东西：

| 项 | `Debug` | `Dev`（＝同 `Release`） | 实际影响 |
| --- | --- | --- | --- |
| `SWIFT_OPTIMIZATION_LEVEL` | `-Onone` | `-O` | **Debug 慢得多** |
| `SWIFT_COMPILATION_MODE` | （未设置 → 增量） | `wholemodule` | 全模块优化 |
| `GCC_OPTIMIZATION_LEVEL` | `0` | （未设置 → 默认优化） | C/C++ 侧同上 |
| `DEBUG_INFORMATION_FORMAT` | `dwarf` | `dwarf-with-dsym` | Dev/Release 有 dSYM |
| `ENABLE_TESTABILITY` | `YES` | （未设置 → `NO`） | Debug 才能 `@testable import` |
| `ONLY_ACTIVE_ARCH` | `YES` | （未设置 → `NO`） | Debug 只编当前架构，更快 |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `DEBUG` | （未设置） | 见下面那条警告 |
| `MTL_ENABLE_DEBUG_INFO` | `INCLUDE_SOURCE` | `NO` | Metal 调试信息 |
| `ENABLE_NS_ASSERTIONS` | （未设置 → `YES`） | `NO` | 关的是 ObjC 的 `NSAssert` |
| `GCC_DYNAMIC_NO_PIC` / `GCC_PREPROCESSOR_DEFINITIONS` | `NO` / `DEBUG=1` | （未设置） | —— |

**谁在用哪个配置**（读 scheme 得来）：

| Action | 配置 |
| --- | --- |
| Run（`⌘R`） | **`Dev`** |
| Test（`⌘U`） | `Debug` —— ⚠️ 但工程里**没有 test target**（单元测试走 SwiftPM），所以这个 action 是空转 |
| Analyze | `Debug` |
| Profile | `Release` |
| Archive | `Release` |

⇒ **本项目里 `Debug` 的真实用途只有一个：要"能用的断点"时，把 Run 临时切过去。**
（`Dev` 是优化构建，断点与变量查看会被优化打乱 —— 这正是项目一开始把 Run 放在 Release 上的原因。）

### 4.2 与 `Debug` 有关的两条硬规则

1. **测性能只能用 `Dev` 或 `Release`。** `-Onone` 下"落点→剪贴板 ≤150 ms""选区拖拽 120 fps"
   这些数字没有参考价值 —— 而 `Dev` 存在的**全部理由**就是让"本地跑的那个"与发版同优化。
   在 Debug 下觉得卡，**不代表产品卡**。
2. **断言只在 `Debug`（以及 `swift test`）下真的会触发。** Swift 的 `assert` 由**优化级别**决定：
   `-O` 会把它移除，所以 `Dev` / `Release` 里它不跑。`ENABLE_NS_ASSERTIONS` 管的是
   Objective-C 的 `NSAssert`（本项目没用）。⇒ 想靠断言发现的问题，得在 Debug 下跑一遍。

> ⚠️ 顺带一条：`Debug` 会定义 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`，
> 但本项目**全仓 0 处 `#if DEBUG`** —— 也就是说这个编译条件目前一点用都没有。
> **不要**用它来区分开发/正式行为；要区分就用 `AppIdentity.isDevelopmentBuild`
> （见 §4 的"关键简化"）—— 那是能脱机单测的。

### 4.3 沙盒改掉了哪几处行为（ticket 32）

沙盒不是"多了一个限制"，是**改了几处行为**。四处，每处都有对应判据：

| 行为 | 非沙盒 | 沙盒 | 判据 |
| --- | --- | --- | --- |
| 自动滚动 | 可用（按需申请辅助功能） | **做不到**，且**不许去申请** | `AutoScrollGate.evaluate(isSandboxed:permissionGranted:)` |
| 默认落盘 | `~/Pictures/Marquee` | **同一个路径**（`getpwuid` 的真实家目录拼出来） | `OutputSettings.defaultOutputDirectory()` |
| 历史仓库 | `~/Library/Application Support/<id>/history/` | 容器内的同名位置 | `AppIdentity.supportDirectory()` |
| 探针报告 | `<数据根>/reports/` | 同上（容器内） | `AppIdentity.logDirectory()` |

**四条硬规则**：

1. **判据按运行期分派，不按配置。** 编译期开关（`#if` / 配置名）会让同一份代码
   在两个构建里行为不同，而**没编进去的那条分支只有发版那天才跑得到**。
   唯一入口是 `AppIdentity.isSandboxed`（读 `APP_SANDBOX_CONTAINER_ID`，可注入 ⇒ 能脱机单测）。
2. **别问 `FileManager` 要"家目录"。** 沙盒下 `NSHomeDirectory()` 是容器，
   `.picturesDirectory` 由它推出来 ⇒ 也指向容器里的 Pictures。图会存进
   `~/Library/Containers/<id>/Data/Pictures/` —— **保存"成功"、用户翻遍访达找不到**，
   而这正是本项目最忌讳的那类错（不崩、不报错、只悄悄错）。
   给用户看的东西走真实家目录（`getpwuid`）；给排障看的走
   `.applicationSupportDirectory`（沙盒下**确定**是容器）。见 `docs/PITFALLS.md` 144。
3. **沙盒构建只能在 `open` 下启动，不能在终端里直接跑。** 开发会话自身就在沙盒里，
   `libsecinit` 装不上自己的沙盒 → **SIGTRAP 崩在 `main` 之前，一行输出都没有**。
   所以自检报告必须落文件（stdout 在 `open` 下是拿不到的）。见 `docs/PITFALLS.md` 143。
4. **不要在沙盒内做数据迁移。** 沙盒进程读不到容器**外**的 Application Support。
   这件事只能由**非沙盒**构建代劳 —— 或者干脆不做：路线 B 下 MAS 版是首发，
   用户本来就没有"沙盒外的老数据"。（偏好还根本不在 Application Support。）

### 关键简化：「是不是开发版」由 bundle id 推导，不用编译期开关

- **数据目录**：`~/Library/Application Support/<bundle id>/history/`
  —— 把硬编码的 `Marquee` 换成 bundle id，于是**将来加任何变体（beta / staging）都自动隔离**，
  而且**不用写任何 dev 专用代码**。
- **偏好**：系统按 bundle id 自动分域，**一行都不用改**。
- **菜单栏标题**：id 以 `.dev` 结尾 → 追加 ` · 开发版`。这是整套里最便宜也最有用的部分 ——
  一眼就知道现在跑的是哪一个。
- **日志 subsystem**：现在写死了 `dev.tango.Marquee`，改成从 `Bundle.main` 取。

> 为什么 `Dev` 必须照抄 `Release` 的优化设置：scheme 的 Run 从 `Release` 改指 `Dev` 之后，
> 如果 `Dev` 是未优化构建，"落点→剪贴板 ≤150 ms / 拖拽 120 fps"这些数字就不可比了 ——
> 而 Run 走 Release 本来就是为了这个。

---

## 5. 改名波及面（约 20 处）

| 位置 | 改什么 |
| --- | --- |
| `project.yml` | `bundleIdPrefix`、`PRODUCT_BUNDLE_IDENTIFIER`、新增 `Dev` 配置 |
| `scripts/build.sh:98` | `codesign … --identifier dev.tango.Marquee`（**这一处漏了会让 TCC 身份对不上**） |
| `Modules/…/SelectionOverlayController.swift:96` | 日志 subsystem |
| **Core（新增）** | bundle id 的**唯一来源**（`AppIdentity`），其余地方一律从它取 |
| `CaptureHistoryStore`、`OutputSettings` | 数据目录 / 输出目录默认值改成从 `AppIdentity` 取 |
| `README.md`、`STATUS-AND-ACCEPTANCE.md`、`DEV-NOTES.md`、`SCREEN-RECORDING-PERMISSION.md` | 全部 `defaults write dev.tango.Marquee …` / `tccutil reset … dev.tango.Marquee` |
| `docs/MAS-AND-MONETIZATION.md` | IAP 商品 id `dev.tango.Marquee.pro` → `<新 id>.pro`（**现在改是免费的**，商品还没建） |
| `Modules/Tests/*` | 测试用的 suite 名（`dev.tango.Marquee.tests.<uuid>`，可留可换） |

**副作用（预期内）**：屏幕录制授权要**重新授一次**（TCC 按 bundle id 记账）；
老的 `~/Library/Application Support/Marquee/history/` 不会自动搬 ——
要么写一次性迁移，要么接受（本地开发数据，重截即可）。

---

## 6. 落地清单（已全部完成，见 §9）

- [x] 定前缀：**`com.tango.Marquee`**（原 `dev.tango.Marquee`）
- [x] `project.yml`：`bundleIdPrefix: com.tango`；新增 `Dev` 配置（type = release）；
      `Debug` 与 `Dev` 都是 `.dev` 身份，**只有 `Release` 拿得到正式 id**
- [x] scheme：`run.config` 从 `Release` 改成 `Dev`
- [x] Core：新增 `AppIdentity`（bundle id 的**唯一来源**）+ "是不是开发版"的判据
- [x] `CaptureHistoryStore` 的数据目录改从 `AppIdentity` 取（不再写死 `Marquee`）
- [x] 日志 subsystem 改从 `AppIdentity` 取（固定用正式 id，两个版本同一条 grep）
- [x] `scripts/build.sh` 的 `--identifier` 改成**从产物读**
- [x] 菜单栏提示 / 设置窗口标题加 ` · 开发版`（仅 `.dev`）
- [x] `scripts/package.sh` 前置检查：产物身份必须是正式 id（不是就停下）
- [x] 文档全量替换（31 处）

## 7. 前缀：已定 `com.tango.Marquee`

> ### ⚠️ 2026-10-04：正式 id 改成**全小写** `com.tango.marquee`
>
> **为什么**：ASC 里的 App ID 是按小写创建的，而 TN3186 把"bundle id 与 ASC 里的
> app 对不上"列为**商品取不到的第一条原因**；而 App ID 与 app 记录的 bundle id
> **建了就不能改**（只能删了重建，且 app 记录一旦创建就不能换 id）。
> ⇒ 只能改代码这一侧。
>
> **改了什么**：`AppIdentity.productionBundleIdentifier` · `project.yml` 的两处
> `PRODUCT_BUNDLE_IDENTIFIER`（正式 / `.dev`）· `scripts/package.sh` 的期望值 ·
> `scripts/build.sh` 的 `codesign --identifier` 兜底 · **两个商品 id**
>（`com.tango.marquee.pro` / `.pro.trial`，它们由一条断言要求以正式 id 作前缀）·
> `App/Products.storekit` · 各文档里的命令与 ASCII 图。
>
> **代价（都要重来一次，但都只影响这台开发机）**：
>
> | 项 | 后果 |
> | --- | --- |
> | TCC（屏幕录制授权） | 按 bundle id 记账 ⇒ **要重新授权一次** |
> | 偏好 / 权益缓存 | UserDefaults 的域就是 bundle id ⇒ 开发机上看起来"全都回到默认" |
> | 数据根目录 | `~/Library/Application Support/com.tango.marquee/`（老的那份留在原地，不自动搬） |
>
> **没变的**：正式 / 开发两个身份的分法、`.dev` 后缀推导、四个构建配置的语义。
> 下面这一节（§7 原文）与 §9 的实施记录是**当时**的事实，刻意不改写。

约定是**反写你控制的域名**（`com.example.app`）。Apple 不校验域名归属，但
"能反写一个真实域名"在将来（App 转让、SDK 备案、universal links）会省事。

选它的理由：**改动最小**（只把 `dev` 换成 `com`），同时把"前缀叫 dev"这个坑填掉 ——
那三个候选（`com.tango.Marquee` / `app.marquee.mac` / 自有域名反写）里，
它不需要引入新概念，也不依赖本人是否拥有某个域名。

## 8. 还没核实的

- ⚠️ `Apple Development` 签名的 `Dev` 构建，能否在**沙盒账号**下完成真实购买。
  我的判断是**可以**（沙盒环境只认 bundle id + 沙盒账号，与签名方式无关），
  但这条**要实测**，不能当成已知条件写进方案。
- ⚠️ 把数据目录从 `Marquee/` 换成 `<bundle id>/` 之后，
  历史仓库在**沙盒构建**（ticket 32）下的路径 —— 那里会再变成容器内，两件事要一起想。

---

## 9. 实施记录（2026-10-03，分支 `feat/iap`）

### 改了什么

| 位置 | 改动 |
| --- | --- |
| `project.yml` | `bundleIdPrefix` → `com.tango`；新增顶层 `configs`（Debug/Dev/Release）；target 的 `settings.configs` 给 Debug 与 Dev 装 `.dev` 身份；scheme 的 `run.config` → `Dev` |
| `MarqueeCore/AppIdentity.swift`（新） | bundle id 的**唯一来源**；`isDevelopmentBuild`（后缀判定）、`developmentTitleSuffix`、`logSubsystem`、`supportDirectory` / `historyDirectory` |
| `CaptureHistoryStore` | `defaultDirectory` 改从 `AppIdentity` 取 ⇒ 数据落在 `Application Support/<bundle id>/history/` |
| 两个 Logger | subsystem 从写死改成 `AppIdentity().logSubsystem` |
| `MenuBarController` / `PreferencesWindowController` | 加 ` · 开发版` 后缀 |
| `scripts/build.sh` | 默认配置 → `Dev`；`codesign --identifier` **从产物 plist 读**；末尾打印"配置 + 身份 + 开发版/正式版" |
| `scripts/package.sh` | 新增**身份核验**：导出后的包必须是正式 id，否则 `exit 1` |
| 文档 | 31 处 `dev.tango.Marquee` → `com.tango.Marquee`；翻译表新增「开发版」→ "Development build"，catalog 187 → 188 条 |

### 验证过的

- `xcodegen generate` 后读 `project.pbxproj`：三个配置都在，
  `Release` = `com.tango.marquee`，`Dev` / `Debug` = `com.tango.marquee.dev`；
  scheme 的 `LaunchAction buildConfiguration = "Dev"`。
- **`Dev` 与 `Release` 的项目级构建设置逐项一致**（53 项，含
  `SWIFT_OPTIMIZATION_LEVEL = -O`、`SWIFT_COMPILATION_MODE = wholemodule`、
  `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`、`ENABLE_NS_ASSERTIONS = NO`），
  而 `Debug` 是 `-Onone` / `dwarf` / `ENABLE_TESTABILITY = YES`。
  ⇒ Run 换到 `Dev` 之后，性能预算的数字仍然与发版构建可比。
- 两个 shell 脚本 `bash -n` 通过；`./scripts/test.sh` 全绿（新增 6 条 `AppIdentityTests`）。

### 两条踩到的

1. **批量改名差点改掉一条本来就要"用旧 id"的断言。**
   `AppIdentityTests` 里有一条拿旧 id `dev.tango.Marquee` 当反例
   （"前缀里的 dev 不该被当成开发版"），全量替换把它换成了新 id ——
   于是那条断言变成与上一行重复（**在测同一件事两遍**，而不是测"前缀冒充"）。
   已手工改回。
   > 判据：**批量替换之后要看一眼 diff 里"被改动的断言"**。
   > 测试里出现旧的标识符，往往**不是漏改，而是它在当反例**。
2. `scripts/build.sh` 里那句 `codesign --identifier dev.tango.Marquee` 是**最容易漏的一处** ——
   它写死了身份，漏掉的表现是"屏幕录制授权又留不住了"，与 bundle id 改没改
   在现象上完全联系不起来。改成从产物 plist 读，从根上消掉这个二义性。

### 还没做的

- 本地旧数据（`~/Library/Application Support/Marquee/history/`）**没有迁移**，
  也没有写 in-app 迁移代码：这个 app 从未发布过，写一段"给不存在的用户"的迁移
  是纯死代码。开发机上的那点历史重截即可。
- 屏幕录制授权要**重新授一次**（换成 `.dev` 身份之后是新的一条），预期行为。

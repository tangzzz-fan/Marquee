# 开发版与正式版的区分（spec）

> 状态：✅ **已实施**（2026-10-03，分支 `feat/iap`）。
> 正式 `com.tango.Marquee` / 开发 `com.tango.Marquee.dev`；三个配置 `Debug` / `Dev` / `Release`。
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

| 配置 | 用途 | bundle id | 数据根 | 优化 |
| --- | --- | --- | --- | --- |
| `Debug` | 只用于跑测试 | 正式 id | 测试临时目录 | 不优化 |
| **`Dev`** | **本地运行（scheme 的 Run）** | **`<正式 id>.dev`** | 自动（按 id） | **照抄 `Release`** |
| `Release` | 发版 / 打包 / **沙盒验证** | 正式 id | 自动（按 id） | 优化 |

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
  `Release` = `com.tango.Marquee`，`Dev` / `Debug` = `com.tango.Marquee.dev`；
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

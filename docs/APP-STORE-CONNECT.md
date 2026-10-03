# App Store Connect 要完成的事（内购上线清单）

> 这份文档只回答一个问题：**为了让 `⌃Q` 之外的"付费"这件事真的成立，你要在 ASC 网页上点哪些按钮。**
>
> 分工（别在别的文档里找这些）：
>
> | 你想知道 | 去哪 |
> | --- | --- |
> | 为什么要买断 ¥36、Pro 含哪四项 | `docs/MAS-AND-MONETIZATION.md` §1 |
> | 开发版与正式版怎么分、商品为什么不能挂 `.dev` id | `docs/DEV-VS-PROD.md` §3.1 / §3.2 |
> | 打包、公证、公证后的验收 | `docs/RELEASE.md` |
> | **本文档** | **ASC 上的按钮 + 提审前必须补的代码缺口** |
>
> 最后核对时间：**2026-10-04**。ASC 的界面改版很勤，措辞可能变，但**每一步的判据（"做完之后你能验证什么"）不会变** —— 卡住时对着那一列查。

---

## 0. 先看清三件事

### 0.1 你要建的是两个商品，不是一个

代码侧的唯一来源是 `MarqueeCore/Storefront.swift` 的 `StoreCatalog`；本地测试用的镜像在 `App/Products.storekit`。**这两份必须与 ASC 里的一致**，有一条测试（`StoreCatalogConfigTests`）只负责盯前两份。

| | 买断商品 | 试用商品 |
| --- | --- | --- |
| 产品 ID | `com.tango.marquee.pro` | `com.tango.marquee.pro.trial` |
| 类型 | **非消耗型**（Non-Consumable） | **非消耗型**（不是"另一种类型"，它只是 0 价） |
| 价格 | ¥36（中国区） | **价格等级 0** |
| 家人共享 | **开** | **关** |
| 显示名（中 / 英） | `Marquee Pro` / `Marquee Pro` | `Marquee 7 天试用` / `Marquee 7-Day Trial` |
| 用途 | 解锁四项 Pro 能力 | 7 天全功能试用 |

⚠️ **产品 ID 一旦创建就永久绑定当时的 bundle id，不能改、不能转移**（Apple TN3186）。所以 ASC 里那个 App 记录必须是 `com.tango.marquee`（正式 id），**不是** `.dev`。

### 0.2 试用为什么是一个单独的 0 价商品

App Review 指南 3.1.1 原文（已核对，`developer.apple.com/app-store/review/guidelines/` 最后一条）：

> Non-subscription apps may offer a free time-based trial period before presenting a full unlock option
> by setting up a **Non-consumable IAP item at Price Tier 0** that follows the naming convention: **"XX-day Trial"**.
> Prior to the start of the trial, your app must clearly identify its duration, the content or services that
> will no longer be accessible when the trial ends and **any downstream charges** the user would need to pay
> for full functionality.

中文官方版：**"在『价格等级 0』中设置非消耗型 IAP 项目，并按照命名约定『XX 天试用』"**；
并且**试用开始前必须清楚指明**：① 时长 ② 结束后不再能访问的内容 ③ 用户为获得完整功能需要的**后续费用**。

⇒ 这条决定了三件事：价格等级确实是 0、**显示名必须含天数**、**界面必须在开始试用前说出 ¥36**（见 §4）。

### 0.3 三个前置条件（不满足则整条链走不通）

| 前置 | 在哪 | 不满足的症状 |
| --- | --- | --- |
| **付费应用协议（Paid Apps Agreement）已生效** | ASC →「协议、税务和银行业务」 | 商品建得出来但**取不到**；StoreKit 调用静默失败 |
| **银行 + 税务信息填完** | 同上 | 同上（协议会停在"待生效"） |
| App ID `com.tango.marquee` 已注册、且**开启 App 内购买能力** | 开发者后台 →「证书、标识符和描述文件」→ Identifiers | 建 IAP 时找不到对应的 app，或 IAP 无法关联 |

⚠️ **这三条是纯阻塞项**，且都不在代码里 —— 代码那边可以全绿而这里一步没做。

---

## 1. 逐步清单（按你在 ASC 里的操作顺序）

### 1.1 开付费应用协议

- [ ] ASC →「协议、税务和银行业务」→ 接受 **Paid Applications Agreement**
- [ ] 填银行账户（Banking）与税务表（Tax Forms）
- [ ] 确认协议状态是**生效 / Active**，不是"待处理"

**做完能验证什么**：`Products.storekit` 那套本地测试**验不了这条**（它不走网络）。唯一的验证是走到 §2 的沙盒测试。

### 1.2 注册 App ID 并开启 IAP 能力

- [ ] 开发者后台 → Identifiers → 新建 App ID：`com.tango.marquee`（**Explicit**，不能是通配符 `com.tango.*`）
- [ ] Capabilities 里勾上 **In-App Purchase**

**为什么要 Explicit**：通配符 App ID **不能用于内购**（Apple 明文）。这条写下来是因为它就是"商品取不到"的第一名原因。

### 1.3 创建 app 记录（如果还没有）

- [ ] ASC →「我的 App」→ 新建：Bundle ID 选 `com.tango.marquee`
- [ ] 名称、SKU、主要语言（建议 `简体中文`，与 `developmentLanguage: zh-Hans` 一致）
- [ ] App 信息里的「价格与销售范围」：**app 本身免费**（钱从内购收）

⚠️ **app 本身必须免费**：买断 ¥36 是那个 IAP 的价格，不是 app 的价格。设成付费 app 会变成"先花 ¥36 买 app，再花 ¥36 解锁"，是两笔钱。

### 1.4 创建第一个商品：买断

ASC → 我的 App → 选 Marquee → 侧栏「App 内购买项目」→ `+`

- [ ] 类型：**非消耗型项目（Non-Consumable）**
- [ ] 参考名称：`Marquee Pro`（内部用，不展示；**与本地 `Products.storekit` 保持一致**，方便对照）
- [ ] 产品 ID：`com.tango.marquee.pro`（**逐字符**核对，错了就是取不到商品）
- [ ] 价格：**¥36**（中国区）；其它地区用自动换算或按需调整
- [ ] **家人共享：开**
- [ ] 「App 内购买项目」可用性：**已批准销售（Cleared for Sale）= 是**
- [ ] 本地化（**中英两套都要填**）：
  - 简体中文：显示名称 `Marquee Pro`
  - English (U.S.)：`Marquee Pro`
  - 描述用 `App/Products.storekit` 里那两句（`滚动截屏、识别文字、钉图，以及不限数量的最近截图。一次买断，永久可用。` / 英文对应句）

### 1.5 创建第二个商品：0 价试用

同样路径，再 `+` 一次：

- [ ] 类型：**非消耗型项目**
- [ ] 参考名称：`Marquee 7 天试用`
- [ ] 产品 ID：`com.tango.marquee.pro.trial`
- [ ] 价格：**价格等级 0**（0 价；这是 3.1.1 指定的做法）
- [ ] **家人共享：关**
- [ ] 已批准销售 = 是
- [ ] 本地化：
  - 简体中文显示名：`Marquee 7 天试用` —— **必须含"7 天"这三个字**（3.1.1 的命名约定 `XX 天试用`）
  - English (U.S.)：`Marquee 7-Day Trial`
  - 描述：`免费试用全部 Pro 能力 7 天。试用结束不会自动收费。`

⚠️ **0 价 ≠ 免费赠送功能**：它是"一次记录在案的事件"，我们的试用起点就是这笔交易的时间戳。做成**非消耗型**的关键收益是：**同一个 Apple ID 下它只能买一次**，于是"试用只能一次"由 Apple 记账，我们不用自己防重。

### 1.6 每个商品都要填「审核信息」

- [ ] 审核截图：**直接上传 `docs/review/` 里那两张**（已经做好，尺寸正好 1280 × 800）
- [ ] 审核备注（Review Notes）：**这段必须自己写，别留空**

| 商品 | 用哪张图 | 图上是 |
| --- | --- | --- |
| `…pro`（买断） | `docs/review/iap-review-pro.png` | 偏好设置 → 通用页底部那块 Pro 状态区，蓝框圈出购买入口 |
| `…pro.trial`（试用） | `docs/review/iap-review-trial.png` | 覆盖层里的升级卡片，绿框圈出「7 天免费试用」 |

**尺寸这件事要说清**：ASC 对审核截图有硬性尺寸，而且**各平台不同** ——
iOS 至少 640 × 920，**macOS 要 1280 × 800**。随手拍的窗口图（偏好页只有 440 × 430）
会被退回，而那个报错只说"尺寸不对"，不告诉你该多大。

那两张图由 app 自己的冒烟工具出（**不需要屏幕录制授权**，任何机器上都能重跑）：

```bash
CONFIGURATION=Release MARQUEE_DISABLE_COMPILER_SANDBOX=1 ./scripts/build.sh
open -a "$PWD/DerivedData/Build/Products/Release/Marquee.app" --args -marqueeSmokeReview
cp "$HOME/Library/Application Support/com.tango.marquee/reports/iap-review-"*.png docs/review/
```

⚠️ 用 **Release** 构建出图：图上页脚会写下 bundle id，开发版那个会写成 `.dev`。
⚠️ 图上的标注框是**按运行期算出来的矩形**画的（`proPanelFrameInContent` /
`ProCardLayout.Content.primary`），不是从源码里估的坐标 —— 布局一改，估的坐标会静静指到别处。
⚠️ 界面补上价格之后（见 §4），这两张图要**重出一遍**。

建议的备注内容（三个商品各写一条）：

```text
This is a one-time purchase that unlocks four features: scrolling capture,
text recognition, pinning, and unlimited recent captures.
入口：菜单栏图标 →「设置…」→ 通用页底部「升级到 Pro」。
无需登录、无账号；购买后立即解锁，不涉及订阅与续费。
```

试用商品那条**额外要解释"为什么要单独做一个 IAP"** —— 这是审核员真的会问的问题（Apple 开发者论坛 thread/132592 有实例）：

```text
按 Guideline 3.1.1 的最后一节，非订阅 app 用「价格等级 0 的非消耗型 IAP」
提供限期试用。试用期 7 天，结束后回到免费版（截图与标注仍然免费），
解锁完整功能需要一次性购买 com.tango.marquee.pro (¥36)。
试用期时长与结束后不可用的内容在 app 内的卡片上有明确说明。
```

### 1.7 与**首个版本**一起提交

- [ ] 首次提交时，在 app 版本的「App 内购买项目」区块**勾上这两个商品**
- [ ] 提交后状态应从"准备提交"变成"等待审核"

**为什么不能只提交 IAP**：内购项目在**第一次**必须与某个 app 版本一起送审（之后才可以单独提交新增商品）。只提交 IAP 会一直是"准备提交"。

### 1.8 建沙盒测试账号

- [ ] ASC →「用户和访问」→「沙盒」→ 测试员 → `+`
- [ ] 用一个**全新的邮箱**（不能是已注册过 Apple ID 的邮箱）
- [ ] 地区建议选**中国**（与 ¥36 一致）

**做完能验证什么**：正式 id 的 Release 构建里能真的走一遍购买（§2）。

### 1.9 价格与可用地区

- [ ] 「价格与销售范围」里确认 ¥36 在所有目标地区都有价格（ASC 会自动换算，但**要逐地区看一眼**）
- [ ] 确认没有把某个地区误设成"下架"

**⚠️ 别在代码里写死价格**：界面必须用 `Product.displayPrice`（StoreKit 给的**已本地化**文案）。
写死 `¥36` 的话，任何非中国区店面的用户都会看到错的货币 —— 而那种错只在别人的机器上出现。

---

## 2. 每一步做完能验证什么（照着查）

| 做完 | 怎么验 | 预期 |
| --- | --- | --- |
| §1.1–§1.3（协议 / App ID / app 记录） | 无本地手段 | 只能靠沙盒测出来（下一行） |
| §1.4–§1.6 商品建好 | `CONFIGURATION=Release ./scripts/build.sh` → 用沙盒账号登录 → `open -a …/Release/Marquee.app --args -marqueeEntitlement` | 报告里「商品价格」是**真实店面价格**（不是"取不到"） |
| 同上（要真的买一次） | `… --args -marqueeEntitlement purchase` | 「发起购买」是 `买成了`；报告落 `<数据根>/reports/entitlement-probe.txt` |
| §1.7 提交 | ASC 里两个商品的状态 | 「等待审核」；**不是**"准备提交" |
| §1.8 沙盒账号 | 在 **App Store 应用**里退出真实账号 → 用测试员那个邮箱登录（入口在 App Store 侧栏的「账户」；macOS 15 之后也可能在「系统设置 → App 账户 → 媒体与购买项目」） | 能登录（**别用你的真实 Apple ID**） |
| 全部 | 免费额度 | 免费版最近截图只留 5 张；买断后不设上限 |
| 全部 | 撤销那一路 | 在 ASC / 沙盒里模拟退款 → 状态变 `.revoked`，锁回来 |

**本地 `.storekit` 能验的（不用 ASC、不用网络）**：购买 / 取消 / 待批准 / 退款 / 移出家人共享 / 恢复 /
重复购买 —— 前提是**从 Xcode 运行**（见 §3 第 1 条）。

**⚠️ 只有真机能验的**：真实收据、`Transaction.updates` 送来的真实事件、真实价格与区域、真实 Apple ID。这三样验不过，就不算"内购做完了"。

---

## 3. 三个与 ASC 直接相关的坑（都实测踩过）

### 3.1 本地 StoreKit 配置**只由 Xcode 注入**

`project.yml` 里的 `storeKitConfiguration: App/Products.storekit` 写进的是 **scheme**。
它**只在从 Xcode 启动进程时生效** —— 用 `open` / 双击启动的构建拿不到它，
于是 `Product.products` 返回空 ⇒ 商品取不到 ⇒ 表现为"**点了升级到 Pro 没反应**"。

⇒ 本地测购买流程**必须从 Xcode 跑**（或者用 §2 那条 Release + 沙盒账号）。见 `PITFALLS` 181。

### 3.2 换 Apple ID + 重装，可以再拿一次试用

Apple 这条 0 价 IAP 的路径**已知**有这个性质（社区与开发者论坛都有记录）。
我们的设计**接受**它："一个 Apple ID 一次试用"是 Apple 的记账粒度；
要按设备/按人防重得上 DeviceCheck 或 CloudKit —— 那与"纯本地、无账号"的定位冲突。
**这是记档的取舍，不是缺陷。**

### 3.3 商品"取不到"的排障顺序

按命中率排（前三条都能在 1 分钟内查完）：

1. **bundle id 对不对**（TN3186 的第一条）：跑的是 Release 构建吗？是 `com.tango.marquee` 而不是 `.dev`？
2. **产品 ID 逐字符**：ASC 里那个字符串与 `StoreCatalog` 里的一致吗？
3. **付费应用协议生效了吗**（§1.1）
4. 商品是不是"已批准销售"、是否与版本一起提交过（§1.7）
5. 网络/沙盒账号：换个沙盒测试员试试

⚠️ **别把第 5 条当成默认嫌疑**。这条链路上"网络问题"是最容易被误判的一档 ——
界面文案现在会说清是哪一档（`.unavailable` 与"连不上"是两句不同的话）。

---

## 4. 提审前的代码缺口：**已补**（2026-10-04）

### 缺口：界面从来没显示过价格 → 已修

3.1.1 要求"试用开始前必须清楚指明……**用户为获得完整功能需要支付的后续费用**"，
而在此之前 `displayPrice()` 只有探针在用 —— 卡片渲染器里还明确写着"标题里不出现价格"。

现在价格出现在**两个点下去之前就能看见的地方**：

| 位置 | 文案 | 取不到价格时 |
| --- | --- | --- |
| 覆盖层的升级卡片（正文） | `试用 7 天 · 之后 ¥36 · 免费版仍可用` | 退回 `试用 7 天，结束后自动回到免费版` |
| 偏好页那颗按钮 | `升级到 Pro · ¥36` | 退回 `升级到 Pro` |

四条约束都守住了：

1. 用的是商店的 `displayPrice`，**没有写死 `¥36`** —— 每个店面的货币与格式都不同；
2. 都在**点下去之前**可见；
3. 取不到价格时**退化成少说一句**，不留空、**也不猜一个数**；
4. 文案宽度进了 `LocalizationScanTests` 那套断言（卡片内宽 268，中英一起量；
   最坏价格按 `US$12.99` 估，实测中文 228 pt / 英文 244 pt，都放得下）。

判据在 Core（`ProCard.bodyVariant(for:priceAvailable:)` + 新的一档 `.trialWithPrice`），
句子在视图 —— 沿用 PITFALLS 178 那条分工；而"哪一档说哪句"是可断言的。

### 那两张审核图要不要重出

`docs/review/` 里那两张**现在是退化句**（画它们的那台机器连不到商店，取不到价格）——
这如实反映了"取不到价格时"的样子。想要**带价格**的那一版，在一个能拿到价格的
环境里重跑一次即可（例如从 Xcode 运行 Dev 配置 —— scheme 里挂着 `Products.storekit`）：

```bash
open -a "$PWD/DerivedData/Build/Products/Dev/Marquee.app" --args -marqueeSmokeReview
cp "$HOME/Library/Application Support/com.tango.marquee.dev/reports/iap-review-"*.png docs/review/
```

⚠️ 上传给 ASC 的那两张建议**用 Release 构建**出（图上页脚会写 bundle id）。

### 顺带记下：三个"已经在做对"的地方，别改坏

- 恢复购买的按钮**永远可点**（Guideline 要求可恢复）；
- 买断型 ⇒ 状态机里**没有"过期"这一档**（订阅那套状态是多余状态，写进去就有人去处理它）；
- 撤销**可以被撤销**（退款撤回后交易上的撤销字段会消失，判定要跟着恢复 Pro）。

---

## 5. 可勾的总对照表

```text
[ ] 1.1 付费应用协议生效 + 银行 + 税务
[ ] 1.2 App ID com.tango.marquee（Explicit）已开启 In-App Purchase
[ ] 1.3 app 记录创建；app 本身免费
[ ] 1.4 IAP com.tango.marquee.pro：非消耗型 · ¥36 · 家人共享开 · 中英双语
[ ] 1.5 IAP com.tango.marquee.pro.trial：非消耗型 · 价格等级 0 · 显示名含「7 天」
[x] 1.6 两个商品的审核截图 —— `docs/review/iap-review-pro.png` / `-trial.png`（**已生成**）
[ ] 1.6b 两个商品的审核备注（试用那条要解释为什么单独建）
[ ] 1.7 与首个 app 版本一起提交
[ ] 1.8 沙盒测试员（新邮箱）
[ ] 1.9 逐地区核对价格
[ ] 2.0 Release + 沙盒账号跑一遍 -marqueeEntitlement purchase
[x] 4.0 补上「试用前告知后续费用」—— **已补**（卡片正文 + 偏好页按钮都带价格）
[ ] 4.1 想给审核图带上价格的话，在能连到商店的环境里重跑 -marqueeSmokeReview（见 §4）
```

---

## 6. 还没核实的（别当结论用）

- **0 价非消耗型 IAP 在 macOS 上的展示形态**：指南原文没有区分平台，但社区案例以 iOS 居多。
  真到提审前，用沙盒账号在 Mac App Store 里看一眼它长什么样（会不会出现在"App 内购买项目"列表里）。
- **ASC 侧栏在最近改版后的确切叫法**（"App 内购买项目" vs "Monetization → In-App Purchases"）。
  本文按中文界面写，英文界面按括号里的英文找。

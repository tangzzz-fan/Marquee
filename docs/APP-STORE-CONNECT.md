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
> | **商店文案**（名称 / 描述 / 关键词 / 隐私标签 / App 审核备注 / 沙盒怎么答） | **`docs/APP-STORE-LISTING.md`** |
> | **导出上架用的构建**（archive → .pkg → 预检） | **`scripts/package-mas.sh`** |
> | **本文档** | **ASC 上的按钮 + 提审前必须补的代码缺口 + app 商店截图怎么出** |
>
> 最后核对时间：**2026-10-08**。ASC 的界面改版很勤，措辞可能变，但**每一步的判据（"做完之后你能验证什么"）不会变** —— 卡住时对着那一列查。

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
| **`Apple Distribution` 证书**（上传那一步要） | Xcode → Settings → Accounts → Manage Certificates | 见 §6.4：没有它，`archive` 出来的包**带着开发签名**（`get-task-allow=true`），上传被拒 |

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

#### ⚠️ 创建时报「名称已被使用」/「SKU 已被使用」

这两个错**同时出现**时，最可能的解释**不是"有人抢了名字"**，而是**记录已经建好了**
（第一次提交其实成功了，页面又提交了一次）—— 名字与 SKU 是同一份记录的两个字段，
被同时占掉正好说明这一点。

**先去「我的 App」看一眼，别再点创建。**

| 你看到的 | 判断 | 怎么办 |
| --- | --- | --- |
| 列表里已有一条 Marquee，且**套装 ID = `com.tango.marquee`** | 就是它 | **直接用**，这一步已完成。接着做 §1.2（给这个 App ID 开内购能力）与 §1.4 / §1.5 |
| 已有一条 Marquee，但**套装 ID 不是它** | 是另一个 app 占用了名字与 SKU | 见下面那张表 |
| 列表里没有 | 缓存 / 看错账号 | 刷新重登再看，确认用的是同一个开发者账号 |

三个字段建完之后**可改性完全不同**（Apple《App 信息》原文，别记错）：

| 字段 | 建完之后还能改吗 |
| --- | --- |
| **名称** | ✅ 能。提交审核前随时可改；之后在**创建新版本**、或版本状态允许编辑时也能改 |
| **套装 ID（Bundle ID）** | ❌ **上传过构建之后**就不能改 |
| **SKU** | ❌ **加入账号后立刻锁死**（原文：「当您将该 App 添加至您的帐户后，便不能再更改 SKU」） |

⇒ 所以「腾出被占用的名字」很便宜（把那个 app 改个名即可），
**「腾出 SKU」很贵** —— 只有一条路：**删掉那条记录**
（ASC → 该 app →「App 信息」→ 拉到底 → 删除 App；仅限未上架 / 可移除状态）。

**SKU 一次定死**：只能含字母、数字、连字符、句号、下划线，且**不能以 `-` `.` `_` 开头**。
建议 `marquee-macos-2026`。别写 `test`、别带版本号 —— 它标识的是**这条产品记录**，
不是这次提交的构建。

**名称的备选**（确实腾不出来时）：`Marquee 截图` / `Marquee 截屏标注`（都 ≤ 30 字）。
⚠️ 名称与副标题里的词也算进 App Store 搜索，备选名因此顺带承担一点关键词职能 ——
但别为了塞词把名字搞成关键词堆。

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
open -a "$PWD/DerivedData/Build/Products/Release/Marquee.app" \
     --args -marqueeSmokeReview -marqueeSmokePrice "¥36.00"
cp "$HOME/Library/Application Support/com.tango.marquee/reports/iap-review-"*.png docs/review/
```

⚠️ 用 **Release** 构建出图：图上页脚会写下 bundle id，开发版那个会写成 `.dev`。
⚠️ 图上的标注框是**按运行期算出来的矩形**画的（`proPanelFrameInContent` /
`ProCardLayout.Content.primary`），不是从源码里估的坐标 —— 布局一改，估的坐标会静静指到别处。
⚠️ **`-marqueeSmokePrice` 的值要与 ASC 上那个店面价逐字一致**（`¥36.00`）。
它为什么存在、又为什么不是"编一个数"，见 §4。

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

### 那两张审核图：**已出带价格版**（2026-10-08）

之前 `docs/review/` 里是**退化句**版（画它们的机器取不到价格）。现在两张都是带价格的那一版：
按钮 `升级到 Pro · ¥36.00`、卡片 `试用 7 天 · 之后 ¥36.00 · 免费版仍可用`。
**试用那张尤其要紧** —— 图上那句 `之后 ¥36.00` 正是 3.1.1 要求的"开始前说清后续费用"，
审核员看的就是它。

**价格从哪来**（这段要说清，否则下次没人知道 `¥36.00` 是谁给的）：

| 路 | 通不通 |
| --- | --- |
| Xcode 运行 Dev 配置（scheme 里挂着 `Products.storekit`） | ✅ 通。但页脚会写 `.dev`，不适合交给审核 |
| 命令行 `open` / 直接 exec（Release 或 Dev） | ❌ **拿不到**。Xcode 是通过它自己的启动环境注入 `.storekit` 的，命令行没有；Dev 构建也带 hardened runtime（`flags=0x10000`）⇒ `DYLD_*` 会被直接剥掉，把 `DYLD_FRAMEWORK_PATH` 指向 Xcode 的 Developer 框架也无效 |
| 真商店 | ❌ 商品还没在 ASC 建好时答不出来 |

⇒ 给截图那条路留了一个**显式**注入口：`-marqueeSmokePrice "¥36.00"`。
它**只在真实取价答不出来时**才生效（`MarqueeAppDelegate.prepareScreenshotPrice` 先给真实取价 2.5 秒），
而且**只在截图路径**上用 —— 生产路径永远走 `start()` 那次真实取价
（`ProEntitlement.overridePriceForScreenshots`）。

⚠️ **两件事要同时成立**，否则图上仍是退化句：

1. 那条冒烟分支**必须是异步的**（`Task`）。原来是同步渲染，而取价是个 `Task` ——
   主线程那一轮不跑完就轮不到它，于是**即使商店能返回价格，图上也不会有**。
   这才是它一直没出现过的真正原因，不是"那台机器连不到商店"。
2. 注入口给的字符串要与 **ASC 上那个价逐字一致**（`¥36.00`）。它是给审核看的，
   写错等于告诉审核一个不存在的价格。

> 商品在 ASC 建好、且机器能连到商店之后，**不带** `-marqueeSmokePrice` 重跑一次，
> 图上的价格就是**商店自己答的**那一个 —— 那比注入口更可信。

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
[x] 1.6 两个商品的审核截图 —— `docs/review/iap-review-pro.png` / `-trial.png`（**已生成，带价格**）
[ ] 1.6b 两个商品的审核备注（试用那条要解释为什么单独建）
[ ] 1.7 与首个 app 版本一起提交
[ ] 1.8 沙盒测试员（新邮箱）
[ ] 1.9 逐地区核对价格
[ ] 2.0 Release + 沙盒账号跑一遍 -marqueeEntitlement purchase
[ ] 3.0 建第二张证书 Mac Installer Distribution + Xcode 里登录 Apple ID（见 §6.5）
[ ] 3.1 ./scripts/package-mas.sh —— 归档 + 导出 + 预检（2026-10-08：归档已通，导出等 3.0）
[ ] 3.2 商店文案：名称 / 描述 / 关键词 / 隐私标签 / App 审核备注（见 docs/APP-STORE-LISTING.md）
[ ] 3.3 隐私政策已发布，且**无痕窗口能打开**（正文与发布步骤见 docs/PRIVACY-POLICY.md）
[x] 3.4 ✅ **app 内已有隐私政策入口**（2026-10-08）—— Guideline 5.1.1(i) 要求
       "App Store Connect metadata field **and within the app**"。落点：**设置 → 通用页最后一行**
       （「隐私政策 · 查看」），点开走系统默认浏览器。
       链接唯一来源在 Core `ExternalLinks.privacyPolicyURLString`，有测试守着
       （https、非占位符、指向具体页）；**链接解析不出来时整行连同分隔线一起不显示**，
       绝不留死链。改动见 `PreferencesWindowController.makeGeneralPage`
[x] 4.0 补上「试用前告知后续费用」—— **已补**（卡片正文 + 偏好页按钮都带价格）
[x] 4.1 两张审核图**已出带价格版**（`-marqueeSmokePrice "¥36.00"`，见 §4）
```

---

## 6. 还没核实的（别当结论用）

- **0 价非消耗型 IAP 在 macOS 上的展示形态**：指南原文没有区分平台，但社区案例以 iOS 居多。
  真到提审前，用沙盒账号在 Mac App Store 里看一眼它长什么样（会不会出现在"App 内购买项目"列表里）。
- **ASC 侧栏在最近改版后的确切叫法**（"App 内购买项目" vs "Monetization → In-App Purchases"）。
  本文按中文界面写，英文界面按括号里的英文找。

### 6.4 上传那一步的一个硬卡点：包里不许有 `get-task-allow`

**2026-10-08 实测**：只装了 `Apple Development` 证书时，`CONFIGURATION=MAS ./scripts/build.sh`
出来的包**带着 `com.apple.security.get-task-allow = true`** —— 那是开发签名的标记，
App Store 上传会被直接拒。同一次实测里另外三项都是对的（bundle id `com.tango.marquee`、
沙盒三项 entitlement、hardened runtime `flags=0x10000`）。

⇒ 判据（一条命令）：

```bash
codesign -d --entitlements - --xml DerivedData/Build/Products/MAS/Marquee.app \
  | plutil -p - | grep get-task-allow
# 有输出 = 这一版**不能上传**
```

⚠️ **`build` 与 `archive` 在这一点上不一样**，别把上面那条结论套到归档产物上：
同一天的归档实测（`.build-mas/Marquee.xcarchive/…/Marquee.app`）**不带** `get-task-allow` ——
因为 `archive` 不注入调试用的基础 entitlement，而 `build` 会。
所以上传那条路真正要核的是**导出的那个包**，脚本预检第 3 步就是干这个的。

### 6.5 导出上架包：**两张证书 + 一把 API Key**（2026-10-08 实测）

整条链路在 `scripts/package-mas.sh`（归档 `MAS` 配置 → 导出 `app-store-connect` → 预检）。
实测把「已经通的」与「卡住的」分得很清楚：

| 阶段 | 结果 |
| --- | --- |
| 归档（`-configuration MAS`） | ✅ **`ARCHIVE SUCCEEDED`**。产物核过：身份 `com.tango.marquee`、三项沙盒 entitlement、hardened runtime `flags=0x10000`、无 `get-task-allow` |
| 导出 | ❌ 卡在「命令行拿不到账号」—— **环境性质，不是配置错误**。下面那条结论被实测推翻过一次，值得读完 |

三条报错分别是什么：

| 报错 | 实际含义 |
| --- | --- |
| `No "Mac Installer Distribution" signing certificate … was found` | **缺第二张证书**。`Apple Distribution` 签 app 本体；`Mac Installer Distribution` 签导出的 `.pkg` —— **是两张，不是一张** |
| `exportArchive No Accounts` | ⚠️ **不是"没登账号"。** `xcodebuild` 读不到 Xcode 里那个 Apple ID —— 凭证在钥匙串里只授权给 Xcode.app 自己。实测：Xcode 早已登录、团队也已选中（`IDEProvisioningTeamManagerLastSelectedTeamID = UKXWZ3FS84`），这条报错照旧 |
| `No profiles for 'com.tango.marquee' were found` | 上一条的连带结果。**登账号解决不了它** |

**这条把 `build` 与 `archive` 也区分开了**：`build.sh` 的 MAS 产物带 `get-task-allow`，
而归档产物**不带**（archive 不注入调试用的基础 entitlement）。

#### 导出那一步的两条出路（登账号不在其中）

| 路 | 怎么做 | 适合 |
| --- | --- | --- |
| **A. 走 Xcode 的 Organizer** | Xcode 左上角 scheme 选 **`Marquee MAS`** → Product → Archive → Organizer → Distribute App → App Store Connect → Upload | **首次提审最省事**。GUI 用得上账号，而且顺带把包传上去（省掉 Transporter 那一步） |
| **B. 给命令行一把 ASC API Key** | ASC → 用户和访问 → 集成 → App Store Connect API → 生成密钥（`.p8` **只能下载一次**，同时记下 Key ID 与 Issuer ID），然后 `ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=… ./scripts/package-mas.sh` | 想自动化 / 以后反复发版 |

⚠️ **走 A 之前先确认 scheme 选的是 `Marquee MAS`，不是 `Marquee`。**
两个 scheme 的仓库默认值不同（见 `project.yml`）：

| scheme | Run | Archive | 那是哪条路 |
| --- | --- | --- | --- |
| `Marquee` | Dev | **Release** | Developer ID（`scripts/package.sh`，打 DMG）—— **不带沙盒，不能上架** |
| `Marquee MAS` | MAS | **MAS** | App Store —— 带沙盒、正式 id |

选错了的表现是**归档成功、上传被拒**，而本地不会给任何提示。

#### 证书自检：⚠️ 两个坑，每个都会把"明明装好了"显示成"找不到"

```bash
security find-identity -v -p codesigning | grep "Apple Distribution"
security find-identity -v | grep -i installer | grep -vi "Developer ID"
```

1. **不能加 `-p codesigning`** —— installer 身份不属于 codesigning 策略，加了过滤永远查不到。
2. **同一样东西有两个名字**（2026-10-08 实测踩到）：证书的**类型名**在开发者后台 / Xcode 的
   `+` 菜单里是 `Mac Installer Distribution`，而钥匙串里打出来的是**身份名**
   `3rd Party Mac Developer Installer: zhenzhi Tang (UKXWZ3FS84)`。
   按类型名 grep 会一无所获，而那时最自然的反应是"再去装一遍" —— 装一张本来就装好的证书。
   ⇒ 所以上面第二条查的是 `installer` 这个**词根**，并排除 `Developer ID Installer`
   （那也是 installer，但属**站外分发**；拿它签 App Store 的 .pkg 会被拒，报 ITMS-90237）。
   `scripts/package-mas.sh` 的预检按同一套写法，并把命中的**身份名原样打出来**，
   免得下次还要靠猜。

⚠️ 归档**必须用 `MAS` 配置**。用 `Release` 归档出来的是 Developer ID 那条路、
**不带沙盒**，上传会被拒 —— 而它在本地一点错都不报。脚本把配置钉死了，预检再核一遍。

---

## 7. App 商店截图（与 §1.6 那两张**不是**一回事）

| | 给谁看 | 尺寸 |
| --- | --- | --- |
| §1.6 那两张（`-marqueeSmokeReview`） | **内购审核**：这两个商品在哪买、在哪开始试用 | 1280 × 800 |
| 本节这一套（`-marqueeSmokeAppShots`） | **app 本身**：它长什么样、能干什么 | **2880 × 1800** |

### 7.1 规格（已核 Apple 原文，2026-10-08）

- **尺寸：16:10，四档之一** —— `1280×800` / `1440×900` / `2560×1600` / **`2880×1800`**
- **张数：至少 1 张、最多 10 张**（每个本地化各一套）
- **格式：PNG / JPEG，RGB，不许有 alpha**
  —— Apple 截图规格页原话：*"Images can't include alpha channels or transparencies"*。
  ⚠️ 这条**两边都管**：app 截图与 IAP 审核截图用的是**同一份规格**
  （审核截图的要求是 "meets any of the screenshot specifications your app supports"）。
  所以出图的 `CGContext` 一律用 `noneSkipLast` 而不是 `premultipliedLast` ——
  带 alpha 的 PNG 在开发机上**看不出任何异常**（每个像素都不透明），只在上传那一刻被退。
- 出**最高那一档**：ASC 会自动向下缩放，反过来（小图被放大显示）只会糊

### 7.2 出图（离屏，**不需要屏幕录制授权**）

```bash
CONFIGURATION=Release MARQUEE_DISABLE_COMPILER_SANDBOX=1 ./scripts/build.sh
open -a "$PWD/DerivedData/Build/Products/Release/Marquee.app" --args -marqueeSmokeAppShots
# 产物：~/Library/Application Support/com.tango.marquee/reports/app-shots/<语言>/
```

⚠️ 用 **Release** 构建出图：页脚写 bundle id，开发版那个会写成 `.dev`。

**英文那一套**（ASC 按本地化分别要）—— 同一个开关加一句语言参数：

```bash
open -a "$PWD/DerivedData/Build/Products/Release/Marquee.app" \
     --args -marqueeSmokeAppShots -AppleLanguages "(en)"
# 落在 app-shots/en/
```

⚠️ 两套图的**窗口内容大半是图标**，光看图分不出哪套是哪套 —— 所以页脚里写了 UI 语言。

### 7.3 出不了的那一张：覆盖层

**覆盖层（选区 + 工具条 + 读数框）出不了**：它是逐屏全屏面板，背后是**实时桌面**，
而拿实时桌面要 ScreenCaptureKit = 屏幕录制授权；离屏渲染只能拍到"没有桌面的蒙层"。
所以这一张**只能真机拍**，而它正好也是产品最该展示的一张：

```bash
# ① 授权（一次就够；⚠️ 必须用 `open -a`，直接 exec 会让 TCC 把授权记在终端头上）
open -a "$PWD/DerivedData/Build/Products/Release/Marquee.app" --args -marqueeRequestPermission
# ② 真覆盖层 + 真拖一次选区 + 抓屏
open -a "$PWD/DerivedData/Build/Products/Release/Marquee.app" --args -marqueeSmokeOverlayShot
# 产物：~/Library/Application Support/com.tango.marquee/reports/overlay-shot.png（整屏）
```

⚠️ 跑完**什么都没发生**时先看同目录的 `reports/launch-arguments.txt`：
没有这个文件 = 参数压根没送到（`open --args` 在被沙箱包裹的 shell 里会静默丢参，PITFALLS 189）。
⚠️ 这张是**整屏**，桌面上的东西都在图里 —— 传 ASC 之前自己裁/挑一张干净的桌面。

### 7.4 这一套图里有什么、没有什么

出的是**真窗口的离屏渲染**，不是示意图；状态行/读数框里的数字都是**真算出来的**。两条边界要记住：

1. **工具条的玻璃质感看不见** —— 离屏一律回退到实色档（PITFALLS 187）。这不是缺陷，是这条路固有的边界。
2. **面板里没有我们没做的东西**：图上的每一项能力都在代码里（`-marqueeSmokeAppShots` 的出图清单在
   `App/Sources/AppShots.swift`）。**不许往图上放"计划中"的功能** —— 那是审核与差评的双重来源。

### 7.5 上传前复核（一条命令，两张硬性条件一起查）

尺寸与 alpha 这两样，在**被退之前看不出来**，所以上传前先跑一遍：

```bash
for f in docs/review/iap-review-*.png docs/review/app-shots/*/*.png; do
  printf "%-56s " "$f"
  sips -g pixelWidth -g pixelHeight -g hasAlpha -g space "$f" | tail -4 | tr -d '\n' | tr -s ' '
  echo
done
```

期望：`iap-review-*` = `1280 × 800`，`app-shots/*` = `2880 × 1800`，
**全部** `hasAlpha: no`、`space: RGB`。（2026-10-08 实测：12 张全过。）

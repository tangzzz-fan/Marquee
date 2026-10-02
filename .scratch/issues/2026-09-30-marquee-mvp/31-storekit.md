# 31 · StoreKit 2 接入

- **状态**：🟡 **进行中** —— 第一批（可脱机测的那半）已完成 2026-10-03，分支 `feat/iap`。
  第二批 = StoreKit 适配器 + `.storekit` 本地配置。
- **依赖**：`30`（已完成 —— `LicenseResolver` 已在 Core）
- **交付的可演示行为**：在 StoreKit 沙盒环境里**真买一次**，Pro 能力解锁；退出重开仍是 Pro；
  「恢复购买」能恢复；退款/撤销能降级。

---

## 1. 一票的目标与**边界**

做的是**取值**那一半：把 StoreKit 的真实世界翻译成 `EntitlementInputs`，
喂给已经写好、已经测过的 `LicenseResolver`。

**不做**：Pro 入口的锁标记 / 升级小卡片 / 「通用」页的 Pro 状态区 ——
那些属于**界面**，是 31 之后的一票（见 §5）。

## 2. 施工图

| 项 | 做法 | 为什么 |
| --- | --- | --- |
| 商品 | **非消耗型** IAP，id `dev.tango.Marquee.pro`。先建 `Products.storekit` 本地配置（开发期能在 Xcode 里买），再去 App Store Connect 建同一个 id | 本地配置让"还没有商店账号"时也能跑通整条链路 |
| 取商品 | `Product.products(for:)`；价格文案**必须**用 `displayPrice` | 写死价格＝本地化事故（每个区价格不同） |
| 购买 | `product.purchase()`；处理 `.success(verification)` / `.userCancelled` / `.pending` | **`.pending` 不是失败**（家长批准会 pending），当成失败会白报错 |
| 校验 | 只认 `verification == .verified`；`unverified` 一律当作**没有** | 未校验的交易可以被伪造 |
| 权益 | `Transaction.currentEntitlements` 逐条校验 | |
| 撤销 | `revocationDate != nil` → `.storeRevoked`。**要从 `Transaction.all` 捞**（`currentEntitlements` 不含已撤销的） | 见下面「三条事实」 |
| 外部变化 | **必须**监听 `Transaction.updates` | 退款、家人关共享、跨设备购买**都发生在 app 之外**；不监听就是"退款了还解锁着" |
| 离线 | 权益**本地缓存**，启动先读缓存 → 立刻 `isResolved = true`，后台再校验 | 不要"每次启动必须联网"：断网时付费用户会被锁在外面 |
| 恢复 | `AppStore.sync()` ↔ 界面里的「恢复购买」 | Guideline 要求可恢复 |
| 试用 | 0 价非消耗型 IAP（见 `docs/MAS-AND-MONETIZATION.md` §1.4），交易时间戳即起点 | 对账交给 Apple |
| 落点 | **接缝**：协议在 Core、StoreKit 实现在新模块 `MarqueeStore` | 与"Core 持协议、实现模块只给 OS 实现"这条既有架构一致 |

## 3. 状态机的接入方式（不改判定）

```swift
// Core：这是接缝
public protocol EntitlementSource: Sendable {
    func loadCached() -> EntitlementInputs        // 启动：读缓存，立刻放行
    func refresh() async -> EntitlementInputs     // 后台：问 StoreKit
    func updates() -> AsyncStream<EntitlementInputs>  // Transaction.updates
}

// 新模块：实现它。Core 与界面都不 import StoreKit。
public final class StoreKitEntitlementSource: EntitlementSource { … }
```

**判据**：搜索 `import StoreKit` 应当**只在 `Modules/Sources/MarqueeStore/` 里命中**。
一旦它在别处出现，"判定能脱机测"这件事就悄悄失效了。

## 4. 会踩的坑（提前记下，遇到后再补实测结论）

1. **`.pending` 不是失败**（家长批准 / 银行待确认）。
2. **启动顺序**：先读缓存并立刻 `isResolved = true`，**不要**等网络 ——
   等网络就等于"断网时付费用户被锁"。与 `unknown ⇒ 放行` 是同一个方向。
3. **`unverified` 必须忽略**，不能"宽容地当作通过"。
4. **`displayPrice` 不能写死**。
5. 沙盒账号与生产账号的**购买状态互相独立** —— 调试时容易把两者搞混。
6. **改试用天数 ＝ 换一个商品**：`TrialPolicy.durationDays` 改了，App Store Connect 里
   那个 0 价商品的命名（`7 天试用`）也得跟着换 —— 它不是改个常量那么简单。

## 5. 明确不在本票范围内（留给下一票）

- 菜单「滚动截屏」/ 工具栏「识别文字」「钉图」的**锁标记与非模态小卡片**
- 「通用」页底部的 **Pro 状态区**（含「恢复购买」）
- 最近截图的 **5 张上限**接到 `historyLimit`
- 界面文案（会新增若干 `L10n.t` key → 走 `Tools/L10nCatalog/` 重新生成 catalog）

## 6. 验证口径

- 单测：`StoreKitEntitlementSource` 的**映射**部分（把 `Transaction` 的字段映射成
  `EntitlementInputs`）—— 这层要能脱机测；真正的 `purchase()` 只能靠沙盒实测。
- 实测（需要你的账号）：买 → 解锁 → 退出重开 → 仍解锁 → 恢复购买 → 退款 → 降级。


---

## 第一批已完成（2026-10-03，分支 `feat/iap`）

这一票里**能脱机测的**那一半先做掉 —— 而它恰好是**错得最贵**的那一半：
判错"这个人有没有买"直接决定要不要给他上锁。

### 交付

| 文件 | 内容 |
| --- | --- |
| `MarqueeCore/Storefront.swift` | `StoreCatalog`（两个商品 id）· `PurchaseRecord`（一条交易里真正要用的四个字段）· `StorefrontSnapshot`（商店的事实）· `StorefrontMapper`（纯映射） |
| `MarqueeCore/EntitlementCache.swift` | `EntitlementCaching` 接缝 + 内存实现 + 落盘实现（`UserDefaults`，域随 bundle id，两版本各存各的） |
| `MarqueeCore/Entitlement.swift` | **`RevocationReason` 从三档改成两档**（见下） |
| 测试 | `StorefrontMapperTests`（13 条）+ `EntitlementCacheTests`（9 条），**22 条 / 6 个变异全红** |

### 为什么缓存的是**输入**而不是判定结果

判定规则还会改（这一票就改了一次 `RevocationReason`）。存结果的话，改规则就得指望
"用户下次联网时被刷新到"，而某些用户可能半年不联网。存**事实**（商店说了什么），
规则怎么改都能重算出来。

### ⚠️ 查证 StoreKit 之后改掉的两处

1. **`RevocationReason` 三档 → 两档。**
   StoreKit 2 的 `Transaction.revocationReason` **只有 `.developerIssue` / `.other`**；
   Apple 的 Server Notifications 文档更明确：
   「For Family Sharing transactions, the revocation reason value is **0** if the customer
   leaves the family group or the owner stops sharing.」
   ⇒ **退款与"被移出家人共享"在运行时区分不出来。** 原来那三档里有两档是**假装能分**，
   代价是给用户一句很确定、但可能是错的解释。现在：`.storeRevoked` / `.purchaseNotFound`。
2. **`currentEntitlements` 已经排除了已撤销的购买。**
   只看它会分不清"从来没有过"与"有过、后来被撤了"（话术完全不同）。
   要捞历史得用 `Transaction.all`。

### 三条硬规则（都有测试钉住）

1. **未校验的交易一律不算数** —— `unverified` 可以被伪造，不能"宽容地当作通过"。
2. **撤销可以被撤销**（Apple 原文：退款撤回后撤销字段被移除、访问要恢复）⇒
   **不许把"曾经被撤销"记成永久状态**；每次从商店的当前事实重算。
3. **「商店里没有」只有在真的问过之后才算证据** ——
   查询失败时 `records` 也是空的，照它判会把付过费的人在断网时锁在外面。
   所以映射函数的文档里把"只在真的问过商店之后调用"写成**硬前提**，
   失败路径直接用缓存里那份输入、根本不进映射。

### 第二批要做的

- `MarqueeStore` 模块 + StoreKit 适配器（`Product.products` / `purchase` / `Transaction.all` /
  `Transaction.updates`），实现 `EntitlementCaching` 之外的两条接缝（读取 / 购买 / 恢复）
- `Products.storekit` 本地配置（开发期测购买、取消、待批准、退款、家庭共享移除）
- 启动顺序：读缓存 → 立刻判定 → 后台核实（**不等网络**）
- ⚠️ `Transaction.updates` **必须在启动时就开始监听**，否则 app 关闭期间发生的退款会漏掉

---

## 第二批已完成（2026-10-03，分支 `feat/iap`）

接上 StoreKit，并把"启动顺序"这条时序规则钉住。这一批之后，**整条链路已经能在本地跑通**
（`-marqueeEntitlement purchase` —— 购买界面还没做，所以先给了自检入口）。

### 交付

| 文件 | 内容 |
| --- | --- |
| `MarqueeCore/StorefrontSeams.swift` | `StorefrontReading` / `ProductPurchasing` 两条接缝 + `PurchaseOutcome`（五档）+ `UnavailableStorefront`（兜底） |
| `MarqueeCore/EntitlementCoordinator.swift` | 启动编排：读缓存 → 立刻判定 → 后台核实；购买成功后本地合并、不再问商店 |
| `MarqueeStore/StoreKitStorefront.swift`（新模块） | StoreKit 2 适配器：`Transaction.all` / `Transaction.updates` / `purchase` / `AppStore.sync` |
| `App/Products.storekit` | 本地商店配置：¥36 非消耗型 + 0 价试用商品 |
| `App/Sources/ProEntitlement.swift` | App 里的装配点 + `-marqueeEntitlement` 自检入口 |
| 测试 | `EntitlementCoordinatorTests` 20 条 · `StoreCatalogConfigTests` 7 条，**共 27 条 / 16 个变异全红** |

### 三条规则（每条都有测试）

1. **启动不等网络。** `primeFromCache()` 同步出判定，核实放后台。
   测试用一个**能挂住的假 reader** 造出"商店还没回话"那一刻 —— 否则这条断言是空跑的。
2. **核实失败不改动判定。** 断网 ≠ 购买没了。变异验证：把失败改成"降级成免费" → **8 条变红**。
3. **只有真问过商店才写缓存。** 把"还没查"或"查询失败"写进去，下次开机读回来就成了
   "查过了、什么都没有"—— 一个伪装成事实的猜测。

另外两条设计决定：
- **购买成功后不再问商店**：`PurchaseOutcome.purchased` 直接带上那条交易，
  用它在本地重算。`Transaction.all` 有几百毫秒往返，而"刚点完购买界面没变"最容易
  被当成"没买上"（然后用户再点一次）。
- **`.pending` 什么都不做**：家人共享的"购买前询问"、银行验证都落这一档 ——
  当成失败会骗用户、当成成功会立刻解锁而家长可能马上拒绝。等 `Transaction.updates`。

### 适配器里的纪律：不许做判断

`fetchRecords()` 里未校验的交易**也如实记下来**（带 `isVerified: false`），不在这里丢掉。
在这里 `continue` 就等于把"未校验一律不算数"这条规则挪进一个只有真机才跑得到的地方。

### 自检入口

```bash
open -a Marquee.app --args -marqueeEntitlement            # 只查看
open -a Marquee.app --args -marqueeEntitlement purchase   # 真买一次（本地配置）
open -a Marquee.app --args -marqueeEntitlement trial      # 走 0 价试用商品
open -a Marquee.app --args -marqueeEntitlement restore    # 恢复购买
```

报告同时落在 `~/Library/Logs/Marquee/entitlement-probe.txt`。它打印：身份（开发版/正式版）、
权益判定、能否放行、**商店核对结果**（成功/失败/还没试）、能否开始试用、商品价格文案。

### 待人工确认（两件，我做不了）

1. **Xcode 里 scheme 的 StoreKit 配置是否选中了文件**：Run → Options → StoreKit Configuration
   下拉里应当选中 `Products.storekit`。XcodeGen 生成的相对路径是它自己的默认前缀
   （`../../App/Products.storekit`），而**它相对哪个目录在 Apple 文档里没明说、第三方说明互相矛盾**
   —— 我不猜，请打开看一眼（10 秒）。若下拉为空，改成 `../../../App/Products.storekit` 再生成。
2. **真机 / 沙盒**：`.storekit` 走的是本地模拟（不连 App Store）。
   真实沙盒交易要在**正式 id 的 Release 构建**上用沙盒测试账号验（`-marqueeEntitlement purchase`）。

### 下一批（31 的收尾）：界面

界面的行为规范已经在 `docs/MAS-AND-MONETIZATION.md` §1.2 写好，只剩落地：
- 三个 Pro 入口（菜单「滚动截屏」、工具栏「识别文字」「钉图」）加**小锁标记**；
- 点下去**不进流程**，原地弹**非模态**小卡片（说明 + 试用 + 了解 Pro），`Esc`/点别处可关，
  **关掉不许丢任何东西**（走和 `Esc` 收弹层同一条通道，不碰 `SelectionSession`）；
- 偏好「通用」页底部一块状态区（当前状态 + 购买/升级 + **恢复购买**），**不新增第 5 页**；
- 最近截图超 5 张时**不弹卡片**，只在面板底部一行小字 + FIFO 淘汰。

这一批要新增一个 `MarqueePro` 界面模块或放进 `MarqueeOverlay`，接线时需同步
`docs/STATUS-AND-ACCEPTANCE.md` §3 Z 组（那里已经列了要人工看的项目）。

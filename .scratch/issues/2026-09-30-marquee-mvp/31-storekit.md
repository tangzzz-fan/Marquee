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

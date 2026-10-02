# 30 · 权益状态机（Core，可脱机单测）

- **状态**：✅ 已完成（2026-10-02）
- **依赖**：无
- **交付**：`Modules/Sources/MarqueeCore/Entitlement.swift`
- **交付的边界**：**只有判定逻辑**。不含 StoreKit（ticket 31）、不含界面。

---

## 1. 为什么先做这一票（而不是直接接 StoreKit）

`LicenseResolver` 只吃 `EntitlementInputs`（一堆值），不读时钟、不碰网络、不碰磁盘。
于是"什么人看到什么"这套规则**在没有 App Store 连接、没有沙盒账号的机器上也能被钉住** ——
而 StoreKit 那条路只有在真账号 + 真环境里才测得到。

把**取值**（ticket 31）与**判定**（本票）分开，是这一票存在的全部理由。

## 2. 类型形状

```swift
public enum ProFeature: String, CaseIterable, Sendable {
    case scrollCapture, textRecognition, pin, unlimitedHistory

    /// 边界只在这里 —— 唯一的落点。`switch` 是穷尽的：
    /// 加了新能力却不做决定，编译就过不去。
    public var requiresPro: Bool { ... }
}

public enum Entitlement: Equatable, Sendable {
    case unknown                     // 还没查（启动瞬间）
    case free
    case trial(daysLeft: Int)
    case pro(purchasedAt: Date)      // 买断 ⇒ 永不过期
    case revoked(RevocationReason)
}

public enum BlockedReason: Equatable, Sendable {
    case neverPurchased, trialEnded, revoked(RevocationReason)
}

public struct EntitlementSnapshot: Equatable, Sendable {
    public let entitlement: Entitlement
    public let blockedReason: BlockedReason?   // 可用时为 nil
    public var access: ProAccess { ... }
    public func access(to feature: ProFeature) -> ProAccess
    public func historyLimit(free: Int) -> Int?    // nil = 无上限
}
```

### 三个刻意的设计选择

1. **`ProFeature` 只有标识、没有文案。** 名字给代码读，标题给用户看。
   中文标题写进 Core 会被本地化扫描拦下 —— 而更根本的理由是：
   **边界会调、文案会改，两件事不该互相牵着。**
2. **只有四项，且都是现存能力。** "批量 / 水印 / 模板 / JPEG 质量"一律不进来 ——
   把一个不存在的功能写成"锁着的"，界面上就会出现一个**点了什么都不会发生的入口**。
3. **买断制 ⇒ 没有"过期"这一档。** 订阅那套 `expiresAt` / `inGrace` 在这里是多出来的状态，
   而不存在的状态一旦写进枚举，就会有人去处理它、并写出永远走不到的分支。

## 3. 判定的顺序就是它的语义

```
0. 还没查（isResolved == false） → .unknown，**放行**
1. 撤销                          → .revoked（撤销比"有购买"更晚发生，也更权威）
2. 有购买                        → .pro，永不过期
3. 试用进行中                    → .trial(daysLeft:)
4. 其它                          → .free
```

### ⚠️ 头号判据：「未知」不能当成「免费」

启动瞬间就判权限，会让付过费的人**先看到一个锁**，几十毫秒后才解锁。
"我买过啊"是最伤人的一类 bug，而它看起来只是"启动闪了一下"。

所以 `unknown` 期间**放行**（乐观），校验失败再降级 ——
方向是"**宁可少收一次，不可错拦一次**"。

这一条在 `historyLimit` 上更狠：`unknown` 时若按免费版裁剪，
那就是**启动时删掉付费用户的历史** —— 整套设计里唯一会真正丢数据的操作。

## 4. 被测试钉住的规则（18 条）

| 组 | 判据 |
| --- | --- |
| 还没查 | `unknown` + 放行 + 无阻断原因 |
| 查过但空 | `free` + `.neverPurchased` |
| 买断 | 一年后、十年后都还是 `pro`（**永不过期**）；拿不到购买时间用"现在"兜底 |
| 撤销 | 优先于"有购买"；`rawValue` 不撞、`blockedReason` 可区分。⚠️ **2026-10-03 修正**：`RevocationReason` 从三档改成两档（`.storeRevoked` / `.purchaseNotFound`）—— StoreKit 的 `revocationReason` 只有 `.developerIssue` / `.other`，退款与"被移出家人共享"落在同一档，原来那三档里有两档是假装能分。详见 ticket 31 |
| 试用 | 第 1 天报 7 天；第 6 天报 1 天；**剩 0.2 天也报 1 天**（不是 0）；满 7 天整才结束 |
| 时钟 | 系统时间被往回拨时，天数夹到 7 —— 不许出现"还有 9 天" |
| 一天的定义 | 固定 86400 秒。用自然日会让 23:59 开始试用的人两分钟后少一天 |
| 试用一次 | `canStartTrial` 三条（用过 / 已买 / 被撤销都不行） |
| 额度 | 免费 5 张、Pro 与 `unknown` 都不设限；**参数写 0 会被夹到 1**（"保留最近 0 张"＝删光历史） |
| 单一来源 | `access(to:)` 与 `allowsProFeatures` 同源；四项能力逐条验 |

## 5. 变异验证（5 次）

| 变异 | 结果 |
| --- | --- |
| 去掉"还没查就放行" | ✘ 12 条变红 ✔ |
| 去掉天数上限夹取（时间倒拨报 12 天） | ✘ 3 条 ✔ |
| 把 `ceil` 换成截断（最后一天报 0 天） | ✘ 7 条 ✔ |
| 试用期当成被挡住 | ✘ 5 条 ✔ |
| 「一天」算成 86000 秒 | ✘ 3 条 ✔ |
| **去掉天数下限夹取** | **✘ 0 条 —— 没变红** |

最后一次没变红，查出来**不是断言盲，是我写了死代码**：
`raw = Int(ceil(rem / 86400))` 且调用点保证 `rem > 0` ⇒ `ceil` 对任何正数都 ≥ 1
⇒ `max(1, raw)` 永远不生效。**已删除**，连同那段说它很重要的注释。

> 教训进 `docs/PITFALLS.md` 117：**变异不变红有两种可能 —— 断言是盲的，或者那段代码是死的。**
> 前者的处理是补用例，后者是删代码，两者完全相反。
> 而"死代码 + 一段说它很重要的注释"比没有更糟：下一个人会照注释去维护它。

## 6. 下一票（31）从哪儿接

`LicenseResolver` 只吃 `EntitlementInputs`。ticket 31 要做的事就是**填满这个结构**：

| 字段 | 从哪儿来 |
| --- | --- |
| `isResolved` | StoreKit 是否已回话（启动先读本地缓存 → `isResolved = true`，然后后台校验） |
| `hasPurchase` / `purchasedAt` | `Transaction.currentEntitlements` 里**校验通过**的那一条 |
| `revocation` | `Transaction.revocationDate != nil` / 缓存里"曾经是 pro、现在没了" |
| `trialStartedAt` / `hasUsedTrial` | 那个 0 价非消耗型 IAP 的交易时间戳 |

## 7. 验证

`./scripts/test.sh` → 509 全绿（其中本票 18 条）；`swift build --disable-sandbox` 全过。

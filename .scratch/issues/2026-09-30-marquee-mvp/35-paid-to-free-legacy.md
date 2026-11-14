# 35 · 付费 app 转免费 + 内购：老付费用户的权益保留

- **状态**：🟡 进行中 —— 分支 `feat/paid-to-free-legacy`（2026-11-14 开工）
- **依赖**：`30`（判定）· `31`（StoreKit 接入）—— 均已完成
- **交付的可演示行为**：
  1. 商店页显示 **「获取」**（app 本体 ¥0），app 内仍能买 Pro（唯一一笔 ¥36）；
  2. **2026-10-27 ~ 转免费之间花 ¥36 买过 app 的人，升级到新版后四项 Pro 能力全部可用**，
     且界面上是「已购买」，不会再被要求付第二次；
  3. 断网 / 沙盒 / 收据取不到时，上面两条都不许退化成"锁住"。

---

## 1. 根因（现场证据，不是台账里的旧结论）

`itunes.apple.com/lookup?bundleId=com.tango.marquee` + 商店页 HTML（2026-11-14 查）：

| 字段 | 实际值 |
| --- | --- |
| 上架 | 已上架 **1.1.0**（首发 2026-10-27，当前版本 2026-11-04） |
| app 本体价格 | **¥36.00** / 美区 **$4.99** |
| 页面按钮 | `titles: "¥36.00"` · `subtitles: "App 内购买"` · `isFree: false` |
| 「App 内购买」区块 | Marquee 7 天试用 ¥0.00 · Marquee Pro ¥36.00 |

⇒ **IAP 早就上线且在架上卖**。问题不是"内购没做"，而是 **app 本体也被设成了收费** ——
`docs/APP-STORE-CONNECT.md` §1.3 那句「app 本身必须免费」在 ASC 上没被执行。
用户现在要先付 ¥36 下载，装完发现滚动截屏带锁，再被要求付 ¥36。

**IAP 那条链路一行都不用改。** 要动的只有 ASC 的价格档 + 本票的老用户识别。

## 2. 只改价格会造成一次事故 —— 这才是本票的主体

顺着代码走过一遍（不是推测）：

1. `StoreKitStorefront.fetchRecords()` 只读 `Transaction.all` —— **只有 IAP 交易，不含 app 本体的购买**；
2. 老付费用户没有 IAP 交易 ⇒ `records` 为空；
3. `StorefrontMapper.inputs(from:)` → `hasPurchase = false`；
4. `LicenseResolver.resolve` 落最后一档 → `.free` + `.neverPurchased`；
5. 四个 Pro 入口全部上锁，界面还对他说「升级到 Pro · ¥36」——**让他为同一个东西付第二次钱**。

`cachedHadPurchase` 也救不了：那批用户本机缓存里存的本来就是 `hasPurchase = false`。

全仓 `grep AppTransaction|originalAppVersion` → **0 命中**。这正是 Apple 为此场景准备的机制。

## 3. 依据（已核 Apple 原文，两处）

《Supporting business model changes by using the app transaction》给的三步：
① 代码里写一个"商业模式变更版本"常量；② 拿 `originalAppVersion` 与它比；
③ **同时**还要走 `currentEntitlements` 交付 IAP —— 即 legacy 与 IAP 是**两条并存的路**。

`originalAppVersion` 文档原文两条关键：

> The string value contains the original value of the **`CFBundleShortVersionString`** for apps
> running in macOS, and the original value of the `CFBundleVersion` for apps running on all other platforms.
>
> In the **sandbox** testing environment, the `originalAppVersion` value is **always `1.0`**.

⇒ macOS 上比的是**营销版本号**（`1.1`），且**沙盒里恒为 `1.0`** ⇒ 这条路**能在沙盒里验**。

⚠️ Apple 的 macOS 样例用的是 `originalMajorVersion < "2"` —— **字符串比较**。
`"10" < "2"` 为真 ⇒ 到 10.x 时会把新用户误判成老用户。**不抄这一句**，见 §5。

## 4. 分界常量：`BusinessModelChange.appVersion = "2.0"`

- 转免费那一版发 **2.0.0**（1.0 轨道已关闭、1.1 已上架）；
- 老用户 `originalAppVersion` ∈ {`1.0`, `1.1`} < `2.0` ⇒ 永久 Pro；
- 沙盒恒 `1.0` ⇒ 沙盒账号一律被判成老用户（**这是预期，不是 bug**，写进验收说明）。

## 5. 判定顺序 —— 本票唯一的核心决策

```
0. 还没查                          → .unknown（放行）
1. legacy 付费购买                 → .pro(purchasedAt: 原始购买日)   ← 新增，在撤销之前
2. 撤销                            → .revoked
3. IAP 有效购买                    → .pro
4. 试用进行中                      → .trial
5. 其它                            → .free
```

### 5.1 为什么 legacy 必须压过撤销（而不是塞进 `hasPurchase`）

第一版想法是"把 legacy 认成 `hasPurchase = true`"，**已推翻**。因为
`StorefrontMapper` 里有这条：

```swift
} else if pro.isEmpty, snapshot.cachedHadPurchase {
    revocation = .purchaseNotFound
}
```

legacy 用户被认成"有购买"后 `knownHadPurchase` 变 true，而商店确实没有 IAP 交易
⇒ 下一轮核实直接判成 `.revoked(.purchaseNotFound)`，**比不认还糟**。

更根本的理由：**app 本体的退款与 IAP 的退款是两笔不同的交易**。
用户退了 Pro 的 IAP，不该丢掉他当初买 app 得来的权益。所以 legacy 与 revocation
**在语义上互不相干**，把 legacy 放在撤销之前不是"网开一面"，而是正确。

### 5.2 为什么用**日期**而不是 `Bool`

`legacyPaidPurchaseAt: Date?` 而非 `isLegacyPaidUser: Bool`：

- `.pro(purchasedAt:)` 需要一个日期，界面会显示它。用 `now` 兜底会让老用户看到
  「今天购买」——**一句可验证的假话**；
- 「是不是老用户」由分界常量算，属于**判定**，必须在 Core（`AppPurchaseMapper`），
  不能让适配器返回一个已经判好的布尔（PITFALLS 130）；
- 缓存存**事实**（原始购买日）而不是结论，规则改了还能重算（`EntitlementCache` 的既定原则）。

### 5.3 legacy 用户不能开始试用

`canStartTrial` 要加一条 `legacyPaidPurchaseAt == nil`。
不加的话卡片会给一个已经付过钱的人显示「7 天免费试用」——他点下去买了一个自己已有的东西。

## 6. 「取不到 app transaction」怎么办 —— 三态，不是两态

这是本票第二个容易做错的地方。`AppTransaction.shared` 在**非商店构建**（Dev / Developer ID）
里会失败；首次取还可能弹一次 Apple ID 登录。所以必须分得清：

| 情况 | 语义 | 做法 |
| --- | --- | --- |
| 取到了、版本 < 2.0 | 确认是老用户 | `legacyPaidPurchaseAt = 日期` |
| 取到了、版本 ≥ 2.0 | **确认不是**老用户 | `legacyPaidPurchaseAt = nil` |
| **取不到**（throw / unverified） | **不知道** | **保留上一次已知的值**，绝不当成"不是" |

第三行是本票的 PITFALLS 126 同型陷阱：**"没有证据"不等于"证据说没有"**。
若把失败当成 `nil` 并写进缓存，一个老用户在断网那次启动之后就会被永久降级。

⇒ `EntitlementCoordinator` 持 `knownLegacyPaidPurchaseAt`，只在**真的取到**时更新它；
取不到就沿用（首次即 `nil`，此时判定仍由 IAP 那条路决定，与今天的行为一致）。

⚠️ **app transaction 失败不许拖累 IAP 那条路**：两者独立取值，
`fetchRecords` 成功 + app transaction 失败 ⇒ 仍按 IAP 事实判定（`verification` 记成功）。

## 7. 施工图

| 落点 | 改动 |
| --- | --- |
| `Core/AppPurchase.swift`（新） | `AppPurchaseRecord`（原始版本 / 购买日 / 当前版本 / bundleID / isVerified）· `AppVersion`（数值化比较）· `BusinessModelChange`（分界常量）· `AppPurchaseMapper`（纯函数判定） |
| `Core/StorefrontSeams.swift` | 新接缝 `AppPurchaseReading.fetchAppPurchase() async throws -> AppPurchaseRecord`；`UnavailableStorefront` 实现为 throw |
| `Core/Entitlement.swift` | `EntitlementInputs` 加 `legacyPaidPurchaseAt: Date?`；`resolve` 在 `isResolved` 之后、`revocation` 之前短路；`canStartTrial` 加一条 |
| `Core/EntitlementCache.swift` | `Stored` 加**可选**字段 —— 旧缓存必须仍能解码（否则老用户缓存整体失效） |
| `Core/EntitlementCoordinator.swift` | 注入 `appPurchaseReader`（默认 `UnavailableStorefront()`，保持既有构造点可用）· `knownLegacyPaidPurchaseAt` · 并行取值 · 失败保留 |
| `MarqueeStore/StoreKitStorefront.swift` | 实现 `AppPurchaseReading`：`AppTransaction.shared`，**unverified 也如实记下来标 false**（PITFALLS 130），不做任何判断 |
| `App/ProEntitlement.swift` | 装配 reader；探针输出加一行 app transaction 事实 |
| `project.yml` | `MARKETING_VERSION` `1.1` → `2.0`；`CURRENT_PROJECT_VERSION` 递增 |

**判据不变**：`import StoreKit` 只许出现在 `Modules/Sources/MarqueeStore/`。

### 7.1 `AppVersion` 为什么要自己写

`CFBundleShortVersionString` 是 `1.1` / `2.0.0` / 可能 `1.1.3` 这种形状。
Apple 样例的字符串比较在 `"10"` 上就错。做法：按 `.` 切段、逐段转 `Int`、缺位补 0、
**非数字段一律当成"读不懂"** ⇒ 返回 `nil` ⇒ **不认作老用户**（保守方向：宁可让他走 IAP，
也不要把一个解析失败的字符串当成付费凭证）。

⚠️ 但"读不懂"与"确认不是老用户"在**缓存**上是同一档（都写 `nil`），
这与 §6 第三行不冲突：那是**取到了但内容读不懂**，不是**没取到**。

## 8. 发布顺序（顺序错了就白做）

价格改动**不需要重新提审、即时生效**。所以：

1. 代码落地 + 测试全绿 → 版本号抬到 **2.0.0**；
2. ASC 版本设为**手动发布**；
3. 审核备注写明「本次由付费 app 转为免费 + 内购，老付费用户通过 AppTransaction 保留全部权益」；
4. 提审 → **通过**；
5. **先把 app 价格改成免费**；
6. **再点发布 2.0.0**。

反过来会出现一个窗口：新用户免费下载到 2.0.0，而价格还没生效时下载的人被收了 ¥36
却拿到免费版界面。

## 9. 验收

**可脱机验（本票必须全绿）**
- [ ] 版本比较：`1.0`/`1.1`/`1.9.9` < `2.0`；`2.0`/`2.0.0`/`2.1`/`10.0` ≥ `2.0`；`""`/`abc`/`1.x` → 读不懂
- [ ] **头号断言**：legacy 压过 `.purchaseNotFound` **与** `.storeRevoked`
- [ ] legacy 用户的 `purchasedAt` 是**原始购买日**，不是 `now`
- [ ] legacy 用户 `canStartTrial == false`
- [ ] 旧格式缓存（没有新字段）仍能解码，且**先断言 `load() != nil`**（PITFALLS 128）
- [ ] app transaction 取不到 ⇒ **保留**已知 legacy；且不影响 IAP 那条路的判定
- [ ] 未校验的 app transaction ⇒ 不认作 legacy（规则在 Core）
- [ ] `unknown` 仍放行；启动仍不等网络（闸门装置，PITFALLS 132）

**必须人工/沙盒验（代码测不到）**
- [ ] 沙盒账号（`originalAppVersion` 恒 `1.0`）⇒ 判成 legacy ⇒ Pro 解锁
- [ ] ASC 价格改免费后，商店页按钮变「获取」，「App 内购买」区块仍在
- [ ] 真实老付费账号升级后不被要求二次付费

## 10. 不做什么

- 不改 IAP 商品、价格、试用规则；
- 不动四个 Pro 能力的边界；
- 不做"把 Pro 对所有人免费"（那与目标相反）；
- 不维持付费 app 撤掉内购（同样不满足"app 内购买"）。
# 开发版与正式版的区分（spec）

> 状态：**待选机制**（2026-10-02）。本文只做勘查与方案，**代码未动**。
> 起因：ticket 31（StoreKit）与 32（沙盒化）都要先回答一个问题 ——
> **「我本地跑的这个 app，是哪一个 app？」**

---

## 0. 结论先说

1. 现状：**没有区分，也没有文档。** 本地构建出来的 app 与将来上架的 app
   **是同一个身份**（同 bundle id、同签名 team、同 Release 配置）。
2. 直觉上最干净的解法（给开发版换一个 `…​.dev` 的 bundle id）**与内购测试直接冲突**：
   IAP 商品挂 bundle id，换了 id 就 `Product.products(for:)` 返回空（依据见 §3）。
3. **推荐路线 A**：**bundle id 不变**，改为隔离**数据**与加一个**可见的开发版标记**；
   购买流程用 `.storekit` 本地配置测。细节见 §4。

---

## 1. 现状（有据可查）

| 维度 | 现状 | 依据 |
| --- | --- | --- |
| bundle id | **只有一个** `dev.tango.Marquee` | `project.yml:104` |
| 编译期开关 | **`#if DEBUG` 全仓 0 处** | 全仓 grep |
| 构建配置 | XcodeGen 默认的 `Debug` / `Release`，**没有自定义配置** | `project.yml` |
| 本地 Run 的配置 | **`Release`**（为了性能预算只在优化构建下才有意义） | `project.yml` 的 scheme |
| 签名 | `Apple Development` + team `UKXWZ3FS84` | `project.yml` |
| 最近截图仓库 | `~/Library/Application Support/Marquee/history/`（**硬编码 `Marquee`**，不看 bundle id） | `CaptureHistoryStore.defaultDirectory` |
| 默认保存位置 | `~/Desktop` | `OutputSettings.desktopDirectory()` |
| 偏好 | `UserDefaults.standard`（域 = bundle id） | `UserDefaultsPreferencesStore` |
| 调试开关 | 三个，都走 `UserDefaults`：`chrome.forceHUD` / `chrome.tint` / `overlay.traceFrames` | 各模块 |
| 相关文档 | `DEV-NOTES.md`（开发摩擦）、`RELEASE.md`（打包公证）。**没有一篇讲开发版与正式版的区分** | `docs/` |

> 注意最后一行与倒数第三行的关系：**调试开关住在 `UserDefaults` 里，而 `UserDefaults`
> 是按 bundle id 存的** —— 也就是说，开发时敲的 `defaults write dev.tango.Marquee chrome.forceHUD`
> **会留在正式版的偏好里**，除非记得删。

## 2. 三类真实风险（不是"理论上的不干净"）

1. **数据污染。** 开发时随手截的图会进**同一个** `~/Library/Application Support/Marquee/history/`。
   调试一次"删除历史"的逻辑，删掉的是真实历史。
2. **偏好污染。** 见上 —— 调试开关会跟着 bundle id 留在正式版里。
   而这类开关的表现恰好是"外观/行为不对"，很难第一时间联想到"是我上周敲的那条 defaults"。
3. **授权与交易的状态混淆。**
   - TCC 的屏幕录制授权按「bundle id + 代码签名身份」记账 ⇒ 开发构建与正式版**共用一条授权**。
     好处是开发时不用重复授权；坏处是**在开发中误撤销授权，正式版也一起没了**。
   - ticket 31 之后：**沙盒交易与本地测试交易会落在同一份权益状态里**。
   - ticket 32 之后：沙盒构建的数据路径还会再变一次（`Application Support` → 容器内），
     那时"我这个构建的数据到底在哪"会更难回答。

## 3. 一条硬约束：IAP 商品挂 bundle id

Apple 的 TN3186（*Troubleshooting In-App Purchases availability in the sandbox*）
在"商品取不到"的原因清单里第一条就是：

> **Your bundle ID doesn't match the bundle ID of an app in App Store Connect.**

并明确：沙盒里测内购**必须**用「在 App Store Connect 注册、且为它开启了 In-App Purchase
能力的 bundle id」。第三方总结更直接：**IAP 商品永久绑定在创建时的那个 bundle id 上，
换 id 之后老商品成为孤儿，且无法转移。**

于是两条推论：

- **换 bundle id 的代价 ≠ 零**：开发版会**永远测不到真实沙盒交易**
  （只能靠本地 `.storekit` 配置测流程）。而"真实沙盒购买"这件事
  （收据、`Transaction.updates`、退款回调、家庭共享）恰恰是**最需要早发现问题的部分**。
- **正式沙盒测试必须用同一个 bundle id + 沙盒测试账号**（App Store Connect →
  用户和访问 → 沙盒测试员）。这是 Apple 给的正路，不是"凑合"。

另有一条与发版有关：**误把开发构建提交上去，会取不到商品**（商品挂在生产 bundle id 下）。

### 开发期怎么测购买流程

Apple 给的正路是 **StoreKit Configuration File（`.storekit`）**：

| 能测 | 说明 |
| --- | --- |
| 购买 / 取消 / 待批准（Ask to Buy） | 不用网络，不用 App Store Connect |
| **退款 / 撤销** | 可以手动"模拟交易失败/退款"，正好覆盖我们的 `RevocationReason` |
| 家庭共享被移除 | 同上 |
| 重复购买 | 非消耗型必须"已购买再买一次"不重复扣款 |
| 恢复购买 | |
| 订阅类（将来） | 沙盒里一个月 = 5 分钟 |

⚠️ 两条操作纪律：**用 `.storekit` 本地配置时，必须关掉 Xcode 的 StoreKit Testing 才能测沙盒**
（两者互斥，TN3186 里也点了这一句）；`.storekit` **不入库生产依赖**，它只是开发期工具。

## 4. 三条路线

| | A（推荐） **bundle id 不变 + 隔离数据 + 开发版标记** | B **开发版换 bundle id** | C **只写文档立纪律** |
| --- | --- | --- | --- |
| 数据（历史 / 输出） | ✅ 隔离（`Marquee-dev/`） | ✅ 隔离（同 id 一起变） | ❌ 共用 |
| 偏好 / 调试开关 | ✅ 隔离（域随 id 不变，但可加前缀… 见下） | ✅ 隔离 | ❌ 共用 |
| TCC 授权 | ⚠️ 共用（**这是可接受的**，开发时本来就需要它） | ✅ 隔离 | ❌ 共用 |
| **真实沙盒内购测试** | ✅ **可以** | ❌ **不行** | ✅ 可以 |
| 改动量 | 中（加一个构建配置 + 一处数据根目录） | 小 | 极小 |
| 误发版风险 | 中（靠脚本前置检查兜） | 低 | 高 |

> ⚠️ 路线 A 里"偏好隔离"需要说明：`UserDefaults.standard` 的域跟着 bundle id 走，
> 而 A 不改 bundle id ⇒ **偏好本身不会自动隔离**。所以 A 要用
> **一套自定的 suite 名**（按配置加 `-dev` 后缀）来隔离，而不是靠系统默认域。
> 这一条是 A 里最容易做漏的地方 —— 漏了它，调试开关照样会污染正式版。

**为什么不选 B**：它看起来最干净，但代价是**放弃了"真实沙盒交易"这条测试路径**，
而那条路径正是 ticket 31 最需要验证的东西。为了"数据更干净"而牺牲"支付能测"，方向反了。

## 5. 推荐方案 A 的具体做法

**三个构建配置，各司其职：**

| 配置 | 用途 | bundle id | 数据根 | 优化 |
| --- | --- | --- | --- | --- |
| `Debug` | 只用于跑测试 | 生产 id | 测试临时目录 | 不优化 |
| `Dev` | **本地运行（scheme 的 Run）** | 生产 id | `Marquee-dev/` | **照抄 `Release`** |
| `Release` | **发版 / 打包** | 生产 id | `Marquee/` | 优化 |

- scheme 的 Run 从现在的 `Release` 改指 `Dev`。`Dev` 必须复制 `Release` 的优化设置，
  否则"性能预算"那些数字在两个构建之间不可比（而 Run 走 Release 本来就是为了这个）。
- 用编译期条件 `MARQUEE_DEV`（`SWIFT_ACTIVE_COMPILATION_CONDITIONS`）来切：
  1. 数据根目录（`CaptureHistoryStore` 与输出目录的默认值都从**一处**取）；
  2. 偏好用的 suite 名；
  3. **菜单栏标题后缀**（例：`Marquee · 开发版`）—— 让"我现在跑的是哪一个"一眼可答。
     这一条是这套方案里最便宜、也最有用的部分。
- 数据根目录**只允许有一个来源**（Core 里的一个 `AppPaths` 之类）：
  现在 `CaptureHistoryStore` 里硬编码了 `"Marquee"`，输出目录另有一处默认值 ——
  两处分开写，将来沙盒化（ticket 32）必然只改一处、漏掉另一处。

**硬规则（写进脚本与文档）：**

- `Debug` 与 `Dev` **都不许用来发版**；`scripts/package.sh` 的前置检查里加一条
  "scheme/配置必须是 `Release`，且 bundle id 是生产 id"（`package.sh` 已经有"签名核验不过就停"
  这类前置检查，加这一条在同一位置）。
- 调试开关的用法改成"用完就删"，并且**在 `Dev` 里才生效**（`Release` 下忽略调试开关）——
  这样就算忘了删，也不会影响正式版。

## 6. 落地清单（若选 A）

- [ ] `project.yml`：顶层 `configs:` 加 `Dev`（type = release）；target 的
      `settings.configs.Dev` 复制 `Release` 的优化设置 + `MARQUEE_DEV` 条件
- [ ] scheme：`run.config` 从 `Release` 改成 `Dev`
- [ ] Core：新增**唯一一处**数据根目录解析（`AppPaths`），`CaptureHistoryStore`
      与输出目录默认值都改从它取
- [ ] 偏好：`UserDefaultsPreferencesStore` 的 suite 名按配置切
- [ ] 调试开关在 `Release` 下忽略（`chrome.*` / `overlay.traceFrames`）
- [ ] 菜单栏标题加"· 开发版"后缀（仅 `Dev`）
- [ ] `scripts/package.sh` 前置检查：配置必须是 `Release`、bundle id 必须是生产 id
- [ ] `README.md` 与本文同步

## 7. 与现有 ticket 的关系

- **ticket 31（StoreKit）**：本票是它的前置。没有本票，"我这次买的是沙盒的还是本地的"会一直说不清。
- **ticket 32（沙盒化）**：本票把"数据根目录只有一处"这件事先做掉，
  32 就只需改那一处；否则 32 一定要漏。
- 建议**插在 31 之前**（或与 31 同时做，作为 31 的第 0 步）。

## 8. 还没核实的

- ⚠️ `Dev` 配置下 `Apple Development` 签名的 app，能否正常完成**沙盒**购买
  （沙盒购买按 Apple ID 区分，与签名方式的关系我没有查到明确结论）。
  我的判断是**可以**（沙盒环境只认 bundle id + 沙盒账号），但这条要**实测**，
  不能当成已知条件写进方案。

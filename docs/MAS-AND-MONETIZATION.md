# Marquee · 上架 Mac App Store 与收费方案

> 用途：回答两个决策问题 —— **1）怎么收费；2）怎么上 Mac App Store。**
> 日期：2026-10-02 ｜ 状态：**spec（待确认）**，实现尚未开工。
> 文中所有"沙盒能不能做"的结论都标了来源；带 ⚠️ 的是**我推断、需要实测**的。

---

## 0. 先量一下完成度

### 0.1 有据可查的

| 维度 | 现状 | 依据 |
| --- | --- | --- |
| 功能代码 | **29 条 ticket 全部落地**，没有一条是"计划中" | `.scratch/issues/.../INDEX.md` |
| 自动化测试 | **491 全绿**（Core 473 + 历史仓库 12 + 真实 Vision 自检 6） | `./scripts/test.sh` |
| 人工验收 | **294 条验收条目，一条都还没勾** | `docs/STATUS-AND-ACCEPTANCE.md` §3（A–Y 组） |
| 打包公证 | 脚本七步就绪，**一次都没跑过**（要你的 Developer ID 证书） | `scripts/package.sh` |
| 性能预算 | ≤150 ms、120 fps、≤4 ms 这些数字**只有埋点，没有实测记录** | 同上 §2 B5 |
| App 图标 | **没有**。仓里没有 `.xcassets`/`.icns`，`project.yml` 里 `ASSETCATALOG_COMPILER_APPICON_NAME` 是**空串** | `project.yml` |
| entitlements | **没有** `.entitlements` 文件 | 全仓 `find` |
| 屏幕录制用途描述 | **没有** `NSScreenCaptureUsageDescription`（见 §2.4） | `App/Info.plist` |
| 收费能力 | 零。没有任何 StoreKit / 许可代码 | 全仓 grep |

### 0.2 我的判断（一句话版）

| 口径 | 估计 | 差的是什么 |
| --- | --- | --- |
| **能演示** | **~95%** | 已成立：能力齐、交互打磨过多轮 |
| **能给自己天天用** | **~85%** | 差真实场景验收（sticky header、超长图、混合 DPI） |
| **能发给别人装** | **~70%** | 差 ①一次真机验收 ②跑通打包公证 ③性能数字 ④App 图标 |
| **能开始收钱** | **~30%** | 差 ①收费边界设计（本文 §1）②支付通道 ③上架材料 |

> 结论：**"做完了"和"能交付"之间隔着一次验收 + 一次打包；"能卖"要在上面再加一层。**
> 现在最大的单点风险不是功能，而是**打包公证从未真实跑过** —— 那一步只有你能跑。

---

## 1. 收费方案

### 1.1 先回答更前面的问题：这东西该**订阅**还是**买断**

先说结论：**对一个纯本地、无服务器成本的工具，买断（非消耗型 IAP）比订阅更诚实，也更好卖。**
订阅的正当理由只有三种，我们**现在一种都没有**：

1. 有**持续成本**（服务器、带宽、AI 调用）→ 我们没有（OCR 走系统 Vision，本地）；
2. 有**持续交付的价值**（云端同步、团队模板、多设备）→ 我们没有（无账号、无网络）；
3. 有**持续的内容/服务**（素材库、行情）→ 不适用。

硬做订阅的代价很具体：**首月冲动购买 + 次月取消 + 差评"一个截图工具凭什么月费"**。
截图工具是"装了就忘"的品类，用户对"每月扣钱"的容忍度极低。

**建议**：主线走**买断**，并利用 App Review 官方给试用的那条路（原文见 §1.4）；
若将来真的做了云能力，再上订阅 —— 那时订阅有依据。

### 1.2 免费 / 付费边界（无论买断还是订阅，这张表都要先定）

原则：**免费版必须能"完整地当一天的工具用"**。卖了基本可用性 = 差评。
所以卖的应该是**规模与频率**，不是"能不能用"。

| 能力 | 免费 | Pro | 为什么这么切 |
| --- | --- | --- | --- |
| 截图 / 窗口识别 / 悬停高亮 | ✅ | ✅ | 产品最外层的脸，不能挡 |
| 就地标注（形状 / 文字 / 打码 / 表情） | ✅ | ✅ | 同上 |
| 剪贴板直接交付 | ✅ | ✅ | 这是"快"的核心，挡了它产品就没有存在意义 |
| 最近截图 | 5 张 | 无上限 | 纯数量，不伤日常 |
| 导出格式 / 质量 | PNG | + JPEG / HEIC + 质量 | 纯数量 |
| **滚动截屏（长截图）** | ❌ | ✅ | **旗舰差异点**，且是竞品做不好的地方 |
| **OCR 文字识别** | ❌ | ✅ | 成本感强（首次 25 s 预热），用户愿意为此付费 |
| **钉图** | ❌ | ✅ | 有明确使用场景（对照抄写 / 设计比对） |
| 批量 / 模板 / 水印 | ❌ | ✅ | 给"专业人士"的增值 |

**不建议**的两类切法：
- ❌ **每日次数上限**：截图是不可预期的（突然要截 10 张），卡住会让人烦躁，而收益很低。
- ❌ **加不显眼的水印**：对一个"截图给别人看"的工具，水印等于毁掉输出 —— 免费用户会直接卸载，
  而不是升级。要挡住的话挡"次数"，别挡"质量"。

### 1.3 技术方案（如果走 App Store）

**必须用 StoreKit / IAP。** App Review 原文（Guideline 3.1.1）：

> 「想要解锁 app 内的功能（例如订阅、游戏货币、…或解锁完整版），**就必须使用 App 内购买**。
> App 不得使用专属机制来解锁内容或功能，例如**授权密钥**、AR 标记、二维码、加密货币…」

也就是说：**在 MAS 版里，任何"输个密钥就解锁"的做法都会被拒。**
（唯一例外在 3.1.3(b)：多平台服务可以承认用户在别处买过的内容，**但前提是 IAP 也必须提供**，
而且要有能关联身份的机制 —— 这与我们"无账号"的定位直接冲突。）

落地要点（StoreKit 2）：

| 项 | 做法 |
| --- | --- |
| 商品 | 买断：一个**非消耗型** IAP（如 `dev.tango.Marquee.pro`）；订阅：`pro.monthly` / `pro.yearly` 一组 |
| 查询 | `Product.products(for:)` 拿价格与本地化标题（价格文案**必须**用 `displayPrice`，不能写死） |
| 购买 | `product.purchase()`；处理 `.success(verification)` / `.userCancelled` / `.pending`（家长批准会 pending） |
| 权益 | `Transaction.currentEntitlements` 逐条 `verified`，取到即 Pro |
| 续期/退款/家庭共享 | 必须监听 `Transaction.updates` —— 这些**发生在 app 之外**，不监听就会"到期了还解锁着" |
| 离线 | 权益**本地缓存**（`Transaction.currentEntitlements` 本身可用），启动先读缓存再校验；不要"每次启动必须联网" |
| 恢复购买 | 界面上必须有一个「恢复购买」按钮（Guideline 要求可恢复） |
| 试用 | 订阅用 introductory offer；**买断**用官方那招（见 §1.4） |

**状态机放 Core**（这是本项目的一贯做法：编排进 Core、可脱机单测）：

```swift
public enum Entitlement: Equatable, Sendable {
    case unknown        // 还没查（启动瞬间）
    case free
    case trial(daysLeft: Int)
    case pro(expiresAt: Date?)   // nil = 买断，永不过期
    case expired(reason: String) // 到期 / 退款撤销
    case inGrace(until: Date)    // 扣款失败但仍在宽限期
}
```

⚠️ 关键判据：**"未知"不能当成"免费"**。启动瞬间就去判权限，会让付过费的用户看到一秒的锁
（"我买过啊" 是最伤人的一类 bug）。所以 `unknown` 期间应当**放行**（乐观），
校验失败再降级 —— 方向是"宁可少收一次，不可错拦一次"。

**界面**：偏好设置里加第五页「Pro」（现四页 + 1，仍在 PRD 的"≤4 页"约束之外 —— 需要决策：
要么并入「通用」页底部，要么把上限抬到 5）。触发点两处：① 点「滚动截屏」菜单项；
② 点工具栏「识别文字」/「钉图」。**不弹窗轰炸**，就地提示 + 一个"了解更多"。

### 1.4 官方给的"买断 + 试用"玩法

App Review 原文（3.1.1）明确允许：

> 非订阅式 app 可以提供一个**限期免费试用**，做法是**设一个价格档 0 的非消耗型 IAP**，
> 命名遵循 `XX 天试用`。试用开始前必须明确说明期限、结束后不可用的内容与后续费用。

也就是说：**买断也能有试用**，走"0 价非消耗型 IAP + 收据时间戳"，
试用期结束再用一个真正的付费 IAP 解锁。这条路比自建试用干净（对账由 Apple 管）。

⚠️ 需要实测：这条玩法在 **macOS** 上的实际体验（尤其是"0 价 IAP"在 Mac App Store 的展示），
我查到的原文没有区分平台，但社区案例以 iOS 居多。

### 1.5 如果**不上** MAS（Developer ID 分发）

那就**不能用 IAP**，必须自建：Paddle / LemonSqueezy（它们是 MoR，帮你处理税）/ Stripe + 自建许可服务。
代价具体是：

- 要**服务器**（发许可、校验、吊销、退款回调）—— 这与"纯本地"直接冲突；
- 要**防破解**（离线许可必然被 patch，只能提高门槛）；
- **一旦将来上 MAS**，就变成两套支付并存：MAS 里必须也能买（3.1.3(b)），
  还要能把"官网买过的人"认出来 —— 而认出人需要账号，与无账号定位冲突。

> **所以：收费渠道要一开始就选定，不能两头都留。** 见 §3 的两条路线。

---

## 2. 上架 Mac App Store 需要改什么

### 2.1 三条硬约束（已核实的原文）

1. **必须开 App Sandbox。** App Review 2.4.5(i) 要求"必须适当地沙盒化"。
   Apple 文档《Protecting user data with App Sandbox》原文写明它是
   "a requirement for distributing your app on the App Store"。
2. **沙盒禁止向其它 app 投递输入事件。** 同一份文档的"与沙盒不兼容的行为"清单里有：

   > 「**Posting keyboard or mouse events to another app** —— 你不能沙盒化一个控制别的 app 的应用。
   > 用 `CGEventPost` 一类函数投递键盘或鼠标事件是绕过这条限制的手段，**因此不允许来自沙盒应用**。」

   同一清单里还有「**Use of accessibility APIs in assistive apps**」。
   Apple 开发者技术支持（Quinn）在论坛的回复更直接：
   > 「It's not possible to use the Accessibility APIs from a sandboxed app. …
   > **AFAICT your only path forward here is to directly distribute your app using Developer ID signing.**」

3. **解锁功能必须走 IAP**（§1.3 的原文）。

### 2.2 会坏的功能 —— 逐条给对策

| 功能 | 沙盒下 | 对策 |
| --- | --- | --- |
| **自动滚动**（滚动截屏的后半，ticket 12） | ❌ **做不了**：它靠代用户发滚轮事件，而那正是被禁的那一条 | ① MAS 版**只保留手动滚动**长截图（能力还在，只是要用户自己滚 —— 与"手动版 MVP"完全同构）；② 或者不发 MAS 版，保住这个差异点 |
| 默认保存到**桌面** | ❌ **写不进去**：文件访问只有 user-selected / Downloads / **Pictures** / Music / Movies 这几类，**桌面对应的 entitlement 根本不存在** | 默认目录改成 `~/Pictures/Marquee`（加 `assets.pictures.read-write`）；或首次让用户选一次目录，存 **security-scoped bookmark** |
| 最近截图仓库 | ⚠️ 路径会从 `~/Library/Application Support/…` 变成容器内 | 写一次**一次性迁移**（把老目录的文件搬进容器），否则老用户"历史全没了" |
| 偏好设置（`dev.tango.Marquee` 的 plist） | ⚠️ 同上，读不到老的 | 同上，迁移或接受重设 |
| 全局快捷键（Carbon 热键） | ✅ 不受影响 | 不用改 |
| 截图 / 覆盖层 / 标注 / 导出 / 钉图 / OCR | ✅ 都不碰受限能力 | 不用改 |
| 鼠标穿透的钉图窗口 | ✅ | 不用改 |
| 「在 Finder 中显示」 | ✅ `NSWorkspace.activateFileViewerSelecting` 可用 | 不用改 |

### 2.3 工程改动清单（可勾）

- [ ] **App 图标**：做 1024×1024 → `Assets.xcassets/AppIcon` →
      `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`（现在是空串，等于没图标）
- [ ] **新增 `App/Marquee.entitlements`**：`app-sandbox` + `files.user-selected.read-write`
      + `assets.pictures.read-write`（默认存 Pictures 的话）；**不勾**用不到的项（多勾会被审核问）
- [ ] `project.yml` 加 `CODE_SIGN_ENTITLEMENTS`；MAS 构建要 `ENABLE_HARDENED_RUNTIME: YES`
      （现在是 NO —— 非 MAS 也建议开，但**开了要重新验一遍所有能力**）
- [ ] **`Info.plist` 补 `NSScreenCaptureUsageDescription`**（见 §2.4）
- [ ] 默认输出目录改 Pictures（或加"首次选目录"流程 + bookmark）
- [ ] 数据迁移（Application Support → 容器）
- [ ] 打包脚本加一条 MAS 路线：`xcodebuild archive` → `-exportArchive`（`app-store` 方法）→ 上传
- [ ] StoreKit：本地 `Products.storekit` 配置文件（开发期能买）+ App Store Connect 里建商品
- [ ] `Entitlement` 状态机（Core，可脱机单测）+ 偏好设置里的 Pro 页 + 四个触发点
- [ ] 上架材料：隐私标签（**可以答"不采集任何数据"** —— 这是我们相对竞品的优势）、
      审核备注（一条一句解释为什么需要屏幕录制）、截图、描述、关键词、年龄分级

### 2.4 ⚠️ 一个**现在就该补**的小缺陷：屏幕录制用途描述

`App/Info.plist` 里**没有** `NSScreenCaptureUsageDescription`。第三方 ScreenCaptureKit 文档一致地说：
触发屏幕录制 TCC 提示时**没有这个键的应用会被系统直接终止**。

⚠️ 但我们的 app 现在跑得起来 —— 所以要么 macOS 27 放宽了，要么你的授权是在某些条件之前授的。
**我不敢下结论，标为待实测。** 不过它成本极低（两行 plist），而且**上架必然要有**，建议现在就补。

### 2.5 顺带要知道的两件事（与上架无关，但影响体验）

1. **macOS 15+ 有定期的屏幕录制复确认提示**（Sequoia 起引入，大约每周/每月一次，
   官方不支持关闭）。用户会周期性看到系统弹框问"是否继续允许 Marquee 录制屏幕"。
   这**不是 bug**，但要在帮助文档和审核备注里说清楚，否则会被当成"这软件老是要权限"。
2. 用户如果**从 DMG 直接运行**（app translocation），TCC 记的是临时路径的身份，
   授权会记不住 —— `RELEASE.md` 里"拖进 Applications 再打开"那句**必须保留**。

---

## 3. 两条路线（请选一条）

| | 路线 A：Developer ID（现状） | 路线 B：Mac App Store |
| --- | --- | --- |
| **自动滚动** | ✅ 保住 | ❌ 必须砍掉（只留手动） |
| **默认存桌面** | ✅ | ❌ 改 Pictures 或让用户选 |
| 支付 | 自建许可（要服务器 / 要防破解） | IAP（Apple 处理税与退款） |
| 分发 / 更新 | 自己发 DMG；更新靠手动指引 | 商店自动更新 |
| 触达 | 要自己推广 | 有商店搜索与曝光 |
| 审核 | 无 | 有（截图工具不是敏感品类，Snip 就在架上） |
| 工作量 | 小（打包脚本已就绪） | **中**（§2.3 那一串 + 一个功能的降级） |

**我的建议**：

- **想快、想保住差异点** → 路线 A 先把 v1 发出去，收费用自建许可（或先免费，攒口碑）。
  代价是以后转 MAS 时要接受功能降级 + 老用户的许可衔接。
- **想要"安装 / 支付 / 更新"一条龙** → 路线 B。接受**自动滚动只在手动模式下存在**。
  这个牺牲是**有先例的**：腾讯 Snip 的 App Store 版就是「滚动截屏不可用」
  （见 `docs/PRD.md` 附录 A），它同样被沙盒挡住了。

> 一句话：**这不是技术难题，是"要哪一个差异点"的产品决策。**
> 技术上两条都通；沙盒那条的唯一硬伤就是自动滚动。

---

## 4. 建议的 ticket 切分（确认方向后再开）

| # | Ticket | 依赖 | 交付 |
| --- | --- | --- | --- |
| 29 | App 图标与上架元数据（含 `NSScreenCaptureUsageDescription`） | 无 | 双路都要；图标是本项目唯一"零风险高收益"的一步 |
| 30 | 权益状态机 + Pro 页（Core 可单测，先用本地开关模拟） | 无 | 不依赖 StoreKit 就能做，界面与判据先落地 |
| 31 | StoreKit 2 接入（查询 / 购买 / 恢复 / `Transaction.updates`） | 30 | 能在沙盒环境真买一次 |
| 32 | 沙盒化改造（entitlements + 默认目录 + 数据迁移） | 无 | `-marqueeDemoEditor` 与主流程在沙盒下全绿 |
| 33 | MAS 打包与提审路线（archive → exportArchive → 上传） | 32 | 至少过一次 TestFlight/内部测试 |

> 顺序建议：**29（图标）→ 30（权益状态机）→ 31（StoreKit）**，
> 沙盒化（32/33）**单独一条线**，因为它会改动默认目录与数据位置，与收费无关，
> 可以并行也可以等路线定了再做。

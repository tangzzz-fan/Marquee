# Marquee · 隐私政策（发布用）

> 用途：**一份可整段粘进飞书云文档的正文** + 发布时必须做的几步。
> 日期：2026-10-08 ｜ 对应 ASC 的「隐私政策 URL」那一格。
>
> ⚠️ 正文里有一处 `[待填：你的支持邮箱]` —— **发布前必须换成真实邮箱**。
> 审核员会点它，空着或写假地址会被打回。

---

## 0. 发布前必做（三步，缺一步审核员就打不开）

### ① 建文档、粘正文

飞书 → 云文档 → 新建文档 → 把下面 **§2 中文正文**（英文站也填就把 §3 附在后面）整段粘进去。
标题写 `Marquee 隐私政策`。

### ② ⚠️ 改共享设置 —— 这一步最容易忘，而忘了必然被打回

飞书文档**默认是「仅组织内成员可阅读」**。Apple 的审核员没有你的飞书账号 ——
他们打开会看到登录页，然后以 **Guideline 5.1.1（隐私政策 URL 不可访问）** 打回。

```text
文档右上角「分享」→ 链接分享 → 改为「互联网上获得链接的人可阅读」
（不同版本措辞略有差异：也可能叫「获得链接的任何人可阅读」/「公开」）
```

⚠️ 有些企业管理员**在后台禁用了对外分享** —— 那时这个开关是灰的。
真遇到这种情况就别在飞书上耗，改用 GitHub Pages / 任意静态托管放一份同样的内容。

### ③ 用**无痕窗口**验证（不要跳过）

```text
复制分享链接 → 开一个无痕窗口（未登录任何账号）→ 粘贴访问
```

**必须能看到正文、不弹登录、不要求申请权限。** 只用你自己的浏览器点开是不够的 ——
你自己的浏览器带着登录态，能打开不代表别人能打开。

---

## 1. 这份政策与 ASC「隐私标签」的对应

| ASC 隐私标签的问法 | 答案 | 依据 |
| --- | --- | --- |
| 是否采集数据 | **不采集任何数据** | Marquee 没有网络权限（`App/Marquee.entitlements` 里刻意不含 `network.client`），物理上无法外发 |
| 使用数据 / 分析 | 否 | 无埋点、无统计 SDK |
| 诊断 | 否 | 日志只落本机，不发送 |
| 用户内容 | 否 | 截图只在本机处理 |
| 购买记录 | 否 | 由 StoreKit 处理；app 侧只在**本机**缓存"买过没" |

⚠️ **两处必须一致**：隐私标签答的、隐私政策写的、以及 app 实际行为的，三者不一致是
被打回的典型理由（审核员会拿标签去对二进制）。这份政策写的每一句都能在代码里指认。

---

## 2. 中文正文（从这里开始整段复制）

# Marquee 隐私政策

最后更新：2026 年 10 月 8 日
生效日期：2026 年 10 月 8 日

Marquee（以下简称"本应用"）是一款运行在 macOS 上的截图与标注工具。我们把它设计成一个**完全在本机工作**的工具：它不采集你的任何数据，也不把你的任何内容发送到任何服务器。

本政策说明本应用如何处理你的信息。请在使用前阅读。

## 一、我们不采集任何数据

本应用**不收集、不存储、不传输**任何个人信息，具体包括：

- 不需要注册账号，不要求登录，不掌握任何可以指向你的身份信息；
- 没有埋点、统计、崩溃上报或广告 SDK；
- 不申请网络访问权限 —— 本应用**在系统层面就没有联网能力**，因此任何内容都不存在"被上传"的可能；
- 不读取设备标识符，不做跨应用或跨网站的追踪。

## 二、你的内容如何被处理

以下每一项都在你的 Mac 本机完成，不离开设备：

| 处理内容 | 在哪里处理 | 是否外发 |
| --- | --- | --- |
| 屏幕截图 | 本机内存与磁盘 | 否 |
| 标注（矩形、箭头、文字、马赛克、模糊等） | 本机 | 否 |
| 文字识别（OCR） | 使用 macOS 系统自带的识别框架，本机完成 | 否 |
| 放大镜取色 | 本机 | 否 |

**「屏幕录制」权限**：首次截图时，macOS 会要求你授予本应用「屏幕录制」权限。这是系统对所有截图工具的强制要求（不只是本应用）。授予后，本应用**只在你按下截图快捷键的那一刻**读取屏幕内容，读取到的图像仅用于你当场发起的截图，不会在后台持续采集，也不会被保存到截图产物之外的任何地方。你可以随时在「系统设置 → 隐私与安全性 → 屏幕录制」中关闭该权限，关闭后本应用将无法截图，其余功能不受影响。

## 三、数据被保存在哪里

1. **截图文件**：保存在你指定的保存目录（默认是 `~/Pictures/Marquee`）。文件完全属于你，你可以随时在访达中查看、移动、复制或删除。
2. **最近截图记录**：为了让"最近截过的那几张"可再次使用，本应用会在本机保留一份截图记录。
   - **由你主动删除的截图**：会被移入**废纸篓**，你可以像对待任何文件一样恢复它；
   - **超出保留数量后被自动淘汰的**：才会被永久删除。免费版保留最近 5 张，购买 Pro 后不设上限。
3. **偏好设置**：保存在本机（macOS 应用沙盒容器或你的用户资源库中），包括快捷键、输出格式、保存目录等。
4. **购买状态**：本应用会在本机记录"你是否已购买 Pro"这一项判断，用于决定功能是否解锁。
5. **排障日志**：用于定位问题的日志只写入本机文件，**不会被发送给我们或任何第三方**。

## 四、第三方

本应用**不与任何第三方共享你的数据**，因为我们根本不持有这些数据。

唯一涉及第三方的环节是**购买**：Marquee Pro 的购买、退款与恢复由 Apple 的 App Store 内购系统完成。交易信息由 Apple 按其隐私政策处理（参见 Apple 隐私政策：https://www.apple.com/legal/privacy/ ）。本应用只从系统获得"这笔购买是否存在、是否被撤销"的结论，不会获得你的支付方式、账单地址或姓名。

本应用不集成任何第三方分析、广告、社交或数据 SDK。

## 五、你的权利：查看、导出与删除

- **查看与导出**：你的截图就在你自己选的目录里，偏好设置也在本机，随时可查看与备份。
- **删除**：删除截图文件即等于删除对应数据（你主动删的进废纸篓）。删除本应用，即会一并移除它在本机保存的偏好设置与最近截图记录。
- **撤回同意**：本应用不依赖任何数据采集运行，因此不存在"撤回同意"这一动作；若要停止使用，直接退出并删除本应用即可。
- **屏幕录制权限**：可随时在系统设置中关闭（见上文第二节）。

由于本应用不持有你的任何个人信息，我们**无法也没有能力**代你查询、导出或删除数据 —— 这些数据从来都只在你自己的设备上。

## 六、儿童

本应用不面向儿童设计，也不采集任何人的数据（包括儿童）。

## 七、本政策的变更

如果本应用未来新增了会接触数据的功能，我们会更新本政策并在本页面公布新的"最后更新"日期。
**在当前版本中，本应用不采集任何数据；若这一点发生改变，一定会在你升级前明确告知。**

## 八、联系我们

对本政策有疑问，请通过以下方式联系我们：

**`[待填：你的支持邮箱]`**

---

## 3. English version (append if you also ship an English listing)

# Marquee Privacy Policy

Last updated: October 8, 2026
Effective: October 8, 2026

Marquee ("the app") is a screenshot and markup tool for macOS. It is designed to work **entirely on your Mac**: it collects no data about you and sends none of your content to any server.

## 1. We collect nothing

The app does **not collect, store, or transmit** any personal information:

- No account and no sign-in. We hold no information that could identify you.
- No analytics, crash-reporting, tracking, or advertising SDKs.
- No network entitlement — the app **has no network capability at the system level**, so nothing can be uploaded even in principle.
- No device identifiers, and no cross-app or cross-site tracking.

## 2. How your content is handled

Everything below happens locally on your Mac and never leaves it: screen capture, annotation
(rectangle, arrow, text, mosaic, blur, and more), text recognition (macOS built-in frameworks),
and the colour picker.

**Screen Recording permission.** On your first capture, macOS asks you to grant the app Screen
Recording access. This is a system requirement for every screenshot tool, not something specific
to Marquee. Once granted, the app reads the screen **only at the moment you press the capture
shortcut**; the image is used solely for the capture you just started, is never collected in the
background, and is never stored anywhere beyond the screenshot you asked for. You can revoke the
permission at any time in System Settings → Privacy & Security → Screen Recording. Without it the
app cannot capture, and nothing else is affected.

## 3. Where data is kept

1. **Captures** are saved to the folder you choose (by default `~/Pictures/Marquee`). They are
   yours; view, move, copy or delete them in Finder at any time.
2. **Recent captures** are kept locally so the last few shots remain reusable.
   Captures **you** delete go to the **Trash** and can be restored like any file; only ones
   **evicted automatically** after exceeding the retention count are removed permanently.
   The free tier keeps the last 5; Pro removes the limit.
3. **Preferences** (shortcuts, output format, save folder) are stored locally on your Mac.
4. **Purchase status** — whether you have bought Pro — is recorded locally to decide what unlocks.
5. **Diagnostic logs** are written to local files only and are **never sent to us or anyone else**.

## 4. Third parties

The app **shares nothing with third parties**, because it does not hold your data at all.

The only third party involved is **purchase**: buying, refunding and restoring Marquee Pro is
handled by Apple's App Store in-app purchase system. Apple processes that transaction under its
own privacy policy (https://www.apple.com/legal/privacy/). The app only learns *whether* a
purchase exists and whether it was revoked — never your payment method, billing address or name.

No third-party analytics, advertising, social or data SDKs are bundled.

## 5. Your rights

- **Access and export**: your captures are in the folder you chose, and your preferences are on
  your Mac. Both are yours to view and back up.
- **Deletion**: deleting a capture deletes that data (captures you delete go to the Trash).
  Deleting the app removes the preferences and recent-capture records it kept locally.
- **Withdrawing consent**: the app does not depend on any data collection to run, so there is no
  consent to withdraw — quit and delete the app to stop using it.
- **Screen Recording permission**: revocable at any time in System Settings (see section 2).

Because the app holds no personal information about you, we **cannot** look up, export or delete
data on your behalf — it has only ever existed on your own device.

## 6. Children

The app is not directed at children, and it collects no data from anyone, including children.

## 7. Changes to this policy

If a future version adds anything that touches data, we will update this policy and publish a new
"last updated" date here. **In the current version the app collects nothing, and if that ever
changes you will be told clearly before you upgrade.**

## 8. Contact

Questions about this policy: **`[待填：你的支持邮箱]`**

---

## 4. 相关文档

| 主题 | 去哪看 |
| --- | --- |
| 商店文案、审核备注、隐私标签怎么写 | `docs/APP-STORE-LISTING.md` |
| ASC 操作清单（含隐私政策 URL 那一格） | `docs/APP-STORE-CONNECT.md` |
| ⚠️ **app 内也要有隐私政策入口**（Guideline 5.1.1(i)） | ✅ **已实装**（2026-10-08）：设置 → 通用页最后一行「隐私政策 · 查看」。链接唯一来源在 Core `ExternalLinks`，改链接**只改那一行** |

# Marquee · App Store 商店文案与审核信息

> 用途：**逐格粘贴**的一份表。App Store Connect 里每个输入框写什么、上限多少字、哪几格必填，
> 都在下面。商品（内购）那两个的审核信息在 `docs/APP-STORE-CONNECT.md` §1.6，不在这里。
>
> 日期：2026-10-08 ｜ 对应构建：`0.1.0 (1)`，`MAS` 配置
>
> ⚠️ 三条总原则（写文案时别破）：
> 1. **只写已经做出来的功能**。产品页承诺了、app 里没有 ⇒ 审核与差评的双重来源。
> 2. **不提具体价格**。价格随地区与调价变，写「一次买断」不写「¥36」。
> 3. **不说"免费"去指代整个 app**。app 本身免费，四项能力要买断 —— 两句话都要说。
>    （指南要求：不能让人觉得"免费装完就没有任何功能限制"。）

---

## 0. 填写顺序（ASC 里的路径）

```text
我的 App → Marquee
├─ App 信息           ← §1 §3（名称·副标题·分类·URL）
├─ 版本信息 1.0.0     ← §2 §4 §5（描述·关键词·年龄分级·隐私）
├─ App 审核信息       ← §6（联系人·登录·备注）
├─ App 内购买项目     ← docs/APP-STORE-CONNECT.md §1.6
└─ 构建版本           ← scripts/package-mas.sh 导出的包
```

必填项（少一格就交不上去）：**名称 · 副标题 · 描述 · 关键词 · 支持 URL · 隐私政策 URL · 年龄分级 · 构建版本**。
「营销 URL」与「宣传文本」选填。

---

## 1. App 名称与副标题

| 格 | 上限 | 中文（主） | 英文 |
| --- | --- | --- | --- |
| **名称** | 30 | `Marquee` | `Marquee` |
| **副标题** | 30 | `键盘驱动的截图与标注` | `Screenshot & markup, keyboard-first` |

⚠️ **名称被占用的话 ASC 会直接拦住**（先占先得，与你是否已上架无关）。若 `Marquee` 已被占，
备选（都 ≤30）：`Marquee 截图` / `Marquee 截屏标注`。**改名要一次定死** ——
商品挂在 App ID 上，而上架后再改名称要重新过审。

> ⚠️ 但**先分清占用者是谁**：如果报的是「**您账户中的另一个 App** 正在使用该名称」，
> 那多半是你自己账号里的记录 —— 而名称是**可以改的**（提交审核前随时可改），
> 把那个 app 改个名就腾出来了。**别急着换名字**。判断表见
> `docs/APP-STORE-CONNECT.md` §1.3。

**分类**：`效率`（Productivity）。
⚠️ 这里必须与 `App/Info.plist` 的 `LSApplicationCategoryType`（`public.app-category.productivity`）
一致 —— 两处不一致会被拒。**改一处就两处一起改**。

**内容版权**：`© 2026 Marquee`（与 `Info.plist` 的 `NSHumanReadableCopyright` 同源）。

---

## 2. 描述类（中文为主，英文另填一套）

### 2.1 宣传文本（≤170 字，选填，可随时改、不用重新过审）

中文：

```text
按一下快捷键，框选，走人。标注是能被反复修改的对象，不是涂上去的像素；截图、打码、识别文字全部在本机完成。
```

英文：

```text
One shortcut, one drag, done. Annotations stay editable objects instead of burnt-in pixels — and everything runs on your Mac.
```

### 2.2 描述（≤4000 字）

中文（直接粘贴）：

```text
Marquee 是一个键盘驱动的截图与标注工具。按一下快捷键，框选，走人。

【快】
· 全局快捷键唤起，默认 ⌃Q，可改成你自己顺手的键
· 光标停在哪，窗口就自动高亮 —— 单击选中整个窗口，不必贴着边缘比划
· 选区带 8 个控制点、边缘吸附，按住 ⇧ 锁定比例
· 按下回车，图已经在剪贴板里了；想留档就 ⌘S

【标注是对象，不是涂上去的像素】
矩形、椭圆、箭头、画笔、文字、序号、马赛克、模糊 —— 每一个都是可以再选中、再移动、
再删除的独立对象，画完之后改主意，⌘Z 可以一路撤到底，裁切也能撤回来。

【打码是真的糊掉】
马赛克与模糊在输出时作用在像素上，不是盖一层半透明色块。马赛克在本机完成，图不会离开你的 Mac。

【长截图】
滚动截屏会把一屏放不下的内容拼成一张长图，自动对齐拼接位置、去掉重复的行。
不方便自动滚动时也可以手动滚、随时结束。

【识别文字】
直接读出截图里的文字，结果一键复制。

【钉图】
把截图钉在屏幕上的任意位置 —— 对照抄写、设计比对时不用来回切窗口。

【本机处理，不需要账号】
截图、打码、文字识别全部在你的 Mac 上完成。Marquee 不要求注册或登录，不上传任何内容，
也没有网络权限。没有埋点、没有统计、没有广告。

【价格】
Marquee 可以直接免费使用：区域 / 窗口 / 全屏截图、完整的就地标注、剪贴板交付，
以及除了一处以外的全部设置项（含开机自启与快捷键自定义）。
一次买断解锁四项能力：滚动截屏、识别文字、钉图，以及不设上限的最近截图
（免费版保留最近 5 张）。没有订阅，没有续费，不涉及任何自动扣款。
拿不准的话可以先免费试用 7 天，试用结束不会扣费，只是回到免费版。

【系统要求】
macOS 15.0 或更高。

首次截图时系统会询问「屏幕录制」权限 —— 这是 macOS 对所有截图工具的要求，
不只是 Marquee。授予之后，Marquee 只在你按下快捷键那一刻读取屏幕，其余时间不碰。
```

英文（直接粘贴）：

```text
Marquee is a keyboard-first screenshot and markup tool. One shortcut, one drag, done.

FAST
· A global shortcut brings up the capture overlay (⌃Q by default, and you can rebind it)
· Hover anywhere and the window underneath is highlighted — one click selects the whole window,
  no pixel-hunting along its edges
· Eight handles, edge snapping, and ⇧ to lock the aspect ratio
· Press Return and the image is already on your clipboard; ⌘S saves it

ANNOTATIONS ARE OBJECTS, NOT PIXELS
Rectangle, ellipse, arrow, pen, text, counter, mosaic, blur — every one of them stays a separate
object you can select again, move, or delete. Changed your mind? ⌘Z walks all the way back,
including a crop you already applied.

REDACTION REALLY REDACTS
Mosaic and blur are applied to the pixels on export, not painted over with a translucent box.
The mosaic is built on your Mac; the image never leaves it.

SCROLLING CAPTURE
Stitch a page that doesn't fit on one screen into a single tall image, with the seams aligned and
duplicated rows dropped. If automatic scrolling isn't an option, you can scroll by hand and stop
whenever you like.

TEXT RECOGNITION
Read the text right out of a screenshot and copy it in one action.

PIN
Pin a screenshot anywhere on screen — handy for copying from a reference or comparing designs
without switching windows.

PROCESSED LOCALLY, NO ACCOUNT
Capture, redaction, and text recognition all happen on your Mac. Marquee never asks you to sign up,
never uploads anything, and has no network access at all. No analytics, no tracking, no ads.

PRICING
Marquee is free to use as-is: area, window and full-screen capture, the complete set of inline
annotation tools, clipboard delivery, and every setting except one (including launch at login and
custom shortcuts). A single one-time purchase unlocks four things: scrolling capture, text
recognition, pinning, and an unlimited recent-captures list (the free tier keeps the last 5).
No subscription, no renewal, nothing recurring. Not sure yet? Try every Pro feature free for
7 days — when the trial ends nothing is charged and the app simply returns to the free tier.

REQUIREMENTS
macOS 15.0 or later.

On your first capture, macOS will ask for Screen Recording permission. That's a system requirement
for every screenshot tool, not something specific to Marquee. Once granted, Marquee only reads the
screen at the moment you press the shortcut.
```

⚠️ 别在描述里放的：**具体价格**、别的 app 的名字、`App Store` 字样以外的平台名、"最好/第一"这类绝对说法。

### 2.3 关键词（≤100 个字符，**逗号分隔，不要空格**）

中文：

```text
截图,截屏,长截图,滚动截屏,标注,马赛克,OCR,识别文字,钉图,贴图,取色,放大镜,快捷键
```

英文：

```text
screenshot,capture,annotation,markup,OCR,pin,longshot,scrolling,colorpicker,macOS,utility,shortcut
```

⚠️ 三条硬规则：
1. **不要重复 app 名称**（名称与副标题里的词系统已经算进去了，重复是纯浪费）。
2. **不要写竞品名**。
3. **逗号后面别留空格** —— 空格也算字符，一百个字符很紧。

---

## 3. URL（三格，其中两格必填）

| 格 | 必填 | 建议值 |
| --- | --- | --- |
| **支持 URL** | ✅ | `https://github.com/tangzzz-fan/Marquee/issues` |
| **营销 URL** | ✕ | 留空，或与支持 URL 相同 |
| **隐私政策 URL** | ✅ | 见 `docs/PRIVACY-POLICY.md`（正文 + 飞书发布三步 + 无痕验证） |

⚠️ **两格都必须能匿名打开**。审核员不会登录 GitHub 企业版或任何账号 ——
先开一个无痕窗口点一遍。

⚠️ 仓库是私有的，那个链接对内是好的、对审核员是 404 ⇒
要么把仓库设为 public，要么另找一个公开页面。

**隐私政策**：即使「不采集任何数据」，这一格也必须填。文案见 §9.2，
放哪儿都行（GitHub Pages / 仓库里的一个公开文件 / 自己的域名）。

---

## 4. 年龄分级

ASC 会问一串问题。**全部选「无 / None」**，结果自动落到 **4+**。
唯一要留意的一条：**「无限制的网页访问」选否** —— Marquee 里没有内嵌浏览器。

---

## 5. 隐私标签（App 隐私）

**答案：`不采集数据`（Data Not Collected）** —— 每一项都选"不采集"，不做任何例外。

依据（都可以在代码里指认）：

| 常被误报的项 | Marquee 的实际做法 |
| --- | --- |
| 使用数据 / 分析 | 没有埋点、没有统计 SDK |
| 诊断 | 崩溃日志只落本机 `~/Library/Application Support/…`，不发送 |
| 用户内容（截图） | 只在本机处理；**没有网络 entitlement**，物理上发不出去 |
| 购买记录 | 由 StoreKit 与 App Store 处理，app 侧只在**本机**缓存"买没买"这个判定 |

⚠️ **屏幕录制不是"数据采集"**。它读的是屏幕内容、不离开设备，
所以在隐私标签里**不算**收集 —— 别因为它就勾"收集用户内容"，那反而是错的。

---

## 6. App 审核信息（App Review Information）

### 6.1 联系人

你的姓名 / 电话 / 邮箱。**邮箱要能收到审核邮件**（退回意见发到这里）。

### 6.2 登录信息

**勾「不需要登录」**（Sign-in required 取消勾选）。
Marquee 没有账号系统，不要编一个测试账号 —— 编了审核员会去找那个不存在的登录入口。

### 6.3 备注（App Review Notes，≤4000 字）

直接粘贴：

```text
Marquee 是菜单栏常驻应用（LSUIElement = true），启动后没有 Dock 图标、也没有主窗口 ——
这一点是设计如此，不是启动失败。请点击屏幕右上角菜单栏里的 Marquee 图标打开菜单。

【最短验证路径】
1. 点菜单栏图标 →「截取屏幕」（或按默认快捷键 ⌃Q）
2. 拖动框选任意区域
3. 按回车 → 截图已进入剪贴板；按 ⌘S 可另存为 PNG

首次截图时系统会询问「屏幕录制」权限，这是 macOS 对所有截图工具的要求。
如果之前误点过拒绝，可在「系统设置 → 隐私与安全性 → 屏幕录制」里重新勾选。

【关于沙盒与权限】
本构建启用 App Sandbox，只声明了三项 entitlement：
  · com.apple.security.app-sandbox
  · com.apple.security.files.user-selected.read-write（「另存为」时用户亲自选的目录）
  · com.apple.security.assets.pictures.read-write（默认落盘 ~/Pictures/Marquee）
没有网络 entitlement —— app 不上传任何数据。没有辅助功能（Accessibility）、
摄像头、麦克风等任何其它权限。

沙盒版本中「自动滚动」不提供（沙盒应用无法向其它进程注入输入事件），
长截图仍可通过手动滚动完成；界面在这种情况下不会引导用户去开启「辅助功能」。

【关于两个 App 内购买项目】
· com.tango.marquee.pro（非消耗型，一次买断 ¥36）：
  解锁滚动截屏、识别文字、钉图，以及不设上限的最近截图。
  入口：菜单栏图标 →「设置…」→ 通用页底部「升级到 Pro」。
  app 本身免费；这一笔是全 app 唯一的收费项，不涉及订阅与自动续费。
· com.tango.marquee.pro.trial（价格等级 0 的非消耗型）：
  按 Guideline 3.1.1 最后一节，非订阅 app 用「价格等级 0 的非消耗型 IAP」提供限期免费试用。
  试用 7 天，结束后不会产生任何扣款，只是回到免费版（截图与标注仍然免费）。
  试用时长与结束后失效的内容，都写在 app 内弹出的卡片正文里。
  入口：在免费版下使用任一 Pro 功能时（菜单「滚动截屏」，或工具栏的「识别文字」「钉图」）
  会在原地弹出一张非模态卡片，其主按钮即「7 天免费试用」。

【如果要在沙盒环境里验证购买】
请使用沙盒测试账号；app 不需要登录任何服务，购买流程完全由系统支付面板完成。
```

---

## 7. 「是否需要填写沙盒信息」—— 直接回答

**ASC 里没有一格叫「沙盒信息」要你填。** 沙盒是从**二进制的 entitlement** 里读出来的，
所以要做的是**让归档出来的包真的带沙盒**，而不是在网页上勾什么。

真正要保证的三件事：

| # | 要保证的 | 怎么核 |
| --- | --- | --- |
| 1 | 归档用的是 **`MAS` 配置**，不是 `Release` | ⚠️ `Release` 是 Developer ID 那条路、**不带沙盒** —— 拿它归档的包上传会被拒。`scripts/package-mas.sh` 已把配置钉死，并在预检里核对 |
| 2 | 包里**有** `com.apple.security.app-sandbox = true` | 脚本预检第 2 步 |
| 3 | 包里**没有** `com.apple.security.get-task-allow` | 脚本预检第 3 步。它是开发签名的标记，带上必被拒 |

还有一处容易被忽略：ASC 的「App 审核信息」里要写清 **app 需要「屏幕录制」权限**（§6.3 已写）。
审核员在第一次截图时会被系统弹框，备注里先说一句，能省掉一轮来回。

---

## 8. 提审前的最后一遍

```text
[ ] 名称 / 副标题（中英）已填，且名称未被占用
[ ] 描述（中英）+ 关键词（中英）已填，字数在上限内
[ ] 宣传文本（中英）已填
[ ] 支持 URL / 隐私政策 URL 能匿名打开
[ ] 分类 = 效率，与 Info.plist 的 LSApplicationCategoryType 一致
[ ] 年龄分级问卷填完（预期 4+）
[ ] 隐私标签 = 不采集数据
[ ] App 审核信息：联系人 + 勾「不需要登录」+ 备注已贴
[ ] 两个内购商品的审核截图与备注已填（docs/APP-STORE-CONNECT.md §1.6）
[ ] 构建版本已导出并上传 —— Xcode 选 **`Marquee MAS`** scheme → Product → Archive →
    Organizer → Distribute App → App Store Connect → Upload（见 docs/APP-STORE-CONNECT.md §6.5）
[ ] 版本信息里的「App 内购买项目」区块勾上了那两个商品
```

---

## 9. 附：隐私政策文案（放 §3 那一格指向的页面）

### 9.1 中文

```text
Marquee 不采集任何数据。

· 截图、打码、文字识别全部在你的 Mac 本机完成，不会上传到任何服务器。
· Marquee 没有网络权限，也没有埋点、统计或广告 SDK。
· 不需要注册或登录，我们不掌握任何可以指向你的信息。
· 唯一被记下的是「你有没有买过 Pro」这个判定，它只存在于你本机的偏好设置里。
· 截图文件保存在你指定的目录；删除时，用户主动删的进废纸篓，自动淘汰的才永久删除。

如果你对隐私有疑问，请通过支持页面联系我们。
```

### 9.2 English

```text
Marquee collects nothing.

· Screenshots, redaction, and text recognition all run locally on your Mac. Nothing is uploaded.
· Marquee has no network access, and contains no analytics, tracking, or advertising SDKs.
· There is no account and no sign-in, so we hold no information that could identify you.
· The only thing stored is whether you have purchased Pro — recorded in your local preferences.
· Captures live in the folder you choose. Files you delete yourself go to the Trash; only
  automatically evicted ones are removed permanently.

Questions about privacy? Reach us through the support page.
```

---

## 10. 相关文档

| 主题 | 去哪看 |
| --- | --- |
| 两个内购商品的建立与审核信息 | `docs/APP-STORE-CONNECT.md`（§1.4–1.6、§4） |
| 商店截图（2880×1800 那套） | `docs/APP-STORE-CONNECT.md` §7 · `docs/review/app-shots/` |
| 导出上架用的构建 | `scripts/package-mas.sh` |
| 为什么沙盒版砍掉了自动滚动 | `docs/MAS-AND-MONETIZATION.md` §2 · `docs/PITFALLS.md` 143/144 |

# 屏幕录制权限：问题分析与解决

> 日期：2026-09-30  
> 现象最初来自人工验收：按截屏快捷键后反复弹出系统「屏幕录制」授权框，或系统设置里找不到 Marquee。  
> 本文是这条链路的**完整复盘**。开发摩擦的短摘要仍在 `docs/DEV-NOTES.md` 第 1 节。

---

## 1. 用户看到的现象

按时间顺序，同一条链路上出现过四种不同的表面症状，底层是同一件事被拆成多层：

| # | 用户描述 | 当时立刻能看到的东西 |
| --- | --- | --- |
| 1 | 每次运行都要重新授权 | 系统授权框；勾选后下次构建又要再勾 |
| 2 | 系统设置 → 屏幕录制里**没有 Marquee** | 授权框、我们自己的「去系统设置」提示；列表里没有可勾的行 |
| 3 | 点了授权仍然截不了 | 提示不准确，或蒙层叠在系统框上面 |
| 4 | 点一次快捷键，授权框**一张接一张** | 同一次按键弹出 2～3 张系统框；再按又来一轮 |

第 4 种是最后修掉的。前三种在修签名与登记方式时已经处理过，但如果不理解整层结构，修第 4 种时很容易把第 2 种再引进来。

---

## 2. 这条链路实际怎么走

按下 `⌃Q`（或菜单「截屏」）：

```
CaptureCoordinator.performCapture
  └─ CaptureGateRunner.run(SystemScreenRecordingPermission)
        ├─ CGPreflightScreenCaptureAccess()     // 静默预检，不弹框
        ├─ 若未授权：requestPermission()
        │     ├─ SCShareableContent.excludingDesktopWindows  // 让系统把 app 登记进列表
        │     └─ CGRequestScreenCaptureAccess()              // 权威结论（可能弹系统框）
        └─ 已授权且不是「刚勾选」→ 弹出选区覆盖层 → ScreenCaptureKit 采集
```

两个系统事实贯穿全程，后面每一层根因都踩在上面：

1. **TCC 按「bundle id + 代码签名身份」记账。**  
   ad-hoc 签名没有身份，系统退回按 **cdhash** 记账；每次重新构建 cdhash 都变，于是每次都是「新应用」。
2. **ScreenCaptureKit 在「刚勾选授权」的同一个进程里不可用。**  
   必须退出并重新打开。`CGRequestScreenCaptureAccess()` 返回 `true` 只表示 TCC 记下来了，不表示当前进程已经能采集。
3. **macOS 只在应用真正调用采集相关 API 时，才把它登记进「屏幕录制」列表。**  
   权限门若拦在采集之前，而请求权限又只调 `CGRequestScreenCaptureAccess()`，列表里可能永远没有这一行。
4. **`CGPreflightScreenCaptureAccess()` 只有布尔，区分不了「从未询问」和「已被拒绝」。**  
   在 macOS 15+ 上，即使用户已经去系统设置勾过，**重启前**它也会一直是 `false`。

---

## 3. 根因分层（按发现顺序）

### 3.1 签名身份不稳定（权限留不住）

工程最初 `CODE_SIGN_IDENTITY: "-"`（ad-hoc）。TCC 无法绑定稳定身份，每次 Xcode Run / `xcodebuild` 都被当成新应用。

第一版修复写在 `scripts/build.sh` 里「构建后再用证书重签」。这在脚本路径有效，但 **Xcode Run 不执行该脚本**，开发时的常态产物仍然是 ad-hoc。所以「修了脚本」等于没修。

**正确位置**：签名必须由 `project.yml` 负责（`CODE_SIGN_STYLE: Automatic` + `Apple Development` + `DEVELOPMENT_TEAM: UKXWZ3FS84`）。

额外踩点：`DEVELOPMENT_TEAM` 必须是 **team id**（`codesign -dvvv` 的 `TeamIdentifier=`，本机 `UKXWZ3FS84`），不是证书名括号里那串（`Apple Development: … (7H6TJ2PN25)` 是证书自身标识）。填错会报 `No signing certificate "Mac Development" found`。

### 3.2 用 UserDefaults 推断「已拒绝」（永远授权不了）

`CGPreflightScreenCaptureAccess()` 只有 true/false。曾经用 `permission.screenRecording.requested` 持久化标记，把 false 补成「已拒绝」，从而不再调用 `CGRequestScreenCaptureAccess()`。

签名一变（ad-hoc 每次构建、或从 ad-hoc 换成证书），TCC 状态重置，**标记还在** → 代码再也不敢问系统 → 又因为没调用采集 API，列表里没有 Marquee → 用户去系统设置也勾不了。

诊断当时看到的就是：`preflight=false` 且状态显示「从未询问过」，但我们已经「问过」了——问的记录是我们自己的，TCC 那边是空白。

**正确做法**：不要把「问过」写到磁盘。进程内记住即可：新进程（含换签名后的新构建）可以再问一次。

### 3.3 只调 `CGRequestScreenCaptureAccess()`，应用不出现在列表里

权限门拦在真正采集之前，避免没权限还盖一层蒙层。但「请求权限」若只调 CoreGraphics 这一句，macOS 不一定把应用登记进「屏幕录制」列表。

用户看到的是：弹了框、去了系统设置、**找不到 Marquee 这一行**，永远走不完授权。

**正确做法**：`requestPermission()` 里必须碰一次采集 API。`SCShareableContent.excludingDesktopWindows(...)` 枚举就够，副作用是「被系统看见」。

从 shell 直接 exec 可执行文件时，TCC 还可能把这次访问算在父进程（终端）头上。要用 LaunchServices 启动（`open -a Marquee.app`），或走 Xcode Run。

### 3.4 一次快捷键叠出多张系统框（最后修掉的）

在 3.3 之上，代码又加了一次真正的 `SCScreenshotManager.captureImage`（2×2，想「更像一次采集」）。macOS 15+ 把**每一次采集尝试**都当成新的授权请求。于是一次 `requestPermission()` 会依次触发：

1. `SCShareableContent` 枚举 → 一张系统框
2. `SCScreenshotManager.captureImage` → 再一张
3. `CGRequestScreenCaptureAccess()` → 可能再一张

同时，探针在 preflight 为 false 时一律报 `.notDetermined`。macOS 15+ 重启前 preflight 一直是 false，所以**每一次快捷键**都再走一遍上面三步。

再叠加：刚授权成功（`CGRequest` 返回 true）后，宿主仍然弹出覆盖层并采集。ScreenCaptureKit 在该进程里还不可用 → 再弹一张框，并且失败。

这就是「点一次快捷键，授权框一直弹」。

---

## 4. 当前设计（必须同时成立）

| 规则 | 为什么 |
| --- | --- |
| 签名由 `project.yml` 负责，禁止 ad-hoc | TCC 要稳定身份；只改构建脚本盖不住 Xcode Run |
| `requestPermission()` 枚举一次 `SCShareableContent`，**不要截帧** | 枚举负责登记进列表；截帧会再弹一张系统框 |
| 随后用 `CGRequestScreenCaptureAccess()` 拿结论 | 同一会话里若枚举已经弹过，这里通常不再弹；被拒绝过的进程再调它不弹框、返回 false |
| 「已经问过」只记在**进程内** | 避免 UserDefaults 把换签名后的用户锁死 |
| 问过仍未授权 → 报 `.denied`，走「打开系统设置」 | 重启前 preflight 一直是 false，不能再当成 `.notDetermined` |
| 本次进程刚授权成功 → **只提示重启，不弹出覆盖层** | SCK 要等下一个进程才生效；再采集只会再弹框 |
| 启动时只打日志，不弹系统框 | 启动即索权是很讨人厌的行为 |

对应代码：

- `Modules/Sources/MarqueeCapture/SystemScreenRecordingPermission.swift`
- `Modules/Sources/MarqueeCore/CaptureGateRunner.swift`
- `App/Sources/CaptureCoordinator.swift`（刚授权则提示重启）
- `App/Sources/PermissionPrompt.swift`（系统设置 + Finder 中显示）

单测钉死的行为：同一探针在拒绝/同意后再过权限门，`requestCount` 仍为 1（`CaptureGateRunnerPromptOnceTests`）。

---

## 5. 授权后为什么必须重启

这是系统约束，不是我们可以绕过的产品选择。

`CGRequestScreenCaptureAccess()` 返回 `true` 只表示 TCC 已经记下「允许」。ScreenCaptureKit（`SCShareableContent` / `SCScreenshotManager`）要等**下一个进程**才会带上这个决定。在当前进程里继续采集会失败，并且在 15+ 上经常再弹一张系统框。

提示文案必须把「退出并重新打开」说出来，否则用户会以为应用坏了。

---

## 6. 如何验证

### 6.1 签名是否稳定

```bash
codesign -dvvv /path/to/Marquee.app
```

应看到 `flags=0x0(none)`（不是 `0x2(adhoc)`）、`Authority=Apple Development: …`、`TeamIdentifier=UKXWZ3FS84`。

从 **Xcode Run** 与 `./scripts/build.sh` 两条路径都要满足。只修脚本不够。

### 6.2 运行时状态

```bash
open -a Marquee.app --args -marqueeDiagnostics
```

看：运行位置、权限状态、`preflight` 原始值、快捷键、**构建签名身份**。  
「权限为什么留不住」的第一手证据是签名那一行。

主动登记 + 请求（不必等快捷键）：

```bash
open -a Marquee.app --args -marqueeRequestPermission
```

结果写在 `~/Library/Logs/Marquee/permission-probe.txt`（`open` 不会把 stdout 送回终端）。

### 6.3 授权框只应出现一次

1. 完全退出 Marquee。
2. 重新 Run，按截屏快捷键。
3. 系统框最多一张；勾选后按提示退出再打开。
4. 之后按快捷键应直接出覆盖层，不再弹系统框。

若列表里有多个 Marquee（历史 ad-hoc 构建留下的）：

```bash
tccutil reset ScreenCapture com.tango.marquee
```

然后重新走一遍授权。

---

## 7. 仍未完全收口的部分

用户反馈「权限部分解决了」对应下面这些**系统侧或尚未单独验收**的残留：

| 项 | 状态 | 说明 |
| --- | --- | --- |
| 首次勾选后必须重启 | 系统约束，已提示 | 无法在同进程里让 SCK 立刻可用 |
| Apple Development 证书一年一换 | 已知 | 续期后身份变，需再授权一次 |
| 历史 ad-hoc 条目残留 | 需手工清理 | `tccutil reset ScreenCapture com.tango.marquee` |
| 运行中撤销授权再恢复 | ticket 06 | 预检每次触发都会走；撤销后应进引导、不弹主窗口。完整生命周期清单尚未单独验收 |
| macOS 15+ 系统自己的定期提醒 | 系统行为 | 「跳过系统窗口选择器」一类月度提醒不是我们弹的，应用层压不掉 |
| 多份 DerivedData 产物 | 开发环境 | 改名前的旧工程 / 另一份 ad-hoc 产物会让「列表里的 Marquee」对不上正在跑的那份 |

不要为了开发机「不弹窗」而放宽代码里的权限检查。权限路径必须保持真实。

---

## 8. 判断流程（以后再踩时用）

```
preflight == true
  → 本进程已能采集。快捷键应直接出覆盖层。

preflight == false，且本进程还没问过
  → 走 requestPermission（枚举 + CGRequest）。
     返回 true  → 提示重启，不要采集。
     返回 false → 引导系统设置；Finder 中显示，便于手动把 app 拖进列表。

preflight == false，且本进程已经问过
  → 不要再弹系统框。引导系统设置 / 重启。

系统设置里没有 Marquee
  → 先看签名是不是 ad-hoc；再确认是不是从终端直接 exec 的；
     再用 -marqueeRequestPermission 登记一次。
```

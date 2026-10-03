# 32 · 沙盒化改造

- **状态**：🟡 **进行中**（2026-10-03）—— 代码已落地，剩人工验收（见 §3）
- **依赖**：无（**与 29/30/31 并行的一条独立线**）
- **为什么单独一条线**：它改动的是**默认目录与数据位置**，与收费无关；
  混进 StoreKit 那一票里，会把"功能不见了"和"授权没生效"两类问题搅在一起。

---

## 0. 开工时定下的一件事（原票没写）

**沙盒加在哪个配置上。** `Release` 当时是双肩挑：`scripts/package.sh` 用它做
**Developer ID** 导出（`method: developer-id`），而那条"后路"的**全部价值就是保住
自动滚动** —— 沙盒一加就没了。同时 `Dev`（日常 Run 的那个）也会被一起沙盒化，
于是**每天用的构建**失去自动滚动、屏幕录制授权还要重问一遍。

⇒ **新增第四个配置 `MAS`，只有它带沙盒 + hardened runtime。**
`Debug` / `Dev` / `Release` 一律不带。

配套的一条硬规则：**「在不在沙盒里」按运行期判据分派，不按配置** ——
否则同一份代码在两个构建里行为不同，而**没编进去的那条分支只有发版那天才跑得到**。
判据是 `AppIdentity.isSandboxed`（读 `APP_SANDBOX_CONTAINER_ID`），可注入 ⇒ 能脱机单测。

## 1. 要做的事

| # | 项 | 细节 | 状态 |
| --- | --- | --- | --- |
| 1 | `App/Marquee.entitlements` | `app-sandbox` + `files.user-selected.read-write` + `assets.pictures.read-write`。**不勾用不到的项** —— 多勾会被审核问。⚠️ **刻意不勾 `network.client`**：本项目不上传任何东西（StoreKit 的网络由系统进程代劳） | ✅ |
| 2 | `project.yml` | `CODE_SIGN_ENTITLEMENTS` + `ENABLE_HARDENED_RUNTIME: YES` —— **只写在 `MAS` 块里**；bundle id 靠**继承**拿正式 id，不靠人记得 | ✅ |
| 3 | **默认输出目录** | `~/Desktop` → `~/Pictures/Marquee`。⚠️ Apple 的文件访问 entitlement **没有"桌面"这一项**，沙盒下 `⌘S` 会 `Operation not permitted` | ✅ |
| 4 | ~~数据迁移~~ | ❌ **撤销**：沙盒进程**读不到容器外**的 Application Support ⇒ 这件事只能由**非沙盒**构建代劳，或干脆不做。见 §2 第四段 | ✂️ |
| 5 | 自动滚动 | **降级为手动滚动**（沙盒禁止向其它 app 投递输入事件）。入口要**给出解释**，而不是静静地变灰 | ✅ |
| 6 | 沙盒判据 | `AppIdentity.isSandboxed` + `AutoScrollGate`（纯函数，进 Core） | ✅ |
| 7 | 实测 | `-marqueeDemoEditor` 与主流程在沙盒下全绿 | ⏳ **待人工**（§3） |

## 2. 三处解释（写给自己，免得以后有人"顺手放开"）

### 为什么桌面写不进去

Apple 的文件访问 entitlement 是**枚举式的**，只有：
`user-selected` / `Downloads` / `Pictures` / `Music` / `Movies`（外加一个已弃用的 All files）。
**"桌面"不在里面** —— 不是我们没勾，是它不存在。

对策二选一：默认改 `~/Pictures/Marquee`（简单），
或首次让用户选一次目录并存 **security-scoped bookmark**（灵活，但多一次打断）。

### 为什么自动滚动必须砍

Apple 文档《Protecting user data with App Sandbox》的"与沙盒不兼容的行为"清单里有
「**Posting keyboard or mouse events to another app**」，并点名 `CGEventPost`
"therefore not allowed from a sandboxed app"；DTS(Quinn) 另答
"沙盒 app 不能用辅助功能 API，唯一出路是用 Developer ID 分发"。

**手动滚动长截图不受影响** —— 能力一条没少，只是要用户自己滚。

### 为什么迁移**不能在沙盒里做**（2026-10-03 订正）

原票写的是"写一次一次性迁移，把老目录的文件搬进容器"。**这条做不到。**

沙盒进程的家目录就是容器，**读不到容器外的 `~/Library/Application Support/`** ——
要做这件事需要"容器外的读权限"，而那正是沙盒不给的东西。

所以只剩两种可能：

1. **不做**（本项目的选择）。路线 B 下 MAS 版是**首发**，用户从来没跑过非沙盒版本，
   容器里本来就是空的 —— 不存在"老数据"这回事。
2. **由非沙盒构建代劳**：只在"Developer ID 版先发过、之后用户改从 MAS 安装"
   这条路上才需要。那时可以先发一版 Developer ID 的迁移构建把事情做掉。

⚠️ 顺带订正原票另一处：**偏好根本不在 Application Support**
（在 `~/Library/Preferences/<bundle id>.plist`），而且沙盒内同样读不回。

## 3. 验收

> ⚠️ **沙盒构建只能在 `open` 下启动，不能在终端里直接跑** —— 在沙盒进程之下起沙盒 app，
> `libsecinit` 装不上自己的沙盒，**SIGTRAP 崩在 `main` 之前、一行输出都没有**
> （`docs/PITFALLS.md` 143）。所以自检报告一律落文件。

完整清单见 **`docs/STATUS-AND-ACCEPTANCE.md` 的 AA1–AA8**（沙盒构建下的自查）。
正式验收是 **AA8**：把那份清单的 A–Z 组在**沙盒构建**下重跑一遍。

重点盯两条：

- **AA2 / AA4**：默认落盘真的是 `~/Pictures/Marquee` —— **不是桌面、也不是容器里的
  Pictures**。后者会让图存到用户永远找不到的地方，而 `⌘S` 显示"成功"。
- **AA5**：沙盒下按 `空格` 时，那句话里**不许出现「辅助功能」** ——
  出现了就是把用户支去干一件注定没用的事。

⚠️ 沙盒构建**会重新问一遍屏幕录制授权**（身份与沙盒状态都变了）—— 预期行为。

## 4. 风险

- **TCC 授权会重新问一遍**（bundle 的身份变了）—— 预期行为，但要在帮助文档里说清。
- **硬运行时（hardened runtime）打开后要重新验所有能力** —— 尤其是截图与 OCR 这类
  需要系统资源的部分。别把它当成"只是加了一行配置"。

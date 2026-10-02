# 32 · 沙盒化改造

- **状态**：⏳ 待开工
- **依赖**：无（**与 29/30/31 并行的一条独立线**）
- **为什么单独一条线**：它改动的是**默认目录与数据位置**，与收费无关；
  混进 StoreKit 那一票里，会把"功能不见了"和"授权没生效"两类问题搅在一起。

---

## 1. 要做的事

| # | 项 | 细节 |
| --- | --- | --- |
| 1 | `App/Marquee.entitlements` | `com.apple.security.app-sandbox` + `files.user-selected.read-write` + `assets.pictures.read-write`（默认存 Pictures 才需要）。**不勾用不到的项** —— 多勾会被审核问 |
| 2 | `project.yml` | `CODE_SIGN_ENTITLEMENTS`；MAS 构建要 `ENABLE_HARDENED_RUNTIME: YES`（现在是 NO） |
| 3 | **默认输出目录** | 从 `~/Desktop` 改 `~/Pictures/Marquee`。⚠️ Apple 的文件访问 entitlement **没有"桌面"这一项**，沙盒下 `⌘S` 会 `Operation not permitted` |
| 4 | 数据迁移 | 最近截图仓库与偏好从 `~/Library/Application Support/…` 变到容器内 —— **一次性迁移**，否则老用户"历史全没了" |
| 5 | 自动滚动 | **降级为手动滚动**（沙盒禁止向其它 app 投递输入事件）。入口要给出解释，而不是静静地变灰 |
| 6 | 实测 | `-marqueeDemoEditor` 与主流程在沙盒下全绿 |

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

### 为什么数据迁移不能省

容器路径是 `~/Library/Containers/dev.tango.Marquee/Data/…`。
老用户的 `~/Library/Application Support/dev.tango.Marquee/` 不会自动搬过去 ——
不写迁移的话，升级之后"最近截图"是空的，而用户会认为**我们把他的东西弄丢了**。

## 3. 验收

- 沙盒构建下：截图 / 标注 / 剪贴板 / 钉图 / OCR / 长截图（手动）/ 偏好设置 / 快捷键
  **逐项跑一遍**（就是 `docs/STATUS-AND-ACCEPTANCE.md` 那份清单，在沙盒构建下重跑）。
- 老数据迁移：先在有数据的机器上装旧版、再装沙盒版，确认历史还在。
- `⌘S` 落盘落在 `~/Pictures/Marquee`，且 Finder 里能看到。

## 4. 风险

- **TCC 授权会重新问一遍**（bundle 的身份变了）—— 预期行为，但要在帮助文档里说清。
- **硬运行时（hardened runtime）打开后要重新验所有能力** —— 尤其是截图与 OCR 这类
  需要系统资源的部分。别把它当成"只是加了一行配置"。

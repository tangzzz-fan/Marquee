# 17b: 本地化（简体中文 / 英文）

**What to build:** 把面向用户的文案从硬编码中文换成可切换的语言资源，补齐英文，
跟随系统语言自动切换；并有一条**扫描测试**防止后续新增文案漏翻译。

> 从原 ticket 17 拆出（2026-10-01）。玻璃视觉见 `17a-liquid-glass.md`。

**Blocked by:** 07、15

**Status:** ✅ done（2026-10-02）

## 做出来的东西

| 决策 | 值 |
| --- | --- |
| 资源放哪 | **只有一份** `App/Resources/Localizable.xcstrings`。App 是唯一宿主、6 个模块都静态链进它 ⇒ 全模块统一查 `Bundle.main`。反过来（每模块一份 catalog + `Bundle.module`）要改 4 个 `Package.swift`、维护 4 份 catalog，收益为零 |
| 工程接线 | `project.yml` 用 `- path: App/Resources` + `buildPhase: resources` **显式列出**，不走 `syncedFolder` —— 同步组里的 `.xcstrings` 是不是稳当进 Resources 阶段没人能替我验证（本机跑不了 xcodebuild），显式声明就把归类钉在生成工程那一刻。另加 `options.developmentLanguage: zh-Hans` |
| key 用什么 | **中文原句**（`L10n.t("矩形")`）。省掉 188 个自造 key，diff 里"这行改了什么"一眼可见 |
| 漏翻会怎样 | `String(localized:)` **回落到 key 本身**（＝中文），不是把 key 显示给用户。于是迁移可以一片一片来，中间态永远可用 |
| 插值怎么办 | `L10n.t` 收 `String.LocalizationValue`，插值由编译器记进 key。**绝不能**写成 `L10n.t("已复制 " + text)` 或先插值再传 `String` —— 查表用的是渲染后的串，catalog 永远匹配不上，**英文用户照样看到中文**，不崩不报错 |
| 不翻的部分 | 日志（`logger` / `print`）、断言（`fatalError` / `preconditionFailure`）、`DateFormatter` 格式串、手势档位名、`-marqueeDiagnostics` 报告。用 `// L10N-EXEMPT[-START/-END]: 理由` 标记声明，**必须写理由**（测试会检查成对与非空） |
| 覆盖范围 | 生产代码 **197 处 / 188 个 key**（25 个文件），英文逐条写完 |

## 关于格式说明符（这一条是实测的，不要靠记忆）

`String.LocalizationValue` 的插值由编译器按**类型**选说明符。写 catalog 时必须逐字对上，
否则就是「查不到 → 回落中文」。用一次性探针实测（`/tmp/l10nprobe`）的结果：

| 表达式类型 | 说明符 |
| --- | --- |
| `Int` / `Int64` / `Array.count` | `%lld` |
| `Int32` / `OSStatus` | `%d` |
| `UInt32` / `UInt8`（如 `CGDirectDisplayID`） | `%u` |
| `String` | `%@` |
| `Double` / `CGFloat` | `%lf` |
| `Float` | `%f` |

摸不清的几条是**去读声明**定下来的，不是猜的：
`RecentCapturesPanelController` 的 `size` 是拼好的 `String` → `%@`；
`ShortcutService` 的 `status` 是 `Int32` → `%d`；`ScreenCaptureKitCapturer` 的 `id` 是 `UInt32` → `%u`。

> 探针本身也顺手证明了**整条链路是通的**：`xcstringstool compile` 出来的
> `en.lproj/Localizable.strings` 放进一个自造 bundle 后，`String(localized:bundle:)` 确实能查到。

## 扫描测试（验收项 4/5）

`Modules/Tests/MarqueeCoreTests/LocalizationScanTests.swift`，6 条：

1. 生产代码里没有未本地化的中文字面量
2. 源码用到的每个 key 都在 catalog 里
3. catalog 里没有源码找不到的孤儿 key
4. catalog 每条都有非空英文
5. 豁免区必须成对且带理由
6. **扫描器自检**：认得出中文字面量、`\(…)` 插值、注释与豁免 ——
   没有这条，一个"什么都扫不到"的扫描器会让上面四条**全绿**

## 变异测试（断言没空跑的证据）

| 变异 | 结果 |
| --- | --- |
| 把 `L10n.t("通用")` 退回裸 `"通用"` | ✘「没有未本地化的中文字面量」变红 ✔，同时 ✘「没有孤儿 key」也变红 ✔ |
| 恢复 | 两条都转绿 ✔ |

## 实现记录（踩过的坑都在这）

- **key 抽取的两个坑**：`\(String(format: "%.2f", x))` 这种插值里**嵌套了字符串字面量**，
  朴素的正则会在内层引号处把字面量截断；`"...。\n请到..."` 里的 `\n` 在源码里是两个字符、
  运行时是一个换行 —— 抽取时必须**反转义**，否则 key 与运行时永远差一点。
- **扫描器的行号会漂**：多行字面量里的**行继续**（`\` 结尾换行）也是一个换行，漏计一次
  后面所有行号整体前移 —— 而"报错的行号指向别的行"会让每一条诊断都变成误导（PITFALLS 95）。
- **keys 那一趟不能看行标记**：`logger.info("…\(L10n.t("…"))")` 这种行里包过的 key 是算数的，
  跟着行标记一起跳过会让它变成"孤儿"然后误报（PITFALLS 96）。
- `App/Sources` 里 4 处 `fatalError("…只支持代码创建")` 与所有 `logger.*` 都按规则跳过，
  没有一条豁免是"因为懒得写理由"。
- 顺带修了一处**用户可见的 bug**：权限弹窗的说明文字里带着 Markdown 的 `**`，
  而 `NSAlert` 不认 —— 用户会原样看到两个星号。迁移时去掉了。

## 以后新增文案怎么写

1. 把中文原句包成 `L10n.t("…")`（**插值直接写在字面量里**，不要自己拼字符串）
2. 往 `App/Resources/Localizable.xcstrings` 的 `strings` 里加一条，`en` 的 `value` 写英文
   —— 说明符要与源码的类型对上（见上表）
3. `./scripts/test.sh` 会替你检查：漏包、漏翻、孤儿、没写理由的豁免，一律变红

## Acceptance criteria

- [x] 简体中文与英文完整覆盖所有面向用户的文案（188 个 key 全部有英文）
- [x] 英文环境下不再出现中文（插值串的说明符逐个核过；见上表）
- [x] 有一份"硬编码字符串扫描"检查（测试），新增文案漏翻译会**变红**
- [x] 扫描测试同时校验 catalog 的 en 完整性（缺 en → 红；目录里有孤儿 → 红）
- [x] 文档里写了"新增文案该怎么写"（本票 + README）
- [ ] **人工**：把系统语言切到 English 跑一遍五处界面（菜单栏 / 偏好设置 / 覆盖层工具条与提示 / 权限弹窗 / 最近截图），确认没有中文残留
- [ ] **人工**：切回中文，确认与迁移前逐字一致

> ⚠️ 人工那两条我做不了（要换系统语言并重启应用）。切完把问题贴回来。

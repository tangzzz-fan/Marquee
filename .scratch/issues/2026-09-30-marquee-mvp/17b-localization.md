# 17b: 本地化（简体中文 / 英文）

**What to build:** 把面向用户的文案从硬编码中文换成可切换的语言资源，补齐英文，
跟随系统语言自动切换；并有一条**扫描测试**防止后续新增文案漏翻译。

> 从原 ticket 17 拆出（2026-10-01）。玻璃视觉见 `17a-liquid-glass.md`。
>
> ⚠️ **这一票不要"顺手包一层就完"** —— 下面第 3 条是最容易踩的坑，
> 它**不崩不报错**，只是英文用户看到中文。

**Blocked by:** 07、15

**Status:** ready-for-agent

## 开工前必须知道的现状（已勘查完，不要再重新查）

| 项 | 现状 |
| --- | --- |
| 已有本地化设施 | **完全没有**：无 `.xcstrings` / `.strings` / `.lproj`，无 `NSLocalizedString`，无 `String(localized:)` |
| `project.yml` | 没有 `knownRegions` / `developmentLanguage`；`App/Sources` 是 **`syncedFolder`**（放 `.xcstrings` 会被自动纳入，不必改工程文件） |
| SPM 模块 | `Package.swift` 里 6 个 target **都没有 `resources:`**，全仓 **0 处 `Bundle.module`** |
| 面向用户的硬编码中文（排除 os_log） | **220 处 / 205 个唯一串**，分布在 25 个文件 |
| 其中最集中的 4 个文件 | `SelectionOverlayController` 63 · `AnnotationEditorWindow` 34 · `PreferencesWindowController` 32 · `ScrollCaptureSession` 14 |
| **带字符串插值的** | **40 处** —— 全部不能直接当 key 用（见下） |
| `App/Info.plist` | `CFBundleDevelopmentRegion = zh_CN` |
| 现有的扫描类测试 | **没有先例**，需自建（仓内只有临时目录写读那类） |

## 三个必须先定下来的决定

### 1. 资源放哪、谁负责查

App 是唯一宿主，6 个模块都静态链进它 → **catalog 只有一份，放 `App/Sources/Localizable.xcstrings`**，
所有模块统一查 `Bundle.main`。反过来（每个模块一份 catalog + `Bundle.module`）要改 4 个
`Package.swift` 加 `resources:`，并且维护 4 份 catalog —— 收益为零。

Core 提供一个薄入口吸收"用哪个 bundle"这件事：

```swift
public enum L10n {
    public static let bundle: Bundle = .main
    public static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: bundle, value: key, comment: "")
    }
}
```

`value: key` 是**刻意的**：源语言就是中文，所以"catalog 里没有这一条"退化成"显示中文"，
**不会变成显示 key**。于是迁移可以一片一片来，中间态永远是可用的。

### 2. key 用什么

**用中文原句当 key**（`L10n.t("矩形")`）。这是"开发语言＝源语言"的标准模型，
省掉 205 个自造 key，也让 diff 里"这行改了什么"一眼可见。
代价：`en` 那一列必须逐条写，漏了就是中文（所以第 5 条的扫描测试必须覆盖 catalog 的完整性，不只是源码）。

### 3. ⚠️ 40 处插值串**不能**直接包

```swift
L10n.t("已复制 \(text)")     // ✗ 错：查表用的是**渲染后**的串（"已复制 #FF0000"），
                            //    catalog 里永远匹配不上 → 英文环境照样显示中文
String(format: L10n.t("已复制 %@"), text)   // ✓ 对
```

`String(format:)` 的说明符必须和实参类型对上（`%@` 给 `String`、`%lld` 给 `Int`、
`%d` 给 `Int32`/`OSStatus`、`%.0f` 给 `Double`）。**对错了不报错，只是数字乱掉或崩**。
40 处的类型要逐条看，这是这一票主要的手工量。

### 4. core 里的错误信息算不算用户可见

`ScreenshotArchiver` / `ScrollCaptureSession` / `ShortcutService` 里那些
`"保存失败：\(…) 里同名文件太多"` **是**发给用户看的（走 alert / 读数框），要翻。
而 `CaptureCoordinator` 里的 `logger.info("…")`（45 处的多数字）**不是**，不要翻 ——
日志保持中文反而对排查有利。

## Acceptance criteria

- [ ] 简体中文与英文完整覆盖所有面向用户的文案，无硬编码字符串残留
- [ ] 切换系统语言后界面语言随之改变（中文系统看中文、英文系统看英文）
- [ ] 40 处插值串全部改成 `String(format:)` 形态，英文环境下**不再出现中文**
- [ ] 有一份"硬编码字符串扫描"检查（测试），新增文案漏翻译会**变红**
- [ ] 扫描测试同时校验 catalog 的 `en` 完整性（源码有 key 但 catalog 缺 en → 红）
- [ ] `docs/` 里记下"新增文案该怎么写"（一条 `L10n.t` + 补 catalog 的 en）

## 建议的推进顺序（每步都能单独提交、单独验证）

1. **机制**：`L10n` + 空 catalog + `project.yml` 的 `developmentLanguage: zh-Hans` /
   `knownRegions`，跑一次 `./scripts/build.sh` 确认 catalog 真的被编进了 `.app`
   （查 `Marquee.app/Contents/Resources/zh-Hans.lproj/Localizable.strings`）——
   **先验通这一步**，否则后面 165 处白包
2. **App 层**：菜单栏 5 · 偏好设置 32 · 权限提示 8 · 最近截图 9（含 4 处插值）
3. **覆盖层**：`SelectionOverlayController` 的提示行与 `PinWindow` 的 tooltip
4. **其余模块**：`AnnotationEditorWindow` 34 · `ScrollCaptureSession` 14 · `AutoScroll` 10 ·
   `ShortcutValidation` 13 · `TextRecognition` 5 · 其余零星
5. **扫描测试**：源码 key ↔ catalog 双向校验 + 新增硬编码中文检测（`os_log` 白名单）
6. **排一遍**：`defaults write -g AppleLanguages -array en-US`（或临时改 `Bundle` 注入），
   肉眼过一遍五处界面

## 已知会遇到的坑

- `enum` 的**裸值**不能包（`case rectangle = "矩形"` 是编译期字面量），扫描/替换脚本要跳过
- 测试文件里的中文（全仓 1230 处 / 61 文件，含 34 个测试文件）**不是**文案，扫描要排除 `Modules/Tests/`
- `"M月d日 HH:mm"` 这种是 `DateFormatter` 的格式串，应该走
  `DateFormatter.dateFormat(fromTemplate:options:locale:)` 而不是当文案翻译
- `App/Sources/EditorDemo.swift` 与 `CaptureCoordinator` 里那些自检/探针输出（`"✅ 已授权…"`）
  不是用户界面，列进白名单

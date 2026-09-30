# 02: 全屏截图直达剪贴板

**What to build:** 在任意应用里按下快捷键，当前显示器整屏截图立刻进入剪贴板，切到聊天窗口 `⌘V` 就能粘贴出**清晰度正确的**图。屏幕录制权限未授予时，不静默失败，而是给出可操作的说明并一键跳到系统设置对应面板。同时提供一个**最小可用的快捷键更换入口**（改键 / 冲突提示 / 恢复默认 / 立即生效，无需重启）。

> **默认键已从 `⌃⌘A` 改为 `⌃Q`（2026-09-30，用户指定）。**
> 原因：本机实测 `⌃⌘A` 已被**微信**（其截图快捷键）**独占**注册。
> 补充一个 Carbon 的坑：**非独占注册永远返回成功**，所以这种情况既收不到事件、也不报错。
> 详见下方「快捷键冲突的真实行为」与 `docs/DEV-NOTES.md` 第 1 节。

这是整个技术栈的**第一条端到端路径**：全局快捷键 → TCC 权限门 → ScreenCaptureKit 采集 → PNG 编码 → 剪贴板。没有覆盖层、没有选区，刻意做窄，目的是尽早暴露"权限 / 采集 / 编码 / 剪贴板"这四层的真实约束。

**Blocked by:** 01

**Status:** 已实现，待人工验收（2026-09-30）

## 快捷键冲突的真实行为（本机实测，2026-09-30）

| 场景 | `RegisterEventHotKey` 返回值 | 含义 |
| --- | --- | --- |
| 非独占注册，无论是否被占 | **永远是 0** | 静默成功 —— 光看它发现不了冲突 |
| 独占注册，同进程内已有自己的注册 | **-9878** | 必须先 `unregister()` 再探测 |
| 独占注册，**别的进程独占**占着该组合 | **-9878** | 这才是可用的冲突探测手段 |
| 独占注册，别的进程只是**非独占**占着（跨进程） | **0** | ⚠️ 探测**无效**；此时双方都会收到事件（"两个 app 一起响应"） |

结论：`probeAvailability`（独占试注册后立刻注销）能覆盖"被别的应用独占占用"这一类（微信就是这种），
但覆盖不了"别的应用非独占并存"。后者只能靠**用户改键**解决，这也是「快捷键…」面板必须存在的原因。

## 已提前验证的结论（直接用，不要重新试）

- 全局快捷键用 Carbon `RegisterEventHotKey`，**不需要辅助功能权限**；重复注册返回 `-9878` 可用于冲突检测（`docs/SPIKE-PLAN.md` G1/G2）
- 不要用 `NSEvent.addGlobalMonitorForEvents`：它返回非 nil 也不代表能收到事件，强依赖输入监控权限
- 权限预检用 `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`
- 剪贴板写**原始 PNG 数据**（`NSPasteboard` 的 `.png` 类型），不要写 `NSImage` 往返（`docs/SPIKE-PLAN.md` F2/F3）
- 采集走 `SCScreenshotManager` 的 async API

## 实现要点（落地后回填）

| 关注点 | 落点 |
| --- | --- |
| 权限三态（granted / denied / notDetermined） | `MarqueeCore.ScreenRecordingPermission`。`CGPreflightScreenCaptureAccess()` 只有布尔，**区分不了"没问过"和"被拒绝"**，用 UserDefaults 记一次"请求过"的痕迹补齐 |
| 权限门 | `MarqueeCore.CaptureGate.decision(for:)` —— 唯一能自动化验证的关键判定 |
| 采集编排 | `MarqueeCore.FullScreenCaptureFlow`（接缝注入，可脱机单测） |
| 采集实现 | `MarqueeCapture.ScreenCaptureKitCapturer`，用 `captureImage(contentFilter:configuration:)`（14.0+），排除本进程窗口，`width/height` 显式设为 点×scale |
| 快捷键 | `MarqueeSettings.CarbonGlobalHotKey` + `MarqueeCore.ShortcutService`（校验 → 试注册 → 成功才落盘，失败回滚） |
| 偏好存储 | `MarqueeCore.UserDefaultsShortcutStore`（JSON，键 `shortcut.fullScreenCapture`） |
| 更换入口 | 菜单栏「快捷键…」→ 快捷键录制控件（`ShortcutRecorderView`），即时生效无需重启 |
| 权限引导 | `App/PermissionPrompt.swift`，一键打开 `Privacy_ScreenCapture` 面板 |

## Acceptance criteria

### 自动化已验证

- [x] 至少一条自动化测试覆盖"权限状态 → 该走哪条分支"的判定逻辑（用可注入的权限探针，不依赖真实 TCC）—— 共 **104 个测试 / 20 suite 全绿**
- [x] 权限没过时**绝不静默**：三个分支各有断言（`denied` 时连系统请求框都不该弹、且不采集、不写剪贴板）
- [x] 写入剪贴板的是**原始 PNG**（魔数校验 `89 50 4E 47`），不是 NSImage/TIFF 往返
- [x] 改键：合法组合落盘并重新注册；非法组合被拦下且不碰系统；注册冲突时**回滚到旧键**且不落盘
- [x] 冲突**探测**：先注销自己 → 独占试注册 → 被占则不注册直接报占用；非法组合不做探测
- [x] 变异测试确认非空跑：把 `.denied` 的分支改错、把 ⌘ 的修饰位改成 Caps Lock 位，共 4 个测试转红
- [x] **端到端**（对真实 Carbon API，非替身）：把已存快捷键设成被微信独占占用的 `⌃⌘A` 后启动，
      应用报「已被其他应用占用」而不是静默注册 —— 用 `Marquee -marqueeDiagnostics` 核对过

### 待人工验收

> ⚠️ ticket 03 落地后，**入口已经变了**：菜单「截屏」与 `⌃Q` 现在打开选区覆盖层，
> 不再是"直接整屏"。下面前两条因此被 ticket 03 的验收取代（整屏改为覆盖层内 `⏎`/双击）。
> 剩下的权限与耗时两条仍然有效。

- [x] ~~应用启动后按快捷键，无任何额外系统确认，剪贴板内容变为当前显示器整屏 PNG~~ → 由 ticket 03 取代
- [x] ~~粘贴到预览/备忘录，图片尺寸 = 显示器物理像素（Retina 下是 2x）~~ → 由 ticket 03 取代（`FullScreenCaptureFlowTests` 已断言 2880×1800）
- [ ] 权限未授予时按 `⌃Q` 看到明确说明 + "打开系统设置"按钮，且按钮直达屏幕录制面板
- [ ] **授权引导能走通**：首次按下后 macOS 把 Marquee 登记进「屏幕录制」列表（此前列表里根本没有它 → 用户无从授权）。
      提示框里的「在 Finder 中显示」能打开 app 所在位置，便于手动添加
- [ ] **签名稳定**：`codesign -dvvv` 显示 `flags=0x0(none)` + `TeamIdentifier=UKXWZ3FS84`；
      从 **Xcode Run** 与 `./scripts/build.sh` 两条路径构建出的产物都是证书签名（不能只修脚本 —— Xcode Run 不执行脚本）
- [ ] **授权后重启应用**，之后重新构建**不再**要求授权
- [ ] **耗时实测记录**：按下快捷键 → 剪贴板可用；目标 ≤ 150 ms。日志在 `dev.tango.Marquee` / `capture`（形如"截图完成：2880×1800 px，… 耗时 x ms"）
- [ ] 热键**实际触发**（SPIKE G3 / M20：注册成功 ≠ 触发成功）—— `⌃Q` 已用 `-marqueeDiagnostics` 确认注册成功
- [ ] 换键后立即可用（改完直接按新键，不重启）；把新键设成别的应用已占用的组合时看到冲突提示
- [ ] 截图内**不含**本进程窗口（SPIKE M6）

# 02: 全屏截图直达剪贴板

**What to build:** 在任意应用里按下 `⌃⌘A`，当前显示器整屏截图立刻进入剪贴板，切到聊天窗口 `⌘V` 就能粘贴出**清晰度正确的**图。屏幕录制权限未授予时，不静默失败，而是给出可操作的说明并一键跳到系统设置对应面板。同时提供一个**最小可用的快捷键更换入口**（改键 / 冲突提示 / 恢复默认 / 立即生效，无需重启）。

这是整个技术栈的**第一条端到端路径**：全局快捷键 → TCC 权限门 → ScreenCaptureKit 采集 → PNG 编码 → 剪贴板。没有覆盖层、没有选区，刻意做窄，目的是尽早暴露"权限 / 采集 / 编码 / 剪贴板"这四层的真实约束。

**Blocked by:** 01

**Status:** 已实现，待人工验收（2026-09-30）

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

- [x] 至少一条自动化测试覆盖"权限状态 → 该走哪条分支"的判定逻辑（用可注入的权限探针，不依赖真实 TCC）—— 共 **61 个测试 / 13 suite 全绿**
- [x] 权限没过时**绝不静默**：三个分支各有断言（`denied` 时连系统请求框都不该弹、且不采集、不写剪贴板）
- [x] 写入剪贴板的是**原始 PNG**（魔数校验 `89 50 4E 47`），不是 NSImage/TIFF 往返
- [x] 改键：合法组合落盘并重新注册；非法组合被拦下且不碰系统；注册冲突时**回滚到旧键**且不落盘
- [x] 变异测试确认非空跑：把 `.denied` 的分支改错、把 ⌘ 的修饰位改成 Caps Lock 位，共 4 个测试转红

### 待人工验收

- [ ] 应用启动后按 `⌃⌘A`，无任何额外系统确认，剪贴板内容变为当前显示器整屏 PNG
- [ ] 粘贴到预览/备忘录，图片尺寸 = 显示器物理像素（Retina 下是 2x）
- [ ] 权限未授予时按 `⌃⌘A` 看到明确说明 + "打开系统设置"按钮，且按钮直达屏幕录制面板
- [ ] 授权后（需重启应用）再次触发可正常工作
- [ ] **耗时实测记录**：按下快捷键 → 剪贴板可用；目标 ≤ 150 ms。日志在 `dev.tango.Marquee` / `capture`（形如"全屏截图完成：2880×1800 px，… 耗时 x ms"）
- [ ] 热键**实际触发**（SPIKE G3 / M20：注册成功 ≠ 触发成功）
- [ ] 换键后立即可用（改完直接按新键，不重启）；把新键设成别的应用已占用的组合时看到冲突提示
- [ ] 截图内**不含**本进程窗口（SPIKE M6）

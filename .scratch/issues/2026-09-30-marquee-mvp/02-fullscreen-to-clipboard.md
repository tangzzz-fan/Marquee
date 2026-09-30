# 02: 全屏截图直达剪贴板

**What to build:** 在任意应用里按下 `⌃⌘A`，当前显示器整屏截图立刻进入剪贴板，切到聊天窗口 `⌘V` 就能粘贴出**清晰度正确的**图。屏幕录制权限未授予时，不静默失败，而是给出可操作的说明并一键跳到系统设置对应面板。

这是整个技术栈的**第一条端到端路径**：全局快捷键 → TCC 权限门 → ScreenCaptureKit 采集 → PNG 编码 → 剪贴板。没有覆盖层、没有选区，刻意做窄，目的是尽早暴露"权限 / 采集 / 编码 / 剪贴板"这四层的真实约束。

**Blocked by:** 01

**Status:** ready-for-agent

## 已提前验证的结论（直接用，不要重新试）

- 全局快捷键用 Carbon `RegisterEventHotKey`，**不需要辅助功能权限**；重复注册返回 `-9878` 可用于冲突检测（`docs/SPIKE-PLAN.md` G1/G2）
- 不要用 `NSEvent.addGlobalMonitorForEvents`：它返回非 nil 也不代表能收到事件，强依赖输入监控权限
- 权限预检用 `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`
- 剪贴板写**原始 PNG 数据**（`NSPasteboard` 的 `.png` 类型），不要写 `NSImage` 往返（`docs/SPIKE-PLAN.md` F2/F3）
- 采集走 `SCScreenshotManager` 的 async API

## Acceptance criteria

- [ ] 应用启动后按 `⌃⌘A`，系统不弹任何额外确认，剪贴板内容变为当前显示器整屏 PNG
- [ ] 粘贴到任意支持图片的应用（如预览、备忘录），图片尺寸 = 显示器物理像素（Retina 下为 2x，不是 1x）
- [ ] 首次运行且未授权时，按下快捷键会看到明确的权限说明与"打开系统设置"按钮，而不是静默无反应
- [ ] 点击"打开系统设置"能直达屏幕录制面板
- [ ] 权限授予后再次触发可正常工作（若系统要求重启，给出明确提示）
- [ ] 采集耗时（按下快捷键 → 剪贴板可用）实测记录，目标 ≤ 150 ms；若超标，记录真实数值
- [ ] 至少一条自动化测试覆盖"权限状态 → 该走哪条分支"的判定逻辑（用可注入的权限探针，不依赖真实 TCC）

# Marquee · Ticket 索引

**日期**: 2026-09-30
**仓库**: `/Users/tango/Developments/Snipo`（远端未配置 → 本地 markdown tracker）
**方法论**: Matt Pocock `to-tickets`（tracer-bullet 垂直切片 + 阻塞边）
**输入**: `docs/PRD.md` v0.2、`docs/RENDER-BENCH.md`、`docs/SPIKE-PLAN.md`

---

## 1. 切片原则

每条 ticket 是一条**窄而完整**的路径，穿过所有层（采集 / 覆盖层 / 编辑器 / 输出 / 测试），落地即可独立演示。**不做横向切片**（不允许出现"先做完所有权限逻辑"这类票）。

- 无阻塞边 → 可立即开工
- 每条 ticket 的验收标准必须是**可运行验证**的，不是"代码写完"
- 已提前验证的技术结论（见 `docs/SPIKE-PLAN.md`）作为实现约束写进对应 ticket，不再重复验证

## 2. 全量总览

| # | Ticket | 阻塞于 | 交付的可演示行为 |
| --- | --- | --- | --- |
| 01 | 工程骨架与可启动的菜单栏应用 | 无 | 应用启动、菜单栏有图标、`swift test` 绿 |
| 02 | 全屏截图直达剪贴板 | 01 | 按 ⌃⌘A，全屏图已在剪贴板可直接粘贴 |
| 03 | 选区覆盖层：拖拽选区并截取 | 02 | 拉出蒙层、拖框、松开即得选区图（像素精确） |
| 04 | 窗口识别与悬停高亮 | 03 | 悬停高亮整窗，单击得干净窗口图（`⌥` 去阴影） |
| 05 | 保存到磁盘与输出策略 | 03 | `⌘S` 按模板落盘，PNG/JPEG/HEIC 可选 |
| 06 | 权限生命周期与手工验收回归 | 02 | 撤销授权后路径正确、不弹主窗口；20 项手工清单可执行 |
| 07 | 编辑器与标注对象模型 | 03 | 画矩形、再选中移动改色、`⌘Z` 撤销、Esc 复制 |
| 08 | 文字 / 箭头 / 画笔 / 序号标注 | 07 | 四类标注齐备且均可反复编辑 |
| 09 | 马赛克与毛玻璃模糊 + 裁切 | 07 | 打码后导出，原图可用 `⌘Z` 还原 |
| 10 | 放大镜与像素取色 | 03 | 选区时 ⌥ 显示放大区域与 HEX 色值并复制 |
| 11 | 滚动截屏 MVP（手动滚动） | 04, 07 | 滚一段，得到无缝长图并在编辑器打开 |
| 12 | 滚动截屏完整版（自动滚动） | 11 | 点一下自动滚完并拼好；失败有明确提示 |
| 13 | OCR 文字识别 | 07 | 一键提取文本，可框选复制；无 25 秒卡死 |
| 14 | 钉图（Pin） | 07 | 截图钉在屏幕最上层，可缩放/穿透/关闭 |
| 15 | 偏好设置四页与快捷键配置 | 02, 05 | 全部偏好落盘生效；快捷键冲突有提示 |
| 16 | 最近截图面板 | 05 | 菜单栏列出最近 N 张，可复制/删除/重编辑 |
| 17 | Liquid Glass 视觉与本地化 | 07, 15 | 26+ 用玻璃效果，15.x 优雅降级；中英双语 |
| 18 | 打包签名公证与更新机制 | 17 | 出可交付安装包，首次启动通过 Gatekeeper |

**前沿（可并行开工）**：`01` 已完成。`02` 解锁，可立即开工。

## 2.1 进度

| # | Ticket | 状态 |
| --- | --- | --- |
| 01 | 工程骨架与可启动的菜单栏应用 | ✅ done (2026-09-30) |
| 02–18 | 其余 | ⏳ ready-for-agent（阻塞边未满足的除外） |

## 3. 关键路径

```
01 → 02 → 03 → 07 → 11 → 12        （最长链，滚动截屏收口）
            ↘ 04 ↗
```

## 4. 文件 → Ticket 映射

| 文件 | Ticket |
| --- | --- |
| `01-skeleton-menubar-app.md` | 工程骨架与可启动的菜单栏应用 |
| `02-fullscreen-to-clipboard.md` | 全屏截图直达剪贴板 |
| `03-region-overlay-selection.md` | 选区覆盖层 |
| `04-window-recognition-highlight.md` | 窗口识别与悬停高亮 |
| `05-save-to-disk-output-policy.md` | 保存到磁盘与输出策略 |
| `06-permission-lifecycle-manual-regression.md` | 权限生命周期与手工验收回归 |
| `07-editor-annotation-object-model.md` | 编辑器与标注对象模型 |
| `08-text-arrow-pen-counter.md` | 文字 / 箭头 / 画笔 / 序号标注 |
| `09-mosaic-blur-crop.md` | 马赛克与毛玻璃模糊 + 裁切 |
| `10-magnifier-color-picker.md` | 放大镜与像素取色 |
| `11-scroll-capture-mvp.md` | 滚动截屏 MVP |
| `12-scroll-capture-auto.md` | 滚动截屏完整版 |
| `13-ocr.md` | OCR 文字识别 |
| `14-pin-window.md` | 钉图 |
| `15-preferences-shortcuts.md` | 偏好设置与快捷键 |
| `16-recent-captures-panel.md` | 最近截图面板 |
| `17-liquid-glass-localization.md` | 视觉与本地化 |
| `18-signing-notarization-update.md` | 打包签名公证 |

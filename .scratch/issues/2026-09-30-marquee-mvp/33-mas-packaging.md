# 33 · MAS 打包与提审路线

- **状态**：⏳ 待开工
- **依赖**：`32`
- **交付的可演示行为**：`archive → exportArchive(app-store) → 上传` 跑通一次，
  至少过一次 TestFlight / 内部测试。

---

## 1. 要做的事

| # | 项 |
| --- | --- |
| 1 | 打包脚本加一条 **MAS 路线**（现有 `scripts/package.sh` 是 Developer ID 的七步：归档 → 导出 → 签名核验 → DMG → 签 DMG → 公证 → 装订，与 MAS 完全不同） |
| 2 | `xcodebuild archive` → `xcodebuild -exportArchive -exportOptionsPlist`（`method: app-store`）→ 上传（`xcrun altool` / Transporter） |
| 3 | 上传前**预检**：`xcrun altool --validate-app` 或 `iTMSTransporter` 的 verify，避免"传了半小时才报错" |
| 4 | 在 App Store Connect 建商品（与 ticket 31 的 id 一致） |
| 5 | 上架材料：**隐私标签**（可以答"不采集任何数据" —— 这是我们相对竞品的优势）· 审核备注（一句解释为什么需要屏幕录制）· 截图 · 描述 · 关键词 · 年龄分级 |

## 2. 审核备注里必须写清的三件事

1. **为什么需要屏幕录制**：这是唯一的用途，截图只在本机处理，不上传。
2. **自动滚动的缺席是刻意的**：App Store 版只提供手动滚动长截图
   （沙盒不允许向其它 app 投递输入事件）。**主动说明比被审核问出来好。**
3. **macOS 15+ 的定期复确认提示**（Sequoia 起的系统行为，官方不支持关闭）——
   不是本 app 在反复要权限。

## 3. 风险

- **打包公证从未真跑过**（`scripts/package.sh` 七步一次都没执行）——
  这是整条上架路线里**唯一的单点风险**，且只有你能跑。`33` 之前必须至少绿一次。
- MAS 的导出与 Developer ID 的导出**用的是两套不同的 exportOptions**，
  别把现有的那份改坏 —— 两条路线要能**并存**（Developer ID 版是"保住自动滚动"的那条后路）。

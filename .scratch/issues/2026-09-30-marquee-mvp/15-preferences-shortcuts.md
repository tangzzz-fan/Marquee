# 15: 偏好设置四页与快捷键配置

**What to build:** 一个克制的偏好设置窗口，正好四页：通用（启动行为）、截屏（光标、阴影、延时）、输出（保存位置、格式、模板）、快捷键。快捷键可以自己改，撞车了会明确告诉你和谁冲突。

**Blocked by:** 02, 05

**Status:** ready-for-agent

## ⚠️ 前情（ticket 02 已提前交付了一部分）

ticket 02 因为"应用启动后要能换快捷键"这条追加需求，已经落地了以下内容，**不要重复造**：

- `MarqueeCore.ShortcutService`：校验 → 试注册 → 成功才落盘 → 冲突回滚
- `MarqueeCore.ShortcutValidation`：修饰键缺失 / 仅 ⇧ / 系统保留组合的拦截
- `MarqueeCore.UserDefaultsShortcutStore` + `MarqueeSettings.CarbonGlobalHotKey`
- 菜单栏「快捷键…」→ `App/ShortcutPreferencesWindowController`（单页，仅快捷键）

因此本条 ticket 的范围调整为：**把那个单页面板并进四页偏好设置窗口**，并把「通用 / 截屏 / 输出」三页补齐。菜单项届时从「快捷键…」改回「设置…」。

## 设计约束（已定）

- **不超过 4 页**，每页可调项要克制（这是"功能简洁"的硬约束）
- 快捷键冲突检测：Carbon 重复注册会返回 `-9878`（`eventHotKeyExistsErr`），据此提示用户
- 偏好必须落盘并立即生效，不需要重启

## Acceptance criteria

- [ ] 偏好窗口共 4 页，无第五页
- [ ] 修改保存位置、格式、命名模板后，下一次截图立即按新配置执行
- [ ] 快捷键可修改；与系统或其他应用冲突时，明确提示且**不静默失败**
- [ ] 快捷键可一键恢复默认值
- [ ] 偏好项全部落盘，重启应用后保持
- [ ] 每页的可调项数量记录在案，若超过约束需说明理由
- [ ] 偏好读写与快捷键组合校验有单元测试（含非法组合、修饰键缺失、与保留组合冲突）

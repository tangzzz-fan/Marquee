# 04: 窗口识别与悬停高亮

**What to build:** 覆盖层出现后，鼠标移到任意窗口上，那个窗口被完整高亮出边框；单击即截取该窗口。默认带系统投影（和系统截图一致），按住 `⌥` 再点则得到**无阴影、无背景**的纯净窗口内容。这是旧版 Snip 的招牌能力，是"能否替代旧版"的关键之一。

**Blocked by:** 03

**Status:** ready-for-agent

## 设计约束（已定）

- 窗口清单来自 `SCShareableContent`（`SCWindow` 提供 `windowID` / `frame` / `windowLayer` / `owningApplication` / `isOnScreen` / `isActive`）
- 单窗口采集用 `SCContentFilter(desktopIndependentWindow:)`
- 去阴影用 `SCStreamConfiguration.ignoreShadowsSingleWindow`
- 需要过滤系统窗口与菜单栏层；按窗口层级排序做命中测试（最上层优先）
- 窗口清单需缓存并在覆盖层期间失效重取，避免每次悬停都查一遍

## Acceptance criteria

- [ ] 鼠标悬停在任意普通窗口上，该窗口边界被高亮，高亮框与窗口实际边缘贴合（含圆角窗口）
- [ ] 单击高亮窗口，剪贴板得到该窗口截图，包含系统阴影，且**不含**被遮挡的其他窗口内容
- [ ] 按住 `⌥` 单击，得到无阴影、无背景（透明）的窗口内容
- [ ] 悬停菜单栏、Dock、桌面空白处时不出现误导性高亮
- [ ] 悬停到 Marquee 自己的覆盖层时不把自己当成目标窗口
- [ ] 悬停高亮刷新在 120 fps 下不掉帧（覆盖层重绘实测记录）
- [ ] 窗口命中测试（按层级排序 + 坐标命中）有单元测试，用构造的窗口矩形集合验证

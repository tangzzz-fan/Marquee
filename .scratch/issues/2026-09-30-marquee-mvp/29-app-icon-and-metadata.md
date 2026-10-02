# 29 · App 图标与上架元数据

- **状态**：✅ 已完成（2026-10-02）
- **依赖**：无
- **为什么排第一**：这是**唯一零风险高收益**的一步 ——
  不碰任何受限能力、不影响任何功能，但它同时解掉"没有图标"和"上架缺键"两件事。

---

## 1. 交付了什么

| 项 | 之前 | 现在 |
| --- | --- | --- |
| App 图标 | **没有**（`ASSETCATALOG_COMPILER_APPICON_NAME` 是空串，仓里没有 `.xcassets`） | `App/Assets.xcassets/AppIcon.appiconset`，十档 PNG（16 → 1024） |
| 屏幕录制用途描述 | **没有** `NSScreenCaptureUsageDescription` | 已补（上架硬要求） |
| App Store 分类 | 没有 | `LSApplicationCategoryType = public.app-category.productivity` |
| 出口合规 | 没有 | `ITSAppUsesNonExemptEncryption = false`（免掉每次上传都要回答的问题） |
| 开发区域 | `zh_CN`（旧写法） | `zh-Hans`（与 catalog / `knownRegions` 一致） |
| 版权 | `Marquee` | `© 2026 Marquee` |

## 2. 图标：为什么是脚本画的

`Tools/IconGen/`（独立 `swiftc` 编译，与 `Tools/` 下其他工具同规矩，**不进产品工程**）。

三条理由，都不是"为了炫技"：

1. **每个尺寸要原生渲染，不能缩图。** 从 1024 缩到 16 点，虚线与圆角会糊成一片灰。
   脚本用同一份几何、按目标像素重画（`cgContext.scaleBy`），十档全部原生出。
2. **图标要跟着产品配色走。** ticket 24 定的深色 chrome / ✗ 珊瑚红 / ✓ 绿是产品的视觉语言，
   图标应该属于同一个家族。参数写在一个 `Variant` 里，改一个数字就能重出全套。
3. **可复现。** 谁 clone 下来跑 `./run.sh` 都能得到同一套 PNG，
   而不是"仓库里躺着一堆来源不明的位图"。

```bash
./Tools/IconGen/run.sh                  # 出三个方案的预览（不改产品资源）
./Tools/IconGen/run.sh install dark     # 装成 AppIcon
```

### 设计

- **深色圆角底**（贴合产品 chrome），上缘一道**线性**高光。
- **虚线选框 + 四个角控制点** —— 就是产品里那个"拖出来的选区"，名字（Marquee）也在此。
- 三个候选方案：`dark`（已选用）/ `light` / `indigo`。

### 两条硬事实（都写进 PITFALLS 119）

- macOS 的图标网格是 **1024 画布里 824×824 居中、圆角约 185**。不按它做，
  图标在 Dock 里会比别人大一圈或小一圈 —— 而那种偏差说不清哪里不对。
- **低 alpha 的幅向渐变在 8 位色深下会出可见色带。** 第一版的"中央柔光"就是这样；
  改成线性渐变就好了（线性渐变只有一条轴，没有等值线圈）。

## 3. 工程接线

```yaml
# project.yml
sources:
  - path: App/Assets.xcassets
    buildPhase: resources      # 与 App/Resources 分开、显式声明
settings:
  base:
    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

**为什么与 `App/Resources` 分开、也显式声明**：`.xcassets` 要过 `actool` 编译，
不能和一堆普通资源混在一个目录里等归类。而且**不走 syncedFolder** ——
本机跑不了 xcodebuild，它在不在 Resources 阶段必须钉在生成工程那一刻
（与 `.xcstrings` 同一条理由，见 ticket 17b）。

**已验证**（`xcodegen generate` 之后读 `project.pbxproj`）：

```
Resources 阶段成员：
   AC13953A4863CC3AECC90110 /* Assets.xcassets in Resources */,
   5E52CB4286AB7EF3F98BE880 /* Localizable.xcstrings in Resources */,
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
```

## 4. 顺带修掉的一件事：生成器在 `/tmp` 里

生成 `Localizable.xcstrings` 的脚本原先只存在于 `/tmp`，`ROOT` 还写死了本机绝对路径。

**这是"唯一的生产工具放在临时目录里"** —— 校验器（`LocalizationScanTests`）能告诉你错了，
但不能帮你改正；生成器一丢就是 187 条翻译的返工。

已收进 `Tools/L10nCatalog/`：路径从脚本位置推导，`run.sh` 提供 `keys` / `write` 两个动作
（不给参数默认 `keys`，不会误写文件）。收进之后核对过三方一致：
**源码 187 key / catalog 187 条 / 翻译表 187 条，缺 0、多 0。**

## 5. 验证

- `./scripts/test.sh` → 509 全绿（Core 491 + 历史仓库 12 + Vision 自检 6）
- `xcrun xcstringstool compile` → 187 条 `en.lproj`（改动前后一致）
- `plutil -lint App/Info.plist` → OK
- `./Tools/IconGen/run.sh install dark` → 十档像素逐一核对
  （16 / 32 / 32 / 64 / 128 / 256 / 256 / 512 / 512 / 1024）

## 6. 待人工确认

1. **Dock / 访达里的实际观感**（要不要换 `light` 或 `indigo`：一条命令）。
2. `./scripts/build.sh` 在**普通终端**跑一次 —— 图标是否真的出现在 `.app` 上
   （本机 shell 里跑 xcodebuild 会撞上 `swift-plugin-server` 那个环境问题）。

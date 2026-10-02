# 28 · 工具条图标的三处错误（截图报障）

**状态**: ✅ **已完成**（2026-10-02）
**阻塞于**: 24（工具条重排）、27（编辑器图标）
**来源**: 用户贴出运行截图，报了三处 ——
「1 emoji 图标默认不对 2 格式 这个文字还在 3 点击 emoji 时，此时画板按钮也高亮了，不对」

---

## 0. 先对着截图把每一格认出来

截图里那条是 15 格，与 `OverlayToolbar.slots` **逐格对上**：

```
□ ○ ③ ↗ ✏ ▦ ⑦ │ ⑧ │ [A] │ ↶ ↷ ⇩ 📌 ✗ ✓
                        ① ② ③ 是用户圈出来的三处
```

右侧日志「工具栏：点了工具 `text` → …」「…点了工具 `emoji` → …」正好印证：
**③ 是表情工具、⑦ 是文字工具** —— 所以不是"别的东西",就是这两格的图标画错了。

## 1. 「emoji 图标默认不对」—— 多色符号被整片填充

`SelectionOverlayView.drawSymbol` 用的是
`NSImage.SymbolConfiguration(paletteColors: [color])`，
而它会**把符号的第一层刷成那个颜色**。`face.smiling` 的首选渲染模式里，
第一层就是**整张脸** —— 于是选中时画出来是**一个实心蓝圆点**。

按应用里那份完全相同的配置渲染出来的对比（左＝不加单调、右＝加）：

| 配置 | `face.smiling` |
| --- | --- |
| `paletteColors` 单用 | 实心圆点 ✗ |
| 加 `.preferringMonochrome()` | 正常笑脸 ✓ |

其余十个图标两种配置**逐格对比完全一样**，所以单调着色不是降级，而是意图
（我们本来就要"整格一种颜色"）。

**修法**：`drawSymbol` 的配置加 `.applying(.preferringMonochrome())`。

## 2. 「格式 这个文字还在」—— SF Symbol 自动本地化

文字工具用的是 `textformat`。**名字没错**，但符号有**中文本地化变体**，
系统按应用语言自动替换：中文下 `textformat` 渲染出来是**两个字「格式」**
（变体名 `textformat.zh`，单独渲染确认过就是「格式」）。

这正是用户上一轮说的"格式 使用 icon 代替，现在直接用文字，比较突兀" ——
当时我把它理解成了编辑器工具栏的「文字」「序号」，**认错了地方**（细节见 §5）。

同一批受影响的还有：`character` → 字、`textbox` → 文、
`textformat.size` → 大小、`textformat.abc` → 甲乙丙。

**修法**：文字工具改用 **`t.square`**（"方框里的 T"）——
两种语言下都是同一个图形，而且正好是参考工具条那一格的画法。
覆盖层与编辑器**都换**（同一个功能用同一个图标是本项目的既有约定）。

编辑器里那两个文字预设也跟着换：`textformat.abc`（中文会变甲乙丙）→ `text.alignleft`。
`list.number` 不受影响，保留。

## 3. 「点击 emoji 时，画板按钮也高亮了」—— 判据写错

「样式」格原先是：

```swift
if state.palette != nil { highlight(rect) }     // ← 只要有弹层开着就亮
```

而弹层有**两个**（样式、表情），选中表情工具会打开表情面板 ——
于是「样式」跟着一起亮。

**修法**：判据抽进 Core（`OverlayToolbarHighlight.isLit(_:activeTool:openPalette:)`），
规则是「点亮必须由**这一格自己的状态**决定」：

| 格子 | 点亮条件 |
| --- | --- |
| `tool(t)` | `activeTool == t` |
| `style` | `openPalette == .style`（**不是** `!= nil`） |
| 动作格（识别/钉图/撤销/重做/保存/取消/完成） | **永不点亮**（它们是动作，不是状态） |

## 4. 顺手留下的探针

这类问题（名字对、画出来不对；本地化；着色）**读代码看不出来**，
只能渲染出来比。所以加了 `Tools/SymbolProbe/`：

```bash
Tools/SymbolProbe/run.sh      # 出 out-en.png / out-zh.png 两张对照图
```

两个坑写在它的头注释里：
- **本地化按"应用声明的本地化"判定** —— 裸二进制永远按英文渲染，
  `-AppleLanguages` 也改不动。所以 `run.sh` 会临时拼一个声明了 zh-Hans 的 bundle 再跑。
- 每格画两遍（带/不带单调着色），好让"被整片填充"的那种一眼看出来。

## 5. 复盘：我上一轮认错了地方

用户上一次说「**格式** 使用 icon 代替，现在直接用文字，比较突兀」，
我拿不准指的是哪里，问了 —— 选项里我把"编辑器工具栏的字按钮"放在第一位，
用户选了这个。但**真正要看的是覆盖层那格**（显示「格式」两个字）。
当时我确实在源码里 grep 过「格式」，得到"从未作为 UI 文案出现过"，就据此排除了它 ——
**而真相是它不来自我们的字面量，来自 SF Symbol 的系统本地化**。
教训：查不到来源时，除了 grep 源码，还要问一句「**这个字符串会不会是系统给的**」。
（这条与 PITFALLS 113 是同一个知识点。）

## 6. 测试

`OverlayToolbarHighlightTests`，**6 条**。核心是那条回归：
**打开表情面板时只有表情格亮，「样式」不能跟着亮**。

变异 3 次全部变红：

| 变异 | 结果 |
| --- | --- |
| `.style` 退回 `openPalette != nil`（＝用户报的那个 bug） | ✘ 3 条 issue |
| 工具格一律点亮（不看是不是当前工具） | ✘ 17 条 |
| 动作格跟着弹层一起亮 | ✘ 16 条 |

图标那两条**没法单测**（要真机上的图标库 + 语言环境），只能靠探针 + 肉眼 ——
这一点也写进了 PITFALLS。

## 6.5 顺带弄清的一件事：catalog 里的 `stale`

构建之后 `App/Resources/Localizable.xcstrings` 被 Xcode 重写了：**187 条一条不少、
英文翻译一字未改**，但全部被标上 `extractionState: stale`（"源码里找不到"）。

**这个标记是错的**：我们的中文字面量几乎都在 **SPM 模块**里，而 catalog 挂在
**App target** 下，Xcode 的字符串抽取是**按 target** 做的 —— 所以 App 那次抽取
看不到模块里的 `L10n.t(...)`。结论有两条，已写进 PITFALLS 116：

- 这个项目**不要用 Xcode 的「Extract Strings」**，唯一可信的是
  `LocalizationScanTests`（源码 ↔ catalog 双向对比）；
- 构建后 catalog 必然变脏，所以它的入库形态就按 Xcode 重写后的样子来，别较劲。
  （顺带：核对条数时**别数文件行数** —— Xcode 重排会让它从 1876 行涨到 2063 行，
  解析 JSON 数 `strings` 的键才对。）

## 7. 验证

- `./scripts/test.sh` → **491 全绿**（Core 473 + 历史仓库 12 + Vision 自检 6）
- `swift build --disable-sandbox`（Modules）→ Build complete
- `Tools/SymbolProbe/run.sh` → 中文环境下逐格确认：笑脸正常、文字是"方框 T"、其余不变

## 8. 待人工验收

`docs/STATUS-AND-ACCEPTANCE.md` §3 **Y 组 Y1–Y5**。

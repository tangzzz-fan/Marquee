# 26 · 覆盖层的鼠标光标

**状态**: ✅ **已完成**（2026-10-02）
**阻塞于**: 24（工具条与弹层的几何）
**来源**: 用户复测后的原话 —— 「需要调整鼠标箭头，目前都是十字」

---

## 1. 现象与根因

覆盖层上**整屏都是十字**：指着工具条上的按钮是十字、压着一个已经画好的标注是十字、
在选区里准备整体挪一下还是十字。只有选区那 8 个控制点上是方向箭头
（那是 ticket 19 单独补的）。

根因是一条：

```swift
override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)     // ← 整块屏一个十字
    …
}
```

`addCursorRect` 是**区域式**的：先铺一层整屏十字，再靠"后加的赢"让控制点压在上面。
于是除了控制点，其余位置全被那层十字盖住 —— 包括后来才加进去的工具条。

十字本身没错，但它**只在"拉一个新选区"时**才是对的含义。其余场合它什么也没说。

## 2. 做出来的东西

### 2.1 规则放 Core，可脱机单测

`Modules/Sources/MarqueeCore/OverlayCursor.swift`（新）：

```swift
public enum OverlayCursorKind {
    case arrow, crosshair, pointingHand, openHand, closedHand, iBeam
    case resize(SelectionGeometry.Handle)
}

public enum OverlayCursor {
    public static func kind(at point: CGPoint,
                            in context: OverlayCursorContext) -> OverlayCursorKind
    public static func kind(for drag: OverlayCursorContext.Drag) -> OverlayCursorKind?
}
```

分派顺序与 `mouseDown` **完全一致** —— 两者不一致的话，会出现
"手型光标压在按钮上、点下去却在重画选区"这种说不清哪里不对的状态：

| # | 位置 | 光标 |
| --- | --- | --- |
| ⓪ | 拖拽中 | 只看**在拖什么**（不看位置） |
| ① | 弹层 | 手型 |
| ② | 工具条上的格子 | 手型（**灰掉的那几格是箭头**）／格间空隙是箭头 |
| ③ | 正在输入文字 | 输入框内 I 形，**框外箭头**（那一下只会结束输入） |
| ④ | 控制点（选区的 + 标注的） | 对应方向的缩放箭头 |
| ⑤ | 长截图抓帧期间 | 箭头（鼠标没有语义） |
| ⑥ | 选了工具 | 选区内十字 / 选区外箭头 |
| ⑦ | 没选工具 | 压着标注或框内＝**张开的手**；框外＝十字 |

拖拽期间：

| 在拖什么 | 光标 |
| --- | --- |
| 拉新选区 / 画一笔标注 | 十字 |
| 挪整框 / 挪标注 | **合上的手** |
| 拖控制点 | 对应方向的缩放箭头 |

### 2.2 光标改成"按点问规则"，不再用 cursor rect

cursor rect 只能表达**矩形**，而"压着某个标注"要按**形状**判
（斜箭头的包围盒里大半是空白）。用包围盒近似的后果是
"箭头旁边的空白也伸出一只可拖的手，点下去什么都没选中" —— 比不做还糟。

所以在三个时刻各问一次：

- `mouseMoved` —— 移动
- `mouseDragged` —— **拖拽期间根本不会有 `mouseMoved`**
- `presentation` 变化时用 `NSEvent.mouseLocation` 补一次 ——
  控制点 / 工具条 / 弹层都是"鼠标停着不动"时出现的

## 3. 测试

`Modules/Tests/MarqueeCoreTests/OverlayCursorTests.swift`，**14 条**：

用户报的那条 · 十字只在两处出现 · 工具条给手型 · **灰按钮不给手型** ·
弹层压过工具条 · 控制点方向与角优先 · 选工具后内外分流 ·
长截图惰性 · 文字输入框 · **标注被拖到框外** · 标注控制点优先于它自己的身体 ·
拖拽不看位置 · **拖拽压过一切** · 空白上下文＝整屏十字。

### 变异验证（3 次，全部变红）

| 变异 | 结果 |
| --- | --- |
| 在规则开头直接 `return .crosshair`（＝还原用户报的现象） | ✘ 29 条 issue |
| 把「拖拽判定」挪到分派链最后 | ✘ 3 条 issue |
| 忽略 `disabledSlots`（灰按钮也给手型） | ✘ 3 条 issue |

## 4. 顺手清掉的

- `SelectionOverlayController.annotationPoint` 上面挂着一段**属于已删除函数**
  （`localAnnotationPoint`）的文档注释 —— ticket 25 删函数时漏掉了注释。
- `docs/STATUS-AND-ACCEPTANCE.md` 的 L 组前言还写着 ticket 22 时代的
  「703 × 40 点，21 格」和「色板 ×6 / 尺寸 ×3 各占一格」——
  ticket 24 已经把它们收进「样式」弹层了，前言没跟上。

## 5. 验证

- `./scripts/test.sh` → **480 全绿**（Core 462 + 历史仓库 12 + Vision 自检 6）
- `./scripts/build.sh` → **BUILD SUCCEEDED**
- `swiftc -parse -swift-version 6 App/Sources/*.swift` → 通过

## 6. 待人工验收

`docs/STATUS-AND-ACCEPTANCE.md` §3 **W 组 W1–W12**（含多屏那一条）。

# 25: 修 ticket 24 的回归 —— 自由框选失效 + 拖拽卡顿

**What to build:** 用户报"被窗口高亮之后、还没确认选区时，其他部分自由框选不对"，
以及"有点卡"。两条都是 ticket 24 引入的回归。

**Blocked by:** 24

**Status:** ✅ done（2026-10-02）

---

## 回归 1（严重）：**自由框选整个失效**

### 现象

还没落点时（鼠标悬停高亮某扇窗的期间，或空白处）按下拖动，**选区什么也不出现**。

### 根因

ticket 24 把 `OverlayAnnotationSession.isSelecting` 的判据从
`tool == .select` 改成了 `tool == nil`（"选择"不再是工具位，改隐式）。而
**`tool == nil` 正是默认状态** —— 于是控制层里那段

```swift
if annotationSession.isSelecting, !hasScrollSession {
    ...
    dragMode = .stroke        // ← 占住了
    return                    // ← 而且直接返回，下面的"重画选区"永远轮不到
}
```

在**每一次按下**时都命中：`dragMode` 被占成"画一笔"，可草稿根本没开始
（`beginResize` / `beginMove` 都返回假），`draggedTo` 里的 `updateStroke` 因为没有草稿而空转。

而下面那条真正该接住它的路（`dragMode = .select` → 拖出新选区）**永远走不到**。

帮凶是 `localAnnotationPoint(_:)`：

```swift
annotationPoint(globalPoint) ?? .zero     // ← 把"没有画布"悄悄变成"画布左上角"
```

它让"没有画布"这件事**在类型上消失**了，判据于是永远成立。

### 修法

1. 判据从"没选工具"改成 **"有画布 **且** 命中了东西"**：
   `OverlayToolbar` 之外新增
   `OverlayAnnotationSession.takesPressForAnnotationEditing(local:)` ——
   放在会话里是为了**能被单测钉住**（放在控制层的 `if` 里没人测得到）。
2. 没命中时**不再提前 return**：清掉选择，然后继续往下走到选区几何那条路。
3. **删掉 `localAnnotationPoint`**：让"没有画布"必须被显式处理，而不是被 `.zero` 吞掉。

### 回归测试（变异实测有效）

- 「没有画布时按下绝不归『改已有标注』」
- 「命中标注才归；空白与『选了工具』都不归」

| 变异（退回 ticket 24 的写法：`{ isSelecting }`） | 结果 |
| --- | --- |
| 两条测试 | ✘ **3 条 issue 变红** ✔（恢复后全绿） |

---

## 回归 2：拖拽卡顿

**已知的两处、已修**（都属于"每次重画都要重做一遍本可以复用的事"）：

1. **子视图同步没做变化判断。**
   `presentation` 的 `didSet` 里有一条快路径 —— "只有放大镜在动"时
   **只重画光标周围一小块**（`setNeedsDisplay(dirtyRect:)`）。
   而 `syncToolbarChrome()` 每次都被调用且无条件 `toolbarForeground.needsDisplay = true`，
   等于把那条快路径抵消掉：**鼠标每动一下都要把整条工具条重画一遍**。
   修法：记住上次同步过去的 `OverlayToolbarPresentation` / `OverlayPalettePresentation`，
   **内容或位置真的变了才碰子视图**。

2. **图标每帧重建。**
   `NSImage(systemSymbolName:) + withSymbolConfiguration` **每次调用都会新建一个图像**，
   而工具条一帧要画 15 个。修法：按「符号名 + 是否置灰 + 外观 + 解析后的颜色」缓存。
   > 颜色用 `usingColorSpace(.sRGB)` 取分量，**不用 `.redComponent`** ——
   > 后者对动态色（`controlAccentColor`）会**抛异常**。

### 还不能确定的部分：材质

排查时**没有把材质排除掉**：工具条与钉图控制条现在是 `NSGlassEffectView`（macOS 26+），
而玻璃是**实时采样背后画面**的 —— 面板跟着选区移动时，它每帧都要重新采一次。

所以留了一条现成的对照实验（ticket 17a 就做了）：

```bash
defaults write dev.tango.Marquee chrome.forceHUD -bool YES   # 换成静态材质，重开 app 再拖一次
defaults delete dev.tango.Marquee chrome.forceHUD
```

如果换掉材质就不卡了 → 问题在玻璃，接着的选择是"只给静态面板用玻璃、跟着动的那条用材质"；
如果一样卡 → 继续查覆盖层重绘那条路。**先拿到结论再改，不猜。**

### 新加的探针（让"卡不卡"有数字）

```bash
defaults write dev.tango.Marquee overlay.traceFrames -bool YES
```

拖一次选区，日志里会出现：

```
拖拽性能[选区几何]：N 帧 / X ms，平均 Y ms/帧，最大间隔 Z ms
```

- **平均 ≤ 8 ms**（120 Hz）算达标；`最大间隔` 才是"卡一下"的观感来源。
- 这条探针与 `chrome.forceHUD` 合起来，能把"是重绘、是材质、还是别的"分开。

## Acceptance criteria

- [x] 悬停高亮窗口期间、或任何未落点状态下，拖动**能拉出新选区**
- [x] 没选工具时按在标注上仍能选中并拖动（隐式选择没被这次修复弄丢）
- [x] 按在空白处会清掉选择，**并继续**去改选区几何
- [x] 回归测试在旧写法下会变红（变异实测）
- [x] 工具条只在内容/位置真的变了时才重画；图标有缓存
- [x] 有可执行的性能探针与材质对照开关
- [ ] **人工**：拖选区、拖控制点、拖标注各走一遍，确认不卡
- [ ] **人工**：`overlay.traceFrames` 打开，把那一行日志贴回来
- [ ] **人工**：`chrome.forceHUD` 对照一次，告诉我"材质换掉还卡不卡"

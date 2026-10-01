# Marquee · 实现陷阱清单

> 每一条都是**实际踩过**的，且大多是「不崩溃、不报错、只悄悄错」那一类 ——
> 这类问题靠调试直觉找不到，只能靠记住它。
>
> 分工：本文件＝**写代码时**的实现陷阱；`DEV-NOTES.md`＝**环境与工具链**的摩擦；
> `SPIKE-PLAN.md`＝提前验证过的技术结论。
>
> 新增陷阱请**直接加在这里**，不要只写在提交信息里。

---

## A. 位图、色彩空间与坐标

1. **`CGBitmapContext` 的内存行序本就自上而下**，不要再"翻转为自上而下" —— 那是相对各自图像高度的镜像，会让帧间位移**符号反转**，配准静默出错。
2. 取帧一律用 **`CGImage.cropping(to:)`**，不要用负坐标 rect 的 `ctx.draw`（结果与预期不符，K2）。
3. **`CGBitmapContext.bytesPerRow` 必须对齐**（用 16 的倍数）。给 `width * 4` 这种未对齐值（例如 2 px 宽的图 = 8 字节）会**整行读出垃圾且不报错**。
4. 位图行步长必须用 **`ctx.bytesPerRow`（字节）**，不能 `bytesPerRow / 4` 再乘像素下标 —— 单位混用会读出毫无关系的字节，且不报错，只是断言在胡说。宽度不是 16 倍数时 `bytesPerRow` 还会被 CG 补齐（实测 400 宽 → 416）。
5. **`CGColorSpaceCreateDeviceRGB()` 在本机（P3 屏）就是 Display P3**：用它建上下文 + 用 `CGColor(red:green:blue:alpha:)` 填色，"纯红"读回来是 `(255,38,0)`，颜色断言变成碰运气。测试里一律用 `CGColorSpace(name: .sRGB)` + `CGColor(colorSpace:components:)`。
6. **导出底图必须保留来源色彩空间**：`AnnotationRasterizer` 曾经恒用 sRGB，把 P3 截图悄悄转掉。要优先取 `cropped.colorSpace`；`AnnotationColor.cgColor(in:)` 也必须走 `converted(to:)` 而不是把 sRGB 分量塞进目标空间。
7. **翻转 CTM 之后再 `draw(CGImage, in:)`，图会上下颠倒。** 翻转后图像的顶行仍在 `rect.maxY`，而 `rect.maxY` 已是视觉上的**下**边（实测：自上而下 10/20/30/40 的四行图落在第 2 行，翻转得 `40,30,20,10`）。所以**底图要在默认 y 向上坐标系里画**，需要"左上原点"时再把 CTM 翻过来画别的（标注）。`AnnotationRasterizer` 与 `ScrollStitchRenderer` 都踩过；**纯色底图看不出翻转**，所以 `TestSupport` 里加了 `topBlackBottomWhite`。
8. **"1:1 直通拷贝"也需要对齐设备像素。** 只要目标矩形落在半个像素上（`origin = 光标 + 间距`，光标天然带小数），CG 就会插值一次 —— 平滑档看起来发虚，最近邻档则是**个别格子被拉宽、个别被吃掉一行**。画任何"像素到像素"的图（放大镜、像素对齐的预览）都要把落位按 `backingScale` 取整。
9. **"坐标空间已对齐"这件事要能实测，不能靠猜。** 编辑器画布走 SwiftUI `Canvas.withCGContext`，导出走自建 CGContext —— 两者的 y 方向若不一致就是**镜像文字**，而"有没有墨"这类断言完全看不出来。解法：用 `ImageRenderer` 把画布离屏渲染成图，再读像素判方向（`AnnotationTextCanvasTests`）。
10. **CoreText 的局部翻转（平移到基线 + `scaleBy(1,-1)`）不能省**，否则文字镜像/跑位。且编辑器与导出必须共用 `MarqueeCore.AnnotationText`，各画各的会出现"编辑器里放得下、导出后被裁掉半个字"。

## B. 滚动拼接与配准

11. **长图拼接的取行区间**：新内容 = 本帧**顶部** d 行 = `(viewH-d)..<viewH`，不是 `d..<viewH`（写反了高度对、内容错位，MAE 75.78）。
12. **长图总高与每片底边都取 `floor`，不要 `ceil`。** 取 `ceil` 会多出一行"只覆盖一半"的行，谁都不完整覆盖它 → 长图上一条**半透明横线**。
13. **Vision 位移符号是 `rows = +ty`**（`targetedCGImage:` = 上一帧、handler = 当前帧）。按"Vision 原点在左下"取负会让所有位移变负 → 每帧都判成"没动"，长图永远只有一屏（不崩不报错）。
14. **配准模块必须内置"装置自检"**：用已知位移的合成图做回归。上面 A/B 两组里好几个坑都是靠自检才发现的。这条不是"建议"——没有它，出错时无从下手。
15. **落地测试要覆盖亚像素**：整数位移会累积 ±0.5 px 误差，长图越长错位越明显。抛物线精化后按**累计小数位移重采样**。

## C. 权限、签名与 TCC

16. **别用自己持久化的标记去推断 TCC 的 `denied`**：签名身份一变，TCC 状态重置而标记还在，于是再也不敢调 `CGRequestScreenCaptureAccess()`；而 macOS 只在应用调用采集 API 时才把它登记进「屏幕录制」列表 → 用户永远授权不了。见 `DEV-NOTES.md` 1。
17. **macOS 只在应用真的调用采集 API 时才登记进「屏幕录制」列表**。权限门若拦在采集之前，"请求权限"里也必须真的碰一次 `SCShareableContent` —— 碰一次**枚举**就够了，**不要**再截一帧：`SCScreenshotManager.captureImage` 在 macOS 15+ 会叠出第二张系统授权框。
18. **授权框连弹**：`requestPermission()` 里截帧 + preflight 在重启前一直是 false 仍报 `.notDetermined` + 刚授权还去采集，三者叠在一起会让每次快捷键都弹系统框。进程内记住"问过一次"（**不要**写 UserDefaults），刚授权只提示重启。见 `DEV-NOTES.md` 1.3。
19. **`DEVELOPMENT_TEAM` 要填真正的 team id**（`codesign -dvvv` 里的 `TeamIdentifier`，本机 `UKXWZ3FS84`），**不是**证书名括号里那串（`Apple Development: … (7H6TJ2PN25)` 里的是证书标识）。填错报 `No signing certificate "Mac Development" found`。
20. **签名必须由工程负责**（`project.yml` 的 `CODE_SIGN_IDENTITY` + `DEVELOPMENT_TEAM`），**不能只写在构建脚本里** —— Xcode Run 不执行脚本，只改脚本等于没修。
21. **自动滚动需要「辅助功能」授权**（本项目唯一一处）：往别的进程注入事件属于辅助功能授权范围。所以它必须**按需**申请 —— 只有用户主动触发才问，拒绝即降级回手动。

## D. 状态推进与 UI 反馈

22. **可选回调漏接线 = 静默 no-op，且毫无线索。** ticket 11 把 `MenuBarController.onScrollCapture` 写成可选 `var` 却忘了在 app delegate 注入 → 菜单项看着是启用的、点下去什么都不发生。**判据：用户说"点了没反应"时，第一件事是验入口通不通，再看下游渲染。** 修法是把 UI 回调做成 `init` 的必填参数（漏接即编译错误）。
23. **"状态没变"的判定必须先验前提。** 长截图把"连续几帧没动"解读成"滚到底"，但用户**还没开始滚**时它只意味着"还没开始" → 进门 1 秒就误报到底。同类陷阱：任何"结束了/到底了/完成了"的自动判定，都要先问"有没有真的开始过"。
24. **误判不能做成终局。** 上面那个误报原来还会**停掉抓帧循环** —— 用户再往下滚就彻底没反应，长图还缺后半段，比误报本身更糟。自动判定触发时应当降级为**提示 + 可恢复**，而不是停机。
25. **改了状态 ≠ 状态会被推出去。** 放大镜更新只改 `magnifier` 字段，把"推给视图"交给调用方顺手调 `refresh()` —— 而空闲移动走的是 `updateHover`，那里"悬停窗口没变"时直接 `return`，于是**落点之后与悬停在同一个窗口内时放大镜定格不动**。规矩：**谁改谁推**（`pushMagnifier`）。同源：`statusText` 是烘进 presentation 的，只 `refresh()` 推的是算好的旧那份 → 反馈要等下次鼠标移动才出现，必须**重建**。
26. **判定要分清"内容没变"与"位置没变"。** 放大镜原来把"取样像素没变"直接当成"什么都不用做"，而光标位置仍可能变了 —— 混在一起就会**该动的没动**。抽成三态（`idle` / `moved`（复用小图、只挪盒子）/ `resample`（重采））后既可测也不再含糊。
27. **说"某键被占用"之前，先确认它被占用的**相位**。** `⌥` 在悬停时是空档，落点之后才归 ticket 04 的"无阴影" —— 一个假冲突换来的是放大镜必须赖在落点之后不走，同时违背 PRD F4 与用户参照的微信行为。**冲突要按相位核对，不能按"这个键有没有人用"粗判。**
28. **`fillMask(punching:)` 的洞有多大，蒙层就少多少** —— 洞等于整屏时这个分支等于"没画"。长截图空状态就踩过：把整块屏当高亮镂空 → 用户看不出覆盖层在工作，以为"拖不了"。空状态要的是满屏蒙层 + 提示。
29. **依赖"前台→后台顺序"的命中，必须在应用切换后重取清单**：`NSWorkspace.didActivateApplicationNotification` → 重拉 `SCShareableContent` + 强制重算悬停（`updateHover` 只在鼠标移动时被调用，不动鼠标就会一直停在旧高亮上）。
30. **自动滚动的三类停稳判定缺一不可**：单步等待上限（无限加载）、步数熔断（永远滚不完）、连续"采不到画面"熔断。少任何一个都会变成"卡住不动"。
31. **滚轮事件是按「指针下方的窗口」派发的** → 自动滚动前必须先把指针对准选区，否则事件滚了别的窗口（用户看到的是"什么都没发生"）。且 CGEvent 的 `wheel1` **向下滚是负值**（同 `NSEvent.scrollingDeltaY`），写反不报错、只是方向相反。

## E. 测试与断言

32. **swift-testing 的 `#expect(...)` 宏展开里不能调 `mutating` 方法**（`$0 is immutable`）→ 先赋给局部变量再断言。
33. **"夹取"与"翻边"是两件不同的事，只断言不变量会漏掉后者。** 摆位时"不越界 + 不盖光标"靠夹取就能满足，翻边真正的价值是**让放大镜贴着光标**。变异测试里把翻边去掉曾经漏网，补了"水平间距 ≈ gap"才抓住。**写断言要写「意图」**，不能只写不能违反的边界。
34. **测"翻转"要用不对称的图。** "上黑下白各一半"关于**水平中线镜像对称**，翻转后逐像素相同，变异测试直接漏网。换成"顶部一条黑带"立刻抓住。
35. **区分两种"都能让细节变少"的滤镜，度量要选对。** 马赛克与模糊用"变脸次数"或"相邻像素是否相等"都区分不出（大色块模糊后中间会出现饱和平台）。可靠度量是**相邻像素跳变的最大幅度**：马赛克是台阶（能跳到接近满量程），模糊是斜坡（被摊薄到几十）。
36. **"放大"发生的地方要和"画"分开想。** 视图里 `interpolationQuality` 只在**非 1:1** 时起作用；图像尺寸与目标矩形严格相等时那个设置形同虚设。**问自己：重采样到底发生在哪一步。**
37. **放大图像必须 `interpolationQuality = .none`**（Core 与视图两处）：双线性会把相邻像素混起来，而放大镜的用途恰恰是"看清这一格是什么颜色"，混色等于把要看的抹掉。测试用"输出里只允许出现源图那两种颜色"来钉它。
38. **变异测试是"断言有没有空跑"的唯一证据。** 每个新模块做完跑一次：故意改坏一处实现，确认测试变红，再改回来。

## F. 工具链与工程

39. **`xcodebuild` 无法解析本地 SPM 包**（deny-default 沙箱在本机宿主环境不可应用）→ 用 `scripts/build.sh`。见 `DEV-NOTES.md` 4。
40. **被沙箱包裹的 shell 里 `xcodebuild` 编不过 SwiftUI 宏**：`swift-plugin-server` 启动时自己再套一层沙箱，外层不放行就被 SIGKILL，报 `StateMacro ... produced malformed response`。**判断方法：`./scripts/test.sh`（SwiftPM，按 `--disable-sandbox`）能过、`./scripts/build.sh` 不能 → 一定是宿主沙箱，别动代码。** App 层可改用 `swiftc -typecheck -sdk $(xcrun --show-sdk-path) -swift-version 6 -strict-concurrency=complete -I Modules/.build/out/Products/Debug App/Sources/*.swift` 验证。
41. **新增/删除源文件后必须 `xcodegen generate`** —— Xcode 的 Run **不会**替你生成，症状是报在**调用方**（"找不到某类型"）而不是新文件本身。已改用 `type: syncedFolder`（Xcode 16+ 文件系统同步组）根治。见 `DEV-NOTES.md` 2.2。
42. **别依赖 Xcode 自动创建的 user scheme**（在 `xcuserdata/`）。`xcodegen generate` 之后它可能不在了 → 必须在 `project.yml` 里声明**共享** scheme。
43. **bash + `set -u`：中文文案里 `$VAR` 紧跟全角字符会被当成变量名的一部分**（如 `$IDENTITY（team …）`）→ 报 "unbound variable"。写 `${VAR}`。
44. **模块缺 `import Foundation` 会让 `Equatable` 静默合成失败**（`URL`/`Date`/`UUID` 场景）。同源：`CGImageDestination*` 要 `import ImageIO`。

## G. 平台 API 细节

45. **`NSEvent.ModifierFlags` 的 ⌘ 是 `1<<20`（0x100000），不是 `1<<16`** —— `1<<16` 是 **Caps Lock**。位值：capsLock `1<<16`、shift `1<<17`、control `1<<18`、option `1<<19`、command `1<<20`（`NSEvent.h:168-172`）。写错不崩，只会让所有 ⌘ 组合静默变成"没按 ⌘"。已用测试钉死。
46. **Carbon 虚拟键码不是顺序的**：`kVK_ANSI_5 = 0x17`、`kVK_ANSI_6 = 0x16`（反序）。键码表一律从 `Events.h` 抄，别按下标推。
47. **Carbon 热键的冲突只能靠「独占注册」探测出来**（四种情形实测）：
    - 非独占注册：**永远是 0**，被占也返回成功 → 光看它永远发现不了冲突（微信同时响应就是这么来的）
    - 独占注册 + 同进程内已有自己的注册 → `-9878` → **必须先 `unregister()` 再探测**
    - 独占注册 + **别的进程独占**占着 → `-9878` ✅ 可用的探测手段
    - 独占注册 + 别的进程只是**非独占**占着（跨进程）→ **0**，探测无效；此时双方都收到事件
48. **`OptionSet` 的 Codable 是 `RawRepresentable` 单值编码**：`ShortcutModifiers` 编出来是 `"modifiers":9`，**不是** `{"rawValue":9}`。手写偏好做测试时别猜形状。
49. **`os.Logger` 的字符串插值里引用实例属性要写 `self.`**，否则 Swift 6 报 "requires explicit use of 'self'"。
50. **Swift 6 的 nonisolated `deinit` 不能碰非 Sendable 的存储属性**（如 `EventHotKeyRef` / `EventHandlerRef`，都是 `OpaquePointer`）→ 编译报错。解法：不写 deinit 做清理，改由显式 `unregister()` 负责。
51. **`NSLock.lock()` 在 async 上下文里不可用**（编译报 "unavailable from asynchronous contexts"）→ 把加解锁收进一个同步闭包（`withLocked`），在闭包外再做异步的事。
52. **屏幕录制之外还有两个「不弹框也能问」的探针**：`CGPreflightListenEventAccess()`（输入监控）、`CGPreflightPostEventAccess()`（辅助功能/事件注入）。它们的声明**不在头文件里**，但 Swift 能直接调用（符号在 `CoreGraphics.tbd`）。`AXIsProcessTrusted()` 则需要 `import ApplicationServices`。
53. **状态机类的东西必须放 Core**：`MarqueeOverlay` 里的东西无法自动化测试（需要真实屏幕），只有抽到 Core 才能单测。

## H. 窗口与呈现

54. **`.accessory` 应用（`LSUIElement`）里 `makeKeyAndOrderFront` 不够。**
    它**依赖应用已经是 active 的**，而 `Marquee` 是 `main.swift` 里
    `setActivationPolicy(.accessory)` 的后台应用 —— 从覆盖层（高层级 `NSPanel`）退下来、
    紧接着开一个**普通层级**的 `NSWindow` 时，窗口很可能开在别的窗口后面。
    用户看到的现象是"`⏎` 按了，编辑器窗口没出来"，而**它其实已经开好了**；
    更麻烦的是"窗口没出来"和"截图失败"在用户眼里完全一样，很容易查错方向。
    **修法：`window.orderFrontRegardless()`（不看激活状态）**，编辑器窗口与快捷键偏好窗口都要。
    > 判据：凡是"用户说某个窗口没出现"的反馈，先看这个窗口是 `NSPanel` 还是 `NSWindow` ——
    > NSPanel（覆盖层）有 `level` 兜着不容易暴露，`NSWindow` 才会踩到。
    > 同时补一条日志（"打开编辑器：W×H"），这样能先确认**到底有没有走到开窗那一步**。

55. **设置 `NSWindow.contentViewController` 会按 SwiftUI 视图的 `fittingSize` 重排窗口。**
    `GeometryReader` **没有固有尺寸**（它的 ideal size 就是 10×10），所以
    `NSWindow(contentRect: 960×680)` 之后紧跟一句 `contentViewController = NSHostingController(...)`，
    窗口会被缩成"工具栏那一条"。
    **修法：尺寸要在设完 `contentViewController` 之后用 `window.setContentSize(_:)` 再定一次**，
    不能只靠 `init` 里那个 `contentRect`。
    > 坑点：窗口**确实创建了、也叫到前台了**，只是面积几乎为零。
    > 现象上完全看不出是尺寸问题（用户只会说"窗口没弹出来"）。
    > 判据：凡是"`NSWindow` + SwiftUI hosting + 说窗口没出现"，先怀疑尺寸被 hosting 改过。

56. **`.nonactivatingPanel` 上"视图的 `keyDown`"靠不住 —— 覆盖层的功能键必须走应用级本地监听。**
    覆盖层面板刻意用 `.nonactivatingPanel`（不激活本应用，免得把用户从当前应用拽走），
    于是"面板是 key window 且视图是 first responder"这条链路在真实使用中**并不成立**。
    实测（2026-10-01，用户跑出来的日志）：`Esc` 生效（它走 `NSEvent.addLocalMonitorForEvents`），
    而 **`⏎` 完全没反应**（它走视图 `keyDown`）—— 用户拖完选区按 `⏎` 什么都没发生，
    只能按 `Esc` 退出，报上来的现象却是"**编辑器窗口弹不出来**"。
    **修法：把覆盖层全部功能键（`Esc` / `⏎` / `⌘S` / 空格 / 方向键）都放进那个本地监听**，
    闭包只回传"消费了没有"（`NSEvent` 不是 `Sendable`，跨隔离域回传它编译不过）。
    > 判据：**`Esc` 能用而别的键不能用 → 就是这个坑**（`Esc` 恰好走了另一条路）。
    > 更一般的教训：同一个功能绝不能留两条"只在特定前提下成立"的输入路径。

57. **一行控件加起来比窗口还宽时，右边那些会被「挤出可视区」—— 不报错、不压缩、只是看不见。**
    编辑器工具栏原先用文字按钮（"选择""矩形"…），整排实测约 **1110 点**，而窗口默认只有 960。
    `HStack` 空间不足时先缩 `Spacer()`（缩到 0），再不够就把超出部分直接裁掉 ——
    **最右边的控件首当其冲**。用户报的是"OCR 入口我不知道在哪""工具栏我没有看到"，
    查了半天代码，其实功能一直都在，只是**没画出来**。
    **修法**：① 控件图标化（30 点/个，中文标签进 `help`）；
    ② 窗口 `minSize` 不得低于工具栏的实际宽度。
    > 判据：用户说"某个按钮/入口看不见"时，先把那一行控件的宽度**加起来**跟窗口宽度比一比。
    > SwiftUI 不会为"放不下"报任何错，这一点和"静默错误"是同一类坑。

58. **同一个功能的"尺寸/位置/命中"若分几处各自推导，差几点就永远对不上 —— 而且只在贴边时暴露。**
    覆盖层浮动工具栏原先：宽度按"间距在**两组之间**"算，按钮偏移按"间距在**末尾**"算 ——
    差 4 点，最后一个按钮探出右边一点。两条规则各自都对，凑在一起才错。
    **修法：让 `layout()` 一次算出尺寸、每格位置、分隔线位置，绘制与命中都从它取。**
    单一来源之后，"画出来的框"和"点得到的区域"**不可能**分叉。
    > 更一般的判据：任何"看到的"与"点得到的"要一致的界面，几何只能有一份。
    > 附带教训：这条最初写成测试也没抓住 —— 我注入的变异（把组间距从 9 改成 1）
    > **全绿通过**了，因为原测试只断言"不重叠、不越界"，而这些在间距变小时照样成立。
    > 补了"组间间距必须明显大于组内间距"与"工具条必须放得进 1024 点的屏"两条**意图**断言才抓住。
    > **断言只写"不能违反的边界"是盲的，必须同时写"应该是什么样"。**

59. **坐标空间差一次「原点在上还是在下」，图形会整体镜像 —— 而它不崩、不报错、只在画了东西之后可见。**
    `Annotation` 的约定是"原点左上、y 向下"，而 Cocoa 的 `CGRect.origin` 是**左下角**（y 向上）。
    覆盖层取"选区左上角"当标注原点时必须用 `rect.maxY`，写成 `minY` 会让所有标注上下镜像。
    同理，视图里画标注要先 `translateBy(origin)` 再 `scaleBy(1, -1)`。
    > 判据：凡是"两个坐标系要接起来"的地方，**先写一条断言把换算钉住**，
    > 再写绘制。默认的那套坐标永远是最容易被想当然的。

60. **缩放标注时只缩位置、不缩线宽 —— Retina 上导出的线条会细成屏幕上的一半。**
    覆盖层用"点"、导出用"像素"，两者差一个屏幕倍率。
    `Annotation.scaled(by:)` 必须**一起**缩放 `frame` / `path` / `lineWidth` / `fontSize` / `effectStrength`。
    只缩位置的表现是"导出把线变细了"，很容易被当成显示问题去查渲染。
    > 判据：缩小/放大一个带样式的对象时，**列出所有带"长度"量纲的字段**，逐个确认。

61. **带阴影的窗口截图比窗口矩形大一圈 —— 有坐标叠加时必然整体偏移。**
    `.isolatedWindow(includeShadow: true)` 拍出来的图含外扩的阴影，
    而"就地标注"的坐标是相对**窗口矩形**算的。差这一圈，所有标注会整体偏移，
    且偏移量随阴影大小变（浅色背景下阴影大）—— 表现是"有时候对、有时候偏"。
    **修法：有就地标注时强制 `includeShadow: false`**（宁可这张图没阴影）。
    > 判据：任何"把 A 坐标系的图元叠到 B 坐标系的图上"的地方，
    > 先确认两个矩形的边界**逐点相同**，而不是"差不多是同一块"。

62. **「合成失败就回退成原图」在有打码的场景里是个安全缺陷，不是容错。**
    `CaptureOutput.finish` 把就地标注栅格化到截图上，失败时如果 `?? image` 回落，
    用户以为已经遮住的内容会被原样复制出去 —— 而且不会有任何提示。
    **修法：标注非空而栅格化失败时，直接让这次截图失败。** 宁可作废，不要静默降级。
    > 判据：任何"降级路径"经过**脱敏 / 打码 / 权限过滤**时，降级方向只能是"更安全"，
    > 不能是"更原始"。

63. **`#expect(...)` 里不能直接写可变调用（`session.undo()` 这类）—— 宏会把它放进闭包重算。**
    Swift Testing 的 `#expect` 会把操作数捕获成表达式再求值，遇到 `mutating` 调用会报
    `cannot use mutating member on immutable value: '$0' is immutable`。
    **修法：先算成局部常量，再断言常量。**（顺带也更可读：能看出断言的到底是什么。）

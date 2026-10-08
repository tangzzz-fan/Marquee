# -*- coding: utf-8 -*-
"""英文翻译。key 与源码里 L10n.t("…") 的 key 逐字一致（插值已归一成 %lld / %@）。"""

EN = {
    "开发版": "Development build",
    # ── 升级卡片（设计稿 `2026-10-03-引导与升级卡片`）─────────────────────
    #
    # ⚠️ ③ 正文是**一行**（稿子：≤ 22 字），而卡片只有 300 宽、内宽 268。
    # 中文照稿子来；英文同样占这条宽度 —— 太长会被裁掉尾巴（`RecentPanel`
    # 与提示行都栽过同一个跟头）。它由 `LocalizationScanTests` 按真字体量。
    "试用 7 天，结束后自动回到免费版": "Free for 7 days, then back to the free version",
    # 拿到商店价格之后的那一句（3.1.1：试用开始前必须说清"后续费用"）。
    # ⚠️ 它必须与上面那句**一样宽或更窄**放得进卡片正文那一行 —— 已经有断言在量。
    "试用 7 天 · 之后 %@ · 免费版仍可用": "7-day trial · then %@ · free tier stays",
    "试用已结束，免费版仍可截图与标注": "Trial ended. Capture and annotate stay free",
    "购买已撤销，可点恢复购买重新获取": "Purchase revoked. Restore it to get it back",
    "这个账号下找不到这笔购买": "No purchase found for this account",
    # ⑤ 微行（只在覆盖层那张卡上出现）
    "关闭卡片，选区保留": "closes this card, your selection stays",
    # ── 编辑器：识别文字面板的四张脸（设计稿第 3 轮 §07）────────────────
    #
    # 面板宽 260（可用 ~236）—— 每句都要在那条宽度里说完，且**第一行说发生了什么、
    # 第二行说下一步**。「没有文字」与「识别失败」两张脸必须一眼分得开：
    # 前者安静（次要色），后者红 + 警告三角，且多一个「重试」。
    "只读": "Read-only",
    # 识别面板的标题条是它的把手 —— 纸没有边框把手，"能拖"只在这里说一次。
    "拖动面板": "Drag to move",
    "正在识别…": "Recognizing…",
    "首次识别可能要十几秒，之后会快。": "The first run can take a while; later ones are fast.",
    "这张图里没有文字": "No text in this image",
    "纯图或图形界面都可能这样；识别只看整张图。":
        "Photos and UI screens look like this — recognition reads the whole image.",
    "识别失败了": "Recognition failed",
    "重试不会影响已经画好的标注。": "Retrying won't touch the annotations you've drawn.",
    "重试": "Retry",
    "%lld 行 · %lld 字": "%lld lines · %lld chars",
    # ── 编辑器的文字预设弹层（设计稿第 3 轮 §05）────────────────────────
    "预设": "Preset",
    "从几开始": "Start at",
    # 198 宽的弹层里放得下 —— 别写成一句解释（稿子：两段都不带解释文字）
    "放一个，数字 +1（1–99）": "Each one adds 1 (1–99)",
    "减少": "Decrease",
    "增加": "Increase",
    "点一下回到「适应窗口」": "Click to fit to window",
    # ── 编辑器窗口的状态行（设计稿第 3 轮 B 块）─────────────────────────
    #
    # ⚠️ 尺寸那两条**必须短**：状态行 22 高、左边留给它的宽度有限，
    # 而窗口再宽也不会把状态行折行（折了就成了 44 高，把画布挤掉一截）。
    "长截图 · %@ px": "Scrolling capture · %@ px",
    "%@ · %lld 段拼接": "%@ · %lld frames stitched",
    "裁剪中 · 拖出保留框 · Esc 取消": "Cropping · drag the area to keep · Esc to cancel",
    "裁剪中 · ⏎ 应用 · Esc 取消": "Cropping · ⏎ to apply · Esc to cancel",
    # 裁切读数框第二行（稿子 §07 c）：第一行是"裁完多大"，这一行是**原图多大**。
    # 两行对照才说明白"这一刀切掉了多少" —— 只有第一行的话，用户得自己记住原图尺寸。
    #
    # ⚠️ 实测（`NSFont.monospacedDigitSystemFont(11, .medium)`，内宽预算 116 点）：
    #   中文 `原图 1440 × 2000 px` = 111.3 ✓ ／ 英文 `Original …` = **131.2 ✗ 放不下**。
    # 所以框按内容长出去（`CropReadout.size(textWidth:)`，132 只是**最小**）——
    # 与覆盖层 `OverlayReadout.minimumSize` 是同一条语义。
    # ⚠️ 别改成"写死 132"：长截图动辄 `1440 × 12000`，那样连中文都溢。
    "原图 %@ px": "Original %@ px",
    # 「适应窗口 34%」：只有当前缩放**正好**是适应窗口那一个时才说这四个字。
    # ⚠️ 百分号不在 key 里（它拼在外面）—— 见 `EditorChrome.trailing` 的注释。
    "适应窗口 %lld": "Fit to window %lld",
    # ── 最近截图面板（设计稿第 2 轮 D 块）────────────────────────────────
    #
    # ⚠️ 底部那一行是**三段拼起来的一句话**，中间那个词才是可点的：
    #   免费版只保留最近 5 张 · [升级到 Pro] 可保留全部
    # 拆成三段而不是整句带占位符，是因为中间那段要是一个**按钮** ——
    # 整句塞进一个 label 就没法只让其中几个字可点。
    # 代价是三种语言的语序都得靠这三段的翻译各自理顺（分隔符由布局给，不进文案）。
    "点缩略图 = 复制": "Click a thumbnail to copy",
    "还没有截图": "No captures yet",
    "按 %@ 截第一张": "Press %@ to take your first one",
    "复制到剪贴板": "Copy to clipboard",
    "从历史里删掉 · 文件移入废纸篓": "Remove from history · the file goes to the Trash",
    # ⚠️ 英文必须**短**：这一行只有 320 点可用（面板 340 − 左右各 10）。
    # 原写 "The free version keeps the last %lld" 实测 370 点，会溢出 49 点 ——
    # 而稿子那张图上量的是中文（254 点），所以这个约束在中文下永远不会被发现。
    # 现在由 `LocalizationScanTests` 按真字体量着（两套语言一起）。
    "免费版只保留最近 %lld 张": "Free keeps the last %lld",
    "可保留全部": "to keep them all",
    # ⚠️ 英文必须短：行里留给这行字只有 ~161 点。
    # "2560×1440 px · 3 annotations" 实测 165 —— 在 1440p 屏上就已经被截断尾巴，
    # 而中文同样那句只有 142。所以用短词 "marks"（Apple 那边这种标注就叫 Markup）。
    "%@ · %lld 个标注": "%@ · %lld marks",
    # ⚠️ 这条**全 ASCII**（只有 `px`）。它是被生成器漏掉过一次的那一类：
    # 生成器原先只看"有没有中文"，于是它被静默跳过 —— 而源码里明明是 `L10n.t`。
    # 现在生成器的判据是「有中文 **或** 带格式符」。
    "%@ px": "%@ px",
    # ── 偏好设置（稿子 §C）─────────────────────────────────────
    # 窗底那行字：它是"没有应用按钮"这件事的**总回执**。
    "所有更改会立刻生效并自动保存": "Every change takes effect immediately and is saved automatically",
    # 偏好窗口右下角那个入口（Guideline 5.1.1(i)：隐私政策链接要在 app 内也有一处）。
    # 英文用 Apple 自己元数据字段的叫法（Privacy Policy），别另造一个词。
    "隐私政策": "Privacy Policy",
    "Marquee 不收集任何数据 · 在默认浏览器中打开": "Marquee collects nothing · opens in your default browser",
    "查看": "View",
    "截图后播放提示音": "Play a sound after a capture",
    "截成功时播一声系统音效 · 关掉适合连着截很多张的时候":
        "A system chime on success · turn it off when you shoot many in a row",
    "开机时自动启动": "Launch at login",
    "Marquee 常驻菜单栏，开机就有": "Marquee lives in the menu bar, ready from the moment you log in",
    "打开登录项设置": "Open Login Items",
    "截图里包含鼠标指针": "Include the pointer in captures",
    "光标会画在图上 · 它常正好压在你要截的内容上":
        "The cursor gets drawn into the image · it often lands right on what you're capturing",
    "窗口截图带阴影": "Shadow on window captures",
    "用系统的窗口阴影 · 在覆盖层里按住 ⌥ 可临时反转这一项":
        "The system window shadow · hold ⌥ in the overlay to flip this for one shot",
    "延时截图": "Capture delay",
    "按下快捷键后立刻出现覆盖层": "The overlay appears the moment you press the shortcut",
    "保存位置": "Save to",
    "只有按 ⌘S 或点覆盖层里的「保存」才写盘 · 日常截图直接进剪贴板":
        "Files are written only on ⌘S or Save in the overlay · everyday captures go straight to the clipboard",
    "选择…": "Choose…",
    "图片格式": "Image format",
    "PNG 无损 · JPEG / HEIC 有损": "PNG is lossless · JPEG and HEIC are lossy",
    "质量": "Quality",
    "文件名模板": "Filename template",
    "每一份存盘文件的名字": "The name of each saved file",
    "可用变量 · 点一下插到模板光标处": "Available variables · click one to insert it at the cursor",
    "全屏截图": "Full-screen capture",
    "随时可截 · 全局生效": "Always available · works system-wide",
    "Marquee 不在前台也能触发 · 任何时候按它，屏幕就定住":
        "Works even when Marquee isn't in front · press it any time and the screen freezes",
    "恢复默认": "Restore default",
    # Pro 状态区（恢复购买那五种结果**常驻**）
    "正在恢复…": "Restoring…",
    "已恢复购买 ✓": "Purchase restored ✓",
    "这个账号下没有可恢复的购买": "No purchase to restore for this account",
    # ⚠️ 三句失败提示**不能混用**：用户取消必须中性（不报红），
    # 只有真·连不上才配提网络 —— 原因不许猜。
    "已取消，没有改动": "Cancelled — nothing changed",
    "恢复失败 · 检查网络后重试": "Restore failed · check your connection and try again",
    "恢复失败 · 请稍后再试": "Restore failed · try again later",
    # 「升级到 Pro」的回执（与恢复购买**共用同一行**）。
    # 原来这一行完全不存在 —— 点了没反应是唯一可能的表现。
    "正在打开 App Store…": "Opening the App Store…",
    "已购买 ✓": "Purchased ✓",
    "等待批准 · 批准后会自动解锁": "Waiting for approval · it unlocks automatically once approved",
    "购买失败 · 请稍后再试": "Purchase failed · try again later",
    "暂时买不了 · 商店里还没有这个商品": "Can't buy right now · this item isn't in the store yet",
    # 开发版专用：这一档在开发机上最常见的原因就是"没用 Xcode 运行"，
    # 而这句话当场就能把那个原因排掉。正式版看不到它。
    "暂时买不了 · 商店里没有这个商品（开发版：请用 Xcode 运行，且 scheme 要挂 Products.storekit）":
        "Can't buy right now · the store has no such item (dev build: run from Xcode with Products.storekit set in the scheme)",
    # 偏好设置「输出」页 —— 质量那一行的两种说明（稿子 §C.3 / §04）。
    # 无损那句必须给出**下一步**（换成哪种格式才有），不是一句「质量不可用」。
    "PNG 是无损格式，没有质量可调 —— 换成 JPEG 或 HEIC 才有":
        "PNG is lossless — there is no quality to adjust. Switch to JPEG or HEIC for that.",
    "%@ 的压缩质量 · 越低文件越小、细节越少":
        "%@ compression quality · lower means smaller files and less detail",
    # 偏好设置「截屏」页 —— 延时那一行的四档说明句（稿子 §04）。
    # 这一项改了当场看不出效果，所以**说明句就是它唯一的回执**。
    "按 %@ 立刻出现覆盖层": "Press %@ and the overlay appears immediately",
    "按 %@ 后 3 秒才出现覆盖层 —— 那几秒是留给你摆屏幕的":
        "Press %@ and the overlay appears after 3 seconds — those seconds are for arranging your screen",
    "按 %@ 后 5 秒才出现覆盖层": "Press %@ and the overlay appears after 5 seconds",
    "按 %@ 后 10 秒才出现覆盖层": "Press %@ and the overlay appears after 10 seconds",
    # 长截图读数框（稿子 §10）：第一行**已拼高度**、第二行**帧数 · 配准耗时**。
    # 两行分开是为了让主角（高度）单独占一行 —— 原先挤成一句时它和帧数一样重。
    "%lld px 高": "%lld px tall",
    "自动滚动中 · %lld px 高": "Auto-scrolling · %lld px tall",
    "%lld 帧": "%lld frames",
    "  ·  ⏎ 确认": "  ·  ⏎ to confirm",
    # 按住 ⌥ 时读数框第二行那句话 —— **说的是结果，不是键**：
    # 它跟着「设置 → 截屏 → 窗口截图带阴影」那一项算，所以两种结果各有一条。
    "⌥ 窗口截图 · 不含阴影": "⌥ Window capture · no shadow",
    "⌥ 窗口截图 · 带阴影": "⌥ Window capture · with shadow",
    " · 已复制到剪贴板": " · Copied to clipboard",
    " · 配准 %.0f ms": " · Alignment %.0f ms",
    "%@ 已被其他应用占用（例如微信的截图快捷键）。\n请到菜单栏「快捷键…」换一个组合。":
        "%@ is already taken by another app (WeChat's screenshot shortcut, for example).\n"
        "Pick a different combination from the menu bar: Shortcuts….",
    "%@（当前工具）": "%@ (current tool)",
    "%@，按 ⏎ 结束可保留已拼好的部分": "%@ Press ⏎ to finish and keep what has been stitched so far.",
    "%lld 秒": "%lld seconds",
    "Marquee 设置": "Marquee Settings",
    "Marquee 需要「屏幕录制」权限": "Marquee needs Screen Recording permission",
    "Vision 没有返回平移观测值": "Vision returned no translation observation",
    "⚠️ 打码预览不可用（没拿到屏幕像素）—— 标记仍然会写进成品图":
        "⚠️ Redaction preview unavailable (no screen pixels) — marks still apply on save",
    "不延时": "No delay",
    "不透明度：现在是 %lld%。点一下换下一档": "Opacity: %lld%% now. Click to cycle.",
    "也可以自己滚 —— 手动模式一样能拼长图":
        "You can also scroll yourself — manual mode stitches the same long image",
    "位移不是有限数值": "The offset is not a finite number",
    "保存位置": "Save location",
    "保存到磁盘并关闭（⌘S）": "Save to disk and close (⌘S)",
    "保存失败：%@ 里同名文件太多，剪贴板里的图仍然可用":
        "Save failed: too many files with the same name in %@. The image is still on the clipboard.",
    "先框出一块区域，再点识别": "Select a region first, then click Recognize",
    "全屏切换": "Toggle full screen",
    "全屏截图": "Full-screen capture",
    "全部复制": "Copy All",
    "关掉这张钉图": "Close this pin",
    "关闭": "Close",
    "删除": "Delete",
    "取消（丢弃刚画的标注，不改剪贴板）": "Cancel (discard annotations, clipboard untouched)",
    "只有 ⇧ 不够，会和普通输入冲突，请带上 ⌘ ⌃ 或 ⌥":
        "⇧ alone is not enough — it collides with normal typing. Add ⌘, ⌃ or ⌥.",
    "图片格式": "Image format",
    "在 Finder 中显示": "Show in Finder",
    "在编辑器里打开（原有的标注仍可编辑）": "Open in editor (existing annotations stay editable)",
    "在选区内拖动即可标注  ·  再点一次工具图标取消  ·  Esc 取消工具":
        "Drag inside to annotate · tap the tool again to cancel · Esc leaves the tool",
    "太短，丢弃": "Too short, discarded",
    "好": "OK",
    "字号": "Font size",
    "完成（复制到剪贴板并关闭）": "Done (copy to clipboard and close)",
    "尚未实现：%@": "Not implemented yet: %@",
    "已停止自动滚动": "Auto-scroll stopped",
    "已复制 %@": "Copied %@",
    "已生效：%@": "Active: %@",
    "已获得屏幕录制权限。请退出并重新打开 Marquee，权限才会生效":
        "Screen Recording permission granted. Quit and reopen Marquee for it to take effect.",
    "已落一个": "Placed",
    "已选中 %lld 个标注  ·  拖动移动  ·  Delete 删除  ·  Esc 取消选择":
        "%lld annotation(s) selected  ·  Drag to move  ·  Delete to remove  ·  Esc to deselect",
    "序号": "Counter",
    "应用切换": "App switcher",
    "延时截图": "Delayed capture",
    "开机时自动启动": "Launch at login",
    "当前：%@": "Current: %@",
    "快捷键": "Shortcuts",
    "快捷键没有生效": "The shortcut didn't take effect",
    "截图后播放提示音": "Play a sound after each capture",
    "截图失败：%@": "Capture failed: %@",
    "截图没有完成": "The capture didn't finish",
    "截图编码为 %@ 失败，剪贴板里的图仍然可用":
        "Failed to encode the image as %@. The image is still on the clipboard.",
    "截图编码为 PNG 失败": "Failed to encode the image as PNG",
    "截图里包含鼠标指针": "Include the pointer in captures",
    "截屏": "Capture",
    "打开系统设置": "Open System Settings",
    "打码强度": "Redaction strength",
    "抓帧失败：%@": "Frame capture failed: %@",
    "拖动这里可以移动这张钉图": "Drag here to move this pin",
    "拼接选区图像失败": "Failed to compose the selected region",
    "拼接长图失败": "Failed to stitch the long image",
    "按下新的组合…": "Press a new combination…",
    "按住 ⌥ 取色": "Hold ⌥ to pick a color",
    "描边颜色": "Stroke color",
    "撤销": "Undo",
    "放大": "Zoom In",
    "文件名模板": "File name template",
    "文字": "Text",
    "文字标注 ABC": "Text annotation ABC",
    "无": "None",
    "未知原因": "Unknown reason",
    "无法写入 %@：%@。剪贴板里的图仍然可用":
        "Couldn't write %@: %@. The image is still on the clipboard.",
    "无法创建保存目录 %@：%@。剪贴板里的图仍然可用":
        "Couldn't create the save folder %@: %@. The image is still on the clipboard.",
    "最近截图": "Recent Captures",
    "权限已经勾选，但 macOS 要求应用重启后才生效。\n请退出 Marquee（菜单栏图标 → 退出 Marquee）再重新打开。":
        "The permission is ticked, but macOS requires an app restart for it to take effect.\n"
        "Quit Marquee (menu bar icon → Quit Marquee) and open it again.",
    "标注": "Annotate",
    "标注没能合成到截图上，这次截图已放弃（避免交出未处理的图）":
        "The annotations couldn't be rendered onto the capture, so it was discarded (rather than handing you an unprocessed image)",
    "椭圆": "Ellipse",
    "模糊": "Blur",
    "横向漂移 %lld px，画面不在做竖直滚动":
        "%lld px of horizontal drift — the content isn't scrolling vertically",
    "正在滚动…（第 %lld 屏）": "Scrolling… (frame %lld)",
    "正在识别文字…": "Recognizing text…",
    "没找到 ID 为 %u 的显示器": "No display with ID %u",
    "没找到可用的显示器": "No usable display found",
    "没找到窗口 %u，它可能已经关掉了": "No window with ID %u — it may have been closed",
    "没找到鼠标所在的显示器，请把鼠标移到要截的屏幕上再试":
        "Couldn't find the display under the pointer. Move the pointer onto the screen you want and try again.",
    "没检测到滚动…继续往下滚": "No scrolling detected… keep scrolling down",
    "注册快捷键失败（错误码 %d）": "Failed to register the shortcut (error %d)",
    "滚动截屏": "Scrolling Capture",
    "滚动步数已达上限，按 ⏎ 结束": "Reached the step limit. Press ⏎ to finish.",
    "点一个标注选中它  ·  拖角改大小  ·  选个工具可直接标注":
        "Click an annotation to select it  ·  Drag a corner to resize  ·  Pick a tool to annotate",
    "点击复制": "Click to copy",
    "点击复制到剪贴板": "Click to copy to clipboard",
    "画笔": "Pen",
    "画面尺寸发生了变化（%lld×%lld → %lld×%lld）":
        "The frame size changed (%lld×%lld → %lld×%lld)",
    "看起来已经滚到底了 · 还可以继续滚，或按 ⏎ 结束":
        "Looks like you've hit the bottom · You can keep scrolling, or press ⏎ to finish",
    "看起来已经滚到底了，按 ⏎ 结束": "Looks like you've hit the bottom. Press ⏎ to finish.",
    "矩形": "Rectangle",
    "稍后": "Later",
    "窗口切换": "Window switcher",
    "窗口截图带阴影": "Shadow on window captures",
    "箭头": "Arrow",
    "系统截图（全屏）": "System screenshot (screen)",
    "系统截图（工具条）": "System screenshot (toolbar)",
    "系统截图（触控栏）": "System screenshot (Touch Bar)",
    "系统截图（选区）": "System screenshot (selection)",
    "系统没有接受这个设置（%@）。开发构建通常是签名问题，正式安装包不受影响。":
        "macOS didn't accept this setting (%@). In development builds that's usually a signing issue; "
        "release builds are unaffected.",
    "线宽": "Line width",
    "继续往下滚，或按空格自动滚 · ⏎ 结束 · ⌘S 结束并保存 · Esc 取消":
        "Keep scrolling, or press Space to auto-scroll · ⏎ finish · ⌘S save · Esc cancel",
    "编辑": "Edit",
    "缩小": "Zoom Out",
    "自动滚动中 · 空格停止 · Esc 停止（已拼的保留） · ⏎ 结束":
        "Auto-scrolling · Space to stop · Esc to stop (keeps what's stitched) · ⏎ to finish",
    "自动滚动需要「辅助功能」授权（系统设置 → 隐私与安全性 → 辅助功能）。":
        "Auto-scroll needs Accessibility · System Settings → Privacy & Security → Accessibility",
    "自动滚动需要「辅助功能」授权；也可以自己滚（手动模式）":
        "Auto-scroll needs Accessibility permission; you can also scroll yourself (manual mode)",
    "至少要有一个修饰键（⌘ ⌃ ⌥）": "At least one modifier key is required (⌘ ⌃ ⌥)",
    "表情与符号": "Emoji & Symbols",
    "裁切": "Crop",
    "裁切中：回车应用 · Esc 取消": "Cropping: Return to apply · Esc to cancel",
    "设置…": "Settings…",
    "识别中…": "Recognizing…",
    "识别到 %lld 行 · %lld 字 · ": "%lld lines · %lld characters · ",
    "识别失败": "Recognition failed",
    "识别失败：%@": "Recognition failed: %@",
    "识别完成": "Recognized",
    "识别文字": "Recognize Text",
    "请到「系统设置 → 隐私与安全性 → 屏幕录制」里勾选 Marquee，然后退出并重新打开应用。\n\n如果列表里找不到 Marquee：点「在 Finder 中显示」，把打开的 Marquee 拖进列表（或点列表下方的「+」选中它）。":
        "Tick Marquee under System Settings → Privacy & Security → Screen Recording, then quit and reopen the app.\n\n"
        "If Marquee isn't in the list: click Show in Finder and drag the opened Marquee into the list "
        "(or pick it with the “+” button below the list).",
    "质量": "Quality",
    "输入文字": "Type text",
    "输入文字 · ⏎ 确认 · Esc 放弃": "Type text · ⏎ to confirm · Esc to discard",
    "输出": "Output",
    "还没拿到这块区域的像素 —— 稍等一下再点一次":
        "The pixels for this region aren't ready yet — wait a moment and click again",
    "这一帧可信度不足（%@）": "This frame isn't reliable enough (%@)",
    "这一帧没对齐：%@": "This frame didn't align: %@",
    "这一帧滚动幅度过大（%lld 行），与前帧几乎不重叠，没法对齐":
        "This frame scrolled too far (%lld rows) and barely overlaps the previous one, so it can't be aligned",
    "这个组合已被系统占用：%@": "That combination is taken by the system: %@",
    "这台机器上没有可用的文字识别（Vision 不可用）":
        "Text recognition isn't available on this machine (Vision unavailable)",
    "这张图没能重新合成出来": "The image couldn't be re-composed",
    "这张图的文件已经不在了（可能被清理过）":
        "The file for this image is gone (it may have been cleaned up)",
    "这张图里没有识别到文字": "No text was recognized in this image",
    "连续采不到画面，自动滚动已停下": "Couldn't capture any frames in a row — auto-scroll stopped",
    "退出 Marquee": "Quit Marquee",
    "选区太小，或者不落在任何显示器上": "The selection is too small, or doesn't land on any display",
    "选择": "Select",
    "选择…": "Choose…",
    "选这个文件夹": "Choose This Folder",
    "通用": "General",
    "配准失败：%@": "Alignment failed: %@",
    "重做": "Redo",
    "锁定屏幕": "Lock Screen",
    "长图已达 %lld px 上限，按 ⏎ 结束": "The long image hit the %lld px limit. Press ⏎ to finish.",
    "长图已达高度上限，按 ⏎ 结束": "The long image hit the height limit. Press ⏎ to finish.",
    "长截图区域太小，或者不落在任何显示器上":
        "The scrolling region is too small, or doesn't land on any display",
    "长截图已取消": "Scrolling capture cancelled",
    "长截图没有采到任何画面": "Scrolling capture didn't capture any frames",
    "长截图起步失败：%@": "Couldn't start the scrolling capture: %@",
    "长截图还没开始，没法自动滚动": "The scrolling capture hasn't started, so there's nothing to auto-scroll",
    "长截图：拖出要滚动的区域，或单击要滚动的窗口":
        "Scrolling capture: drag out the region to scroll, or click the window to scroll",
    "隐藏当前应用": "Hide current app",
    "马赛克": "Mosaic",
    "鼠标穿透：关着。点开后点击会落到下面的应用":
        "Click-through: off. Turn it on and clicks fall through to the app below.",
    "鼠标穿透：开着（点击会落到下面的应用）。点一下关掉":
        "Click-through: on (clicks fall through to the app below). Click to turn it off.",
    "，已停止拼接；按 ⏎ 结束可保留已拼好的部分":
        ", stitching stopped; press ⏎ to finish and keep what's already stitched",
    "，已拼好的部分保留可用，按 ⏎ 结束":
        ", what's stitched so far stays usable; press ⏎ to finish",

    # ── 升级卡片（ticket 31）──────────────────────────────────────────────
    # ⚠️ 四个入口的标题**刻意写成整句**，不做 "\(入口名)是 Pro 能力" 那种拼接：
    #    拼接既把中文语序焊死，也会让生成器按表达式名猜错说明符类型
    #    （详见 SelectionOverlayView.cardTitle 的注释）。
    "滚动截屏是 Pro 能力": "Scrolling capture is a Pro feature",
    "识别文字是 Pro 能力": "Text recognition is a Pro feature",
    "钉图是 Pro 能力": "Pinning to screen is a Pro feature",
    "最近截图是 Pro 能力": "Unlimited history is a Pro feature",
    "这个账号下找不到这笔购买": "No purchase found for this account",
    # ⚠️ 这三个按钮的英文长度是**量出来的**：主按钮 + 10 + 次按钮 必须 ≤ 卡片内宽 268。
    # 原先写的 "Start a 7-day free trial" + "Learn about Pro" 合起来 272 —— 差 4 点就放不下，
    # 而超出的表现是**次按钮被裁掉尾巴**（英文系统上才看得见）。
    # 判据在 `LocalizationScanTests`。
    "7 天免费试用": "Try 7 days free",
    "了解 Pro": "Learn about Pro",
    "恢复购买": "Restore Purchase",
    "需要 Pro": "Requires Pro",

    # ── 偏好「通用」页底部的 Pro 状态区（ticket 31）──────────────────────
    # ⚠️ 状态行**从判定整句推**，不在这里拼「状态 + 余量」——
    #    与卡片标题同一条理由（见 ProCardRenderer.title 的注释）。
    "Marquee Pro · 正在确认…": "Marquee Pro · Checking…",
    "Marquee Pro · 免费版（最近截图保留 %lld 张）":
        "Marquee Pro · Free (keeps the last %lld captures)",
    "Marquee Pro · 试用中，还剩 %lld 天": "Marquee Pro · Trial, %lld days left",
    "Marquee Pro · 已购买，谢谢": "Marquee Pro · Purchased, thank you",
    "Marquee Pro · 这笔购买已被撤销": "Marquee Pro · This purchase was revoked",
    "Marquee Pro · 这个账号下找不到这笔购买":
        "Marquee Pro · No purchase found for this account",
    "升级到 Pro": "Upgrade to Pro",
    # 偏好页那颗按钮带上价格 —— "点之前看得见"。拿不到价格时退回上面那条。
    "升级到 Pro · %@": "Upgrade to Pro · %@",
    "已购买": "Purchased",
    "这个账号下没有可恢复的购买": "No purchases to restore for this account",

    # ── 最近截图面板的配额说明（ticket 31）──────────────────────────────

    # ── 首次启动的引导（ticket 34）──────────────────────────────────────
    #
    # ⚠️ 引导是**一页**，不是三步（2026-10-03 合并）。文案原则：能删就删 ——
    # 引导页没人会读完，每句都要回答一个问题，答不上就删。
    # 原先那六行「能力 —— 说明」和「上一步 / 继续」整段砍掉了，
    # 所以这里的条目比第一版**少一大截**：那不是漏翻，是那些 key 已经不存在。
    "欢迎使用 Marquee": "Welcome to Marquee",
    "Marquee 就在菜单栏": "Marquee lives in the menu bar",
    "按一下快捷键，屏幕冻住，框出要截的地方。":
        "Press the shortcut, the screen freezes, and you drag out what you want.",
    "截图 · 标注 · 滚动截屏 · 识别文字 · 钉图":
        "Capture · Annotate · Scrolling capture · Text recognition · Pin",
    "截屏快捷键": "Capture shortcut",
    "屏幕录制：已授权": "Screen Recording: granted",
    "屏幕录制：还没授权": "Screen Recording: not granted yet",
    "开始使用": "Get started",
    "已生效：%@": "Active: %@",

    # ⚠️ 下面这两句**看着像引导里的**，其实菜单与工具条也在用 ——
    # 删掉它们不会变成"孤儿"，而是变成"缺翻译"。
    "滚动截屏": "Scrolling capture",
    "识别文字": "Text recognition",

    # 自动滚动的两种「不能用」（ticket 32）。⚠️ 这两句**不能混用** ——
    # 沙盒里让用户去勾辅助功能，是把他送去做一件注定没用的事。
    "这个版本不提供自动滚动：沙盒不允许代替你操作别的应用。":
        "This version doesn't offer auto-scroll: the sandbox doesn't allow acting on other apps.",
    "自己滚一样能拼长图 —— 手动模式没受影响":
        "Scrolling yourself works just as well — manual mode is unaffected",
}

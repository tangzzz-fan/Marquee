# -*- coding: utf-8 -*-
"""英文翻译。key 与源码里 L10n.t("…") 的 key 逐字一致（插值已归一成 %lld / %@）。"""

EN = {
    "开发版": "Development build",
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
    "%@ px · %lld 个标注": "%@ px · %lld annotations",
    "%lld 秒": "%lld seconds",
    "JPEG / HEIC 有损，可调质量": "JPEG and HEIC are lossy; quality is adjustable",
    "Marquee 常驻菜单栏，开机自启后随时按快捷键就能截":
        "Marquee lives in the menu bar; with this on, the shortcut works right after you log in",
    "Marquee 设置": "Marquee Settings",
    "Marquee 需要「屏幕录制」权限": "Marquee needs Screen Recording permission",
    "PNG（无损）": "PNG (lossless)",
    "Vision 没有返回平移观测值": "Vision returned no translation observation",
    "⚠️ 打码预览不可用（没拿到屏幕像素）—— 标记仍然会写进成品图":
        "⚠️ Redaction preview unavailable (no screen pixels) — the marks will still be applied to the saved image",
    "不延时": "No delay",
    "不透明度：现在是 %lld%。点一下换下一档": "Opacity: %lld%% now. Click to cycle.",
    "也可以自己滚 —— 手动模式一样能拼长图":
        "You can also scroll yourself — manual mode stitches the same long image",
    "从历史里删掉（连磁盘上的文件一起清）": "Delete from history (removes the file on disk too)",
    "位移不是有限数值": "The offset is not a finite number",
    "保存位置": "Save location",
    "保存到磁盘并关闭（⌘S）": "Save to disk and close (⌘S)",
    "保存失败：%@ 里同名文件太多，剪贴板里的图仍然可用":
        "Save failed: too many files with the same name in %@. The image is still on the clipboard.",
    "先框出一块区域，再点识别": "Select a region first, then click Recognize",
    "全局生效，应用不在前台也能触发": "Works globally, even when the app is in the background",
    "全屏切换": "Toggle full screen",
    "全屏截图": "Full-screen capture",
    "全部复制": "Copy All",
    "关掉这张钉图": "Close this pin",
    "关闭": "Close",
    "删除": "Delete",
    "取消（丢弃刚画的标注，不改剪贴板）": "Cancel (discard annotations, clipboard untouched)",
    "只在有损格式下有效": "Only applies to lossy formats",
    "只有 ⇧ 不够，会和普通输入冲突，请带上 ⌘ ⌃ 或 ⌥":
        "⇧ alone is not enough — it collides with normal typing. Add ⌘, ⌃ or ⌥.",
    "只有按 ⌘S 或点「保存」时才写盘": "Written to disk only on ⌘S or Save",
    "可用变量：{date} {time} {n} {app} {title}": "Available: {date} {time} {n} {app} {title}",
    "图片格式": "Image format",
    "在 Finder 中显示": "Show in Finder",
    "在编辑器里打开（原有的标注仍可编辑）": "Open in editor (existing annotations stay editable)",
    "在覆盖层里按 ⌥ 可以临时反过来": "Hold ⌥ in the overlay to flip it temporarily",
    "在选区内拖动即可标注  ·  再点一次工具图标取消  ·  Esc 取消工具":
        "Drag inside the selection to annotate  ·  Click the tool again to deselect  ·  Esc to leave the tool",
    "太短，丢弃": "Too short, discarded",
    "好": "OK",
    "字号": "Font size",
    "完成（复制到剪贴板并关闭）": "Done (copy to clipboard and close)",
    "尚未实现：%@": "Not implemented yet: %@",
    "已停止自动滚动": "Auto-scroll stopped",
    "已加入系统登录项。可在「系统设置 → 通用 → 登录项」里查看":
        "Added to login items. Check System Settings → General → Login Items.",
    "已复制 %@": "Copied %@",
    "已生效：%@": "Active: %@",
    "已获得屏幕录制权限。请退出并重新打开 Marquee，权限才会生效":
        "Screen Recording permission granted. Quit and reopen Marquee for it to take effect.",
    "已落一个": "Placed",
    "已选中 %lld 个标注  ·  拖动移动  ·  Delete 删除  ·  Esc 取消选择":
        "%lld annotation(s) selected  ·  Drag to move  ·  Delete to remove  ·  Esc to deselect",
    "序号": "Counter",
    "序号从几开始（后续每放一个自增）": "Starting number (increments with each new one)",
    "应用切换": "App switcher",
    "延时截图": "Delayed capture",
    "开机时自动启动": "Launch at login",
    "当前：%@": "Current: %@",
    "快捷键": "Shortcuts",
    "快捷键没有生效": "The shortcut didn't take effect",
    "恢复默认（⌃Q）": "Restore default (⌃Q)",
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
    "拖角改大小 · 框内拖动移动  ·  选个工具可直接标注  ·  ⏎ 确认  ·  Esc 取消":
        "Drag a corner to resize · Drag inside to move  ·  Pick a tool to annotate  ·  ⏎ to confirm  ·  Esc to cancel",
    "拼接选区图像失败": "Failed to compose the selected region",
    "拼接长图失败": "Failed to stitch the long image",
    "按下快捷键后等几秒再出现选择框，方便先把画面摆好":
        "Wait a few seconds after the shortcut before the selection appears, so you can set the screen up first",
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
    "点上面的方框后按下新的组合；Esc 取消。与系统或其他应用冲突时会明确告诉你。":
        "Click the box above, then press a new combination; Esc cancels. "
        "Conflicts with the system or other apps are reported explicitly.",
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
        "Keep scrolling, or press Space to auto-scroll · ⏎ to finish · ⌘S to finish and save · Esc to cancel",
    "编辑": "Edit",
    "缩小": "Zoom Out",
    "自动滚动中 · 已拼 %lld px · %lld 帧": "Auto-scrolling · %lld px stitched · %lld frames",
    "自动滚动中 · 空格停止 · Esc 停止（已拼的保留）· ⏎ 结束":
        "Auto-scrolling · Space to stop · Esc to stop (keeps what's stitched) · ⏎ to finish",
    "自动滚动需要「辅助功能」授权（系统设置 → 隐私与安全性 → 辅助功能）。":
        "Auto-scroll needs Accessibility permission (System Settings → Privacy & Security → Accessibility).",
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
    "还没有截图。按 ⌃Q 截一张，它会出现在这里。":
        "No captures yet. Press ⌃Q to take one — it will show up here.",
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
    "连着截很多张时想安静一点可以关掉": "Turn this off if you take many captures in a row and want it quieter",
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
    "长截图 · 已拼 %lld px · %lld 帧": "Scrolling capture · %lld px stitched · %lld frames",
    "长截图区域太小，或者不落在任何显示器上":
        "The scrolling region is too small, or doesn't land on any display",
    "长截图已取消": "Scrolling capture cancelled",
    "长截图已开始 · 往下滚": "Scrolling capture started · scroll down",
    "长截图没有采到任何画面": "Scrolling capture didn't capture any frames",
    "长截图起步失败：%@": "Couldn't start the scrolling capture: %@",
    "长截图还没开始，没法自动滚动": "The scrolling capture hasn't started, so there's nothing to auto-scroll",
    "长截图：拖出要滚动的区域，或单击要滚动的窗口":
        "Scrolling capture: drag out the region to scroll, or click the window to scroll",
    "隐藏当前应用": "Hide current app",
    "马赛克": "Mosaic",
    "默认不带 —— 指针会挡在内容上": "Off by default — the pointer would cover the content",
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
    "一次买断，不订阅": "One-time purchase, not a subscription",
    "试用已结束，购买后继续使用": "Your trial has ended. Purchase Pro to keep using it.",
    "购买被撤销：退款，或移出家人共享":
        "This purchase was revoked: refunded, or removed from Family Sharing",
    "这个账号下找不到这笔购买": "No purchase found for this account",
    "7 天免费试用": "Start a 7-day free trial",
    "了解 Pro": "Learn about Pro",
    "恢复购买": "Restore Purchases",
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
    "已购买": "Purchased",
    "已恢复购买": "Purchases restored",
    "这个账号下没有可恢复的购买": "No purchases to restore for this account",
    "恢复失败，请检查网络后重试": "Restore failed. Check your connection and try again.",

    # ── 最近截图面板的配额说明（ticket 31）──────────────────────────────
    "免费版只保留最近 %lld 张 · 升级到 Pro 可保留全部":
        "The free version keeps the last %lld captures · Upgrade to Pro to keep them all",

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

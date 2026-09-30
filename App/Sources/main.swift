import AppKit

// Marquee 是菜单栏常驻应用：没有 Dock 图标，也没有主窗口。
//
// 用 .accessory 而不是 .prohibited —— 后者会让应用无法可靠地接收键盘焦点，
// 而覆盖层必须能响应键盘（Esc 取消、方向键微调、回车提交）。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = MarqueeAppDelegate()
application.delegate = delegate

application.run()

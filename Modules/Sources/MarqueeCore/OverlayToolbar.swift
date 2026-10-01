import CoreGraphics

/// 覆盖层上那排浮动工具栏的**几何约定与位置计算**（ticket 20）。
///
/// ## 为什么放 Core
///
/// 位置计算要能单测 —— 贴边、翻面、跨屏这几种情况靠肉眼试不全，
/// 而一旦算错，表现是"工具栏跑出屏幕了"或"它盖住了选区"，
/// 用户只会说"那个条没了"，不会告诉你它跑到哪去了。
///
/// 尺寸也放在这里，是为了让**绘图层与命中测试用同一个数**：
/// 两边各写一份的话，命中区会偏出去几个点，表现是"按钮点不准"。
public enum OverlayToolbar {

    public static let buttonSize: CGFloat = 32
    /// 按钮之间的间距
    public static let buttonSpacing: CGFloat = 4
    /// 工具条自身的内边距
    public static let padding: CGFloat = 6
    /// 工具条与选区之间的间距
    public static let gap: CGFloat = 10
    /// 两组之间的空隙（左边一个「编辑」，右边「取消 / 完成」）
    public static let groupingGap: CGFloat = 14
    /// 夹取时与屏幕边缘留的余量
    public static let screenMargin: CGFloat = 8

    /// 工具条尺寸（点）。
    ///
    /// 三个按钮的宽度由 [`buttonSize`] 推出，不写死 ——
    /// 否则以后加一个按钮就要同时改三处（这里、绘制、命中）。
    ///
    /// 排布（从左到右）：`padding │ edit │ groupingGap │ cancel │ buttonSpacing │ confirm │ padding`
    public static var toolbarSize: CGSize {
        let width = buttonSize * 3 + groupingGap + buttonSpacing + padding * 2
        return CGSize(width: width, height: buttonSize + padding * 2)
    }

    /// 算出工具栏该放在哪（**Cocoa 全局点**，y 向上）。
    ///
    /// 与读数框（`SelectionOverlayView.drawReadout`）同一套思路：
    /// 优先贴在选区**下方**；下方空间不够就翻到上方；最后统一夹进屏幕可见区。
    ///
    /// ⚠️ **夹取必须最后做**。先夹再翻会得到"翻上去之后又被夹回屏幕外"这种组合 ——
    /// 两个规则各自都对，顺序一错结果就错，而且只在贴边的选区上出现。
    ///
    /// - Parameters:
    ///   - selection: 选区（Cocoa 全局点）
    ///   - screenFrame: 所在屏的可见区域（已扣掉菜单栏 / Dock）
    public static func frame(for selection: CGRect,
                             screenFrame: CGRect,
                             toolbarSize: CGSize? = nil,
                             gap: CGFloat = gap) -> CGRect {
        let size = toolbarSize ?? Self.toolbarSize
        let box = selection.standardized
        let screen = screenFrame.standardized

        // ① 优先：选区正下方，左对齐
        var origin = CGPoint(x: box.minX, y: box.minY - gap - size.height)
        // ② 下方放不下 → 翻到上方
        if origin.y < screen.minY {
            origin.y = box.maxY + gap
        }
        // ③ 最后统一夹进屏幕（水平竖直都要）
        //
        // 屏幕比工具栏还小时（外接小屏、可见区被 Dock 压得很矮），
        // `maxX`/`maxY` 会算成比 `minX`/`minY` 更小的值 —— 用 `max` 兜住，
        // 那样至少保证"左上角在屏幕内、尺寸不变"，而不是算出个反向矩形。
        let minX = screen.minX + screenMargin
        let maxX = max(minX, screen.maxX - screenMargin - size.width)
        let minY = screen.minY + screenMargin
        let maxY = max(minY, screen.maxY - screenMargin - size.height)
        origin.x = min(max(minX, origin.x), maxX)
        origin.y = min(max(minY, origin.y), maxY)

        return CGRect(origin: origin, size: size)
    }

    /// 工具条里**每个按钮**的位置（Cocoa 全局点，坐标原点在工具条左下角）。
    ///
    /// 与 `toolbarSize` 用同一套常量推导 —— 绘制和命中测试都调它，
    /// 于是"看到的框"和"点得到的区域"不可能对不上。
    public enum Button: CaseIterable, Sendable {
        /// 打开编辑器（过渡入口：覆盖层内的标注能力要到 ticket 22 才齐）
        case edit
        /// 丢弃标注，关闭覆盖层，剪贴板不变
        case cancel
        /// 栅格化 + 写剪贴板 + 关闭覆盖层
        case confirm
    }

    /// 按钮在工具条内部的偏移（从左下角算起）。
    ///
    /// ⚠️ 这里的算式必须与 `toolbarSize` 的分组顺序**完全一致**。
    /// 写这段时我就犯过一次：宽度按"间距在中间"算、偏移按"间距在末尾"算，
    /// 差了 4 点 —— 结果最后一个按钮会探出工具条右边一点。
    /// `OverlayToolbarTests.buttonsFitInsideToolbar` 就是钉这个的。
    public static func offset(of button: Button) -> CGPoint {
        let left = padding
        switch button {
        case .edit:
            return CGPoint(x: left, y: padding)
        case .cancel:
            return CGPoint(x: left + buttonSize + groupingGap, y: padding)
        case .confirm:
            return CGPoint(x: left + buttonSize * 2 + groupingGap + buttonSpacing, y: padding)
        }
    }

    /// 按钮的命中区域（传工具栏自身的矩形，返回 Cocoa 全局点下的按钮矩形）。
    public static func hitFrame(of button: Button, in toolbar: CGRect) -> CGRect {
        let point = offset(of: button)
        return CGRect(x: toolbar.minX + point.x,
                      y: toolbar.minY + point.y,
                      width: buttonSize,
                      height: buttonSize)
    }

    /// 点在哪个按钮上（`nil` = 不在任何按钮上）。
    ///
    /// 顺序无所谓（按钮互不重叠），但用 `allCases` 遍历而不是写死三个 `if` ——
    /// 以后加按钮时不必再改这里。
    public static func button(at point: CGPoint, in toolbar: CGRect) -> Button? {
        Button.allCases.first { hitFrame(of: $0, in: toolbar).contains(point) }
    }
}

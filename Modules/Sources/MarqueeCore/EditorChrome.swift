import CoreGraphics
import Foundation

/// 编辑器窗口的**几何与文案**：窗口尺寸、工具条整条的排布、状态行。
///
/// ## 为什么这一块要放 Core
///
/// 与 `ChromeControl` / `OverlayToolbar` 同一条脉络：一堆单独看都普通、
/// 改错了却**不会报错**的数。而编辑器这一条还多一个特点 ——
/// **整条工具条是"窗口满宽"的，所以它有一个下限**：排不下就会挤（`Spacer` 缩成 0
/// 之后溢出部分被直接裁掉），而"被裁掉"的那一头正好是**最右边那几个动作**
/// （历史上有过一次：用户报「OCR 入口我不知道在哪」，其实是它压根没画出来）。
///
/// 所以这里提供 `minimumToolbarWidth`：把整条上每一件的宽度加起来，
/// 再由测试保证它**放得进窗口宽度**。这与覆盖层那条「整条必须放得进 1024 点的屏」
/// 是同一条纪律，只是换了个界面。
///
/// ## 与设计稿的两次记账
///
/// 1. **工具条 40 → 48**：常驻的色板托盘（34）与尺寸芯片（38）放不进 40。
///    48 = 5 + 38 + 5 —— 内边距、格 28、圆角、点亮规则全部未动，
///    条高是**跟着最高的那件长出来的**，只长一次（不随内容变）。
/// 2. **画布 690，不是稿子写的 688**：稿子按 48 + 688 + 22 = 758 算，
///    而窗口是 760 —— 差的 2 点是它把工具条的 1px 下边线与状态行的 1px 上边线
///    各算了一次。画布取**剩下的全部**，因为它才是这扇窗存在的理由。
public enum EditorChrome {

    // MARK: - 窗口

    /// 窗口默认尺寸。稿子 §03：「整窗 1200 × 760」。
    public static let defaultWindowSize = CGSize(width: 1200, height: 760)

    /// 窗口最小尺寸。
    ///
    /// ⚠️ **宽度不是拍的**：它是整条工具条所需的最小宽度（`minimumToolbarWidth`）。
    /// 再窄一点，右边那几格就会被挤出可视区 —— 而那种情况**不会崩、不会报错**，
    /// 只是有几个按钮"不存在"。宁可不让用户缩到那么窄。
    public static var minimumWindowSize: CGSize {
        CGSize(width: minimumToolbarWidth() + 8, height: 560)
    }

    // MARK: - 工具条（= 标题栏）

    /// 条高。稿子 §04：「48 = 5 + 38 + 5」。
    public static let toolbarHeight: CGFloat = 48
    /// 条的内边距（四周同值）。稿子：「内边距 5」。
    public static let toolbarPadding: CGFloat = 5
    /// 相邻两件之间的间隙。稿子：`.ebar{gap:2px}`。
    public static let toolbarGap: CGFloat = 2

    /// 红绿灯那一簇占掉的宽度。
    ///
    /// 稿子：`.tls{gap:8px;padding:0 12px 0 8px}` + 三颗 `.tl{12×12}`
    /// ⇒ 8 + 12 + 8 + 12 + 8 + 12 + 12 = **72**。
    ///
    /// ⚠️ 这里是**系统**画的红绿灯（不是自绘），我们只能**把位置让出来**。
    /// 72 与 macOS 自己那三颗所占的宽度几乎相等（它们从 x≈12 起、间距 20），
    /// 所以让出来之后，它们看起来仍在自己该在的地方。
    public static let trafficLightsWidth: CGFloat = 72

    /// 格子（工具 / 动作）。稿子：`.cell{width:28px;height:28px;border-radius:6px}`。
    public static let cellSize: CGFloat = 28
    /// 格子的圆角。稿子：「6」。**与覆盖层的 10 不同**：那边的格是 28 点里画 16 点图标、
    /// 圆角 10 是为了托住整条工具条的形状；这里是窗口满宽的一条，格子小、圆角也就小。
    public static let cellCornerRadius: CGFloat = 6

    /// 分组竖线。稿子：`.vsep{width:1px;height:18px;margin:0 6px}`。
    public static let separatorSize = CGSize(width: 1, height: 18)
    /// 竖线自己左右各让出的距离（不含 `toolbarGap`）。
    public static let separatorMargin: CGFloat = 6

    /// `✗` 前面额外让开的距离。稿子：`.cell.gap{margin-left:8px}` ——
    /// 「取消与完成永远压在最右，且 ✗ 前让开 8」，免得误点到 ✗。
    public static let gapBeforeCancel: CGFloat = 8

    // MARK: - 色板托盘（从覆盖层的「样式」弹层搬进条上）

    /// 托盘。稿子 §04：「托盘 174 × 34（④ 的 `.tray` 逐字）」。
    ///
    /// 174 = 6×2（内边距）+ 22×6（六个色块）+ 6×5（五个间隙）。
    /// 色板坐在**内底**上才够对比度 —— 那正是它带一块托盘而不是六个裸色块的原因。
    public static let traySize = CGSize(width: 174, height: 34)
    /// 一个色块。稿子：`.sw{width:22px;height:22px;border-radius:5px}`。
    public static let swatchSize: CGFloat = 22
    public static let swatchGap: CGFloat = 6

    // MARK: - 尺寸三档（芯片 + 常显读数）

    /// 尺寸芯片。稿子 §08：「芯片 54 × 38 · 间隙 6」。
    public static let chipSize = CGSize(width: 54, height: 38)
    public static let chipGap: CGFloat = 6

    /// 芯片右边那个**常显读数**（「8 px」）的预算宽度。
    ///
    /// 它随本地化变（英文也是「8 px」，但字号与字体不同），所以量出来的宽度
    /// 由调用方传（`minimumToolbarWidth(sizeReadoutTextWidth:)`）。
    /// 这里给的是**算窗口下限时的预算**：三位数字 + 空格 + 单位 —— 编辑器最大的那档是 88，
    /// 而 `88 px` 在 12 点等宽字下约 40 点，44 够用且留了一点余量。
    public static let sizeReadoutWidth: CGFloat = 44

    // MARK: - 缩放

    /// `−` / `+` 两格。稿子 §04：「24 · 44 · 24」。
    public static let zoomStepSize: CGFloat = 24
    /// 中间那个百分数。**点它回「适应窗口」**。
    public static let zoomLabelWidth: CGFloat = 44

    // MARK: - 状态行（窗口地板）

    /// 状态行高。稿子 §10：「22 高，窗口地板」，复用 ④ 的 `.strip`。
    public static let statusLineHeight: CGFloat = 22
    public static let statusLinePadding: CGFloat = 12

    // MARK: - 画布

    /// 画布高度 = 窗口高 − 工具条 − 状态行。**剩下的全部给它**。
    public static func canvasHeight(windowHeight: CGFloat) -> CGFloat {
        max(1, windowHeight - toolbarHeight - statusLineHeight)
    }

    // MARK: - 整条工具条的宽度

    /// 编辑器工具条上的**分组**，从左到右。顺序即排布顺序。
    public enum ToolbarGroup: String, CaseIterable, Sendable {
        /// 八个标注工具（矩形…模糊）
        case annotationTools
        /// 第九格：裁切（**前面单独一条分隔线**，因为它改的是画布不是标注）
        case crop
        /// 六个色块 + 托盘
        case colorTray
        /// 三张尺寸芯片 + 常显读数
        case sizeChips
        /// `−` 百分数 `+`
        case zoom
        /// 右簇：识别文字 ｜ 撤销 · 重做 ｜ 保存 ‖ ✗ ✓
        case actions
    }

    /// 标注工具的个数（不含裁切）。稿子：「1–8 标注工具 ｜ 9 裁切」。
    public static let annotationToolCount = 8

    /// 一条分组竖线的总占宽（含它自己左右的余量与两侧的 `toolbarGap`）。
    public static var separatorWidth: CGFloat {
        toolbarGap + separatorMargin + separatorSize.width + separatorMargin + toolbarGap
    }

    /// 整条工具条**至少要有多宽**。
    ///
    /// - Parameter sizeReadoutTextWidth: 「8 px」那个常显读数的文字宽度
    ///   （随本地化变，所以由调用方量了传进来 —— 与 `RecentPanel.actionWidth` 同一做法）。
    ///
    /// 每一项都按稿子的实际件数算：见 `docs/design/2026-10-03-编辑器/editor-window.html`
    /// §04 的整条排布。
    public static func minimumToolbarWidth(sizeReadoutTextWidth: CGFloat = sizeReadoutWidth) -> CGFloat {
        var width = toolbarPadding * 2 + trafficLightsWidth
        func add(_ value: CGFloat) {
            width += toolbarGap + value
        }

        // 八格标注工具
        add(CGFloat(annotationToolCount) * cellSize
            + CGFloat(annotationToolCount - 1) * toolbarGap)
        // ｜ 裁切 ｜
        add(separatorWidth)
        add(cellSize)
        add(separatorWidth)
        // 托盘
        add(traySize.width)
        add(separatorWidth)
        // 尺寸芯片 + 读数
        add(3 * chipSize.width + 2 * chipGap)
        add(toolbarGap + sizeReadoutTextWidth)
        add(separatorWidth)
        // 缩放
        add(zoomStepSize + zoomLabelWidth + zoomStepSize)
        // 空档（最小 8，免得左右两簇贴在一起）
        add(8)
        // 右簇：识别文字 + 锁 ｜ 撤销 · 重做 ｜ 保存 ‖ ✗ ✓
        add(cellSize + lockBadgeSize)
        add(separatorWidth)
        add(cellSize + toolbarGap + cellSize)
        add(separatorWidth)
        add(cellSize)
        add(gapBeforeCancel + cellSize + toolbarGap + cellSize)
        return width
    }

    /// 识别文字格子上那枚 Pro 小锁的尺寸。稿子：「9 × 9」（与 ④ 完全同尺寸）。
    public static let lockBadgeSize: CGFloat = 9
}

// MARK: - 状态行文案

public extension EditorChrome {

    /// 编辑器此刻处在哪个模式。它决定状态行**左半边**说什么。
    public enum Mode: Equatable, Sendable {
        /// 常态：说这张图是什么。
        case normal
        /// 手上拿着裁切刀、**框还没拖出来**。
        case croppingWaitingForFrame
        /// 框已经拖出来了（`⏎` 可以应用）。
        case croppingAdjusting
    }

    /// 状态行左半边。
    ///
    /// ⚠️ 裁切进行中时它**换成模式动词**，而不是继续报尺寸 ——
    /// 那一会儿用户脑子里只有一件事："现在按什么"。尺寸并没有消失：
    /// 画布上的读数框那时正在说"裁完多大"（设计稿判断 4）。
    ///
    /// - Parameter segments: 拼接用了多少段。`nil` = 不知道（宿主没传），
    ///   **不编一个数**：状态行是"说真话"的地方，编出来的 4 段比不说更糟。
    public static func leading(pixelSize: CGSize,
                               segments: Int?,
                               mode: Mode = .normal) -> String {
        switch mode {
        case .croppingWaitingForFrame:
            return L10n.t("裁剪中 · 拖出保留框 · Esc 取消")
        case .croppingAdjusting:
            return L10n.t("裁剪中 · ⏎ 应用 · Esc 取消")
        case .normal:
            // ⚠️ 尺寸先拼成字符串再进 `L10n.t`（`String(localized:)` 的整数插值
            // 会按语言加千位分隔符 —— 分辨率是**标识**不是计数，不能出现 `1,440 px`）。
            let dimensions = "\(Int(pixelSize.width.rounded())) × \(Int(pixelSize.height.rounded()))"
            let summary = L10n.t("长截图 · \(dimensions) px")
            guard let segments, segments > 1 else { return summary }
            // ⚠️ 局部名就叫 `summary`：生成器靠**变量名**认格式符（`SPEC_OVERRIDES`），
            // 认成 `%lld` 的话，这条 key 与运行时查的那一条对不上 ——
            // 结果是"英文用户看到一句中文"，而且不报错。
            return L10n.t("\(summary) · \(segments) 段拼接")
        }
    }

    /// 状态行右半边：视图状态。
    ///
    /// 稿子 §03 的整窗图上是「适应窗口 34%」；而键盘那一表写着
    /// 「点缩放的百分数回到『适应窗口』」—— 也就是说**只有当前缩放正好是"适应窗口"
    /// 算出来的那一个时**，才该把「适应窗口」四个字写出来。
    /// 否则那几个字是在替一个已经过去的状态说话（用户手动缩过之后，它就成了错的）。
    public static func trailing(zoomPercent: Int, isFitted: Bool) -> String {
        // ⚠️ 百分号**拼在文案外面**：写成 `L10n.t("适应窗口 \(n)%")` 的话，
        // 那条 key 里会带上一个**孤零零的 `%`**，而它随后会被当成格式串用 ——
        // printf 家族里 `%` 后面缺一个转换符是未定义行为。
        // 百分号在两种语言里都是同一个符号，它本来也不该进文案。
        isFitted ? L10n.t("适应窗口 \(zoomPercent)") + "%" : "\(zoomPercent)%"
    }
}

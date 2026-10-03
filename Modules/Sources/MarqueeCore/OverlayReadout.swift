import CoreGraphics
import Foundation

/// 读数框里一行字**是什么角色**。
///
/// ## 为什么要有这个枚举
///
/// 读数框是覆盖层里唯一一块"同一个框、三种内容"的地方（设计稿 §08）：
/// 落点前它说颜色、落点后说尺寸、按住 `⌥` 时第二行换成"这个 ⌥ 会做什么"。
///
/// 在这之前，行色是**散在控制器里当场挑的**（`NSColor.systemOrange`、`white.withAlphaComponent(0.75)`…），
/// 于是三个问题同时存在：
///
/// 1. 三行的**层级**没人保证 —— 加一行时随手挑个色，主次就乱了；
/// 2. 挑出来的色**不在色板里**，与工具条/弹层那套各走各的；
/// 3. **对比度没有任何东西记得**，而"这行字压在屏幕上读不读得出"靠肉眼试不全。
///
/// 把"角色"做成枚举之后，颜色只有一个来源（`ChromePalette.Overlay.Readout`），
/// 而"每一枚都要够亮""主副只差一档""琥珀要读得出是琥珀"全都变成可执行断言。
///
/// ⚠️ **行色与行数无关**：`primary` 永远是第一行，但第二行**不是**永远是 `secondary` ——
/// 按住 `⌥` 时它是 `caution`。判据是"这一行此刻是什么"，不是"它排第几"。
public enum ReadoutRole: String, CaseIterable, Sendable {
    /// 主角：当前那一刻的值（尺寸 / 颜色 / 已拼高度）。
    case primary
    /// 副手：位置、rgb、一句轻提示。
    case secondary
    /// 「此刻按 `⌥` 会改变结果」——**开关**，不是说明。
    ///
    /// 设计稿 §08 的原话：「不含阴影用琥珀色而不是普通次要色：它是一个会改变结果的开关，
    /// 不是一个说明。」把它画成 `secondary` 就等于降级成说明书，而它真的会改导出的图。
    case caution

    /// 这一行该用的颜色。**唯一来源在 `ChromePalette`。**
    public var color: RGB {
        switch self {
        case .primary: ChromePalette.Overlay.Readout.primary
        case .secondary: ChromePalette.Overlay.Readout.secondary
        case .caution: ChromePalette.Overlay.Readout.caution
        }
    }
}

/// 读数框里的一行。
///
/// ## 为什么把"文字 + 角色"绑成一个结构
///
/// 在这之前，读数框的几行是**六个平行的字符串字段**
/// （`sizeText` / `originText` / `hoverLabel` / `actionHintText` / `scrollStatusText` /
/// `scrollHintText` / `scrollWarningText`），而"哪一行用什么色"是绘制方**当场 `switch`** 出来的。
///
/// 那样有三个后果，每一个都不会报错：
///
/// 1. **顺序是隐式的** —— 谁先谁后写在绘制方的 `if` 顺序里，改一处就换一层；
/// 2. **角色是隐式的** —— "这一行是主角还是副手"没有地方记着，加一行只能靠猜；
/// 3. **空行是隐式的** —— 六个字段里哪个为空、空的时候要不要占位，全靠绘制方逐个判。
///
/// 绑成一个数组之后，三件事都变成**数据**：顺序就是数组顺序、角色就在元素里、
/// 空行在构造的时候就滤掉了。
public struct ReadoutLine: Equatable, Sendable {

    public var text: String
    public var role: ReadoutRole

    public init(_ text: String, _ role: ReadoutRole) {
        self.text = text
        self.role = role
    }

    /// 从若干行里滤掉空文本。**顺序原样保留。**
    ///
    /// 做成构造器而不是"让绘制方跳过空串"：空串在读数框里表现为**一行空白**，
    /// 而"为什么这里空了一行"是最难看出原因的一类显示问题。
    public static func compact(_ lines: [ReadoutLine]) -> [ReadoutLine] {
        lines.filter { !$0.text.isEmpty }
    }
}

/// 读数框的**尺寸与行阶**。
///
/// 与 `OverlayToolbar` 同一个理由放 Core：工具条与读数框是覆盖层上仅有的两块
/// "有确切尺寸"的东西，而它们的尺寸被写进了设计稿的硬约束里 ——
/// 散在视图里的话，"框变大了"这种改动没有任何东西会拦。
public enum OverlayReadout {

    /// 框的**最小**尺寸（点），稿子给的是 132 × 44。
    ///
    /// ⚠️ 是"最小"不是"固定"：四行文字里最长的那句（本地化之后可能更长）要放得下。
    /// 但它**不会因为内容不同而跳大小** —— 三种读数在同一块框里换内容，
    /// 用户不需要学两个框（设计稿 §08 的原话）。
    public static let minimumSize = CGSize(width: 132, height: 44)

    /// 第一行的字号。稿子：13 / 11。
    public static let primaryFontSize: CGFloat = 13
    /// 其余行的字号。
    public static let secondaryFontSize: CGFloat = 11

    /// 框的内边距。
    public static let textPadding = CGSize(width: 8, height: 5)

    /// 圆角。
    public static let cornerRadius: CGFloat = 5

    /// 行与行之间没有额外留白 —— 行高由字体自己给。
    /// 留这么一个常量是为了让"间距"这件事有个可改的地方，而不是散在两处的 `+ 2`。
    public static let lineSpacing: CGFloat = 0
}

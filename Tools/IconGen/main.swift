// Marquee 图标生成器（ticket 29）
//
// 为什么用脚本画、而不是丢一张图进仓库：
//
//  1. **尺寸要按每个规格原生渲染**。从 1024 缩到 16 点会糊成一团；
//     按目标像素重画，16 点那档才有干净的边。
//  2. 图标要跟着产品的配色走（ticket 24 定的深色 chrome）。
//     参数写在这里，改一个数字就能重出全套 —— 不用求人重画。
//  3. 它是**可复现**的：谁 clone 下来跑 `./run.sh` 都能得到同一套 PNG。
//
// 用法：
//   ./run.sh                      # 渲染三个方案的预览（不改产品资源）
//   ./run.sh install dark         # 把 dark 装成 AppIcon
//   ./run.sh compare              # 小尺寸画法的对照图（16/32/64 × 三种画法）
//
// ─────────────────────────────────────────────────────────────────────────────
// ⚠️ **小尺寸不是"大尺寸缩一缩"**
//
// 第一版就是这么干的：把 1024 的画布整体 `scaleBy(1/32)`，于是一条 26 点的虚线
// 在 32 点那档只有 **0.8 像素**宽，虚线段 1.7 像素 —— 抗锯齿把它摊成一片灰雾，
// 看起来是"图标糊了/失真了"，而代码逻辑一点没错（用户就是这么反馈的）。
//
// 所以这里按**目标像素**分档：≤96 像素用另一套画法（粗描边、更大的控制点、
// 小到一定程度干脆去掉虚线与控制点），≥128 像素才是那套精细构图。
// 两个档永远不会同时出现在屏幕上，风格差异没人看得见；
// 而"小而清楚"是**必须**的 —— 16 点那一版才是访达列表里最常被看到的。
// ─────────────────────────────────────────────────────────────────────────────

import AppKit

// MARK: - 网格

/// macOS Big Sur 起的图标模板：1024 的画布上，圆角矩形占 **824×824、居中**，
/// 圆角半径约 **185**。
///
/// 这三个数字不是审美选择 —— 系统图标全都按它排。不按它做，我们的图标在 Dock 里
/// 会比别人**大一圈或小一圈**，而那种偏差说不清哪里不对，只觉得"有点糙"。
private let canvas: CGFloat = 1024
private let bodyInset: CGFloat = 100
private let bodyCornerRadius: CGFloat = 185

/// 选框在**图标本体**里的相对位置（0…1）。
///
/// 用比例而不是绝对点：大档与小档要同一套构图，只是画法粗细不同。
private let marqueeFractions = (x: 0.165, y: 0.257, width: 0.670, height: 0.485)

/// 小尺寸的分界线：**48**。
///
/// 图标集的十档是 16/32/64/128/256/512/1024 —— 48 正好把 **16 与 32** 划进小档，
/// 而 **64 及以上原样保留第一版的精细构图**。
///
/// ⚠️ 一开始我把它定成 96（把 64 也划进来），结果 64 那档被改成"粗虚线"之后
/// 断成一颗颗**獠牙** —— 虚线起点正好落在四角的控制点上，两者一叠就散架了。
/// 渲染出来一比才发现：**64 本来就是好的，不该动**。分档要按"哪一档真的出问题"
/// 来划，不是按"看起来都不够大"来划。
private let smallSizeThreshold = 48

// MARK: - 方案

private struct Variant {
    let id: String
    let title: String
    /// 底色的渐变两端（上 → 下）。
    let top: NSColor
    let bottom: NSColor
    /// 选框线与被压住的选区底色。
    let mark: NSColor
    /// 四个角上的控制点。
    let handle: NSColor
    /// 上缘内侧的高光强度（Big Sur 图标的气质基本就来自这一道柔光）。
    let highlight: CGFloat
}

private let variants: [Variant] = [
    Variant(id: "dark",
            title: "深色（贴合产品 chrome）",
            top: NSColor(srgbRed: 0.259, green: 0.259, blue: 0.290, alpha: 1),
            bottom: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.129, alpha: 1),
            mark: NSColor(white: 1, alpha: 0.96),
            handle: NSColor(white: 1, alpha: 1),
            highlight: 0.13),
    Variant(id: "light",
            title: "浅色",
            top: NSColor(srgbRed: 0.996, green: 0.996, blue: 1.000, alpha: 1),
            bottom: NSColor(srgbRed: 0.898, green: 0.898, blue: 0.925, alpha: 1),
            mark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.125, alpha: 1),
            handle: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.125, alpha: 1),
            highlight: 0.55),
    Variant(id: "indigo",
            title: "靛蓝",
            top: NSColor(srgbRed: 0.294, green: 0.322, blue: 0.522, alpha: 1),
            bottom: NSColor(srgbRed: 0.137, green: 0.145, blue: 0.259, alpha: 1),
            mark: NSColor(white: 1, alpha: 0.96),
            handle: NSColor(white: 1, alpha: 1),
            highlight: 0.16),
]

// MARK: - 小尺寸的几种画法（用来做对照，选定之后 `install` 用 `.solid`）

enum SmallStyle: String, CaseIterable {
    /// **按尺寸自动选**（产品用的就是这一档）。逐尺寸的结论见 `metrics(pixels:style:)`。
    case auto
    /// **第一版做法**：等比缩小。留着当对照 —— 它就是"失真"那版。
    case proportional
    /// 实线粗描边 + 四角点（小档默认）。
    case solid
    /// 更粗的虚线 + 四角点。
    case chunkyDash
    /// **只画四个角**（不描边）—— 给 16 点那档试的候选。
    case cornersOnly
    /// 细实线（1 像素档）—— 给 16 点那档试的候选。
    case solidThin
}

// MARK: - 几何

/// 一个尺寸档的全部几何，**单位是目标像素**（不是 1024 设计单位）。
///
/// 这样写的好处：小档想要"2 像素的线"时，写的就是 2，不用去反推 1024 里该是多少。
private struct Metrics {
    var bodyInset: CGFloat
    var bodyCorner: CGFloat
    var marquee: CGRect
    var lineWidth: CGFloat
    /// 空 = 实线。
    var dash: [CGFloat]
    /// 0 = 不画控制点。
    var handleDiameter: CGFloat
    var regionFillAlpha: CGFloat
    var highlightAlpha: CGFloat
    var shadowBlur: CGFloat
    var shadowOffset: CGFloat
}

/// 把矩形对齐到像素网格。
///
/// **小档必须对齐**：一条 2.6 像素宽的线落在半像素上是"两边各一条灰边"，
/// 看起来就是"模糊"。对齐之后同样的线是干净的。
/// 大档不必对齐 —— 线本身就够粗，抗锯齿看不出来。
private func aligned(_ rect: CGRect, lineWidth: CGFloat) -> CGRect {
    let half = lineWidth / 2
    let r = rect.insetBy(dx: half, dy: half)
    // 奇数线宽要落在**半像素中心**上，否则 1 像素的线会摊成两半
    let nudge: CGFloat = lineWidth.truncatingRemainder(dividingBy: 2) == 0 ? 0 : 0.5
    return CGRect(x: r.origin.x.rounded() + nudge,
                  y: r.origin.y.rounded() + nudge,
                  width: max(lineWidth, r.width.rounded()),
                  height: max(lineWidth, r.height.rounded()))
}

private func metrics(pixels: Int, style: SmallStyle = .auto) -> Metrics {
    let side = CGFloat(pixels)
    let u = side / canvas

    let inset = max(1, (bodyInset * u).rounded())
    let body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let corner = pixels <= smallSizeThreshold
        ? max(2, (bodyCornerRadius * u).rounded())
        : bodyCornerRadius * u

    // 选框按**本体的比例**放，于是大小档构图一致
    let raw = CGRect(x: body.minX + body.width * marqueeFractions.x,
                     y: body.minY + body.height * marqueeFractions.y,
                     width: body.width * marqueeFractions.width,
                     height: body.height * marqueeFractions.height)

    if pixels > smallSizeThreshold {
        // ── 大档：精细构图（与第一版完全一致，别动）──────────────────
        return Metrics(bodyInset: inset, bodyCorner: corner, marquee: raw,
                       lineWidth: 26 * u,
                       dash: [54 * u, 40 * u],
                       handleDiameter: 84 * u,
                       regionFillAlpha: 0.075,
                       highlightAlpha: 1,          // 乘上 variant.highlight
                       shadowBlur: 18 * u, shadowOffset: 6 * u)
    }

    // ── 小档：另立一套 ──────────────────────────────────────────
    var m = Metrics(bodyInset: inset, bodyCorner: corner, marquee: raw,
                    lineWidth: 0, dash: [], handleDiameter: 0,
                    regionFillAlpha: 0, highlightAlpha: 0,
                    shadowBlur: 0, shadowOffset: 0)

    switch style {
    case .auto:
        // 逐尺寸的结论（都是渲染出来比的，不是推的）：
        //
        //   16 点：**细线框**。这一档下选框本体只有 8×6 像素，任何 2 像素的描边
        //          都会把中间那个洞填掉，变成一个白疙瘩。细线是唯一读得出来的画法。
        //   32 点：**粗实线 + 四角点**。虚线在这一档只有 0.8 像素，抗锯齿一摊就是灰雾；
        //          而实线 + 角点既清楚又保留了"这是个选框"的意思。
            if pixels <= 20 {
            // 16：细线框。选框本体只有 8×6 像素，2 像素的描边会把中间的洞填掉。
            m.lineWidth = 1
        } else {
            // 32：粗实线 + 四角点。虚线在这一档只有 0.8 像素，抗锯齿一摊就是灰雾。
            m.lineWidth = max(2, (side * 0.085).rounded())
            m.handleDiameter = max(3, (side * 0.16).rounded())
            m.shadowBlur = side * 0.05
            m.shadowOffset = side * 0.02
        }

    case .proportional:
        // 对照组：等比缩小（＝用户报的"失真"那版）
        m.lineWidth = 26 * u
        m.dash = [54 * u, 40 * u]
        m.handleDiameter = 84 * u
        m.regionFillAlpha = 0.075
        m.highlightAlpha = 1

    case .solid:
        // 实线。粗细按**像素**给，不按比例 —— 比例给不出"看得见的线"。
        m.lineWidth = max(2, (side * 0.085).rounded())
        // 16 点那档不放控制点：12 像素宽的框里塞四个点，只会变成一团糊
        m.handleDiameter = pixels <= 20 ? 0 : max(3, (side * 0.16).rounded())
        m.shadowBlur = side * 0.06
        m.shadowOffset = side * 0.02

    case .chunkyDash:
        m.lineWidth = max(2, (side * 0.075).rounded())
        m.dash = [max(3, (side * 0.175).rounded()), max(2, (side * 0.105).rounded())]
        m.handleDiameter = pixels <= 20 ? 0 : max(3, (side * 0.16).rounded())
        m.shadowBlur = side * 0.06
        m.shadowOffset = side * 0.02

    case .cornersOnly:
        // 不描边，只在四个角放点。16 点那档下，"四个角"比"一圈线"干净得多 ——
        // 线在 12 像素宽的本体里只够摊出一圈灰，而四个实心点仍然四个点。
        m.handleDiameter = max(3, (side * 0.22).rounded())

    case .solidThin:
        m.lineWidth = max(1, (side * 0.06).rounded())
        m.handleDiameter = 0
        m.shadowBlur = 0
        m.shadowOffset = 0
    }

    // ⚠️ `aligned` 之后才 **不要**再传 0：`lineWidth = 0` 在 CoreGraphics 里
    // 表示"1 像素的发丝线"，**不是**"不画线"。写 0 会凭空多出一圈细线，
    // 而它看起来像"模板里本来就有的装饰"。
    m.marquee = aligned(raw, lineWidth: max(m.lineWidth, 1))
    return m
}

// MARK: - 画

/// 全部按**目标像素**画（不再有 1024 的 `scaleBy`）。
private func drawIcon(_ variant: Variant, _ m: Metrics, side: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let body = CGRect(x: m.bodyInset, y: m.bodyInset,
                      width: side - m.bodyInset * 2, height: side - m.bodyInset * 2)
    let squircle = NSBezierPath(roundedRect: body,
                                xRadius: m.bodyCorner, yRadius: m.bodyCorner)

    // ── 圆角底 ──────────────────────────────────────────────
    ctx.saveGState()
    squircle.addClip()
    // AppKit 的 y 轴向上：90° 是"从下往上"，于是 `starting` 落在**底部** ——
    // 这里刻意把 bottom 传前面，让"上浅下深"与参数名一致。
    NSGradient(starting: variant.bottom, ending: variant.top)?.draw(in: body, angle: 90)

    if m.highlightAlpha > 0 {
        // 上缘内侧高光。**线性**，不是幅向的。
        //
        // 第一版用的是"中央一团柔光"（幅向 + alpha 0.10），在 8 位色深下沿等值线
        // 出现了一圈可见的**色带** —— 深底上的低 alpha 渐变最容易出这个。
        // 线性渐变只有一条轴，没有等值线圈，缩到任何尺寸都不会长出色带。
        let highlightRect = CGRect(x: body.minX, y: body.midY,
                                   width: body.width, height: body.height / 2)
        NSGradient(starting: NSColor(white: 1, alpha: variant.highlight * m.highlightAlpha),
                   ending: NSColor(white: 1, alpha: 0))?.draw(in: highlightRect, angle: -90)
    }
    ctx.restoreGState()

    // 大档才画内侧那圈高光描边（小档那 3 像素宽的本体上会糊成一圈）
    if m.highlightAlpha > 0 {
        let inner = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3),
                                 xRadius: max(0, m.bodyCorner - 3),
                                 yRadius: max(0, m.bodyCorner - 3))
        inner.lineWidth = 6
        variant.mark.withAlphaComponent(0.10).setStroke()
        inner.stroke()
    }

    // ── 选框 ────────────────────────────────────────────────
    if m.regionFillAlpha > 0 {
        ctx.saveGState()
        let region = NSBezierPath(roundedRect: m.marquee, xRadius: 8, yRadius: 8)
        region.addClip()
        variant.mark.withAlphaComponent(m.regionFillAlpha).setFill()
        m.marquee.fill()
        ctx.restoreGState()
    }

    let stroke = NSBezierPath(roundedRect: m.marquee,
                              xRadius: max(1, m.marquee.width * 0.03),
                              yRadius: max(1, m.marquee.height * 0.03))
    stroke.lineWidth = m.lineWidth
    stroke.lineCapStyle = .butt
    stroke.lineJoinStyle = .round
    if !m.dash.isEmpty {
        stroke.setLineDash(m.dash, count: m.dash.count, phase: 0)
    }
    variant.mark.setStroke()
    ctx.saveGState()
    if m.shadowBlur > 0 {
        ctx.setShadow(offset: CGSize(width: 0, height: -m.shadowOffset), blur: m.shadowBlur,
                      color: NSColor(white: 0, alpha: 0.35).cgColor)
    }
    stroke.stroke()
    ctx.restoreGState()

    // ── 四个角控制点 ───────────────────────────────────────
    //  只给四角、不给四边中点：小尺寸下 8 个点会挤成一条花边。
    guard m.handleDiameter > 0 else { return }
    let radius = m.handleDiameter / 2
    for corner in [CGPoint(x: m.marquee.minX, y: m.marquee.minY),
                   CGPoint(x: m.marquee.maxX, y: m.marquee.minY),
                   CGPoint(x: m.marquee.minX, y: m.marquee.maxY),
                   CGPoint(x: m.marquee.maxX, y: m.marquee.maxY)] {
        let dot = CGRect(x: corner.x - radius, y: corner.y - radius,
                         width: m.handleDiameter, height: m.handleDiameter)
        ctx.saveGState()
        if m.shadowBlur > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: -m.shadowOffset), blur: m.shadowBlur,
                          color: NSColor(white: 0, alpha: 0.35).cgColor)
        }
        variant.handle.setFill()
        NSBezierPath(ovalIn: dot).fill()
        ctx.restoreGState()
    }
}

// MARK: - 输出

private func render(_ variant: Variant, pixels: Int, style: SmallStyle = .auto) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(variant, metrics(pixels: pixels, style: style), side: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

/// macOS 图标集要的十档。`filename` 里的 `@2x` 后缀是 Xcode 的约定，不能自创。
private let slots: [(size: Int, scale: Int, filename: String)] = [
    (16, 1, "icon_16x16.png"), (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"), (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"), (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"), (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"), (512, 2, "icon_512x512@2x.png"),
]

private func contentsJSON() -> String {
    let entries = slots.map { slot in
        """
            {
              "filename" : "\(slot.filename)",
              "idiom" : "mac",
              "scale" : "\(slot.scale)x",
              "size" : "\(slot.size)x\(slot.size)"
            }
        """
    }.joined(separator: ",\n")
    return """
    {
      "images" : [
    \(entries)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

private let catalogContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""

// MARK: - 入口

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIconSet = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
let previewDir = root.appendingPathComponent("Tools/IconGen/preview")

let args = Array(CommandLine.arguments.dropFirst())
let fm = FileManager.default
try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)

/// 拼一张对照图：每一行一种画法，每一列一个尺寸，按 `zoom` 倍放大（最近邻保留硬边）。
private func writeComparison(variant: Variant, zoom: CGFloat) -> String? {
    let sizes = [16, 32, 64]
    let styles = SmallStyle.allCases
    let cell = CGFloat(sizes.max()!) * zoom
    let gap: CGFloat = 12
    let pad: CGFloat = 16
    let width = pad * 2 + cell * CGFloat(sizes.count) + gap * CGFloat(sizes.count - 1)
    let height = pad * 2 + cell * CGFloat(styles.count) + gap * CGFloat(styles.count - 1)

    guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: Int(width), pixelsHigh: Int(height),
                                       bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    sheet.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: width, height: height).fill()

    for (row, style) in styles.enumerated() {
        for (column, pixels) in sizes.enumerated() {
            guard let data = render(variant, pixels: pixels, style: style),
                  let image = NSImage(data: data) else { continue }
            // AppKit 原点在左下：第 0 行画在最上面
            let x = pad + CGFloat(column) * (cell + gap)
            let y = height - pad - cell - CGFloat(row) * (cell + gap)
            image.draw(in: CGRect(x: x, y: y, width: cell, height: cell),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    let url = previewDir.appendingPathComponent("compare-\(variant.id).png")
    try? sheet.representation(using: .png, properties: [:])?.write(to: url)
    return url.path
}

if args.first == "compare" {
    print("对照图：每行一种画法（\(SmallStyle.allCases.map(\.rawValue).joined(separator: " / "))），")
    print("        每列一个尺寸（16 / 32 / 64），放大 10 倍")
    if let path = writeComparison(variant: variants[0], zoom: 10) {
        print("  → \(path)")
    }
    exit(0)
}

let installing = args.first == "install"
let chosen = (installing ? args.dropFirst().first : args.first) ?? "dark"

for variant in variants {
    let isChosen = variant.id == chosen
    print("\(isChosen ? "●" : "○") \(variant.id)  \(variant.title)")

    // 预览：512 一张，方便肉眼看构图
    if let data = render(variant, pixels: 512) {
        try? data.write(to: previewDir.appendingPathComponent("\(variant.id).png"))
    }
    // 小尺寸**才是最常被看到的那一档**（访达列表），单独出原尺寸图
    for pixels in [16, 32, 64] {
        if let data = render(variant, pixels: pixels) {
            try? data.write(to: previewDir.appendingPathComponent("\(variant.id)-\(pixels).png"))
        }
    }

    guard installing, isChosen else { continue }

    try? fm.createDirectory(at: appIconSet, withIntermediateDirectories: true)
    try? catalogContents.write(to: appIconSet.deletingLastPathComponent()
        .appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    try? contentsJSON().write(to: appIconSet.appendingPathComponent("Contents.json"),
                              atomically: true, encoding: .utf8)

    for slot in slots {
        let pixels = slot.size * slot.scale
        guard let data = render(variant, pixels: pixels) else {
            print("  ✗ \(slot.filename)")
            continue
        }
        try? data.write(to: appIconSet.appendingPathComponent(slot.filename))
    }
    print("  → 已写入 \(appIconSet.path)")
}

print("""

   预览在 Tools/IconGen/preview/（512 构图 + 16/32/64 小档）
   装成产品图标：./run.sh install <dark|light|indigo>
   小档画法对照：./run.sh compare
""")

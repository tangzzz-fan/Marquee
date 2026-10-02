// Marquee 图标生成器（ticket 29）
//
// 为什么用脚本画、而不是丢一张图进仓库：
//
//  1. **尺寸要按每个规格原生渲染**。从 1024 缩到 16 点会糊成一团；
//     按 1024 的几何**按比例重画**，16 点那档才有干净的边。
//  2. 图标要跟着产品的配色走（ticket 24 定的 ✗ 珊瑚红 / ✓ 绿、深色 chrome）。
//     参数写在这里，改一个数字就能重出全套 —— 不用求人重画。
//  3. 它是**可复现**的：谁 clone 下来跑 `./run.sh` 都能得到同一套 PNG，
//     而不是"仓库里躺着一堆来源不明的位图"。
//
// 用法：
//   ./run.sh              # 渲染三个方案的预览（不改产品资源）
//   ./run.sh dark light   # 把 dark 装成 AppIcon、light 也出一份预览
//   ./run.sh install dark # 只装 dark

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

// MARK: - 画

/// 在 1024 的**逻辑画布**上画，由调用方负责把当前上下文缩放到目标像素。
private func drawIcon(_ variant: Variant) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // ── 圆角底 ──────────────────────────────────────────────
    let body = CGRect(x: bodyInset, y: bodyInset,
                      width: canvas - bodyInset * 2, height: canvas - bodyInset * 2)
    let squircle = NSBezierPath(roundedRect: body,
                                xRadius: bodyCornerRadius, yRadius: bodyCornerRadius)

    ctx.saveGState()
    squircle.addClip()
    // AppKit 的 y 轴向上：`draw(in:angle:)` 的 90° 就是"从下往上"，
    // 于是 `starting` 落在**底部**。这里刻意把 bottom 传前面、角度取 90，
    // 让"上浅下深"的直觉与参数名一致。
    NSGradient(starting: variant.bottom, ending: variant.top)?.draw(in: body, angle: 90)

    // 上缘内侧高光。
    //
    // ⚠️ 这里是**线性**渐变，不是幅向的。第一版用的是"中央一团柔光"（幅向 + alpha 0.10），
    // 在 8 位色深下沿等值线出现了一圈可见的**色带** —— 深底上的低 alpha 渐变最容易出这个，
    // 而它在 512 的预览里只是"有点脏"，到 Dock 里就是明显的同心圆。
    // 线性渐变只有一条轴，没有等值线圈，缩到任何尺寸都不会长出色带。
    let highlightRect = CGRect(x: body.minX, y: body.midY,
                               width: body.width, height: body.height / 2)
    NSGradient(starting: NSColor(white: 1, alpha: variant.highlight),
               ending: NSColor(white: 1, alpha: 0))?.draw(in: highlightRect, angle: -90)
    ctx.restoreGState()

    // 内侧一圈极淡的高光：把图标从浅色/深色背景上都"抠"出来
    let innerHighlight = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3),
                                      xRadius: bodyCornerRadius - 3, yRadius: bodyCornerRadius - 3)
    innerHighlight.lineWidth = 6
    variant.mark.withAlphaComponent(0.10).setStroke()
    innerHighlight.stroke()

    // ── 选框 ────────────────────────────────────────────────
    let marquee = CGRect(x: 236, y: 312, width: 552, height: 400)

    // 被选中的区域淡淡压一层：让"选框"读起来是"框住了东西"，而不是漂浮的方框
    ctx.saveGState()
    let region = NSBezierPath(roundedRect: marquee, xRadius: 8, yRadius: 8)
    region.addClip()
    variant.mark.withAlphaComponent(0.075).setFill()
    marquee.fill()
    ctx.restoreGState()

    // 虚线：线宽与间隔都按 1024 画布给足，缩到 16 点才不会糊成一片灰
    let dashed = NSBezierPath(roundedRect: marquee, xRadius: 8, yRadius: 8)
    dashed.lineWidth = 26
    dashed.lineCapStyle = .butt
    dashed.lineJoinStyle = .round
    dashed.setLineDash([54, 40], count: 2, phase: 0)
    variant.mark.setStroke()
    // 一点点投影：压在浅色背景上时，纯白虚线会"融化"
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
                  color: NSColor(white: 0, alpha: 0.35).cgColor)
    dashed.stroke()
    ctx.restoreGState()

    // ── 四个角控制点 ───────────────────────────────────────
    //  只给四角、不给四边中点：8 个点在 16 点那档会挤成一条花边，
    //  而四角在最小尺寸下仍然读得出来是"可以拖的选框"。
    let handleRadius: CGFloat = 42
    for point in [CGPoint(x: marquee.minX, y: marquee.minY),
                  CGPoint(x: marquee.maxX, y: marquee.minY),
                  CGPoint(x: marquee.minX, y: marquee.maxY),
                  CGPoint(x: marquee.maxX, y: marquee.maxY)] {
        let dot = CGRect(x: point.x - handleRadius, y: point.y - handleRadius,
                         width: handleRadius * 2, height: handleRadius * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 14,
                      color: NSColor(white: 0, alpha: 0.35).cgColor)
        variant.handle.setFill()
        NSBezierPath(ovalIn: dot).fill()
        ctx.restoreGState()
    }
}

// MARK: - 输出

/// 按**目标像素**原生渲染，而不是缩图。
private func render(_ variant: Variant, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / canvas
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
    drawIcon(variant)
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
let installing = args.first == "install"
let chosen = (installing ? args.dropFirst().first : args.first) ?? "dark"

let fm = FileManager.default
try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)

for variant in variants {
    let isChosen = variant.id == chosen
    print("\(isChosen ? "●" : "○") \(variant.id)  \(variant.title)")

    // 预览：512 一张，方便肉眼比
    if let data = render(variant, pixels: 512) {
        try? data.write(to: previewDir.appendingPathComponent("\(variant.id).png"))
    }
    // 也出一张 32 点的：**小尺寸才是真正的考验**，大图好看说明不了什么
    if let data = render(variant, pixels: 32) {
        try? data.write(to: previewDir.appendingPathComponent("\(variant.id)-32.png"))
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

   预览在 Tools/IconGen/preview/（512 与 32 各一张）
   装成产品图标：./run.sh install <dark|light|indigo>
""")

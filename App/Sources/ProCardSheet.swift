import AppKit
import MarqueeCore
import MarqueeOverlay

/// 把升级卡片的几种状态渲成一张对照图（`-marqueeSmokeProCard`）。
///
/// ## 为什么值得有它
///
/// 卡片的几何在 Core 里被断言钉住了（五个槽、两条高度、按钮右对齐、不覆盖选区），
/// 但"摆出来是不是稿子那个样子"只有眼睛能判 —— 而这一批恰好把它整个重做了：
/// 加了 ① 图标槽与 ⑤ 微行、按钮从"两个等宽色块"改成"一个色块 + 一个文字按钮"、
/// 并且补了悬停与按下两档（没有它们，用户会说"这张卡片点不动"）。
///
/// 与 `-marqueeSmokeRecent` / 编辑器那几张同一个套路：**Core 答"数对不对"，
/// 这张图答"看起来对不对"**。
@MainActor
enum ProCardSheet {

    /// 一行的说明。**ASCII**（`LocalizationScanTests` 把生产代码里的中文字面量
    /// 当成"漏翻的用户文案"拦下 —— 而这里是给开发看的诊断文字，不进界面）。
    private struct RowSpec {
        var label: String
        var content: ProCardContent
        var includesMicro: Bool
        var theme: ChromePalette.Theme
        var background: RGB
        var hovered: ProCardAction?
        var pressed: ProCardAction?
    }

    static func render(into directory: URL) -> URL? {
        let rows: [RowSpec] = [
            RowSpec(label: "A · trial · default",
                    content: .init(feature: .textRecognition, reason: .neverPurchased,
                                   primary: .startTrial, secondary: .purchase),
                    includesMicro: true, theme: ChromePalette.dark,
                    background: ChromePalette.dark.background,
                    hovered: nil, pressed: nil),
            RowSpec(label: "A · trial · hover primary",
                    content: .init(feature: .scrollCapture, reason: .neverPurchased,
                                   primary: .startTrial, secondary: .purchase),
                    includesMicro: true, theme: ChromePalette.dark,
                    background: ChromePalette.dark.background,
                    hovered: .startTrial, pressed: nil),
            RowSpec(label: "A · trial · press secondary",
                    content: .init(feature: .pin, reason: .neverPurchased,
                                   primary: .startTrial, secondary: .purchase),
                    includesMicro: true, theme: ChromePalette.dark,
                    background: ChromePalette.dark.background,
                    hovered: nil, pressed: .purchase),
            RowSpec(label: "A · trial ended",
                    content: .init(feature: .scrollCapture, reason: .trialEnded,
                                   primary: .purchase, secondary: .restore),
                    includesMicro: true, theme: ChromePalette.dark,
                    background: ChromePalette.dark.background,
                    hovered: nil, pressed: nil),
            RowSpec(label: "A · revoked",
                    content: .init(feature: .pin, reason: .revoked(.storeRevoked),
                                   primary: .restore, secondary: .purchase),
                    includesMicro: true, theme: ChromePalette.dark,
                    background: ChromePalette.dark.background,
                    hovered: nil, pressed: nil),
            RowSpec(label: "B · dark (no micro)",
                    content: .init(feature: .textRecognition, reason: .neverPurchased,
                                   primary: .startTrial, secondary: .purchase),
                    includesMicro: false, theme: ChromePalette.dark,
                    background: ChromePalette.dark.background,
                    hovered: nil, pressed: nil),
            RowSpec(label: "B · light (follows system)",
                    content: .init(feature: .textRecognition, reason: .revoked(.purchaseNotFound),
                                   primary: .restore, secondary: .purchase),
                    includesMicro: false, theme: ChromePalette.light,
                    background: ChromePalette.light.background,
                    hovered: nil, pressed: nil),
        ]

        let labelWidth: CGFloat = 200
        let margin: CGFloat = 20
        let gap: CGFloat = 14
        // 每行按卡片那张图自己报的高度（140 / 115）+ 上下各留 12
        let rowHeights = rows.map { ProCardLayout.height(includesMicro: $0.includesMicro) + 24 }
        let canvasWidth = margin * 2 + labelWidth + ProCardLayout.width
        let canvasHeight = margin * 2 + rowHeights.reduce(0, +)
            + gap * CGFloat(max(0, rows.count - 1))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil,
                                      width: Int(canvasWidth), height: Int(canvasHeight),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var top = canvasHeight - margin
        for (index, row) in rows.enumerated() {
            let height = rowHeights[index]
            let rowBox = CGRect(x: margin, y: top - height, width: canvasWidth - margin * 2,
                                height: height)
            // 每一行自己的底：A 是深色台面，B 浅色那行要浅色台面 ——
            // 否则"卡片在浅色宿主下长什么样"就看不出来了。
            row.background.nsColor.setFill()
            rowBox.fill()

            let cardRect = CGRect(x: rowBox.maxX - ProCardLayout.width,
                                  y: rowBox.midY - ProCardLayout.height(includesMicro: row.includesMicro) / 2,
                                  width: ProCardLayout.width,
                                  height: ProCardLayout.height(includesMicro: row.includesMicro))
            let layout = ProCardRenderer.layout(for: row.content,
                                                in: CGRect(origin: .zero, size: cardRect.size),
                                                includesMicro: row.includesMicro)
            // 卡片自己的底（材质）先铺一层，免得叠在下面那层的可见度上
            row.theme.panel.nsColor.setFill()
            NSBezierPath(roundedRect: cardRect,
                         xRadius: ProCardLayout.cornerRadius,
                         yRadius: ProCardLayout.cornerRadius).fill()
            ProCardRenderer.draw(row.content,
                                 layout: layout,
                                 in: cardRect,
                                 theme: row.theme,
                                 hovered: row.hovered,
                                 pressed: row.pressed)

            let labelColor = row.theme == ChromePalette.dark
                ? NSColor.white.withAlphaComponent(0.72)
                : NSColor.black.withAlphaComponent(0.72)
            (row.label as NSString).draw(
                at: CGPoint(x: rowBox.minX + 8, y: rowBox.midY + 6),
                withAttributes: [.font: labelFont, .foregroundColor: labelColor])

            top = rowBox.minY - gap
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent("pro-card-sheet.png")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: url)
        return url
    }
}

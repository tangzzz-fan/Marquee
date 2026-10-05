// SF Symbol 探针：把工具条上用的图标**按应用里那份配置**渲染出来，并支持指定语言。
//
// ## 为什么需要它
//
// 两件事**没法靠读代码看出来**，而且都是"不崩不报错、只是难看"那一类：
//
// 1. **SF Symbol 会自动本地化。** 有些符号有中文本地化变体，系统按应用语言自动替换。
//    实测：`textformat` 在中文下变成 **两个字「格式」**（变体名 `textformat.zh`），
//    `character` → 字、`textbox` → 文、`textformat.size` → 大小、`textformat.abc` → 甲乙丙。
//    夹在一排图标里的两个汉字，看起来像"代码里写错了"，其实名字一个字都没错。
//
// 2. **多色符号在 `paletteColors` 下会被整片填充。** `face.smiling` 不给
//    `.preferringMonochrome()` 时画出来是**一个实心圆点**（第一层被填满）。
//
// ## 怎么跑
//
//     ./run.sh
//
// 本地化要"应用带 zh-Hans 本地化"才生效，所以 `run.sh` 会临时拼一个 app bundle
// 再跑两遍（en / zh-Hans），产出 `out-en.png` 与 `out-zh.png` —— 直接看图对比。
//
// ⚠️ 新增或更换图标时，把名字加进下面的 `symbols`，再跑一次。
//    只看英文那一张是不够的：本项目面向中文用户，中文那张才是用户看到的。

// SF Symbol 探针：把工具条上用的图标**按应用里那份配置**渲染出来，并支持指定语言。
//
// ## 为什么需要它
//
// 两件事**没法靠读代码看出来**，而且都是"不崩不报错、只是难看"那一类：
//
// 1. **SF Symbol 会自动本地化。** 有些符号有中文本地化变体，系统按应用语言自动替换。
//    实测：`textformat` 在中文下变成 **两个字「格式」**（变体名 `textformat.zh`），
//    `character` → 字、`textbox` → 文、`textformat.size` → 大小、`textformat.abc` → 甲乙丙。
//    夹在一排图标里的两个汉字，看起来像"代码里写错了"，其实名字一个字都没错。
//
// 2. **多色符号在 `paletteColors` 下会被整片填充。** `face.smiling` 不给
//    `.preferringMonochrome()` 时画出来是**一个实心圆点**（第一层被填满）。
//
// 3. **自绘图形要用同一个墨迹高度摆**（2026-10-04 起）。钉图不再来自 SF Symbol，
//    它走 `AnnotationGlyph`（稿子 ⑩ §06）。这一条只能看图：自绘的那枚比邻居大一圈
//    或小一圈都不会报错，只会"看着有点怪"。
//
// ## 怎么跑
//
//     ./run.sh
//
// 本地化要"应用带 zh-Hans 本地化"才生效，所以 `run.sh` 会临时拼一个 app bundle
// 再跑两遍（en / zh-Hans），产出 `out-en.png` 与 `out-zh.png` —— 直接看图对比。
//
// ⚠️ 新增或更换图标时，把名字加进下面的 `symbols`，再跑一次。
//    只看英文那一张是不够的：本项目面向中文用户，中文那张才是用户看到的。

import AppKit

/// 工具条上用到的全部符号（覆盖层 + 编辑器）。用 `(名字, 说明)` 记一笔记它是什么。
let symbols: [(name: String, note: String)] = [
    // 覆盖层 · 绘制
    ("rectangle", "矩形"),
    ("circle", "椭圆"),
    ("face.smiling", "表情 —— ⚠️ 不加 preferringMonochrome 会画成实心圆点"),
    ("arrow.up.right", "箭头"),
    ("pencil.tip", "画笔（已换成 pencil，留着看旧的那个楔形）"),
    ("checkerboard.rectangle", "马赛克"),
    ("t.square", "文字 —— ⚠️ 不能用 textformat（中文下变成「格式」）"),
    // 覆盖层 · 样式 / 智能 / 动作
    ("paintpalette", "样式"),
    ("text.viewfinder", "识别文字（中文下是「文」在取景框里，属预期）"),
    ("arrow.uturn.backward", "撤销"),
    ("arrow.uturn.forward", "重做"),
    ("square.and.arrow.down", "保存"),
    ("pin", "钉图 —— ⚠️ **已不再使用**：2026-10-04 起改自绘，见下面的 glyph 行"),
    ("xmark", "取消"),
    ("checkmark", "完成"),
    // 编辑器
    ("cursorarrow", "选择"),
    ("camera.filters", "模糊（已换成 drop，留着看那两个交叠的圆）"),
    ("crop", "裁切"),
    ("text.alignleft", "文字预设（普通文字）"),
    ("list.number", "文字预设（序号）"),
    ("minus.magnifyingglass", "缩小"),
    ("plus.magnifyingglass", "放大"),
]

/// **自绘图形**（目前只有钉图一枚）。
///
/// 它们和上面那排符号用**同一个 `tint`、同一个墨迹高度**摆
///（`AnnotationGlyph.toolbarInkHeight` —— 值就是被换掉那枚 `pin` 的实测墨迹高度），
/// 所以"换完大小对不对"在这张图上一眼可见。下面那排把它画进真实的 28 点格里。
let glyphs: [(glyph: AnnotationGlyph, note: String)] = [
    (AnnotationGlyph.pin, "钉图（自绘 · 稿子 ⑩ §06）"),
]


let tint = NSColor.controlAccentColor
let tag = CommandLine.arguments.dropFirst().first ?? "out"

/// **与应用里 `SelectionOverlayView.drawSymbol` 完全相同的配置。**
/// 探针要和产品用同一套参数，否则探出来的结论不适用。
func render(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(paletteColors: [tint])
            .applying(.preferringMonochrome())
            .applying(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
}

/// 不给 `preferringMonochrome` 的版本 —— 用来一眼看出哪些符号会被"整片填充"。
func renderWithoutMonochrome(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(paletteColors: [tint])
            .applying(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
}

let side: CGFloat = 46
let columns = 11
let rows = Int(ceil(Double(symbols.count) / Double(columns))) * 2   // 每个画两遍：带/不带单调
let glyphBands = Int(ceil(Double(glyphs.count) / Double(columns))) * 2
let canvas = NSImage(size: NSSize(width: side * CGFloat(columns),
                                  height: side * CGFloat(rows + glyphBands) + 8))
canvas.lockFocus()
NSColor(white: 0.11, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: canvas.size.width, height: canvas.size.height).fill()

for (index, item) in symbols.enumerated() {
    let column = index % columns
    let band = index / columns
    let x = side * CGFloat(column)
    for (row, image) in [render(item.name), renderWithoutMonochrome(item.name)].enumerated() {
        // 每对占两行：上面是"带单调"（产品实际用的），下面是"不带"（对照）
        let y = canvas.size.height - side * CGFloat(band * 2 + row + 1) - 4
        guard let image else {
            // 画不出来就点一个红方块 —— 和"空白"区分开
            NSColor.systemRed.setFill()
            NSRect(x: x + 16, y: y + 16, width: 13, height: 13).fill()
            continue
        }
        let size = image.size
        image.draw(in: NSRect(x: x + (side - size.width) / 2, y: y + (side - size.height) / 2,
                              width: size.width, height: size.height))
    }
}

// 自绘图形那几行。
for (index, item) in glyphs.enumerated() {
    let x = side * CGFloat(index % columns)
    let band = rows + (index / columns) * 2
    // 上排：同样一块 46 × 46 的方框里摆一枚；下排：真实的 28 点格（1× 实尺）
    let top = NSRect(x: x, y: canvas.size.height - side * CGFloat(band + 1) - 4,
                     width: side, height: side)
    ChromeGlyph.draw(item.glyph, in: top, color: tint,
                     inkHeight: AnnotationGlyph.toolbarInkHeight)

    let cell = NSRect(x: x + (side - 28) / 2,
                      y: canvas.size.height - side * CGFloat(band + 2) + 5,
                      width: 28, height: 28)
    NSColor(white: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()
    // 顺带把右下角那把 Pro 锁占的位置标出来 —— 稿子那条"右下 9 × 9 完整留给锁"
    // 只能在这张图上看：叠上了也不会报错。
    NSColor(white: 1, alpha: 0.22).setFill()
    NSRect(x: cell.maxX - 9 - 2, y: cell.minY + 2, width: 9, height: 9).fill()
    ChromeGlyph.draw(item.glyph, in: cell, color: tint,
                     inkHeight: AnnotationGlyph.toolbarInkHeight)
}
canvas.unlockFocus()

let representation = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
let out = URL(fileURLWithPath: "out-\(tag).png")
try! representation.representation(using: .png, properties: [:])!.write(to: out)

// 顺带把"名字存不存在"打出来：不存在的符号是**静默画不出东西**，
// 而那种空白很容易被当成布局算错了。
let missing = symbols.map(\.name).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
print("[\(tag)] 语言=\(Bundle.main.preferredLocalizations.first ?? "?") "
      + "落在 \(out.path)（上排＝产品配置，下排＝不带单调着色的对照）")
print(missing.isEmpty ? "      全部符号都存在" : "      ✗ 不存在：\(missing.joined(separator: ", "))")
print("      自绘图形：\(glyphs.map(\.note).joined(separator: " / "))"
      + "（墨迹高 \(AnnotationGlyph.toolbarInkHeight) 点）")

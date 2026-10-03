import Foundation
import Testing

@testable import MarqueeCore

/// 图标：**同一个功能在两处必须是同一枚**（设计稿 §01，编辑器的验收第一条）。
@Suite("标注图标")
struct AnnotationIconTests {

    /// 覆盖层里那七个工具（编辑器还有「选择」，覆盖层没有）。
    static let sharedTools: [(name: String, editor: AnnotationEditorTool, overlay: OverlayTool, kind: AnnotationKind)] = [
        ("矩形", .rectangle, .rectangle, .rectangle),
        ("椭圆", .ellipse, .ellipse, .ellipse),
        ("箭头", .arrow, .arrow, .arrow),
        ("画笔", .pen, .pen, .pen),
        ("文字", .text, .text, .text),
        ("马赛克", .mosaic, .mosaic, .mosaic),
        // 模糊：编辑器有这一格，覆盖层那一条上**没有入口**（工具条只有马赛克一格），
        // 但渲染、导出、编辑都还在（长截图那条编辑器路径上用得到）。
        ("模糊", .blur, .mosaic, .blur),
    ]

    @Test("同一功能同一图标：编辑器与覆盖层取到的是同一个名字")
    func sameFunctionSameIcon() {
        for item in Self.sharedTools where item.name != "模糊" {
            #expect(AnnotationIcon.symbol(for: item.editor) == AnnotationIcon.symbol(for: item.overlay),
                    "\(item.name) 在两个界面里是两枚图标 —— 用户会以为是两个不同的东西")
        }
        // 七个标注类型各自的一枚（这也是上面那条的根据）
        for item in Self.sharedTools {
            #expect(AnnotationIcon.symbol(for: item.editor) == AnnotationIcon.symbol(for: item.kind))
        }
    }

    @Test("图标名是**钉住**的 —— 换一枚要在这里也换，不能悄悄换")
    func symbolsArePinned() {
        // 这条不是"测试实现"，是**防漂移**：图标名是字符串，改一个字母不会报错，
        // 只会让某一处变成另一个符号（而它看起来只是"这个图标不太对"）。
        // 钉住之后，任何一次改名都会在此红一次 —— 那时人会想一下"编辑器那边跟了没有"。
        #expect(AnnotationIcon.symbol(for: AnnotationKind.rectangle) == "rectangle")
        #expect(AnnotationIcon.symbol(for: AnnotationKind.ellipse) == "circle")
        #expect(AnnotationIcon.symbol(for: AnnotationKind.arrow) == "arrow.up.right")
        #expect(AnnotationIcon.symbol(for: AnnotationKind.pen) == "pencil")
        #expect(AnnotationIcon.symbol(for: AnnotationKind.text) == "t.square")
        #expect(AnnotationIcon.symbol(for: AnnotationKind.mosaic) == "checkerboard.rectangle")
        #expect(AnnotationIcon.symbol(for: AnnotationKind.blur) == "drop")
        #expect(AnnotationIcon.symbol(for: AnnotationEditorTool.select) == "cursorarrow")
        #expect(AnnotationIcon.select == "cursorarrow")
        #expect(AnnotationIcon.crop == "crop")
        #expect(AnnotationIcon.emoji == "face.smiling")

        // 动作格：设计稿的继承表写着「逐字复用 ④」——
        // 两处的撤销 / 重做 / 保存 / ✕ / ✓ 就该是这五枚。
        #expect(AnnotationIcon.undo == "arrow.uturn.backward")
        #expect(AnnotationIcon.redo == "arrow.uturn.forward")
        #expect(AnnotationIcon.save == "square.and.arrow.down")
        #expect(AnnotationIcon.cancel == "xmark")
        #expect(AnnotationIcon.confirm == "checkmark")
        #expect(AnnotationIcon.recognizeText == "text.viewfinder")
        #expect(AnnotationIcon.recognizing == "hourglass")
        #expect(AnnotationIcon.lock == "lock.fill")
        // 缩放的 − / + 是**朴素加减号**（稿子 §04：「− 34% +」）
        #expect(AnnotationIcon.zoomIn == "plus")
        #expect(AnnotationIcon.zoomOut == "minus")
    }

    @Test("**没有一枚图标会被系统本地化** —— `textformat` 的教训")
    func noLocalizedSymbols() {
        // ⚠️ SF Symbol 里有一批会自动本地化：`textformat` 在中文环境下会换成
        // `textformat.zh`，而那个变体渲染出来是**两个字「格式」**，夹在一排图标里非常突兀
        //（用户报过："格式这个文字还在"）。见 `docs/PITFALLS.md` 28。
        //
        // 这条对**所有**图标生效：不只是文字那一格 —— 谁换名字时换成 `textformat.*`
        // 都会被拦下。
        var all: [String] = AnnotationKind.allSymbolsForTesting
        all += [AnnotationIcon.select, AnnotationIcon.crop, AnnotationIcon.emoji,
                AnnotationIcon.undo, AnnotationIcon.redo, AnnotationIcon.save,
                AnnotationIcon.cancel, AnnotationIcon.confirm,
                AnnotationIcon.recognizeText, AnnotationIcon.recognizing,
                AnnotationIcon.zoomIn, AnnotationIcon.zoomOut,
                AnnotationIcon.lock, AnnotationIcon.pin,
                AnnotationIcon.presetText, AnnotationIcon.presetCounter]
        for symbol in all {
            #expect(!symbol.lowercased().contains("textformat"),
                    "\(symbol) 是会自动本地化的符号 —— 中文下会变成汉字")
            #expect(!symbol.isEmpty, "有空格子没有图标")
        }
        #expect(Set(all).count >= 18)
    }

    @Test("七个标注类型的图标**互不相同**")
    func kindSymbolsAreDistinct() {
        let symbols = AnnotationKind.allSymbolsForTesting
        #expect(Set(symbols).count == symbols.count, "有两种标注长着同一张脸：\(symbols)")
        #expect(symbols.count == 7)
    }
}

/// 只为测试准备的一张小表：把七个类型列全。
///
/// 放在测试文件里而不是 Core：Core 不需要"枚举所有类型"这个能力，
/// 而 `AnnotationKind` 不是 `CaseIterable`（它有 `Codable` 的合成实现，
/// 加 `CaseIterable` 会多出一个 Core 用不到的 conformance）。
extension AnnotationKind {
    static var allSymbolsForTesting: [String] {
        let kinds: [AnnotationKind] = [.rectangle, .ellipse, .arrow, .pen, .text, .mosaic, .blur]
        return kinds.map { AnnotationIcon.symbol(for: $0) }
    }
}

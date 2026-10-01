import CoreGraphics
import Foundation
import MarqueeCore
import Testing

/// 覆盖层浮动工具栏的**位置计算**（ticket 20）。
///
/// 为什么把这个小计算单独抽出来测：贴边、翻面、跨屏这几种情况**靠肉眼试不全**，
/// 而一旦算错，表现是"工具栏跑出屏幕了"或"它盖住了选区" ——
/// 用户只会说"那个条没了"，不会告诉你它跑到哪去了。
@Suite("覆盖层工具栏位置")
struct OverlayToolbarTests {

    /// 1440×900 的主屏（Cocoa 全局点，y 向上）
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = OverlayToolbar.toolbarSize

    // MARK: - 默认位置

    @Test("默认贴在选区**下方**，且与选区左对齐")
    func sitsBelowSelection() {
        let selection = CGRect(x: 400, y: 400, width: 300, height: 200)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(bar.maxY <= selection.minY, "Cocoa 坐标 y 向上，『下方』指 y 更小")
        #expect(bar.minX == selection.minX, "默认与选区左边缘对齐")
    }

    @Test("永远不遮选区 —— 这是「不阻断」的前提")
    func neverCoversSelection() {
        let selections = [
            CGRect(x: 400, y: 400, width: 300, height: 200),
            CGRect(x: 100, y: 100, width: 200, height: 150),   // 贴左下
            CGRect(x: 1000, y: 700, width: 300, height: 150),  // 贴右上
            CGRect(x: 600, y: 20, width: 400, height: 300),    // 贴下边
            CGRect(x: 600, y: 580, width: 400, height: 300),   // 贴上边
        ]

        for selection in selections {
            let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)
            #expect(!bar.intersects(selection),
                    "选区 \(selection) 的工具栏 \(bar) 盖住了它")
        }
    }

    // MARK: - 翻面

    @Test("选区贴到屏幕底边时，工具栏翻到**上方**")
    func flipsAboveWhenNoRoomBelow() {
        // 选区底边离屏底只有 20 点，放不下 44 高的工具栏
        let selection = CGRect(x: 400, y: 20, width: 300, height: 200)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(bar.minY >= selection.maxY, "下方放不下就该翻到上方")
        #expect(!bar.intersects(selection))
    }

    @Test("上下都放不下（选区几乎占满屏）时，仍然完整留在屏幕内")
    func staysOnScreenWhenSelectionIsHuge() {
        let selection = screen.insetBy(dx: 4, dy: 4)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(screen.contains(bar), "工具栏不能被推出屏幕：\(bar)")
        #expect(bar.width == size.width)
        #expect(bar.height == size.height)
    }

    // MARK: - 水平夹取

    @Test("选区贴左边缘：工具栏不越出屏幕左侧")
    func clampsAtLeadingEdge() {
        let selection = CGRect(x: 0, y: 400, width: 200, height: 150)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(bar.minX >= screen.minX)
        #expect(screen.contains(bar))
    }

    @Test("选区贴右边缘：工具栏不越出屏幕右侧")
    func clampsAtTrailingEdge() {
        let selection = CGRect(x: 1240, y: 400, width: 200, height: 150)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: screen)

        #expect(bar.maxX <= screen.maxX, "工具栏被推到屏幕外了：\(bar)")
    }

    // MARK: - 多屏

    @Test("副屏（屏幕原点不是 0,0）上同样成立")
    func worksOnSecondaryDisplay() {
        // 挂在主屏右侧的副屏
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 1500, y: 100, width: 300, height: 200)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: second)

        #expect(second.contains(bar), "工具栏应当留在**它所在的那块屏**上：\(bar)")
        #expect(bar.maxY <= selection.minY, "空间够时仍应贴在下方")
    }

    @Test("屏幕可见区比工具栏还矮时也不崩（夹取顺序不能反）")
    func survivesTinyScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 30)
        let selection = CGRect(x: 10, y: 10, width: 50, height: 10)

        let bar = OverlayToolbar.frame(for: selection, screenFrame: tiny)

        #expect(bar.width == size.width, "尺寸不该被改")
        #expect(bar.height == size.height)
    }

    // MARK: - 排布（单一来源）

    @Test("每一格都落在工具条内、彼此不重叠 —— 绘制与命中必须来自同一份排布")
    func slotsFitInsideToolbar() {
        let toolbar = CGRect(origin: .zero, size: OverlayToolbar.toolbarSize)
        let layout = OverlayToolbar.layout()

        for item in layout.items {
            #expect(toolbar.contains(item.frame), "\(item.slot) 超出了工具条：\(item.frame)")
        }
        for (previous, next) in zip(layout.items, layout.items.dropFirst()) {
            #expect(!previous.frame.intersects(next.frame),
                    "格子重叠：\(previous.slot) 与 \(next.slot)")
        }
    }

    @Test("格子从左到右按下标的顺序排，且不超过右内边距")
    func slotsAreOrderedLeftToRight() {
        let layout = OverlayToolbar.layout()
        let xs = layout.items.map(\.frame.minX)

        for (previous, next) in zip(xs, xs.dropFirst()) {
            #expect(previous < next, "顺序反了：\(previous) 之后的 \(next)")
        }
        let last = layout.items.last!.frame
        #expect(last.maxX <= layout.size.width - OverlayToolbar.padding + 0.001,
                "最后一个格子探出了工具条右边（这正是当初宽度与偏移各推一次时踩的坑）")
    }

    @Test("分组之间画了分隔线，且分隔线不与任何格子重叠")
    func separatorsSitBetweenGroups() {
        let layout = OverlayToolbar.layout()
        // 不写死条数：加了功能就多一组，写死会让这条断言在无关改动上变红，
        // 而"该有几条"本来就能从内容推出来。
        let groups = OverlayToolbar.slots.map(\.group)
        let expected = Set(groups).count - 1

        #expect(layout.separators.count == expected,
                "\(Set(groups).count) 个分组之间应当有 \(expected) 条分隔线")
        for separator in layout.separators {
            #expect(layout.items.allSatisfy { !$0.frame.intersects(separator) })
            #expect(separator.minX > 0 && separator.maxX < layout.size.width)
        }
    }

    @Test("工具条内容与用户预期一致：7 个工具 + 色板 + 尺寸三档 + 识别/钉图 + 撤销重做 + 保存取消完成")
    func slotInventory() {
        #expect(OverlayToolbar.slots.count
                == OverlayTool.allCases.count
                + AnnotationPalette.colors.count
                + AnnotationPalette.lineWidths.count
                + 7)
        // 「选择」在最左（与编辑器一致）：它是"不动手画"的那个，摆在最前面最不容易误点
        #expect(OverlayToolbar.slots.first == .tool(.select))
        #expect(OverlayToolbar.slots.last == .confirm)
        // OCR 是**动作**不是工具：它必须在工具区之外，否则以后数工具数会把它算进去
        #expect(OverlayToolbar.slots.contains(.ocr))
        #expect(!OverlayTool.allCases.contains { $0.rawValue == "ocr" })
    }

    @Test("命中测试：点在各格中心能认出来，点在工具条内的空隙上认不出格子但仍在工具条上")
    func hitTestPicksTheRightSlot() {
        let toolbar = OverlayToolbar.frame(for: CGRect(x: 400, y: 400, width: 300, height: 200),
                                           screenFrame: screen)

        for slot in OverlayToolbar.slots {
            let frame = OverlayToolbar.hitFrame(of: slot, in: toolbar)!
            #expect(OverlayToolbar.slot(at: CGPoint(x: frame.midX, y: frame.midY), in: toolbar) == slot)
        }
        // 工具条内部、但落在格子之间的空隙上
        let gap = CGPoint(x: toolbar.midX, y: toolbar.minY + 3)
        #expect(OverlayToolbar.slot(at: gap, in: toolbar) == nil)
        #expect(OverlayToolbar.contains(gap, in: toolbar), "空隙仍属于工具条，不该掉进拖拽逻辑")
        // 工具条之外
        #expect(OverlayToolbar.slot(at: CGPoint(x: toolbar.maxX + 20, y: toolbar.midY), in: toolbar) == nil)
        #expect(!OverlayToolbar.contains(CGPoint(x: toolbar.maxX + 20, y: toolbar.midY), in: toolbar))
    }

    @Test("色板与线宽的格子尺寸一致，且都小于工具按钮")
    func swatchesAreCompact() {
        #expect(OverlayToolbar.swatchSize < OverlayToolbar.buttonSize)
        for slot in [OverlayToolbar.Slot.color(0), .lineWidth(0)] {
            let frame = OverlayToolbar.layout().frame(of: slot)!
            #expect(frame.width == OverlayToolbar.swatchSize)
            #expect(frame.height == OverlayToolbar.swatchSize)
        }
    }

    @Test("组内间距要明显小于组间间距 —— 否则分隔线挤在中间，分组看不出来")
    func groupGapIsVisiblyLargerThanItemGap() {
        let layout = OverlayToolbar.layout()
        let minimum = OverlayToolbar.itemGap + OverlayToolbar.groupGap / 2

        for separator in layout.separators {
            let left = layout.items.map(\.frame.maxX).filter { $0 <= separator.minX }.max()
            let right = layout.items.map(\.frame.minX).filter { $0 >= separator.maxX }.min()
            #expect(left != nil && right != nil)
            if let left, let right {
                #expect(separator.minX - left >= minimum,
                        "分隔线左边只留了 \(separator.minX - left) 点，跟普通格子间距分不出来")
                #expect(right - separator.maxX >= minimum,
                        "分隔线右边只留了 \(right - separator.maxX) 点")
            }
        }
    }

    @Test("工具条必须放得进 1024 点宽的屏 —— 否则贴边时最右边的「完成」会被夹到屏幕外，点不到")
    func fitsOnTheNarrowestReasonableScreen() {
        // 这条不是"越大越好"的美学约束，而是**可达性**约束：
        // `frame(for:)` 的夹取保证的是"左上角在屏幕内"，宽度超出时右边的格子就真的出屏了 ——
        // 用户看不到也点不到，而工具栏看起来只是"有点长"，不会报任何错。
        #expect(OverlayToolbar.toolbarSize.width < 1024,
                "工具条现在 \(OverlayToolbar.toolbarSize.width) 点宽，超出这个宽度就得把参数收进弹层")
    }

    @Test("线宽档与打码强度档的数量必须一致")
    func sizeSlotCountsMatch() {
        // 工具条上的格数是按**线宽**那组建的，而控制层按当前工具去**打码强度**那组取下标 ——
        // 两组长度不一样就会越界（或永远选中不到最后一档），而界面看起来只是"少了一档"。
        #expect(AnnotationPalette.overlayRedactionStrengths.count == AnnotationPalette.lineWidths.count)
        #expect(AnnotationPalette.overlayRedactionStrengths.count == 3)
        // 默认档必须落在数组里，否则一进来就没有任何一档高亮
        #expect(AnnotationPalette.overlayRedactionStrengths.contains(AnnotationPalette.defaultRedactionStrength))
    }

    @Test("需要底图的工具就是马赛克与模糊这两类")
    func backdropTools() {
        #expect(OverlayTool.mosaic.needsBackdrop)
        #expect(OverlayTool.blur.needsBackdrop)
        for tool in OverlayTool.allCases where tool != .mosaic && tool != .blur {
            #expect(!tool.needsBackdrop)
        }
    }

    @Test("「选择」不是绘图工具：它没有 kind，`draws` 为假")
    func selectToolDrawsNothing() {
        // 这条是本类里最容易写错的一处：把 `.select` 也算成"选了工具就画"，
        // 用户想点选一个箭头，结果在旁边画了个新矩形。
        #expect(OverlayTool.select.kind == nil)
        #expect(!OverlayTool.select.draws)
        for tool in OverlayTool.allCases where tool != .select {
            #expect(tool.kind != nil)
            #expect(tool.draws)
        }
    }

    // MARK: - 文字工具（ticket 22）

    @Test("文字是靠「点一下」放下的，不是「拖一笔」")
    func textIsPlacedByClick() {
        // ⚠️ 这条是关键的行为差别：文字若走 `beginStroke`，用户按住鼠标拖一下
        // 就会得到一个"宽度等于拖拽距离"的文字框，而正文根本还没输入。
        #expect(OverlayTool.text.kind == .text)
        #expect(OverlayTool.text.draws, "它仍然是个绘图工具（会被画到图上）")
        #expect(!OverlayTool.text.isStrokeBased)
        #expect(!OverlayTool.text.needsBackdrop, "文字不需要底图像素")

        for tool in OverlayTool.allCases where tool != .text {
            #expect(tool.isStrokeBased || !tool.draws,
                    "\(tool.rawValue) 不是点放式工具，却被打上了 isStrokeBased=false")
        }
    }

    @Test("那三档尺寸的含义由当前工具决定 —— 加新工具时只改一处")
    func sizeMeaningFollowsTheTool() {
        #expect(OverlayTool.mosaic.sizeMeaning == .redactionStrength)
        #expect(OverlayTool.blur.sizeMeaning == .redactionStrength)
        #expect(OverlayTool.text.sizeMeaning == .fontSize)
        for tool in [OverlayTool.select, .rectangle, .ellipse, .arrow, .pen] {
            #expect(tool.sizeMeaning == .lineWidth)
        }
    }

    @Test("三组尺寸档必须一样长 —— 否则有一组永远选不到最后一档")
    func everySizeMeaningHasTheSameNumberOfSlots() {
        // 工具条上的格子数是按**线宽**那组建的（`slots` 用的是 `lineWidths.indices`），
        // 而控制层按当前含义去另一组取同一个下标。长度不一样就会越界，
        // 或者最后一档永远高亮不上 —— 而界面看起来只是"那一档点了没反应"。
        let expected = AnnotationPalette.lineWidths.count
        for meaning in OverlaySizeMeaning.allCases {
            #expect(meaning.values.count == expected,
                    "\(meaning) 有 \(meaning.values.count) 档，与工具条的 \(expected) 格对不上")
            #expect(!meaning.values.isEmpty)
        }
    }

    @Test("点工具条不会把正在打的字扔掉：改样式与撤销重做留着输入，其余先结算")
    func toolbarClicksDoNotDiscardTyping() {
        // 这条钉的是**一条产品决定**：`结算`（把内容落成标注）与 `丢弃` 是两件事。
        // 换工具 / 识别 / 保存 / 取消 / 完成 都该先结算；只有 `Esc` 才丢。
        for slot in [OverlayToolbar.Slot.color(0), .lineWidth(1), .undo, .redo] {
            #expect(slot.preservesTextEditing, "\(slot) 属于「改这一行」，不该把输入结算掉")
        }
        for slot in [OverlayToolbar.Slot.tool(.rectangle), .ocr, .pin, .save, .cancel, .confirm] {
            #expect(!slot.preservesTextEditing, "\(slot) 会离开「写文字」这件事，必须先结算输入")
        }
    }

    @Test("每组的默认值都必须落在自己的档位里 —— 否则一进来三档全不高亮")
    func defaultsLandOnASlot() {
        for meaning in OverlaySizeMeaning.allCases {
            #expect(meaning.values.contains(meaning.defaultValue),
                    "\(meaning) 的默认值 \(meaning.defaultValue) 不在 \(meaning.values) 里")
        }
    }
}

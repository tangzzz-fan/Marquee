import CoreGraphics
import Foundation
import Testing
@testable import MarqueeCore

@Suite("窗口清单：筛选与命中测试")
struct WindowCatalogTests {

    private let ownPID: Int32 = 99
    private let otherPID: Int32 = 100

    @Test("普通窗口可被选中")
    func normalWindowIsSelectable() {
        let window = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(WindowCatalog.selectable(from: [window], excludingPID: ownPID) == [window])
    }

    @Test("自己进程的窗口一律排除（覆盖层不能选中自己）")
    func excludesOwnProcess() {
        let window = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), pid: ownPID)
        #expect(WindowCatalog.selectable(from: [window], excludingPID: ownPID).isEmpty)
    }

    @Test("Dock / 菜单栏 / 桌面层不能被选中")
    func excludesSystemLayers() {
        let dock = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 40), layer: 20)
        let menu = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 1440, height: 24), layer: 24)
        let desktop = makeWindow(id: 3, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), layer: -1)
        #expect(WindowCatalog.selectable(from: [dock, menu, desktop], excludingPID: ownPID).isEmpty)
    }

    @Test("浮动面板（layer 3）可以选 —— 很多应用的检查器在这一层")
    func floatingPanelIsSelectable() {
        let inspector = makeWindow(id: 1, frame: CGRect(x: 100, y: 100, width: 280, height: 400), layer: 3)
        #expect(WindowCatalog.selectable(from: [inspector], excludingPID: ownPID) == [inspector])
    }

    @Test("太小或几乎全透明的窗口排除")
    func excludesTinyAndTransparent() {
        let tiny = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        let ghost = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 300), alpha: 0)
        #expect(WindowCatalog.selectable(from: [tiny, ghost], excludingPID: ownPID).isEmpty)
    }

    @Test("重叠处命中前台那扇；后面的窗即使层数更高、框也盖住该点，也不选")
    func coveredWindowIsNotSelected() {
        let front = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0)
        let covered = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 8)
        let hit = WindowCatalog.topmost(at: CGPoint(x: 100, y: 100),
                                        in: [front, covered],
                                        excludingPID: ownPID)
        #expect(hit?.windowID == 1)
    }

    @Test("后窗只在没被挡住的区域命中")
    func backWindowHitOnlyWhereVisible() {
        let front = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        let back = makeWindow(id: 2, frame: CGRect(x: 40, y: 40, width: 300, height: 300))
        #expect(WindowCatalog.topmost(at: CGPoint(x: 80, y: 80), in: [front, back], excludingPID: ownPID)?.windowID == 1)
        #expect(WindowCatalog.topmost(at: CGPoint(x: 200, y: 200), in: [front, back], excludingPID: ownPID)?.windowID == 2)
    }

    @Test("不在在屏清单里的窗口丢掉，避免选到看不见的窗")
    func dropsWindowsMissingFromOnScreenList() {
        let visible = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let hidden = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let ordered = WindowCatalog.orderedForHitTesting([hidden, visible], frontToBackIDs: [1])
        #expect(ordered.map(\.windowID) == [1])
    }

    @Test("按前台→后台重排，不按层数")
    func reordersFrontToBackIgnoringLayer() {
        let back = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 10)
        let front = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0)
        let ordered = WindowCatalog.orderedForHitTesting([back, front], frontToBackIDs: [1, 2])
        #expect(ordered.map(\.windowID) == [1, 2])
    }

    @Test("同一层：输入数组里靠前的（前台）优先")
    func sameLayerKeepsFrontToBackOrder() {
        let front = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let back = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let hit = WindowCatalog.topmost(at: CGPoint(x: 10, y: 10),
                                        in: [front, back],
                                        excludingPID: ownPID)
        #expect(hit?.windowID == 1)
    }

    @Test("点在桌面空白 / 菜单栏 / 自己的覆盖层上 → nil，不出现误导性高亮")
    func missReturnsNil() {
        let app = makeWindow(id: 1, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let overlay = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), pid: ownPID)
        let menu = makeWindow(id: 3, frame: CGRect(x: 0, y: 876, width: 1440, height: 24), layer: 24)

        let windows = [overlay, menu, app]
        #expect(WindowCatalog.topmost(at: CGPoint(x: 10, y: 10), in: windows, excludingPID: ownPID) == nil)
        #expect(WindowCatalog.topmost(at: CGPoint(x: 50, y: 880), in: windows, excludingPID: ownPID) == nil)
        #expect(WindowCatalog.topmost(at: CGPoint(x: 200, y: 200), in: windows, excludingPID: ownPID)?.windowID == 1)
    }

    @Test("悬停文案：有标题时带应用名，没标题时只用应用名")
    func hoverLabel() {
        let titled = makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), title: "README.md")
        let untitled = makeWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 100, height: 100), title: nil)
        #expect(titled.hoverLabel == "App — README.md")
        #expect(untitled.hoverLabel == "App")
    }

    private func makeWindow(id: UInt32,
                            frame: CGRect,
                            layer: Int = 0,
                            pid: Int32? = nil,
                            alpha: Double = 1,
                            title: String? = "Title") -> WindowInfo {
        WindowInfo(windowID: id,
                   frame: frame,
                   layer: layer,
                   ownerPID: pid ?? otherPID,
                   ownerName: "App",
                   title: title,
                   alpha: alpha)
    }
}

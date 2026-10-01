import CoreGraphics
import Foundation
import Testing
@testable import MarqueeCore
@testable import MarqueeHistory

/// 最近截图的历史仓库（ticket 16）。
///
/// 每个用例一个临时目录：这一类的断言里有**文件系统状态**，
/// 共用一个目录的话用例之间会互相看见对方的文件，表现为"单独跑绿、一起跑红"。
@Suite("最近截图的历史仓库")
struct CaptureHistoryStoreTests {

    private func makeStore(limit: Int = CaptureHistoryStore.defaultLimit)
        -> (store: CaptureHistoryStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-history-\(UUID().uuidString)", isDirectory: true)
        return (CaptureHistoryStore(directory: directory, limit: limit), directory)
    }

    /// 一张纯色小图（够用即可，速度优先）
    private func image(_ value: CGFloat = 0.5) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 40, height: 30,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [value, value, value, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return context.makeImage()!
    }

    /// 记一条并把它取回来。
    ///
    /// 接缝 `record` 只返回 id（Core 不该知道条目的形状），
    /// 而这一组的断言要拿文件名去核对磁盘 —— 所以从索引里读回来。
    private func record(_ store: CaptureHistoryStore,
                        image: CGImage,
                        annotations: [Annotation] = []) -> CaptureHistoryEntry? {
        if store.record(original: image, originalPNG: nil, annotations: annotations, at: Date()) == nil {
            return nil
        }
        return store.entries().first
    }

    private func files(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names)
    }

    // MARK: - 记一条

    @Test("记一条：进索引、文件真的写出来了")
    func recordWritesFiles() throws {
        let (store, directory) = makeStore()

        let entry = try #require(record(store, image: image(), annotations: []))

        #expect(store.entries().count == 1)
        #expect(store.entries().first?.id == entry.id)
        // 原图 + 索引；没有标注时**不该**多写一个空的标注文件
        #expect(files(in: directory) == ["index.json", entry.originalFileName])
        #expect(entry.annotationsFileName == nil)
    }

    @Test("有标注时同时存原图与标注向量 —— 否则「重新编辑」就退化成在成品上再画")
    func recordKeepsAnnotationsAsVectors() throws {
        let (store, directory) = makeStore()
        let annotation = Annotation(kind: .rectangle,
                                    frame: CGRect(x: 5, y: 6, width: 10, height: 8),
                                    zIndex: 0)

        let entry = try #require(record(store, image: image(), annotations: [annotation]))

        #expect(entry.annotationCount == 1)
        let name = try #require(entry.annotationsFileName)
        #expect(files(in: directory).contains(name))

        let snapshot = try #require(store.snapshot(for: entry))
        #expect(snapshot.annotations == [annotation], "标注必须原样回来")
        #expect(snapshot.original.width == 40, "拿回来的是**原图**，不是拍平后的成品")
    }

    @Test("新记的排在最前面")
    func newestComesFirst() {
        let (store, _) = makeStore()
        let first = record(store, image: image(0.2), annotations: [])
        let second = record(store, image: image(0.8), annotations: [])

        #expect(store.entries().map(\.id) == [second?.id, first?.id])
    }

    // MARK: - 上限与淘汰

    @Test("超过上限时淘汰**最旧的**，且它的文件被一起清掉")
    func evictionDropsTheOldestAndItsFiles() throws {
        let (store, directory) = makeStore(limit: 3)

        var recorded: [CaptureHistoryEntry] = []
        for index in 0..<5 {
            recorded.append(try #require(record(store, image: image(CGFloat(index) / 5))))
        }

        let live = store.entries()
        #expect(live.count == 3)
        #expect(live.map(\.id) == [recorded[4].id, recorded[3].id, recorded[2].id])

        // 被淘汰的那两条的文件必须真的没了，否则磁盘会一直长
        let names = files(in: directory)
        #expect(!names.contains(recorded[0].originalFileName))
        #expect(!names.contains(recorded[1].originalFileName))
        #expect(names.contains(recorded[4].originalFileName))
        #expect(names == Set(["index.json"] + live.map(\.originalFileName)))
    }

    @Test("上限为 1 也不会把刚记的那条自己删掉")
    func limitOfOneKeepsTheNewest() {
        let (store, _) = makeStore(limit: 1)
        _ = record(store, image: image(), annotations: [])
        let newest = record(store, image: image(), annotations: [])

        #expect(store.entries().map(\.id) == [newest?.id])
    }

    // MARK: - 删除

    @Test("删一条：索引里没了，文件也没了，**别的条目不受影响**")
    func deleteRemovesEntryAndItsFiles() throws {
        let (store, directory) = makeStore()
        let keep = try #require(record(store, image: image(), annotations: []))
        let drop = try #require(record(store, image: image(), annotations: []))

        store.delete(drop.id)

        #expect(store.entries().map(\.id) == [keep.id])
        let names = files(in: directory)
        #expect(!names.contains(drop.originalFileName))
        #expect(names.contains(keep.originalFileName), "另一条的文件不能被误删")
    }

    @Test("删一条不存在的 id 是空操作（不该把别人的删掉）")
    func deletingAnUnknownIDIsANoOp() throws {
        let (store, _) = makeStore()
        let entry = try #require(record(store, image: image(), annotations: []))

        store.delete(UUID())

        #expect(store.entries().map(\.id) == [entry.id])
    }

    @Test("**只删自己写出来的文件** —— 用户另存到历史目录里的东西不能动")
    func deleteOnlyTouchesItsOwnFiles() throws {
        // 这是 ticket 的验收项之一："不会误删用户自己保存到别处的文件"。
        // 仓库只按**条目里记的文件名**删，所以放一个名字不一样的文件进去，
        // 删多少条它都该在。
        let (store, directory) = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let userFile = directory.appendingPathComponent("我自己放的.png")
        try Data([0x00, 0x01]).write(to: userFile)

        let entry = try #require(record(store, image: image(), annotations: []))
        store.delete(entry.id)
        store.removeAll()

        #expect(FileManager.default.fileExists(atPath: userFile.path))
    }

    @Test("全清：索引空、文件只剩那个不认识的外来文件")
    func removeAllClearsEverythingItOwns() throws {
        let (store, directory) = makeStore()
        _ = record(store, image: image(), annotations: [])
        _ = record(store, image: image(), annotations: [])

        store.removeAll()

        #expect(store.entries().isEmpty)
        #expect(files(in: directory) == ["index.json"])
    }

    // MARK: - 健壮性

    @Test("索引坏掉时当作空，而不是整个功能不可用")
    func brokenIndexDegradesToEmpty() throws {
        let (store, directory) = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("这不是 JSON".utf8).write(to: directory.appendingPathComponent("index.json"))

        #expect(store.entries().isEmpty)

        // 而且**还能继续记新的**：坏索引不该让写入也一起坏掉
        let entry = record(store, image: image(), annotations: [])
        #expect(entry != nil)
        #expect(store.entries().count == 1)
    }

    @Test("原图文件被外部删掉时，取回返回 nil 而不是崩")
    func missingFileReturnsNil() throws {
        let (store, directory) = makeStore()
        let entry = try #require(record(store, image: image(), annotations: []))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.originalFileName))

        #expect(store.snapshot(for: entry) == nil)
        // 但条目还在索引里 —— 面板要能显示它、也要能删掉它
        #expect(store.entries().count == 1)
    }

    @Test("重新打开一个仓库（模拟重启应用）能读到之前的历史")
    func indexSurvivesReopen() throws {
        let (store, directory) = makeStore()
        let entry = try #require(record(store, image: image(), annotations: []))

        let reopened = CaptureHistoryStore(directory: directory)

        #expect(reopened.entries().map(\.id) == [entry.id])
        #expect(reopened.snapshot(for: entry) != nil)
    }
}

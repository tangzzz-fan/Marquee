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

    /// 假废纸篓：每跑一次删除，文件被**移**到这里。
    ///
    /// ⚠️ 不能用真的 `FileManager.trashItem`：那会把测试造出来的文件丢进
    /// **跑测试那个人的废纸篓**里，跑一次多几条。没人会注意到，
    /// 但那是"测试污染用户的环境"，而且它只在真机上才看得见。
    ///
    /// 放在 `directory` 的**兄弟**位置（不是子目录）：`files(in:)` 列的是
    /// `directory` 的内容，假废纸篓放在里面就会混进那些断言里。
    private final class TrashCan {
        let directory: URL
        /// 成功收下的文件。
        private(set) var received: [String] = []
        /// **被问到过**的文件 —— 与 `received` 分开记。
        ///
        /// 少了它，"没去惹废纸篓"与"惹了但失败"这两种情况在断言里长得一模一样 ——
        /// 而它们是两回事：前者是我们**刻意**不问（文件本来就不在），
        /// 后者说明守卫被拿掉了（真机上那会往日志里灌一条假失败）。
        private(set) var attempts: [String] = []
        var failure: Error?

        init(near directory: URL) {
            self.directory = directory.deletingLastPathComponent()
                .appendingPathComponent("marquee-trash-\(UUID().uuidString)", isDirectory: true)
        }

        func trash(_ url: URL) throws {
            attempts.append(url.lastPathComponent)
            if let failure { throw failure }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: url, to: destination)
            received.append(url.lastPathComponent)
        }

        var contents: Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        }
    }

    private func makeStore(limit: Int = CaptureHistoryStore.defaultLimit)
        -> (store: CaptureHistoryStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-history-\(UUID().uuidString)", isDirectory: true)
        let can = TrashCan(near: directory)
        return (CaptureHistoryStore(directory: directory, limit: limit,
                                    trash: { try can.trash($0) }),
                directory)
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

    // MARK: - 上限是可变的（ticket 31：免费版只留若干张）

    @Test("上限可以改小 —— 但要**下一次写入**才淘汰，改的那一刻不删东西")
    func limitIsMutable() throws {
        let (store, _) = makeStore(limit: 3)
        for _ in 0..<3 { _ = record(store, image: image()) }
        #expect(store.entries().count == 3)

        // 这一条是刻意的：改上限（用户买了 / 试用到期）**不该顺带丢历史**。
        // 若在 setter 里顺手淘汰，那么"启动时按权益设一次上限"就等于每次启动
        // 都删一批文件 —— 而那个删除动作跟用户做过的任何事都对不上。
        store.limit = 2
        #expect(store.entries().count == 3, "改上限本身不该删任何东西")

        _ = record(store, image: image())
        #expect(store.entries().count == 2, "下一次写入才把多出来的淘汰掉")
    }

    @Test("上限为 nil = 不淘汰（Pro）—— 不然「不设上限」只是一句空话")
    func nilLimitKeepsEverything() throws {
        let (store, _) = makeStore(limit: 2)
        store.limit = nil

        for _ in 0..<6 { _ = record(store, image: image()) }

        #expect(store.entries().count == 6)
    }

    // MARK: - 删除的去处：废纸篓（设计稿 §02）

    /// 造一个"我能看见废纸篓里有什么"的仓库。
    private func makeStoreWithTrash(limit: Int = CaptureHistoryStore.defaultLimit)
        -> (store: CaptureHistoryStore, directory: URL, can: TrashCan) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-history-\(UUID().uuidString)", isDirectory: true)
        let can = TrashCan(near: directory)
        let store = CaptureHistoryStore(directory: directory, limit: limit,
                                        trash: { try can.trash($0) })
        return (store, directory, can)
    }

    @Test("用户删的那一条进**废纸篓** —— 原图与标注两份文件都进")
    func deleteMovesFilesToTrash() throws {
        // 设计稿 §02：「删除 = 从历史移除并**把磁盘文件移进废纸篓**」，
        // 它替掉的是确认弹窗 —— 硬约束禁止新弹窗，而"删了就没 + 不可撤销"
        // 在一个高频面板里是危险的。
        let (store, directory, can) = makeStoreWithTrash()
        let annotation = Annotation(kind: .rectangle,
                                    frame: CGRect(x: 5, y: 6, width: 10, height: 8),
                                    zIndex: 0)
        let entry = try #require(record(store, image: image(), annotations: [annotation]))
        let markers = try #require(entry.annotationsFileName)

        store.delete(entry.id)

        #expect(store.entries().isEmpty)
        // 目录里两份都不在了……
        let names = files(in: directory)
        #expect(!names.contains(entry.originalFileName))
        #expect(!names.contains(markers))
        // ……因为它们**在废纸篓里**，而不是被抹掉了
        #expect(can.contents == Set([entry.originalFileName, markers]))
        #expect(can.received.count == 2)
    }

    @Test("自动淘汰**不**走废纸篓 —— 那不是用户按的那一下")
    func evictionDoesNotUseTrash() throws {
        // 淘汰是我们替他做的决定（"免费版只留 5 张"），他既没要求删那几张、
        // 也不知道是哪几张。把它也塞进废纸篓，等于每截一张就往他的废纸篓里丢东西 ——
        // 那是借系统的回收站来掩盖我们自己的决定。
        let (store, directory, can) = makeStoreWithTrash(limit: 3)

        for index in 0..<5 { _ = record(store, image: image(CGFloat(index) / 5)) }

        #expect(store.entries().count == 3)
        #expect(can.received.isEmpty, "自动淘汰不该往废纸篓里塞东西")
        #expect(can.contents.isEmpty)
        // 但被淘汰的文件确实从目录里清掉了（磁盘不能一直长）
        #expect(files(in: directory).count == 4, "3 张原图 + index.json")
    }

    @Test("废纸篓不可用时退回永久删 —— 但记录**必须**离开索引，也不留孤儿文件")
    func trashFailureFallsBackToErase() throws {
        // 走到这里说明用户已经按了删除，那条记录一定会离开索引。
        // 只剩两种结果：留一个**谁都看不见的孤儿文件**，或者少一次"还能捞回来"的机会。
        // 前者是唯一那种既看不见又永久的坏结果，所以取后者。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-history-\(UUID().uuidString)", isDirectory: true)
        let can = TrashCan(near: directory)
        can.failure = CocoaError(.fileWriteNoPermission)
        let store = CaptureHistoryStore(directory: directory, trash: { try can.trash($0) })
        let entry = try #require(record(store, image: image(), annotations: []))

        store.delete(entry.id)

        #expect(store.entries().isEmpty, "记录必须离开索引 —— 否则那一行会一直在面板里")
        #expect(!files(in: directory).contains(entry.originalFileName),
                "退回永久删：文件不能变成孤儿留在历史目录里")
        #expect(can.contents.isEmpty)
    }

    @Test("文件本来就不在时，不去麻烦废纸篓")
    func missingFileIsNotSentToTrash() throws {
        // `trashItem` 对不存在的路径会抛错，而那会把上面那条退路**误触发**一次
        // （日志里多一条"回收失败"，其实什么都没发生过）。
        let (store, directory, can) = makeStoreWithTrash()
        let entry = try #require(record(store, image: image(), annotations: []))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.originalFileName))

        store.delete(entry.id)

        #expect(store.entries().isEmpty)
        #expect(can.received.isEmpty, "文件都不在了，没什么可回收的")
        // ⚠️ 断言的是"**问都没问过**"，不是"没成功"：
        // 拿 `received.isEmpty` 当判据的话，把那条"文件不在就别去惹废纸篓"的守卫删掉
        // 也照样绿 —— 因为假废纸篓会失败、失败也不算 `received`。变异测试当场抓到了这一条。
        #expect(can.attempts.isEmpty, "文件都不在了，不该去问废纸篓")
    }
}

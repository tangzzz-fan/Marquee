import CoreGraphics
import Foundation
import ImageIO
import MarqueeCore
import os

/// 一条历史记录（ticket 16）。
///
/// ## 为什么同时存**原图**和**标注向量**
///
/// 历史面板的用处之一是"刚才那张我还要再改一下"。如果只存拍平后的成品，
/// 「重新编辑」就退化成"在一张已经画好的图上再画"—— 原有的标注成了图的一部分，
/// 既不能选中也不能撤掉。所以原图与标注分开存，重新进编辑器时把它们合起来喂进去。
public struct CaptureHistoryEntry: Equatable, Sendable, Codable {
    public var id: UUID
    public var capturedAt: Date
    public var pixelSize: CGSize
    /// 当时画了几个标注（面板上标一下，用户能一眼看出哪张是"还没画过的原图"）
    public var annotationCount: Int
    /// 原图（未拍平）在历史目录里的文件名
    public var originalFileName: String
    /// 标注的文件名。没有标注时为 `nil` —— 那时不必多写一个空文件。
    public var annotationsFileName: String?

    public init(id: UUID = UUID(),
                capturedAt: Date,
                pixelSize: CGSize,
                annotationCount: Int,
                originalFileName: String,
                annotationsFileName: String? = nil) {
        self.id = id
        self.capturedAt = capturedAt
        self.pixelSize = pixelSize
        self.annotationCount = annotationCount
        self.originalFileName = originalFileName
        self.annotationsFileName = annotationsFileName
    }
}

/// 从历史里取回一张图所需的全部东西。
public struct CaptureHistorySnapshot: Equatable, Sendable {
    /// **未拍平**的原图
    public let original: CGImage
    /// 当时的标注（可直接喂回编辑器）
    public let annotations: [Annotation]

    public init(original: CGImage, annotations: [Annotation]) {
        self.original = original
        self.annotations = annotations
    }

    /// 原图的像素尺寸（喂给 `AnnotationDocument` 用）。
    public var originalSize: CGSize {
        CGSize(width: original.width, height: original.height)
    }
}

/// 落在磁盘上的历史仓库。
///
/// ## 目录约定
///
/// `<数据根>/history/`，而数据根是 `~/Library/Application Support/<bundle id>/`
/// （见 `AppIdentity` —— 开发版是 `com.tango.Marquee.dev`，于是两个版本各有各的历史）：
/// - `index.json` —— 条目清单（新→旧）
/// - `<uuid>-original.png` / `<uuid>-annotations.json`
///
/// **只删自己写出来的文件**：条目里记的是文件名，删除时按名字删，
/// 于是用户自己另存到别处的图**永远不在删除范围内**（ticket 的验收项之一）。
public final class CaptureHistoryStore: CaptureHistoryWriting, @unchecked Sendable {

    /// 上限。超过就淘汰最旧的 —— 不让磁盘无限增长。
    public static let defaultLimit = 20

    /// 当前上限。`nil` = **不淘汰**（Pro）。
    ///
    /// ⚠️ 它是**可变的**（ticket 31）：免费版只留若干张，买断之后放开。
    /// 原先写死成 `let`，于是"免费版只留 5 张"这件事在存储层根本表达不了 ——
    /// 界面可以假装看不见，磁盘上的文件照样留着。
    ///
    /// 读写都走锁：它会被采集路径（后台线程）与权益变化（主线程）同时碰。
    public var limit: Int? {
        get { lock.withLock { _limit } }
        set { lock.withLock { _limit = newValue.map { max(1, $0) } } }
    }

    /// 真正的那一份。**内部一律读写它** —— 内部方法大多已经在锁里，
    /// 再走一次带锁的 `limit` 会死锁（`NSLock` 不可重入）。
    private var _limit: Int?

    /// 把一份文件**放进废纸篓**。做成接缝是为了能测 —— 真的 `trashItem` 会把测试
    /// 造出来的文件丢进跑测试那个人的废纸篓里（跑一次多几条，没人会注意到，
    /// 但那是"测试污染用户的环境"）。
    public typealias FileTrasher = (URL) throws -> Void

    private let directory: URL
    private let fileManager: FileManager
    private let trash: FileTrasher
    private let logger = Logger(subsystem: AppIdentity().logSubsystem, category: "history")
    /// 索引与文件的读写都在这一把锁里。历史可能被采集路径（后台）与面板（主线程）同时碰。
    private let lock = NSLock()

    public init(directory: URL? = nil,
                limit: Int = CaptureHistoryStore.defaultLimit,
                fileManager: FileManager = .default,
                trash: FileTrasher? = nil) {
        self.fileManager = fileManager
        self._limit = max(1, limit)
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.trash = trash ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// 默认目录 = `AppIdentity` 给的那个。
    ///
    /// ⚠️ 这里**不再写死 `Marquee`**：写死的话，开发版与正式版会共用同一份历史，
    /// 而"调试删除逻辑删掉真实历史"就是那么发生的（见 `docs/DEV-VS-PROD.md`）。
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        AppIdentity().historyDirectory(fileManager: fileManager)
    }

    public var directoryURL: URL { directory }

    // MARK: - 读

    /// 全部条目，**新 → 旧**。
    public func entries() -> [CaptureHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadIndex()
    }

    /// 取回一张图（原图 + 标注）。取不到（文件被外部删了）时返回 `nil`。
    public func snapshot(for entry: CaptureHistoryEntry) -> CaptureHistorySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let original = loadImage(named: entry.originalFileName) else { return nil }
        let annotations: [Annotation] = entry.annotationsFileName
            .flatMap { loadJSON([Annotation].self, named: $0) } ?? []
        return CaptureHistorySnapshot(original: original, annotations: annotations)
    }

    // MARK: - 写

    @discardableResult
    public func record(original: CGImage,
                       originalPNG: Data?,
                       annotations: [Annotation],
                       at date: Date) -> UUID? {
        lock.lock()
        defer { lock.unlock() }

        let id = UUID()
        let originalName = "\(id.uuidString)-original.png"
        let annotationsName = annotations.isEmpty ? nil : "\(id.uuidString)-annotations.json"

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let png: Data
            if let originalPNG {
                png = originalPNG
            } else if let encoded = ImageEncoding.pngData(from: original) {
                png = encoded
            } else {
                return nil
            }
            try png.write(to: directory.appendingPathComponent(originalName))
            if let annotationsName {
                let data = try JSONEncoder().encode(annotations)
                try data.write(to: directory.appendingPathComponent(annotationsName))
            }
        } catch {
            // 落盘失败就**不留半条记录**：一条指向不存在文件的历史，
            // 点开时只会得到"加载失败"，而用户会以为那张图丢了。
            try? fileManager.removeItem(at: directory.appendingPathComponent(originalName))
            if let annotationsName {
                try? fileManager.removeItem(at: directory.appendingPathComponent(annotationsName))
            }
            return nil
        }

        let entry = CaptureHistoryEntry(id: id,
                                        capturedAt: date,
                                        pixelSize: CGSize(width: original.width, height: original.height),
                                        annotationCount: annotations.count,
                                        originalFileName: originalName,
                                        annotationsFileName: annotationsName)
        var list = loadIndex()
        list.insert(entry, at: 0)
        evict(&list)
        saveIndex(list)
        return entry.id
    }

    /// 删一条 —— **用户按的那一下**，所以它的文件进**废纸篓**。
    ///
    /// ## 为什么是废纸篓，而不是直接抹掉
    ///
    /// 设计稿 §02 给的理由是它替掉了确认弹窗：「硬约束禁止新弹窗，而『删了就没』配
    /// 『不可撤销』在一个高频面板里是危险的。废纸篓把撤销权交给系统
    /// （Finder 里随时捞回来），我们一步不加 —— 这比弹一个『确定删除吗』更体面，也更符合 macOS。」
    ///
    /// ⚠️ 与「自动淘汰」（`evict`）的区别是**刻意的**：那一条不是用户按的，
    /// 他既没要求删那几张、也不知道是哪几张。把淘汰也塞进废纸篓，等于我们每次截图
    /// 都往他的废纸篓里丢东西 —— 那是借系统的回收站来掩盖我们自己的决定。
    public func delete(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var list = loadIndex()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let entry = list.remove(at: index)
        removeFiles(of: entry, via: .trash)
        saveIndex(list)
    }

    /// 全清（连同文件）。同样不是"用户按了删除那一下"，所以永久删。
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for entry in loadIndex() { removeFiles(of: entry, via: .erase) }
        saveIndex([])
    }

    // MARK: - 内部

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// 淘汰最旧的几条，直到回到上限之内。
    ///
    /// 顺序**只由数组顺序决定**（`record` 总是插在最前面），不重新按时间排序 ——
    /// 万一系统时钟被改过，按时间排会把"刚截的"排到最旧去、然后被删掉。
    private func evict(_ list: inout [CaptureHistoryEntry]) {
        // `nil` = 不淘汰（Pro）。读 `_limit` 而不是 `limit` —— 这个方法已经在锁里了，
        // 再走一次带锁的 getter 会死锁（`NSLock` 不可重入）。
        guard let cap = _limit else { return }
        while list.count > cap {
            let dropped = list.removeLast()
            removeFiles(of: dropped, via: .erase)
        }
    }

    /// 一份文件该怎么处置。
    private enum Disposal {
        /// 进废纸篓（用户按的删除）
        case trash
        /// 直接抹掉（自动淘汰 / 全清）
        case erase
    }

    private func removeFiles(of entry: CaptureHistoryEntry, via disposal: Disposal) {
        for name in [entry.originalFileName, entry.annotationsFileName].compactMap({ $0 }) {
            let url = directory.appendingPathComponent(name)
            switch disposal {
            case .erase:
                try? fileManager.removeItem(at: url)
            case .trash:
                disposeToTrash(url)
            }
        }
    }

    /// 把一份文件放进废纸篓，**放不进去就抹掉**。
    ///
    /// ## 为什么失败时要退回"抹掉"，而不是留着它
    ///
    /// 走到这里说明用户已经按了删除，那条记录**一定**会离开索引（这是"删除"的定义）。
    /// 于是只剩两种结果：
    ///
    /// | 废纸篓失败时的做法 | 后果 |
    /// | --- | --- |
    /// | 留着文件 | 历史目录里多一个**谁都看不见**的孤儿文件 —— 用户既回收不了它，也永远不知道它占着空间 |
    /// | 抹掉 | 少了一次"还能捞回来"的机会，但磁盘与界面是一致的 |
    ///
    /// 第二种更可取：孤儿文件是唯一那种**既看不见又永久**的坏结果。
    ///
    /// ⚠️ 文件本来就不在时**不去惹废纸篓** —— `trashItem` 对不存在的路径会抛错，
    /// 而那会把上面这条退路误触发一次（日志里会多一条"回收失败"，其实什么都没发生）。
    private func disposeToTrash(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try trash(url)
        } catch {
            logger.warning("回收站不可用，改为永久删除：\(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: url)
        }
    }

    private func loadIndex() -> [CaptureHistoryEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([CaptureHistoryEntry].self, from: data) else {
            // 索引读不出来（第一次运行 / 文件被外部破坏）时当作空 ——
            // 绝不因为一个坏索引让整个功能不可用。
            return []
        }
        return list
    }

    private func saveIndex(_ list: [CaptureHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func loadImage(named name: String) -> CGImage? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, named name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

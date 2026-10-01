import CoreGraphics
import Foundation
import ImageIO
import MarqueeCore

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
/// `~/Library/Application Support/Marquee/history/`：
/// - `index.json` —— 条目清单（新→旧）
/// - `<uuid>-original.png` / `<uuid>-annotations.json`
///
/// **只删自己写出来的文件**：条目里记的是文件名，删除时按名字删，
/// 于是用户自己另存到别处的图**永远不在删除范围内**（ticket 的验收项之一）。
public final class CaptureHistoryStore: CaptureHistoryWriting, @unchecked Sendable {

    /// 上限。超过就淘汰最旧的 —— 不让磁盘无限增长。
    public static let defaultLimit = 20

    private let directory: URL
    private let limit: Int
    private let fileManager: FileManager
    /// 索引与文件的读写都在这一把锁里。历史可能被采集路径（后台）与面板（主线程）同时碰。
    private let lock = NSLock()

    public init(directory: URL? = nil,
                limit: Int = CaptureHistoryStore.defaultLimit,
                fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.limit = max(1, limit)
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Marquee/history", isDirectory: true)
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

    /// 删一条，并把它的文件一起清掉。
    public func delete(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var list = loadIndex()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let entry = list.remove(at: index)
        removeFiles(of: entry)
        saveIndex(list)
    }

    /// 全清（连同文件）。
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for entry in loadIndex() { removeFiles(of: entry) }
        saveIndex([])
    }

    // MARK: - 内部

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// 淘汰最旧的几条，直到回到上限之内。
    ///
    /// 顺序**只由数组顺序决定**（`record` 总是插在最前面），不重新按时间排序 ——
    /// 万一系统时钟被改过，按时间排会把"刚截的"排到最旧去、然后被删掉。
    private func evict(_ list: inout [CaptureHistoryEntry]) {
        while list.count > limit {
            let dropped = list.removeLast()
            removeFiles(of: dropped)
        }
    }

    private func removeFiles(of entry: CaptureHistoryEntry) {
        for name in [entry.originalFileName, entry.annotationsFileName].compactMap({ $0 }) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
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

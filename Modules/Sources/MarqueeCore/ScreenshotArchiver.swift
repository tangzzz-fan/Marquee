import CoreGraphics
import Foundation

/// 落盘用的输出设置。偏好窗口（ticket 15）以后写同一组字段；现在 `⌘S` 读默认值。
public struct OutputSettings: Equatable, Sendable {
    /// 落盘目录。
    ///
    /// **`nil` = 用户还没有选过保存位置**（不是"不适用"）。这一项必须可选 ——
    /// 给它兜一个默认路径，就等于替用户预置了一个位置，而 App Review
    /// 2.4.5(i) 正是因此打回（2026-10-14，见 `docs/PITFALLS.md` 202）。
    public var directory: URL?
    public var format: ImageFileFormat
    public var quality: Double
    public var nameTemplate: String

    public init(directory: URL?,
                format: ImageFileFormat = .png,
                quality: Double = 0.9,
                nameTemplate: String = FileNameTemplate.defaultTemplate) {
        self.directory = directory
        self.format = format
        self.quality = quality
        self.nameTemplate = nameTemplate
    }

    /// 保存面板打开时的**浏览起点**（只是一个方便落脚的地方，不是落盘位置）。
    ///
    /// ## 为什么这里不再叫「默认落盘目录」
    ///
    /// 它原先叫 `defaultOutputDirectory()`、返回 `~/Pictures/Marquee`，
    /// 被当成"用户什么都不选就存这儿"。2026-10-14 那次提审，Apple 按
    /// Guideline 2.4.5(i) 打回两条：**预置位置 `~/Pictures`**，以及**为它声明的
    /// `com.apple.security.assets.pictures.read-write`**（"entitlement 与功能不匹配"）。
    ///
    /// 原文给出的下一步是："让用户通过标准的 Open/Save 面板选择默认位置"。
    /// 于是位置改由**面板选一次 + security-scoped 书签**记住，
    /// 这里只剩面板的起点。名字跟着改，免得下一个人又把它当落盘目标写回去。
    ///
    /// ## 为什么自己拼路径，而不是问 `FileManager` 要 `.picturesDirectory`
    ///
    /// 沙盒下那个 API 返回的是**容器里的** Pictures（它由 `NSHomeDirectory()` 推出来），
    /// 于是面板会从一个用户永远找不到的地方打开。见 `AppIdentity.realHomeDirectory()`。
    public static func savePanelStartDirectory(fileManager: FileManager = .default) -> URL {
        let home = AppIdentity.realHomeDirectory()
        let suggested = home
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Marquee", isDirectory: true)
        // 只返回**存在**的目录：面板拿到一个不存在的 `directoryURL` 会安静地退回默认位置，
        // 于是"起点"这件事看着像是没生效。
        if fileManager.fileExists(atPath: suggested.path) { return suggested }
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        if fileManager.fileExists(atPath: pictures.path) { return pictures }
        return home
    }

    /// 给用户选中的目录建**书签**。
    ///
    /// 沙盒下"用户选过"这件事只在**当次运行**有效；跨启动还能写进同一个目录，
    /// 靠的就是这份 security-scoped 书签（`com.apple.security.files.user-selected.read-write`
    /// 已经覆盖了它的创建与解析，不需要额外的 bookmark entitlement）。
    public static func securityScopedBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope,
                              includingResourceValuesForKeys: nil,
                              relativeTo: nil)
    }

    /// 解析面板给出的书签。`isStale` = 目录被移动/改名的信号（调用方应重存一份）。
    public static func resolveDirectoryBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}

extension OutputSettings {

    /// 界面上「保存位置」那一格显示什么。
    ///
    /// ## 为什么收在这一处
    ///
    /// 偏好页与引导页各有一格「保存位置」（2026-10-20 加的引导页那一格）。
    /// 各写一遍 `directory?.path ?? …` 的代价不是重复三行，而是**同一件事在两个窗口里
    /// 说法不同** —— 改了文案只改一处，而"两个地方写的不一样"没人会当成 bug 去查。
    ///
    /// ## 为什么"没选过"必须是一句话，而不是一个路径
    ///
    /// 这一格若兜一个路径（哪怕只是面板起点），预置位置就只是从**落盘层**挪到了**显示层** ——
    /// 而审核看的是用户看到什么。2.4.5(i) 打回的正是这一件事，见 `docs/PITFALLS.md` 202。
    public var directorySummary: String {
        directory?.path ?? L10n.t("未选择 · 第一次保存时选")
    }
}

/// 一次 `⌘S` 要写入的上下文。序号由调用方先占一个，撞名时归档器自己往后加。
public struct CaptureSaveRequest: Equatable, Sendable {
    public var settings: OutputSettings
    public var capturedAt: Date
    public var sequence: Int
    public var applicationName: String
    public var windowTitle: String
    public var calendar: Calendar

    public init(settings: OutputSettings,
                capturedAt: Date,
                sequence: Int,
                applicationName: String,
                windowTitle: String,
                calendar: Calendar = .current) {
        self.settings = settings
        self.capturedAt = capturedAt
        self.sequence = sequence
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.calendar = calendar
    }
}

public struct ArchiveFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct ArchiveWriteResult: Equatable, Sendable {
    public let url: URL
    public let sequenceUsed: Int

    public init(url: URL, sequenceUsed: Int) {
        self.url = url
        self.sequenceUsed = sequenceUsed
    }
}

/// 把一张图按模板写到目录里。
///
/// 目录不存在会创建。同名文件已存在就递增序号，**不覆盖**。
/// 写入失败只返回说明，调用方必须仍然保留剪贴板里的图。
public enum ScreenshotArchiver {

    public static func write(_ image: CGImage,
                             request: CaptureSaveRequest,
                             fileManager: FileManager = .default) -> Result<ArchiveWriteResult, ArchiveFailure> {
        // ⚠️ 没有位置就**不写**，也不许拿一个"默认目录"顶上：
        // 那种兜底会写到用户没选过的地方（沙盒里直接 `Operation not permitted`，
        // 而非沙盒里是"图存到了他不知道的文件夹"）。调用方本该先问出位置。
        guard let directory = request.settings.directory else {
            return .failure(ArchiveFailure(message: L10n.t("还没有选择保存位置，这次没有写盘。剪贴板里的图仍然可用")))
        }

        // 用户选过的目录靠 security-scoped 书签续命：写之前必须 start，写完 stop。
        // 非沙盒下 `start` 返回 false，什么都不做 —— 两种构建同一条代码路径。
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(ArchiveFailure(message: L10n.t("无法创建保存目录 \(directory.path)：\(error.localizedDescription)。剪贴板里的图仍然可用")))
        }

        guard let data = ImageEncoding.data(from: image,
                                            format: request.settings.format,
                                            quality: request.settings.quality) else {
            return .failure(ArchiveFailure(message: L10n.t("截图编码为 \(request.settings.format.rawValue.uppercased()) 失败，剪贴板里的图仍然可用")))
        }

        var sequence = max(0, request.sequence)
        let ext = request.settings.format.pathExtension
        for _ in 0..<1000 {
            let stem = FileNameTemplate.render(request.settings.nameTemplate,
                                               date: request.capturedAt,
                                               calendar: request.calendar,
                                               sequence: sequence,
                                               applicationName: request.applicationName,
                                               windowTitle: request.windowTitle)
            let url = directory.appendingPathComponent(stem).appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: url.path) {
                do {
                    try data.write(to: url, options: .withoutOverwriting)
                    return .success(ArchiveWriteResult(url: url, sequenceUsed: sequence))
                } catch {
                    return .failure(ArchiveFailure(message: L10n.t("无法写入 \(url.path)：\(error.localizedDescription)。剪贴板里的图仍然可用")))
                }
            }
            sequence += 1
        }
        return .failure(ArchiveFailure(message: L10n.t("保存失败：\(directory.path) 里同名文件太多，剪贴板里的图仍然可用")))
    }
}

/// 序号与输出设置的落盘。界面在 ticket 15，这里先把默认值稳住，`⌘S` 才能重复按下而不互相覆盖。
public struct UserDefaultsOutputStore: @unchecked Sendable {
    public static let directoryKey = "output.directoryPath"
    /// 用户在面板里选的那个目录的 security-scoped 书签。
    ///
    /// **沙盒下路径本身不算数**：跨启动还能写进那个目录，只有书签能给这个权限。
    /// 所以判据是"有书签就只认书签"，见 `chosenDirectory()`。
    public static let bookmarkKey = "output.directoryBookmark"
    public static let formatKey = "output.format"
    public static let qualityKey = "output.quality"
    public static let templateKey = "output.nameTemplate"
    public static let sequenceKey = "output.sequence"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 用户**亲手选过**的保存目录；`nil` = 还没选过。
    ///
    /// ⚠️ 这里**没有兜底目录**，而且顺序不能反过来：
    ///
    /// 1. 有书签 ⇒ **只认书签**。解析不出来（文件夹被删/改名）就当作没选过，
    ///    让调用方重新问用户 —— 退回去拿路径硬写，在沙盒里会失败成
    ///    `Operation not permitted`，用户看不出原因（PITFALLS 202）。
    /// 2. 没书签 ⇒ 才退回路径。这一支服务的是**非沙盒构建**，以及书签没建成的那一次。
    public func chosenDirectory() -> URL? {
        if let data = defaults.data(forKey: Self.bookmarkKey) {
            // **有书签就只认书签**：解析不出来 = 那个文件夹已经不在了（或书签坏了），
            // 当作没选过、让调用方重新问用户。退回去拿路径硬写，在沙盒里会失败成
            // `Operation not permitted`，用户看不出原因（PITFALLS 202）。
            guard let resolved = OutputSettings.resolveDirectoryBookmark(data) else { return nil }
            // 目录被移动过 ⇒ 旧书签还能解析但已过期，重存一份，否则下次可能就解析不出来了。
            if resolved.isStale,
               let refreshed = OutputSettings.securityScopedBookmark(for: resolved.url) {
                defaults.set(refreshed, forKey: Self.bookmarkKey)
            }
            return resolved.url
        }
        // 没书签才退回路径：服务非沙盒构建，以及书签没建成的那一次。
        let path = defaults.string(forKey: Self.directoryKey) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 记住用户在面板里选的目录。
    ///
    /// - Parameter bookmark: 传 `nil` = 书签没建成（只剩路径，仅非沙盒构建可用）。
    public func saveDirectory(_ url: URL, bookmark: Data?) {
        defaults.set(url.path, forKey: Self.directoryKey)
        if let bookmark {
            defaults.set(bookmark, forKey: Self.bookmarkKey)
        } else {
            defaults.removeObject(forKey: Self.bookmarkKey)
        }
    }

    public func settings() -> OutputSettings {
        let format = ImageFileFormat(rawValue: defaults.string(forKey: Self.formatKey) ?? "") ?? .png
        let storedQuality = defaults.object(forKey: Self.qualityKey) as? Double
        let quality = storedQuality.map { min(1, max(0, $0)) } ?? 0.9
        let template = defaults.string(forKey: Self.templateKey).flatMap { $0.isEmpty ? nil : $0 }
            ?? FileNameTemplate.defaultTemplate
        return OutputSettings(directory: chosenDirectory(),
                              format: format,
                              quality: quality,
                              nameTemplate: template)
    }

    /// 写入输出设置（界面在 ticket 15）。
    ///
    /// 与 `settings()` 成对放在这里：key 是这一类型自己的私事，
    /// 让界面去 `defaults.set(_:forKey:)` 就等于把 key 暴露出去 ——
    /// 那时候"改了没生效"要同时看两处才查得出来。
    public func save(_ settings: OutputSettings) {
        // 目录用 `saveDirectory(_:bookmark:)` 写（它一并管书签）。
        // 这里只在**明确有值**时更新路径：写设置里的格式/质量不该把保存位置清掉。
        if let directory = settings.directory {
            defaults.set(directory.path, forKey: Self.directoryKey)
        }
        defaults.set(settings.format.rawValue, forKey: Self.formatKey)
        defaults.set(min(1, max(0, settings.quality)), forKey: Self.qualityKey)
        defaults.set(settings.nameTemplate, forKey: Self.templateKey)
    }

    /// 占下一个序号（从 1 起）并记下来。
    public func consumeSequence() -> Int {
        let next = max(1, defaults.integer(forKey: Self.sequenceKey) + 1)
        defaults.set(next, forKey: Self.sequenceKey)
        return next
    }

    /// 撞名往后跳过时，把计数器跟到实际用掉的序号，避免下次又从旧号开始。
    public func advanceSequence(to used: Int) {
        let stored = defaults.integer(forKey: Self.sequenceKey)
        if used > stored {
            defaults.set(used, forKey: Self.sequenceKey)
        }
    }
}

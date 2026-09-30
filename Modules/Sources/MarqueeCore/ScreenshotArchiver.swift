import CoreGraphics
import Foundation

/// 落盘用的输出设置。偏好窗口（ticket 15）以后写同一组字段；现在 `⌘S` 读默认值。
public struct OutputSettings: Equatable, Sendable {
    public var directory: URL
    public var format: ImageFileFormat
    public var quality: Double
    public var nameTemplate: String

    public init(directory: URL,
                format: ImageFileFormat = .png,
                quality: Double = 0.9,
                nameTemplate: String = FileNameTemplate.defaultTemplate) {
        self.directory = directory
        self.format = format
        self.quality = quality
        self.nameTemplate = nameTemplate
    }

    public static func desktopDirectory() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Desktop", isDirectory: true)
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
        let directory = request.settings.directory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(ArchiveFailure(message: "无法创建保存目录 \(directory.path)：\(error.localizedDescription)。剪贴板里的图仍然可用"))
        }

        guard let data = ImageEncoding.data(from: image,
                                            format: request.settings.format,
                                            quality: request.settings.quality) else {
            return .failure(ArchiveFailure(message: "截图编码为 \(request.settings.format.rawValue.uppercased()) 失败，剪贴板里的图仍然可用"))
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
                    return .failure(ArchiveFailure(message: "无法写入 \(url.path)：\(error.localizedDescription)。剪贴板里的图仍然可用"))
                }
            }
            sequence += 1
        }
        return .failure(ArchiveFailure(message: "保存失败：\(directory.path) 里同名文件太多，剪贴板里的图仍然可用"))
    }
}

/// 序号与输出设置的落盘。界面在 ticket 15，这里先把默认值稳住，`⌘S` 才能重复按下而不互相覆盖。
public struct UserDefaultsOutputStore: @unchecked Sendable {
    public static let directoryKey = "output.directoryPath"
    public static let formatKey = "output.format"
    public static let qualityKey = "output.quality"
    public static let templateKey = "output.nameTemplate"
    public static let sequenceKey = "output.sequence"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func settings() -> OutputSettings {
        let path = defaults.string(forKey: Self.directoryKey) ?? ""
        let directory = path.isEmpty
            ? OutputSettings.desktopDirectory()
            : URL(fileURLWithPath: path, isDirectory: true)
        let format = ImageFileFormat(rawValue: defaults.string(forKey: Self.formatKey) ?? "") ?? .png
        let storedQuality = defaults.object(forKey: Self.qualityKey) as? Double
        let quality = storedQuality.map { min(1, max(0, $0)) } ?? 0.9
        let template = defaults.string(forKey: Self.templateKey).flatMap { $0.isEmpty ? nil : $0 }
            ?? FileNameTemplate.defaultTemplate
        return OutputSettings(directory: directory, format: format, quality: quality, nameTemplate: template)
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

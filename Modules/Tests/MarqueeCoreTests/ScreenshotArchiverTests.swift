import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MarqueeCore

@Suite("截图落盘")
struct ScreenshotArchiverTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-archive-\(UUID().uuidString)", isDirectory: true)
    }

    private func request(directory: URL,
                         format: ImageFileFormat = .png,
                         quality: Double = 0.9,
                         sequence: Int = 1,
                         template: String = "Shot {index}") -> CaptureSaveRequest {
        CaptureSaveRequest(settings: OutputSettings(directory: directory,
                                                    format: format,
                                                    quality: quality,
                                                    nameTemplate: template),
                           capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           sequence: sequence,
                           applicationName: "Safari",
                           windowTitle: "Start",
                           calendar: {
                               var calendar = Calendar(identifier: .gregorian)
                               calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                               return calendar
                           }())
    }

    @Test("目录不存在时会创建，并按模板写出 PNG，像素尺寸不变")
    func createsDirectoryAndWritesPNG() throws {
        let directory = temporaryDirectory().appendingPathComponent("nested", isDirectory: true)
        let image = TestImage.solid(width: 40, height: 24, red: 0.1, green: 0.2, blue: 0.3)
        let result = try written(ScreenshotArchiver.write(image, request: request(directory: directory)))

        #expect(result.url.lastPathComponent == "Shot 001.png")
        #expect(result.sequenceUsed == 1)
        let data = try Data(contentsOf: result.url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 40)
        #expect(decoded.height == 24)
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    @Test("同名文件已存在时递增序号，不覆盖")
    func doesNotOverwrite() throws {
        let directory = temporaryDirectory()
        let image = TestImage.solid(width: 8, height: 8, red: 1, green: 0, blue: 0)
        let first = try written(ScreenshotArchiver.write(image, request: request(directory: directory)))
        let second = try written(ScreenshotArchiver.write(image, request: request(directory: directory, sequence: 1)))

        #expect(first.url.lastPathComponent == "Shot 001.png")
        #expect(second.url.lastPathComponent == "Shot 002.png")
        #expect(second.sequenceUsed == 2)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("目录不可写时返回说明，不抛掉调用方已经拿到的图")
    func unwritableDirectoryReportsFailure() throws {
        let blocker = temporaryDirectory()
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let notADirectory = blocker.appendingPathComponent("file")
        try Data("x".utf8).write(to: notADirectory)
        let image = TestImage.solid(width: 4, height: 4, red: 0, green: 0, blue: 0)

        let result = ScreenshotArchiver.write(image, request: request(directory: notADirectory))
        guard case .failure(let failure) = result else {
            Issue.record("期望写入失败，实际 \(result)")
            return
        }
        #expect(failure.message.contains("剪贴板"))
        try? FileManager.default.removeItem(at: blocker)
    }

    private func written(_ result: Result<ArchiveWriteResult, ArchiveFailure>) throws -> ArchiveWriteResult {
        switch result {
        case .success(let value):
            return value
        case .failure(let failure):
            throw failure
        }
    }
}

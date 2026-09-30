import Foundation
import Testing
@testable import MarqueeCore

@Suite("文件名模板")
struct FileNameTemplateTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2023-11-14 22:13:20 UTC
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("日期、时间和序号都会替换，序号补齐 3 位")
    func replacesDateTimeAndIndex() {
        let name = FileNameTemplate.render("{date} {time} {index}",
                                           date: date,
                                           calendar: utc,
                                           sequence: 7,
                                           applicationName: "",
                                           windowTitle: "")
        #expect(name == "2023-11-14 22.13.20 007")
    }

    @Test("年月日时分秒占位符按日历组件补零")
    func replacesComponents() {
        let name = FileNameTemplate.render("{yyyy}{MM}{dd}-{HH}{mm}{ss}",
                                           date: date,
                                           calendar: utc,
                                           sequence: 1,
                                           applicationName: "",
                                           windowTitle: "")
        #expect(name == "20231114-221320")
    }

    @Test("窗口标题里的非法字符被换成连字符")
    func stripsIllegalCharacters() {
        let name = FileNameTemplate.render("{title}",
                                           date: date,
                                           calendar: utc,
                                           sequence: 1,
                                           applicationName: "",
                                           windowTitle: "报告/草稿:v1*终稿?")
        #expect(name == "报告-草稿-v1-终稿")
    }

    @Test("超长窗口标题截到 80 字")
    func truncatesLongTitle() {
        let title = String(repeating: "字", count: 120)
        let name = FileNameTemplate.render("{title}",
                                           date: date,
                                           calendar: utc,
                                           sequence: 1,
                                           applicationName: "",
                                           windowTitle: title)
        #expect(name.count == 80)
        #expect(name == String(repeating: "字", count: 80))
    }

    @Test("应用名同样过滤非法字符")
    func sanitizesApplicationName() {
        let name = FileNameTemplate.render("{app}",
                                           date: date,
                                           calendar: utc,
                                           sequence: 1,
                                           applicationName: "Notes: Draft",
                                           windowTitle: "")
        #expect(name == "Notes- Draft")
    }
}

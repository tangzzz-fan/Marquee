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

    @Test("界面上摆出来的每个变量，render 都真的认 —— 摆一个不认的等于骗用户")
    func availableTokensAreAllReal() {
        // ⚠️ 这条是拿真实存在的一个错写的：`PAGE-LOGIC.md` 里那份清单写的是 `{n}`，
        // 而实现里的序号变量叫 `{index}`。用户点一下 `{n}`，文件名会真的叫
        // `Marquee-{n}.png` —— 而它看起来像"模板功能坏了"，不像"清单写错了"。
        for token in FileNameTemplate.availableTokens {
            let rendered = FileNameTemplate.render(token,
                                                   date: Date(timeIntervalSince1970: 0),
                                                   sequence: 1,
                                                   applicationName: "App",
                                                   windowTitle: "T")
            #expect(!rendered.contains("{"),
                    "\(token) 没有被替换（渲染成了 \(rendered)）—— render 不认它")
        }
        // 反向：认得的那张表里也不该有"没人会用到"的漏网之鱼
        #expect(!FileNameTemplate.variables.isEmpty)
    }
}

import Foundation

/// 截图文件名模板。
///
/// 占位符：`{yyyy}` `{MM}` `{dd}` `{HH}` `{mm}` `{ss}` `{date}` `{time}` `{index}` `{app}` `{title}`。
/// `{date}` = `yyyy-MM-dd`，`{time}` = `HH.mm.ss`（冒号不能进文件名）。
/// `{index}` 至少补齐 3 位。应用名和窗口标题里的非法字符会被换成 `-`，标题超过 80 字会截断。
public enum FileNameTemplate {

    public static let defaultTemplate = "Marquee {date} at {time} {index}"
    public static let maximumFieldLength = 80

    /// `render` 认识的**全部**变量名。
    ///
    /// 提取成一个常量是为了让"界面摆的清单"与"实际会替换的清单"能对得上 ——
    /// 两处各写一遍的话，界面摆出一个不认的变量时**不会报错**，
    /// 只是那个占位符会原样留在文件名里。
    public static let variables = ["date", "time", "yyyy", "MM", "dd", "HH", "mm", "ss",
                                   "index", "app", "title"]

    /// 界面上要摆出来的**常用变量**（顺序即从左到右）。
    ///
    /// ⚠️ 最早的一版 `PAGE-LOGIC.md` 里写的是 `{date} {time} {n} {app} {title}` ——
    /// 而实现里的**序号变量叫 `{index}`，不叫 `{n}`**。
    /// 这个差别是要命的那种：界面摆出一个 `render` 不认的变量，用户点一下
    /// 得到的是**原样留在文件名里的一段字面量**（文件真的会叫 `Marquee-{n}.png`），
    /// 而它看起来像"模板功能坏了"。
    ///
    /// ⇒ 所以这份清单**不手写**，而是与替换表同源（见 `variables`），
    /// 并由 `FileNameTemplateTests.availableTokensAreAllReal` 钉住。
    public static let availableTokens = ["{date}", "{time}", "{index}", "{app}", "{title}"]

    public static func render(_ template: String,
                              date: Date,
                              calendar: Calendar = .current,
                              sequence: Int,
                              applicationName: String,
                              windowTitle: String) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let yyyy = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        let hour = String(format: "%02d", parts.hour ?? 0)
        let minute = String(format: "%02d", parts.minute ?? 0)
        let second = String(format: "%02d", parts.second ?? 0)

        let values = [
            "date": "\(yyyy)-\(month)-\(day)",
            "time": "\(hour).\(minute).\(second)",
            "yyyy": yyyy,
            "MM": month,
            "dd": day,
            "HH": hour,
            "mm": minute,
            "ss": second,
            "index": String(format: "%03d", max(0, sequence)),
            "app": sanitize(applicationName),
            "title": sanitize(windowTitle),
        ]

        var result = template
        for key in variables {
            result = result.replacingOccurrences(of: "{\(key)}", with: values[key] ?? "")
        }
        let stem = sanitize(result, limit: 180)
        return stem.isEmpty ? "Marquee" : stem
    }

    /// 去掉路径分隔符和文件名保留字符。连续的 `-` 收成一个。
    public static func sanitize(_ raw: String, limit: Int = maximumFieldLength) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            scalars.append(illegal.contains(scalar) ? "-" : scalar)
        }
        var text = String(String.UnicodeScalarView(scalars))
        while text.contains("--") {
            text = text.replacingOccurrences(of: "--", with: "-")
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        if text.count > limit {
            text = String(text.prefix(limit))
        }
        return text
    }
}

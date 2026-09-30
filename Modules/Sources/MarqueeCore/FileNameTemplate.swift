import Foundation

/// 截图文件名模板。
///
/// 占位符：`{yyyy}` `{MM}` `{dd}` `{HH}` `{mm}` `{ss}` `{date}` `{time}` `{index}` `{app}` `{title}`。
/// `{date}` = `yyyy-MM-dd`，`{time}` = `HH.mm.ss`（冒号不能进文件名）。
/// `{index}` 至少补齐 3 位。应用名和窗口标题里的非法字符会被换成 `-`，标题超过 80 字会截断。
public enum FileNameTemplate {

    public static let defaultTemplate = "Marquee {date} at {time} {index}"
    public static let maximumFieldLength = 80

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
        for key in ["date", "time", "yyyy", "MM", "dd", "HH", "mm", "ss", "index", "app", "title"] {
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

import Foundation
import Testing

@testable import MarqueeCore

/// 本地化扫描（ticket 17b）。
///
/// ## 为什么要有这么一组测试
///
/// 本地化最容易的失败形态**不是崩**，而是"英文用户看到中文" —— 不报错、没日志，
/// 只有在另一台机器上把系统语言换掉才看得见。所以判据必须是可执行的：
///
/// - 生产代码里**不许再有**没包 `L10n.t` 的中文字面量
/// - 源码用到的每个 key **必须**在 catalog 里有对应条目（漏了就是漏翻）
/// - catalog 里的每条 **必须**有非空的英文
/// - catalog 里**不许有孤儿**（源码里找不到的 key，说明改了文案没清理）
///
/// ## 豁免怎么写
///
/// 有些中文**刻意不翻译**（诊断报告、`DateFormatter` 格式串、手势档位名）。
/// 用标记声明，并且**必须写理由**：
///
/// ```swift
/// // L10N-EXEMPT-START: -marqueeDiagnostics 的报告，贴回来给我看，翻译反而看不懂
/// ...
/// // L10N-EXEMPT-END
/// ```
///
/// 单行可以用行尾标记：`let f = "M月d日 HH:mm"   // L10N-EXEMPT: DateFormatter 的格式串`
///
/// 用标记而不是"文件+行号白名单"：行号会腐烂，而烂掉之后的表现是**测试继续绿**。
@Suite("本地化扫描（ticket 17b）")
struct LocalizationScanTests {

    // MARK: - 定位

    /// 从本文件的路径上溯到仓库根（`Modules/Tests/MarqueeCoreTests/xxx.swift` → 仓库）。
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MarqueeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // 仓库根
    }

    static var sourceFiles: [URL] {
        let dirs = ["App/Sources", "Modules/Sources"]
        var out: [URL] = []
        for dir in dirs {
            let base = root.appendingPathComponent(dir)
            let walker = FileManager.default.enumerator(at: base,
                                                        includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                if url.pathExtension == "swift" { out.append(url) }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    static var catalogURL: URL {
        root.appendingPathComponent("App/Resources/Localizable.xcstrings")
    }

    // MARK: - 扫描

    struct Literal {
        var content: String
        var line: Int
        /// 紧邻前面就是 `L10n.t(`
        var isEntry: Bool
    }

    /// 把豁免区域涂成空格（保留长度与换行，于是行号与偏移都不变）。
    static func blankingExemptions(_ text: String) -> String {
        var chars = Array(text)
        var inBlock = false
        var lineStart = 0
        var line = 1
        var i = 0
        func blank(from: Int, to: Int) {
            for k in from..<min(to, chars.count) where chars[k] != "\n" { chars[k] = " " }
        }
        while i < chars.count {
            if chars[i] == "\n" {
                lineStart = i + 1
                line += 1
                i += 1
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                var end = i
                while end < chars.count, chars[end] != "\n" { end += 1 }
                let comment = String(chars[i..<end])
                if comment.contains("L10N-EXEMPT-START") {
                    inBlock = true
                } else if comment.contains("L10N-EXEMPT-END") {
                    inBlock = false
                } else if comment.contains("L10N-EXEMPT") {
                    blank(from: lineStart, to: i)   // 行尾标记：只豁免这一行
                }
                if inBlock { blank(from: lineStart, to: end) }
                i = end
                continue
            }
            if inBlock { blank(from: i, to: i + 1) }
            i += 1
        }
        return String(chars)
    }

    /// 抽出所有字符串字面量。会跳过注释、处理 `\(…)` 里可能嵌套的引号。
    static func literals(in text: String) -> [Literal] {
        var out: [Literal] = []
        let chars = Array(text)
        var i = 0
        var line = 1
        let n = chars.count

        func isEntry(at start: Int) -> Bool {
            var k = start - 1
            while k >= 0, chars[k] == " " || chars[k] == "\t" { k -= 1 }
            guard k >= 0, chars[k] == "(" else { return false }
            k -= 1
            let needle = Array("L10n.t")
            var m = needle.count - 1
            while m >= 0, k >= 0, chars[k] == needle[m] { k -= 1; m -= 1 }
            return m < 0
        }

        while i < n {
            if chars[i] == "\n" { line += 1; i += 1; continue }
            // 块注释
            if chars[i] == "/", i + 1 < n, chars[i + 1] == "*" {
                i += 2
                while i + 1 < n, !(chars[i] == "*" && chars[i + 1] == "/") {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i = min(i + 2, n)
                continue
            }
            // 行注释
            if chars[i] == "/", i + 1 < n, chars[i + 1] == "/" {
                while i < n, chars[i] != "\n" { i += 1 }
                continue
            }
            guard chars[i] == "\"" else { i += 1; continue }

            let entry = isEntry(at: i)
            let startLine = line
            // 多行字面量
            var isMultiline = false
            if i + 2 < n, chars[i + 1] == "\"", chars[i + 2] == "\"" { isMultiline = true }
            i += isMultiline ? 3 : 1

            var content: [Character] = []
            while i < n {
                let c = chars[i]
                if c == "\n" { line += 1 }
                if c == "\\" {
                    if i + 1 < n, chars[i + 1] == "(" {
                        // 插值：跳到配对的 `)`，其中可能出现嵌套的字符串
                        var depth = 1
                        var k = i + 2
                        var inner = 0
                        while k < n, depth > 0 {
                            if chars[k] == "\n" { line += 1 }
                            if chars[k] == "\"" { inner += 1 }
                            if chars[k] == "(" { depth += 1 }
                            if chars[k] == ")" { depth -= 1 }
                            k += 1
                        }
                        _ = inner
                        content.append("\\")
                        content.append("(")
                        content.append("\u{FFFC}")   // 占位：一个插值
                        content.append(")")
                        i = k
                        continue
                    }
                    if i + 1 < n {
                        // ⚠️ 多行字面量里的行继续（`\` 结尾换行）也算一个换行。
                        // 漏计一次，后面所有行号就会整体前移 —— 而"报错的行号指向别的行"
                        // 会让每一条诊断都变成误导。
                        if chars[i + 1] == "\n" { line += 1 }
                        content.append(chars[i])
                        content.append(chars[i + 1])
                        i += 2
                        continue
                    }
                }
                if c == "\"" {
                    if isMultiline {
                        if i + 2 < n, chars[i + 1] == "\"", chars[i + 2] == "\"" { i += 3; break }
                        content.append(c)
                        i += 1
                        continue
                    }
                    i += 1
                    break
                }
                content.append(c)
                i += 1
            }
            out.append(Literal(content: String(content), line: startLine, isEntry: entry))
        }
        return out
    }

    /// 源码 key 与 catalog key 都归一成同一形状再比 ——
    /// 源码是 `\(expr)`，catalog 是 `%lld` / `%@` / `%lf` / `%.2f`，两边本来不同形。
    static func normalized(_ key: String) -> String {
        var s = ""
        let chars = Array(key)
        var i = 0
        while i < chars.count {
            // 源码的 `\(…)`：跳到配对的 `)`，整体归一成一个占位符。
            // 不依赖 `literals` 注入的标记 —— 这样把裸字符串直接喂进来也对，
            // 扫描器自检才有意义。
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                var depth = 1
                var j = i + 2
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                s += "{X}"
                i = j
                continue
            }
            if chars[i] == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": s += "\n"; i += 2; continue
                case "t": s += "\t"; i += 2; continue
                case "\"": s += "\""; i += 2; continue
                case "\\": s += "\\"; i += 2; continue
                default: break
                }
            }
            if chars[i] == "%" {
                if i + 1 < chars.count, chars[i + 1] == "%" {   // `%%` = 一个字面百分号
                    s += "%%"
                    i += 2
                    continue
                }
                var j = i + 1
                while j < chars.count, ".0123456789-+#".contains(chars[j]) { j += 1 }
                while j < chars.count, "hlLqjzt".contains(chars[j]) { j += 1 }
                if j < chars.count, "@diouxXeEfgGaAcsp".contains(chars[j]) {
                    s += "{X}"
                    i = j + 1
                    continue
                }
            }
            s.append(chars[i])
            i += 1
        }
        return s
    }

    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    struct Catalog {
        var keys: [String: String?]   // key -> 英文（nil 表示缺）
    }

    static func loadCatalog() throws -> Catalog {
        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let strings = json["strings"] as? [String: Any] ?? [:]
        var keys: [String: String?] = [:]
        for (key, value) in strings {
            let loc = (value as? [String: Any])?["localizations"] as? [String: Any]
            let en = (loc?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            keys[key] = en?["value"] as? String
        }
        return Catalog(keys: keys)
    }

    // MARK: - 测试

    /// 不算"文案"的输出：日志与断言。
    ///
    /// 它们**刻意保持中文**：排查时中文比英文快，而且它们不经过任何本地化入口
    /// （`logger` / `print` / `fatalError`）。按**行**判定，因为多行日志块的字面量
    /// 起始行上就带着 `print(`。
    static let nonUserFacingMarkers = ["logger.", "os_log(", "print(", "fatalError(",
                                       "preconditionFailure(", "precondition(", "assert(",
                                       "Logger("]

    struct Scan {
        /// 没包 `L10n.t`、也没标豁免的中文字面量
        var unlocalized: [String] = []
        /// 源码里用到的 key（已归一）
        var keys: [String] = []
    }

    static func scan() throws -> Scan {
        var result = Scan()
        for file in sourceFiles {
            let text = blankingExemptions(try String(contentsOf: file, encoding: .utf8))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for literal in literals(in: text) {
                let key = normalized(literal.content)
                if literal.isEntry {
                    // ⚠️ **keys 这一趟不看行标记**：
                    // `logger.info("…\(L10n.t("…"))")` 这种行里，包过的 key 是算数的。
                    // 用行标记把它们一起跳过，会让这条 key 变成"孤儿"，然后误报。
                    result.keys.append(key)
                    continue
                }
                let line = literal.line <= lines.count ? String(lines[literal.line - 1]) : ""
                if nonUserFacingMarkers.contains(where: line.contains) { continue }
                if hasCJK(literal.content) {
                    result.unlocalized.append("\(file.lastPathComponent):\(literal.line)  \(literal.content.prefix(60))")
                }
            }
        }
        return result
    }

    /// 判据的主体：**生产代码里不许再有没包 `L10n.t` 的中文字面量**。
    ///
    /// 这条断言的是"意图"而不是边界 —— 只写"字面量不为空"之类是盲的：
    /// 漏翻正是那种"每一处单独看都没问题、合起来才发现有 100 处没翻"的错。
    @Test("生产代码里没有未本地化的中文字面量")
    func noUnlocalizedChineseLiterals() throws {
        let offenders = try Self.scan().unlocalized
        let detail = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty,
                "这些中文字面量还没包 L10n.t（要么包上，要么用 L10N-EXEMPT 标注理由）：\n\(detail)")
    }

    /// 源码用到的 key 必须逐条在 catalog 里 —— 漏一条就是"英文环境下出现一句中文"。
    @Test("源码用到的每个 key 都在 catalog 里")
    func catalogCoversEveryKey() throws {
        let catalog = try Self.loadCatalog()
        let catalogKeys = Set(catalog.keys.keys.map(Self.normalized))
        let missing = try Self.scan().keys.filter { !catalogKeys.contains($0) }
        let detail = missing.joined(separator: "\n")
        #expect(missing.isEmpty, "catalog 里缺这些 key：\n\(detail)")
    }

    /// 反向：catalog 里不许有源码里找不到的 key。
    /// 少了这条，改了文案之后旧条目会一直留着 —— 而它们**看起来像是有翻译的**。
    @Test("catalog 里没有源码找不到的孤儿 key")
    func catalogHasNoOrphanKeys() throws {
        let catalog = try Self.loadCatalog()
        let used = Set(try Self.scan().keys)
        let orphans = catalog.keys.keys.map(Self.normalized).filter { !used.contains($0) }.sorted()
        let detail = orphans.joined(separator: "\n")
        #expect(orphans.isEmpty, "这些 catalog 条目已经没人用了：\n\(detail)")
    }

    /// 每条都必须有非空英文。中文可以靠"回落到 key"兜住，**英文不行** ——
    /// 缺英文的表现就是英文用户看到中文，正是这一票要消灭的东西。
    @Test("catalog 每条都有非空英文")
    func everyEntryHasEnglish() throws {
        let catalog = try Self.loadCatalog()
        let empty = catalog.keys.filter { ($0.value ?? "").isEmpty }.keys.sorted()
        #expect(empty.isEmpty, "这些 key 缺英文：\n\(empty.joined(separator: "\n"))")
    }

    /// 豁免区必须**成对**且**写了理由**。
    /// 不写理由的豁免就等于把问题藏起来 —— 而藏起来的东西没人会再回头看。
    @Test("豁免区必须成对且带理由")
    func exemptionsAreWellFormed() throws {
        var problems: [String] = []
        for file in Self.sourceFiles {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n",
                                                                             omittingEmptySubsequences: false)
            var open = 0
            for (index, line) in lines.enumerated() {
                guard let range = line.range(of: "L10N-EXEMPT") else { continue }
                let rest = line[range.upperBound...]
                if rest.hasPrefix("-START") {
                    open += 1
                    let reason = rest.dropFirst("-START".count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                    if reason.isEmpty {
                        problems.append("\(file.lastPathComponent):\(index + 1) 起了一段豁免但没写理由")
                    }
                } else if rest.hasPrefix("-END") {
                    open -= 1
                    if open < 0 { problems.append("\(file.lastPathComponent):\(index + 1) 有 END 没有 START") }
                }
            }
            if open != 0 { problems.append("\(file.lastPathComponent) 有 \(open) 段豁免没闭合") }
        }
        let detail = problems.joined(separator: "\n")
        #expect(problems.isEmpty, "豁免标记写坏了：\n\(detail)")
    }

    /// 扫描器自己的自检：**装置先证明能用，结论才算数**。
    ///
    /// 这几条不钉业务，钉的是"扫描器认得出它该认的东西" ——
    /// 一个什么都扫不到的扫描器会让上面四条**全绿**。
    @Test("扫描器自检：认得出中文字面量、`\\(…)` 插值、注释与豁免")
    func scannerSelfCheck() {
        let sample = #"""
        let a = "中文"
        let b = L10n.t("已包 \(x)")
        // "注释里的中文"
        let c = "原文"   // L10N-EXEMPT: 理由
        /* "块注释里的中文" */
        """#
        let found = Self.literals(in: Self.blankingExemptions(sample))
        let plain = found.filter { !$0.isEntry }.map(\.content)
        #expect(plain == ["中文"] || plain == ["中文", "块注释里的中文"],
                "应该只扫到未本地化的那条，实际：\(plain)")
        #expect(found.contains { $0.isEntry && $0.content.contains("\u{FFFC}") },
                "插值没被记成占位符，`\\(…)` 的归一化会失效")
        #expect(Self.normalized(#"已包 \(x)"#) == Self.normalized(#"已包 \(另一个名字)"#),
                "两条插值不同的串归一后应当相同")
        #expect(Self.normalized(#"\(1) 秒"#) == Self.normalized("%lld 秒"),
                "源码的 `\\(…)` 要与 catalog 的 `%lld` 归一成同一个形状")
    }
}

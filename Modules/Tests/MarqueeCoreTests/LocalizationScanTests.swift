import AppKit
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

    // MARK: - 提示行必须单行放得下

    /// 提示行那套文案。**加一条提示行文案时也要加到这里** ——
    /// 这份清单本身就是"哪些字符串要受 501 点约束"的声明。
    ///
    /// 注意这里写的是 **key（中文原句）**：英文从 catalog 里取，
    /// 于是"中文放得下、英文放不下"这种错也会被同一条断言抓住。
    static let hintLineKeys = [
        // 长截图（稿子 §10 那六个面孔）
        "继续往下滚，或按空格自动滚 · ⏎ 结束 · ⌘S 结束并保存 · Esc 取消",
        "自动滚动中 · 空格停止 · Esc 停止（已拼的保留） · ⏎ 结束",
        "看起来已经滚到底了 · 还可以继续滚，或按 ⏎ 结束",
        "看起来已经滚到底了，按 ⏎ 结束",
        "这一帧没对齐：%@",
        "没检测到滚动…继续往下滚",
        "这个版本不提供自动滚动：沙盒不允许代替你操作别的应用。",
        "自动滚动需要「辅助功能」授权（系统设置 → 隐私与安全性 → 辅助功能）。",
        // 落点后的例外提示（打码预览 / 选中 / 画标注 / 输入文字）
        "⚠️ 打码预览不可用（没拿到屏幕像素）—— 标记仍然会写进成品图",
        "已选中 %lld 个标注  ·  拖动移动  ·  Delete 删除  ·  Esc 取消选择",
        "点一个标注选中它  ·  拖角改大小  ·  选个工具可直接标注",
        "在选区内拖动即可标注  ·  再点一次工具图标取消  ·  Esc 取消工具",
        "输入文字 · ⏎ 确认 · Esc 放弃",
    ]

    /// 把格式符换成**最坏情况**的实数。
    ///
    /// 拿 `%lld` 原样去量会低估 —— 而"低估"正是这条约束最容易悄悄失效的方式：
    /// 真跑起来时那个数可能是 `9999`，而行宽是按 `%lld` 五个字符算的。
    static func materialized(_ key: String) -> String {
        key.replacingOccurrences(of: "%lld", with: "9999")
            .replacingOccurrences(of: "%@", with: "xxxxxxxx")
    }

    static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    static func textWidth(_ s: String) -> CGFloat {
        // 与视图里同一条路径：11pt、500 字重（`OverlayToolbar.hintLineFontSize`）
        textWidth(s, font: NSFont.systemFont(ofSize: OverlayToolbar.hintLineFontSize,
                                             weight: .medium))
    }

    /// 稿子 §10 给了这条约束的物理前提：
    /// 「六种文字全部 ≤ 34 字（11 pt → 约 374 pt），单行放得下 513 宽的提示行 ——
    ///  这是『不许换行、不许加高』的物理前提」。
    ///
    /// ⚠️ **那个「34 字」是按中文量的**，而英文同样占这条行宽。
    /// 这条断言第一次跑就抓出一条真超宽的英文（556 pt，比可用的 533 多 23 pt），
    /// 而它**只会在英文系统上被截断尾巴** —— 中文开发机上永远看不见。
    /// 「够不够长」这件事不能靠字数估，只能用真字体量。
    ///
    /// ⚠️ 宽度用的是**我们自己工具条的实际宽度**（545 − 2×6 = 533），不是稿子那个 513：
    /// 513 是按「内边距 5 / 组内间隙 2 / 分隔线两侧各 8」算的，而我们实现里是 6 / 4 / 9 ——
    /// 两者都放得进 1024，但提示行的预算必须跟着**我们这一条**走，
    /// 否则约束会变成"按别人的尺寸检查自己"。
    @Test("提示行文案：中英文都必须单行放得下面板宽度")
    func hintLineTextsFitOnOneLine() throws {
        let catalog = try Self.loadCatalog()
        // 可用宽度 = 面板宽 − 两侧内边距。面板与工具条**同宽**（稿子定的）。
        let available = OverlayToolbar.toolbarSize.width - OverlayToolbar.padding * 2
        #expect(available > 400, "可用宽度算出来只有 \(available)，先看面板宽是不是被改小了")

        var overflows: [String] = []
        for key in Self.hintLineKeys {
            let zh = Self.materialized(key)
            // ⚠️ 查表用**原样**的 key，不用 `normalized` ——
            // `loadCatalog` 的字典是按 catalog 里的**原文**键的（`%lld` 还没被折成 `{X}`）。
            // 拿归一化之后的形状去查会一条都查不到，而表现是"13 条全缺英文"。
            let rawEnglish = catalog.keys[key] ?? nil
            let en = Self.materialized(rawEnglish ?? "")
            #expect(!(rawEnglish ?? "").isEmpty,
                    "「\(key)」在 catalog 里没有英文 —— 英文用户会看到一句中文")
            for (tag, text) in [("中", zh), ("英", en)] {
                let width = Self.textWidth(text)
                if width > available {
                    overflows.append(String(format: "%@ %.0fpt（上限 %.0f）%@", tag, width, available, text))
                }
            }
        }
        #expect(overflows.isEmpty,
                Comment(rawValue: "这些提示行文案放不下，会被截断尾巴：\n"
                        + overflows.joined(separator: "\n")))
    }

    // MARK: - 最近截图面板：每一行字都要放得进它自己那块宽度

    /// 面板上要受宽度约束的文案（key = 中文原句）。
    ///
    /// ⚠️ 加一条面板文案就要加到这里 —— 这份清单就是"哪些字要受 340 点约束"的声明。
    static let recentPanelKeys = [
        // 标题带（左标题 + 右小字，两者共用一条 320 点的带子）
        "点缩略图 = 复制",
        // 空态
        "还没有截图",
        "按 %@ 截第一张",
        // 行里那两行（共用 174 点，见下面第二条断言的算式）
        "%@ px",
        "%@ · %lld 个标注",
        // 行里那两个动作（它们占的是行宽里固定的两块）
        "编辑",
        "删除",
        // 底部那三段 + 中间那枚可点的词
        "免费版只保留最近 %lld 张",
        "升级到 Pro",
        "可保留全部",
    ]

    /// 底部那一行是**三段 + 一枚按钮**拼出来的，而它自己只有 320 点。
    ///
    /// ⚠️ 这条约束**只有英文会撞上**：中文三段加起来 254 点，
    /// 而最初那版英文（"The free version keeps the last …"）实测 **370 点** ——
    /// 溢出 49 点，会把最后那段整个挤掉。
    /// 稿子那张图上量的是中文，所以这个错在中文环境下**永远不会被发现**。
    @Test("最近截图面板：底部那一句（三段 + 按钮）放得进面板宽，中英一起量")
    func recentPanelFooterFits() throws {
        let catalog = try Self.loadCatalog()
        let available = RecentPanel.width - RecentPanel.footerPadding * 2
        let bodyFont = NSFont.systemFont(ofSize: 11)
        // 中间那枚按钮的字是 500 字重（`ChromeTextButton`），比正文宽一点，不能拿正文字体量。
        let actionFont = NSFont.systemFont(ofSize: 11, weight: .medium)

        // 配额数字取**最坏情况**：两位（当前上限最多到 20）。
        let materialize: (String) -> String = { $0.replacingOccurrences(of: "%lld", with: "20") }

        var overflows: [String] = []
        for (tag, catalogKey, english) in [("中", "免费版只保留最近 %lld 张",
                                            "免费版只保留最近 %lld 张"),
                                           ("英", "免费版只保留最近 %lld 张",
                                            (catalog.keys["免费版只保留最近 %lld 张"] ?? nil) ?? "")] {
            #expect(!english.isEmpty, "底部那句在 catalog 里没有英文")
            let actionKey = "升级到 Pro"
            let actionEnglish = (catalog.keys[actionKey] ?? nil) ?? ""
            let suffixKey = "可保留全部"
            let suffixEnglish = (catalog.keys[suffixKey] ?? nil) ?? ""

            let prefix = materialize(tag == "中" ? catalogKey : english)
            let action = tag == "中" ? actionKey : actionEnglish
            let suffix = tag == "中" ? suffixKey : suffixEnglish
            let total = Self.textWidth(prefix, font: bodyFont)
                + Self.textWidth(RecentPanel.footerSeparator, font: bodyFont)
                + RecentPanel.actionWidth(textWidth: Self.textWidth(action, font: actionFont))
                + Self.textWidth(suffix, font: bodyFont)
                + RecentPanel.footerGap * 3
            if total > available {
                overflows.append(String(format: "%@ %.0fpt（上限 %.0f）%@ · %@ %@",
                                        tag, total, available, prefix, action, suffix))
            }
        }
        #expect(overflows.isEmpty,
                Comment(rawValue: "底部那一句放不下 —— 最后那段会被挤掉：\n"
                        + overflows.joined(separator: "\n")))
    }

    /// 行里那两行字（时间 12pt / 尺寸 mono 11pt）共用**同一块宽度**：
    /// 列表宽 − 行内缩 ×2 − 缩略图 − 两处间隙 − 两个动作。
    ///
    /// 这一块靠算而不是靠看：四个加数里任何一个变了（缩略图宽一点、动作字长一点），
    /// 留给人读的那块就窄一点 —— 而它的表现只是"尺寸那行被截断了个尾巴"。
    @Test("最近截图面板：行里那两行字放得进行里文字那一块，中英一起量")
    func recentPanelRowTextFits() throws {
        let catalog = try Self.loadCatalog()
        let actionFont = NSFont.systemFont(ofSize: 11, weight: .medium)

        // 两个动作的实际占宽：本地化之后**取宽的那个**（编辑 22 / Edit 20 → 22）。
        let actionWidths = ["编辑", "删除"].map { key -> CGFloat in
            let zh = Self.textWidth(key, font: actionFont)
            let en = Self.textWidth((catalog.keys[key] ?? nil) ?? "", font: actionFont)
            return RecentPanel.actionWidth(textWidth: max(zh, en))
        }
        let actionsTotal = actionWidths.reduce(0, +)
            + CGFloat(actionWidths.count - 1) * RecentPanel.actionGap
        let available = RecentPanel.listWidth
            - RecentPanel.rowPadding * 2
            - RecentPanel.thumbnailSize.width
            - RecentPanel.rowGap * 2
            - actionsTotal
        #expect(available > 120, "行里留给文字的只有 \(available) 点，先看缩略图或动作是不是变大了")

        // 最坏情况：5K 屏 + 两位数标注。
        let size = CGSize(width: 5120, height: 2880)
        let detailKey = "%@ · %lld 个标注"
        let detailEnglish = (catalog.keys[detailKey] ?? nil)
            ?? ""
        let date = Date(timeIntervalSince1970: 1_791_024_420)
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let timeFont = NSFont.systemFont(ofSize: 12)

        var overflows: [String] = []
        // 第一行：时间（它不是 catalog 里的文案，是按语言排出来的，所以直接用真函数要两种）
        for (tag, locale) in [("中", "zh_CN"), ("英", "en_US")] {
            let text = RecentPanel.rowDate(date, locale: Locale(identifier: locale), timeZone: zone)
            let width = Self.textWidth(text, font: timeFont)
            if width > available {
                overflows.append(String(format: "%@ 时间 %.0fpt（上限 %.0f）%@", tag, width, available, text))
            }
        }
        // 第二行：尺寸 + 标注数
        for (tag, materialized) in [("中", RecentPanel.rowDetail(pixelSize: size, annotationCount: 12)),
                                    ("英", detailEnglish
                                        .replacingOccurrences(of: "%@", with: "5120×2880 px")
                                        .replacingOccurrences(of: "%lld", with: "12"))] {
            let width = Self.textWidth(materialized, font: mono)
            if width > available {
                overflows.append(String(format: "%@ 尺寸 %.0fpt（上限 %.0f）%@", tag, width, available, materialized))
            }
        }
        #expect(overflows.isEmpty,
                Comment(rawValue: "行里这些字放不下，会被截断尾巴：\n"
                        + overflows.joined(separator: "\n")))
    }

    /// 反向：清单里不许有**源码里已经不用**的 key。
    ///
    /// 少了这条，改了文案之后旧句子会一直留在这份清单里 ——
    /// 而它**看起来像是在被检查**，其实只是在检查一句没人用的话。
    @Test("提示行清单里没有源码找不到的孤儿")
    func hintLineKeysHaveNoOrphans() throws {
        let used = Set(try Self.scan().keys)
        // 两份清单一起查：它们都是"这些字受某个宽度约束"的声明，
        // 而一条不再被源码使用的声明**看起来仍在被检查**，其实只是在检查一句没人用的话。
        let declared = Self.hintLineKeys + Self.recentPanelKeys
            + Self.proCardTitleKeys + Self.proCardBodyKeys
            + Self.proCardButtonKeys + [Self.proCardMicroKey]
        let orphans = declared.filter { !used.contains(Self.normalized($0)) }
        #expect(orphans.isEmpty,
                Comment(rawValue: "这些提示行文案已经没人用了：\n"
                        + orphans.joined(separator: "\n")))
    }

    // MARK: - 升级卡片：每一句都要放得进 300 宽的卡

    /// 卡片上要受宽度约束的文案（key = 中文原句）。
    ///
    /// ⚠️ 加一条卡片文案就要加到这里 —— 这份清单就是"哪些字要受这张卡的宽度约束"的声明。
    static let proCardTitleKeys = [
        "滚动截屏是 Pro 能力", "识别文字是 Pro 能力", "钉图是 Pro 能力", "最近截图是 Pro 能力",
    ]
    static let proCardBodyKeys = [
        "试用 7 天，结束后自动回到免费版",
        "试用已结束，免费版仍可截图与标注",
        "购买已撤销，可点恢复购买重新获取",
        "这个账号下找不到这笔购买",
    ]
    static let proCardButtonKeys = ["7 天免费试用", "了解 Pro", "恢复购买"]
    static let proCardMicroKey = "关闭卡片，选区保留"

    /// 三种文案结构里 (主, 次) 的组合 —— 卡片的核心判据（`ProCard.content`）只吐这三种。
    static let proCardButtonPairs: [(primary: String, secondary: String)] = [
        ("7 天免费试用", "了解 Pro"),     // 从未购买 · 可试用
        ("了解 Pro", "恢复购买"),         // 试用已结束
        ("恢复购买", "了解 Pro"),         // 购买被撤销
    ]

    /// 卡片只有 300 宽、内宽 268 —— **一行**的正文、**一排**的按钮都要放得进。
    ///
    /// ⚠️ 稿子上量的是中文（≤ 22 字），而英文同样占这条宽度。
    /// 这一条是同一类错的**第三次**：提示行（556 pt）、最近截图底部那一句（370 pt），
    /// 现在是卡片的按钮组（"Start a 7-day free trial" + "Learn about Pro" = **272 > 268**）
    /// 与正文（"Trial ended. The free version still captures and annotates" = **321**）。
    /// 三处都只在英文系统上被裁掉尾巴，中文开发机上永远看不见。
    @Test("升级卡片：标题 / 正文 / 按钮组 / 微行，中英文都要放得进它自己那块宽度")
    func proCardTextsFit() throws {
        let catalog = try Self.loadCatalog()

        func english(_ key: String) -> String? { catalog.keys[Self.normalized(key)] ?? nil }
        func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
            Self.textWidth(text, font: .systemFont(ofSize: size, weight: weight))
        }

        var overflows: [String] = []

        // ① + ② 标题：从图标右边 8 点起，到右内边距止
        let titleAvailable = ProCardLayout.width - ProCardLayout.padding
            - (ProCardLayout.glyphSize + ProCardLayout.glyphTitleGap)
        for key in Self.proCardTitleKeys {
            let en = english(key)
            #expect(en != nil, "「\(key)」在 catalog 里没有英文 —— 英文用户会看到一句中文")
            for (tag, text) in [("中", key), ("英", en ?? "")] where !text.isEmpty {
                let w = width(text, size: ProCardLayout.titleFontSize, weight: .semibold)
                if w > titleAvailable {
                    overflows.append(String(format: "%@ 标题 %.0fpt（上限 %.0f）%@",
                                            tag, w, titleAvailable, text))
                }
            }
        }

        // ③ 正文：**一行**。超出就是被裁尾巴（它没有换行的余地）
        for key in Self.proCardBodyKeys {
            let en = english(key)
            #expect(en != nil, "「\(key)」在 catalog 里没有英文")
            for (tag, text) in [("中", key), ("英", en ?? "")] where !text.isEmpty {
                let w = width(text, size: ProCardLayout.bodyFontSize, weight: .regular)
                if w > ProCardLayout.bodyLineWidth {
                    overflows.append(String(format: "%@ 正文 %.0fpt（上限 %.0f）%@",
                                            tag, w, ProCardLayout.bodyLineWidth, text))
                }
            }
        }

        // ④ 按钮组：主 + 间距 + 次，右对齐 —— 总量必须放得进内宽
        for pair in Self.proCardButtonPairs {
            for tag in ["中", "英"] {
                let primary = tag == "中" ? pair.primary : (english(pair.primary) ?? "")
                let secondary = tag == "中" ? pair.secondary : (english(pair.secondary) ?? "")
                let total = width(primary, size: ProCardLayout.buttonFontSize, weight: .semibold)
                    + ProCardLayout.primaryButtonPadding * 2
                    + ProCardLayout.buttonGap
                    + width(secondary, size: ProCardLayout.buttonFontSize, weight: .medium)
                    + ProCardLayout.textButtonPadding * 2
                if total > ProCardLayout.buttonRowWidth {
                    overflows.append(String(format: "%@ 按钮组 %.0fpt（上限 %.0f）[%@ / %@]",
                                            tag, total, ProCardLayout.buttonRowWidth,
                                            primary, secondary))
                }
            }
        }

        // ⑤ 微行：键帽 + 5 + 那句话
        let capWidth = max(ProCardLayout.escKeyCapMinWidth,
                           width("esc", size: ProCardLayout.escKeyCapFontSize, weight: .medium)
                           + ProCardLayout.escKeyCapPadding * 2)
        let microKey = Self.proCardMicroKey
        for (tag, text) in [("中", microKey), ("英", english(microKey) ?? "")] where !text.isEmpty {
            let total = capWidth + ProCardLayout.microGap
                + width(text, size: ProCardLayout.microFontSize, weight: .regular)
            if total > ProCardLayout.bodyLineWidth {
                overflows.append(String(format: "%@ 微行 %.0fpt（上限 %.0f）%@",
                                        tag, total, ProCardLayout.bodyLineWidth, text))
            }
        }

        #expect(overflows.isEmpty,
                Comment(rawValue: "卡片上这些字放不下，会被裁掉尾巴：\n"
                        + overflows.joined(separator: "\n")))
    }
}

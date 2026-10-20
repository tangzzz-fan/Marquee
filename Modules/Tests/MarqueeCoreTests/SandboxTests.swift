import Foundation
import Testing

@testable import MarqueeCore

/// 沙盒带来的那几处行为差异（ticket 32），以及 2026-10-14 那次提审
/// （Guideline 2.4.5(i)：预置保存位置 + 与之配套的 Pictures entitlement）之后的判据。
@Suite("沙盒判据与保存位置（ticket 32）")
struct SandboxTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    // MARK: - 沙盒判据

    @Test("容器 id 在环境里 = 在沙盒里")
    func detectsSandbox() {
        #expect(AppIdentity.detectSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "com.tango.marquee"]))
    }

    @Test("没有那个变量 = 不在沙盒里")
    func detectsNoSandbox() {
        #expect(!AppIdentity.detectSandboxed(environment: [:]))
        #expect(!AppIdentity.detectSandboxed(environment: ["HOME": "/Users/someone"]))
    }

    @Test("变量在但是空串 —— **不算**沙盒")
    func emptyContainerIDIsNotSandbox() {
        // 空串说明那个变量是坏的（或被谁清过），据此认定"在沙盒里"会让 app
        // 白白关掉自动滚动、还可能去改默认落盘 —— 拿一个坏值当证据，
        // 代价全是用户的。判成"不在沙盒"则一切照旧。
        #expect(!AppIdentity.detectSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": ""]))
    }

    @Test("注入优先于探测 —— 否则这条判据在测试里根本没法验")
    func injectionWins() {
        #expect(AppIdentity(bundleIdentifier: "com.tango.marquee", isSandboxed: true).isSandboxed)
        #expect(!AppIdentity(bundleIdentifier: "com.tango.marquee", isSandboxed: false).isSandboxed)
    }

    // MARK: - 保存位置：**没有默认值**（2026-10-14 被 2.4.5(i) 打回后改）

    @Test("全新安装没有保存目录 —— 不预置任何位置")
    func freshInstallHasNoSaveDirectory() {
        // ⚠️ 这条是本次改动的核心。原先 `settings().directory` 兜的是
        // `~/Pictures/Marquee`，并为此声明了 `assets.pictures.read-write` ——
        // Apple 按 2.4.5(i) 打回：预置位置 + entitlement 与功能不匹配。
        // 现在位置只能由用户在面板里选；"没选过"必须是**看得见**的状态。
        let store = UserDefaultsOutputStore(defaults: freshDefaults())

        #expect(store.chosenDirectory() == nil)
        #expect(store.settings().directory == nil, "兜一个默认路径就等于替用户预置位置，审核会再打回")
    }

    @Test("面板起点是给人浏览的：真家目录里、不在容器里、不在桌面")
    func panelStartDirectoryIsBrowsable() {
        let start = OutputSettings.savePanelStartDirectory()

        #expect(start.path.hasPrefix("/"), "必须是绝对路径")
        // 沙盒下 `NSHomeDirectory()` 是 `~/Library/Containers/<id>/Data`，
        // 从那儿打开面板等于把用户送到一个他永远找不到的地方（PITFALLS 101 同一类错）。
        #expect(!start.path.contains("/Library/Containers/"))
        #expect(start.path.hasPrefix(AppIdentity.realHomeDirectory().path))
        // 起点只是一个落脚处，不能是"写死的落盘位置"（那个已经被打回过一次）。
        #expect(!start.path.contains("Desktop"))
    }

    @Test("界面上「保存位置」那一格：没选过就直说，**不许**显示某个路径")
    func directorySummaryNeverInventsAPath() {
        // 偏好页与引导页共用 `directorySummary`。它若兜一个路径（哪怕只是"面板起点"），
        // 预置位置就只是从落盘层挪到了显示层 —— 而审核看的是**用户看到什么**。
        let store = UserDefaultsOutputStore(defaults: freshDefaults())
        let summary = store.settings().directorySummary

        #expect(!summary.isEmpty, "没选过是**一个状态**，不是一片空白")
        #expect(!summary.contains("/"), "这一格显示出了一个路径：\(summary)")
    }

    @Test("记住的是用户选的那一个目录，路径能原样读回来")
    func chosenDirectoryRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-chosen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UserDefaultsOutputStore(defaults: freshDefaults())
        store.saveDirectory(directory, bookmark: OutputSettings.securityScopedBookmark(for: directory))

        #expect(store.chosenDirectory()?.path == directory.path)
        #expect(store.settings().directory?.path == directory.path)
        // 选过之后这一格就是那个路径 —— 原文直出，不再加"已选择"之类的前缀
        #expect(store.settings().directorySummary == directory.path)
    }

    @Test("书签能解析回同一个目录 —— 沙盒跨启动就靠这一条")
    func bookmarkResolvesBackToTheSameDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        guard let data = OutputSettings.securityScopedBookmark(for: directory) else {
            // 非沙盒进程里建书签可能直接失败 —— 那正是"退回路径"那一支存在的理由
            // （见 `chosenDirectory()`），不是这条用例的失败。
            return
        }
        let resolved = try #require(OutputSettings.resolveDirectoryBookmark(data))
        #expect(resolved.url.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
    }

    @Test("书签坏了 = 当作没选过，**不拿路径硬写**")
    func brokenBookmarkMeansUnchosen() {
        // 这条钉的是顺序：有书签就只认书签。反过来（书签失败 → 退回路径）在沙盒里
        // 会写失败成 `Operation not permitted`，而用户看不出为什么 ——
        // 更糟的是非沙盒下它会**安静地**写进一个早就不该用的目录。
        let defaults = freshDefaults()
        defaults.set(Data("这不是书签".utf8), forKey: UserDefaultsOutputStore.bookmarkKey)
        defaults.set("/tmp/marquee-old-place", forKey: UserDefaultsOutputStore.directoryKey)
        let store = UserDefaultsOutputStore(defaults: defaults)

        #expect(store.chosenDirectory() == nil, "解析不出来就该重新问用户")
    }

    @Test("没有书签时才退回路径 —— 服务非沙盒构建与升级上来的安装")
    func missingBookmarkFallsBackToPath() {
        let defaults = freshDefaults()
        defaults.set("/tmp/marquee-legacy", forKey: UserDefaultsOutputStore.directoryKey)
        let store = UserDefaultsOutputStore(defaults: defaults)

        #expect(store.chosenDirectory()?.path == "/tmp/marquee-legacy")
    }
}

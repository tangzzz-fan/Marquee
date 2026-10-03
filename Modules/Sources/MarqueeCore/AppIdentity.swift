import Foundation

/// App 的身份（ticket 31 的第 0 步，设计见 `docs/DEV-VS-PROD.md`）。
///
/// ## 为什么需要它
///
/// 项目原来只有**一个** bundle id（`dev.tango.Marquee`）—— 本地构建出来的 app
/// 与将来上架的 app 是**同一个身份**：同一份偏好、同一条屏幕录制授权、同一个数据目录。
/// 于是"调试时敲的开关留在正式版里""调试删除逻辑删掉真实历史"这类事迟早会发生。
///
/// 现在分成两个：正式 `com.tango.marquee`、开发 `com.tango.marquee.dev`。
///
/// ## 关键设计：「是不是开发版」**由 bundle id 推导**
///
/// 不用编译期开关（`#if DEBUG` / `MARQUEE_DEV`）。三条理由：
///
/// 1. **只有一个来源** —— 身份就是 bundle id，不需要第二处再声明"我是谁"；
/// 2. **隔离是自动的** —— 偏好按 bundle id 分域是系统行为，一行都不用写；
/// 3. **将来加变体免费** —— 再加 beta / staging 时，数据目录与偏好自动跟着分。
///
/// ## 为什么做成可注入的
///
/// `Bundle.main` 在单测里**不是这个 app**（SwiftPM 跑测试时 `main` 是测试进程），
/// 所以"默认值"这件事没法在测试里断言。把 bundle id 做成入参之后，
/// 后缀识别与目录拼接就都能脱机测 —— 与 `LicenseResolver` 同一条思路。
public struct AppIdentity: Equatable, Sendable {

    /// 正式版的 bundle id。**全项目只有这里写死它。**
    public static let productionBundleIdentifier = "com.tango.marquee"

    /// 开发版的后缀。
    ///
    /// 用**后缀**而不是另一套前缀，是为了让两者一眼看出是同一个 app 的变体。
    /// 项目原先的前缀恰好是 `dev.`（`dev.tango.Marquee`）—— 那既冒充了"开发"，
    /// 又正好挡住"开发版后缀"这个位置，两个含义叠在一起根本分不清。
    public static let developmentSuffix = ".dev"

    public let bundleIdentifier: String

    /// 当前进程是不是跑在 App Sandbox 里。
    ///
    /// **为什么要有它**：沙盒不是"多了一个限制"，而是**改了几处行为** ——
    /// 自动滚动做不到、默认落盘写不进桌面、数据进容器。
    /// 这些差异必须**按运行期判据分派**，不能按构建配置用编译期开关分：
    /// 那样同一份代码在两个构建里行为不同，而**没编进去的那条分支
    /// 只有发版那天才跑得到**（届时才发现，正是最不适合发现的时刻）。
    public let isSandboxed: Bool

    public init(bundleIdentifier: String? = nil, isSandboxed: Bool? = nil) {
        self.bundleIdentifier = bundleIdentifier
            ?? Bundle.main.bundleIdentifier
            ?? Self.productionBundleIdentifier
        self.isSandboxed = isSandboxed ?? Self.detectSandboxed()
    }

    /// 沙盒判据：`APP_SANDBOX_CONTAINER_ID`（沙盒在 exec 时一定会注入它）。
    ///
    /// 做成入参是为了**能脱机单测** —— 真跑在沙盒里没法测"不在沙盒里"那一支。
    public static func detectSandboxed(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let containerID = environment["APP_SANDBOX_CONTAINER_ID"] else { return false }
        return !containerID.isEmpty
    }

    /// **真实**的家目录，不是沙盒容器里的那一个。
    ///
    /// ## 为什么不能直接用 `NSHomeDirectory()`
    ///
    /// 沙盒进程的 `NSHomeDirectory()` 是 `~/Library/Containers/<id>/Data`，
    /// 于是 `FileManager.urls(for: .picturesDirectory, in: .userDomainMask)`
    /// 也跟着指向**容器里的** Pictures。那会把图安静地存到用户永远找不到的地方 ——
    /// "我明明按了保存，怎么没看见"，而屏幕上没有任何提示。
    /// 这正是本项目最忌讳的那类缺陷（不崩、不报错、只悄悄错）。
    ///
    /// `getpwuid` 读的是 passwd 条目，沙盒**不会**改它，拿到的始终是 `/Users/<你>`；
    /// 配上 `com.apple.security.assets.pictures.read-write` 就能真写进用户的 Pictures。
    ///
    /// 非沙盒构建下两者本来就相等 ⇒ 一条代码路径同时服务两种构建。
    public static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// 当前跑的是不是开发版。
    public var isDevelopmentBuild: Bool {
        bundleIdentifier.hasSuffix(Self.developmentSuffix)
    }

    /// 界面上用来标识"这是开发版"的后缀；正式版是**空串**。
    ///
    /// 放 Core 而不是让两个界面各拼一遍：菜单栏提示与设置窗口标题要拼出**同一个**
    /// 字符串，两处各写一遍迟早分叉（`SettingsPage.title` 也是同样的理由放在 Core）。
    public var developmentTitleSuffix: String {
        isDevelopmentBuild ? " · " + L10n.t("开发版") : ""
    }

    /// 日志用的 subsystem。
    ///
    /// **刻意固定用正式 id，而不是当前 bundle id**：日志是给人 grep 的，
    /// `log show --predicate 'subsystem == "com.tango.marquee"'` 在开发版与正式版上
    /// 都应当命中 —— 否则排障时还要先问"我该 grep 哪个 subsystem"。
    /// （只想看开发版就按进程过滤。）
    public var logSubsystem: String { Self.productionBundleIdentifier }

    // MARK: - 数据落点

    /// 数据根目录：`~/Library/Application Support/<bundle id>/`
    ///
    /// **拿 bundle id 当目录名**（而不是写死一个 `Marquee`）：于是开发版、
    /// 以及将来任何新变体，**自动**各有各的数据，不用写一行 dev 专用代码。
    public func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// 最近截图仓库：`<数据根>/history/`
    public func historyDirectory(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager)
            .appendingPathComponent("history", isDirectory: true)
    }

    /// 一次性探针的报告目录：`<数据根>/reports/`。
    ///
    /// ⚠️ **刻意不放在 `~/Library/Logs/Marquee/`**（2026-10-03 改）。
    /// 原因：沙盒下 `~/Library/Logs` 在容器**外**，写不进去 —— 而探针里写文件
    /// 用的是 `try?`，失败会被**静静吞掉**。表现出来是"探针跑了但什么都没留下"，
    /// 与"这个入口没触发"长得一模一样。这正是本项目最忌讳的那类错。
    ///
    /// 而 `supportDirectory()` 走 `.applicationSupportDirectory` —— 沙盒下它天然
    /// 落在**容器内**，非沙盒下落在 `~/Library/Application Support/`，
    /// 于是**两种构建同一条代码路径**都写得进去，不需要"沙盒走这边、否则走那边"。
    ///
    /// 单独立这一处，是因为它原本被三个探针各拼了一遍。三份同样的路径拼法，
    /// 改一处忘两处就是"有的探针读得到、有的读不到"。
    public func logDirectory(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager)
            .appendingPathComponent("reports", isDirectory: true)
    }
}

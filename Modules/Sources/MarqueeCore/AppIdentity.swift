import Foundation

/// App 的身份（ticket 31 的第 0 步，设计见 `docs/DEV-VS-PROD.md`）。
///
/// ## 为什么需要它
///
/// 项目原来只有**一个** bundle id（`dev.tango.Marquee`）—— 本地构建出来的 app
/// 与将来上架的 app 是**同一个身份**：同一份偏好、同一条屏幕录制授权、同一个数据目录。
/// 于是"调试时敲的开关留在正式版里""调试删除逻辑删掉真实历史"这类事迟早会发生。
///
/// 现在分成两个：正式 `com.tango.Marquee`、开发 `com.tango.Marquee.dev`。
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
    public static let productionBundleIdentifier = "com.tango.Marquee"

    /// 开发版的后缀。
    ///
    /// 用**后缀**而不是另一套前缀，是为了让两者一眼看出是同一个 app 的变体。
    /// 项目原先的前缀恰好是 `dev.`（`dev.tango.Marquee`）—— 那既冒充了"开发"，
    /// 又正好挡住"开发版后缀"这个位置，两个含义叠在一起根本分不清。
    public static let developmentSuffix = ".dev"

    public let bundleIdentifier: String

    public init(bundleIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
            ?? Bundle.main.bundleIdentifier
            ?? Self.productionBundleIdentifier
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
    /// `log show --predicate 'subsystem == "com.tango.Marquee"'` 在开发版与正式版上
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
}

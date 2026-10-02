import Foundation
import Testing

@testable import MarqueeCore

/// App 身份（ticket 31 的第 0 步）。
///
/// 全部传 bundle id 进去测，不依赖 `Bundle.main` ——
/// 跑单测时 `main` 是测试进程，拿它当断言对象等于什么都没测。
@Suite("App 身份（ticket 31 第 0 步）")
struct AppIdentityTests {

    private let prod = AppIdentity(bundleIdentifier: "com.tango.Marquee")
    private let dev = AppIdentity(bundleIdentifier: "com.tango.Marquee.dev")

    @Test("开发版靠**后缀**识别，前缀冒充不算")
    func developmentDetection() {
        #expect(!prod.isDevelopmentBuild)
        #expect(dev.isDevelopmentBuild)

        // ⚠️ 这一组是这次改名的**原动力**：旧 id `dev.tango.Marquee` 里那个 `dev` 是
        // **前缀**（当年随手写的），与"开发版"毫无关系，却长得像。
        // 靠后缀判定之后，这种冒充就不会被误认。
        // （这个字符串**故意保留旧 id** —— 它就是那条反例；批量改名脚本会想改它，
        //   改了这条断言就等于在测同一件事两遍。）
        #expect(!AppIdentity(bundleIdentifier: "dev.tango.Marquee").isDevelopmentBuild,
                "前缀里的 dev 不该被当成开发版")
        // 近似串也不能误判
        #expect(!AppIdentity(bundleIdentifier: "com.tango.Marqueedev").isDevelopmentBuild)
        #expect(!AppIdentity(bundleIdentifier: "com.tango.Marquee.develop").isDevelopmentBuild)
    }

    @Test("正式 id 里不许再出现 `dev.` 前缀 —— 那就是这次要摆脱的东西")
    func productionIdentifierIsClean() {
        #expect(AppIdentity.productionBundleIdentifier == "com.tango.Marquee")
        #expect(!AppIdentity.productionBundleIdentifier.hasPrefix("dev."))
        // 开发版 = 正式 id + 后缀（同一个 app 的两个变体，不是两个东西）
        #expect(AppIdentity.productionBundleIdentifier + AppIdentity.developmentSuffix
                == "com.tango.Marquee.dev")
    }

    @Test("数据目录按 bundle id 分 —— 两个版本天然不打架，且不用写 dev 专用代码")
    func supportDirectoryIsPerBundleID() {
        #expect(prod.supportDirectory().lastPathComponent == "com.tango.Marquee")
        #expect(dev.supportDirectory().lastPathComponent == "com.tango.Marquee.dev")
        #expect(prod.historyDirectory().path != dev.historyDirectory().path,
                "两个版本共用历史目录，就是这次改名的起因")
        #expect(prod.historyDirectory().lastPathComponent == "history")
        #expect(prod.historyDirectory().path.contains("Application Support"))
    }

    @Test("日志 subsystem 两个版本共用一条 —— 排障时不用先问用哪个 grep")
    func logSubsystemIsStable() {
        #expect(dev.logSubsystem == prod.logSubsystem)
        #expect(dev.logSubsystem == AppIdentity.productionBundleIdentifier)
    }

    @Test("开发版才有后缀；正式版是空串（不能拼出一个多余的 ` · `）")
    func titleSuffixOnlyInDevelopment() {
        #expect(prod.developmentTitleSuffix.isEmpty)
        #expect(dev.developmentTitleSuffix.hasSuffix(L10n.t("开发版")))
        #expect(dev.developmentTitleSuffix.hasPrefix(" · "),
                "分隔符丢了会让标题变成「Marquee 设置开发版」")
    }

    @Test("拿不到 bundle id 时退回正式 id —— 不能退成空串")
    func fallsBackToProduction() {
        // 显式传 nil 走的是同一条兜底路径（`Bundle.main` 为 nil 时）
        let identity = AppIdentity(bundleIdentifier: nil)
        #expect(!identity.bundleIdentifier.isEmpty)
        #expect(identity.bundleIdentifier == Bundle.main.bundleIdentifier
                ?? AppIdentity.productionBundleIdentifier)
    }
}

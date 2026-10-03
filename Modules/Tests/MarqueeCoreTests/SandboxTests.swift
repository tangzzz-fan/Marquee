import Foundation
import Testing

@testable import MarqueeCore

/// 沙盒带来的那几处行为差异（ticket 32）。
@Suite("沙盒判据与默认落盘（ticket 32）")
struct SandboxTests {

    // MARK: - 沙盒判据

    @Test("容器 id 在环境里 = 在沙盒里")
    func detectsSandbox() {
        #expect(AppIdentity.detectSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "com.tango.Marquee"]))
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
        #expect(AppIdentity(bundleIdentifier: "com.tango.Marquee", isSandboxed: true).isSandboxed)
        #expect(!AppIdentity(bundleIdentifier: "com.tango.Marquee", isSandboxed: false).isSandboxed)
    }

    // MARK: - 默认落盘

    @Test("默认落盘是 ~/Pictures/Marquee，**不是桌面**")
    func defaultOutputIsPicturesNotDesktop() {
        let directory = OutputSettings.defaultOutputDirectory()

        #expect(directory.path.hasPrefix("/"), "必须是绝对路径")
        #expect(directory.lastPathComponent == "Marquee")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Pictures")

        // ⚠️ 这一条是本次改动的核心。Apple 的文件访问 entitlement 是**枚举式**的，
        // 「桌面」不在里面 —— 沙盒下往那儿写会直接 Operation not permitted，
        // 而用户只看到"保存不了"。改回桌面等于把这个坑重新挖开。
        #expect(!directory.path.contains("Desktop"))
    }

    @Test("默认落盘不落在容器里 —— 那是「保存成功但找不到」的来源")
    func defaultOutputIsNotInsideAContainer() {
        // 沙盒下 `NSHomeDirectory()` 是 `~/Library/Containers/<id>/Data`，
        // 而 `FileManager` 的 `.picturesDirectory` 由它推出来 —— 于是图会存到
        // 用户永远找不到的地方。所以路径必须从**真实**家目录拼（`realHomeDirectory()`）。
        let directory = OutputSettings.defaultOutputDirectory()
        #expect(!directory.path.contains("/Library/Containers/"))
        #expect(directory.path.hasPrefix(AppIdentity.realHomeDirectory().path))
    }
}

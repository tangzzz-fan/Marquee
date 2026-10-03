import Foundation
import Testing

@testable import MarqueeCore

@Suite("自动滚动的可性判据")
struct AutoScrollGateTests {

    // MARK: - 四种组合

    @Test("沙盒里一律不可用 —— 哪怕已经拿到了辅助功能授权")
    func sandboxWinsOverPermission() {
        // ⚠️ 这一条是本组的头号判据。它同时钉住两件事：
        //   ① 沙盒下不给用；② **判据顺序**是沙盒优先。
        // 顺序反了（先看授权）时，已授权的那一支会变成 .allowed ——
        // 于是 App Store 版"看起来能用"，一按空格什么都不发生，
        // 而界面上连一句解释都没有。
        #expect(AutoScrollGate.evaluate(isSandboxed: true, permissionGranted: true)
                == .unavailableInSandbox)
    }

    @Test("沙盒 + 没授权，也是「不可用」而不是「去授权」")
    func sandboxWithoutPermission() {
        #expect(AutoScrollGate.evaluate(isSandboxed: true, permissionGranted: false)
                == .unavailableInSandbox)
    }

    @Test("不在沙盒里、还没授权 → 去申请（这是唯一一条能走通的路）")
    func needsPermission() {
        #expect(AutoScrollGate.evaluate(isSandboxed: false, permissionGranted: false)
                == .needsPermission)
    }

    @Test("不在沙盒里、已授权 → 放行")
    func allowed() {
        #expect(AutoScrollGate.evaluate(isSandboxed: false, permissionGranted: true) == .allowed)
    }

    // MARK: - 文案

    @Test("放行时没有话要说")
    func allowedIsSilent() {
        #expect(AutoScrollGate.blockedMessage(for: .allowed) == nil)
    }

    @Test("沙盒那句**不许**提「辅助功能」授权")
    func sandboxMessageDoesNotMentionAccessibility() {
        // 这是本组第二条关键断言。「去系统设置勾一下辅助功能」在沙盒里
        // **做了也没用** —— 提它就是把用户送去做一件注定徒劳的事，
        // 而他会以为是权限没生效，转头去怀疑系统。
        let message = AutoScrollGate.blockedMessage(for: .unavailableInSandbox)
        #expect(message != nil)
        #expect(message?.contains("辅助功能") == false)
    }

    @Test("没授权那句**必须**指出辅助功能在哪里勾")
    func permissionMessagePointsAtSystemSettings() {
        let message = AutoScrollGate.blockedMessage(for: .needsPermission)
        #expect(message?.contains("辅助功能") == true)
        #expect(message?.contains("系统设置") == true)
    }

    @Test("两种被挡的话都要写明「手动模式照旧可用」")
    func bothBlockedMessagesKeepManualModeAlive() {
        // 不写明的话，用户会以为整条长截图链路坏了 ——
        // 而实际上手动滚动一行代码都没动过。
        for gate in [AutoScrollGate.unavailableInSandbox, .needsPermission] {
            #expect(AutoScrollGate.blockedMessage(for: gate)?.contains("手动模式") == true)
        }
    }
}

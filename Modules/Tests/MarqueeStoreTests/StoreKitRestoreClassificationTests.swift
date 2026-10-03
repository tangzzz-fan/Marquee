import Foundation
import MarqueeCore
import StoreKit
import Testing

@testable import MarqueeStore

/// `StoreKitStorefront.classifyRestoreFailure` —— 平台错误码 → 三档语义。
///
/// ## 为什么这条测试值钱
///
/// 2026-10-04 用户报：「恢复购买后取消，提示网络失败，但是我的网络是好的」。
/// 根因就在这个翻译上：`AppStore.sync()` **在用户按取消时也会抛错**，
/// 而当时那层翻译根本不存在（错误直接透给 Core，被一律当成"失败"）。
///
/// 这一层是**唯一**知道平台错误码长什么样的地方 —— Core 那边只认语义，
/// 所以漏认一个错误码的后果是：某个真实的取消被报成网络故障。
/// 而那种错在真机上看起来"只是提示不对"，没有任何东西会红。
///
/// ## 为什么认两套
///
/// 同一个"用户取消"，在不同系统版本上分别以 `StoreKitError.userCancelled`
/// 与老的 `SKErrorDomain` code 2（`SKErrorPaymentCancelled`）两种形态抛出来。
/// 只认一种就会漏 —— 而漏掉的那一半恰好是用户最常碰到的那一半。
@Suite("恢复购买：平台错误 → 语义")
struct StoreKitRestoreClassificationTests {

    @Test("StoreKit 2 的取消 → 用户取消")
    func storeKitUserCancelled() {
        #expect(StoreKitStorefront.classifyRestoreFailure(StoreKitError.userCancelled)
                == .cancelledByUser)
    }

    @Test("StoreKit 2 的网络错误 → 连不上")
    func storeKitNetworkError() {
        #expect(StoreKitStorefront.classifyRestoreFailure(
            StoreKitError.networkError(URLError(.notConnectedToInternet))) == .network)
    }

    @Test("网络域里的 -1012「用户取消了认证」→ 也是用户取消，**不是**网络故障")
    func urlErrorUserCancelledAuthentication() {
        // Apple《Handling errors》把 -1012 列在 "StoreKit 的网络错误" 里，
        // 但它的含义就是"用户取消了这次认证"。整片按网络报的话，
        // 用户会看到「检查网络后重试」而他的网是好的 —— 正是本次要修的那个 bug。
        #expect(StoreKitStorefront.classifyRestoreFailure(
            NSError(domain: NSURLErrorDomain,
                    code: URLError.Code.userCancelledAuthentication.rawValue))
                == .cancelledByUser)
        #expect(StoreKitStorefront.classifyRestoreFailure(
            URLError(.userCancelledAuthentication)) == .cancelledByUser)
        #expect(StoreKitStorefront.classifyRestoreFailure(
            StoreKitError.networkError(URLError(.userCancelledAuthentication)))
                == .cancelledByUser)
    }

    @Test("老 API 的 SKErrorPaymentCancelled（域 + 码）→ 也是用户取消")
    func legacyPaymentCancelled() {
        let error = NSError(domain: SKErrorDomain,
                            code: SKError.Code.paymentCancelled.rawValue)
        #expect(StoreKitStorefront.classifyRestoreFailure(error) == .cancelledByUser,
                "用户关掉 Apple ID 登录框时实测常见这一档 —— 漏了它就又变成「网络失败」")
    }

    @Test("老的网络错误码 → 连不上")
    func legacyNetworkFailure() {
        let error = NSError(domain: SKErrorDomain,
                            code: SKError.Code.cloudServiceNetworkConnectionFailed.rawValue)
        #expect(StoreKitStorefront.classifyRestoreFailure(error) == .network)
    }

    @Test("URLError 直接透上来 → 连不上")
    func bareURLError() {
        #expect(StoreKitStorefront.classifyRestoreFailure(URLError(.timedOut)) == .network)
    }

    @Test("认不出来的一律 `.other` —— **绝不**猜成网络")
    func unknownFallsBackToOther() {
        #expect(StoreKitStorefront.classifyRestoreFailure(StoreKitError.unknown) == .other)
        #expect(StoreKitStorefront.classifyRestoreFailure(StoreKitError.notEntitled) == .other)
        #expect(StoreKitStorefront.classifyRestoreFailure(
            NSError(domain: SKErrorDomain, code: SKError.Code.unknown.rawValue)) == .other)
        // 完全陌生的域
        struct Weird: Error {}
        #expect(StoreKitStorefront.classifyRestoreFailure(Weird()) == .other)
    }

    @Test("`systemError` 里裹的那一层会被剥开 —— 但只剥一层")
    func systemErrorUnwrapsOneLayer() {
        // 里面裹着取消 → 认得出
        #expect(StoreKitStorefront.classifyRestoreFailure(
            StoreKitError.systemError(StoreKitError.userCancelled)) == .other,
                "裹着的还是个 StoreKitError ⇒ 只剥一层，不递归 —— 免得走到栈溢出")

        // 里面裹着 URLError → 认得出
        #expect(StoreKitStorefront.classifyRestoreFailure(
            StoreKitError.systemError(URLError(.notConnectedToInternet))) == .network)
    }

    @Test("三档语义都在用 —— 没有哪一档是死代码")
    func everyReasonIsReachable() {
        let cancelled = StoreKitStorefront.classifyRestoreFailure(StoreKitError.userCancelled)
        let network = StoreKitStorefront.classifyRestoreFailure(
            StoreKitError.networkError(URLError(.timedOut)))
        let other = StoreKitStorefront.classifyRestoreFailure(StoreKitError.unknown)

        #expect(cancelled == .cancelledByUser)
        #expect(network == .network)
        #expect(other == .other)
        #expect(cancelled != network)
        #expect(network != other)
    }
}

import AppKit
import MarqueeCore
import MarqueeStore
import os

/// Pro 权益在 App 里的装配点（ticket 31）。
///
/// ## 职责边界
///
/// 它只做三件事：**装配**（把 StoreKit 实现接到 Core 的接缝上）、**启动**
/// （先按缓存出判定、再去核实、并开始监听交易更新）、**自检**（`-marqueeEntitlement`）。
/// 一条判断逻辑都不在这里 —— 判定在 `LicenseResolver`、映射在 `StorefrontMapper`、
/// 时序在 `EntitlementCoordinator`，那些都能脱机单测，而这一层只有真机跑得到。
///
/// 界面那一层（锁标记、升级卡片、偏好里的状态区）属于**下一批**，
/// 它从这里读 `snapshot` 就够了 —— 界面不许自己拼判据。
@MainActor
final class ProEntitlement {

    /// 全 app 唯一的权益状态。多处各持一份的话，
    /// "购买之后那个页面解锁了、这个页面还锁着"这类问题会立刻出现。
    static let shared = ProEntitlement()

    private let store: StoreKitStorefront
    private let coordinator: EntitlementCoordinator
    private let logger = Logger(subsystem: AppIdentity().logSubsystem, category: "entitlement")
    private var isStarted = false

    init() {
        let store = StoreKitStorefront()
        self.store = store
        self.coordinator = EntitlementCoordinator(cache: UserDefaultsEntitlementCache(),
                                                  reader: store,
                                                  purchaser: store)
    }

    /// 当前判定。界面只读这一个东西。
    var snapshot: EntitlementSnapshot { coordinator.snapshot }

    /// 把当前状态推给所有界面。**判定与价格走同一个出口**。
    private func publish() {
        for observer in observers { observer(snapshot) }
    }

    /// 判定变化时要通知的界面。
    ///
    /// 用列表而不是单个闭包：要跟着变的界面**不止一处**（设置里的状态区、
    /// 以后可能还有别的），而"谁最后设置谁生效"这种约定，在两个地方都要更新时
    /// 必然漏掉一个 —— 而且漏掉的那处不会报错，只会一直显示旧值。
    private var observers: [(EntitlementSnapshot) -> Void] = []

    /// 订阅判定变化。**注册时立刻回调一次当前值** ——
    /// 否则界面得自己记得"先读一次、再订阅"，而漏掉前半句的表现是空着不显示。
    func observe(_ observer: @escaping (EntitlementSnapshot) -> Void) {
        observers.append(observer)
        observer(snapshot)
    }

    /// 价格变化时也要刷新界面吗 —— **要**，但它与判定共用 `observe`
    ///（价格到货时会再推一次同一份快照）。理由见 `publish`。

    /// 与商店核对的状态（排障用：分得清"商店说没有"与"压根没连上"）。
    var verification: EntitlementCoordinator.Verification { coordinator.verification }

    /// 商店的价格文案（`displayPrice`，含货币符号、已本地化）。启动时取一次并缓存。
    ///
    /// ## 为什么缓存而不是每次现取
    ///
    /// 它要出现在**卡片正文**里（App Review 3.1.1 要求试用开始前说清"后续费用"），
    /// 而卡片是**同步**画出来的。现取的话只有两条路：让卡片等一次网络往返
    ///（用户被挡下来时盯着一个空卡片），或者先画一张没有价格的、价格到了再重画
    ///（闪一下，而那张卡片是此刻唯一的解释）。
    ///
    /// ⇒ 启动时取一次，之后同步读。价格变了（换店面、官方调价）下次启动就更新 ——
    /// 而**取不到就是 `nil`**：界面会退化成不报价格的那一句，**绝不编一个数**。
    private(set) var priceText: String?

    /// **只在截图路径上调用**：把价格钉成调用方给的值。
    ///
    /// ## 为什么需要这个口子
    ///
    /// 审核截图要展示"**点下去之前就能看见价格**"（验收 Z23 / Z24 的另一半），
    /// 而价格只有一条来路 —— 商店的 `displayPrice`。可截图那台机器上这条路经常是断的：
    ///
    /// - **命令行启动的进程拿不到本地 `.storekit` 配置。** Xcode 是通过它自己的
    ///   启动环境注入的，`open --args` 与直接 exec **两条路都实测过**：都拿不到。
    ///   连 `DYLD_FRAMEWORK_PATH` 指向 Xcode 的 Developer 框架 + 各种候选环境变量
    ///   （`SKTestConfigurationFilePath` / `StoreKitConfigurationFile`）一起试过 ——
    ///   Dev 构建也带 hardened runtime（`flags=0x10000`）⇒ `DYLD_*` 会被直接剥掉；
    /// - 商品还没在 App Store Connect 建好时，真商店也答不出价格。
    ///
    /// ⇒ 截图上就永远只有退化句。所以留一个**显式**的注入口：值**由调用方给**
    ///（= ASC 上那个店面价，例 `¥36.00`），这里不编、视图里也不拼。
    ///
    /// ⚠️ 调用方必须**先给真实取价一个机会**，答不出来才用这个口子
    ///（见 `MarqueeAppDelegate.prepareScreenshotPrice`）—— 商店能答的时候，
    /// 图上应当是**商店的答案**。生产路径只走 `start()` 那次真实取价。
    func overridePriceForScreenshots(_ text: String?) {
        priceText = text
        publish()
    }

    /// 启动。**幂等** —— 被调两次不会重复监听。
    func start() {
        guard !isStarted else { return }
        isStarted = true

        coordinator.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.logger.info("权益变化 → \(String(describing: snapshot.entitlement), privacy: .public)")
            self.publish()
        }

        // 价格：与核实**并行**，不挡任何东西。拿到之后把同一份快照再推一次 ——
        // 卡片上会多出"之后 ¥xx"那一句，而它画的正是这份快照。
        // ⚠️ 走同一个出口（`publish`）：价格单独开一条通知的话，
        // 一定会有某个界面只订阅了其中一条。
        Task { [weak self] in
            guard let self else { return }
            guard let price = await coordinator.displayPrice() else { return }
            self.priceText = price
            self.publish()
        }

        // ⚠️ 启动顺序就是这两行：**先按缓存立刻出判定，再去核实**。
        // `start()` 返回的后台 Task 故意不 await —— 不 await 就等于"判定已经好了、
        // 商店那边慢慢问"。await 了它，断网时用户就要先干等一次超时。
        coordinator.start()

        // 监听必须**在这里**就开始，不能等到打开购买界面。
        // 它送来的是发生在 app 之外的事：退款、家庭共享被移除、家长批准了待批准的购买。
        // 只在购买界面监听的话，"用户在 app 没开的时候退了款"永远不会被发现 ——
        // 表现是**退款了还解锁着**。
        Task { [store] in
            await store.startObservingUpdates { [weak self] in
                await self?.coordinator.verifyWithStore()
            }
        }
    }

    // MARK: - 界面要用的几个动作（下一批的界面直接调这些）

    func purchasePro() async -> PurchaseOutcome { await coordinator.purchasePro() }
    func startTrial() async -> PurchaseOutcome { await coordinator.startTrial() }
    func restorePurchases() async -> EntitlementCoordinator.RestoreOutcome {
        await coordinator.restorePurchases()
    }
    func displayPrice() async -> String? { await coordinator.displayPrice() }
    var canStartTrial: Bool { coordinator.canStartTrial }

    // MARK: - 自检入口

    /// `Marquee -marqueeEntitlement [purchase|trial|restore]`
    ///
    /// 存在的理由：**购买界面还没做，而"能在真实沙盒里买一次"是这一票的验收**。
    /// 有了它，整条链路（取商品 → 购买 → 校验 → 判定 → 缓存）现在就能在
    /// 正式 id 的构建上跑一遍，不用等界面。
    static func runProbe(action: String) async {
        let entitlement = ProEntitlement.shared
        entitlement.start()

        // 等核实回来。启动不等网络，但**报告要等** —— 否则打印的是
        // "还没查"那一版，看不出商店到底说了什么。
        try? await Task.sleep(for: .seconds(3))

        // 动作
        var actionLines: [String] = []
        // L10N-EXEMPT-START: `-marqueeEntitlement` 的控制台报告文案，贴回来给我看
        switch action {
        case "purchase":
            NSApplication.shared.activate()
            let outcome = await entitlement.purchasePro()
            actionLines.append("发起购买   : \(describe(outcome))")
            try? await Task.sleep(for: .seconds(2))
        case "trial":
            NSApplication.shared.activate()
            let outcome = await entitlement.startTrial()
            actionLines.append("发起试用   : \(describe(outcome))")
            try? await Task.sleep(for: .seconds(2))
        case "restore":
            let result = await entitlement.restorePurchases()
            actionLines.append("恢复购买   : \(String(describing: result))")
        case "":
            break
        default:
            actionLines.append("未知动作   : \(action)（可用：purchase / trial / restore）")
        }
        // L10N-EXEMPT-END

        let price = await entitlement.displayPrice()

        // L10N-EXEMPT-START: `-marqueeEntitlement` 的控制台报告，贴回来给我看
        let report = """
        Marquee 内购探针
          身份        : \(AppIdentity().bundleIdentifier)\(AppIdentity().isDevelopmentBuild ? "（开发版）" : "（正式版）")
          权益判定    : \(describe(entitlement.snapshot.entitlement))
          能放行 Pro  : \(entitlement.snapshot.allowsProFeatures ? "是" : "否（\(String(describing: entitlement.snapshot.blockedReason))）")
          商店核对    : \(describe(entitlement.verification))
          能开始试用  : \(entitlement.canStartTrial ? "是" : "否")
          商品价格    : \(price ?? "取不到（商品没建 / 商店不可用）")
          缓存文件键  : pro.entitlementCache（域 = \(AppIdentity().bundleIdentifier)）
        \(actionLines.joined(separator: "\n"))
          时间        : \(Date())
        """
        // L10N-EXEMPT-END

        print(report)
        writeProbe(report)
        NSApplication.shared.terminate(nil)
    }

    // L10N-EXEMPT-START: 同上 —— 都是探针报告里的说明文字
    private static func describe(_ outcome: PurchaseOutcome) -> String {
        switch outcome {
        case .purchased(let record):
            "买成了（\(record.productIdentifier)，交易时间 \(record.purchaseDate)）"
        case .cancelledByUser: "用户取消"
        case .pending: "待批准（等交易更新）"
        case .unavailable: "商店里没有这个商品 —— 检查 App Store Connect 与 bundle id"
        case .failed: "出错（可重试）"
        }
    }

    private static func describe(_ entitlement: Entitlement) -> String {
        switch entitlement {
        case .unknown: "unknown（还没查，按放行处理）"
        case .free: "free"
        case .trial(let daysLeft): "trial（还剩 \(daysLeft) 天）"
        case .pro(let date): "pro（\(date) 购买）"
        case .revoked(let reason): "revoked（\(String(describing: reason))）"
        }
    }

    private static func describe(_ verification: EntitlementCoordinator.Verification) -> String {
        switch verification {
        case .notYetAttempted: "还没试过"
        case .succeeded(let at): "成功（\(at)）"
        case .failed: "失败 —— 判定保持上一次的值"
        }
    // L10N-EXEMPT-END
    }

    /// 探针结果落到固定路径（用 `open` 启动时 stdout 不回终端）。
    ///
    /// 目录由 `AppIdentity.logDirectory()` 给 —— 三个探针原本各拼一遍同一个路径，
    /// 那种重复迟早变成"有的探针读得到、有的读不到"。
    private static func writeProbe(_ text: String) {
        let directory = AppIdentity().logDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: directory.appendingPathComponent("entitlement-probe.txt"),
                        atomically: true,
                        encoding: .utf8)
    }
}

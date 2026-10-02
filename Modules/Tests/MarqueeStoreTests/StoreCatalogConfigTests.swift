import Foundation
import MarqueeCore
import Testing

@testable import MarqueeStore

/// `Products.storekit` 与 `StoreCatalog` 的一致性（ticket 31 第二批）。
///
/// ## 为什么这条测试值钱
///
/// 本地 StoreKit 配置（`Products.storekit`）与代码里的商品 id 是**两份独立的事实**，
/// 而它们不同步的后果很难反查：
///
/// - 配置里有、代码里没有 → 开发期能买、但没人读它的结果（"点了购买没反应"）；
/// - 代码里有、配置里没有 → **本地能过、真机上取不到商品**（`.unavailable`），
///   而排障会先去怀疑网络。
///
/// 真正把两份事实连起来的地方只有这里。真机沙盒能验购买流程，但验不了"配置与代码是否一致"
/// —— 那正好是本地测试的活。
@Suite("商店配置一致性（ticket 31）")
struct StoreCatalogConfigTests {

    // MARK: - 定位与解析

    /// 从本文件的路径上溯到仓库根（`Modules/Tests/MarqueeStoreTests/xxx.swift` → 仓库）。
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MarqueeStoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // 仓库根
    }

    static var configURL: URL {
        root.appendingPathComponent("App/Products.storekit")
    }

    struct Config: Decodable {
        struct Product: Decodable {
            var productID: String
            var type: String
            var displayPrice: String
            var familyShareable: Bool
            struct Localization: Decodable {
                var displayName: String
                var locale: String
            }
            var localizations: [Localization]
        }
        var products: [Product]
    }

    private func config() throws -> Config {
        let data = try Data(contentsOf: Self.configURL)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// ⚠️ 解析器自检。
    ///
    /// 没有这一条，一个"什么都解析不出来"的实现会让下面每一条断言都**空跑通过**
    /// （空集合与空集合当然相等）。绿色从"配置正确"悄悄变成"检查没生效"，
    /// 而两者在输出上完全一样。
    @Test("自检：配置文件存在、能解析、而且真的读到了商品")
    func parserActuallyReadsSomething() throws {
        #expect(FileManager.default.fileExists(atPath: Self.configURL.path),
                "App/Products.storekit 不在了 —— 本地购买流程会直接取不到商品")

        let parsed = try config()
        #expect(!parsed.products.isEmpty, "解析出 0 个商品：下面的断言会变成空跑")
        for product in parsed.products {
            #expect(!product.localizations.isEmpty, "\(product.productID) 没有本地化名称")
        }
    }

    // MARK: - 两份事实必须一致

    @Test("配置文件里的商品 id 与 `StoreCatalog` **完全一致**（两个方向都查）")
    func identifiersMatchBothWays() throws {
        let inFile = Set(try config().products.map(\.productID))
        let inCode = Set(StoreCatalog.allProductIdentifiers)

        #expect(inFile.subtracting(inCode).isEmpty,
                "配置文件里这些商品代码不认识：\(inFile.subtracting(inCode).sorted()) —— 开发期买得到、但没人读结果")
        #expect(inCode.subtracting(inFile).isEmpty,
                "代码里这些商品配置里没有：\(inCode.subtracting(inFile).sorted()) —— 本地能过、真机取不到")
    }

    @Test("商品 id 不重复")
    func identifiersAreUnique() throws {
        let ids = try config().products.map(\.productID)
        #expect(Set(ids).count == ids.count)
    }

    @Test("商品 id 用**正式 bundle id** 作前缀 —— 这份绑定关系要看得见")
    func identifiersArePrefixedByProductionBundleID() throws {
        // 它不是洁癖：IAP 商品一旦创建就**永久绑定**当时的 bundle id，无法转移
        // （见 docs/DEV-VS-PROD.md §3.2）。所以"商品 id 与正式 id 的关系"
        // 值得被钉住 —— 将来真要改 bundle id 时，这条会提醒你去核对商品那一侧。
        for product in try config().products {
            #expect(product.productID.hasPrefix(AppIdentity.productionBundleIdentifier),
                    "\(product.productID) 不是以正式 bundle id 开头")
        }
    }

    // MARK: - 两个商品各自的形态

    private func product(_ identifier: String) throws -> Config.Product {
        let found = try config().products.first { $0.productID == identifier }
        return try #require(found, "配置里没有 \(identifier)")
    }

    @Test("买断商品：非消耗型、有价格、允许家人共享")
    func proProductShape() throws {
        let pro = try product(StoreCatalog.proProductIdentifier)

        // "非消耗型"是这个设计的地基：买断制靠的就是它（消耗型会被重复消耗，
        // 而自动续期订阅是另一套完全不同的状态机）。
        #expect(pro.type == "NonConsumable")
        let price = try #require(Double(pro.displayPrice))
        #expect(price > 0, "买断商品的价格必须大于 0")
        // 家人共享是**已经定下的决策**（非消耗型默认支持，开着是免费的善意）。
        // 钉住它，免得将来有人"顺手"关掉 —— 那会让一家人都用不了。
        #expect(pro.familyShareable, "买断商品建议开着家人共享")
    }

    @Test("试用商品：**0 价的非消耗型** —— 这就是 3.1.1 给的那条试用路径")
    func trialProductShape() throws {
        let trial = try product(StoreCatalog.trialProductIdentifier)

        // App Review Guideline 3.1.1 原文：非订阅式 app 可以用
        // "价格档 0 的非消耗型 IAP" 提供限期试用，命名遵循 `XX 天试用`。
        #expect(trial.type == "NonConsumable", "试用必须是非消耗型 —— 它只是 0 价，不是另一种商品类型")
        #expect(Double(trial.displayPrice) == 0, "试用商品的价格必须是 0")

        // 命名要能直接看出是几天的试用（3.1.1 对命名有要求）。
        let names = trial.localizations.map(\.displayName)
        #expect(names.contains { $0.contains("试用") }, "本地化名称里要写明是试用：\(names)")
        #expect(names.contains { $0.contains("Trial") }, "英文名同样要写明：\(names)")
    }

    @Test("两个商品都要有中英两套本地化名称（少一套就是某语言的用户看到英文/空白）")
    func bothProductsAreLocalized() throws {
        for product in try config().products {
            let locales = Set(product.localizations.map(\.locale))
            #expect(locales.contains("zh_CN"), "\(product.productID) 缺中文名称")
            #expect(locales.contains("en_US"), "\(product.productID) 缺英文名称")
        }
    }
}

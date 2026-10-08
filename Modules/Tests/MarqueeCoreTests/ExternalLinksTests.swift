import Foundation
import Testing
@testable import MarqueeCore

/// 守 `ExternalLinks` —— 也就是 "app 内那个隐私政策入口会指向哪"。
///
/// 存在的理由：这条链路的失败**在开发机上完全没有症状**。链接写错、写成占位符、
/// 或者指向首页，app 里那一行照样画得好好的，只有审核员点下去才知道 ——
/// 而那时回来的是一封 Guideline 5.1.1 的拒信。
@Suite("对外链接")
struct ExternalLinksTests {

    @Test("隐私政策链接：能解析、是 https、不含占位符")
    func privacyPolicyIsUsable() throws {
        // 解析不出来 ⇒ 界面会把那一行藏起来。藏起来是**诚实**的（不给死链），
        // 但那样这一票就没做完 —— 所以在这里先红。
        let url = try #require(ExternalLinks.privacyPolicy,
                               "隐私政策链接解析不出来；app 内那一行会被藏起来")

        // https 是硬要求：http 链接会被审查看作不可信来源。
        #expect(url.scheme == "https", "隐私政策必须走 https，实际是 \(url.scheme ?? "nil")")

        let host = try #require(url.host)
        #expect(!host.isEmpty)

        // 占位符黑名单。它们与"死链"在审核眼里是同一件事：
        // 都表现为"隐私政策不可访问"，而本地看不出任何异常。
        let forbidden = ["example.com", "yourcompany", "your-domain", "yourdomain",
                         "TODO", "PLACEHOLDER", "localhost", "127.0.0.1"]
        for token in forbidden {
            #expect(!ExternalLinks.privacyPolicyURLString.localizedCaseInsensitiveContains(token),
                    "链接里出现了占位符「\(token)」")
        }
    }

    @Test("链接要指向**具体某一页**，不是首页")
    func privacyPolicyIsNotABareHomepage() throws {
        let url = try #require(ExternalLinks.privacyPolicy)
        // 只有域名、没有路径 ⇒ 十有八九落到首页，而"隐私政策 URL 指向首页"
        // 是 5.1.1 最常见的打回理由之一（点进去的内容与声明不符）。
        #expect(url.path.count > 1, "链接没有指向具体页面（path = 「\(url.path)」）")
    }
}

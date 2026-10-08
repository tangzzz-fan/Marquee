import Foundation

/// 对外的链接。**集中在这里，别在界面里另写一份。**
///
/// ## 为什么要有这个文件
///
/// 隐私政策 URL 会出现在**三个地方**：
///
/// 1. App Store Connect 的「隐私政策 URL」那一格；
/// 2. 隐私政策文档本身（`docs/PRIVACY-POLICY.md`）；
/// 3. **app 内**。
///
/// 第 3 条是硬性要求，而且最容易被漏掉 —— Guideline 5.1.1(i) 的原文是
/// *"All apps must include a link to their privacy policy in the App Store Connect
/// metadata field **and within the app** in an easily accessible manner."*
///（2026-10-08 核实；本项目在补这一条之前，全仓一个隐私政策链接都没有。）
///
/// 三处各写一遍的话，改一处就分叉，而分叉的表现是"审核员点开的是旧链接"。
public enum ExternalLinks {

    /// 隐私政策的地址。**要改就只改这一行。**
    ///
    /// 线上位置：飞书知识库节点（`docs/PRIVACY-POLICY.md` 里有正文与发布步骤）。
    ///
    /// ⚠️ **发布前必须用无痕窗口验一次**：飞书文档默认是「仅组织内可阅读」，
    /// 而**知识库节点（`/wiki/…`）的分享权限是另一套**，比普通文档更容易漏。
    /// 审核员没有你的飞书账号 —— 打开只会看到登录页，然后以
    /// Guideline 5.1.1（隐私政策 URL 不可访问）打回。
    public static let privacyPolicyURLString = "https://mcnrn1su375m.feishu.cn/wiki/LqIQwd0YbioZBYkCBq7cY0Rcntb"

    /// 解析后的 URL。**写错字面量时是 `nil`** —— 界面据此把那一行整个藏起来。
    ///
    /// 为什么不写 `URL(string: …)!`：一个点不开的链接在审核眼里不是"少了个功能"，
    /// 而是"隐私政策不可访问"，同样会被打回；而崩掉更糟。
    /// 藏起来至少是诚实的 —— 而且这个常量有测试守着（`ExternalLinksTests`）。
    public static var privacyPolicy: URL? {
        URL(string: privacyPolicyURLString)
    }
}

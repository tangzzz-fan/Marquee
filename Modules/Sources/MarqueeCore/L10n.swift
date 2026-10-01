import Foundation

/// 面向用户的文案入口（ticket 17b）。
///
/// ## 为什么只有一份 catalog
///
/// App 是唯一的宿主 target，6 个模块都静态链进它 —— 所以文案资源只放
/// `App/Resources/Localizable.xcstrings` 一份，所有模块统一查 `Bundle.main`。
/// 反过来（每个模块一份 catalog + `Bundle.module`）要改 4 个 `Package.swift`
/// 加 `resources:`，还要维护 4 份 catalog，收益为零。
///
/// ## key 就是**中文原句**
///
/// 开发语言＝源语言，于是 `L10n.t("矩形")` 的 key 直接是那句话。
/// 这样省掉 186 个自造 key，也让 diff 里"这行改了什么"一眼可见。
///
/// ⚠️ **插值串不要自己拼 format**：`L10n.t` 收的是 `String.LocalizationValue`，
/// 插值由编译器记进 key（`\(n)` → `%lld`、`\(s)` → `%@`）。
/// 写成 `L10n.t("已复制 " + text)` 或先插值再传 `String` 会**静默失效** ——
/// 查表用的是渲染后的串，catalog 永远匹配不上，英文用户照样看到中文。
///
/// ## 漏翻会怎样
///
/// catalog 里没有这一条时，`String(localized:)` **回落到 key 本身**（也就是中文），
/// 而不是把 key 显示给用户。所以迁移可以一片一片来，中间态永远是可用的。
public enum L10n {

    /// 查表用的 bundle。默认即宿主 App（见上面的说明）。
    ///
    /// 留成 `var` 是为了测试能换成自造的 bundle；生产里没有任何地方改它。
    nonisolated(unsafe) public static var bundle: Bundle = .main

    /// 取一条文案。key 与 catalog 里的 key 必须逐字一致。
    public static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Localizable", bundle: bundle)
    }
}

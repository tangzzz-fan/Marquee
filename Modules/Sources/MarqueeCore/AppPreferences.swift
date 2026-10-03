import CoreGraphics
import Foundation

/// 「通用」页的偏好（ticket 15）。
///
/// ## 为什么要一个类型、而不是三个散落的 `UserDefaults` key
///
/// 读的时候要**一起**读（截图那一刻要用到全部），写的时候要**一起**写。
/// 散着写的话，"改了但没生效"会变成一件要靠猜的事 —— 而这一页上的每一项
/// 都直接改变用户看到的结果。
public struct GeneralPreferences: Equatable, Sendable {
    /// 截图成功后播一声系统音效。
    ///
    /// 关掉它的实际场景是"连着截很多张时不想被声音打断"。
    public var playSound: Bool
    /// 开机自启（走 `SMAppService`）。
    public var launchAtLogin: Bool

    public init(playSound: Bool = true, launchAtLogin: Bool = false) {
        self.playSound = playSound
        self.launchAtLogin = launchAtLogin
    }

    // 刻意**没有**"截图后是否自动复制到剪贴板"这一项：
    // 这条链路（`CaptureOutput.finish`）目前无条件写剪贴板，而"能不写"要靠
    // 注入一个空剪贴板实现 —— 那样 `CaptureOutcome.copiedToClipboard` 这个
    // 结果名就成了假话（日志会说"已复制"，而其实没有）。
    // 界面上摆一个**兑现不了**的开关，比少一个开关糟糕得多。

    public static let `default` = GeneralPreferences()
}

/// 「截屏」页的偏好。
public struct CapturePreferences: Equatable, Sendable {
    /// 截图里**包含鼠标指针**。
    ///
    /// 默认关：指针会挡在内容上，而"我要的是那张图、不是我的鼠标在哪"是更常见的情形。
    public var includeCursor: Bool
    /// 窗口截图**带系统阴影**。
    ///
    /// 覆盖层里按 `⌥` 会临时反转这一项（PRD F4）。
    public var includeShadow: Bool
    /// 按下快捷键之后、覆盖层出现之前的等待秒数。
    public var delaySeconds: Int

    public init(includeCursor: Bool = false, includeShadow: Bool = true, delaySeconds: Int = 0) {
        self.includeCursor = includeCursor
        self.includeShadow = includeShadow
        self.delaySeconds = Self.normalize(delaySeconds)
    }

    /// 可选的延时档位。
    ///
    /// 是**有限档位**而不是任意数字：一个数输入框要配校验、错误提示、越界夹取，
    /// 而用户要的只是"给我几秒钟摆一下"。
    public static let delayOptions = [0, 3, 5, 10]

    /// 把存下来的值夹进合法档位。
    ///
    /// ⚠️ 这一条不是洁癖：`UserDefaults` 里可能留着旧版本写的、或者被人手改过的值
    /// （`defaults write dev.tango.Marquee capture.delaySeconds -int 999`）。
    /// 不夹的话，用户按一下快捷键要等 **16 分钟**才看到覆盖层 ——
    /// 那与"应用卡死了"完全一样，而且没有任何提示。
    public static func normalize(_ seconds: Int) -> Int {
        delayOptions.contains(seconds) ? seconds : 0
    }

    /// 延时那一行的**说明句** —— 它随档位改写。
    ///
    /// ## 为什么这一项的说明句要换
    ///
    /// 稿子 §04 的原话：「延时这一项改了**当场看不出效果**（要等下一次按快捷键），
    /// 所以它的回执全押在说明句上：说明句随档位改写。」
    ///
    /// 窗口里没有「应用」按钮（改一下立刻落盘），而"立刻生效"这件事在多数项上
    /// 是**看得见**的（开关会动、分区会变）。延时是唯一一项改完屏幕上什么都不会变的 ——
    /// 所以它需要一句**说人话的回执**，而不是一个不动的控件。
    ///
    /// ⚠️ 句子里要带上**当前的快捷键**。写死 `⌃Q` 的话，用户把键改了之后
    /// 这一句就成了一句反话 —— 而它会一直挂在那里，用户按图索骥按错键。
    /// 这也是为什么这一条判据必须吃 `KeyCombo` 而不是一个 Bool。
    ///
    /// ⚠️ 「那几秒是留给你摆屏幕的」只出现在 **3 秒**那一档（稿子给的四句就是这样）：
    /// 它是这个功能的**由来**，说一遍就够；四档各说一遍会变成墙上的标语。
    public static func delayExplanation(seconds: Int, combo: KeyCombo) -> String {
        switch normalize(seconds) {
        case 0:
            L10n.t("按 \(combo.displayString) 立刻出现覆盖层")
        case 3:
            L10n.t("按 \(combo.displayString) 后 3 秒才出现覆盖层 —— 那几秒是留给你摆屏幕的")
        case 5:
            L10n.t("按 \(combo.displayString) 后 5 秒才出现覆盖层")
        default:
            L10n.t("按 \(combo.displayString) 后 10 秒才出现覆盖层")
        }
    }

    public static let `default` = CapturePreferences()
}

/// 偏好设置的落盘。
///
/// 与 `UserDefaultsOutputStore` 分开：那一个管输出（目录 / 格式 / 模板 / 序号），
/// 已经在 ticket 05 落地并有自己的测试，没必要为了"合在一起"去动它。
public struct UserDefaultsPreferencesStore: @unchecked Sendable {

    public static let soundKey = "general.playSound"
    public static let launchAtLoginKey = "general.launchAtLogin"
    public static let cursorKey = "capture.includeCursor"
    public static let shadowKey = "capture.includeShadow"
    public static let delayKey = "capture.delaySeconds"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 通用

    public func general() -> GeneralPreferences {
        GeneralPreferences(playSound: bool(Self.soundKey, default: GeneralPreferences.default.playSound),
                           launchAtLogin: bool(Self.launchAtLoginKey, default: GeneralPreferences.default.launchAtLogin))
    }

    public func save(_ general: GeneralPreferences) {
        defaults.set(general.playSound, forKey: Self.soundKey)
        defaults.set(general.launchAtLogin, forKey: Self.launchAtLoginKey)
    }

    // MARK: - 截屏

    public func capture() -> CapturePreferences {
        CapturePreferences(includeCursor: bool(Self.cursorKey, default: CapturePreferences.default.includeCursor),
                           includeShadow: bool(Self.shadowKey, default: CapturePreferences.default.includeShadow),
                           delaySeconds: defaults.object(forKey: Self.delayKey) as? Int
                               ?? CapturePreferences.default.delaySeconds)
    }

    public func save(_ capture: CapturePreferences) {
        defaults.set(capture.includeCursor, forKey: Self.cursorKey)
        defaults.set(capture.includeShadow, forKey: Self.shadowKey)
        defaults.set(CapturePreferences.normalize(capture.delaySeconds), forKey: Self.delayKey)
    }

    // MARK: - 内部

    /// **不能**用 `defaults.bool(forKey:)` 直接取默认值 —— 它在 key 不存在时返回 `false`，
    /// 而那与"用户关掉了"无法区分。于是"默认打开"的项会变成默认关闭，
    /// 且只在**全新安装**时表现出来（开发机上早就被别的测试写进去了）。
    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}


/// 偏好设置的**页面清单**（ticket 15）。
///
/// 从 `MarqueeSettings` 挪到 Core：它描述的是**偏好模型有哪些页**，而页面清单
/// 正是"约束"本身（PRD 3.1：最多 4 页）。放在实现模块里会让 Core 的测试够不着它，
/// 而"页数不能超过 4"这条**恰恰是最该有测试守着的一条**。
///
/// 新增页面必须同时改这里和那条测试 —— 那是刻意的摩擦。
public enum SettingsPage: String, CaseIterable, Sendable {
    /// 通用：启动行为、剪贴板、音效
    case general
    /// 截屏：光标、阴影、延时
    case capture
    /// 输出：保存位置、格式、命名模板
    case output
    /// 快捷键
    case shortcuts

    /// 标签页标题。
    public var title: String {
        switch self {
        case .general: L10n.t("通用")
        case .capture: L10n.t("截屏")
        case .output: L10n.t("输出")
        case .shortcuts: L10n.t("快捷键")
        }
    }
}

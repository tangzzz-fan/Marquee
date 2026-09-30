import CoreGraphics
import MarqueeCore

/// 偏好设置模块。
///
/// 归属 ticket：15（四页偏好与快捷键配置）。
///
/// 约束（来自 PRD 3.1「功能简洁」）：**最多 4 页**，每页可调项要克制。
/// 这里先把页面清单固定下来，新增页面必须走评审。
public enum SettingsPage: String, CaseIterable, Sendable {
    case general   // 启动行为
    case capture   // 光标、阴影、延时
    case output    // 保存位置、格式、命名模板
    case shortcuts // 快捷键
}

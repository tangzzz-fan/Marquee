// swift-tools-version: 6.0
import PackageDescription

// Marquee 的模块化边界。
//
// 依赖规则（不要打破）：
//   - 只有 MarqueeCore 是无依赖的纯逻辑层
//   - 其余模块只允许依赖 MarqueeCore，模块之间不互相依赖
//   - 宿主 target（Marquee）负责把所有模块装配起来
// 违反这条规则会让「纯逻辑可单测」的前提失效，见 docs/PRD.md 5.2。
//
// `MarqueeTestSupport` 是**测试专用**目标：合成数据（长页生成、像素读取、MAE）
// 要被两个测试目标共用（`MarqueeCoreTests` 断言拼接公式，`MarqueeCaptureTests` 断言
// 真实 Vision 的端到端结果）。它**不挂进宿主 target**，不会被应用链接。
let package = Package(
    name: "MarqueeModules",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MarqueeCore", targets: ["MarqueeCore"]),
        .library(name: "MarqueeCapture", targets: ["MarqueeCapture"]),
        .library(name: "MarqueeOverlay", targets: ["MarqueeOverlay"]),
        .library(name: "MarqueeEditor", targets: ["MarqueeEditor"]),
        .library(name: "MarqueeSettings", targets: ["MarqueeSettings"]),
        .library(name: "MarqueeHistory", targets: ["MarqueeHistory"]),
    ],
    targets: [
        .target(name: "MarqueeCore"),
        .target(name: "MarqueeCapture", dependencies: ["MarqueeCore"]),
        .target(name: "MarqueeOverlay", dependencies: ["MarqueeCore"]),
        .target(name: "MarqueeEditor", dependencies: ["MarqueeCore"]),
        .target(name: "MarqueeSettings", dependencies: ["MarqueeCore"]),
        .target(name: "MarqueeHistory", dependencies: ["MarqueeCore"]),

        // 测试专用：合成长页 + 位图读取 + MAE 比对
        .target(name: "MarqueeTestSupport"),

        .testTarget(name: "MarqueeCoreTests",
                    dependencies: ["MarqueeCore", "MarqueeTestSupport"]),
        // 真实 Vision 配准的「装置自检」必须打在真实实现上，所以单独一个测试目标
        .testTarget(name: "MarqueeCaptureTests",
                    dependencies: ["MarqueeCapture", "MarqueeCore", "MarqueeTestSupport"]),
        // ticket 16 的历史仓库要断言"删完之后文件系统里到底还剩什么"，
        // 而那是 `MarqueeHistory` 的事 —— 放在 Core 的测试里够不着。
        .testTarget(name: "MarqueeHistoryTests",
                    dependencies: ["MarqueeHistory", "MarqueeCore"]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// Marquee 的模块化边界。
//
// 依赖规则（不要打破）：
//   - 只有 MarqueeCore 是无依赖的纯逻辑层
//   - 其余模块只允许依赖 MarqueeCore，模块之间不互相依赖
//   - 宿主 target（Marquee）负责把所有模块装配起来
// 违反这条规则会让「纯逻辑可单测」的前提失效，见 docs/PRD.md 5.2。
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
        .testTarget(name: "MarqueeCoreTests", dependencies: ["MarqueeCore"]),
    ]
)

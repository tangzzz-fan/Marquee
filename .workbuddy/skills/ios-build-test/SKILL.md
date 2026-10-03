---
name: ios-build-test
description: This skill should be used for any iOS build or test task on this machine — building or testing an iOS app/package for the Simulator or a real device with `xcodebuild`, picking or listing a destination, installing/launching on a simulator, or diagnosing iOS-specific build failures (provisioning/code signing, "Unable to find a destination matching", device not found, Swift macro `swift-plugin-server ... produced malformed response`). Trigger it on requests like "build 一下 iOS"、"在模拟器上跑"、"跑一下测试"、"上真机", or when a repo such as jove / ExternaldisplayDemo needs its scheme built or tested. The sandbox-escape parameters and the macro-failure signature live in `apple-build-sandbox`; this skill carries the destination syntax for both simulators and devices.
agent_created: true
---

# iOS 构建与测试（模拟器 / 真机）

## 0. 陌生项目 60 秒上手

```bash
IOS=~/.workbuddy/skills/ios-build-test/scripts/ios-run.sh

ls -d */*.xcodeproj */*.xcworkspace 2>/dev/null     # 工程在哪
xcodebuild -list -project Foo.xcodeproj             # schemes / configurations 一次看清
$IOS probe                                          # 环境 + 沙箱判据 + 可用模拟器/真机
$IOS build --project Foo.xcodeproj --scheme Foo     # 直接构建（destination 自动挑）
```

**先 `-list` 再动手** —— scheme 名猜错会得到 `The project named "X" does not contain a scheme named "Y"`，
那是最容易浪费一轮的一种失败。

## 1. 第一原则：这个环境是**嵌套沙箱**

**这段知识的正文只有一份，在独立技能 `apple-build-sandbox` 里**（用户级 `~/.workbuddy/skills/`
或项目级 `.workbuddy/skills/`）：判据命令、逃逸参数、「社区常推的三个参数为什么无效」、
以及**宏报错的失败签名**都在那儿。**别在这里重写一份。**

本技能只留三条够用的：

- **先跑判据再动手**：`sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok`
- `ios-run.sh` 会**自动判断并加上**：`xcodebuild` → `OTHER_SWIFT_FLAGS=-disable-sandbox`；
  SwiftPM 侧 → `--disable-sandbox`
- 看到宏的 `produced malformed response` → **先往上翻一行找 `sandbox_apply`**，别去查插件路径

## 2. destination：三种形态

| 要跑在哪 | 参数 | 说明 |
| --- | --- | --- |
| **模拟器（按机型名）** | `--sim "iPhone 18 Pro"` | 最省事；机型名要**现查** |
| **模拟器（按 UDID）** | `--sim D16A8318-…` | 最稳，不受重名影响 |
| **真机** | `--device 00008140-…` | 需要签名/描述文件 |
| 不指定 | 自动挑一台可用 iPhone 模拟器 | 脚本行为 |

### ⚠️ 机型与 UDID **必须现查**

模拟器会被删除、重建、随 Xcode 升级换代。本机实测：几天前记录的 `iPhone 17 Pro (CA2BEF90-…)`
**已经不存在**；当前列表是 `iPhone 18 Pro` / `iPhone 18 Pro Max` / `iPhone 17e` /
`iPhone Air` / `iPhone 17`。连接的**真机也可能换**（UDID 会变）。

所以：**不要把 UDID 写进脚本、文档或测试代码**；每次先

```bash
$IOS sims        # 可用模拟器（含 UDID 与 Booted/Shutdown）
$IOS devices     # 已连接的真机
```

用户提到某个机型时，**先核对它还在不在**，再照它下参数。

## 3. 测试

```bash
$IOS test --project Foo.xcodeproj --scheme Foo
$IOS test --project Foo.xcodeproj --scheme Foo --only-testing FooTests/LoginTests
$IOS test --project Foo.xcodeproj --scheme Foo --result-bundle /tmp/Foo.xcresult
```

- **`--only-testing <Target>/<Class>[/<method>]`** 是最高价值的一个参数：全量 UI 测试十几分钟，
  单条用例几十秒。改一处就跑相关的那几条。
- 要保留报告（失败截图、附件、耗时）就给 `--result-bundle`，再
  `xcrun xcresulttool get --path X.xcresult --format json`。
- `xcodebuild test` 需要 scheme 里配了 test target。**没有 test target 的 scheme**
  会报 `Scheme Foo is not currently configured for the test action` —— 那就退回
  `build`（只验编译），或用 SwiftPM 侧测（若逻辑在本地包里）。

## 4. 失败签名对照表（iOS 特有）

| 症状 | 原因 / 处置 |
| --- | --- |
| `...'SwiftUIMacros.StateMacro' could not be found ... produced malformed response` | 上一行必有 `sandbox_apply: Operation not permitted` → 加逃逸参数（§1） |
| `Unable to find a destination matching the provided destination specifier` | 机型被删了 / 系统版本变了 → 重新 `sims`，改用 UDID |
| `No signing certificate "iOS Development" found` / `Provisioning profile ... doesn't include` | 真机签名问题。模拟器不受影响 —— **先确认是不是非要上真机**（多数构建/测试在模拟器就够） |
| `The request was denied by service delegate (SBMainWorkspace)` / 模拟器卡住 | `xcrun simctl shutdown all` 再 `xcrun simctl boot <udid>`；顽固时 `xcrun simctl erase <udid>`（会清掉该模拟器的数据） |
| 构建成功但 app 立刻崩 | 先看 `~/Library/Logs/DiagnosticReports/` 与 `xcrun simctl spawn <udid> log stream` |
| `Could not resolve package dependencies` | 网络 / 代理（见 §5） |
| 首次构建特别慢 | SPM 解析 + 全量编译；增量通常快一个数量级 |

## 5. 远程 SPM 依赖与代理

本地路径依赖**不联网**；一旦工程引用远程包（`https://github.com/...`），首次解析需要出网。
解析失败时：

- 报错形如 `Could not resolve package dependencies` / `Failed to clone repository` —— **先确认是网络**
  （`curl -sI https://github.com` 超时即是）。
- 本技能的脚本**不会自动开代理** —— 代理配置在会话之外，擅自设 `HTTP_PROXY` 可能与用户的
  真实环境冲突。**遇到就先问用户**当前代理是否已启用。
- 已经解析过的依赖会有本地缓存（`~/Library/Caches/org.swift.swiftpm`），离线也能重复构建。

## 6. 写脚本时的环境坑

**这段知识的正文只有一份，在独立技能 `shell-portability` 里**（项目 `.workbuddy/skills/`
或用户级 `~/.workbuddy/skills/`）：两套 `grep` 语义、三条硬规则、`sed -i` 的两套语义、
`$var` 后紧跟全角字符、heredoc 配 `set -e` 的写法、逃生舱、以及自查命令。

本技能只留两条：

| 坑 | 正解 |
| --- | --- |
| 解析 `simctl` / `devicectl` 输出 | 用 `--json` + python3（`xcrun simctl list devices available --json`），别去 grep 人类可读格式 |
| 失败时的读法 | **先看第一条 `error:`**，不要先看最后一条（后面常是级联噪声） |

本技能的 `scripts/ios-run.sh` 已在开头把 shim 目录从 PATH 摘掉，脚本内语义恒定 ——
自己写脚本时照抄那段，或直接看 `shell-portability` 的 §2。

## 7. 与其他技能的分工

- **macOS 本机**（host app、命令行工具、SwiftPM）→ 用 `macos-build-test`
- **沙箱判据与逃逸参数** → 用 `apple-build-sandbox`（两个 build 技能共用同一份，不各自重写）
- **shell 两套语义** → 用 `shell-portability`
- 本技能只管 iOS 的 **destination、签名、模拟器状态机与失败签名**。

更深入的排查（签名、模拟器状态机、xcresult）见 `references/troubleshooting.md`。

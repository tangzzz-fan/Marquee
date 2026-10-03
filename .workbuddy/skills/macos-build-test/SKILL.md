---
name: macos-build-test
description: This skill should be used for any macOS-side build or test task on this machine — building/testing a macOS app or command-line target with `xcodebuild`, running a SwiftPM package's `swift build|test`, choosing a build configuration (Debug/Dev/Release), or diagnosing "Xcode 编不过 / 构建失败" when the cause is the sandboxed environment rather than the code (e.g. `swift-plugin-server ... produced malformed response`, `sandbox_apply: Operation not permitted`). Trigger it on requests like "build 一下"、"编译看看"、"跑一下测试"、"跑一遍 test.sh", or when a repo such as Marquee's needs its scheme built. It carries the configuration semantics that make performance numbers meaningful; the sandbox-escape parameters and the macro-failure signature live in `apple-build-sandbox`.
agent_created: true
---

# macOS 构建与测试（本机 host + SwiftPM）

## 0. 60 秒上手

```bash
M=~/.workbuddy/skills/macos-build-test/scripts/macos-run.sh

ls -d */*.xcodeproj */*.xcworkspace 2>/dev/null   # 工程在哪
ls scripts/ 2>/dev/null                           # **项目自带脚本优先**（见 §3）
xcodebuild -list -project Foo.xcodeproj           # schemes / configurations 一次看清
$M probe                                          # 环境 + 沙箱判据 + macOS SDK

$M macos --project Foo.xcodeproj --scheme Foo build
$M spm test --package-dir Modules                 # SwiftPM 包（最快的一条路）
```

## 1. 第一原则：这个环境是**嵌套沙箱**

**这段知识的正文只有一份，在独立技能 `apple-build-sandbox` 里**（用户级 `~/.workbuddy/skills/`
或项目级 `.workbuddy/skills/`）：判据命令、逃逸参数、「社区常推的三个参数为什么无效」、
以及**宏报错的失败签名**都在那儿。**别在这里重写一份。**

本技能只留三条够用的：

- **先跑判据再动手**：`sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok`
- `macos-run.sh` 在需要时**自动加上**：`xcodebuild` → `OTHER_SWIFT_FLAGS=-disable-sandbox`；
  `swift build` / `swift test` → `--disable-sandbox`
- 看到宏的 `produced malformed response` → **先往上翻一行找 `sandbox_apply`**，别去查插件路径

## 2. 配置（configuration）：**性能数字只在优化构建下才有意义**

| 目的 | 用哪个 |
| --- | --- |
| 只想知道"编不编得过" | 默认（scheme 的 BuildAction 配置，通常是 `Debug`）—— 最快 |
| **测性能 / 复现手感 / 验证预算** | `--config Release`（或项目自定义的优化配置） |
| 单步调试 | `--config Debug` |

`xcodebuild build` 不带 `-configuration` 时用 scheme 的 BuildAction 配置。**`Debug` 是 `-Onone`** ——
在它下面测出来的帧率与耗时没有参考价值（"在 Debug 下觉得卡，不代表产品卡"）。

若项目自定义了配置（例：Marquee 的 `Dev` = 带 `.dev` 身份的优化构建），
**先 `xcodebuild -list` 看有哪些**，别猜名字。

## 3. 项目自带脚本优先

多数 macOS 项目有封装脚本，带着项目特有的前置检查（生成工程、签名核验、产物定位、
配置选择）。**先看 `scripts/`，有就用它**：

```bash
./scripts/build.sh
./scripts/test.sh
```

例（Marquee）：

```bash
./scripts/build.sh                          # 默认配置
./scripts/test.sh                           # = cd Modules && swift test --disable-sandbox
CONFIGURATION=Release ./scripts/build.sh    # 发版 / 性能

# 只在**被外部沙箱包裹的 shell**（agent 会话、某些 CI 容器）里需要：
MARQUEE_DISABLE_COMPILER_SANDBOX=1 ./scripts/build.sh
```

本技能的价值在于：① 需要**绕过**项目脚本时（临时换配置、只编一个 scheme、跑别人的仓库）；
② 遇到沙箱/宏报错时知道加什么参数（而不是去改代码）；③ 没有封装脚本的项目。

## 4. 跑起来（不只是构建）

```bash
open DerivedData/Build/Products/Dev/Foo.app
open -a Foo.app --args -someFlag
```

> 需要权限（屏幕录制、辅助功能）的 app，**用 `open -a` 而不是直接 exec 可执行文件** ——
> 直接 exec 时 TCC 可能把这次访问算在父进程（终端）头上，于是登记的是终端而不是这个 app。

## 5. 失败签名

| 症状 | 真正的原因 | 处置 |
| --- | --- | --- |
| `external macro implementation type '…' could not be found ... produced malformed response` | 上一行必有 `sandbox-exec: sandbox_apply: Operation not permitted`。**后一句是症状，前一句才是根因** | 加逃逸参数（§1） |
| `Could not resolve package dependencies` | 网络 / 代理。远程 SPM 依赖要出网 | **不自动开代理** —— 代理配置在会话外，先问用户；本地路径包不联网 |
| 构建成功但 app 一跑就崩 / 权限反复索要 | 签名身份不稳（ad-hoc） | `codesign -dvvv Foo.app` 看 `Authority=` / `TeamIdentifier=` |
| 改了 bundle id 后屏幕录制授权留不住 | TCC 按「bundle id + 签名身份」记账 | **预期行为**，重新授权即可（换身份就是新的一条） |
| 产物在 `~/Library/Developer/Xcode/DerivedData/<带哈希>` 找不到 | 默认 DerivedData 位置 | 用 `-derivedDataPath` 固定（脚本默认钉到 `<cwd>/DerivedData`） |

## 6. 写脚本 / 解析输出时的环境坑

**这段知识的正文只有一份，在独立技能 `shell-portability` 里**（项目 `.workbuddy/skills/`
或用户级 `~/.workbuddy/skills/`）：两套 `grep` 语义、三条硬规则、`sed -i` 的两套语义、
`$var` 后紧跟全角字符、heredoc 配 `set -e` 的写法、逃生舱、以及自查命令。

本技能只留两条与**构建日志**直接相关的：

| 坑 | 正解 |
| --- | --- |
| 想"只看关键行" | `grep -E "error:|warning:|\*\* .* \*\*" \| tail -40`；**别把上千行日志整段贴回来** |
| 失败时的读法 | **先看第一条 `error:`**，不要先看最后一条（后面常是级联噪声） |

本技能的 `scripts/*-run.sh` 已在开头把 shim 目录从 PATH 摘掉，脚本内语义恒定 ——
自己写脚本时照抄那段，或直接看 `shell-portability` 的 §2。

## 7. 与其他技能的分工

- **iOS**（模拟器 / 真机）→ 用 `ios-build-test`
- **沙箱判据与逃逸参数** → 用 `apple-build-sandbox`（两个 build 技能共用同一份，不各自重写）
- **shell 两套语义** → 用 `shell-portability`
- 本技能只管 macOS host 与 SwiftPM 的**流程与失败签名**。

平台细节见 `references/macos.md`。

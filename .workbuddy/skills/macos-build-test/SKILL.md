---
name: macos-build-test
description: This skill should be used for any macOS-side build or test task on this machine — building/testing a macOS app or command-line target with `xcodebuild`, running a SwiftPM package's `swift build|test`, choosing a build configuration (Debug/Dev/Release), or diagnosing "Xcode 编不过 / 构建失败" when the cause is the sandboxed environment rather than the code (e.g. `swift-plugin-server ... produced malformed response`, `sandbox_apply: Operation not permitted`). Trigger it on requests like "build 一下"、"编译看看"、"跑一下测试"、"跑一遍 test.sh", or when a repo such as Marquee's needs its scheme built. It carries the sandbox-escape parameters this environment requires and the configuration semantics that make performance numbers meaningful.
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

本 agent 会话的 shell 通常已在受限 profile 里，macOS 不允许在受限进程里再 apply 一层
deny-default 沙箱。凡是"会自己再套沙箱"的工具都会失败 —— 最典型的是 **Swift 宏**
（`swift-plugin-server` 跑 `@State` 这类宏）。

**判据（一条命令，别猜）**：

```bash
sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok
# ✅ 可 apply → 不需要参数
# ❌ 本环境实测：sandbox_apply: Operation not permitted，退出码 71 → 需要逃逸
```

**逃逸参数（只加在命令行上）**：

| 工具 | 参数 |
| --- | --- |
| `xcodebuild` | `OTHER_SWIFT_FLAGS=-disable-sandbox` |
| `swift build` / `swift test` | `--disable-sandbox` |

`macos-run.sh` 在需要时**自动加上**。

> ⚠️ Xcode 社区常推的那三个 —— `-IDEPackageSupportDisableManifestSandbox=1`、
> `-IDEPackageSupportDisablePluginExecutionSandbox=1`、`ENABLE_USER_SCRIPT_SANDBOXING=NO`
> —— **本环境实测无效**：它们关的是**内层**沙箱，外层那次 apply 本身就被拒。
> 有效的是 `swiftc` 自己的 `-disable-sandbox`（`xcrun swiftc -help-hidden | grep sandbox`）。
>
> ⚠️ **绝不把它写进工程文件**（`project.yml` / `.pbxproj` / `Package.swift` / scheme）：
> 那会削弱正常终端与发版构建的隔离。它只属于"这一次命令"。

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

## 6. 写脚本 / 解析输出时的环境坑（本机实测）

**先记住一件事：`grep` / `sed` 在这个环境有两套实现。** agent 会话的 PATH 首部是
WorkBuddy 的 shim 目录，`grep sed find ls head tail cat wc …` 被换成 **toybox 0.8.13**；
你自己的终端里是 BSD grep 2.6.0。shim **只在 stderr 出现 `Unknown option` 时
才回退**到真工具 ⇒ **语义差异不触发回退，而是静默失配**。

| 写法 | toybox（agent 会话） | BSD（你的终端） |
| --- | --- | --- |
| BRE 交替 `grep 'a\|b'` | ❌ **静默 rc=1** | ✅ 命中 |
| ERE 交替 `grep -E` + 裸竖线 | ✅ | ✅ |
| `\s` 简写 `grep -E 'a\sb'` | ❌ **静默 rc=1** | ✅ 命中 |
| POSIX 类 `grep -E 'a[[:space:]]b'` | ✅ | ✅ |
| `sed -i 's/a/b/' f` | ✅ | ❌ unterminated substitute |
| `sed -i '' 's/a/b/' f` | ❌ 把 `''` 当文件名 | ✅ |

**三条硬规则（跨环境唯一安全写法）：**

1. 永远 `grep -E`，交替用裸竖线 —— **永不写 BRE 的 `\|`**
2. 字符类只用 POSIX（`[[:space:]]` / `[[:digit:]]`）—— **永不写 `\s` `\d` `\w`**
3. **`sed -i` 两边语义相反 ⇒ 一律不用**：写临时文件再 `mv`，或用 python3

**逃生舱**（只对只读命令）：`CODEBUDDY_TOYBOX_BIN= grep 'a\|b' file` → 本条走真 BSD 工具。
⚠️ 它同时绕开 shim 的分发层，**别用于写 / 删命令**（safe-delete 与写入前备份会失效）。
本技能的 `scripts/*-run.sh` **已在开头把 shim 目录从 PATH 摘掉**，脚本内语义恒定 —— 自己写脚本时照抄那段。

| 坑 | 正解 |
| --- | --- |
| `set -u` + 可能为空的数组 | bash 3.2 下 `"${arr[@]}"` 会报 unbound → 写 `${arr[@]+"${arr[@]}"}` |
| 想"只看关键行" | `grep -E "error:|warning:|\*\* .* \*\*" \| tail -40`；**别把上千行日志整段贴回来** |
| 失败时的读法 | **先看第一条 `error:`**，不要先看最后一条（后面常是级联噪声） |

## 7. 与其他技能的分工

- **iOS**（模拟器 / 真机）→ 用 `ios-build-test`
- 本技能只管 macOS host 与 SwiftPM；两者共享同一套"嵌套沙箱"判据，但各自自包含，可单独使用。

平台细节见 `references/macos.md`。

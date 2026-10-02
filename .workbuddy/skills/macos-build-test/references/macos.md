# macOS 侧（本机 host）

## 最小命令

```bash
S=~/.workbuddy/skills/xcode-build-test/scripts/xcode-run.sh

$S macos --project Foo.xcodeproj --scheme Foo build
$S macos --project Foo.xcodeproj --scheme Foo test
$S macos --project Foo.xcodeproj --scheme Foo --config Release build
```

等价的手写命令（当需要用项目脚本、或要加别的参数时）：

```bash
xcodebuild -project Foo.xcodeproj -scheme Foo \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  build
```

- destination 在 macOS 上**只有一个形态**：`platform=macOS`。不要传 `name=My Mac`
  （机器名会变，`-showdestinations` 里那两个 macOS 条目哪一个都能用 `platform=macOS` 命中）。
- `OTHER_SWIFT_FLAGS=-disable-sandbox` **只在需要时加** —— 先跑 `$S probe` 看判据。
- **不要** `clean`：增量构建通常几秒。怀疑缓存坏了才删 `DerivedData/`。

## 先确认工程长什么样（不知道 scheme 名时的第一步）

```bash
ls -d */*.xcodeproj */*.xcworkspace 2>/dev/null
xcodebuild -list -project Foo.xcodeproj     # targets / configurations / schemes 一次看清
```

`-list` 比翻 `project.pbxproj` 快得多，而且能看到**有哪些 configuration**
（决定 `--config` 该写什么）。

## 配置（configuration）怎么选

`xcodebuild build` 不带 `-configuration` 时用 **scheme 的 BuildAction 配置**，
而那个往往是 `Debug`。Debug 是 `-Onone`：

- **只想知道"编不编得过"** → 默认即可，最快
- **要看性能数字 / 复现手感** → **必须** `--config Release`（或项目自定义的优化配置）
  —— `-Onone` 下的帧率与耗时没有参考价值
- 三个配置语义的完整讨论见 Marquee 的 `docs/DEV-VS-PROD.md`（`Debug` / `Dev` / `Release`）

## 项目自带脚本优先

多数 macOS 项目有封装脚本，它带着项目特有的前置检查（生成工程、签名核验、
配置选择、产物定位）。**先看有没有，有就用它**：

```bash
ls scripts/
```

例（Marquee）：

```bash
./scripts/build.sh                          # 默认配置
./scripts/test.sh                           # = cd Modules && swift test --disable-sandbox
CONFIGURATION=Release ./scripts/build.sh    # 发版 / 性能

# 只在**被外部沙箱包裹的 shell**（agent 会话、某些 CI 容器）里需要：
MARQUEE_DISABLE_COMPILER_SANDBOX=1 ./scripts/build.sh
```

## macOS 特有的坑

| 现象 | 原因 / 处置 |
| --- | --- |
| 构建成功但 app 一跑就崩、或权限反复索要 | 签名身份不稳定（ad-hoc）。用 `codesign -dvvv Foo.app` 看；正常应有 `Authority=` 与 `TeamIdentifier=` |
| 改了 bundle id 之后屏幕录制授权留不住 | TCC 按「bundle id + 签名身份」记账，**换身份就是新的一条**，要重新授权；这是预期行为 |
| 想跑 app 但它在 `~/Library/Developer/Xcode/DerivedData/<带哈希的目录>` | 用 `-derivedDataPath` 固定（本技能脚本默认钉到 `<cwd>/DerivedData`） |
| `Codesign error: resource fork ... detritus` | 通常是 `xattr`/`.DS_Store` 混进了资源目录，清掉再编 |

## 跑起来（不只是构建）

```bash
open DerivedData/Build/Products/Dev/Foo.app
open -a Foo.app --args -someFlag          # 带启动参数（LaunchServices 启动，TCC 才对）
```

> 需要权限（屏幕录制、辅助功能）的 app，**用 `open -a` 而不是直接 exec 可执行文件** ——
> 直接 exec 时 TCC 可能把这次访问算在父进程（终端）头上。

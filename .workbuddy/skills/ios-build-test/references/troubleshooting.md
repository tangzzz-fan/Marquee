# iOS 排查手册

## 真机：签名与描述文件

真机构建失败几乎都在这两件事上。**先问一句"是不是非要上真机"** —— 绝大多数构建与测试
在模拟器上就能做，而模拟器**不需要任何签名**。

```bash
# 自动签名（推荐）：让 Xcode 去更新描述文件
xcodebuild ... -allowProvisioningUpdates build

# 看这台机器有哪些签名身份
security find-identity -v -p codesigning

# 看产物签名
codesign -dvvv Foo.app | grep -E "Authority|TeamIdentifier"
```

常见报错与含义：

| 报错 | 含义 |
| --- | --- |
| `No signing certificate "iOS Development" found` | 钥匙串里没有对应证书（或没被信任） |
| `Provisioning profile "…" doesn't include signing certificate` | 描述文件与证书不配对 |
| `The device is not registered in your developer account` | 新机器/新设备要先注册（或开自动签名） |
| `Unable to install … (The application's bundle identifier is not unique)` | 装了两份同 id 的包（常见于 debug/release 混装） |

> 想**跳过签名只验编译**（模拟器场景常用）：加 `CODE_SIGNING_ALLOWED=NO`。
> 这是最快的"编得过得吗"检查，但它**不能替代**真机安装验证。

## 模拟器状态机

```bash
xcrun simctl list devices available          # 人读
xcrun simctl list devices available --json   # 机读（解析用这个）

xcrun simctl boot <udid>                     # 启动
xcrun simctl shutdown all                    # 全部关机（卡住时的第一招）
xcrun simctl erase <udid>                    # 抹掉该模拟器数据（第二招）
open -a Simulator                            # 打开模拟器 UI
```

`xcodebuild` 通常会**自动启动**目标模拟器，所以一般不需要手动 boot。
只有当它报 `Unable to boot device in current state: Booted`（已经在跑）或长时间无响应时，
才需要介入：`shutdown all` → 重新跑。

```
# 装 / 卸 / 启动 app（不经 Xcode）
xcrun simctl install <udid> path/to/Foo.app
xcrun simctl launch <udid> com.example.Foo
xcrun simctl uninstall <udid> com.example.Foo
```

## 拿运行日志（app 崩了、行为不对时）

```bash
# 看某台模拟器的实时日志（按 subsystem 过滤更有效）
xcrun simctl spawn <udid> log stream --level debug \
  --predicate 'subsystem == "com.example.Foo"'

# 崩了的话
ls -t ~/Library/Logs/DiagnosticReports/ | head
```

> `log stream` 的 `--predicate` 用 **subsystem**（不是 bundle id）—— 前提是代码里
> 用 `Logger(subsystem:category:)` 且 subsystem 稳定。这一条在 macOS 侧同样适用。

## 测试报告（xcresult）

```bash
xcodebuild ... test -resultBundlePath /tmp/Foo.xcresult

# 概览
xcrun xcresulttool get --path /tmp/Foo.xcresult --format json | head -40
# 失败的用例
xcrun xcresulttool get --path /tmp/Foo.xcresult --format json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("actions",{}), ensure_ascii=False, indent=2))' | head -60
```

报告里最有价值的两样：**失败断言的原始输出**与**附件（失败截图）**。
只贴 `Test Case '-[X y]' failed` 这一行，等于没有信息。

## 快慢与取舍

| 做法 | 效果 |
| --- | --- |
| `--only-testing` | 只跑指定用例，最快 |
| 增量构建（不清 DerivedData） | 第二次通常快 5–10 倍 |
| `clean build` | 只在怀疑缓存坏了时用（它会让你付出一次全量编译） |
| `-quiet` | 少打日志；**但失败时也少信息**，排查阶段别用 |
| `build-for-testing` + `test-without-building` | 分两步：CI 上先编一次、再多设备跑 |

```bash
# 分两步的典型用法（省一次编译）
xcodebuild ... build-for-testing
xcodebuild ... test-without-building --only-testing FooTests/BarTests
```

## 自检：确认本技能在这台机器上仍然可用

技能依赖三件会变的事 —— 沙箱形态、模拟器清单、工具链路径。**改动环境后（或怀疑技能失效时）**
跑一次这个最小闭环，全部通过才说明技能是好的：

```bash
# ① 沙箱判据（决定要不要逃逸）
sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok
#    本环境预期：sandbox_apply: Operation not permitted（退出码 71）

# ② 造一个含 @State 的最小 iOS 工程（宏 = 必须走逃逸那条路）
mkdir -p /tmp/iosprobe/Sources && cd /tmp/iosprobe
cat > project.yml <<'YML'
name: ProbeApp
options: { bundleIdPrefix: dev.tango, deploymentTarget: { iOS: "18.0" } }
targets:
  ProbeApp:
    type: application
    platform: iOS
    sources: [Sources]
    info:
      path: Info.plist
      properties: { UILaunchScreen: {}, CFBundleVersion: "1", CFBundleShortVersionString: "1.0" }
YML
cat > Sources/ContentView.swift <<'SWIFT'
import SwiftUI
struct ContentView: View {
    @State private var count = 0            // ← 宏：没有逃逸参数这里就编不过
    var body: some View { Text("\(count)") }
}
SWIFT
cat > Sources/ProbeApp.swift <<'SWIFT'
import SwiftUI
@main struct ProbeApp: App { var body: some Scene { WindowGroup { ContentView() } } }
SWIFT
xcodegen generate

# ③ 正例：应当 BUILD SUCCEEDED
~/.workbuddy/skills/ios-build-test/scripts/ios-run.sh build \
  --project ProbeApp.xcodeproj --scheme ProbeApp

# ④ 反例：手工不加逃逸参数，应当 BUILD FAILED 且日志里有 sandbox_apply
xcodebuild -project ProbeApp.xcodeproj -scheme ProbeApp \
  -destination "id=$(xcrun simctl list devices available --json | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print([x["udid"] for r in sorted(d,reverse=True) for x in d[r] if "iPhone" in x["name"]][0])')" \
  -derivedDataPath DerivedData build ; echo "exit=$?"

rm -rf /tmp/iosprobe                        # 用完清掉
```

**2026-10-03 实测结果**（本机 Xcode 27 / iOS 27.0 SDK）：

| 步骤 | 结果 |
| --- | --- |
| ① 沙箱判据 | `sandbox_apply: Operation not permitted`（71）⇒ 需要逃逸 |
| ③ 带逃逸 | **BUILD SUCCEEDED** |
| ④ 不带逃逸 | **BUILD FAILED**（exit 65，日志含 `sandbox_apply: Operation not permitted`） |
| 按机型名 / 按 UDID / 自动挑 | 三种 destination 形态均 **BUILD SUCCEEDED** |

> ③ 与 ④ 的对比就是**这个技能存在的理由**：参数不是可选的。

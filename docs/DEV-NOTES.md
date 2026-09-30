# 开发循环中的已知摩擦

记录那些"每次都会踩、但又不值得单独开一条 ticket"的开发环境问题。

---

## 1. 屏幕录制权限留不住（ad-hoc 签名）——**已修复**

**现象**：每次重新构建后运行，macOS 都重新要一次屏幕录制授权；用户勾选过也不管用。

**根因（两级）**：

1. **签名身份不稳定**。TCC 按「bundle id + 代码签名身份」记账，
   而 XcodeGen 生成的工程默认走 ad-hoc（`CODE_SIGN_IDENTITY: "-"`）——
   ad-hoc 没有身份，系统退回按 **cdhash** 记账，每次重新构建 cdhash 都变，
   macOS 就把新构建当成一个**新应用**。
2. **我们自己的"已请求过"标记会把用户锁死**（这条更隐蔽，2026-09-30 才发现）。
   旧实现用一个持久化的 `permission.screenRecording.requested` 标记，
   在 `CGPreflightScreenCaptureAccess()` 返回 false 时推断出 `.denied`。
   但签名一变，TCC 与该身份相关的状态被重置，**我们的标记却还留着** ——
   于是我们再也不调 `CGRequestScreenCaptureAccess()`；
   而 macOS 只在应用**调用采集 API 时**才把它登记进「屏幕录制」列表，
   结果：**列表里没有 Marquee → 用户无从授权 → 每次按快捷键都只看到提示，永远出不来**。

**修复**：

- `scripts/build.sh` 在构建后用证书**重签一次**（`MARQUEE_SIGN_IDENTITY` 可覆盖，
  `MARQUEE_SKIP_RESIGN=1` 可跳过）。签名身份稳定后，授权跨构建保留。
- `SystemScreenRecordingPermission` **不再声称 `.denied`**：
  preflight 为 false 时一律报 `.notDetermined`，交给上层去调一次系统请求。
  真被拒绝时该调用不弹框、直接返回 false，代价可忽略；
  已授权但当前进程未生效时会返回 true，于是能走「请重启应用」的正确分支。

**代价（要如实告诉用户）**：从 ad-hoc 换成证书的**第一次**仍会再弹一次授权（身份变了），
之后就不该再弹。**授权后必须退出并重新打开应用**，macOS 才认。

**其他注意**：

- 证书有有效期（Apple Development 一年）。证书续期后身份会变，需要重新授权一次。
- 派生数据路径固定也有助于减少漂移；但真正起作用的是**签名身份稳定**。
- 不要为了让它在开发机上"不弹窗"而放宽代码里的权限检查逻辑 —— 权限路径必须保持真实。

**排障入口**：
```bash
Marquee.app/Contents/MacOS/Marquee -marqueeDiagnostics
```
打印权限状态、`preflight` 原始值、当前快捷键、注册结果、**构建签名身份**（team / 证书数）。
"权限为什么留不住"的第一手证据就是最后一行。

---

## 2. `.xcodeproj` 不入库

`.xcodeproj` 由 `project.yml` 生成，已加入 `.gitignore`。
**首次 clone 后必须先 `xcodegen generate`**，否则 `xcodebuild` 会找不到 scheme。

改工程配置（依赖、target、build settings）一律改 `project.yml`，不要改动生成的工程文件 —— 改了下一次生成就没了。

---

## 3. 模块单元测试不需要 Xcode 工程

`Modules/` 是独立的 SPM 包，`swift test` 即可跑，比走 `xcodebuild test`
快很多。日常开发用这条路径；只有在验证 App 层时才需要生成工程。

---

## 4. deny-default 沙箱在本机宿主环境无法应用（构建阻塞项）

**症状**：`xcodebuild` 解析本地 SPM 包时报

```
xcodebuild: error: Could not resolve package dependencies:
  sandbox-exec: sandbox_apply: Operation not permitted
```

**根因**（已逐条实测，不是猜测）：

| 命令 | 结果 |
| --- | --- |
| `sandbox-exec -p '(version 1)(allow default)' /bin/echo ok` | ✅ 正常 |
| `sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok` | ❌ `Operation not permitted` |

- SwiftPM 给 `Package.swift` 求值套的正是 **deny-default** 形态的沙箱
- **与网络无关**：本地路径包不联网，`proxy_on` 不解决任何问题
- **与工具沙箱无关**：在完全关闭沙箱的情况下（可写用户目录已实测）依然失败
- 本质是宿主进程自身已处于受限 profile，而 macOS 不允许在受限进程中再套一层不同形态的沙箱

**解法**（二选一，已选第一条）：

```bash
# 方案 A（当前采用）：打开 Xcode 的 manifest 求值沙箱开关
defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
# 回退：
defaults delete com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox
```

- 影响范围：仅 `Package.swift` 的求值沙箱。本地自写包，风险可忽略
- `scripts/build.sh` 会检查该设置，缺失时直接报错而不是让你对着莫名其妙的失败排查

```bash
# 方案 B（未采用）：去掉 Xcode 对 SPM 本地包的依赖，模块改成 6 个独立 Xcode target
# 代价：偏离 PRD 的 SPM 模块化决策，且 swift test 快跑循环要改成 xcodebuild test
```

**结论**：所有构建走 `scripts/build.sh`，所有测试走 `scripts/test.sh`，
不要再手敲裸命令 —— 参数是必需的，不是可选的。


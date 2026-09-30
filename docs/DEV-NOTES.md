# 开发循环中的已知摩擦

记录那些"每次都会踩、但又不值得单独开一条 ticket"的开发环境问题。

---

## 1. ad-hoc 签名与屏幕录制权限的反复授权

**现象**：用 XcodeGen 生成的工程默认走 ad-hoc 签名（`CODE_SIGN_IDENTITY: "-"`）。
TCC 的屏幕录制授权是按「bundle id + 代码签名」记账的，而每次重新构建都会改变 cdhash，
于是 macOS 可能把新构建出来的应用当成一个"新应用"，重新弹权限、甚至需要重新勾选。

**影响**：在 ticket 02 之后，每次改代码重新构建都可能要重走一次授权流程，磨掉开发节奏。

**处理**：

- 短期：把 `DerivedData` 下的构建产物路径固定，减少签名漂移；必要时手动在系统设置里保持勾选。
- 若摩擦过大：用钥匙串创建一个本机自签证书（如 `Marquee Local Dev`），
  在 `project.yml` 里把 `CODE_SIGN_IDENTITY` 指向它。签名稳定后 TCC 授权就能持久。
- 正式签名与公证见 ticket 18。

**注意**：这条不是产品缺陷，是开发循环的摩擦。不要为了让它在开发机上"不弹窗"而
放宽代码里的权限检查逻辑 —— 权限路径必须保持真实。

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


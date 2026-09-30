# 开发循环中的已知摩擦

记录那些"每次都会踩、但又不值得单独开一条 ticket"的开发环境问题。

---

## 1. 屏幕录制权限留不住 / 列表里找不到 Marquee / 授权框连弹 ——**已修复**

完整复盘（现象、四层根因、当前设计、验证步骤、残留项）见
[`docs/SCREEN-RECORDING-PERMISSION.md`](SCREEN-RECORDING-PERMISSION.md)。
下面只留开发时会反复撞上的操作要点。

**现象**：每次运行都要重新授权屏幕录制；勾选过也不管用；有时系统设置里**根本找不到 Marquee 这一行**。

**根因是三层**，一层比一层隐蔽：

1. **签名身份不稳定**。TCC 按「bundle id + 代码签名身份」记账，
   而工程默认走 ad-hoc（`CODE_SIGN_IDENTITY: "-"`）——
   ad-hoc 没有身份，系统退回按 **cdhash** 记账，每次重新构建 cdhash 都变，
   macOS 就把每次构建当成一个**新应用**。
2. **修复只放在构建脚本里等于没修**。第一版把"用证书重签"写进了 `scripts/build.sh`，
   但开发时从 **Xcode Run** 才是常态，而 Xcode 的构建**不执行**这个脚本 ——
   产物又变回 ad-hoc，问题原样复现。**签名必须由工程本身负责**（`project.yml`）。
3. **只调 `CGRequestScreenCaptureAccess()` 不足以让应用出现在列表里**。见下一节。

**修复**：

- **签名由 `project.yml` 负责**：`CODE_SIGN_STYLE: Automatic` +
  `CODE_SIGN_IDENTITY: "Apple Development"` + `DEVELOPMENT_TEAM: UKXWZ3FS84`。
  这样无论 `xcodebuild` 还是 Xcode GUI 构建，产物都是证书签名的。
- ⚠️ **`DEVELOPMENT_TEAM` 必须填真正的 team id**。别把证书名括号里那串抄进来：
  `security find-identity` 显示的是 `Apple Development: zhenzhi Tang (7H6TJ2PN25)`，
  但那串是**证书自身的标识**，不是 team id。填错会报
  `No signing certificate "Mac Development" found: … matching team ID "7H6TJ2PN25"`。
  判定方法：签完之后 `codesign -dvvv` 看 `TeamIdentifier=`（本机是 `UKXWZ3FS84`）。
- `scripts/build.sh` 现在只做**核验**（发现退回 ad-hoc 就警告，可用
  `MARQUEE_SIGN_IDENTITY=...` 强制重签），不再盲目重签 —— 否则会掩盖"工程配置被改坏"。
- `SystemScreenRecordingPermission` **不再声称 `.denied`**：
  preflight 为 false 时一律报 `.notDetermined`，交给上层去调一次系统请求。
  真被拒绝时该调用不弹框、直接返回 false，代价可忽略；
  已授权但当前进程未生效时会返回 true，于是能走「请重启应用」的正确分支。
- **`requestPermission()` 里必须真的碰一次采集 API**（`SCShareableContent` 枚举即可），
  理由见第 1.1 节。**不要在这里截一帧**，见第 1.3 节。

### 1.1 系统设置里找不到 Marquee 是怎么回事

macOS **只在应用实际调用采集 API 时**才把它登记进「屏幕录制」列表。
如果权限门拦在采集之前、而"请求权限"又只调了 `CGRequestScreenCaptureAccess()`，
应用就可能**从未出现在列表里** —— 用户翻遍系统设置也找不到可勾选的行，**永远授权不了**。

所以 `SystemScreenRecordingPermission.requestPermission()` 里两步都要做：

1. `_ = try? await SCShareableContent.excludingDesktopWindows(...)` —— 只为"被系统看见"这个副作用，
   结果不看（没权限时本来就拿不到内容）。**到此为止，不要再截一帧。**
2. `CGRequestScreenCaptureAccess()` —— 拿权威结论（同一会话里若第 1 步已经弹过框，这里通常不再弹）

权限提示框也相应加了一个「在 Finder 中显示」按钮：
真遇到列表里没有的情况，用户可以直接把 app 拖进列表，不用去 DerivedData 里翻路径。

### 1.2 代价与善后

- 从 ad-hoc 换成证书的**第一次**仍会再弹一次授权（身份变了），之后不该再弹。
  **授权后必须退出并重新打开应用**，macOS 才认。
- 证书有有效期（Apple Development 一年）。证书续期后身份会变，需要重新授权一次。
- 如果系统设置里出现了**多个 Marquee 条目**（历史 ad-hoc 构建留下的），
  可以一次性清掉这个 bundle id 的全部记录再重新授权：

  ```bash
  tccutil reset ScreenCapture dev.tango.Marquee
  ```

- 不要为了让它在开发机上"不弹窗"而放宽代码里的权限检查逻辑 —— 权限路径必须保持真实。

### 1.3 按一次快捷键叠出多张系统授权框 ——**已修复**

**现象**：点截屏快捷键后，系统「屏幕录制」授权框一张接一张地弹。

**根因是三层叠在一起**：

1. `requestPermission()` 里除了枚举 `SCShareableContent`、调 `CGRequestScreenCaptureAccess()`，
   还真的走了一次 `SCScreenshotManager.captureImage`。macOS 15+ 把每次采集尝试都当成新的授权请求，
   **一次快捷键就能叠出两到三张系统框**。
2. 真实探针在 preflight 为 false 时一律报 `.notDetermined`。macOS 15+ 上即使用户已经去
   系统设置勾过，重启前 preflight 也会一直是 false —— 于是**每一次**快捷键都再走一遍第 1 步。
3. 刚授权成功后宿主仍弹出覆盖层并采集。ScreenCaptureKit 在授权的同一个进程里还不可用，
   这次采集会再弹一张系统框，并且必然失败。

**修复**：

- 登记进列表只枚举 `SCShareableContent`，不再截帧。
- 进程内记住"已经问过"（**不要**写 UserDefaults，见第 1 节开头）：问过仍未授权就报 `.denied`，
  后续快捷键走「打开系统设置」而不是再弹系统框。
- 本次进程刚授权成功 → 只提示重启，不弹出覆盖层、不采集。

**验证签名是否稳定**：`codesign -dvvv <app>` 应看到 `flags=0x0(none)`（不是 `0x2(adhoc)`）、
`Authority=Apple Development: …`、`TeamIdentifier=UKXWZ3FS84`。

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

### 2.1 scheme 必须在 `project.yml` 里显式声明

**症状**：`xcodebuild -scheme Marquee` 报
`The project named "Marquee" does not contain a scheme named "Marquee"`，
而 `xcodebuild -list` 里 `Schemes:` 是空的。

**根因**：之前能构建是**碰巧** —— Xcode 打开工程时会自动创建一个**用户级** scheme
（放在 `xcuserdata/` 里）。`xcodegen generate` 重新生成工程后它就不在了。
依赖这种自动生成物的代价是：构建能否成功取决于你之前有没有用 Xcode 打开过这个工程。

**修法**：在 `project.yml` 里声明**共享** scheme（生成到 `xcshareddata/xcschemes/`），
见 `project.yml` 顶部的 `schemes:` 段。这样每次生成结果都确定，谁 clone 下来都能直接构建。

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

| 命令                                                                           | 结果                          |
| ---------------------------------------------------------------------------- | --------------------------- |
| `sandbox-exec -p '(version 1)(allow default)' /bin/echo ok`                  | ✅ 正常                        |
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

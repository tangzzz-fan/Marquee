# 打包、公证与更新（ticket 18）

> 归属：ticket 18。走 **Developer ID 公证分发**，**不上 Mac App Store**
> —— 沙盒会约束滚动截屏等系统级能力（PRD 已定）。

## 1. 一次性准备

| 项 | 命令 / 位置 | 怎么判断成了 |
| --- | --- | --- |
| Developer ID Application 证书 | `security find-identity -v -p codesigning \| grep "Developer ID Application"` | 打出一行带证书名的结果 |
| 公证凭据 | `xcrun notarytool store-credentials "marquee-notary" --apple-id <Apple ID> --team-id UKXWZ3FS84 --password <App 专用密码>` | `xcrun notarytool history --keychain-profile marquee-notary` 不报错 |
| Xcode 沙箱开关 | `defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES` | 见 `docs/DEV-NOTES.md` 第 4 节 |

**App 专用密码不是 Apple ID 登录密码** —— 在 appleid.apple.com →「登录与安全」→「App 专用密码」生成。
凭据存进钥匙串，脚本按 profile 名引用，**不落明文**。

## 2. 出包

```bash
./scripts/package.sh                 # 版本取 project.yml
VERSION=0.2.0 ./scripts/package.sh   # 临时指定
```

七步，每步都能单独判断成败：

| 步 | 做什么 | 失败时看什么 |
| --- | --- | --- |
| 1 | `xcodegen generate` | 工程定义写错了 |
| 2 | `xcodebuild archive`（Release） | 编译错误；**必须在普通终端跑**（沙箱问题见 `build.sh`） |
| 3 | `-exportArchive`（`method=developer-id`） | 证书 / team 不对 |
| 4 | `codesign --verify --strict` | **这一步不过就不要往下** —— 公证必被拒，而拒信要等几分钟才回来 |
| 5 | `notarytool submit --wait` | 凭据失效、或有未签名的嵌套二进制 |
| 6 | `stapler staple` + `spctl --assess` | 装订失败说明第 5 步其实没过 |
| 7 | `hdiutil` 打 DMG，再对 DMG 本身签 + 公证 + 装订 | 漏了对 DMG 的公证时，**打开 dmg 那一步**会被拦 |

### 为什么 DMG 自己也要签 + 公证

分发的是 DMG，用户拿到的第一个动作是"打开 dmg"。只公证里面的 `.app` 的话，
`spctl` 在挂载那一步就会拦 —— 而现象是"下载的包打不开"，看起来像下载损坏。

### 为什么先 zip 再公证、最后还要装订

- `notarytool` 收的是压缩包；先用 zip 上传比直接传 DMG 快，失败重试也便宜。
- **装订（staple）不是可选项**：它把公证票据贴进包本体，于是用户**离线**也能通过
  首次校验。不装订的话，"有的人能打开、有的人不能"—— 那是最难查的一类反馈。

## 3. 验收（必须做的一条）

在**一台没装开发环境的 Mac** 上：

1. 双击 DMG → 拖进 Applications
2. 双击打开 → **不该出现「无法验证开发者」**
3. 第一次按 `⌃Q` → 屏幕录制授权引导 → 授权 → 重启应用 → 能截

> 在你自己机器上它**一定**是过的（钥匙串里有证书、TCC 里已经记过），
> 那不构成证据。这一条只能靠另一台机器。

## 4. 版本号与更新

### 版本号

- `project.yml` 里的 `MARKETING_VERSION`（`CFBundleShortVersionString`）
- `CFBundleVersion` 每次出包递增（脚本传 `MARKETING_VERSION`，构建号交给 Xcode 自增）

### 更新机制：**手动更新为主**（诚实说明）

ticket 18 的验收项是"能从旧版本检测到新版本并完成更新（**或至少给出清晰的手动更新指引**）"。
本项目选**后者**，理由：

- 自动更新要引入 Sparkle 之类的框架，它会带来**第二个需要签名的可执行文件**、
  一套 appcast 签名密钥、以及"更新器自身被替换"这类安全面。那不是这一轮该背的东西。
- 这个工具的更新频率不高，手动更新一次的代价远小于上面那套机制的长期成本。

**手动更新指引**（写进发布说明即可）：

1. 下载新的 DMG，拖进 Applications 覆盖旧版本。
2. 覆盖后**屏幕录制授权会重新索要一次** —— 因为签名身份虽然没变，
   但 TCC 在部分系统版本上会因 bundle 变化重新判定。这是系统行为，不是缺陷。
3. 最近截图（`~/Library/Application Support/Marquee/history/`）与偏好都会保留：
   它们在应用沙盒之外，覆盖安装不会动。

### 若以后要做自动更新

最小可用形态是一个 `appcast.json`（版本号 + DMG 的 URL + EdDSA 签名）+
启动时拉一次 + 提示"有新版本"并跳到下载页。**先做提示、不做静默替换**：
静默替换一旦出问题（下载中断、签名不匹配），用户手上会是一个坏掉的 app。

## 5. 已记录的数字

出包后把这两个数补到这里（ticket 18 明确要求记录）：

| 项 | 值 |
| --- | --- |
| 包体大小（DMG） | 待填（跑一次 `./scripts/package.sh` 会打印） |
| 最低系统版本 | macOS 15.0（`project.yml` 的 `deploymentTarget`） |
| 需要的受限权限 | 屏幕录制（必须）；**辅助功能**（只有自动滚动用，按需申请，拒绝即退回手动） |
| 不申请的权限 | 麦克风、摄像头、通讯录、定位 —— 一个都不用 |

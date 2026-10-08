#!/usr/bin/env bash
#
# 打一个**能上传到 App Store Connect** 的 Marquee（`MAS` 配置，**带沙盒**）。
#
#   归档（MAS）→ 导出（app-store）→ 上传前预检 → 打印 .pkg 路径
#
# ── 为什么不复用 package.sh ─────────────────────────────────────────────
#
# `scripts/package.sh` 是 **Developer ID** 那条路（`method: developer-id`，打成 DMG 给人下载），
# 它**刻意不带沙盒** —— 那条路存在的全部价值就是保住自动滚动（沙盒禁止向其它 app 投递输入事件）。
# 而 App Store **要求沙盒**。拿 Developer ID 的归档去上传，会在上传环节被拒。
# 两条路并存、互不替代：
#
#   Developer ID  → scripts/package.sh       → DMG（自己分发）
#   App Store     → scripts/package-mas.sh   → .pkg（上传 ASC）
#
# ⚠️ 归档**必须用 `MAS` 配置**。用 `Release` 归档出来的包没有沙盒 ——
#    这是本项目最容易"看起来成功了但结果不能用"的一步，所以下面预检第 2 步专门核它。
#
# ── 一次性准备（两张证书 / 一个账号 / 一个设置）─────────────────────────
#
# 1) **两张证书，不是一张**：
#
#      security find-identity -v -p codesigning | grep "Apple Distribution"
#      security find-identity -v | grep -i installer | grep -vi "Developer ID"
#
#    · `Apple Distribution`         —— 签 app 本体
#    · `Mac Installer Distribution` —— 签导出时生成的 .pkg 安装包
#
#    ⚠️⚠️ **同一张证书有两个名字，这是本脚本踩过的最大一个坑**：
#        开发者后台/Xcode 里叫「类型名」`Mac Installer Distribution`，
#        钥匙串里打出来的是「身份名」`3rd Party Mac Developer Installer`。
#        上面第二条命令查的就是后者 —— 按类型名 grep 会查不到（东西明明装着）。
#    ⚠️ 查第二张**不能加 `-p codesigning`**：installer 身份不在那个策略里，
#       加了过滤会永远查不到。
#    ⚠️ 两张都在 Xcode → Settings → Accounts → Manage Certificates 里用 `+` 建。
#
# 2) **`xcodebuild` 用不了 Xcode 里那个 Apple ID 账号** —— 这是这条路唯一的真坎，
#    而且它的报错会把人骗去反复确认那个"明明登着"的账号。
#
#    实测（2026-10-08）：Xcode 已登录、团队已选中，`-exportArchive` 仍报
#      exportArchive No Accounts
#      No profiles for 'com.tango.marquee' were found
#    原因是账号凭证在钥匙串里只授权给 Xcode.app，命令行进程读不到。**登账号解决不了它。**
#
#    两条出路（本脚本支持第二条）：
#
#      A. 不用脚本的导出那一步：Xcode → Product → Archive → Organizer →
#         Distribute App → App Store Connect → Upload
#         （GUI 用得上账号，而且顺带把包传上去；**首次提审走这条最省事**）
#
#      B. 给命令行一把 **App Store Connect API Key**（可自动化）：
#           ASC → 用户和访问 → 集成 → App Store Connect API → 生成密钥
#           （.p8 只能下载一次，同时记下 Key ID 与 Issuer ID）
#         然后：
#           ASC_KEY_PATH=/path/AuthKey_XXX.p8 ASC_KEY_ID=XXX ASC_ISSUER_ID=xxx \
#             ./scripts/package-mas.sh
#
# 3) 必需的 Xcode 设置（只做一次）：
#
#      defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
#
# 4) 上传用 **Transporter**（Mac App Store 里免费下）：把导出的 .pkg 拖进去。
#    命令行那条路（`xcrun altool --upload-app`）需要 App 专用密码，见脚本末尾。
#
# 2026-10-08 实测总结：**归档那一步从头到尾是通的**（`ARCHIVE SUCCEEDED`；
# 产物身份、三项沙盒 entitlement、hardened runtime 全部正确）。
# 导出卡在「命令行拿不到账号」—— 那是环境性质，不是配置错误。
#
# 用法：
#
#     ./scripts/package-mas.sh                   # 归档 + 导出 + 预检
#     VERSION=1.0.0 ./scripts/package-mas.sh     # 临时指定版本号
#     ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=… ./scripts/package-mas.sh
#                                                # 用 API Key 认证（见上面第 2 条）
#
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Marquee"
APP_NAME="Marquee"
TEAM_ID="${DEVELOPMENT_TEAM:-UKXWZ3FS84}"
BUILD_DIR="$PWD/.build-mas"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
# 正式版 id。**内购商品挂在它下面** —— 开发版（…​.dev）的包在商店里取不到商品，
# 而那个现象很难反推回"归档时用错了配置"。所以这里核一遍，且预检再核一遍。
EXPECTED_BUNDLE_ID="com.tango.marquee"

echo "── 0/5 前置检查 ─────────────────────────────────────────────"

if [ "$(defaults read com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox 2>/dev/null || echo 0)" != "1" ]; then
  echo "✗ 缺少必需的 Xcode 设置，归档无法进行。先执行（一次性，可回退）：" >&2
  echo "" >&2
  echo "    defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES" >&2
  echo "" >&2
  exit 1
fi

# 找一条**有效的**签名身份。
#
# ⚠️ **证书的「类型名」与钥匙串里的「身份名」不是同一个字符串。**
# 同一张证书：开发者后台与 Xcode 的 `+` 菜单里叫 `Mac Installer Distribution`，
# 而钥匙串（`security find-identity` 打出来的那一行）是 `3rd Party Mac Developer Installer`。
# 只匹配一个名字，就会在**明明装好了**的时候报"找不到" —— 2026-10-08 实测踩过：
# 用户装完仍被拦下，而照着报错去查证书本身是查不出问题的（东西是对的，是判据写窄了）。
#
# ⚠️ 查 installer 那一类**不能用 `-p codesigning`**：installer 身份不属于 codesigning
# 策略，加了过滤会永远查不到（Apple 文档专门用 IMPORTANT 标过这一条）。
#
# ⚠️ 还要把 `Developer ID Installer` 排除掉：它**也是** installer，但那条是
# **站外分发**用的；拿去签 App Store 的 .pkg 会被拒（ITMS-90237），
# 而那个报错不会告诉你"证书选错了"。
identity_for() {
  if [ "$1" = "installer" ]; then
    security find-identity -v | grep -i "installer" | grep -vi "Developer ID" | head -1
  else
    security find-identity -v \
      | grep -iE "Apple Distribution|3rd Party Mac Developer Application" \
      | grep -vi "Installer" | head -1
  fi
}

APP_IDENTITY="$(identity_for app || true)"
if [ -z "$APP_IDENTITY" ]; then
  echo "✗ 找不到「Apple Distribution」证书 —— 上传 App Store 必须用它。" >&2
  echo "  （Apple Development 是开发签名、Developer ID Application 是站外分发那条路，" >&2
  echo "   两个都不能用来上传商店。）" >&2
  echo "  建证书：Xcode → Settings → Accounts → Manage Certificates → + → Apple Distribution" >&2
  exit 1
fi

INSTALLER_IDENTITY="$(identity_for installer || true)"
if [ -z "$INSTALLER_IDENTITY" ]; then
  echo "✗ 找不到「Mac Installer Distribution」证书 —— 它签的是 .pkg 安装包，" >&2
  echo "  与签 app 的 Apple Distribution 是两张不同的证书，少一张导出就过不去。" >&2
  echo "  建证书：Xcode → Settings → Accounts → Manage Certificates → + → Mac Installer Distribution" >&2
  echo "  ⚠️ 它在钥匙串里的名字是「3rd Party Mac Developer Installer」，与上面那个类型名不同；" >&2
  echo "     核对请用 `security find-identity -v`（不要加 `-p codesigning`）。" >&2
  exit 1
fi

echo "  签名身份（类型名 → 钥匙串里的身份名可能不同，这里打的是后者）："
echo "    $APP_IDENTITY"
echo "    $INSTALLER_IDENTITY"

# ⚠️ **「命令行拿不到账号」是这条路的固有性质，不是让你去登账号。**
#
# 2026-10-08 实测：Xcode 里 Apple ID 早已登录、团队也选中了
#（`IDEProvisioningTeamManagerLastSelectedTeamID = UKXWZ3FS84`），
# 而 `xcodebuild -exportArchive … -allowProvisioningUpdates` 仍然报
#   exportArchive No Accounts
#   No profiles for 'com.tango.marquee' were found
# 它**不是**"没登"——而是 Xcode 的账号凭证存在钥匙串里、只授权给 Xcode.app 自己，
# 命令行进程读不到。
#
# ⇒ 两条路，脚本都支持：
#   · 给命令行一把 **App Store Connect API Key**（下面三个环境变量）—— 可自动化；
#   · 或者干脆不走脚本这一步：Xcode → Product → Archive → Organizer →
#     Distribute App → App Store Connect（GUI 用得上账号，而且顺带把包传上去）。
API_AUTH_ARGS=""
if [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  API_AUTH_ARGS="-authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
  echo "  认证：App Store Connect API Key（ID = $ASC_KEY_ID）"
else
  echo "  认证：未提供 API Key（导出若报 No Accounts，见第 3 步失败时的说明）"
fi

VERSION="${VERSION:-$(awk '/MARKETING_VERSION:/{print $2; exit}' project.yml 2>/dev/null | tr -d '"')}"
VERSION="${VERSION:-0.1.0}"
echo "  版本：$VERSION   团队：$TEAM_ID   构建目录：$BUILD_DIR"

# 嵌套沙箱逃逸（与 scripts/build.sh 同一条，理由见那份文件顶部的长注释）。
# 值里没有空格，所以下面不加引号直接展开 —— 加了会把整串当成一个参数名。
EXTRA_BUILD_SETTING=""
if [ "${MARQUEE_DISABLE_COMPILER_SANDBOX:-}" = "1" ]; then
  EXTRA_BUILD_SETTING="OTHER_SWIFT_FLAGS=-disable-sandbox"
  echo "⚠️  已关闭编译器的子进程沙箱（MARQUEE_DISABLE_COMPILER_SANDBOX=1）——"
  echo "    只在被沙箱包裹的 shell 里需要；正常终端请去掉这个变量。"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "── 1/5 生成工程 ─────────────────────────────────────────────"
xcodegen generate

echo "── 2/5 归档（配置 = MAS）────────────────────────────────────"
# `-allowProvisioningUpdates` 不能省：没有它，第一次归档会停在
# "找不到匹配的描述文件"上，而那句话不会告诉你去哪里建。
xcodebuild \
  -workspace Marquee.xcworkspace \
  -scheme "$SCHEME" \
  -configuration MAS \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -allowProvisioningUpdates \
  $API_AUTH_ARGS \
  $EXTRA_BUILD_SETTING \
  MARKETING_VERSION="$VERSION" \
  archive

echo "── 3/5 导出（method = app-store-connect）────────────────────"
# 用 `-exportOptionsPlist` 而不是直接拿归档里的 .app：
# 这一步会把它**重新签成 Apple Distribution**（归档时用的是 Apple Development），
# 并用 `Mac Installer Distribution` 签出 ASC 收的 .pkg。
#
# ⚠️ method 的名字：`app-store` 已弃用，现在叫 `app-store-connect`
#   （用旧名字时 xcodebuild 会打一行 deprecation，仍然能跑，但别留着）。
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

if ! xcodebuild -exportArchive \
      -archivePath "$ARCHIVE" \
      -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
      -allowProvisioningUpdates \
      $API_AUTH_ARGS ; then
  echo "" >&2
  echo "✗ 导出失败。按上面那几行报错对号入座：" >&2
  echo "" >&2
  echo "  · No Accounts / No profiles for '…' were found" >&2
  echo "      = **命令行读不到 Xcode 里那个账号**（Xcode 登了也没用，见脚本顶部那段）。" >&2
  echo "        两条路：" >&2
  echo "        ① 不用这个脚本的导出那一步 —— Xcode 里 Product → Archive →" >&2
  echo "           Organizer → Distribute App → App Store Connect（顺带把包传上去）；" >&2
  echo "        ② 给脚本一把 ASC API Key 然后重跑：" >&2
  echo "           ASC → 用户和访问 → 集成 → App Store Connect API → 生成密钥" >&2
  echo "           （.p8 只能下载一次，记下 Key ID 与 Issuer ID）" >&2
  echo "           ASC_KEY_PATH=/path/AuthKey_XXX.p8 ASC_KEY_ID=XXX \\" >&2
  echo "             ASC_ISSUER_ID=xxx ./scripts/package-mas.sh" >&2
  echo "" >&2
  echo "  · No \"Mac Installer Distribution\" signing certificate …" >&2
  echo "      = 缺 installer 那张证书（见脚本顶部第 1 步）。" >&2
  exit 1
fi

APP="$EXPORT_DIR/$APP_NAME.app"
PKG="$EXPORT_DIR/$APP_NAME.pkg"
[ -d "$APP" ] || { echo "✗ 导出目录里没有 $APP_NAME.app" >&2; exit 1; }

echo "── 4/5 上传前预检（这三条错一条就会被退）─────────────────────"
#
# 为什么值得单列一步：这三条**在开发机上都不会报错**，
# 只在上传那一刻被拒，而拒信只说"包有问题"。
fail=0

# ① 身份：必须是正式 id
PACKED_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [ "$PACKED_ID" != "$EXPECTED_BUNDLE_ID" ]; then
  echo "✗ 身份是「$PACKED_ID」，不是正式 id「$EXPECTED_BUNDLE_ID」。" >&2
  echo "  内购商品挂在 bundle id 下 —— 开发 id 的包在商店里取不到商品。检查归档用的配置。" >&2
  fail=1
else
  echo "  ✓ 身份：$PACKED_ID"
fi

# ② 沙盒必须真的在包里（App Store 的硬要求）
ENT_FILE="$BUILD_DIR/entitlements.plist"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -convert xml1 -o "$ENT_FILE" - 2>/dev/null || true

if plutil -extract com.apple.security.app-sandbox raw "$ENT_FILE" >/dev/null 2>&1; then
  echo "  ✓ 沙盒：app-sandbox = $(plutil -extract com.apple.security.app-sandbox raw "$ENT_FILE")"
else
  echo "✗ 包里没有 com.apple.security.app-sandbox —— App Store 会拒。" >&2
  echo "  多半是归档用了 Release 配置（那条路刻意不带沙盒）。用 MAS 重新归档。" >&2
  fail=1
fi

# ③ 开发签名的标记不能进包
#    （它是 Apple Development 签名带进去的；换 Distribution 重新签名后应当消失。）
if plutil -extract com.apple.security.get-task-allow raw "$ENT_FILE" >/dev/null 2>&1; then
  echo "✗ 包里带着 com.apple.security.get-task-allow —— 上传会被直接拒。" >&2
  echo "  它说明包还是开发签名；检查第 3 步的导出有没有真的重新签名。" >&2
  fail=1
else
  echo "  ✓ 无 get-task-allow（不是开发签名）"
fi

# 附带信息（不参与判断，但排障时有用）
echo "  · 版本：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
echo "  · 最低系统：$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
echo "  · 分类：$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$APP/Contents/Info.plist")"
codesign -dvvv "$APP" 2>&1 | grep -E "^Authority=|^flags=" | sed 's/^/  · /' || true

if [ "$fail" != "0" ]; then
  echo "" >&2
  echo "✗ 预检没过 —— **不要上传**。上面每一条都写了原因。" >&2
  exit 1
fi

echo "── 5/5 好了 ─────────────────────────────────────────────────"
echo
if [ -f "$PKG" ]; then
  echo "  上传包：$PKG"
else
  echo "  ⚠️ 没生成 .pkg（导出目录内容如下），用下面的 app 也能通过 Transporter 上传："
  ls -la "$EXPORT_DIR"
fi
echo
echo "  上传方式（二选一）："
echo "    A) Transporter（推荐）：Mac App Store 里下 Transporter，把上面的包拖进去 → 交付。"
echo "    B) 命令行：xcrun altool --upload-app -f <包> -t macos \\"
echo "         -u <Apple ID> -p <App 专用密码>      # 密码在 appleid.apple.com 生成，不是登录密码"
echo
echo "  上传后：App Store Connect → 该版本 →「构建版本」选它；"
echo "  并确认版本信息里的「App 内购买项目」区块勾上了那两个商品（首次提审必须一起交）。"
echo "  商店文案与审核备注见 docs/APP-STORE-LISTING.md。"

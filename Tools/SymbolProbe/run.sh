#!/bin/bash
# SF Symbol 探针：在 en 与 zh-Hans 两种语言下各渲染一张图标对照图。
#
# 本地化要"应用声明了 zh-Hans 本地化"才生效 —— 直接用 swiftc 编出来的裸二进制
# 永远按英文渲染（这一点实测过：`-AppleLanguages` 改不动它）。
# 所以这里临时拼一个最小 app bundle，把探针放进去再跑。
#
# 用法：./run.sh          （产物在同目录 out-en.png / out-zh.png）

set -euo pipefail
cd "$(dirname "$0")"

APP=".build/SymbolProbe.app"
rm -rf .build
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources/en.lproj" \
         "$APP/Contents/Resources/zh-Hans.lproj"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleIdentifier</key><string>dev.tango.SymbolProbe</string>
<key>CFBundleName</key><string>SymbolProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict></plist>
PLIST

# 自绘图形（钉图）也要一起编进来 —— 它与 SF Symbol 走的是两条渲染路
#（`AnnotationGlyph` 给几何、`ChromeGlyph` 画）。两个文件都是自包含的：
# 只依赖 CoreGraphics / AppKit，不牵动 Core 的其余部分。
CORE="../../Modules/Sources/MarqueeCore"
swiftc -O -o "$APP/Contents/MacOS/SymbolProbe" main.swift \
    "$CORE/AnnotationGlyph.swift" "$CORE/ChromeGlyph.swift"
"$APP/Contents/MacOS/SymbolProbe" en -AppleLanguages '(en)'
"$APP/Contents/MacOS/SymbolProbe" zh -AppleLanguages '(zh-Hans)'

echo
echo "看这两张图（项目面向中文用户，zh 那张才是用户看到的）："
echo "  open out-en.png out-zh.png"
echo "两张都要看：**只在中文下变形的图标**才是要防的那一类。"

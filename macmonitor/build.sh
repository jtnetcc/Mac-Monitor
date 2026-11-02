#!/bin/bash
# Mac Monitor 构建脚本 —— 无需 Xcode 工程，直接用 swiftc 编译并组装 .app

set -e
cd "$(dirname "$0")"

APP_NAME="MacMonitor"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SRC="Sources"

echo "==> 清理"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "==> 编译"
# 软件管家那部分要求 macOS 14（用了 List/scrollPosition 等新 API），
# 所以整个 app 的部署目标从 13.0 抬到 14.0
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework Cocoa \
  -framework SwiftUI \
  -framework IOKit \
  -framework Carbon \
  -framework SystemConfiguration \
  "$SRC"/*.swift \
  "$SRC"/Manager/*.swift \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> 组装 bundle"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# 软件管家的卸载规则表（Scanner 从 Bundle.main 里读）
if [ -f "Resources/rules.json" ]; then
  cp "Resources/rules.json" "$APP_BUNDLE/Contents/Resources/rules.json"
else
  echo "    ⚠️  缺 Resources/rules.json，卸载规则会退回内置默认值"
fi

# 图标由 ./package.sh 生成（app 自己画，保证每个尺寸都原生渲染）
if [ -f "Assets/AppIcon.icns" ]; then
  cp "Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "    （缺 Assets/AppIcon.icns，先跑 ./package.sh 生成图标）"
fi

echo "==> 本地签名（ad-hoc）"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "   签名跳过"

echo "==> 完成: $APP_BUNDLE"
du -sh "$APP_BUNDLE"

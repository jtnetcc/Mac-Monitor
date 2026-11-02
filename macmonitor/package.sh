#!/bin/bash
# Mac Monitor 打包脚本
#   ./package.sh         只出 DMG（默认，拖拽安装）
#   ./package.sh dmg     同上
#   ./package.sh pkg     只出 PKG（安装器，一般用不上）
#   ./package.sh all     两个都出
#
# 产物不带 Apple 开发者签名（本地 ad-hoc 签名），首次打开会被 Gatekeeper
# 拦一次，DMG 里附了说明。
#
# 默认走 DMG：PKG 是组件包，安装器会做一堆额外判断（重定位、同版本跳过、
# 收据残留），踩过坑；DMG 就是挂载 → 拖进「应用程序」，没有中间环节。

set -e
cd "$(dirname "$0")"

APP_NAME="MacMonitor"
DISPLAY_NAME="Mac Monitor"
DIST="dist"
APP="build/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

WANT_DMG=1
WANT_PKG=0
case "${1:-}" in
  dmg) WANT_PKG=0 ;;
  pkg) WANT_DMG=0; WANT_PKG=1 ;;
  all) WANT_PKG=1 ;;
  "")  ;;
  *) echo "用法: ./package.sh [dmg|pkg|all]"; exit 1 ;;
esac

# ---------------------------------------------------------------- 1. 图标
echo "==> 1/4 应用图标"
mkdir -p Assets
# 图标要用 app 自己画，所以先确保有可执行文件
if [ ! -x "$BIN" ]; then
  echo "    先编译一次（用于渲染图标）"
  ./build.sh > /dev/null
fi
rm -rf Assets/AppIcon.iconset
"$BIN" --iconset Assets/AppIcon.iconset
iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
rm -rf Assets/AppIcon.iconset
echo "    Assets/AppIcon.icns"

# ---------------------------------------------------------------- 2. 编译
echo "==> 2/4 编译（含图标与 ad-hoc 签名）"
./build.sh

# 清掉可能残留的 quarantine 等扩展属性（com.apple.provenance 是系统加的，去不掉，
# 所以包里仍会有几个 ._ 开头的 AppleDouble 文件，属正常现象）
xattr -cr "$APP" 2>/dev/null || true

# ---------------------------------------------------------------- 3. 校验
echo "==> 3/4 校验 bundle"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" > /dev/null
if codesign --verify --strict "$APP" 2>/dev/null; then
  echo "    签名有效（ad-hoc）"
else
  echo "    ⚠️  签名校验失败"
fi
test -f "$APP/Contents/Resources/AppIcon.icns" || { echo "❌ 图标没进 bundle"; exit 1; }
test -f "$APP/Contents/Resources/rules.json" || { echo "❌ 软件管理的规则表 rules.json 没进 bundle"; exit 1; }
echo "    体积 $(du -sh "$APP" | cut -f1)"

mkdir -p "$DIST"

# ---------------------------------------------------------------- 4. DMG
if [ "$WANT_DMG" = "1" ]; then
  echo "==> 制作 DMG"
  STAGE="$DIST/.dmg-stage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/应用程序"

  # 挂载后卷宗显示成应用图标（不然就是个空白硬盘图标）
  if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
    SetFile -a C "$STAGE" 2>/dev/null || true
  fi

  cat > "$STAGE/安装说明.txt" <<'TXT'
Mac Monitor —— 安装说明
========================================

这是一个「菜单栏常驻」应用：没有 Dock 图标，也没有主窗口。
装好之后抬头看屏幕右上角的菜单栏，会出现一个圆环 + 百分比，
点它展开面板。

除了系统监测，还带一套软件管理（安装 / 卸载 / 残留清理），
在详情窗口左侧点「软件」，或者右键菜单栏图标选「打开软件管理」。

安装
----
把左边的 MacMonitor 拖到右边的「应用程序」文件夹，然后打开它。
需要 macOS 14 或更新版本。

首次打开被系统拦住？
--------------------
本应用是本地构建、没有 Apple 开发者签名，首次双击可能提示
「无法打开，因为无法验证开发者」。两种解法任选其一：

  1) 在「应用程序」里右键点 MacMonitor → 选择「打开」→ 再点「打开」
  2) 打开「终端」执行：
     xattr -dr com.apple.quarantine /Applications/MacMonitor.app

软件管理需要「完全磁盘访问权限」
--------------------------------
卸载应用时要清理 ~/Library 下的沙盒容器，这部分受系统 TCC 保护，
普通应用删不掉（sudo 也不行，那是按发起进程判定的）。

  系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 加入 Mac Monitor 并打开开关
  然后在应用里点「重启应用」让授权生效。

不授权也能用：应用会自动改请访达代删，只是每次会多弹一次确认，
而且清空废纸篓才算真正删干净。

注意：本应用是 ad-hoc 签名，重新编译后签名会变，旧的授权记录可能失效。
如果列表里开关看着是开的却仍提示未授权，把它从列表里删掉再加一次。

日常操作
--------
  左键点图标     精简面板 ↔ 详情窗口
  右键点图标     菜单（进程 / 软件 / 菜单栏显示哪个指标 / 系统工具）
  ⌥M           同上切换
  ⌥P           直接打开进程管理
  ⌥S           直接打开软件管理
  右键点进程行   结束进程 / 强制结束 / 查看详情
  悬停进程行     行尾出现 ✕，单击直接结束
  ESC          收起精简面板

卸载
----
把 /Applications/MacMonitor.app 拖进废纸篓即可。
应用不写任何数据文件，只在 UserDefaults 里存一条
「菜单栏显示哪个指标」的偏好；软件管理会把卸载记录写在
~/.macapp/history/（移入废纸篓的可以还原）。
TXT

  hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DIST/$APP_NAME-$VERSION.dmg" > /dev/null
  rm -rf "$STAGE"
  echo "    $DIST/$APP_NAME-$VERSION.dmg（$(du -h "$DIST/$APP_NAME-$VERSION.dmg" | cut -f1)）"
fi

# ---------------------------------------------------------------- 5. PKG
if [ "$WANT_PKG" = "1" ]; then
  echo "==> 制作 PKG"
  PKGROOT="$DIST/.pkg-root"
  rm -rf "$PKGROOT"
  mkdir -p "$PKGROOT/Applications"

  # 用 --root 而不是 --component，并且必须关掉「可重定位」。
  #
  # 背景：pkgbuild 一旦在 payload 里发现 .app，就会自动写
  #   relocatable="true" + <relocate><bundle id="..."/></relocate>
  # 安装器拿到这个元数据后，会先在磁盘上搜同 identifier 的 bundle，
  # 找到就把安装目标「重定位」过去。我们的 build/MacMonitor.app 正好同 id，
  # 于是 /Applications 什么都没写，build/ 里那份被 chown 成 root:wheel，
  # 安装器还报「安装成功」。
  #
  # 解法：--analyze 生成 component plist，把 BundleIsRelocatable 改成 false，
  # 再带着它打包。这样 PackageInfo 里是 relocatable="false"，
  # <relocate> 保留成空元素（无害），安装路径强制为 /。
  # COPYFILE_DISABLE=1 可以少掉一批 ._ 开头的 AppleDouble 文件（com.apple.provenance
  # 去不掉，所以通常还是会剩几个，属正常现象，不影响安装）
  COPYFILE_DISABLE=1 ditto --noextattr --norsrc "$APP" "$PKGROOT/Applications/$APP_NAME.app"

  COMPLIST="$DIST/.pkg-components.plist"
  rm -f "$COMPLIST"
  pkgbuild --analyze --root "$PKGROOT" "$COMPLIST" > /dev/null
  # 把所有 bundle 条目（通常只有 1 个）的可重定位都关掉
  N=$(/usr/libexec/PlistBuddy -c "Print" "$COMPLIST" | grep -c "BundleIsRelocatable" || true)
  i=0
  while [ "$i" -lt "${N:-0}" ]; do
    /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$COMPLIST"
    i=$((i + 1))
  done

  pkgbuild \
    --root "$PKGROOT" \
    --component-plist "$COMPLIST" \
    --install-location / \
    --identifier com.local.macmonitor \
    --version "$VERSION" \
    --ownership recommended \
    "$DIST/$APP_NAME-$VERSION.pkg" > /dev/null
  rm -rf "$PKGROOT" "$COMPLIST"

  # 防回归：relocatable 必须是 false，且 <relocate> 里不能再有 bundle 条目
  CHECK="$DIST/.pkg-check"
  rm -rf "$CHECK"
  pkgutil --expand "$DIST/$APP_NAME-$VERSION.pkg" "$CHECK" > /dev/null
  if ! grep -q 'relocatable="false"' "$CHECK/PackageInfo"; then
    echo "❌ 包仍允许重定位（relocatable 未关闭），安装器可能装到别处"
    rm -rf "$CHECK"
    exit 1
  fi
  if grep -A3 "<relocate" "$CHECK/PackageInfo" | grep -q "<bundle "; then
    echo "❌ <relocate> 里仍有 bundle 条目，安装器可能装到别处"
    rm -rf "$CHECK"
    exit 1
  fi
  LOC=$(grep -o 'install-location="[^"]*"' "$CHECK/PackageInfo" | head -1)
  FILES=$(grep -o 'numberOfFiles="[0-9]*"' "$CHECK/PackageInfo" | head -1)
  rm -rf "$CHECK"
  # 注意：变量后面紧跟中文全角标点时必须写 ${VAR}。
  # 否则 UTF-8 locale 下 bash 会把标点的字节当成变量名的一部分，
  # 展开成空字符串（踩过一次）。
  echo "    $DIST/$APP_NAME-$VERSION.pkg（$(du -h "$DIST/$APP_NAME-$VERSION.pkg" | cut -f1)，${LOC}，${FILES}，不可重定位）"
fi

echo
echo "==> 完成"
for f in "$DIST"/*.dmg "$DIST"/*.pkg; do
  [ -f "$f" ] || continue
  printf "    %-28s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
echo
echo "提示：产物未签名/未公证，首次打开需要右键「打开」或去掉 quarantine 标记"
if [ "$WANT_PKG" = "1" ]; then
  echo
  echo "提示：如果之前装过同版本 PKG（安装器会认为「已安装」而跳过），先清掉回执："
  echo "    sudo pkgutil --forget com.local.macmonitor"
fi

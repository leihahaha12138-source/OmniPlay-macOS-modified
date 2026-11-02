#!/bin/bash
# 打包 Release 版 DMG
# ---------------------------------------------------------------
# 用法：双击或在终端执行
#   ./scripts/make-dmg.sh            # 产出到 ./dist/
#   ./scripts/make-dmg.sh /tmp/out   # 指定输出目录
#
# 说明：本脚本只负责「编译 + 打包」，不做签名与公证。
#       签名/公证需要 Apple Developer Program（$99/年），本仓库不提供。
# ---------------------------------------------------------------
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$SRC_DIR/dist}"
BUILD_DIR="/tmp/omniplay-release-dd"
APP_NAME="觅影"
# 文件名用 ASCII：GitHub Release 上传时中文名会被吞掉（实测变成 "-1.7-mod1.dmg"）
DMG_BASE="OmniPlay"
# 版本号只用于文件名，不改工程设置（避免动 pbxproj）
VERSION="1.7-mod1"
DMG="$OUT_DIR/${DMG_BASE}-${VERSION}.dmg"

echo "=== 编译 Release ==="
xcodebuild -project "$SRC_DIR/OmniPlay.xcodeproj" -scheme OmniPlay \
  -configuration Release -sdk macosx \
  -derivedDataPath "$BUILD_DIR" \
  -IDEPackageSupportDisableManifestSandbox=1 \
  -IDEPackageSupportDisablePluginExecutionSandbox=1 \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  build | tail -3

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "✘ 没找到产物：$APP"; exit 1; }

echo "=== 组装 DMG 内容 ==="
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/首次打开说明.txt" <<'TXT'
首次打开（重要）
================

本程序没有经过 Apple 签名与公证（个人项目，没有付费开发者账号），
所以下载后直接双击会被系统拦下，提示「无法打开」或「已损坏」。

二选一：

方法一（推荐）
--------------
把「觅影.app」拖到「应用程序」文件夹后，在「应用程序」里
按住 Control 键点它 → 选「打开」→ 再点一次「打开」。

方法二（终端，一行）
--------------------
打开「终端」，粘贴执行：

    xattr -dr com.apple.quarantine /Applications/觅影.app

然后正常双击即可。

这个命令只是去掉「从网上下载」的隔离标记，不会修改程序本身。
如果还是不放心，可以直接从源码编译（十几分钟），见 GitHub 仓库的 README。

数据位置
--------
数据库与海报缓存在 ~/Library/Application Support/OmniPlay/，
卸载 App 不会删除；想彻底清干净需要手动删这个目录。
TXT

echo "=== 生成 DMG ==="
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo ""
echo "✔ 完成：$DMG"
echo "  体积：$(du -h "$DMG" | cut -f1)"
echo "  签名：$(codesign -dv "$APP" 2>&1 | grep -E '^Signature' | cut -d= -f2)（adhoc = 未公证）"

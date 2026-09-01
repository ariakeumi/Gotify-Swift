#!/bin/zsh
#
# package.sh — 构建 Gotify-Swift 并打包为 .app 和 .dmg
#
# 用法:
#   ./package.sh                  # 构建并打包
#   ./package.sh --skip-build     # 跳过 xcodebuild,直接用已构建的 .app 打包
#   IDENTITY="Developer ID Application: Your Name" ./package.sh   # 指定签名证书
#
# 产物输出在 build/ 目录下。

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Gotify-Swift.xcodeproj"
SCHEME="Gotify-Swift"
APP_NAME="Gotify-Swift"
BUNDLE_ID="com.umi.Gotify-Swift"
CONFIG="Release"
BUILD_DIR="build"
DERIVED_DIR="$BUILD_DIR/DerivedData"
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 定位 Xcode:xcode-select 可能指向 CommandLineTools,此时 xcodebuild 不可用,
# 自动改用 DEVELOPER_DIR 指向 /Applications 下最新的 Xcode。
# ---------------------------------------------------------------------------
find_xcode() {
  if xcodebuild -version >/dev/null 2>&1; then
    return
  fi
  local xcode
  xcode=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)
  if [[ -z "$xcode" ]]; then
    echo "错误: 未找到完整版 Xcode。请安装 Xcode 或执行:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
  fi
  echo "提示: 使用 DEVELOPER_DIR=$xcode(当前 xcode-select 指向 CommandLineTools)"
  export DEVELOPER_DIR="$xcode"
}

find_xcode

# 从项目设置中读取版本号
read_version() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk '/[[:space:]]MARKETING_VERSION = /{gsub(/[";]/,"",$3); v=$3} /[[:space:]]CURRENT_PROJECT_VERSION = /{gsub(/[";]/,"",$3); b=$3} END{print v"_b"b}'
}

VERSION=$(read_version)
[[ -n "$VERSION" ]] || VERSION="unknown"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "==> 版本: $VERSION"

# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------
if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> xcodebuild ($CONFIG)..."
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DIR" \
    -destination "generic/platform=macOS" \
    clean build \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${IDENTITY:--}" \
    | tail -n 5
else
  echo "==> 跳过构建,使用已有产物"
fi

BUILT_APP="$DERIVED_DIR/Build/Products/$CONFIG/$APP_NAME.app"
[[ -d "$BUILT_APP" ]] || { echo "错误: 未找到 $BUILT_APP"; exit 1; }

rm -rf "$BUILD_DIR/$APP_NAME.app"
cp -R "$BUILT_APP" "$BUILD_DIR/$APP_NAME.app"

# ---------------------------------------------------------------------------
# 签名(默认 ad-hoc;通过 IDENTITY=... 指定真实证书)
# ---------------------------------------------------------------------------
echo "==> codesign (${IDENTITY:-ad-hoc})..."
if [[ -n "${IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$BUILD_DIR/$APP_NAME.app"
else
  codesign --force --sign - "$BUILD_DIR/$APP_NAME.app"
fi
codesign --verify --strict "$BUILD_DIR/$APP_NAME.app" && echo "    签名校验通过"

# ---------------------------------------------------------------------------
# 制作 DMG
#   已安装 create-dmg 时生成带拖拽安装布局的窗口样式 DMG,
#   否则用 hdiutil 打包(内容相同,无背景布局)。
# ---------------------------------------------------------------------------
DMG_PATH="$BUILD_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

STAGING=$(mktemp -d /tmp/gotify-dmg.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> create-dmg..."
  create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 --window-size 660 400 \
    --icon-size 100 --icon "$APP_NAME.app" 175 185 \
    --app-drop-link 480 185 \
    "$DMG_PATH" "$BUILD_DIR/$APP_NAME.app" || true
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "==> hdiutil 打包..."
  mkdir -p "$STAGING"
  cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -fs HFS+ \
    -ov "$DMG_PATH" >/dev/null
fi

echo ""
echo "打包完成:"
echo "  App: $BUILD_DIR/$APP_NAME.app"
echo "  DMG: $DMG_PATH"

#!/bin/bash
# 一键构建「智能教务.app」：编译原生外壳 + 打包网页 + ad-hoc 签名
#
#   ./build.sh                       # 正式版：智能教务.app，bundle id com.zhipai.paike
#   APP_NAME=智能教务（演示） \
#   BUNDLE_ID=com.zhipai.paike.demo \
#   ./build.sh                       # 演示版（数据仓库独立，不干扰正式版）
#   OUT_DIR=/tmp/out ./build.sh      # 指定输出目录
#
# 产物是 arm64 + x86_64 通用二进制，最低系统 macOS 13.0（DEPLOY_MIN 可改）。
# 数据由 App 自己在 Contents/Resources/userdata/store.json 里维护，见 docs/数据与迁移.md。
#
# 依赖：Xcode Command Line Tools（swiftc / lipo / codesign / plutil）。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="${APP_NAME:-智能教务}"
BUNDLE_ID="${BUNDLE_ID:-com.zhipai.paike}"
VERSION="${VERSION:-1.0.0}"
OUT_DIR="${OUT_DIR:-$(cd .. && pwd)/dist}"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "==> 构建 $APP_NAME ($BUNDLE_ID)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

echo "==> 编译 main.swift（arm64 + x86_64 通用二进制）"
# 为什么是 13.0：CLT 里的 libswiftCompatibility*.a 只有 arm64 切片，
# 交叉编到 x86_64 时若 minos < 13 会去链它，链接失败。
DEPLOY_MIN="${DEPLOY_MIN:-13.0}"
BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$BIN_DIR"' EXIT

for ARCH in arm64 x86_64; do
  echo "    - $ARCH (macOS $DEPLOY_MIN+)"
  swiftc -swift-version 5 -O \
    -target "$ARCH-apple-macos$DEPLOY_MIN" \
    -o "$BIN_DIR/zhipai-$ARCH" \
    main.swift \
    -framework AppKit -framework WebKit -framework PDFKit
done
lipo -create "$BIN_DIR/zhipai-arm64" "$BIN_DIR/zhipai-x86_64" \
  -output "$APP_BUNDLE/Contents/MacOS/zhipai"
lipo -archs "$APP_BUNDLE/Contents/MacOS/zhipai"

echo "==> 打包资源"
cp ../web/app.html "$APP_BUNDLE/Contents/Resources/app.html"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# 数据仓库目录先建出来（空目录不参与封条，真正的 store.json 运行后才生成）
mkdir -p "$APP_BUNDLE/Contents/Resources/userdata"

plutil -replace CFBundleDisplayName -string "$APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$DEPLOY_MIN" "$APP_BUNDLE/Contents/Info.plist"

echo "==> ad-hoc 签名"
codesign -f -s - --deep "$APP_BUNDLE" >/dev/null 2>&1 || true
codesign --verify --strict "$APP_BUNDLE" && echo "签名校验通过"

echo "==> 完成：$APP_BUNDLE"
echo "    自检：'$APP_BUNDLE/Contents/MacOS/zhipai' --selftest && cat /tmp/zhipai-selftest.log"

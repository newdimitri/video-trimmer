#!/usr/bin/env bash
# 一键构建「视频裁剪.app」（Apple Silicon / arm64）
# 用法: ./build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="视频裁剪"
EXEC_NAME="VideoTrim"
BUILD_DIR="$SCRIPT_DIR/build"
RESOURCES_DIR="$SCRIPT_DIR/Resources"
APP_BUNDLE="$SCRIPT_DIR/${APP_NAME}.app"
FFMPEG_BIN="$RESOURCES_DIR/ffmpeg"

# 静态 ffmpeg 下载源（arm64 macOS）
FFMPEG_URL="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0/ffmpeg-darwin-arm64"

echo "========================================"
echo "  构建 ${APP_NAME}.app (arm64)"
echo "========================================"

# ---------- 1. 获取静态 ffmpeg ----------
if [[ ! -x "$FFMPEG_BIN" ]]; then
    echo "[1/4] 下载静态 arm64 ffmpeg..."
    mkdir -p "$RESOURCES_DIR"
    curl -fsSL "$FFMPEG_URL" -o "$FFMPEG_BIN"
    chmod +x "$FFMPEG_BIN"
else
    echo "[1/4] 使用已有 ffmpeg: $FFMPEG_BIN"
fi

# 校验架构与可执行
ARCH=$(file "$FFMPEG_BIN" | grep -o 'arm64' || true)
if [[ "$ARCH" != "arm64" ]]; then
    echo "[错误] ffmpeg 不是 arm64 架构: $(file "$FFMPEG_BIN")"
    exit 1
fi
if ! "$FFMPEG_BIN" -version >/dev/null 2>&1; then
    echo "[错误] ffmpeg 无法执行"
    exit 1
fi
echo "       ffmpeg OK: $("$FFMPEG_BIN" -version 2>&1 | head -1)"

# ---------- 2. 编译 Swift ----------
echo "[2/4] 编译 Swift 源码..."
mkdir -p "$BUILD_DIR"

swiftc -O \
    -target arm64-apple-macos12 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework UniformTypeIdentifiers \
    "$SCRIPT_DIR/Sources/App.swift" \
    "$SCRIPT_DIR/Sources/ContentView.swift" \
    "$SCRIPT_DIR/Sources/Trimmer.swift" \
    -o "$BUILD_DIR/$EXEC_NAME"

# ---------- 3. 组装 .app ----------
echo "[3/4] 组装 ${APP_NAME}.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$EXEC_NAME" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp "$FFMPEG_BIN" "$APP_BUNDLE/Contents/Resources/ffmpeg"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [[ -f "$RESOURCES_DIR/AppIcon.icns" ]]; then
    cp "$RESOURCES_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

chmod +x "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP_BUNDLE/Contents/Resources/ffmpeg"

# ---------- 4. Ad-hoc 签名（arm64 必须有签名才能运行）----------
echo "[4/4] Ad-hoc 签名..."
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/ffmpeg"
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "========================================"
echo "  构建完成: $APP_BUNDLE"
echo "  大小: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo "========================================"
echo ""
echo "运行: open \"$APP_BUNDLE\""
echo "分发: 压缩 ${APP_NAME}.app 发送到其他 Apple Silicon Mac"
echo "      对方首次打开: 右键 → 打开（绕过 Gatekeeper）"

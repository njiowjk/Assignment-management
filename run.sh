#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/.build"
CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if ! command -v swift >/dev/null 2>&1; then
    print -u2 "エラー: Swift Command Line Toolsが見つかりません。"
    print -u2 "ターミナルで xcode-select --install を実行してください。"
    exit 1
fi

mkdir -p \
    "$BUILD_DIR/cache" \
    "$BUILD_DIR/config" \
    "$BUILD_DIR/security" \
    "$BUILD_DIR/clang-cache"

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"

# このMacのCommand Line Tools 26.5は、標準SDKとSwiftコンパイラの
# 内部バージョンが一致していない。付属の互換SDKを選ぶことで回避する。
if [[ "$DEVELOPER_DIR_PATH" == *"CommandLineTools"* && -d "$CLT_SDK" ]]; then
    APP_SDK="$CLT_SDK"
else
    APP_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi

if [[ -z "$APP_SDK" || ! -d "$APP_SDK" ]]; then
    print -u2 "エラー: 利用できるmacOS SDKが見つかりません。"
    print -u2 "ターミナルで xcode-select --install を実行してください。"
    exit 1
fi

print "大学課題管理アプリをビルドして起動します…"

cd "$PROJECT_DIR"

SDKROOT="$APP_SDK" \
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache" \
exec swift run \
    --sdk "$APP_SDK" \
    --cache-path "$BUILD_DIR/cache" \
    --config-path "$BUILD_DIR/config" \
    --security-path "$BUILD_DIR/security" \
    --manifest-cache local \
    UniversityTaskManager


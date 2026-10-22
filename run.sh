#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/.build"
CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
BUILD_ONLY=0
if [[ "${1:-}" == "--build-only" ]]; then
    BUILD_ONLY=1
    shift
fi

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

export SDKROOT="$APP_SDK"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache"
SWIFT_OPTIONS=(
    --sdk "$APP_SDK"
    --cache-path "$BUILD_DIR/cache"
    --config-path "$BUILD_DIR/config"
    --security-path "$BUILD_DIR/security"
    --manifest-cache local
)
swift build "${SWIFT_OPTIONS[@]}" --product UniversityTaskManager
APP_BINARY_DIR="$(swift build "${SWIFT_OPTIONS[@]}" --show-bin-path)"

# Launch Services経由で通常のアプリとして起動し、入力フォーカス・編集メニューを利用できるようにする。
APP_BUNDLE="$BUILD_DIR/UniversityTaskManager.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$PROJECT_DIR/AppBundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_BINARY_DIR/UniversityTaskManager" "$APP_BUNDLE/Contents/MacOS/UniversityTaskManager.next"
mv -f "$APP_BUNDLE/Contents/MacOS/UniversityTaskManager.next" "$APP_BUNDLE/Contents/MacOS/UniversityTaskManager"
"$PROJECT_DIR/backend/build.sh" "$APP_BUNDLE/Contents/Resources"
# UserNotifications identifies a real signed bundle, not SwiftPM's loose executable.
# Local ad-hoc signing needs no certificate and grants no extra system permissions.
# Finder/iCloud can attach FinderInfo to this generated .app directory, which codesign rejects.
# Remove only that display metadata; retain provenance/quarantine and all source-file attributes.
xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
codesign --force --sign - --identifier jp.example.UniversityTaskManager "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
if [[ "$BUILD_ONLY" == 1 ]]; then
    print "アプリのビルドが完了しました: $APP_BUNDLE"
    exit 0
fi
# openだけでは実行中の旧版が再表示される。このチェックアウトのアプリだけを
# 終了してから起動し、ビルドした新しい実行ファイルを確実に使用する。
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/UniversityTaskManager"
RUNNING_APP_PIDS=()
while read -r app_pid app_command; do
    if [[ "$app_command" == "$APP_EXECUTABLE" ]]; then
        RUNNING_APP_PIDS+=("$app_pid")
    fi
done < <(ps -axo pid=,comm=)

for app_pid in "${RUNNING_APP_PIDS[@]}"; do
    # PIDが再利用されていた場合、別プロセスにはシグナルを送らない。
    if [[ "$(ps -p "$app_pid" -o comm= 2>/dev/null || true)" == "$APP_EXECUTABLE" ]]; then
        print "起動中の大学課題管理アプリを最新版に切り替えます…"
        kill -TERM "$app_pid" 2>/dev/null || true
    fi
done

for app_pid in "${RUNNING_APP_PIDS[@]}"; do
    for attempt in {1..50}; do
        if [[ "$(ps -p "$app_pid" -o comm= 2>/dev/null || true)" != "$APP_EXECUTABLE" ]]; then
            break
        fi
        sleep 0.1
    done
    if [[ "$(ps -p "$app_pid" -o comm= 2>/dev/null || true)" == "$APP_EXECUTABLE" ]]; then
        print -u2 "アプリを終了できませんでした。大学課題管理を閉じてから再実行してください。"
        exit 1
    fi
done

exec open -n -W "$APP_BUNDLE" --args "$@"


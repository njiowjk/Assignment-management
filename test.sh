#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/.build"
CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
if [[ "$DEVELOPER_DIR_PATH" == *"CommandLineTools"* && -d "$CLT_SDK" ]]; then
    APP_SDK="$CLT_SDK"
else
    APP_SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
mkdir -p "$BUILD_DIR/clang-cache"
"$PROJECT_DIR/backend/build.sh"
npm --prefix "$PROJECT_DIR/backend" test
export ASSIGNMENT_BACKEND_DIR="$PROJECT_DIR/backend/dist"
export ASSIGNMENT_NODE_EXECUTABLE="$(command -v node)"

# XCTest/Swift Testingの付属しないCommand Line Toolsでも、実コードを検証できる。
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache" \
swiftc -swift-version 6 -parse-as-library -sdk "$APP_SDK" \
    "$PROJECT_DIR"/UniversityTaskManager/Models/*.swift \
    "$PROJECT_DIR"/UniversityTaskManager/Utilities/*.swift \
    "$PROJECT_DIR"/UniversityTaskManager/Persistence/*.swift \
    "$PROJECT_DIR"/UniversityTaskManager/Connectors/TaskSourceConnector.swift \
    "$PROJECT_DIR"/UniversityTaskManager/Connectors/Moodle/*.swift \
    "$PROJECT_DIR"/UniversityTaskManager/Connectors/WebClass/*.swift \
    "$PROJECT_DIR"/UniversityTaskManager/ViewModels/*.swift \
    "$PROJECT_DIR"/UniversityTaskManager/Services/*.swift \
    "$PROJECT_DIR"/UniversityTaskManager/Backend/*.swift \
    "$PROJECT_DIR"/Tests/Phase2Checks/Checks.swift \
    -o "$BUILD_DIR/phase2-checks"
exec "$BUILD_DIR/phase2-checks"

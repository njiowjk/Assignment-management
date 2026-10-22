#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v node >/dev/null; then
    print -u2 "配布物のビルドにはNode.js 22以降が必要です（完成したアプリの実行には不要です）。"
    exit 1
fi
exec node "$PROJECT_DIR/scripts/create-release.mjs" "$@"

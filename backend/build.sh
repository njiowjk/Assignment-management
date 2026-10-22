#!/bin/zsh
set -euo pipefail
BACKEND_DIR="${0:A:h}"
cd "$BACKEND_DIR"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
    print -u2 "Node.js 22以降とnpmをインストールしてください。"
    exit 1
fi
node -e 'if(Number(process.versions.node.split(".")[0]) < 22) { console.error("Node.js 22以降が必要です。"); process.exit(1); }'
if [[ ! -x node_modules/.bin/tsc || ! -x node_modules/.bin/esbuild ]]; then
    npm ci --no-audit --no-fund
fi
npm run build
if [[ $# -gt 0 ]]; then
    node "$BACKEND_DIR/../scripts/package-backend.mjs" "$1"
fi

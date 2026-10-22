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
    # app Resources内に、依存をまとめたworkerとNodeの実行パスだけを配置する。
    node --input-type=module -e '
      import { mkdirSync, copyFileSync, writeFileSync } from "node:fs";
      import { join } from "node:path";
      import { spawnSync } from "node:child_process";
      const destination = join(process.argv[1], "Backend");
      mkdirSync(destination, { recursive: true });
      copyFileSync("dist/worker.mjs", join(destination, "worker.mjs"));
      writeFileSync(join(destination, "runtime.json"), JSON.stringify({ nodeExecutable: process.execPath }));
      const check = spawnSync(process.execPath, [join(destination, "worker.mjs")], {
        input: JSON.stringify({ version: 1, command: "health" }), encoding: "utf8", timeout: 5000,
      });
      let ok = false;
      try { const response = JSON.parse(check.stdout); ok = check.status === 0 && response.version === 1 && response.ok && response.result.protocolVersion === 1; }
      catch {}
      if (!ok) { console.error("TypeScriptバックエンドの起動確認に失敗しました。"); process.exit(1); }
    ' "$1"
fi

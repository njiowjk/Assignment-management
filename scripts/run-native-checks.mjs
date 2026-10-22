import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { ensureRuntime } from "./distribution-lib.mjs";

let runtime;
try {
  if (process.argv.length !== 3) throw new Error("ネイティブテストの実行ファイルが必要です。");
  runtime = await ensureRuntime();
  const result = spawnSync(process.argv[2], [], { stdio: "inherit", timeout: 120_000,
    env: { ...process.env, ASSIGNMENT_BUNDLED_NODE_EXECUTABLE: runtime.executable } });
  process.exitCode = result.status ?? 1;
} catch (error) { console.error(error.message); process.exitCode = 1; }
finally { if (runtime) rmSync(runtime.directory, { recursive: true, force: true }); }

import { cpSync, lstatSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { archiveFor, checkSystemDependencies, cleanEnvironment, run, runtimeLock } from "./distribution-lib.mjs";

export function validateRuntimeManifest(value) {
  if (value?.version !== 1 || value.nodeExecutable !== "../../Helpers/node" || value.nodeVersion !== runtimeLock.version ||
      !["arm64", "x64"].includes(value.architecture) || value.archiveSHA256 !== archiveFor(value.architecture).sha256) {
    throw new Error("同梱Node.jsの設定が不正、または固定バージョンと一致しません。");
  }
  return value;
}

export function validateLayout(app) {
  app = realpathSync(app);
  const allowed = new Set([
    "Contents", "Contents/Info.plist", "Contents/MacOS", "Contents/MacOS/UniversityTaskManager",
    "Contents/Helpers", "Contents/Helpers/node", "Contents/Resources", "Contents/Resources/Backend",
    "Contents/Resources/Backend/runtime.json", "Contents/Resources/Backend/worker.mjs", "Contents/Resources/Licenses",
    "Contents/Resources/Licenses/Node.js-LICENSE.txt", "Contents/Resources/Licenses/Backend-NOTICES.txt",
    "Contents/_CodeSignature", "Contents/_CodeSignature/CodeResources",
  ]);
  function walk(directory, prefix = "") {
    for (const name of readdirSync(directory)) {
      const relative = prefix ? `${prefix}/${name}` : name, full = join(directory, name), info = lstatSync(full);
      if (!allowed.has(relative) || info.isSymbolicLink() || (!info.isDirectory() && !info.isFile())) {
        throw new Error("配布appに想定外のファイル、認証データ、またはシンボリックリンクが含まれています。");
      }
      if (info.isDirectory()) walk(full, relative);
    }
  }
  walk(app);
  for (const required of allowed) if (!lstatSync(join(app, required))) throw new Error("配布appの構成要素が不足しています。");
  return validateRuntimeManifest(JSON.parse(readFileSync(join(app, "Contents/Resources/Backend/runtime.json"), "utf8")));
}

export function verifyBundle(app, { relocate = true } = {}) {
  app = realpathSync(app);
  const metadata = validateLayout(app);
  // Finder/iCloud may add display-only xattrs after signing. Never modify the user's input app.
  // Verify its sealed code, then strictly verify a content-identical relocated copy without those xattrs.
  run("/usr/bin/codesign", ["--verify", "--deep", app]);
  let scratch;
  try {
    let target = app;
    if (relocate) {
      scratch = mkdtempSync(join(tmpdir(), "assignment-relocation-"));
      target = join(scratch, "Moved folder with spaces", "UniversityTaskManager.app");
      cpSync(app, target, { recursive: true });
    }
    run("/usr/bin/codesign", ["--verify", "--deep", "--strict", target]);
    const contents = join(target, "Contents"), executable = join(contents, "MacOS/UniversityTaskManager"), node = join(contents, "Helpers/node");
    const expected = metadata.architecture === "x64" ? "x86_64" : "arm64";
    for (const binary of [executable, node]) {
      if (run("/usr/bin/lipo", ["-archs", binary]).trim() !== expected) throw new Error("アプリとNode.jsのアーキテクチャが一致しません。");
    }
    checkSystemDependencies(node); checkSystemDependencies(executable, { allowSwift: true });
    if (run(node, ["--version"]).trim() !== `v${runtimeLock.version}`) throw new Error("同梱Node.jsのバージョンが一致しません。");
    const result = JSON.parse(run(executable, ["--self-test"], { timeout: 30_000, cwd: tmpdir(),
      env: { ...cleanEnvironment, ASSIGNMENT_BACKEND_DIR: "/nonexistent-test-override",
        ASSIGNMENT_NODE_EXECUTABLE: "/nonexistent-test-node" } }));
    const checks = ["health", "ics-timezone", "merge", "sync-policy", "notifications"];
    if (result.version !== 1 || !result.ok || JSON.stringify(result.checks) !== JSON.stringify(checks)) {
      throw new Error("アプリ内バックエンドの自己診断に失敗しました。");
    }
    return { version: 1, ok: true, architecture: metadata.architecture, nodeVersion: metadata.nodeVersion,
      relocated: relocate, checks: ["layout", "signature", "system-only-libraries", ...checks] };
  } finally { if (scratch) rmSync(scratch, { recursive: true, force: true }); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3) throw new Error("検証するappを指定してください。");
    console.log(JSON.stringify(verifyBundle(process.argv[2]), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}

import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { cleanEnvironment, ensureRuntime, installRuntime, projectRoot, run, runtimeLock, signHelper } from "./distribution-lib.mjs";

export function backendNotices() {
  const backend = join(projectRoot, "backend"), meta = JSON.parse(readFileSync(join(backend, "dist/metafile.json"), "utf8"));
  const packages = new Map();
  for (const input of Object.keys(meta.inputs)) {
    if (!input.startsWith("node_modules/")) continue;
    let directory = dirname(join(backend, input));
    while (directory.startsWith(join(backend, "node_modules") + "/")) {
      const metadata = join(directory, "package.json");
      if (existsSync(metadata)) {
        const pkg = JSON.parse(readFileSync(metadata, "utf8"));
        if (!pkg.name || !pkg.version) { directory = dirname(directory); continue; }
        const files = readdirSync(directory).filter(name => /^(license|licence|copying|notice)([.-].*)?$/i.test(name));
        if (!files.length && pkg.name === "boolbase" && pkg.version === "1.0.0" && pkg.license === "ISC") {
          packages.set("boolbase@1.0.0", readFileSync(join(projectRoot, "scripts/licenses/boolbase-1.0.0-LICENSE.txt"), "utf8"));
          break;
        }
        if (!files.length) throw new Error(`ライセンス文書が見つかりません: ${pkg.name}`);
        packages.set(`${pkg.name}@${pkg.version}`, files.map(name => readFileSync(join(directory, name), "utf8")).join("\n\n"));
        break;
      }
      directory = dirname(directory);
    }
  }
  if (!packages.size) throw new Error("バックエンドのライセンス一覧を作成できませんでした。");
  return [...packages].sort(([a], [b]) => a.localeCompare(b)).map(([name, license]) => `===== ${name} =====\n${license}`).join("\n\n");
}

export async function packageBackend(resources) {
  resources = resolve(resources);
  if (basename(resources) !== "Resources" || basename(dirname(resources)) !== "Contents") {
    throw new Error("出力先にはappのContents/Resourcesを指定してください。");
  }
  if (process.env.ARCHS?.trim().split(/\s+/).length > 1) throw new Error("現段階は単一アーキテクチャのビルドに対応しています。");
  const runtime = await ensureRuntime();
  try {
    const destination = join(resources, "Backend");
    mkdirSync(destination, { recursive: true });
    const node = installRuntime(runtime, dirname(resources));
    copyFileSync(join(projectRoot, "backend/dist/worker.mjs"), join(destination, "worker.mjs"));
    writeFileSync(join(destination, "runtime.json"), JSON.stringify({ version: 1, nodeExecutable: "../../Helpers/node",
      nodeVersion: runtimeLock.version, architecture: process.arch, archiveSHA256: runtime.archive.sha256 }) + "\n");
    writeFileSync(join(resources, "Licenses/Backend-NOTICES.txt"), backendNotices());
    // Xcode signs the outer app after this build phase; its nested helper must be signed first.
    if (process.env.XCODE_VERSION_ACTUAL && process.env.CODE_SIGNING_ALLOWED !== "NO") {
      signHelper(node, process.env.EXPANDED_CODE_SIGN_IDENTITY || "-");
    }
    const result = JSON.parse(run(node, [join(destination, "worker.mjs")], {
      input: JSON.stringify({ version: 1, command: "health" }), env: cleanEnvironment, timeout: 10_000,
    }));
    if (!result.ok || result.version !== 1 || result.result?.protocolVersion !== 1) throw new Error("同梱バックエンドの起動確認に失敗しました。");
    console.log(`Node.js ${runtimeLock.version} (${process.arch}) をアプリに同梱しました。`);
  } finally { rmSync(runtime.directory, { recursive: true, force: true }); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3) throw new Error("出力先のContents/Resourcesが必要です。");
    await packageBackend(process.argv[2]);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}

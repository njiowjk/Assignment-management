import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const runtimeLock = JSON.parse(readFileSync(join(projectRoot, "scripts/node-runtime.json"), "utf8"));
export const cleanEnvironment = { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "en_US.UTF-8", TZ: "UTC" };

export function run(command, args, options = {}) {
  return execFileSync(command, args, { encoding: "utf8", timeout: 120_000, env: cleanEnvironment, ...options });
}
export function sha256(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
export function archiveFor(architecture) {
  if (!["arm64", "x64"].includes(architecture)) throw new Error("対応するMacのアーキテクチャではありません。");
  const archive = runtimeLock.archives[architecture];
  if (!/^\d+\.\d+\.\d+$/.test(runtimeLock.version) ||
      runtimeLock.source !== `https://nodejs.org/download/release/v${runtimeLock.version}/` ||
      archive.file !== `node-v${runtimeLock.version}-darwin-${architecture}.tar.xz` || !/^[a-f0-9]{64}$/.test(archive.sha256)) {
    throw new Error("Node.jsの固定バージョン情報が不正です。");
  }
  return { ...archive, url: runtimeLock.source + archive.file };
}
export function verifyArchive(bytes, expectedHash) {
  if (sha256(bytes) !== expectedHash) throw new Error("Node.jsアーカイブのSHA-256が一致しません。使用を中止しました。");
}

export async function ensureRuntime(architecture = process.arch) {
  const archive = archiveFor(architecture);
  const cache = join(projectRoot, ".build/node-runtime", runtimeLock.version, architecture);
  mkdirSync(cache, { recursive: true });
  const archivePath = join(cache, archive.file);
  let bytes;
  if (existsSync(archivePath)) bytes = readFileSync(archivePath);
  else {
    console.log(`公式Node.js ${runtimeLock.version} (${architecture}) を取得します…`);
    const response = await fetch(archive.url, { redirect: "error", signal: AbortSignal.timeout(120_000) });
    if (!response.ok || !response.body) throw new Error("公式Node.jsをダウンロードできませんでした。");
    const chunks = []; let length = 0;
    for await (const chunk of response.body) {
      length += chunk.length;
      if (length > 64 * 1024 * 1024) throw new Error("Node.jsアーカイブがサイズ制限を超えました。");
      chunks.push(Buffer.from(chunk));
    }
    bytes = Buffer.concat(chunks);
    verifyArchive(bytes, archive.sha256);
    writeFileSync(archivePath, bytes, { flag: "wx" });
  }
  // Recheck even a cached archive. Never execute a cached/external executable without re-extraction.
  verifyArchive(bytes, archive.sha256);
  const scratch = mkdtempSync(join(cache, "extract-"));
  try {
    const prefix = `node-v${runtimeLock.version}-darwin-${architecture}`;
    run("/usr/bin/tar", ["-xJf", archivePath, "-C", scratch, "--strip-components", "1", `${prefix}/bin/node`, `${prefix}/LICENSE`]);
    return { directory: scratch, executable: join(scratch, "bin/node"), license: join(scratch, "LICENSE"), archive };
  } catch (error) { rmSync(scratch, { recursive: true, force: true }); throw error; }
}

export function checkSystemDependencies(executable, { allowSwift = false } = {}) {
  const output = run("/usr/bin/otool", ["-L", executable]);
  const dependencies = output.split("\n").slice(1).map(line => line.trim().split(" (compatibility")[0]).filter(Boolean);
  if (!dependencies.length || dependencies.some(library => !library.startsWith("/usr/lib/") &&
      !library.startsWith("/System/Library/") && !(allowSwift && /^@rpath\/libswift[^/]+\.dylib$/.test(library)))) {
    throw new Error("実行ファイルがHomebrewなどの外部ライブラリに依存しています。配布を中止しました。");
  }
  return dependencies;
}

export function removeFinderInfo(target) {
  // Only generated artifact display metadata; never remove quarantine, ACLs, or provenance.
  try { run("/usr/bin/xattr", ["-d", "com.apple.FinderInfo", target], { stdio: "ignore" }); } catch {}
}

export function signHelper(helper, identity = "-") {
  const flags = ["--force", "--sign", identity, "--options", "runtime", identity === "-" ? "--timestamp=none" : "--timestamp"];
  removeFinderInfo(helper);
  run("/usr/bin/codesign", [...flags, "--identifier", "jp.example.UniversityTaskManager.node",
    "--entitlements", join(projectRoot, "AppBundle/Node.entitlements"), helper], { stdio: "inherit" });
}

export function signApp(app, identity = "-") {
  // FileProvider can re-add an empty FinderInfo between signing and strict validation.
  // Sign a content-identical private staging copy instead of fighting the provider or changing OS policy.
  const scratch = mkdtempSync(join(tmpdir(), "assignment-signing-"));
  try {
    const staged = join(scratch, "UniversityTaskManager.app");
    cpSync(app, staged, { recursive: true });
    const flags = ["--force", "--sign", identity, "--options", "runtime", identity === "-" ? "--timestamp=none" : "--timestamp"];
    signHelper(join(staged, "Contents/Helpers/node"), identity);
    run("/usr/bin/codesign", [...flags, "--identifier", "jp.example.UniversityTaskManager", staged], { stdio: "inherit" });
    run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged], { stdio: "inherit" });
    for (const file of ["Contents/Helpers/node", "Contents/MacOS/UniversityTaskManager", "Contents/_CodeSignature/CodeResources"]) {
      const source = join(staged, file), destination = join(app, file), next = destination + ".signed-next";
      mkdirSync(dirname(destination), { recursive: true });
      copyFileSync(source, next); chmodSync(next, statSync(source).mode & 0o777); renameSync(next, destination);
    }
    run("/usr/bin/codesign", ["--verify", "--deep", app], { stdio: "inherit" });
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

export function installRuntime(runtime, appContents) {
  const helper = join(appContents, "Helpers/node");
  mkdirSync(dirname(helper), { recursive: true });
  copyFileSync(runtime.executable, helper); chmodSync(helper, 0o755);
  checkSystemDependencies(helper);
  const licenses = join(appContents, "Resources/Licenses");
  mkdirSync(licenses, { recursive: true });
  copyFileSync(runtime.license, join(licenses, "Node.js-LICENSE.txt"));
  return helper;
}

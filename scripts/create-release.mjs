import { cpSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { projectRoot, run, sha256, signApp } from "./distribution-lib.mjs";
import { verifyBundle } from "./verify-app.mjs";

function argumentsFor(values) {
  let identity = "-", profile;
  while (values.length) {
    const argument = values.shift();
    if (argument === "--sign" && values[0]) identity = values.shift();
    else if (argument === "--notary-profile" && values[0]) profile = values.shift();
    else throw new Error("利用できるオプションは --sign 署名ID、--notary-profile 保存済みプロファイル名 です。");
  }
  if (identity !== "-" && !identity.startsWith("Developer ID Application:")) throw new Error("一般配布用にはDeveloper ID Application証明書を指定してください。");
  if (profile && identity === "-") throw new Error("公証にはDeveloper ID Application署名が必要です。");
  return { identity, profile };
}

let scratch, mounted = false;
try {
  const { identity, profile } = argumentsFor(process.argv.slice(2));
  if (identity !== "-") {
    const identities = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]);
    if (!identities.includes(`"${identity}"`)) throw new Error("指定されたDeveloper ID証明書がこのMacにありません。");
  }
  // The release build is separate from normal debug launch; it never restarts the running app.
  run("/bin/zsh", [join(projectRoot, "run.sh"), "--build-only", "--release", "--sign", identity], {
    env: process.env, stdio: "inherit", timeout: 600_000,
  });
  scratch = mkdtempSync(join(tmpdir(), "assignment-release-"));
  const source = join(projectRoot, ".build/UniversityTaskManager.app"), stage = join(scratch, "image");
  mkdirSync(stage);
  const app = join(stage, "UniversityTaskManager.app");
  cpSync(source, app, { recursive: true });
  signApp(app, identity);
  const verification = verifyBundle(app);
  const version = run("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", join(app, "Contents/Info.plist")]).trim();
  if (!/^\d+(\.\d+){1,2}$/.test(version)) throw new Error("配布バージョンの形式が不正です。");
  const mode = identity === "-" ? "local-preview" : (profile ? "notarized" : "developer-id-unnotarized");
  const name = `UniversityTaskManager-${version}-${verification.architecture}-${mode}`;
  const outputRoot = join(projectRoot, "dist"); mkdirSync(outputRoot, { recursive: true });
  const output = mkdtempSync(join(outputRoot, `${name}-`));
  const instructions = ["大学課題管理 - インストールと確認", "",
    "1. アプリが起動中の場合は終了します。", "2. UniversityTaskManager.appをApplicationsへドラッグします。",
    "3. Applicationsからアプリを開き、Moodle / WebClassへ初回ログインします。",
    "4. 設定で通知をONにし、テスト通知を確認します。自動起動はインストール後に設定してください。", "",
    identity === "-" ? "この版はローカル検証用のad-hoc署名です。Appleの公証済み一般配布版ではありません。" :
      "Developer ID署名済みです。公証の完了は配布元のverification.jsonのAcceptedと、公証チケットを確認してください。",
    "Gatekeeperや隔離属性を無効にする操作は行わないでください。", "",
    "予約済み通知は終了後も届くことがあります。終了中はLMSへ同期しません。",
    "課題データは各Mac内、ログイン情報は各MacのKeychainに保存します。この配布物には含みません。",
    "このビルドと異なるCPUアーキテクチャのMacやmacOS 13での実機確認は別途必要です。", "",
  ].join("\n");
  writeFileSync(join(stage, "はじめに.txt"), instructions);
  symlinkSync("/Applications", join(stage, "Applications"));
  // Never label a failed/unfinished image as a verified release.
  let dmg = join(output, `${name}.incomplete.dmg`);
  run("/usr/bin/hdiutil", ["create", "-volname", "UniversityTaskManager", "-srcfolder", stage, "-format", "UDZO", "-fs", "HFS+", dmg], {
    stdio: "inherit", timeout: 120_000,
  });
  if (identity !== "-") run("/usr/bin/codesign", ["--sign", identity, "--timestamp", dmg], { stdio: "inherit" });
  let notarization = { status: "not-submitted" };
  if (profile) {
    console.log("Appleの公証サービスへ提出します…");
    const submitted = JSON.parse(run("/usr/bin/xcrun", ["notarytool", "submit", dmg, "--keychain-profile", profile, "--wait", "--output-format", "json"], {
      timeout: 900_000,
    }));
    if (submitted.status !== "Accepted") throw new Error("Apple公証はAcceptedになりませんでした。配布せず、公証ログを確認してください。");
    run("/usr/bin/xcrun", ["stapler", "staple", dmg], { stdio: "inherit" });
    run("/usr/bin/xcrun", ["stapler", "validate", dmg], { stdio: "inherit" });
    notarization = { status: submitted.status, id: submitted.id };
  }
  run("/usr/bin/hdiutil", ["verify", dmg], { stdio: "inherit" });
  const mount = join(scratch, "mounted"); mkdirSync(mount);
  run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg], { stdio: "inherit" });
  mounted = mount;
  const imageVerification = verifyBundle(join(mount, "UniversityTaskManager.app"), { relocate: false });
  run("/usr/bin/hdiutil", ["detach", mount], { stdio: "inherit" }); mounted = false;
  const finalDMG = join(output, `${name}.dmg`); renameSync(dmg, finalDMG); dmg = finalDMG;
  const digest = sha256(readFileSync(dmg));
  writeFileSync(join(output, "SHA256SUMS.txt"), `${digest}  ${name}.dmg\n`);
  writeFileSync(join(output, "verification.json"), JSON.stringify({ version: 1, mode, appVersion: version,
    verification, imageVerification, notarization, sha256: digest, createdAt: new Date().toISOString() }, null, 2) + "\n");
  writeFileSync(join(output, "はじめに.txt"), instructions);
  console.log(`配布物の作成・検証が完了しました: ${dmg}`);
} catch (error) {
  console.error(error.message); process.exitCode = 1;
} finally {
  if (mounted) {
    try { run("/usr/bin/hdiutil", ["detach", mounted], { stdio: "inherit" }); mounted = false; } catch {}
  }
  if (scratch && !mounted) rmSync(scratch, { recursive: true, force: true });
}

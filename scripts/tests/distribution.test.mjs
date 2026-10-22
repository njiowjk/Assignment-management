import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { archiveFor, cleanEnvironment, runtimeLock, sha256, verifyArchive } from "../distribution-lib.mjs";
import { backendNotices } from "../package-backend.mjs";
import { validateLayout, validateRuntimeManifest } from "../verify-app.mjs";

const metadata = () => ({ version: 1, nodeExecutable: "../../Helpers/node", nodeVersion: runtimeLock.version,
  architecture: "arm64", archiveSHA256: archiveFor("arm64").sha256 });

test("distribution: runtime archives are pinned to official HTTPS for both host architectures", () => {
  for (const architecture of ["arm64", "x64"]) {
    const archive = archiveFor(architecture);
    assert.equal(new URL(archive.url).hostname, "nodejs.org");
    assert.match(archive.sha256, /^[a-f0-9]{64}$/);
    assert.ok(archive.file.includes(runtimeLock.version));
  }
});
test("distribution: unsupported architectures cannot select arbitrary archives", () => {
  for (const architecture of ["ia32", "../arm64", "", "universal"]) assert.throws(() => archiveFor(architecture));
});
test("distribution: archive corruption fails closed", () => {
  const bytes = Buffer.from("synthetic-runtime"); verifyArchive(bytes, sha256(bytes));
  assert.throws(() => verifyArchive(Buffer.from("modified-runtime"), sha256(bytes)), /SHA-256/);
});
test("distribution: child environment has no inherited Node/DYLD/credential settings", () => {
  assert.deepEqual(Object.keys(cleanEnvironment).sort(), ["LANG", "PATH", "TZ"]);
  assert.ok(!cleanEnvironment.PATH.includes("homebrew"));
});
test("distribution: valid relative runtime manifest is accepted", () => {
  assert.deepEqual(validateRuntimeManifest(metadata()), metadata());
});
for (const change of [{ version: 99 }, { nodeExecutable: "/opt/homebrew/bin/node" }, { nodeExecutable: "../../../node" },
  { nodeExecutable: "https://example.test/node" }, { architecture: "universal" }, { nodeVersion: "0.0.0" }, { archiveSHA256: "0".repeat(64) }]) {
  test(`distribution: reject invalid runtime metadata ${JSON.stringify(change)}`, () => {
    assert.throws(() => validateRuntimeManifest({ ...metadata(), ...change }));
  });
}

function fixture(action) {
  const scratch = mkdtempSync(join(tmpdir(), "assignment-layout-check-")), app = join(scratch, "App with spaces.app");
  const files = ["Info.plist", "MacOS/UniversityTaskManager", "Helpers/node", "Resources/Backend/worker.mjs",
    "Resources/Backend/runtime.json", "Resources/Licenses/Node.js-LICENSE.txt", "Resources/Licenses/Backend-NOTICES.txt", "_CodeSignature/CodeResources"];
  for (const file of files) {
    const destination = join(app, "Contents", file); mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, file.endsWith("runtime.json") ? JSON.stringify(metadata()) : "synthetic");
  }
  try { action(app); } finally { rmSync(scratch, { recursive: true, force: true }); }
}
test("distribution: allowlisted portable bundle layout accepts spaces", () => {
  fixture(app => assert.equal(validateLayout(app).architecture, "arm64"));
});
test("distribution: accidental credential/database/extra files are rejected", () => {
  for (const name of ["credentials.json", "tasks.sqlite", ".env", "node_modules"]) fixture(app => {
    writeFileSync(join(app, "Contents/Resources", name), "synthetic");
    assert.throws(() => validateLayout(app), /想定外/);
  });
});
test("distribution: helper symlinks are rejected even if their name is allowlisted", () => {
  fixture(app => {
    const node = join(app, "Contents/Helpers/node"); rmSync(node);
    symlinkSync("/usr/bin/true", node); assert.throws(() => validateLayout(app), /想定外/);
  });
});
test("distribution: missing required components are rejected", () => {
  fixture(app => { rmSync(join(app, "Contents/Resources/Backend/worker.mjs")); assert.throws(() => validateLayout(app)); });
});
test("distribution: licenses include actual bundled dependencies, including nested package.json layouts", () => {
  const notices = backendNotices();
  for (const name of ["cheerio", "css-select", "domhandler", "domutils", "entities", "htmlparser2", "boolbase", "jsbi", "@js-temporal/polyfill"]) {
    assert.ok(notices.includes(`===== ${name}@`), `missing ${name}`);
  }
  assert.ok(notices.includes("Copyright (c) 2014-2015, Felix Boehm"));
  assert.ok(!notices.includes("==== undefined"));
  assert.ok(!notices.includes("/Users/"));
});

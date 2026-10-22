import { resolve } from "node:path";
import { signApp } from "./distribution-lib.mjs";

try {
  if (process.argv.length < 3 || process.argv.length > 4) throw new Error("署名するappと、任意の署名IDを指定してください。");
  signApp(resolve(process.argv[2]), process.argv[3] ?? "-");
} catch (error) { console.error(error.message); process.exitCode = 1; }

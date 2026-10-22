import { build } from "esbuild";

await build({
  entryPoints: ["src/worker.ts"],
  outfile: "dist/worker.mjs",
  bundle: true,
  platform: "node",
  target: "node22",
  format: "esm",
  sourcemap: false,
});

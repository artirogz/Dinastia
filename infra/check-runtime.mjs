// Build-time check of the runner image, run by infra/Dockerfile as the last step of the runner stage.
//
// It proves, without starting any process, that every entry point compose and the docs call exists
// and that every package those bundles import is installed in the image:
//   1. each file in ENTRIES exists (dist/ paths produced by `npm run build:server`);
//   2. each bare import in those files ("pg-boss", "js-yaml/dist/x.js", "@scope/pkg") resolves to
//      node_modules/<package>/package.json, walking up from the file like Node does.
// Importing the bundles instead would start the worker and run migrations, so the check reads them as text.
//
//   node infra/check-runtime.mjs            from the app root (/app in the image)
//
// Exit code 0 and "runtime check passed" on success; a list of problems and exit code 1 otherwise.
import { existsSync, readFileSync } from "node:fs";
import { isBuiltin } from "node:module";
import { dirname, join, resolve } from "node:path";

const ENTRIES = ["dist/worker/index.js", "dist/db/migrate.js", "dist/scripts/import-content.js", "dist/scripts/admin.js"];

// esbuild prints string literals with double quotes; single quotes are accepted for safety.
const IMPORT_PATTERNS = [
  /\bfrom\s*["']([^"']+)["']/g, // import x from "pkg", export { x } from "pkg"
  /\bimport\s*["']([^"']+)["']/g, // import "pkg"
  /\bimport\s*\(\s*["']([^"']+)["']\s*\)/g, // import("pkg")
  /\brequire\s*\(\s*["']([^"']+)["']\s*\)/g, // require("pkg") through createRequire
];

/** Package name of a bare specifier: "a/b" -> "a", "@s/a/b" -> "@s/a". */
function packageName(spec) {
  const parts = spec.split("/");
  return spec.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
}

function isBare(spec) {
  return !spec.startsWith(".") && !spec.startsWith("/") && !spec.startsWith("#") && !/^[a-z]+:/i.test(spec);
}

function isInstalled(fromFile, pkg) {
  let dir = dirname(resolve(fromFile));
  for (;;) {
    if (existsSync(join(dir, "node_modules", pkg, "package.json"))) return true;
    const parent = dirname(dir);
    if (parent === dir) return false;
    dir = parent;
  }
}

const problems = [];
for (const entry of ENTRIES) {
  if (!existsSync(entry)) {
    problems.push(`missing entry point ${entry} (check the build:server script)`);
    continue;
  }
  const source = readFileSync(entry, "utf8");
  const packages = new Set();
  for (const pattern of IMPORT_PATTERNS) {
    for (const match of source.matchAll(pattern)) {
      const spec = match[1];
      if (isBare(spec) && !isBuiltin(spec)) packages.add(packageName(spec));
    }
  }
  for (const pkg of packages) {
    if (!isInstalled(entry, pkg)) problems.push(`${entry} imports "${pkg}", but node_modules/${pkg} is not in the image`);
  }
  console.log(`${entry}: ${packages.size} external package(s): ${[...packages].join(", ") || "none"}`);
}

if (problems.length > 0) {
  for (const problem of problems) console.error(`FAIL ${problem}`);
  process.exit(1);
}
console.log("runtime check passed");

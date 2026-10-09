// Mark every installed Playwright WebKit bundle as a background app (LSUIElement = true) and
// re-sign it ad hoc, so a crash of the test browser is not reported as a foreground application
// crash ("Playwright quit unexpectedly" on the CEO's screen, 2026-10-09). Run from `postinstall`
// right after `playwright install webkit`, so a reinstall keeps it. Idempotent: a bundle that
// already carries the key is left untouched (no rewrite, no re-sign).
//
// If re-signing fails the original Info.plist is restored and re-signed, so the browser is never
// left with a broken signature. Exit 1 if any bundle could not be patched.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const browsersRoot = (env = process.env) => {
  const configured = env.PLAYWRIGHT_BROWSERS_PATH;
  if (configured && configured !== "0") return configured;
  if (configured === "0") return path.join(__dirname, "..", "node_modules", "playwright-core", ".local-browsers");
  return path.join(os.homedir(), "Library", "Caches", "ms-playwright");
};

const webkitBundles = (root) => {
  if (!fs.existsSync(root)) return [];
  return fs
    .readdirSync(root)
    .filter((n) => /^webkit-/.test(n))
    .map((n) => path.join(root, n, "Playwright.app"))
    .filter((p) => fs.existsSync(path.join(p, "Contents", "Info.plist")));
};

const plist = (bundle) => path.join(bundle, "Contents", "Info.plist");

const isBackground = (bundle) => {
  try {
    return (
      execFileSync("plutil", ["-extract", "LSUIElement", "raw", "-o", "-", plist(bundle)], {
        stdio: ["ignore", "pipe", "ignore"],
      })
        .toString()
        .trim() === "true"
    );
  } catch (e) {
    return false;
  }
};

const sign = (bundle) => execFileSync("codesign", ["--force", "--deep", "-s", "-", bundle], { stdio: "ignore" });

// "patched" | "unchanged"; throws (after restoring the original) when signing fails.
const patch = (bundle) => {
  if (isBackground(bundle)) return "unchanged";
  const original = fs.readFileSync(plist(bundle));
  try {
    execFileSync("plutil", ["-replace", "LSUIElement", "-bool", "true", plist(bundle)], { stdio: "ignore" });
    sign(bundle);
  } catch (e) {
    fs.writeFileSync(plist(bundle), original);
    try {
      sign(bundle);
    } catch (e2) {
      /* report the first failure */
    }
    throw e;
  }
  return "patched";
};

const main = () => {
  const root = browsersRoot();
  const bundles = webkitBundles(root);
  if (bundles.length === 0) {
    console.log(`background-browser: no Playwright WebKit bundle under ${root}; nothing to patch`);
    return 0;
  }
  let failed = 0;
  for (const b of bundles) {
    try {
      console.log(`background-browser: ${patch(b)}: ${b}`);
    } catch (e) {
      failed++;
      console.error(`background-browser: FAILED (original restored): ${b}: ${e.message}`);
    }
  }
  return failed ? 1 : 0;
};

module.exports = { browsersRoot, webkitBundles, isBackground, patch };
if (require.main === module) process.exit(main());

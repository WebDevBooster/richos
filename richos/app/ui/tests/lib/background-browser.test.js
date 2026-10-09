// The installed Playwright WebKit bundles are background apps (LSUIElement) with a valid ad hoc
// signature, and patching is idempotent. A synthetic bundle covers the patch/no-op behavior; the
// real installed bundles cover "the key is actually there".
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const bb = require("./background-browser");

const verify = (b) => execFileSync("codesign", ["--verify", "--deep", "--strict", b], { stdio: "pipe" });
let failed = 0;
const check = (name, ok) => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}`);
  if (!ok) failed++;
};
const verifies = (b) => {
  try {
    verify(b);
    return true;
  } catch (e) {
    return false;
  }
};

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bgbrowser-"));
try {
  const app = path.join(tmp, "webkit-1", "Playwright.app");
  const info = path.join(app, "Contents", "Info.plist");
  fs.mkdirSync(path.join(app, "Contents", "MacOS"), { recursive: true });
  fs.writeFileSync(path.join(app, "Contents", "MacOS", "Playwright"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  fs.writeFileSync(
    info,
    '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Playwright</string><key>CFBundleIdentifier</key><string>org.webkit.Playwright</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>'
  );
  execFileSync("codesign", ["--force", "-s", "-", app], { stdio: "ignore" });

  check("synthetic bundle is found by the glob", bb.webkitBundles(tmp).length === 1);
  check("synthetic bundle starts as foreground", !bb.isBackground(app));
  check("first patch reports patched", bb.patch(app) === "patched");
  check("patched bundle carries LSUIElement", bb.isBackground(app));
  check("patched bundle passes codesign --verify", verifies(app));
  const before = fs.readFileSync(info);
  const mtime = fs.statSync(info).mtimeMs;
  check("second patch reports unchanged", bb.patch(app) === "unchanged");
  check(
    "second patch leaves the plist byte-identical and untouched",
    before.equals(fs.readFileSync(info)) && fs.statSync(info).mtimeMs === mtime
  );
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

const real = bb.webkitBundles(bb.browsersRoot());
console.log(`installed bundles under ${bb.browsersRoot()}: ${real.length}`);
for (const b of real) {
  const name = path.basename(path.dirname(b));
  check(`installed ${name} carries LSUIElement`, bb.isBackground(b));
  check(`installed ${name} passes codesign --verify`, verifies(b));
}
process.exit(failed ? 1 : 0);

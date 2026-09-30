// Source-shape guard for recheck R29: splash check 25c must read the resumed state inside the
// second keystroke, not in a round trip after `#splash` can already be gone (the shipping
// renderer removes it 220 ms after the resume). The suite run is the behavioral proof; this
// fails fast, without a browser, if the old sequence comes back.
//
// `SUITE_RACES_TESTS_DIR` points the guard at another copy of the suites (to prove it red on a
// tree that still has the defect); by default it reads the suites next to it.
"use strict";

const fs = require("fs");
const path = require("path");

const TESTS = process.env.SUITE_RACES_TESTS_DIR || path.resolve(__dirname, "..");
const src = fs.readFileSync(path.join(TESTS, "splash.js"), "utf8");
const from = src.indexOf('run.check("25c ');
const to = src.indexOf('run.check("25d ', from);
if (from < 0 || to < 0) {
  console.log("FAIL  cannot find splash check 25c; update this guard");
  process.exit(1);
}
const check = src.slice(from, to);
const second = check.lastIndexOf('keyboard.press("Space")');
const listener = check.search(/addEventListener\(\s*"keydown"/);
if (second < 0) {
  console.log("FAIL  splash check 25c no longer presses Space; update this guard");
  process.exit(1);
}
if (listener < 0 || listener > second) {
  console.log(
    "FAIL  splash check 25c presses the resume key without a keydown listener registered first, so it reads " +
      "#splash in a second round trip after the 220 ms removal can already have happened"
  );
  process.exit(1);
}
console.log("PASS  splash check 25c reads the resumed state inside the keystroke");

// Source-shape guard for hunt part 2, finding 29: splash check 17 must read the pinned state
// inside the keystroke, not in a second round trip after `#splash` can already be gone (the
// shipping renderer removes it 220 ms after the pin). The suite run is the behavioral proof;
// this fails fast, without a browser, if the old sequence comes back.
//
// `SUITE_RACES_TESTS_DIR` points the guard at another copy of the suites (to prove it red on a
// tree that still has the defect); by default it reads the suites next to it.
"use strict";

const fs = require("fs");
const path = require("path");

const TESTS = process.env.SUITE_RACES_TESTS_DIR || path.resolve(__dirname, "..");
const src = fs.readFileSync(path.join(TESTS, "splash.js"), "utf8");
const from = src.indexOf('run.check("17 ');
const to = src.indexOf('run.check("18 ', from);
if (from < 0 || to < 0) {
  console.log("FAIL  cannot find splash check 17; update this guard");
  process.exit(1);
}
const check = src.slice(from, to);
const press = check.indexOf('keyboard.press("a")');
const listener = check.search(/addEventListener\(\s*"keydown"/);
if (press < 0) {
  console.log("FAIL  splash check 17 no longer presses a key; update this guard");
  process.exit(1);
}
if (listener < 0 || listener > press) {
  console.log(
    "FAIL  splash check 17 presses a key without a keydown listener registered first, so it reads " +
      "#splash in a second round trip after the 220 ms removal can already have happened"
  );
  process.exit(1);
}
console.log("PASS  splash check 17 reads the pinned state inside the keystroke");

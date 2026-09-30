// Source-shape guard for hunt part 2, finding 43: `phone.js` must not reopen the EXPIRED sheet
// through the live-code geometry wait. The expired code is deliberately `hidden` (zero
// rectangle), so that wait can never become true and spent its whole 10 s guard on every run,
// then swallowed the timeout. The suite run is the behavioral proof; this fails fast, without
// a browser, if the expired branch goes back through it.
//
// `SUITE_RACES_TESTS_DIR` points the guard at another copy of the suites (to prove it red on a
// tree that still has the defect); by default it reads the suites next to it.
"use strict";

const fs = require("fs");
const path = require("path");

const TESTS = process.env.SUITE_RACES_TESTS_DIR || path.resolve(__dirname, "..");
const src = fs.readFileSync(path.join(TESTS, "phone.js"), "utf8");
const call = /reopen\(\s*expired\s*(,\s*\{[^}]*\})?\s*\)/.exec(src);
if (!call) {
  console.log("FAIL  phone.js no longer reopens the expired sheet; update this guard");
  process.exit(1);
}
if (!call[1] || !/expectCode\s*:\s*false/.test(call[1])) {
  console.log(
    "FAIL  phone.js reopens the expired sheet through the live-code wait, which spends its whole 10 s " +
      "guard on a code that is deliberately hidden"
  );
  process.exit(1);
}
console.log("PASS  the expired reopen skips the live-code wait");

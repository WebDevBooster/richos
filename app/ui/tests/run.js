// Run every browser suite in this directory, in order, and fail loudly.
//
// Each suite is a plain node script that exits non-zero on any failure, so it is runnable on
// its own (`node workers.js`) when you are working on one thing.
//
// THE INVENTORY IS DISCOVERED FROM DISK, NEVER TYPED. This file used to carry a hand-written
// SUITES array, and slice 6 landed `steering.js` that the array did not name — so a passing
// `run.js` would have reported "all 4 suites passed" while silently running none of its 24
// checks. That is the same defect, in its fifth costume, that produced "13/13 guards" over a
// typed list, "18/18 suites" over one directory's glob, and an install.sh whose HOOK_FILES had
// drifted from the registration. Add a suite and it runs; there is no second place to update.
//
// Zero suites found is exit 2, not "all 0 suites passed" — an empty inventory reporting green
// is exactly how an unreachable CI workflow looked green for months.

"use strict";

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

// `lib/` holds shared harness code, not suites. Everything else ending in .js is a suite.
const SUITES = fs
  .readdirSync(__dirname)
  .filter((f) => f.endsWith(".js") && f !== "run.js")
  .filter((f) => fs.statSync(path.join(__dirname, f)).isFile())
  .sort();

if (SUITES.length === 0) {
  console.error("no browser suites discovered in " + __dirname + " — refusing to report green over an empty inventory");
  process.exit(2);
}

console.log(`${SUITES.length} suite(s) discovered: ${SUITES.join(", ")}\n`);

let failed = 0;
for (const suite of SUITES) {
  const r = spawnSync(process.execPath, [path.join(__dirname, suite)], { stdio: "inherit" });
  if (r.status !== 0) failed++;
}

console.log(failed ? `\n${failed} suite(s) FAILED` : `\nall ${SUITES.length} suites passed`);
process.exit(failed ? 1 : 0);

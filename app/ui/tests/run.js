// Run every browser suite in this directory, in order, and fail loudly.
//
// Each suite is a plain node script that exits non-zero on any failure, so it is runnable on
// its own (`node workers.js`) when you are working on one thing.

"use strict";

const { spawnSync } = require("child_process");
const path = require("path");

const SUITES = ["workers.js", "inspector.js", "realbytes.js"];

let failed = 0;
for (const suite of SUITES) {
  const r = spawnSync(process.execPath, [path.join(__dirname, suite)], { stdio: "inherit" });
  if (r.status !== 0) failed++;
}

console.log(failed ? `\n${failed} suite(s) FAILED` : `\nall ${SUITES.length} suites passed`);
process.exit(failed ? 1 : 0);

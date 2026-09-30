// Fails while any UI suite passes its wait deadline as the page function's argument.
// See `wait-shape.js` for why (hunt part 2, finding 28).
"use strict";

const path = require("path");
const { findMisplacedTimeouts } = require("./wait-shape");

const hits = findMisplacedTimeouts(path.resolve(__dirname, ".."));
if (hits.length) {
  console.log("FAIL  " + hits.length + " waitForFunction call(s) pass { timeout } as the page function's argument, so the wait uses Playwright's 30 s default:");
  for (const h of hits) console.log("        " + h);
  console.log("      The deadline is the THIRD argument: waitForFunction(fn, null, { timeout }).");
  process.exit(1);
}
console.log("PASS  every waitForFunction deadline is in the third argument");

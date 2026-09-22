// THE COST OF THE NAVIGATION CAPTURE ON A PASSING RUN. A bench you run by hand when you want
// the number; it lives in `lib/` so `run.js` never discovers it as a suite.
//
//     node lib/navigation-bench.js             # 100 loads each way, the shipping index.html
//     node lib/navigation-bench.js 300         # more loads, tighter numbers
//
// `navigation-evidence.js` also runs a short pass of it on every run (check 6), so the bench
// cannot rot unnoticed and the number is in every run's output.
//
// `lib/navigation-evidence.js` attaches its listeners for the length of each `goto` and
// removes them when it settles. This measures what that costs, on ONE page, by alternating
// the observed `page.goto` with Playwright's own prototype method called on the same page —
// so both sides share the browser, the page, the cache and the moment, and the only
// difference between them is the capture. The order alternates every pair so neither side
// always goes first.
//
// It reports the median and the 95th percentile of each side and their difference. A
// difference inside the spread between two runs of this bench is noise, and should be
// reported as that.

"use strict";

const path = require("path");
const H = require("./harness.js");

function pct(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
}

/// `n` loads through the capture and `n` without it, alternating, on one page of `browser`.
async function measure(browser, n) {
  const url = "file://" + path.join(H.UI_DIR, "index.html");
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  try {
    const raw = Object.getPrototypeOf(page).goto;
    if (page.goto === raw) throw new Error("the capture is not installed on this page; nothing to compare");
    const sides = { observed: [], raw: [] };
    const once = async (side) => {
      const t0 = performance.now();
      if (side === "observed") await page.goto(url);
      else await raw.call(page, url);
      sides[side].push(performance.now() - t0);
    };
    // Warm the page and the file cache before anything is counted.
    for (let i = 0; i < 3; i++) await page.goto(url);
    for (let i = 0; i < n; i++) {
      const order = i % 2 ? ["observed", "raw"] : ["raw", "observed"];
      for (const side of order) await once(side);
    }
    const summary = {};
    for (const [side, xs] of Object.entries(sides)) {
      const s = xs.slice().sort((a, b) => a - b);
      summary[side] = { n: s.length, medianMs: +pct(s, 50).toFixed(3), p95Ms: +pct(s, 95).toFixed(3) };
    }
    summary.deltaMedianMs = +(summary.observed.medianMs - summary.raw.medianMs).toFixed(3);
    summary.deltaP95Ms = +(summary.observed.p95Ms - summary.raw.p95Ms).toFixed(3);
    return summary;
  } finally {
    await page.close();
  }
}

async function main() {
  if (String(process.env.RICHOS_UI_NAV_EVIDENCE || "").toLowerCase() === "off") {
    throw new Error("RICHOS_UI_NAV_EVIDENCE=off: there is no capture to measure");
  }
  const browser = await H.loadPlaywright().webkit.launch();
  try {
    console.log(JSON.stringify(await measure(browser, Number(process.argv[2] || 100)), null, 2));
  } finally {
    await browser.close();
  }
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { measure };

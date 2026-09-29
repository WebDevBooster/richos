// A HARNESS WHOSE EVERY ROUND TRIP TO THE PAGE IS SLOW — loaded with `node --require` in front
// of any suite in this directory:
//
//     node --require ./fixtures/slow-round-trips-preload.js home.js
//     RICHOS_UI_ROUND_TRIP_LAG_MS=600 node --require ./fixtures/slow-round-trips-preload.js memory-strategy.js
//
// WHAT IT REPRODUCES. The nightly runs the UI shards beside the mutation pool, the script suites
// and Cargo (`--gates-at-once all`). On that host a `page.evaluate` that answers in a few
// milliseconds on a quiet Mac answers in hundreds, while the PAGE's own timers keep running at
// their own speed. Any check that reads the page, spends a few round trips, and then asserts a
// wall-clock window or a count of the page's frames is measuring that latency, not the product
// (`docs/verification/2026-09-29-load-sensitive-checks-audit.md`, R1, R2, R6, R10). This file
// makes the latency deterministic and puts it on any Mac, without loading anyone's machine:
// every call below resolves with its real answer, `RICHOS_UI_ROUND_TRIP_LAG_MS` (default 250)
// milliseconds after the page gave it.
//
// A check that is load-independent passes under it. A check that is not goes red here the same
// way it goes red in a loaded nightly, which is how each fix in that audit was shown to be a fix.
// Nothing is changed in what the page does or answers; only when the harness hears it.
//
// It wraps the same seam `lib/navigation-evidence.js` wraps (the browser type's `launch`, then
// every context and page it makes), on top of that instrumentation rather than instead of it.
// It is announced once on stderr, so a run can be shown to have had it on.

"use strict";

const harness = require("../lib/harness");
const navigation = require("../lib/navigation-evidence");

const LAG_MS = Number(process.env.RICHOS_UI_ROUND_TRIP_LAG_MS || 250);
const MARK = Symbol.for("richos.slowRoundTrips");

/// `RICHOS_UI_ROUND_TRIP_LAG_ONLY=<regular expression>` confines the lag to the checks whose
/// name matches, so one check can be put on a very slow harness without paying that lag across
/// the whole suite. Unset, every round trip is slow. The check name is the one `createRun()`
/// hands `navigation-evidence.setCurrentCheck`, read through the same seam.
const ONLY = process.env.RICHOS_UI_ROUND_TRIP_LAG_ONLY ? new RegExp(process.env.RICHOS_UI_ROUND_TRIP_LAG_ONLY) : null;
let currentCheck = null;
const setCurrentCheck = navigation.setCurrentCheck;
navigation.setCurrentCheck = function (label, check) {
  currentCheck = check;
  return setCurrentCheck.apply(this, arguments);
};
const lagNow = () => (ONLY ? (currentCheck && ONLY.test(currentCheck) ? LAG_MS : 0) : LAG_MS);

/// The calls a suite in this directory uses to read or drive the page. Each is a round trip
/// through the Playwright server to the WebKit process and back.
const PAGE_CALLS = [
  "evaluate",
  "evaluateHandle",
  "waitForFunction",
  "waitForSelector",
  "click",
  "fill",
  "press",
  "type",
  "hover",
  "goto",
  "reload",
  "$",
  "$$",
  "$eval",
  "$$eval",
  "textContent",
  "innerText",
  "getAttribute",
  "isVisible",
  "focus",
];

const sleep = (ms) => (ms > 0 ? new Promise((r) => setTimeout(r, ms)) : Promise.resolve());

function slowPage(page) {
  if (!page || page[MARK]) return page;
  page[MARK] = true;
  for (const name of PAGE_CALLS) {
    const real = page[name];
    if (typeof real !== "function") continue;
    page[name] = async function (...args) {
      const answer = await real.apply(page, args);
      await sleep(lagNow());
      return answer;
    };
  }
  for (const input of ["keyboard", "mouse"]) {
    const dev = page[input];
    if (!dev) continue;
    for (const name of Object.getOwnPropertyNames(Object.getPrototypeOf(dev))) {
      const real = dev[name];
      if (name === "constructor" || typeof real !== "function") continue;
      dev[name] = async function (...args) {
        const answer = await real.apply(dev, args);
        await sleep(lagNow());
        return answer;
      };
    }
  }
  return page;
}

function slowContext(ctx) {
  if (!ctx || ctx[MARK]) return ctx;
  ctx[MARK] = true;
  const newPage = ctx.newPage.bind(ctx);
  ctx.newPage = async (...args) => slowPage(await newPage(...args));
  ctx.on("page", slowPage);
  for (const p of ctx.pages()) slowPage(p);
  return ctx;
}

function slowBrowser(browser) {
  if (!browser || browser[MARK]) return browser;
  browser[MARK] = true;
  // `Browser.newPage` goes through `this.newContext` (see `lib/navigation-evidence.js`), so
  // wrapping `newContext` covers both.
  const newContext = browser.newContext.bind(browser);
  browser.newContext = async (...args) => {
    const ctx = await newContext(...args);
    if (BUSY_MS > 0) await ctx.addInitScript(busyPage, BUSY_MS);
    return slowContext(ctx);
  };
  for (const c of browser.contexts()) slowContext(c);
  return browser;
}

/// `RICHOS_UI_PAGE_BUSY_MS=<ms>`: THE PAGE'S OWN MAIN THREAD IS BUSY, the other half of a loaded
/// host. Every page this browser opens holds its main thread for this many milliseconds, then
/// lets it run for 50, again and again, from its first script: its timers fire late, its frames
/// come slowly, and a debounced write or a re-render lands later than a sleep in the harness
/// bets it will. Off (0) unless set. Combine with `RICHOS_UI_ROUND_TRIP_LAG_MS=0` to load only
/// the page. The clock read is taken before any page script can replace it.
const BUSY_MS = Number(process.env.RICHOS_UI_PAGE_BUSY_MS || 0);
function busyPage(ms) {
  const now = performance.now.bind(performance);
  const later = setTimeout;
  const hold = () => {
    const end = now() + ms;
    while (now() < end) {
      /* a starved CPU */
    }
    later(hold, 50);
  };
  later(hold, 50);
}

const pw = harness.loadPlaywright();
for (const name of ["webkit", "chromium", "firefox"]) {
  const type = pw[name];
  if (!type || typeof type.launch !== "function" || type[MARK]) continue;
  const launch = type.launch.bind(type);
  type.launch = async (...args) => slowBrowser(await launch(...args));
  type[MARK] = true;
}

process.stderr.write(`slow-round-trips: page round trips answer ${LAG_MS}ms late${ONLY ? " inside checks matching " + ONLY : ""}\n`);
if (BUSY_MS > 0) process.stderr.write(`slow-round-trips: every page's main thread is busy ${BUSY_MS}ms of every ${BUSY_MS + 50}ms\n`);

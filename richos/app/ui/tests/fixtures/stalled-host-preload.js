// A HOST TOO BUSY TO RUN THIS PROCESS ON TIME — loaded with `node --require` (directly, or
// through `NODE_OPTIONS` so a child suite inherits it), with either knob or both:
//
//     RICHOS_UI_FREEZE_AFTER_GOTO_MS=2500 node --require ./fixtures/stalled-host-preload.js navigation-evidence.js
//     RICHOS_UI_SPAWN_LAG_MS=6000         node --require ./fixtures/stalled-host-preload.js navigation-evidence.js
//
// WHAT IT REPRODUCES, and it is the other half of `slow-round-trips-preload.js`. That file makes
// the PAGE answer late; this one makes THIS process late, which is what a nightly host with
// three gates side by side does to it (`docs/verification/2026-09-29-load-sensitive-checks-audit.md`,
// R6; nightly `20260929T044015Z-588457c3`, load average 13.0 on 10 cores with 432 MB free):
//
//   RICHOS_UI_FREEZE_AFTER_GOTO_MS  50 ms after every `page.goto` is issued, this whole process
//                                   stops for this long: a descheduled Node. Playwright's server
//                                   runs in this process, so the navigation's own deadline is
//                                   armed before the freeze and DELIVERED after it, exactly as on
//                                   a starved CPU. Anchored to the navigation rather than
//                                   periodic, so the delay it causes is the same every run.
//   RICHOS_UI_SPAWN_LAG_MS          every `child_process.spawnSync` waits this long before it
//                                   starts: fork and exec on a host that is swapping.
//
//   RICHOS_UI_STALLED_HOST_ONLY     a regular expression on the script's file name; in any other
//                                   process this file does nothing. With `NODE_OPTIONS` every
//                                   node process inherits the preload, so this is how the
//                                   condition is put on a child suite
//                                   (`fixtures/navigation-hang-suite.js`) and not on the suite
//                                   that spawns it.
//
// Neither changes what anything answers, only when. Each is announced once on stderr, so a run
// can be shown to have had it on. With neither set this file refuses, loudly, rather than
// quietly simulating nothing.

"use strict";

const cp = require("child_process");
const path = require("path");

const ONLY = process.env.RICHOS_UI_STALLED_HOST_ONLY ? new RegExp(process.env.RICHOS_UI_STALLED_HOST_ONLY) : null;
const here = ONLY ? ONLY.test(path.basename(process.argv[1] || "")) : true;
const FREEZE_MS = here ? Number(process.env.RICHOS_UI_FREEZE_AFTER_GOTO_MS || 0) : 0;
const SPAWN_LAG_MS = here ? Number(process.env.RICHOS_UI_SPAWN_LAG_MS || 0) : 0;
const MARK = Symbol.for("richos.stalledHost");

if (here && !(FREEZE_MS > 0) && !(SPAWN_LAG_MS > 0)) {
  process.stderr.write(
    "stalled-host: neither RICHOS_UI_FREEZE_AFTER_GOTO_MS nor RICHOS_UI_SPAWN_LAG_MS is set; refusing to run a 'stalled host' that is not stalled\n"
  );
  process.exit(2);
}

/// A synchronous sleep that burns no CPU: the whole thread waits, which is what a descheduled
/// process looks like from inside it.
function blockFor(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

if (SPAWN_LAG_MS > 0) {
  const realSpawnSync = cp.spawnSync;
  cp.spawnSync = function laggedSpawnSync() {
    blockFor(SPAWN_LAG_MS);
    return realSpawnSync.apply(this, arguments);
  };
  process.stderr.write(`stalled-host: every spawnSync starts ${SPAWN_LAG_MS}ms late (pid ${process.pid})\n`);
}

if (FREEZE_MS > 0) {
  const freezingPage = (page) => {
    if (!page || page[MARK]) return page;
    page[MARK] = true;
    const goto = page.goto;
    page.goto = function (...args) {
      setTimeout(() => blockFor(FREEZE_MS), 50);
      return goto.apply(page, args);
    };
    return page;
  };
  const freezingContext = (ctx) => {
    if (!ctx || ctx[MARK]) return ctx;
    ctx[MARK] = true;
    const newPage = ctx.newPage.bind(ctx);
    ctx.newPage = async (...args) => freezingPage(await newPage(...args));
    ctx.on("page", freezingPage);
    return ctx;
  };
  const instrument = (pw) => {
    for (const name of ["webkit", "chromium", "firefox"]) {
      const type = pw && pw[name];
      if (!type || typeof type.launch !== "function" || type[MARK]) continue;
      const launch = type.launch.bind(type);
      type.launch = async (...args) => {
        const browser = await launch(...args);
        const newContext = browser.newContext.bind(browser);
        browser.newContext = async (...a) => freezingContext(await newContext(...a));
        return browser;
      };
      type[MARK] = true;
    }
    return pw;
  };
  // THE HARNESS IS HOOKED WHEN THE SUITE LOADS IT, NOT HERE. Loading it from a preload would load
  // `lib/navigation-evidence.js` before any preload after this one, and that module takes its
  // `spawnSync` at load time: `fixtures/loaded-host-preload.js`, loaded after this file by
  // `navigation-evidence.js` check 7, would then never reach it.
  const Module = require("module");
  const load = Module._load;
  Module._load = function (request) {
    const m = load.apply(this, arguments);
    if (/(^|[\\/])lib[\\/]harness(\.js)?$/.test(request) && m && typeof m.loadPlaywright === "function" && !m[MARK]) {
      m[MARK] = true;
      const loadPlaywright = m.loadPlaywright;
      m.loadPlaywright = function () {
        return instrument(loadPlaywright.apply(this, arguments));
      };
    }
    return m;
  };
  process.stderr.write(`stalled-host: this process freezes ${FREEZE_MS}ms, 50ms after every page.goto (pid ${process.pid})\n`);
}

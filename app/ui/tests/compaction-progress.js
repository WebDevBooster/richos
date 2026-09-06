// THE PACED BAR — a bar over a wait whose length nobody knows, held to the one thing that
// makes it honest: it never claims a completion it does not have.
//
// The CEO asked, 2026-09-06, whether the compaction row could carry a bar like the splash
// screen's. He was told a bar would have to fabricate progress, because the duration is
// unknown, and he rejected that and specified the design himself:
//
//   *"It doesn't need to know. It just needs to move to almost full with the expected minimum
//    time and then stay at 'almost full' until all finished etc."*
//
// So the bar climbs over the SHORTEST compaction ever measured — 38138 ms, the minimum of 16
// committed `compact_boundary` frames — and then it HOLDS. Reaching almost-full and stopping
// is itself a true signal (this one is taking longer than the fastest case) where a bar that
// stalls mid-way looks broken and a bar that completes early lies.
//
// WHAT THIS SUITE IS FOR, one line each:
//
//   1. The pace is the RECORD's. The minimum is re-derived here from the committed frames on
//      every run and checked against the constant the product ships, so the two cannot drift.
//   2. It climbs, and then it HOLDS — at 38.1s, at 45s and at 62.029s (the longest boundary
//      ever measured) the bar is in exactly the same place, and it is never full.
//   3. Only a frame off the wire fills it. Time passing never does.
//   4. A compaction FASTER than the floor completes gracefully — the case the CEO did not
//      name, and the one that decides whether the whole thing is honest.
//   5. A dead turn does not leave a bar sitting at almost-full looking alive.
//   6. No number anywhere: no text, no `aria-valuenow`, no `role="progressbar"`.
//   7. A row with no measured floor gets no bar at all.
//   8. Reduced motion still advances the bar, and animates nothing.
//   9. WCAG AA, computed from the rendered DOM, in both themes, on all three boundaries.
//
// IT DRIVES THE SHIPPING RENDERER, and the payload it emits is the crate's own shape — the
// field name is read out of `timeline.rs` and the span out of `machinery.rs` at run time, so
// the day either is renamed this suite fails rather than testing a wire that stopped
// existing. (`compaction-notice.js` reads that file for the same reason and for its own
// three sentences; this suite extends nothing of its own and duplicates its page harness
// deliberately, so one suite cannot break another by changing a fixture.)
//
// NO AUDIO PATH IS TOUCHED: headless WebKit, no voice mode, no output device.
//
// RUN:  node compaction-progress.js
//       RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node compaction-progress.js
//       RICHOS_PACE_FRAMES=<dir> node compaction-progress.js     # also writes PNGs

"use strict";

const path = require("path");
const fs = require("fs");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");
const C = require("./lib/contrast");

const APP = "file://" + path.join(UI_DIR, "index.html");
const REPO = path.resolve(UI_DIR, "..", "..");
const CRATE = path.join(REPO, "app", "crates", "richos-core", "src");
const FRAME_DIR = process.env.RICHOS_PACE_FRAMES || null;

// ---------------------------------------------------------------------------------------
// THE RECORD, AND THE PRODUCT'S CLAIM ABOUT IT
// ---------------------------------------------------------------------------------------

/// Every compaction ever measured by this project, in milliseconds, straight out of the
/// committed frames. `compact_boundary` arrives at the millisecond a pause ends and carries
/// the authoritative `duration_ms` for the span that just finished, so summing them over
/// every cell IS the population.
function measuredBoundaries() {
  const dirs = [
    path.join(REPO, "docs", "verification", "inner-doctrine-opens-2026-09-06", "raw"),
    path.join(REPO, "docs", "verification", "compaction-notice-2026-09-06", "raw"),
  ];
  const out = [];
  for (const dir of dirs) {
    assert(fs.existsSync(dir), "the committed evidence this bar is paced on is gone: " + dir);
    for (const name of fs.readdirSync(dir).sort()) {
      if (!name.endsWith(".jsonl") || name.endsWith(".timed.jsonl")) continue;
      for (const l of fs.readFileSync(path.join(dir, name), "utf8").split("\n")) {
        if (!l.trim()) continue;
        let f;
        try {
          f = JSON.parse(l);
        } catch (_e) {
          continue;
        }
        if (f.type === "system" && f.subtype === "compact_boundary" && f.compact_metadata) {
          out.push({ cell: name, ms: f.compact_metadata.duration_ms });
        }
      }
    }
  }
  return out;
}

/// The span the crate ships, read from its own source. A `const NAME: u64 = 38_138;`, with
/// rustc's numeric underscores removed.
function rustConstant(file, name) {
  const src = fs.readFileSync(path.join(CRATE, file), "utf8");
  const m = src.match(new RegExp("const\\s+" + name + "\\s*:\\s*u64\\s*=\\s*([0-9_]+)\\s*;"));
  assert(m, file + " no longer declares " + name + " — this suite is pacing a bar on a number the product stopped shipping");
  return parseInt(m[1].replace(/_/g, ""), 10);
}

/// The wire field the renderer keys the bar on, proven to exist on the Rust item rather than
/// assumed. `#[serde(rename_all = "camelCase")]` on the variant turns `measured_min_ms` into
/// `measuredMinMs`, so this asserts the snake_case field and derives the JSON name from it.
function wireFieldName() {
  const src = fs.readFileSync(path.join(CRATE, "timeline.rs"), "utf8");
  assert(
    /\n\s*measured_min_ms:\s*Option<u64>,/.test(src),
    "timeline.rs's Activity no longer carries `measured_min_ms` — the bar's whole input is gone"
  );
  return "measuredMinMs";
}

// ---------------------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------------------

/// Captures every listener `main.js` registers, hangs `send_message`, and installs a
/// controllable clock — `waiting-state.js`'s shape, for its reasons: `send_message` resolving
/// only at the end of a turn IS the shipping contract, and a frozen clock makes every
/// position below a function of the skew alone rather than of how fast this machine is.
const INIT = `
window.__TAP = { listeners: {}, hang: false };
(function () {
  const BASE = Date.now();
  window.__CLOCK = { skew: 0 };
  Date.now = function () { return BASE + window.__CLOCK.skew; };
})();
let _rb;
Object.defineProperty(window, "RichBridge", {
  configurable: true,
  get() { return _rb; },
  set(v) {
    const ol = v.listen.bind(v), oi = v.invoke.bind(v);
    v.listen = (name, cb) => { (window.__TAP.listeners[name] = window.__TAP.listeners[name] || []).push(cb); return ol(name, cb); };
    v.invoke = (cmd, args) => (window.__TAP.hang && cmd === "send_message") ? new Promise(() => {}) : oi(cmd, args);
    _rb = v;
  }
});
window.__emit = (name, payload) => (window.__TAP.listeners[name] || []).forEach((cb) => cb({ payload }));
`;

async function openApp(browser, opts) {
  const o = opts || {};
  const page = await browser.newPage({
    viewport: { width: 1280, height: 860 },
    reducedMotion: o.reducedMotion || "no-preference",
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.addInitScript((t) => {
    try {
      window.localStorage.setItem("richos-theme", t);
      window.localStorage.setItem("richos-font-scale", "100");
      window.localStorage.setItem("richos-mock-config", JSON.stringify({ theme: t, font_scale: 100, user_name: null }));
    } catch (e) {
      /* storage unavailable; theme-boot falls back to the shipped default */
    }
  }, o.theme || "dark");
  await page.addInitScript(INIT);
  await page.goto(APP);
  await page
    .evaluate(() => {
      const s = window.RichSplash;
      if (s && s.state && s.state.shown && !s.state.reason) s.yieldNow("compaction-progress-suite");
    })
    .catch(() => {});
  await page.waitForFunction(() => !document.getElementById("splash"), { timeout: 8000 }).catch(() => {});
  await page.waitForFunction("typeof window.RichHome === 'object'", { timeout: 8000 }).catch(() => {});
  await page.evaluate(() => {
    if (window.RichHome && window.RichHome.isOpen()) window.RichHome.hide("compaction-progress-suite");
  });
  await page.waitForFunction(() => { const h = document.getElementById("home"); return !h || h.hidden; }, { timeout: 8000 }).catch(() => {});
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

async function startTurn(page, turnId) {
  await page.evaluate(() => { window.__TAP.hang = true; });
  const fence = await page.evaluate(() => {
    const m = window.__RICHOS_TIMELINE__();
    return { entityId: m.entityId, threadId: m.threadId, bindingRevision: m.bindingRevision };
  });
  await page.fill("#input", "What is in the Q4 folder?");
  await page.press("#input", "Enter");
  await page.evaluate(
    (o) => {
      const startedAt = Date.now();
      window.__emit("rich://turn-status", Object.assign({}, o.fence, {
        turnId: o.turnId, status: "queued", startedAt: null, activeDurationMs: null, visibility: "ceo", at: startedAt,
      }));
      window.__emit("rich://turn-status", Object.assign({}, o.fence, {
        turnId: o.turnId, status: "working", startedAt, activeDurationMs: null, visibility: "ceo", at: startedAt,
      }));
    },
    { fence, turnId }
  );
  return fence;
}

/// ONE `rich://activity-upserted`, in the crate's own shape.
///
/// `startedAt` is pinned to the span's OPENING instant on every frame of it, exactly as the
/// crate does: `merge_into` keeps the opening record's `at`, so a heartbeat 30 seconds in
/// still reports the instant the pause began. A suite that let it drift would be testing a
/// bar that restarts itself twice a minute.
async function emitRow(page, fence, o) {
  await page.evaluate(
    (a) => {
      const at = Date.now();
      const p = Object.assign({}, a.fence, {
        kind: "activity",
        id: a.id,
        turnId: a.turnId,
        activityType: "other",
        state: a.state,
        summary: a.summary,
        detailRef: a.id,
        sequence: 0,
        slot: "stream",
        createdAt: a.startedAt,
        startedAt: a.startedAt,
        visibility: "ceo",
        at,
      });
      if (a.minMs !== null && a.minMs !== undefined) p[a.field] = a.minMs;
      if (a.state === "completed" || a.state === "failed") p.completedAt = at;
      window.__emit("rich://activity-upserted", p);
    },
    Object.assign({ fence }, o)
  );
}

async function endTurn(page, fence, turnId, status) {
  await page.evaluate(
    (o) => {
      window.__emit("rich://turn-status", Object.assign({}, o.fence, {
        turnId: o.turnId, status: o.status, startedAt: Date.now(), activeDurationMs: 1000, visibility: "ceo", at: Date.now(),
      }));
    },
    { fence, turnId, status }
  );
}

const advance = (page, ms) => page.evaluate((n) => { window.__CLOCK.skew += n; }, ms);

/// Repaint on the band's OWN one-second interval rather than by calling a renderer.
const tick = (page) => page.waitForTimeout(1100);

/// Everything about the bar that can be read without asking it a question it cannot answer.
/// `position` is the product's own pure function (`waitBandCopy`), `width` is what was
/// actually written to the element, and `paintedPx` is what the compositor ended up with —
/// three views that have to agree.
async function readBar(page) {
  return page.evaluate(() => {
    const w = window.__RICHOS_WAIT__();
    const band = document.getElementById("turn-wait");
    const track = document.querySelector(".wait-pace");
    const fill = document.querySelector(".wait-pace-fill");
    return {
      band: !!band,
      detail: band ? band.querySelector(".wait-detail").textContent : null,
      time: band ? band.querySelector(".wait-time").textContent : null,
      tone: band ? band.dataset.tone : null,
      present: !!track && !track.hidden,
      position: w && w.copy && w.copy.pace ? w.copy.pace.position : null,
      done: w && w.copy && w.copy.pace ? w.copy.pace.done : null,
      landMs: w && w.copy && w.copy.pace ? w.copy.pace.landMs : null,
      width: fill ? fill.style.width : null,
      transition: fill ? fill.style.transition : null,
      almost: w ? w.paceAlmost : null,
      landFullMs: w ? w.paceLandFullMs : null,
      landMinMs: w ? w.paceLandMinMs : null,
      trackPx: track ? track.clientWidth : null,
      paintedPx: fill ? fill.getBoundingClientRect().width : null,
      text: track ? track.textContent : null,
      attrs: track ? Array.from(track.attributes).map((a) => a.name + "=" + a.value).join(" ") : null,
      role: track ? track.getAttribute("role") : null,
    };
  });
}

const pct = (p) => (p === null || p === undefined ? "(no bar)" : (p * 100).toFixed(2) + "%");

/// The fraction actually written to the element. WebKit normalizes an inline
/// `width: 92.000%` back to `92%` when it is read again, so the string that comes out of
/// `style.width` is not the string that went in and only its VALUE can be compared.
const widthFraction = (w) => {
  if (!w) return null;
  const m = String(w).match(/^([0-9.]+)%$/);
  return m ? parseFloat(m[1]) / 100 : null;
};

async function frame(page, name) {
  if (!FRAME_DIR) return;
  fs.mkdirSync(FRAME_DIR, { recursive: true });
  await page.screenshot({ path: path.join(FRAME_DIR, name + ".png") });
}

// ---------------------------------------------------------------------------------------

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("the paced bar — WebKit");

  const BOUNDARIES = measuredBoundaries();
  const FLOOR = rustConstant("machinery.rs", "COMPACTION_MEASURED_MIN_MS");
  const FIELD = wireFieldName();
  const SENTENCE = "Making room to keep going";
  const ENDED = "Made room to keep going";

  // =====================================================================================
  // 1. THE PACE IS THE RECORD'S
  // =====================================================================================

  await run.check("the span the bar is paced on is re-derived from the committed frames, not typed", async () => {
    assert(BOUNDARIES.length >= 16, "expected at least the 16 committed boundaries, found " + BOUNDARIES.length);
    const ms = BOUNDARIES.map((b) => b.ms).sort((a, b) => a - b);
    const min = ms[0];
    const max = ms[ms.length - 1];
    const mean = ms.reduce((a, b) => a + b, 0) / ms.length;
    assertEqual(
      FLOOR,
      min,
      "machinery.rs ships " + FLOOR + " ms but the shortest compaction in the committed record is " + min + " ms"
    );
    // The minimum and not the mean: paced on the mean the bar would already be holding on
    // half of these and still climbing on the other half, so half of all compactions would
    // see it jump forward at the end from wherever it had got to.
    const holdingAtMean = ms.filter((v) => v <= mean).length;
    assert(FLOOR < mean, "the floor must be the minimum, not a central value");
    return (
      "n=" + ms.length + "  min=" + min + "  max=" + max + "  mean=" + mean.toFixed(1) + " ms" +
      "\n          COMPACTION_MEASURED_MIN_MS = " + FLOOR + "  (wire field: " + FIELD + ")" +
      "\n          paced on the mean, " + holdingAtMean + " of " + ms.length + " would already be holding and " +
      (ms.length - holdingAtMean) + " still climbing" +
      "\n          " + ms.join(" ")
    );
  });

  // =====================================================================================
  // 2 and 3. IT CLIMBS, IT HOLDS, AND ONLY THE WIRE FILLS IT
  //
  // One page, driven on the wire's own cadence: the announcement, a heartbeat every 30.000s
  // (measured twice in `cellT1`), and an ending. Without the heartbeats the band would go
  // quiet at QUIET_AFTER_MS and take the bar with it, which is check 5's subject.
  // =====================================================================================

  const held = await openApp(browser, { theme: "dark" });
  const heldFence = await startTurn(held, "t_hold");
  const readings = [];

  await run.check("it climbs over the measured floor and then HOLDS, short of full", async () => {
    const t0 = await held.evaluate(() => Date.now());
    await emitRow(held, heldFence, { turnId: "t_hold", id: "mach_hold", state: "running", summary: SENTENCE, startedAt: t0, minMs: FLOOR, field: FIELD });
    let at = 0;
    const seen = [];
    // 30000 and 60000 carry a heartbeat, exactly as the wire does.
    for (const [ms, beat, note] of [
      [5000, false, ""],
      [19069, false, "half the floor"],
      [30000, true, "the wire's 30.000s heartbeat"],
      [FLOOR, false, "the shortest compaction ever measured"],
      [45000, false, "past every fast case"],
      [60000, true, "the second heartbeat"],
      [62029, false, "the LONGEST boundary ever measured"],
    ]) {
      await advance(held, ms - at);
      at = ms;
      if (beat) await emitRow(held, heldFence, { turnId: "t_hold", id: "mach_hold", state: "running", summary: SENTENCE, startedAt: t0, minMs: FLOOR, field: FIELD });
      await tick(held);
      const b = await readBar(held);
      readings.push(b);
      seen.push(String(ms).padStart(6) + " ms  " + pct(b.position).padStart(7) + "  " + b.width.padStart(8) + "  " + b.detail + (note ? "   (" + note + ")" : ""));
    }
    await frame(held, "held-at-almost-dark");

    const almost = readings[0].almost;
    assert(almost > 0.85 && almost < 0.97, "almost-full is " + almost + ", which is neither almost nor full");
    for (const b of readings) {
      assert(b.present, "the bar left the screen while the compaction was still being described");
      assert(b.position < 1, "the bar reached FULL on time passing alone, at " + pct(b.position));
      assert(b.position <= almost + 1e-9, "the bar went past almost-full without an ending: " + pct(b.position));
      assert(b.tone === "working", "the band went " + b.tone + " while the wire was still beating");
    }
    for (let i = 1; i < readings.length; i++) {
      assert(readings[i].position >= readings[i - 1].position - 1e-9, "the bar went BACKWARDS between readings " + (i - 1) + " and " + i);
    }
    // The hold, which is the CEO's whole design: three readings spanning 23.9 seconds, all
    // in exactly the same place.
    const hold = readings.slice(3);
    for (const b of hold) {
      assertEqual(b.position, almost, "the bar moved during the hold");
      assert(
        Math.abs(widthFraction(b.width) - almost) < 1e-5,
        "the painted width moved during the hold: " + b.width + " against " + pct(almost)
      );
    }
    // And what was WRITTEN is what was PAINTED, to within a subpixel.
    const last = readings[readings.length - 1];
    const expectPx = last.trackPx * almost;
    assert(
      Math.abs(last.paintedPx - expectPx) < 1.5,
      "the compositor painted " + last.paintedPx.toFixed(1) + "px where " + expectPx.toFixed(1) + "px was asked for"
    );
    return seen.join("\n          ") + "\n          held still for " + (62029 - FLOOR) + " ms at " + pct(almost) +
      ", painted " + last.paintedPx.toFixed(1) + "px of a " + last.trackPx + "px track";
  });

  await run.check("only a frame off the wire fills it, and it lands in 180ms from almost-full", async () => {
    const before = await readBar(held);
    assertEqual(before.position, before.almost, "the bar should still be holding when the ending arrives");
    await emitRow(held, heldFence, { turnId: "t_hold", id: "mach_hold", state: "completed", summary: ENDED, startedAt: await held.evaluate(() => Date.now() - 62029), minMs: FLOOR, field: FIELD });
    const after = await readBar(held);
    assertEqual(after.position, 1, "the ending did not fill the bar");
    assertEqual(widthFraction(after.width), 1, "the ending did not fill the bar on screen: " + after.width);
    assertEqual(after.detail.indexOf(ENDED), 0, "the sentence did not change with the bar: " + after.detail);
    // From almost-full there are 8 points to travel, which at one bar-length per 700ms is
    // 56ms — under the floor, so the ordinary landing gets the floor.
    assertEqual(after.landMs, after.landMinMs, "the ordinary landing is the floor, not a sweep");
    assert(/^width 180ms /.test(after.transition), "the landing transition is " + JSON.stringify(after.transition));
    await frame(held, "landed-dark");
    await tick(held);
    const settled = await readBar(held);
    assert(
      Math.abs(settled.paintedPx - settled.trackPx) < 1.5,
      "after the landing the fill is " + settled.paintedPx.toFixed(1) + "px of a " + settled.trackPx + "px track"
    );
    return "held at " + pct(before.position) + " -> " + pct(after.position) + " on `compact_result`, " +
      after.landMs + "ms, painted " + settled.paintedPx.toFixed(1) + "/" + settled.trackPx + "px";
  });

  await held.close();

  // =====================================================================================
  // 4. FASTER THAN THE FLOOR — the case he did not name
  // =====================================================================================

  await run.check("a compaction that finishes faster than the floor catches up rather than snapping", async () => {
    const page = await openApp(browser, { theme: "dark" });
    const fence = await startTurn(page, "t_fast");
    const seen = [];

    // 8 seconds: a fifth of the shortest wait ever measured, and the bar is a quarter along.
    const t0 = await page.evaluate(() => Date.now());
    await emitRow(page, fence, { turnId: "t_fast", id: "mach_fast", state: "running", summary: SENTENCE, startedAt: t0, minMs: FLOOR, field: FIELD });
    await advance(page, 8000);
    await tick(page);
    const mid = await readBar(page);
    seen.push("  8000 ms  " + pct(mid.position).padStart(7) + "  climbing");
    assert(mid.position > 0.2 && mid.position < 0.4, "8s of a 38.1s floor should be about a quarter along, got " + pct(mid.position));

    await emitRow(page, fence, { turnId: "t_fast", id: "mach_fast", state: "completed", summary: ENDED, startedAt: t0, minMs: FLOOR, field: FIELD });
    const done = await readBar(page);
    seen.push("  ending    " + pct(done.position).padStart(7) + "  catch-up " + Math.round(done.landMs) + "ms");
    assertEqual(done.position, 1, "an early ending must still fill the bar — the wait IS over");

    // NOT A SNAP: it travels at one bar-length per `landFullMs`, so a longer distance takes
    // longer, and it is never below the floor that makes a movement read as a movement.
    const expected = (1 - mid.position) * done.landFullMs;
    assert(
      Math.abs(done.landMs - expected) < 1,
      "the catch-up is " + done.landMs + "ms where a fixed speed over " + pct(1 - mid.position) + " gives " + expected.toFixed(0) + "ms"
    );
    assert(done.landMs >= done.landMinMs, "the catch-up is below the floor at " + done.landMs + "ms — that is a snap");
    assert(done.landMs > mid.landMinMs * 1.5, "an early ending should be visibly slower than the ordinary landing");
    assert(new RegExp("^width " + Math.round(done.landMs) + "ms ").test(done.transition), "the element did not get the catch-up: " + done.transition);
    await frame(page, "caught-up-dark");

    // AND THE ONE THE OVERRIDE PRODUCES: `cellT1` holds two attempts abandoned 1ms in
    // (`too_few_groups`). A 644ms gold sweep over a 1ms event would make a non-wait look like
    // a wait, so the catch-up is capped at the wait it is drawing and falls to the floor.
    const fence2 = await startTurn(page, "t_blink");
    const t1 = await page.evaluate(() => Date.now());
    await emitRow(page, fence2, { turnId: "t_blink", id: "mach_blink", state: "running", summary: SENTENCE, startedAt: t1, minMs: FLOOR, field: FIELD });
    await emitRow(page, fence2, { turnId: "t_blink", id: "mach_blink", state: "failed", summary: "Kept going without making room", startedAt: t1, minMs: FLOOR, field: FIELD });
    const blink = await readBar(page);
    seen.push("  1 ms      " + pct(blink.position).padStart(7) + "  catch-up " + Math.round(blink.landMs) + "ms  (the abandoned attempt)");
    assertEqual(blink.position, 1, "an abandoned attempt is still an ending: the pause is over");
    assertEqual(blink.landMs, blink.landMinMs, "a 1ms non-wait must not get a 644ms sweep");

    await page.close();
    return seen.join("\n          ");
  });

  // =====================================================================================
  // 5. A DEAD TURN DOES NOT LEAVE A BAR ALIVE
  //
  // `echo-opus-cb1` established the truth for the SENTENCE: past QUIET_AFTER_MS with no
  // heartbeat the band stops describing what it last saw and names the silence, because at
  // that point the app genuinely does not know whether the compaction is still running. The
  // bar obeys that same one rather than a second one of its own.
  // =====================================================================================

  await run.check("a child that dies mid-compaction takes the bar with the description", async () => {
    const page = await openApp(browser, { theme: "dark" });
    const fence = await startTurn(page, "t_dead");
    const seen = [];
    const t0 = await page.evaluate(() => Date.now());
    await emitRow(page, fence, { turnId: "t_dead", id: "mach_dead", state: "running", summary: SENTENCE, startedAt: t0, minMs: FLOOR, field: FIELD });

    await advance(page, 20000);
    await tick(page);
    let b = await readBar(page);
    seen.push("   20s  " + pct(b.position).padStart(7) + "  " + b.detail + "   [" + b.tone + "]");
    assert(b.present, "20s: no heartbeat is due yet, so the bar is still describing a live pause");

    // 40s: the heartbeat never came.
    await advance(page, 20000);
    await tick(page);
    b = await readBar(page);
    seen.push("   40s  " + pct(b.position).padStart(7) + "  " + b.detail + "   [" + b.tone + "]");
    assertEqual(b.tone, "quiet", "40s: two missed heartbeats is not 'still making room'");
    assert(!b.present, "40s: a bar sitting at " + pct(b.position) + " over a dead child is the spinner this band exists to remove");
    assertEqual(widthFraction(b.width), 0, "the bar must not keep its old position off-screen either: " + b.width);
    await frame(page, "dead-turn-dark");

    await advance(page, 120000);
    await tick(page);
    b = await readBar(page);
    seen.push("  2m40s  " + pct(b.position).padStart(7) + "  " + b.detail + "   [" + b.tone + "]");
    assert(!b.present, "the bar came back while nothing at all was arriving");

    await endTurn(page, fence, "t_dead", "failed");
    b = await readBar(page);
    assert(!b.band, "a failed turn leaves no band, and therefore no bar");
    seen.push("  failed  (the whole band is gone)");
    await page.close();
    return seen.join("\n          ");
  });

  // =====================================================================================
  // 6 and 7. NO NUMBER, AND NOTHING UNPACED GETS A BAR
  // =====================================================================================

  await run.check("the bar publishes no number, no value and no progressbar role", async () => {
    const page = await openApp(browser, { theme: "dark" });
    const fence = await startTurn(page, "t_mute");
    const t0 = await page.evaluate(() => Date.now());
    await emitRow(page, fence, { turnId: "t_mute", id: "mach_mute", state: "running", summary: SENTENCE, startedAt: t0, minMs: FLOOR, field: FIELD });
    await advance(page, 20000);
    await tick(page);
    const b = await readBar(page);
    assert(b.present, "the bar has to be on screen to be checked for what it says");
    assertEqual(b.text, "", "the bar renders text: " + JSON.stringify(b.text));
    assertEqual(b.role, null, 'the bar carries role="' + b.role + '" — a progressbar owes an aria-valuenow, and every value it could carry would be a proportion of a span that is not this wait\'s');
    for (const forbidden of ["aria-valuenow", "aria-valuemin", "aria-valuemax", "aria-valuetext", "aria-label", "title"]) {
      assert(b.attrs.indexOf(forbidden + "=") < 0, "the bar carries " + forbidden + ": " + b.attrs);
    }
    assert(b.attrs.indexOf("aria-hidden=true") >= 0, "the bar is not aria-hidden: " + b.attrs);
    // And the sentence beside it is still the crate's, with no digit in it.
    assertEqual(b.detail.split(" · ")[0], SENTENCE, "the sentence changed: " + b.detail);
    assert(!/\d+\s*%/.test(b.detail), "a percentage reached the band: " + b.detail);
    await page.close();
    return "attrs: " + b.attrs + "\n          text: " + JSON.stringify(b.text) + "   detail: " + JSON.stringify(b.detail);
  });

  await run.check("a row with no measured floor gets no bar, and a new sentence takes the bar away", async () => {
    const page = await openApp(browser, { theme: "dark" });
    const fence = await startTurn(page, "t_plain");
    const seen = [];
    const t0 = await page.evaluate(() => Date.now());

    // An ordinary activity row: the crate emits no `measuredMinMs` for anything but a
    // compaction, and nothing in main.js knows the difference by name.
    await emitRow(page, fence, { turnId: "t_plain", id: "mach_read", state: "running", summary: "Read a file", startedAt: t0, minMs: null, field: FIELD });
    await tick(page);
    let b = await readBar(page);
    seen.push("  Read a file          " + (b.present ? "BAR" : "no bar"));
    assert(!b.present, "an unpaced row got a bar, which means the bar was paced on something invented");

    // Then a real one, and then a signal that replaces the sentence.
    await emitRow(page, fence, { turnId: "t_plain", id: "mach_c", state: "running", summary: SENTENCE, startedAt: t0, minMs: FLOOR, field: FIELD });
    await advance(page, 10000);
    await tick(page);
    b = await readBar(page);
    seen.push("  " + SENTENCE + "  " + (b.present ? "BAR at " + pct(b.position) : "no bar"));
    assert(b.present, "the compaction row did not get a bar");

    await page.evaluate((o) => {
      window.__emit("rich://message-started", Object.assign({}, o.fence, { turnId: o.turnId, messageId: "m1", role: "assistant", visibility: "ceo", at: Date.now() }));
    }, { fence, turnId: "t_plain" });
    b = await readBar(page);
    seen.push("  " + b.detail.split(" · ")[0] + "        " + (b.present ? "BAR" : "no bar"));
    assert(!b.present, "Rich started writing the reply and the compaction's bar stayed on screen");
    await page.close();
    return seen.join("\n          ");
  });

  // =====================================================================================
  // 8. REDUCED MOTION
  // =====================================================================================

  await run.check("under reduced motion the bar still advances and animates nothing", async () => {
    const page = await openApp(browser, { theme: "dark", reducedMotion: "reduce" });
    const fence = await startTurn(page, "t_rm");
    const t0 = await page.evaluate(() => Date.now());
    await emitRow(page, fence, { turnId: "t_rm", id: "mach_rm", state: "running", summary: SENTENCE, startedAt: t0, minMs: FLOOR, field: FIELD });
    await advance(page, 10000);
    await tick(page);
    const a = await readBar(page);
    await advance(page, 10000);
    await tick(page);
    const c = await readBar(page);
    assert(c.position > a.position, "the bar stopped advancing under reduced motion — a loading bar that does not move is a broken loading bar");
    assertEqual(c.transition, "none", "reduced motion got a transition: " + c.transition);
    await page.close();
    return "10s " + pct(a.position) + " -> 20s " + pct(c.position) + ", transition " + JSON.stringify(c.transition);
  });

  // =====================================================================================
  // 9. CONTRAST — three boundaries, both themes, off the rendered DOM
  // =====================================================================================

  for (const theme of ["dark", "light"]) {
    await run.check("WCAG AA on the paced bar, computed — " + theme, async () => {
      const page = await openApp(browser, { theme });
      const painted = await page.evaluate(() => document.documentElement.getAttribute("data-theme"));
      assertEqual(painted, theme, "asked for " + theme + " and the document painted " + painted);
      const fence = await startTurn(page, "t_contrast_" + theme);
      const t0 = await page.evaluate(() => Date.now());
      await emitRow(page, fence, { turnId: "t_contrast_" + theme, id: "mach_c", state: "running", summary: SENTENCE, startedAt: t0, minMs: FLOOR, field: FIELD });
      await advance(page, 20000);
      await tick(page);
      const b = await readBar(page);
      assert(b.present, "the bar under measurement must be on screen");
      await frame(page, "bar-" + theme);

      await page.evaluate(C.pageScript());
      const measured = await page.evaluate(() => {
        const M = window.__contrastMath;
        /// The paint stack BEHIND a node, composited — the same walk the shipping checker
        /// does, started at the node itself or at its parent.
        function bgFrom(node) {
          let el = node;
          let acc = null;
          while (el) {
            const c = M.parseCssColor(getComputedStyle(el).backgroundColor);
            if (c && c.a > 0) {
              acc = acc ? M.compositeOver(acc, c) : c;
              if (c.a >= 0.999) return acc;
            }
            el = el.parentElement;
          }
          return null;
        }
        const track = document.querySelector(".wait-pace");
        const fill = document.querySelector(".wait-pace-fill");
        if (!track || !fill) return null;
        const paper = bgFrom(track.parentElement);
        const ghost = bgFrom(track);
        const border = M.parseCssColor(getComputedStyle(track).borderTopColor);
        const gold = M.parseCssColor(getComputedStyle(fill).backgroundColor);
        if (!paper || !ghost || !border || !gold) return null;
        return {
          paper: M.hex(paper),
          ghost: M.hex(ghost),
          border: M.hex(M.compositeOver(border, paper)),
          gold: M.hex(M.compositeOver(gold, ghost)),
          borderWidth: getComputedStyle(track).borderTopWidth,
          rows: [
            // What each boundary CARRIES is what decides that it owes 3:1 — the extent of
            // the bar, and how far along it the fill has got. Both are non-text indicators
            // (WCAG 2.2 1.4.11).
            { what: "the bar's full extent", pair: ".wait-pace border vs the paper", ratio: M.round2(M.contrastRatio(M.compositeOver(border, paper), paper)), floor: 3 },
            { what: "how far along it is", pair: ".wait-pace-fill vs the track", ratio: M.round2(M.contrastRatio(M.compositeOver(gold, ghost), ghost)), floor: 3 },
            { what: "the moving thing itself", pair: ".wait-pace-fill vs the paper", ratio: M.round2(M.contrastRatio(M.compositeOver(gold, paper), paper)), floor: 3 },
          ],
          // Reported, never asserted on: the unfilled interior is the ground the fill is read
          // AGAINST, not a thing that has to be seen in its own right. It is deliberately
          // faint and is declared here rather than left for a reviewer to discover.
          ghostVsPaper: M.round2(M.contrastRatio(ghost, paper)),
        };
      });
      assert(measured, "the bar's colors could not be resolved — a failure to prove, never a pass");
      assert(parseFloat(measured.borderWidth) >= 1, "the border that carries the bar's extent is " + measured.borderWidth);

      const out = [];
      for (const r of measured.rows) {
        assert(r.ratio >= r.floor, theme + " " + r.pair + " = " + r.ratio + ":1, floor " + r.floor + ":1");
        out.push(theme + " " + r.pair.padEnd(30) + String(r.ratio).padStart(6) + ":1  (floor " + r.floor + ")   " + r.what);
      }
      out.push(
        theme + " paper " + measured.paper + "  track interior " + measured.ghost + " (" + measured.ghostVsPaper +
          ":1, declared: the unfilled ground, not an indicator)  border " + measured.border + "  fill " + measured.gold
      );
      await page.close();
      return out.join("\n          ");
    });
  }

  await browser.close();
  process.exitCode = run.report() ? 1 : 0;
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

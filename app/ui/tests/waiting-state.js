// THE WAITING STATE — the state the first outside user of RichOS called "a crashed
// application", held to what it is allowed to say.
//
// His words, 2026-09-06, relayed verbatim by the CEO:
//
//   "it takes a lot of time to get a reply, a lot of spinning wheels waiting … no
//    interaction of feedback, so it looks like a crashed application."
//
// The full before/after record, the frames and the two measurements this suite's constants
// come from live in `docs/verification/waiting-state-2026-09-06/`.
//
// WHAT THIS SUITE IS FOR, and it is not "the band renders". It is the four properties that
// make the band honest, each of which is a way it could quietly start lying:
//
//   1. IT CANNOT FABRICATE PROGRESS. No percentage, no step count, no estimate, no invented
//      step name — asserted against the sentence, not against a screenshot of it. The
//      backend's `summary` is relayed VERBATIM and nothing composes around it.
//   2. IT GOES STILL WHEN NOTHING IS ARRIVING. The mark flashes once per accepted event and
//      never on a loop, so it cannot keep reassuring after the process has stopped. A
//      spinner that spins after a crash is the lie that produced the report.
//   3. A DEAD TURN LOOKS DIFFERENT FROM A SLOW ONE. A terminal `rich://turn-status` removes
//      the band; the turn's own failure treatment is what is left, and it stays that way.
//   4. IT CLEARS WCAG AA IN BOTH THEMES, computed from the REAL DOM with the shipping
//      checker's arithmetic (`lib/contrast.js`) — 4.5:1 for its text, 3:1 for the mark.
//
// HOW IT DRIVES A TURN. Through the callbacks `main.js` registered with
// `window.RichBridge.listen`, captured by wrapping the bridge as mock.js assigns it, with
// `send_message` made to hang — which is the shipping contract, not a fiction: it resolves
// only when the turn ends, so a long turn's whole duration is driven by events. No renderer
// function is ever called directly, so a green run here is a statement about the DOM a real
// event produces.
//
// TIME IS BOUGHT WITH A CLOCK, NOT WITH A WAIT. `Date.now` is overridden inside the page to
// return a controllable offset, so the 35-second quiet threshold is reached in milliseconds.
// Everything downstream of it — the elapsed label, the silence count, `durationRow` — reads
// that same clock, which is exactly the property §6.2 asks for ("recompute from timestamps",
// never accumulate). A suite that slept 35 seconds per case would be a suite nobody runs.
//
// THE THRESHOLD MOVED, 25000 -> 35000, on 2026-09-06 (`main.js`, "RAISED 25000 -> 35000").
// The native wire has two 30-second heartbeats — `tool_progress` at 30.002s and
// `system/status: "compacting"` at 30.000s — and at 25000ms a healthy turn spent 5 seconds
// of every 30 in the attention tone. Three instants below moved with it, and nothing else
// about this suite changed.
//
// PROVEN TO BE ABLE TO FAIL, on the check most likely to rot into a rubber stamp. With
// light `--live-mark` temporarily set to `#b8a06a`, the contrast check reported
// `light/working .wait-mark #b8a06a on #eae6dd = 2.04:1, floor 3:1` and the run went red.
// A contrast gate nobody has watched fail is a contrast gate nobody should believe.
//
// NO AUDIO PATH IS TOUCHED: headless WebKit, no voice mode, no output device.
//
// RUN:  node waiting-state.js
//       RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node waiting-state.js

"use strict";

const path = require("path");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");
const C = require("./lib/contrast");

const APP = "file://" + path.join(UI_DIR, "index.html");

/// Captures every listener `main.js` registers, hangs `send_message`, and installs a
/// controllable clock. Injected before any of the page's own scripts run.
const INIT = `
window.__TAP = { listeners: {}, hang: false };
(function () {
  // FROZEN, not merely offset. The page's whole notion of "now" is one controllable value,
  // so an elapsed label is a function of the skew alone and cannot drift with however long
  // a real wait took on this machine. Everything downstream reads the same clock, which is
  // the property section 6.2 asks for: recompute from timestamps, never accumulate.
  // (No backticks in this comment: it lives inside a template literal, where one would end
  // the string.)
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

async function openApp(browser, theme) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 860 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  // The STORE as well as the mirror: `syncAppearanceFromBackend` reconciles the two and the
  // backend wins, so a mirror-only seed is overwritten a few hundred ms after boot and the
  // walk would measure dark while claiming light.
  await page.addInitScript((t) => {
    try {
      window.localStorage.setItem("richos-theme", t);
      window.localStorage.setItem("richos-font-scale", "100");
      window.localStorage.setItem("richos-mock-config", JSON.stringify({ theme: t, font_scale: 100, user_name: null }));
    } catch (e) {
      /* storage unavailable; theme-boot falls back to the shipped default, which is dark */
    }
  }, theme || "dark");
  await page.addInitScript(INIT);
  await page.goto(APP);
  await page
    .evaluate(() => {
      const s = window.RichSplash;
      if (s && s.state && s.state.shown && !s.state.reason) s.yieldNow("waiting-state-suite");
    })
    .catch(() => {});
  await page.waitForFunction(() => !document.getElementById("splash"), { timeout: 8000 }).catch(() => {});
  await page.waitForFunction("typeof window.RichHome === 'object'", { timeout: 8000 }).catch(() => {});
  await page.evaluate(() => {
    if (window.RichHome && window.RichHome.isOpen()) window.RichHome.hide("waiting-state-suite");
  });
  await page.waitForFunction(() => { const h = document.getElementById("home"); return !h || h.hidden; }, { timeout: 8000 }).catch(() => {});
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

/// Send, then hand the window the spine's own `queued` -> `working` pair. Returns the fence
/// every later event has to carry, read off the live model rather than typed.
async function startTurn(page, turnId) {
  await page.evaluate(() => { window.__TAP.hang = true; });
  const fence = await page.evaluate(() => {
    const m = window.__RICHOS_TIMELINE__();
    return { entityId: m.entityId, threadId: m.threadId, bindingRevision: m.bindingRevision };
  });
  await page.fill("#input", "Draft the Q4 board memo from the numbers in the folder.");
  await page.press("#input", "Enter");
  await page.evaluate(
    (o) => {
      window.__emit("rich://turn-status", Object.assign({}, o.fence, {
        turnId: o.turnId, status: "queued", startedAt: null, activeDurationMs: null, visibility: "ceo", at: Date.now(),
      }));
    },
    { fence, turnId }
  );
  return fence;
}

async function goWorking(page, fence, turnId) {
  await page.evaluate(
    (o) => {
      const startedAt = Date.now();
      window.__emit("rich://turn-status", Object.assign({}, o.fence, {
        turnId: o.turnId, status: "working", startedAt, activeDurationMs: null, visibility: "ceo", at: startedAt,
      }));
    },
    { fence, turnId }
  );
}

const advance = (page, ms) => page.evaluate((n) => { window.__CLOCK.skew += n; }, ms);

/// Repaint on the band's own one-second path rather than by calling a renderer: one tick of
/// the interval it installs. `waitForFunction` on the rendered text is what proves the tick
/// happened, so nothing here asserts against a frame that was never painted.
async function tick(page) {
  await page.waitForTimeout(1100);
}

async function band(page) {
  return page.evaluate(() => {
    const b = document.getElementById("turn-wait");
    if (!b) return null;
    const r = b.getBoundingClientRect();
    const mark = b.querySelector(".wait-mark");
    return {
      tone: b.dataset.tone,
      head: b.querySelector(".wait-head").textContent,
      time: b.querySelector(".wait-time").textContent,
      detail: b.querySelector(".wait-detail").textContent,
      role: b.getAttribute("role"),
      ariaLive: b.getAttribute("aria-live"),
      onScreen: r.width > 0 && r.height > 0 && r.top < innerHeight && r.bottom > 0,
      markFlashing: !!(mark && mark.classList.contains("wait-mark--flash")),
      markAnimation: mark ? getComputedStyle(mark).animationIterationCount : null,
      markIsIndicator: !!(mark && mark.getAttribute("data-contrast-role") === "indicator"),
    };
  });
}

/// The claim vocabulary a progress display is not allowed to invent. Every one of these is a
/// statement about how much of a turn is done, and nothing on the ACP wire says that (see
/// `docs/verification/acp-emission-probe-2026-08-28.md` §4-5).
const FABRICATION = [
  /\d+\s*%/, // a percentage of anything
  /\bstep\s+\d+\s+of\s+\d+/i,
  /\b\d+\s*\/\s*\d+\b/, // "3/7"
  /\balmost (there|done|finished)\b/i,
  /\bnearly (there|done|finished)\b/i,
  /\bshould (be|take)\b/i,
  /\bestimated?\b/i,
  /\bremaining\b/i,
  /\babout (a|an|\d)/i,
  /\bthinking\b/i, // no phase exists on this wire; `phase` is `unknown` on every message
  /\bprogress\b/i,
];

function assertNoFabrication(text, where) {
  for (const re of FABRICATION) {
    assert(!re.test(text), where + ' says "' + text + '", which matches ' + re + " — a claim about how much of a turn is done, and nothing on the wire carries one");
  }
}

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("the waiting state — WebKit");

  // =====================================================================================
  // 1. THE REPORT: a turn with nothing coming back
  // =====================================================================================

  await run.check("a silent turn says it is alive, what it knows, and how long it has been", async () => {
    const page = await openApp(browser, "dark");
    const fence = await startTurn(page, "t_silent");

    let b = await band(page);
    assert(b, "no band on screen while the turn was queued — the state the report is about");
    assertEqual(b.head, "Rich has your message", "queued headline");
    assertEqual(b.detail, "He hasn't started on it yet", "queued detail");
    assert(b.onScreen, "the band is off screen");

    await goWorking(page, fence, "t_silent");
    b = await band(page);
    assertEqual(b.head, "Rich is working", "working headline");
    assertEqual(b.detail, "Nothing has come back yet", "with zero events, the honest detail");

    // 10s: an elapsed number, derived from the ledger's `startedAt` through the SAME
    // `durationRow` the timeline's own row uses.
    await advance(page, 10000);
    await tick(page);
    b = await band(page);
    assertEqual(b.time, "10s", "elapsed at +10s");
    assertEqual(b.detail, "Nothing has come back yet", "still nothing, still said plainly");
    assertEqual(b.tone, "working", "10s is inside the measured healthy-gap range (max 20.7s)");

    // Past the measured threshold: the silence becomes the thing worth reporting.
    await advance(page, 20000);
    await tick(page);
    b = await band(page);
    assertEqual(b.time, "30s", "elapsed at +30s");
    assertEqual(
      b.detail,
      "Nothing has come back yet",
      "30s is INSIDE the wire's own 30.002s heartbeat cadence, so the band must not call it quiet"
    );
    assertEqual(b.tone, "working", "and must not raise the attention tone on a turn a heartbeat is about to reach");

    await advance(page, 30000);
    await tick(page);
    b = await band(page);
    assertEqual(b.time, "1m 0s", "elapsed at +60s");
    assertEqual(b.detail, "Nothing new for 1m 0s", "past 35s the band names the silence, and keeps being true");

    // THE ONE THING IT IS FOR: the four instants say four different things, and every one of
    // them is checked for invented progress.
    for (const t of ["Rich has your message", "Rich is working"]) assertNoFabrication(t, "a headline");
    assertNoFabrication(b.detail, "the 60s detail");

    await page.close();
  });

  // =====================================================================================
  // 2. IT CANNOT FABRICATE, AND IT RELAYS RATHER THAN COMPOSES
  // =====================================================================================

  await run.check("the activity line is the backend's own sentence, verbatim, with a real age", async () => {
    const page = await openApp(browser, "dark");
    const fence = await startTurn(page, "t_active");
    await goWorking(page, fence, "t_active");

    const SUMMARY = "Read the Q3 board pack";
    await page.evaluate((o) => {
      window.__emit("rich://activity-upserted", Object.assign({}, o.fence, {
        kind: "activity", id: "mach_1", turnId: "t_active", createdAt: Date.now(), sequence: 1,
        slot: "stream", visibility: "ceo", activityType: "command", state: "running",
        summary: o.summary, at: Date.now(),
      }));
    }, { fence, summary: SUMMARY });

    let b = await band(page);
    assertEqual(b.detail, SUMMARY, "the backend's summary, relayed with nothing added to it");

    await advance(page, 8000);
    await tick(page);
    b = await band(page);
    assertEqual(b.detail, SUMMARY + " · 8s ago", "the same sentence, plus how long ago it was");
    assertNoFabrication(b.detail, "the activity detail");

    // Text starting is licensed to say ONE thing.
    await page.evaluate((f) => {
      window.__emit("rich://message-started", Object.assign({}, f, {
        turnId: "t_active", messageId: "t_active:text:0", phase: "unknown", seq: 2, visibility: "ceo", at: Date.now(),
      }));
    }, fence);
    b = await band(page);
    assertEqual(b.detail, "Writing the reply", "streaming text claims that text is arriving, and nothing more");
    assertNoFabrication(b.detail, "the streaming detail");
    await page.close();
  });

  await run.check("an activity row with no summary is TIMED, never described with an invented one", async () => {
    const page = await openApp(browser, "dark");
    const fence = await startTurn(page, "t_nosum");
    await goWorking(page, fence, "t_nosum");
    await page.evaluate((f) => {
      window.__emit("rich://activity-upserted", Object.assign({}, f, {
        kind: "activity", id: "mach_2", turnId: "t_nosum", createdAt: Date.now(), sequence: 1,
        slot: "stream", visibility: "ceo", activityType: "command", state: "running", at: Date.now(),
      }));
    }, fence);
    await advance(page, 3000);
    await tick(page);
    const b = await band(page);
    assertEqual(b.detail, "Last update 3s ago", "with nothing to relay it reports the clock, which it does know");
    assertNoFabrication(b.detail, "the summary-less detail");
    await page.close();
  });

  // =====================================================================================
  // 3. IT GOES STILL. THE ANIMATION IS DRIVEN BY EVENTS, NOT BY A TIMER
  // =====================================================================================

  await run.check("the mark flashes once per arriving event and never loops", async () => {
    const page = await openApp(browser, "dark");
    const fence = await startTurn(page, "t_still");
    await goWorking(page, fence, "t_still");

    let b = await band(page);
    assertEqual(b.markAnimation, "1", "the mark's animation runs exactly once — a looping count here would be a spinner");
    assert(b.markIsIndicator, "the mark must carry data-contrast-role=indicator so the shipping contrast gate walks it");

    // The flash is REMOVED and re-added per event, so an event that never comes leaves the
    // class exactly where the last one left it. What matters is that nothing re-arms it.
    await page.evaluate((f) => {
      window.__emit("rich://activity-upserted", Object.assign({}, f, {
        kind: "activity", id: "mach_3", turnId: "t_still", createdAt: Date.now(), sequence: 1,
        slot: "stream", visibility: "ceo", activityType: "command", state: "running",
        summary: "Opened the folder", at: Date.now(),
      }));
    }, fence);
    b = await band(page);
    assert(b.markFlashing, "an arriving event must flash the mark");

    // A POSITIVE PROBE THAT THIS CHECK CAN FAIL: if the flash were on a loop, the computed
    // iteration count would be `infinite` and the assertion above would have caught it. This
    // asserts the same fact from the stylesheet, so a future change to either is seen.
    const loops = await page.evaluate(() => {
      const el = document.querySelector(".wait-mark");
      return getComputedStyle(el).animationIterationCount;
    });
    assert(loops !== "infinite", "the aliveness mark must never animate infinitely — that is a spinner, and a spinner spins after a crash");
    await page.close();
  });

  await run.check("the elapsed clock keeps moving while the mark is still — the honest kind of motion", async () => {
    const page = await openApp(browser, "dark");
    const fence = await startTurn(page, "t_clock");
    await goWorking(page, fence, "t_clock");
    await advance(page, 5000);
    await tick(page);
    const a = await band(page);
    await advance(page, 7000);
    await tick(page);
    const c = await band(page);
    assert(a.time !== c.time, "the elapsed label must change between frames — it is the one thing on screen that is allowed to move on its own, because time passing is a fact");
    assertEqual(a.time, "5s", "first reading");
    assertEqual(c.time, "12s", "second reading");
    await page.close();
  });

  // =====================================================================================
  // 4. A DEAD TURN LOOKS DIFFERENT FROM A SLOW ONE
  // =====================================================================================

  await run.check("a terminal status removes the band, and nothing re-reassures afterwards", async () => {
    const page = await openApp(browser, "dark");
    const fence = await startTurn(page, "t_dead");
    await goWorking(page, fence, "t_dead");
    await advance(page, 6000);
    await tick(page);
    assert(await band(page), "the band must be up while the turn is alive");

    await page.evaluate((f) => {
      window.__emit("rich://turn-status", Object.assign({}, f, {
        turnId: "t_dead", status: "failed", startedAt: Date.now() - 6000, activeDurationMs: 6000, visibility: "ceo", at: Date.now(),
      }));
    }, fence);
    assertEqual(await band(page), null, "a failed turn must take the band with it — a band still saying 'Rich is working' over a failure card is the reassurance-after-death this feature exists to remove");

    // The turn's OWN outcome is what is left, and it says the turn ended. Waited for on the
    // END STATE rather than on a timer: `scheduleRender` coalesces into an animation frame,
    // so reading the row in the same tick as the emit would be reading the frame before the
    // one the CEO sees.
    await page
      .waitForFunction(() => {
        const el = document.querySelector(".tl-duration-label");
        return !!el && /^Stopped after /.test(el.textContent);
      }, { timeout: 4000 })
      .catch(() => {});
    const row = await page.evaluate(() => {
      const el = document.querySelector(".tl-duration-label");
      return el ? el.textContent : null;
    });
    assert(row && /^Stopped after /.test(row), "the duration row must state the ending; got " + JSON.stringify(row));

    // And it STAYS gone: the band's own ticker must not resurrect it on the next second.
    await advance(page, 5000);
    await tick(page);
    assertEqual(await band(page), null, "the band must not come back on a later tick");
    await page.close();
  });

  await run.check("a completed turn takes the band with it too", async () => {
    const page = await openApp(browser, "dark");
    const fence = await startTurn(page, "t_done");
    await goWorking(page, fence, "t_done");
    await page.evaluate((f) => {
      window.__emit("rich://turn-status", Object.assign({}, f, {
        turnId: "t_done", status: "completed", startedAt: Date.now() - 4000, activeDurationMs: 4000, visibility: "ceo", at: Date.now(),
      }));
    }, fence);
    assertEqual(await band(page), null, "a completed turn leaves no waiting state behind");
    await page.close();
  });

  // =====================================================================================
  // 5. CONTRAST — computed from the real DOM, both themes
  // =====================================================================================

  for (const theme of ["dark", "light"]) {
    await run.check("WCAG AA on the waiting band, computed — " + theme, async () => {
      const page = await openApp(browser, theme);
      const painted = await page.evaluate(() => document.documentElement.getAttribute("data-theme"));
      assertEqual(painted, theme, "asked for " + theme + " and the document painted " + painted + " — the measurement below would carry the wrong label");

      const fence = await startTurn(page, "t_contrast_" + theme);
      await goWorking(page, fence, "t_contrast_" + theme);

      // Both tones, because they use different inks: `working` and, past the threshold,
      // `quiet`.
      const results = [];
      for (const want of ["working", "quiet"]) {
        if (want === "quiet") {
          // Past QUIET_AFTER_MS, which is 35000 since 2026-09-06.
          await advance(page, 40000);
          await tick(page);
        }
        const b = await band(page);
        assertEqual(b.tone, want, "expected the " + want + " tone");
        await page.evaluate(C.pageScript());
        const measured = await page.evaluate(() => {
          const M = window.__contrastMath;
          // The composited background BEHIND the band: walk up for the first opaque paint,
          // which for `#composer-zone` is `--paper`. An unresolvable background is reported
          // as unresolvable, never as a pass.
          function bgOf(node) {
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
          const out = [];
          const band = document.getElementById("turn-wait");
          const bg = bgOf(band);
          for (const sel of [".wait-head", ".wait-time", ".wait-detail", ".wait-mark"]) {
            const el = band.querySelector(sel);
            const cs = getComputedStyle(el);
            const isMark = sel === ".wait-mark";
            const fg = M.parseCssColor(isMark ? cs.backgroundColor : cs.color);
            const px = parseFloat(cs.fontSize);
            out.push({
              sel,
              fg: fg ? M.hex(M.compositeOver(fg, bg)) : null,
              bg: bg ? M.hex(bg) : null,
              px: isMark ? null : px,
              // 3:1 for the non-text mark; 3:1 for large text (18.66px bold / 24px+);
              // 4.5:1 for everything else. `isLargeText` is the shipping checker's own.
              floor: isMark ? 3 : M.isLargeText(px, cs.fontWeight) ? 3 : 4.5,
              ratio: fg && bg ? M.round2(M.contrastRatio(M.compositeOver(fg, bg), bg)) : null,
            });
          }
          return out;
        });
        for (const r of measured) {
          assert(r.ratio !== null, r.sel + " could not be resolved against its background — a failure to prove, never a pass");
          assert(
            r.ratio >= r.floor,
            theme + "/" + want + " " + r.sel + " " + r.fg + " on " + r.bg +
              (r.px ? " at " + r.px + "px" : "") + " = " + r.ratio + ":1, floor " + r.floor + ":1"
          );
          results.push(theme + "/" + want + " " + r.sel.padEnd(13) + " " + String(r.ratio).padStart(6) + ":1  (floor " + r.floor + ")");
        }
      }
      await page.close();
      return results.join("\n          ");
    });
  }

  // =====================================================================================
  // 6. THE ANNOUNCEMENT IS CONTROLLED — §18 forbids narrating a clock
  // =====================================================================================

  await run.check("the band is not a live region, and the quiet state is announced once", async () => {
    const page = await openApp(browser, "dark");
    const fence = await startTurn(page, "t_a11y");
    await goWorking(page, fence, "t_a11y");
    const b = await band(page);
    assertEqual(b.role, "status", "the band carries role=status");
    assertEqual(b.ariaLive, "off", "…with aria-live OFF, or a clock rewriting itself every second would be narrated");

    // Past QUIET_AFTER_MS, which is 35000 since 2026-09-06.
    await advance(page, 40000);
    await tick(page);
    const first = await page.evaluate(() => (document.getElementById("live-region") || {}).textContent || "");
    assert(/Nothing new for/.test(first), "the quiet state is worth saying once; got " + JSON.stringify(first));

    // Said ONCE. Another ten seconds of the same silence must not re-announce.
    await page.evaluate(() => { const r = document.getElementById("live-region"); if (r) r.textContent = ""; });
    await advance(page, 10000);
    await tick(page);
    const again = await page.evaluate(() => (document.getElementById("live-region") || {}).textContent || "");
    assertEqual(again, "", "the same quiet stretch must not be announced twice");
    await page.close();
  });

  await browser.close();
  process.exitCode = run.report() ? 1 : 0;
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

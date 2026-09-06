// **CODE THAT IS ONLY CORRECT WHEN THE BRIDGE IS INSTANT** — the class of defect, with a lever
// that makes it visible on demand.
//
// Two shipped defects were measured on 2026-09-06 by `tom-opus-bw1` while replacing this
// directory's blind waits with real signals, and raised as `esc-20260906T085912Z-4005a6b5`.
// Both were the same shape: an interaction whose correctness depended on a bridge call
// returning before something else happened, which is true in an in-page mock and false on a
// Tauri IPC call. Neither is a test artifact and neither could be seen at zero latency.
//
//   1. A THREAD PRESSED DURING BOOT COULD OPEN A DIFFERENT THREAD. `main.js`'s `init()` painted
//      real, handler-wired `.nav-thread` buttons and then made five more bridge calls before
//      opening the thread the LAST session ended on — over the top of the one the CEO had just
//      pressed, with no error. At 120 ms, pressing "hiring" landed him on "general": Harbor
//      Analytics, "Running", zero turns.
//
//   2. THE UPDATE CONTROL COULD NOT BE REACHED IN ONE KEYSTROKE. `updates.js`'s `openTheRow()`
//      deferred the cue's focus with `setTimeout(..., 0)`, which fired while `#update-install`
//      was still `disabled` by the menu's own in-flight `update_state` read. Focus landed at
//      0 ms of bridge latency and never at 10 ms or more, so §26's "one keystroke from the act"
//      held in a zero-latency fixture and nowhere else.
//
// THE LEVER IS THE POINT OF THIS FILE. `INSTRUMENTED_BRIDGE` puts a fixed latency on every call
// the page makes, wrapped at the ASSIGNMENT of `window.RichBridge` so every caller in the page is
// behind it. A check that is green at 0 ms and green at 400 ms is a check that waited for a
// signal; one that is green at 0 and red at 120 was measuring the machine. Each check below runs
// at THREE latencies — 0, 120 (an ordinary machine, and the number both defects were measured at)
// and 400 (slower still) — and states which, so a green line here is a statement about all three.
//
// WHAT THESE CHECKS ARE NOT. They are not a shorter window. Both fixes removed a DEPENDENCE on
// timing — a restore that yields to a choice, a ticket that abandons a stale chain, a focus bound
// to the control becoming usable — so the assertions below are about outcomes at any latency
// rather than about a race being won more often. If a future change reintroduces a window, these
// go red at 120 and 400 while staying green at 0, which is the signature to look for.
//
// PROVEN TO CATCH THE DEFECTS IT NAMES, not merely observed green. `app/ui/main.js` and
// `app/ui/updates.js` were restored to their pre-fix state at `041eee8`, this file left exactly
// as it stands, and the run reported 6 of its 9 checks red — verbatim, trimmed to the first line
// of each:
//
//     FAIL  a thread pressed during boot is the thread that opens (120ms bridge)
//             pressed "hiring" at +360ms and the conversation on screen is "Harbor Analytics /
//             Running" — the rail marks "general", the model is bound to "general", 0 turn(s)
//     FAIL  a thread pressed during boot is the thread that opens (400ms bridge)
//             pressed "hiring" at +1200ms ... the model is bound to "general", 0 turn(s) painted
//     FAIL  the shell remembers the thread he pressed, not the one the boot would have imposed
//             at 400ms ... the shell would restore "general"
//     FAIL  the update cue puts the hand on the control (0ms bridge)
//     FAIL  the update cue puts the hand on the control (120ms bridge)
//     FAIL  the update cue puts the hand on the control (400ms bridge)
//             the menu's own re-read must not disarm the control it opens onto
//     FAIL  the row's control is never disarmed by the menu's own re-read (400ms bridge)
//             the control was not pressable on 25 of 55 sampled frames
//
// THE THREE THAT STAYED GREEN ARE THE CONTROL CASES, and they are why the list above is evidence
// rather than a suite that fails at everything: the 0 ms thread press was correct before the fix
// (the defect needs latency), and "with no press at all, the boot still restores where the last
// session ended" was correct before it and must stay correct after — a fix that read "never
// restore" would have broken exactly that line.
//
// The cue check goes red at 0 ms as well, and that is not a stricter reading of the old defect —
// it is the same one seen without the fixture's help. The old `setTimeout(0)` fired after the
// microtask that resolved a 0 ms invoke, which is the entire reason the defect was invisible
// here; reading the focus in the SAME synchronous block as the press removes that accident.
//
// Run: node slow-bridge.js   (or `npm test` for every suite in this directory)

"use strict";

const path = require("path");
const { loadPlaywright, leaveHome, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");

/// The latencies every check is run at. 120 is where both defects were measured; 400 is the
/// "slower still" the fix has to survive as well, and it is not a fantasy — it is a laptop
/// swapping, or a spine mid-rotation.
const LATENCIES = [0, 120, 400];

/// A DELIBERATE SLOW RUNNER, WITH A LEDGER: `ms` of latency on every bridge call the page makes,
/// and a record of every call issued and returned.
///
/// Wrapped at the ASSIGNMENT of `window.RichBridge` rather than after load, so it is in front of
/// every caller including the ones `init()` makes before any test code runs. Passed to
/// `page.addInitScript` before `goto`.
///
/// THE LEDGER IS HOW THIS FILE KNOWS THE BOOT IS OVER, and it is here rather than in the product
/// because a test's end state must not need the product to publish one. See `bootDone`.
///
/// `tom-opus-bw1` wrote the latency half first — inline in `contrast.js`, then hoisted into
/// `lib/harness.js` on his branch as `SLOW_BRIDGE`. It is spelled out here rather than imported
/// because that branch is not landed; when it lands, the latency half should become
/// `require("./lib/harness").SLOW_BRIDGE` and the two must not be allowed to drift.
const INSTRUMENTED_BRIDGE = (ms) => {
  window.__bridgeIssued = [];
  window.__bridgeReturned = [];
  let real;
  Object.defineProperty(window, "RichBridge", {
    configurable: true,
    get: () => real,
    set: (v) => {
      real = v;
      const invoke = v.invoke.bind(v);
      v.invoke = async (name, args) => {
        window.__bridgeIssued.push(name);
        if (ms > 0) await new Promise((r) => setTimeout(r, ms));
        try {
          return await invoke(name, args);
        } finally {
          window.__bridgeReturned.push(name);
        }
      };
    },
  });
};

/// A NEGATIVE OBSERVATION WINDOW — not a wait for a signal, and named differently on purpose so
/// nobody later "fixes" it into one. Two of the assertions here are that over a stretch of time
/// NOTHING happens: no second thread opens, no control is disarmed. There is no end state to wait
/// for, because the claim is about the absence of one. The number IS the assertion's width.
async function observe(page, ms, why) {
  void why;
  await page.waitForTimeout(ms);
}

async function open(browser, lag) {
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.addInitScript(INSTRUMENTED_BRIDGE, lag);
  await page.goto(APP);
  await leaveHome(page);
  page.__errors = errors;
  return page;
}

/// `init()` HAS RUN TO ITS LAST LINE — not "the app looks ready", which is a different and much
/// earlier fact.
///
/// The end state is `raw_retention`, which `syncRetentionFromBackend()` issues from the very last
/// line of `init()`. Once it has RETURNED, every decision `init()` makes about which screen the
/// CEO is on has been made, and any override it was going to issue has been issued.
///
/// A COMPOSER HOLDING FOCUS IS NOT THIS FACT, and believing it was made the first version of this
/// suite fail against a correct product. `home.js:1037` focuses `#input` when the home screen is
/// hidden — "Focus follows the surface" — so `leaveHome()` satisfies that condition before
/// `init()` has reached its rail, let alone its landing branch. Measured 2026-09-06: at 120 ms
/// the check read `bound: null` on a boot that went on to land perfectly well.
async function bootDone(page) {
  await page.waitForFunction(() => (window.__bridgeReturned || []).indexOf("raw_retention") >= 0, {
    timeout: 60000,
  });
}

async function onScreen(page) {
  return page.evaluate(() => {
    const m = window.__RICHOS_TIMELINE__ ? window.__RICHOS_TIMELINE__() : null;
    return {
      active: (document.querySelector(".nav-thread-row.is-active .nav-thread") || { dataset: {} }).dataset.threadId,
      bound: m ? m.threadId : null,
      entity: ((document.getElementById("scope-entity") || {}).textContent || "").trim(),
      crumb: ((document.getElementById("scope-thread") || {}).textContent || "").trim(),
      turns: document.querySelectorAll("#messages .tl-turn").length,
    };
  });
}

/// Press a thread row `after` ms after it first exists, and report where the app ends up.
///
/// The offsets the callers use are not decoration. `init()` reaches the rail on its 7th bridge
/// call and its landing branch 5 calls later, so a press was overwritten when its own two-call
/// chain (`switch_thread`, `active_context`) could not land before that branch — between 3 and 5
/// call-times after the row appears. Sampling at 3, 3.5 and 4 call-times covers that window with
/// room for the jitter a real machine adds, rather than pinning one number measured on one Mac.
async function pressDuringBoot(browser, lag, after) {
  const page = await open(browser, lag);
  await page.waitForSelector('.nav-thread[data-thread-id="hiring"]', { state: "attached" });
  if (after > 0) await page.waitForTimeout(after);
  await page.evaluate(() => document.querySelector('.nav-thread[data-thread-id="hiring"]').click());
  await bootDone(page);
  await observe(
    page,
    6 * lag + 400,
    "the override this check is about was issued before `raw_retention` and needs about four " +
      "more call-times to paint, so the window is six of them plus a floor for a 0ms run"
  );
  const on = await onScreen(page);
  const remembered = await page.evaluate(() => window.RichBridge.invoke("active_thread"));
  const errors = page.__errors.slice();
  await page.close();
  return { on, remembered, errors };
}

/// Seed the panel with an update waiting, exactly as `updates.rs` reports one.
const AVAILABLE = {
  state: "available",
  currentVersion: "0.1.1",
  availableVersion: "0.1.2",
  busy: false,
  busyReason: null,
  notes: null,
  pubDate: null,
  downloadedBytes: 0,
  totalBytes: null,
  percent: null,
  endpoint: "",
  endpointIsPlaceholder: true,
  checkedAt: null,
  failure: null,
};

async function withUpdateWaiting(browser, lag) {
  const page = await open(browser, lag);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  await bootDone(page);
  await page.evaluate((v) => window.__RICHOS_MOCK__.updateSet(Object.assign({}, v, { checkedAt: Date.now() }), []), AVAILABLE);
  await page.waitForSelector("#update-cue", { state: "visible" });
  return page;
}

async function main() {
  const run = createRun("slow-bridge — the two interactions that were correct only at zero latency");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();

  // ---- 1. a thread pressed during boot is the thread that opens -------------------------
  for (const lag of LATENCIES) {
    await run.check(`a thread pressed during boot is the thread that opens (${lag}ms bridge)`, async () => {
      // Three presses across the window `init()` used to own: 3, 3.5 and 4 call-times after the
      // row appears. At 0 ms they are all "immediately", which is the control case.
      const offsets = [3 * lag, 3.5 * lag, 4 * lag].map(Math.round);
      const seen = [];
      for (const after of offsets) {
        const r = await pressDuringBoot(browser, lag, after);
        assertEqual(r.errors, [], `the shell logged errors on the press at +${after}ms`);
        assertEqual(
          r.on.bound,
          "hiring",
          `pressed "hiring" at +${after}ms and the conversation on screen is ` +
            JSON.stringify(r.on.entity + " / " + r.on.crumb) +
            ` — the rail marks ${JSON.stringify(r.on.active)}, the model is bound to ` +
            `${JSON.stringify(r.on.bound)}, ${r.on.turns} turn(s) painted. A press that opens a ` +
            `different conversation than the one pressed is the defect, not a slow machine`
        );
        assertEqual(r.on.active, "hiring", `the rail marks the thread he pressed at +${after}ms`);
        assert(r.on.turns > 0, `and its turns are painted, not the previous thread's: ${r.on.turns}`);
        seen.push("+" + after + "ms");
      }
      return `pressed at ${seen.join(", ")} — every one landed on Northwind Traders / "Q4 hiring" with its own turn`;
    });
  }

  // ---- 2. and the shell REMEMBERS the thread he pressed ----------------------------------
  await run.check("the shell remembers the thread he pressed, not the one the boot would have imposed", async () => {
    // A race here does not end when the window is repainted: `switch_thread` is what the NEXT
    // launch restores from, so a boot that issued its own behind his left the wrong thread
    // durably active even on a launch where the screen happened to end up right.
    const out = [];
    for (const lag of LATENCIES.filter((l) => l > 0)) {
      const r = await pressDuringBoot(browser, lag, Math.round(3.5 * lag));
      assertEqual(
        r.remembered,
        "hiring",
        `at ${lag}ms the screen shows ${JSON.stringify(r.on.bound)} and the shell would restore ` +
          `${JSON.stringify(r.remembered)} — the next launch would land him somewhere he never chose`
      );
      out.push(`${lag}ms: active_thread = "hiring"`);
    }
    return out.join("; ");
  });

  // ---- 3. ...and the restore itself still happens when he presses nothing -----------------
  await run.check("with no press at all, the boot still restores where the last session ended", async () => {
    // The other half, and the one a fix like this breaks if it is written as "never restore".
    const out = [];
    for (const lag of LATENCIES) {
      const page = await open(browser, lag);
      await bootDone(page);
      const on = await onScreen(page);
      const remembered = await page.evaluate(() => window.RichBridge.invoke("active_thread"));
      assertEqual(on.bound, "general", `at ${lag}ms the boot did not restore the last session's thread`);
      assertEqual(remembered, "general", `at ${lag}ms the shell's own memory disagrees with the screen`);
      assertEqual(page.__errors, [], `the shell logged errors during a plain boot at ${lag}ms`);
      await page.close();
      out.push(`${lag}ms: general`);
    }
    return "restored at " + out.join(", ");
  });

  // ---- 4. the update cue puts the hand on the control -------------------------------------
  for (const lag of LATENCIES) {
    await run.check(`the update cue puts the hand on the control (${lag}ms bridge)`, async () => {
      const page = await withUpdateWaiting(browser, lag);
      // PRESSED AND READ IN ONE SYNCHRONOUS BLOCK — no task turn, no frame, no round trip. This
      // is the strongest form of §26's "one keystroke from the act": the hand is on the control
      // before control returns to the event loop, so there is no window for anything to be
      // waited out. A deferred focus cannot pass this line at any latency, including 0.
      const immediate = await page.evaluate(() => {
        document.getElementById("update-cue").click();
        const go = document.getElementById("update-install");
        return {
          focus: document.activeElement && document.activeElement.id,
          hidden: !!(go && go.hidden),
          disabled: !!(go && go.disabled),
        };
      });
      assertEqual(immediate.disabled, false, "the menu's own re-read must not disarm the control it opens onto");
      assertEqual(
        immediate.focus,
        "update-install",
        "the hand is on the row's own control in the same turn as the press, not one task queue later"
      );
      // AND THE KEYSTROKE REACHES THE COMMAND. Focus on a control that does nothing would be a
      // more elaborate version of the same defect.
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => window.__RICHOS_MOCK__.updateCalls().indexOf("update_install") >= 0, {
        timeout: 15000,
      });
      const calls = await page.evaluate(() => window.__RICHOS_MOCK__.updateCalls());
      assertEqual(page.__errors, [], "the shell logged errors between the cue and the command");
      await page.close();
      return `focus landed synchronously on #update-install and Enter issued update_install (${calls.join(", ")})`;
    });
  }

  // ---- 5. the control is never disarmed by the menu's own re-read -------------------------
  await run.check("the row's control is never disarmed by the menu's own re-read (400ms bridge)", async () => {
    // `update_state` is a pure READ (`updates.rs:767` — `refresh_work_verdict` then `snapshot`).
    // Sampling ACROSS the whole round trip is the assertion: at 400 ms there is a third of a
    // second in which the old code offered a dimmed, unpressable button to a CEO who had just
    // been told an update was waiting.
    const page = await withUpdateWaiting(browser, 400);
    await page.evaluate(() => {
      window.__disarmed = [];
      const sample = () => {
        const go = document.getElementById("update-install");
        window.__disarmed.push(!go ? "absent" : go.hidden ? "hidden" : go.disabled ? "disabled" : "live");
        if (window.__sampling) requestAnimationFrame(sample);
      };
      window.__sampling = true;
      document.getElementById("update-cue").click();
      sample();
    });
    await observe(page, 900, "one 400ms round trip and change — the whole length of the re-read the press sets off");
    const seen = await page.evaluate(() => {
      window.__sampling = false;
      return window.__disarmed;
    });
    const bad = seen.filter((s) => s !== "live");
    assert(seen.length > 10, `the sampler ran: ${seen.length} frame(s)`);
    assertEqual(bad, [], `the control was not pressable on ${bad.length} of ${seen.length} sampled frames`);
    assertEqual(page.__errors, [], "the shell logged errors while the row was re-read");
    await page.close();
    return `${seen.length} frames sampled across a 400ms read, live on every one`;
  });

  await browser.close();
  process.exit(run.report() > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

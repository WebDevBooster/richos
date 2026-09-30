// THE APP HAS FINISHED WHAT A PRESS STARTED — read off the bridge, not the clock.
//
// Hunt part 2 recheck R41 (richos-hq `docs/audits/2026-09-30-hunt/part-2-codex-recheck.md`):
// `techy.js` waited a fixed 250 ms or 120 ms after each press, and `setup.js` 2,500 ms after
// an Escape. A fixed wait costs its full length when the app is already done, and is too short
// when the app is slow: `main.js`'s answer to a press is a chain of awaited bridge calls
// (`openThread` awaits six of them before the conversation is painted; confirming the
// technical-view sheet awaits `set_techy_scope` and then `loadTimeline`'s read), so how long
// it takes is how long those round trips take.
//
// SO THE WAIT IS ON THE CHAIN ITSELF. Every bridge call the page starts is counted, and so is
// every one that settles. A press has finished when the two counts are equal, every finite
// animation has run out (`awaitSettled`) and the result is painted (`flushFrames`). That is a
// fact about the app that is not the fact a check then asserts, so the assertion still decides
// pass or fail (`appearance.js`'s afterInvoke rule): a product that writes the wrong thing
// fails, it does not hang.
//
// WHY EQUAL COUNTS MEAN THE CHAIN IS DONE. A chain's next call is started by the continuation
// of the previous one, which is a microtask; the count is read by a separate task, and every
// microtask runs before the next task. So a read can never land between one call settling and
// the next one starting. The chains these suites wait on await nothing but bridge calls and a
// render frame, and the frame is `flushFrames`'s.
//
// Latency, optional: `COUNT_BRIDGE(ms)` also puts `ms` on every call, the lever `harness.js`'s
// `SLOW_BRIDGE` describes ("a check that is green at zero and green at 120 is a check that
// waited for a signal"). It lives in this one wrapper because two hooks on `window.RichBridge`
// replace each other.

"use strict";

const { awaitSettled, flushFrames } = require("./harness");

/// An init script: count the bridge calls the page starts and settles, and add `lagMs` to
/// each. Pass it to `page.addInitScript` before `goto`. Counted in a `finally`, so a command
/// the mock rejects still settles.
const COUNT_BRIDGE = (lagMs) => {
  let real;
  window.__bridgeCalls = { started: 0, settled: 0 };
  Object.defineProperty(window, "RichBridge", {
    configurable: true,
    get: () => real,
    set: (v) => {
      real = v;
      const invoke = v.invoke.bind(v);
      v.invoke = async (...args) => {
        window.__bridgeCalls.started++;
        try {
          if (lagMs > 0) await new Promise((r) => setTimeout(r, lagMs));
          return await invoke(...args);
        } finally {
          window.__bridgeCalls.settled++;
        }
      };
    },
  });
};

/// A hang guard, not a verdict: a quiet bridge normally arrives within a few round trips.
/// Running out of it throws with what was still in flight (the 30-second floor the UI
/// suites keep for hang guards, `591d26d14`).
const QUIET_GUARD_MS = 30000;

/// Return when every bridge call the page has started has settled, every finite animation
/// has finished and the result is painted. `what` names the press, for the failure message.
async function bridgeQuiet(page, what) {
  const installed = await page.evaluate(() => !!window.__bridgeCalls);
  if (!installed) {
    throw new Error(`bridgeQuiet (${what}): this page was opened without COUNT_BRIDGE, so there is nothing to wait on`);
  }
  await page
    .waitForFunction(() => window.__bridgeCalls.started === window.__bridgeCalls.settled, undefined, {
      timeout: QUIET_GUARD_MS,
    })
    .catch(async (e) => {
      const c = await page.evaluate(() => window.__bridgeCalls).catch(() => null);
      throw new Error(
        `bridgeQuiet (${what}): the bridge was still busy after ${QUIET_GUARD_MS} ms ` +
          `(${c ? c.started - c.settled : "?"} call(s) in flight): ` +
          String(e.message || e).split("\n")[0]
      );
    });
  await awaitSettled(page);
  await flushFrames(page);
}

module.exports = { COUNT_BRIDGE, bridgeQuiet };

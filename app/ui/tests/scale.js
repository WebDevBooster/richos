// THE TWO PROMISED NUMBERS — RICH-TODOs "virtualization" row.
//
// §25 "Accessibility and performance" makes two claims with a number in them:
//
//     "A 10,000-item thread history remains smooth through virtualization."
//     "A 10,000-entity seeded index remains searchable and bounded."
//
// Until 2026-08-30 neither had a test, and the first had no implementation either — three
// documents said the timeline "uses virtualized infinite scroll" and
// `grep -rn virtualiz app/` returned nothing. A capability a document claims and the tree
// does not deliver is the defect this project exists to catch, and it was sitting in the
// design record for the surface the CEO looks at most.
//
// ---------------------------------------------------------------------------------------
// WHAT THIS SUITE PINS, AND WHY IT IS NOT ONLY TIMINGS
// ---------------------------------------------------------------------------------------
//
// A budget in milliseconds is a real check and it is also a flaky one: it moves with the
// machine, the load and the WebKit build. So every timing here is paired with a STRUCTURAL
// check of the property that produces it — reuse is asserted by NODE IDENTITY, correctness
// of that reuse by a byte-for-byte comparison against a from-scratch render, and the
// projection's fast path against the brute-force scan it replaced. If the budgets are ever
// loosened, those keep working.
//
// The budgets are set roughly an order of magnitude above the measured figure and roughly
// an order of magnitude below the number this work started from, so they catch a return of
// the defect and not a busy laptop. Measured and baseline figures are named at each one.
// Full sweeps: `docs/verification/timeline-scale-2026-08-30/`, tool `lib/scale-bench.js`.
//
// THE SECOND NUMBER IS NOT IN THIS FILE, AND THAT IS SAID OUT LOUD RATHER THAN LEFT TO A
// READER. The 10,000-entity index is `run_search` in `app/src-tauri/src/main.rs`, a
// different component in a different language; its test is the Rust one named in check 10,
// and check 10 exists so that half of the row cannot quietly lose its test while this half
// keeps passing.
//
// NO PAGINATION (standing rule, CEO). Check 9 is structural: at 10,000 items every turn is
// mounted and the DOM carries no page control of any kind. This work made the timeline
// faster by reusing nodes, NEVER by rendering fewer turns.
//
// Every check here was run RED once, by breaking the thing it guards in the shipped source.
// Those runs are transcribed in
// `docs/verification/timeline-scale-2026-08-30/mutation-runs.txt`.

"use strict";

const fs = require("fs");
const path = require("path");
const { loadPlaywright, openFixture, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness.js");
const { makeSnapshot, oneMoreActivity, ENTITY, THREAD, T0 } = require("./lib/scale-fixtures.js");

// THE PROMISED NUMBER, at a realistic turn shape: 1,000 turns of ten items.
const TURNS = 1000;
const PER_TURN = 10;
const ITEMS = TURNS * PER_TURN;

// Budgets. Left column is what this branch measures, right is what the tree measured before
// it (docs/verification/timeline-scale-2026-08-30/baseline.txt).
// A structural change is TWO costs and they move independently. The JS half — projection,
// signatures, DOM construction — is what turn reuse removed, and it is the one that
// regresses if reuse ever breaks. The rest is WebKit re-measuring a 1,000-child flex column
// when one child changes height, which is a floor imposed by mounting every turn (and
// mounting every turn is the NO PAGINATION rule, so it stays). Two budgets, because one
// number would hide which half moved.
const BUDGET_STRUCT_JS_MS = 20; // measured  2ms | baseline ~60ms of the 257
const BUDGET_STRUCT_MS = 90; // measured 22ms | baseline 257ms
const BUDGET_FRAME_P95_MS = 30; // measured 17ms  | baseline 18ms (this was never the defect)
const BUDGET_FIRST_PAINT_MS = 900; // measured 265ms | baseline 278ms
// Set BELOW the baseline on purpose. 34ms is what the tree measured before this work
// (apply 15 + turnsOf 19); a budget of 60 would have passed on the very code it exists to
// catch, which is a check that cannot fail. 20ms is 10x the measured figure and still well
// under the number it guards against.
const BUDGET_PROJECTION_MS = 20; // measured 2ms | baseline 34ms (apply 15 + turnsOf 19)

/// Install the shared page state every check below works from: one 10,000-item model,
/// rendered once, with the shipping options object.
async function seed(page, snapshot) {
  return page.evaluate(async (snap) => {
    const messages = document.getElementById("messages");
    const model = window.RichTimeline.createModel();
    window.RichTimeline.bind(model, snap.entityId, snap.threadId, snap.bindingRevision);
    const t0 = performance.now();
    window.RichTimeline.applySnapshot(model, snap);
    const applyMs = performance.now() - t0;
    const p0 = performance.now();
    window.RichTimeline.turnsOf(model);
    const turnsOfMs = performance.now() - p0;

    window.__model = model;
    window.__opts = {
      now: 1787950000000,
      expandedMessages: new Set(),
      avatarAlreadyShown: true,
      isExpanded: (id) => window.RichTimeline.isTurnExpanded(model, id),
      toggle: () => {},
      rerender: () => {},
      copy: () => {},
      retry: () => {},
      openWorker: () => {},
    };
    messages.innerHTML = "";
    window.RichTimeline.render(model, messages, window.__opts);
    // LET IT ACTUALLY PAINT HERE. Otherwise the first render in the next check pays for the
    // initial layout of all 32,001 nodes and reports it as the cost of adding one activity
    // row — measured 181ms of somebody else's bill before this line existed, and 24ms with
    // only a forced `scrollHeight` and no frame.
    void document.getElementById("conversation").scrollHeight;
    await new Promise((res) => requestAnimationFrame(() => requestAnimationFrame(res)));
    return { applyMs, turnsOfMs, turns: model.turnOrder.length, items: model.items.size };
  }, snapshot);
}

async function main() {
  const pw = loadPlaywright();
  const browser = await pw.webkit.launch();
  const run = createRun("§25 the timeline at 10,000 items — WebKit");
  const page = await openFixture(browser, { width: 1280, height: 900 });

  const snapshot = makeSnapshot(TURNS, PER_TURN);
  const snapshotItems = snapshot.items.length;
  const lastTurnId = "turn_" + (TURNS - 1);
  const seeded = await seed(page, snapshot);

  await run.check("the fixture really is a 10,000-item thread, not a small one named 10,000", async () => {
    // THE EMPTY-CORPUS GUARD. Every budget below is meaningless if the model is small, and
    // "10,000" in a constant is not evidence that 10,000 items reached the renderer.
    // `applySnapshot` folds every `work_duration` row into its turn RECORD instead of
    // storing it as an item (one per turn), so a 10,000-item snapshot is 9,000 model items.
    // Both numbers are asserted: the wire payload is the promised size and the model is the
    // exact projection of it.
    assertEqual(snapshotItems, ITEMS, "items on the wire");
    assertEqual(seeded.items, ITEMS - TURNS, "items in the model (durations live on the turn record)");
    assertEqual(seeded.turns, TURNS, "turns in the model");
    const drawn = await page.evaluate(() => document.querySelectorAll("#messages > .tl-turn").length);
    assertEqual(drawn, TURNS, "turn sections in the DOM");
    return `${snapshotItems} items on the wire -> ${seeded.items} model items + ${seeded.turns} turn records, ${drawn} mounted sections`;
  });

  await run.check("ONE new activity row does not rebuild the thread", async () => {
    // THE DEFECT THIS ROW WAS ABOUT. `render` used to empty the container and rebuild every
    // turn on every structural change — and a structural change is every activity row,
    // every worker upsert, every turn-status transition, dozens of them in one 52-second
    // multi-tool turn. Measured 257ms each at this size before 2cf03b0.
    const r = await page.evaluate(
      ({ payloads }) => {
        const messages = document.getElementById("messages");
        const conv = document.getElementById("conversation");
        const times = [];
        const js = [];
        for (const p of payloads) {
          window.RichTimeline.onActivityUpserted(window.__model, p);
          const t0 = performance.now();
          window.RichTimeline.render(window.__model, messages, window.__opts);
          js.push(performance.now() - t0);
          void conv.scrollHeight; // the layout the CEO pays for, not just the JS
          times.push(performance.now() - t0);
        }
        times.sort((a, b) => a - b);
        js.sort((a, b) => a - b);
        return { median: times[2], worst: times[4], js: js[2] };
      },
      { payloads: [0, 1, 2, 3, 4].map((i) => oneMoreActivity(lastTurnId, i)) }
    );
    assert(
      r.js <= BUDGET_STRUCT_JS_MS,
      `the JS half of a structural change at ${ITEMS} items took ${r.js.toFixed(0)}ms ` +
        `(budget ${BUDGET_STRUCT_JS_MS}ms) — the thread is being REBUILT rather than reused`
    );
    assert(
      r.median <= BUDGET_STRUCT_MS,
      `a structural change at ${ITEMS} items took ${r.median.toFixed(0)}ms (budget ${BUDGET_STRUCT_MS}ms, ` +
        `baseline before this work 257ms) — the whole thread is being rebuilt again`
    );
    return (
      `median of 5: ${r.median.toFixed(0)}ms total, ${r.js.toFixed(0)}ms of it JS ` +
      `(budgets ${BUDGET_STRUCT_MS}/${BUDGET_STRUCT_JS_MS}ms; baseline 257ms total). ` +
      `The remainder is WebKit re-measuring ${TURNS} mounted flex children.`
    );
  });

  await run.check("STRUCTURAL: the other 999 turns keep the DOM nodes they already had", async () => {
    // The timing above is the symptom; THIS is the property. Node identity, not innerHTML —
    // an equal-looking rebuild would pass a text comparison and fail here.
    const r = await page.evaluate(({ payload }) => {
      const messages = document.getElementById("messages");
      const before = Array.from(messages.children);
      window.RichTimeline.onActivityUpserted(window.__model, payload);
      window.RichTimeline.render(window.__model, messages, window.__opts);
      const after = Array.from(messages.children);
      let same = 0;
      let replaced = [];
      for (let i = 0; i < Math.min(before.length, after.length); i++) {
        if (before[i] === after[i]) same++;
        else replaced.push(after[i].dataset.turnId);
      }
      return { beforeLen: before.length, afterLen: after.length, same, replaced };
    }, { payload: oneMoreActivity(lastTurnId, 99) });
    assertEqual(r.afterLen, TURNS, "the turn count is unchanged");
    assertEqual(r.replaced, [lastTurnId], "exactly the turn that changed is rebuilt, and only it");
    assertEqual(r.same, TURNS - 1, "every other turn is the SAME node object");
    return `${r.same}/${r.afterLen} sections identical by reference; rebuilt: ${r.replaced.join(", ")}`;
  });

  await run.check("CORRECTNESS: the reused DOM is byte-identical to a from-scratch render", async () => {
    // The check that makes the one above safe. Reuse is only ever an optimization if what
    // is on screen is what a full rebuild would have produced — so the same model is
    // rendered into a SECOND container, which has no cache and therefore builds everything,
    // and the two are compared as markup.
    const r = await page.evaluate(() => {
      const messages = document.getElementById("messages");
      const fresh = document.createElement("div");
      document.body.appendChild(fresh);
      window.RichTimeline.render(window.__model, fresh, window.__opts);
      const a = messages.innerHTML;
      const b = fresh.innerHTML;
      fresh.remove();
      let at = -1;
      for (let i = 0; i < Math.max(a.length, b.length); i++) {
        if (a[i] !== b[i]) {
          at = i;
          break;
        }
      }
      return { equal: a === b, length: a.length, at, a: a.slice(Math.max(0, at - 60), at + 60), b: b.slice(Math.max(0, at - 60), at + 60) };
    });
    assert(r.equal, `the incrementally-updated DOM diverges at character ${r.at}:\n          reused: ${r.a}\n          fresh:  ${r.b}`);
    return `${r.length} characters of markup, identical`;
  });

  await run.check("a streamed delta reaches a turn whose nodes were reused", async () => {
    // THE REGRESSION REUSE WOULD HAVE INTRODUCED. `onMessageDelta` used to do
    // `existing.text += p.textDelta` — mutating the item behind the reference the signature
    // is built from. Harmless while every render was a full rebuild; with reuse it freezes
    // the prose at whatever the last structural render caught. The delta path now replaces
    // the object, and this drives it through the RENDER path (not `updateProse`) to prove
    // the item, not the node write, is what carries the text.
    const r = await page.evaluate(() => {
      const messages = document.getElementById("messages");
      const model = window.__model;
      const turnId = "turn_500";
      const messageId = turnId + ":text:0";
      const before = model.items.get(messageId).text;
      window.RichTimeline.onMessageDelta(model, {
        entityId: model.entityId,
        threadId: model.threadId,
        bindingRevision: 1,
        turnId: turnId,
        messageId: messageId,
        textDelta: " AND THE TAIL THE DELTA ADDED.",
        at: 1787949000000,
      });
      window.RichTimeline.render(model, messages, window.__opts);
      const node = messages.querySelector('[id="prose:' + messageId + '"]');
      return { before: before, model: model.items.get(messageId).text, onScreen: node ? node.textContent : null };
    });
    assert(r.onScreen !== null, "the prose node must still be on screen");
    assert(
      r.onScreen.endsWith(" AND THE TAIL THE DELTA ADDED."),
      `a structural render after a delta showed stale prose:\n          on screen: ${JSON.stringify(r.onScreen.slice(-60))}`
    );
    assertEqual(r.onScreen, r.model, "the screen and the model agree");
    return `${r.before.length} chars -> ${r.onScreen.length} on screen, tail present after a full render`;
  });

  await run.check(`scrolling the whole ${ITEMS}-item history stays at frame rate`, async () => {
    // THE CLAIM THE DOCUMENTS ACTUALLY MADE. Deliberately harsher than a real flick: the
    // viewport is dragged through the ENTIRE history in 60 steps, so content is revealed the
    // whole way. 17ms is this engine's vsync floor.
    const r = await page.evaluate(async () => {
      const conv = document.getElementById("conversation");
      conv.scrollTop = conv.scrollHeight;
      await new Promise((res) => requestAnimationFrame(res));
      const frames = [];
      const step = Math.max(1, Math.floor(conv.scrollHeight / 60));
      let pos = conv.scrollHeight;
      let prev = performance.now();
      for (let i = 0; i < 60; i++) {
        pos -= step;
        conv.scrollTop = pos;
        await new Promise((res) => requestAnimationFrame(res));
        const now = performance.now();
        frames.push(now - prev);
        prev = now;
      }
      frames.sort((a, b) => a - b);
      return {
        p50: frames[30], p95: frames[57], max: frames[59], px: conv.scrollHeight,
        travelled: conv.scrollHeight - conv.scrollTop,
        overflowY: getComputedStyle(conv).overflowY,
        viewport: conv.clientHeight,
      };
    });
    // THE POSITIVE PROBE, and a mutation run earned it: `scrollTop` can be SET on a
    // container with `overflow-y: hidden`, so a timing-only check passes perfectly on a
    // timeline the CEO cannot scroll at all. §15 is a section about a SCROLL CONTAINER;
    // assert that it is one before timing anything in it.
    assert(
      r.overflowY === "auto" || r.overflowY === "scroll",
      `#conversation is not a scroll container — overflow-y is ${r.overflowY}`
    );
    assert(r.px > r.viewport * 10, `the history must overflow the viewport — ${r.px}px in ${r.viewport}px`);
    assert(r.travelled > 100000, `the scroll must actually travel — it moved ${r.travelled}px`);
    assert(
      r.p95 <= BUDGET_FRAME_P95_MS,
      `scroll frames at ${ITEMS} items: p95 ${r.p95.toFixed(0)}ms (budget ${BUDGET_FRAME_P95_MS}ms)`
    );
    return `p50 ${r.p50.toFixed(0)}ms, p95 ${r.p95.toFixed(0)}ms, max ${r.max.toFixed(0)}ms over ${r.px}px of history`;
  });

  await run.check("opening the thread paints, and the projection is not quadratic", async () => {
    const r = await page.evaluate(async (snap) => {
      const messages = document.getElementById("messages");
      const conv = document.getElementById("conversation");
      const model = window.RichTimeline.createModel();
      window.RichTimeline.bind(model, snap.entityId, snap.threadId, snap.bindingRevision);
      const a0 = performance.now();
      window.RichTimeline.applySnapshot(model, snap);
      const applyMs = performance.now() - a0;
      const p0 = performance.now();
      window.RichTimeline.turnsOf(model);
      const turnsOfMs = performance.now() - p0;
      const opts = Object.assign({}, window.__opts, {
        isExpanded: (id) => window.RichTimeline.isTurnExpanded(model, id),
      });
      messages.innerHTML = "";
      const f0 = performance.now();
      window.RichTimeline.render(model, messages, opts);
      void conv.scrollHeight;
      await new Promise((res) => requestAnimationFrame(() => requestAnimationFrame(res)));
      return { applyMs, turnsOfMs, firstPaintMs: performance.now() - f0 };
    }, snapshot);
    assert(
      r.firstPaintMs <= BUDGET_FIRST_PAINT_MS,
      `first paint at ${ITEMS} items took ${r.firstPaintMs.toFixed(0)}ms (budget ${BUDGET_FIRST_PAINT_MS}ms)`
    );
    assert(
      r.applyMs + r.turnsOfMs <= BUDGET_PROJECTION_MS,
      `model + projection took ${(r.applyMs + r.turnsOfMs).toFixed(0)}ms (budget ${BUDGET_PROJECTION_MS}ms, ` +
        `baseline 34ms) — a per-item scan over the turn list is back`
    );
    return (
      `first paint ${r.firstPaintMs.toFixed(0)}ms (budget ${BUDGET_FIRST_PAINT_MS}); ` +
      `apply ${r.applyMs.toFixed(0)}ms + turnsOf ${r.turnsOfMs.toFixed(0)}ms (budget ${BUDGET_PROJECTION_MS}, was 34ms)`
    );
  });

  await run.check("§9.2's steering cue: the fast predicate agrees with the scan it replaced", async () => {
    // `addedWhileWorking` went from `spans.some(...)` per turn to a binary search against a
    // running TOP-TWO maximum, and the top-two is the whole subtlety: a turn's own span
    // always reaches its own prompt, so a plain maximum answers "yes" for everything. This
    // runs both over a mix built to break a careless version — turns that overlap, a turn
    // nested wholly inside another, a live turn with no end, and ordinary turns that must
    // NOT be flagged — and requires them to agree message for message.
    const r = await page.evaluate(() => {
      const model = window.RichTimeline.createModel();
      window.RichTimeline.bind(model, "northwind", "thr_steer", 1);
      const T = 1787000000000;
      //
      // THE LIVE TURN IS LAST ON PURPOSE. Its span is open-ended (`to: Infinity`), so every
      // prompt after it is inside SOME other turn's span and legitimately flagged — put it
      // in the middle and the "not steering" half of this check has nothing left to hold,
      // which is exactly how the first version of this mix read.
      //
      // [turnId, promptAt, startedAt, activeMs|null, live]
      const spec = [
        ["a", T + 0, T + 10, 5000, false], // long turn, prompt before its own start -> quiet
        ["b", T + 2000, T + 2100, 100, false], // prompt landed INSIDE a's span -> steering
        ["c", T + 3000, T + 3100, 20000, false], // starts inside a, runs past it -> steering
        ["d", T + 4000, T + 4100, 50, false], // nested inside BOTH a and c -> steering
        ["g", T + 500000, T + 500010, 30, false], // alone and quiet -> NOT steering
        ["h", T + 500020, T + 500100, 40, false], // prompt inside g's SHORT span -> steering
        ["i", T + 700000, T + 700010, 40, false], // alone and quiet -> NOT steering
        // THE ONLY SHAPE IN WHICH THE EXCLUSION IS DECIDABLE AT ALL. Everywhere else the
        // prompt lands BEFORE its own turn started (`PromptReceived` is written before
        // `TurnStarted`), so a turn's own span is not even a candidate and any predicate
        // agrees. Here the prompt is AT the start, the own span IS the running maximum, and
        // only keeping the RUNNER-UP gets the answer right. A mutation run earned this row:
        // without it, replacing the top-two with a plain maximum passed.
        ["j", T + 800000, T + 800000, 5000, false], // prompt ON its own start -> quiet
        ["e", T + 900000, T + 900010, null, true], // live, no end -> quiet itself
        ["f", T + 950000, T + 950010, 10, false], // inside e's OPEN span -> steering
      ];
      const items = [];
      for (const [id, promptAt, startedAt, activeMs, live] of spec) {
        items.push({
          kind: "user_message", id: "turn_" + id + ":user", entityId: "northwind", threadId: "thr_steer",
          turnId: "turn_" + id, bindingRevision: 1, createdAt: promptAt, slot: "opening", sequence: null,
          visibility: "ceo", text: "prompt " + id, source: "text",
        });
        items.push({
          kind: "work_duration", id: "turn_" + id + ":duration", entityId: "northwind", threadId: "thr_steer",
          turnId: "turn_" + id, bindingRevision: 1, createdAt: promptAt, slot: "terminal", sequence: null,
          visibility: "ceo", state: live ? "working" : "completed", startedAt: startedAt,
          endedAt: activeMs === null ? null : startedAt + activeMs, activeMs: activeMs,
        });
      }
      window.RichTimeline.applySnapshot(model, {
        entityId: "northwind", threadId: "thr_steer", mode: "ceo", bindingRevision: 1, items: items,
      });
      for (const [id, , , , live] of spec) if (live) model.turns.get("turn_" + id).live = true;

      // THE BRUTE FORCE, written here rather than imported — this is the definition the
      // shipped predicate has to match, and importing it would compare the fast path to
      // itself.
      const spans = [];
      for (const [id, t] of model.turns) {
        if (typeof t.startedAt !== "number") continue;
        const end = typeof t.activeMs === "number" ? t.startedAt + t.activeMs : t.live ? Infinity : null;
        if (end === null) continue;
        spans.push({ id: id, from: t.startedAt, to: end });
      }
      const brute = (turnId, at) =>
        spans.some((s) => s.id !== turnId && at >= s.from && at <= s.to);

      const shipped = {};
      const expected = {};
      for (const turn of window.RichTimeline.turnsOf(model)) {
        if (!turn.user) continue;
        shipped[turn.turnId] = !!turn.user.steering;
        expected[turn.turnId] = brute(turn.turnId, turn.user.createdAt);
      }
      return { shipped, expected, spans: spans.length };
    });
    assertEqual(r.spans, 10, "the mix must actually produce spans");
    assertEqual(r.shipped, r.expected, "the fast predicate disagrees with the brute-force scan");
    const flagged = Object.keys(r.expected).filter((k) => r.expected[k]);
    const quiet = Object.keys(r.expected).filter((k) => !r.expected[k]);
    // POSITIVE AND NEGATIVE BOTH PRESENT — an all-false agreement would agree with anything.
    assert(flagged.length >= 3, "the mix must flag some messages as steering");
    assert(quiet.length >= 3, "the mix must leave some messages unflagged");
    return `10 turns, ${flagged.length} steering (${flagged.join(",")}), ${quiet.length} not (${quiet.join(",")}) — both agree`;
  });

  await run.check("a turn with a record is always in the turn order", async () => {
    // The implication `turnRecord`'s guard now relies on. It used to re-scan `turnOrder` for
    // every ITEM; it now only scans when it CREATES the record, which is only sound while
    // "has a record" implies "is in the order". Driven through every mutation site that
    // touches either: snapshot, live upsert, an optimistic bubble adopted onto a real turn,
    // a local notice (which is in the order with NO record — the reverse, and legal), and a
    // supersede, which drops one turn and re-inserts the replacement in its place.
    const r = await page.evaluate(() => {
      const model = window.RichTimeline.createModel();
      window.RichTimeline.bind(model, "northwind", "thr_inv", 1);
      const mk = (turnId, id, extra) =>
        Object.assign({ id, entityId: "northwind", threadId: "thr_inv", turnId, bindingRevision: 1,
          createdAt: 1787000000000, slot: "stream", sequence: 0, visibility: "ceo" }, extra);
      const violations = [];
      const everSeen = new Set();
      let checkpoints = 0;
      const checkpoint = (label) => {
        checkpoints++;
        for (const id of model.turns.keys()) everSeen.add(id);
        for (const id of model.turns.keys()) {
          if (model.turnOrder.indexOf(id) < 0) violations.push(label + ": " + id);
        }
        const seen = new Set();
        for (const id of model.turnOrder) {
          if (seen.has(id)) violations.push(label + ": duplicate in turnOrder: " + id);
          seen.add(id);
        }
      };

      window.RichTimeline.applySnapshot(model, { entityId: "northwind", threadId: "thr_inv", mode: "ceo",
        bindingRevision: 1, items: [mk("t1", "t1:a", { kind: "activity", activityType: "read", state: "completed", summary: "x" })] });
      checkpoint("after snapshot");

      // The payload IS the item (STREAMING.md), so it is passed flat.
      window.RichTimeline.onActivityUpserted(model,
        mk("t2", "t2:a", { kind: "activity", activityType: "read", state: "completed", summary: "y", at: 1787000000000 }));
      checkpoint("after a live activity on a new turn");

      window.RichTimeline.addPendingUserMessage(model, "hello", 1787000000001);
      window.RichTimeline.onTurnStatus(model, { entityId: "northwind", threadId: "thr_inv", bindingRevision: 1,
        turnId: "t3", status: "working", at: 1787000000002 });
      checkpoint("after an optimistic bubble was adopted");

      window.RichTimeline.addLocalNotice(model, "a locally authored line", 1787000000003);
      checkpoint("after a local notice (in the order with no record — the legal reverse)");

      window.RichTimeline.onTurnStatus(model, { entityId: "northwind", threadId: "thr_inv", bindingRevision: 1,
        turnId: "t4", status: "queued", supersedesTurnId: "t3", at: 1787000000004 });
      checkpoint("after a supersede dropped one turn and inserted its replacement");

      return { violations, everSeen: Array.from(everSeen).sort(), checkpoints, turns: model.turns.size, order: model.turnOrder.length };
    });
    assertEqual(r.violations, [], "a turn had a record but no place in the order");
    // THE EMPTY-CORPUS GUARD. Four distinct turn records are created across the sweep and
    // three survive it — `onTurnStatus` drops the superseded turn before creating its
    // replacement, so the two are never both present and the peak is three, not four.
    // Naming every id ever seen is what proves the sequence really ran: a check on the end
    // state alone would pass on a model where `onTurnStatus` had quietly stopped creating
    // records at all.
    assertEqual(r.everSeen, ["t1", "t2", "t3", "t4"], "four distinct turn records were created across the sweep");
    assertEqual(r.turns, 3, "three survive the supersede");
    assertEqual(r.checkpoints, 5, "every mutation site was visited");
    return `${r.everSeen.join(",")} created -> ${r.turns} after the supersede, ${r.order} ordered ids, ${r.checkpoints} checkpoints, 0 violations`;
  });

  await run.check("NO PAGINATION: every turn is mounted and no page control exists", async () => {
    // THE STANDING RULE (CEO), pinned structurally rather than trusted. This work made the
    // timeline faster by REUSING nodes; if a future change makes it faster by rendering
    // fewer turns behind a page control, it fails here. Infinite scroll, virtualization and
    // behind-the-scenes chunked loading are the sanctioned answers and none of them adds a
    // control with a page number on it.
    const r = await page.evaluate(() => {
      const messages = document.getElementById("messages");
      const sections = messages.querySelectorAll(":scope > .tl-turn");
      const ids = new Set(Array.from(sections).map((s) => s.dataset.turnId));
      const text = messages.textContent;
      const banned = [];
      for (const re of [/\bpage\s*\d+\b/i, /\bnext\s+page\b/i, /\bprevious\s+page\b/i, /\bpage\s+\d+\s+of\s+\d+\b/i, /\bshow\s+more\s+(turns|history|messages)\b/i, /\bload\s+more\b/i]) {
        const m = text.match(re);
        if (m) banned.push(m[0]);
      }
      const controls = messages.querySelectorAll("[class*=pagin], [class*=pager], [data-page], nav[aria-label*=agination]");
      return { sections: sections.length, distinct: ids.size, banned, controls: controls.length, chars: text.length };
    });
    assertEqual(r.sections, TURNS, "every turn of the 10,000-item history is mounted");
    assertEqual(r.distinct, TURNS, "and each one exactly once");
    assertEqual(r.banned, [], "page-control wording reached the CEO's timeline");
    assertEqual(r.controls, 0, "a pagination control reached the CEO's timeline");
    assert(r.chars > 100000, `the scan must have real text to scan — it saw ${r.chars} characters`);
    return `${r.sections} turns mounted, ${r.chars} characters scanned, 0 page controls, 0 page wording`;
  });

  await run.check("the OTHER promised number has a test, and it is not in this file", async () => {
    // §25 makes two claims with 10,000 in them. This suite pins the thread history; the
    // entity index is `run_search` in the Tauri shell, matched in Rust so thread bodies
    // never cross the IPC boundary. Joining them here is what stops half the row silently
    // losing its coverage while this half stays green — the same drift `docs-claims.js`
    // catches between this directory and its README.
    const rs = path.join(UI_DIR, "..", "src-tauri", "src", "main.rs");
    const src = fs.readFileSync(rs, "utf8");
    const name = "a_ten_thousand_entity_index_stays_searchable_and_the_result_stays_bounded";
    assert(src.includes("fn " + name + "()"), `${name} is gone from ${rs} — the 10,000-entity half of the row has no test`);
    assert(src.includes("hits.truncate(limit)"), "the bound that test asserts is gone from run_search");
    assert(src.includes("set_entity_registry(seeded)"), "the test no longer seeds a registry — it would be testing the four dogfood entities");
    for (const n of ["10_000", "assert_eq!(hits.len(), 40"]) {
      assert(src.includes(n), `the 10,000-entity test no longer contains ${n}`);
    }
    return `app/src-tauri/src/main.rs::${name} — run it with \`cargo test -p richos-tauri\` (12ms, 40 hits, debug build)`;
  });

  await run.check("no page errors anywhere in this suite", async () => {
    assertEqual(page.__errors, [], "uncaught errors in the fixture");
    return "0 uncaught errors, 0 console errors";
  });

  await page.close();
  const failed = run.report();
  await browser.close();
  return failed;
}

main().then((f) => process.exit(f ? 1 : 0));

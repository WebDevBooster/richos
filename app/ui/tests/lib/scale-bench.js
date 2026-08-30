// THE MEASUREMENT. Not a suite — a bench you run by hand when you want the numbers.
//
//     RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node lib/scale-bench.js
//     node lib/scale-bench.js --expanded      # every work transcript open
//     node lib/scale-bench.js --shape "1000 turns"
//
// It lives in `lib/` on purpose: `run.js` discovers suites from this directory and skips
// `lib/`, and a six-shape sweep that takes a couple of minutes has no business in the run
// every slice does. The BUDGETS derived from it are pinned by `scale.js`, which does belong
// there.
//
// WHY IT EXISTS. Three documents said the timeline "uses virtualized infinite scroll" and
// that "a 10,000-item thread history remains smooth through virtualization"; on 2026-08-30
// `grep -n virtualiz app/` returned nothing at all. Rather than build the missing thing on
// the strength of the sentence, this measured what 10,000 items actually cost. The answer
// was NOT the one the documents implied: scrolling was already fine at 60fps, and the real
// defect was a full DOM teardown on every structural change — 256 ms per new activity row.
// `docs/verification/timeline-scale-2026-08-30/` has the sweep, before and after.
//
// FOUR NUMBERS, AND THEY ARE NOT INTERCHANGEABLE:
//
//   apply / turnsOf   the model and the projection. No DOM. Where a quadratic hides.
//   firstPaint        snapshot to pixels, through two animation frames. Thread open, once.
//   struct            ONE new item, whole render, forced layout. The live path, and the
//                     number that matters: it fires once per tool call for a whole turn.
//   frame p50/p95     scroll frame intervals while dragging the viewport through the entire
//                     history in 60 steps. Deliberately harsher than a real flick — a real
//                     one traverses ~3,000px, this traverses the lot and so reveals content
//                     the whole way. 17ms is this engine's vsync floor; treat it as 60fps.

"use strict";

const H = require("./harness.js");
const { makeSnapshot, oneMoreActivity } = require("./scale-fixtures.js");

// [turns, itemsPerTurn]. The fourth row is THE PROMISED NUMBER at a realistic turn shape;
// rows five and six are the same item count (or double it) redistributed, because a claim
// about "items" that only holds at one turn ratio is not the claim the document makes.
const SHAPES = [
  [10, 10],
  [100, 10],
  [500, 10],
  [1000, 10],
  [10000, 1],
  [2000, 5],
];

async function measure(page, snapshot, expanded) {
  return page.evaluate(
    async ({ snap, expanded }) => {
      const messages = document.getElementById("messages");
      const conv = document.getElementById("conversation");

      const t0 = performance.now();
      const model = window.RichTimeline.createModel();
      window.RichTimeline.bind(model, snap.entityId, snap.threadId, snap.bindingRevision);
      window.RichTimeline.applySnapshot(model, snap);
      const applyMs = performance.now() - t0;
      if (expanded) for (const id of model.turnOrder) model.expanded.add(id);
      window.__model = model;

      const p0 = performance.now();
      window.RichTimeline.turnsOf(model);
      const turnsOfMs = performance.now() - p0;

      const opts = {
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
      const f0 = performance.now();
      window.RichTimeline.render(model, messages, opts);
      const renderMs = performance.now() - f0;
      void conv.scrollHeight; // force layout
      const layoutMs = performance.now() - f0 - renderMs;
      await new Promise((res) => requestAnimationFrame(() => requestAnimationFrame(res)));
      const firstPaintMs = performance.now() - f0;

      const lastTurnId = snap.items[snap.items.length - 1].turnId;
      const struct = [];
      for (let i = 0; i < 5; i++) {
        window.RichTimeline.onActivityUpserted(model, window.__oneMore(lastTurnId, i));
        const s0 = performance.now();
        window.RichTimeline.render(model, messages, opts);
        void conv.scrollHeight;
        struct.push(performance.now() - s0);
      }
      struct.sort((a, b) => a - b);

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
        applyMs,
        turnsOfMs,
        renderMs,
        layoutMs,
        firstPaintMs,
        structMs: struct[2],
        domNodes: messages.getElementsByTagName("*").length,
        scrollPx: conv.scrollHeight,
        p50: frames[30],
        p95: frames[57],
        max: frames[59],
        turns: model.turnOrder.length,
      };
    },
    { snap: snapshot, expanded: expanded }
  );
}

async function main() {
  const expanded = process.argv.includes("--expanded");
  const shapeArg = process.argv.indexOf("--shape");
  const only = shapeArg >= 0 ? process.argv[shapeArg + 1] : null;

  const pw = H.loadPlaywright();
  const browser = await pw.webkit.launch();
  const page = await H.openFixture(browser, { width: 1280, height: 900 });
  // The fixture page is the shipping renderer and nothing else, so the one helper the bench
  // needs inside it is injected rather than re-implemented there.
  await page.exposeFunction("__oneMoreImpl", (turnId, n) => oneMoreActivity(turnId, n));
  await page.evaluate(() => {
    // `exposeFunction` is async; the bench needs it synchronously inside a timing window, so
    // the payloads are precomputed on first use per turn id.
    window.__oneMoreCache = new Map();
    window.__oneMore = (turnId, n) => window.__oneMoreCache.get(turnId + "/" + n);
  });

  console.log(`WebKit ${await page.evaluate(() => navigator.userAgent.replace(/^.*Version/, "Version"))}`);
  console.log(`expanded transcripts: ${expanded}\n`);

  for (const [turns, per] of SHAPES) {
    const label = `${turns} turns x ${per}`;
    if (only && !label.startsWith(only)) continue;
    const snap = makeSnapshot(turns, per);
    const lastTurnId = snap.items[snap.items.length - 1].turnId;
    const payloads = {};
    for (let i = 0; i < 5; i++) payloads[lastTurnId + "/" + i] = oneMoreActivity(lastTurnId, i);
    await page.evaluate((p) => {
      for (const k of Object.keys(p)) window.__oneMoreCache.set(k, p[k]);
    }, payloads);

    const r = await measure(page, snap, expanded);
    console.log(
      `${label.padEnd(18)} items=${String(snap.items.length).padStart(6)} turns=${String(r.turns).padStart(5)}` +
        ` | apply ${r.applyMs.toFixed(0).padStart(5)}ms | turnsOf ${r.turnsOfMs.toFixed(0).padStart(5)}ms` +
        ` | render ${r.renderMs.toFixed(0).padStart(5)}ms | layout ${r.layoutMs.toFixed(0).padStart(5)}ms` +
        ` | firstPaint ${r.firstPaintMs.toFixed(0).padStart(5)}ms | struct ${r.structMs.toFixed(0).padStart(5)}ms` +
        ` | frame p50 ${r.p50.toFixed(0).padStart(3)} p95 ${r.p95.toFixed(0).padStart(3)} max ${r.max.toFixed(0).padStart(3)}` +
        ` | dom ${String(r.domNodes).padStart(6)} nodes, ${r.scrollPx}px`
    );
  }

  if (page.__errors.length) {
    console.log("\nPAGE ERRORS: " + page.__errors.slice(0, 5).join(" | "));
    process.exitCode = 1;
  }
  await browser.close();
}

main();

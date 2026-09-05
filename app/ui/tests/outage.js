// **THE FAILURE CARD, WHEN THE MODEL API IS WHAT FAILED** — `open-items.md` row 3.30,
// rendered by the REAL renderer under WebKit, the engine Tauri ships on macOS.
//
// The row's second and fifth answers reach the CEO here or they reach him nowhere. Before
// this suite existed the card said two fixed sentences for every failure:
//
//     I hit a snag mid-thought and had to stop — say the word and I'll pick it back up.
//     Everything I'd already written above is saved.
//
// The second is true about the TEXT and false about the whole — the session's working
// context is gone, and on 2026-09-03 five agents died having written nothing at all. And
// neither sentence can tell a `529` from a `429`, which are the two ends of "waiting is a
// plan" and "waiting is a plan with a known end".
//
// **THE BYTES ARE THE BACKEND'S, NOT THIS FILE'S.** Every sentence asserted below is
// scraped out of `crates/richos-core/src/upstream.rs` at run time by
// `lib/state-strings.js`'s Rust bridge — the same scrape `affordances.js` builds its state
// inventory from. Nothing here types a sentence, so a reworded `ceo_message()` moves this
// suite with it instead of leaving it green over copy the product no longer says.
//
// Run: node outage.js   (or `npm test` for every suite in this directory)

"use strict";

const { loadPlaywright, openFixture, createRun, assert, assertEqual } = require("./lib/harness");
const { rustStrings, normalize } = require("./lib/state-strings");

const THREAD = "thr_outage";
const TURN = "turn_outage";

// ---------------------------------------------------------------------------------------
// THE SENTENCES, READ OUT OF THE RUST SOURCE
// ---------------------------------------------------------------------------------------

/// Find the one scraped `ceo_message` literal containing `needle`. Throws if there is not
/// exactly one — an ambiguous match means the source moved and this suite would otherwise
/// keep asserting against whichever it happened to pick.
function rustSentence(needle) {
  const hits = rustStrings()
    .map((s) => normalize(s.text))
    .filter((t) => t.includes(needle));
  const unique = Array.from(new Set(hits));
  assertEqual(
    unique.length,
    1,
    `expected exactly one Rust CEO sentence containing ${JSON.stringify(needle)}, found ${unique.length}`
  );
  return unique[0];
}

const OVERLOAD = rustSentence("Anthropic's servers are at capacity");
const QUOTA = rustSentence("Your Claude usage limit is used up");
const NOT_ON_DISK = rustSentence("Not on disk: everything the session had worked out");

// The two generic sentences, which must NOT appear when an outage is explained.
const GENERIC_BODY = "I hit a snag mid-thought and had to stop";
const GENERIC_NOTE = "Everything I'd already written above is saved.";

// ---------------------------------------------------------------------------------------
// FIXTURES
// ---------------------------------------------------------------------------------------

function snapshot(outage) {
  const b = (id, extra) =>
    Object.assign(
      {
        id,
        entityId: "northwind",
        threadId: THREAD,
        turnId: TURN,
        bindingRevision: 1,
        createdAt: 1787949000000,
        sequence: null,
        slot: "stream",
        visibility: "ceo",
      },
      extra || {}
    );
  const items = [
    Object.assign(b(TURN + ":user", { slot: "opening", createdAt: 1787948000000 }), {
      kind: "user_message",
      text: "Check the Acme numbers again.",
      source: "text",
    }),
    Object.assign(b(TURN + ":text:0", { sequence: 0 }), {
      kind: "rich_message",
      phase: "unknown",
      text: "Pulling the comparables now.",
    }),
    Object.assign(b(TURN + ":duration", { slot: "terminal", createdAt: 1787948000000 }), {
      kind: "work_duration",
      state: "interrupted",
      startedAt: 1787948100000,
      endedAt: 1787948100000 + 461000,
      activeMs: 461000,
    }),
  ];
  if (outage) {
    items.push(Object.assign(b(TURN + ":upstream", { slot: "terminal", createdAt: 1787948561000 }), outage));
  }
  return { entityId: "northwind", threadId: THREAD, mode: "ceo", bindingRevision: 1, items };
}

/// A `529`, exactly as `richos-core` projects it.
function overloadItem(retryMessage) {
  return {
    kind: "upstream_outage",
    fault: "overloaded",
    clearsOnAKnownSchedule: false,
    ceoMessage: OVERLOAD,
    lossMessage: "On disk: what you asked for is saved. " + NOT_ON_DISK,
    retryMessage: retryMessage || undefined,
  };
}

/// A `429`.
function quotaItem() {
  return {
    kind: "upstream_outage",
    fault: "rate_limit",
    clearsOnAKnownSchedule: true,
    ceoMessage: QUOTA,
    lossMessage: "Nothing had been written to disk yet for this turn. " + NOT_ON_DISK,
  };
}

// The renderer fixture: the real `timeline.js`, the real `style.css`, and
// `window.__render(snapshot)` applying a `get_timeline` payload through the SAME
// `applySnapshot` path `main.js` uses on a reload. Nothing about the render is stubbed.


const cardText = (page) =>
  page.evaluate(() => {
    const card = document.querySelector(".tl-intervention");
    if (!card) return null;
    return {
      body: Array.from(card.querySelectorAll(".tl-intervention-body")).map((n) => n.textContent),
      notes: Array.from(card.querySelectorAll(".tl-intervention-note")).map((n) => n.textContent),
      action: card.querySelector(".tl-intervention-action")
        ? card.querySelector(".tl-intervention-action").textContent
        : null,
      actionUsable: (() => {
        const b = card.querySelector(".tl-intervention-action");
        if (!b) return false;
        const cs = getComputedStyle(b);
        return !b.disabled && cs.display !== "none" && cs.visibility !== "hidden";
      })(),
    };
  });

// ---------------------------------------------------------------------------------------
// CONTRAST — computed from the pixels the renderer actually produced, never eyeballed
// ---------------------------------------------------------------------------------------

const CONTRAST_PROBE = `(() => {
  const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  const lum = ([r, g, b]) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  const parse = (s) => (s.match(/[\\d.]+/g) || []).map(Number);
  const opaqueBehind = (el) => {
    let n = el;
    while (n) {
      const c = parse(getComputedStyle(n).backgroundColor);
      if (c.length >= 3 && (c.length < 4 || c[3] === 1)) return [c[0], c[1], c[2]];
      n = n.parentElement;
    }
    return [255, 255, 255];
  };
  const over = (fg, a, bg) => [0, 1, 2].map((i) => fg[i] * a + bg[i] * (1 - a));
  const ratio = (a, b) => {
    const l1 = lum(a), l2 = lum(b);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  };
  const out = [];
  for (const el of document.querySelectorAll(".tl-intervention-body, .tl-intervention-note, .tl-intervention-action")) {
    const cs = getComputedStyle(el);
    const c = parse(cs.color);
    const bg = opaqueBehind(el);
    const fg = c.length === 4 ? over([c[0], c[1], c[2]], c[3], bg) : [c[0], c[1], c[2]];
    out.push({
      cls: el.className,
      px: parseFloat(cs.fontSize),
      bold: parseInt(cs.fontWeight, 10) >= 700,
      ratio: Math.round(ratio(fg, bg) * 100) / 100,
      text: (el.textContent || "").slice(0, 40),
    });
  }
  return out;
})()`;

async function contrastOfCard(page) {
  return page.evaluate(CONTRAST_PROBE);
}

// ---------------------------------------------------------------------------------------

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("row 3.30 — the model API failed, and the card says which kind");

  const page = await openFixture(browser);

  // =====================================================================================
  // The `529`
  // =====================================================================================

  await run.check("a 529 replaces the generic card with the backend's own three sentences", async () => {
    await page.evaluate((s) => window.__render(s), snapshot(overloadItem()));
    await page.waitForSelector(".tl-intervention");
    const c = await cardText(page);
    assert(c, "no failure card rendered at all");
    assertEqual(c.body, [OVERLOAD], "the body is the authored overload sentence, verbatim");
    assert(
      c.notes.some((n) => n.includes("Not on disk:")),
      "the loss note must say what is NOT on disk: " + JSON.stringify(c.notes)
    );
    assert(
      !c.body.concat(c.notes).some((t) => t.includes(GENERIC_BODY)),
      "the generic body must be replaced, not appended to"
    );
    assert(
      !c.notes.some((t) => t.includes(GENERIC_NOTE)),
      'the "Everything I\'d already written above is saved" claim must be gone — it is the ' +
        "half of the old card that is false about the whole"
    );
    return `body=1 note(s)=${c.notes.length}`;
  });

  await run.check("the control is still there, and it is still the one verb", async () => {
    const c = await cardText(page);
    assertEqual(c.action, "Pick it back up", "same label as every other failure");
    assert(c.actionUsable, "the button is present, enabled and visible");
    return "Pick it back up — present, enabled, visible";
  });

  await run.check("the attempts spent render when there are any, and not before", async () => {
    // First failure: `RetryBudget::ceo_message` is None on the item, so there is no line.
    let c = await cardText(page);
    assert(
      !c.notes.some((n) => n.includes("tried")),
      "no attempt line before anything was spent: " + JSON.stringify(c.notes)
    );
    const before = c.notes.length;

    await page.evaluate(
      (s) => window.__render(s),
      snapshot(overloadItem("RichOS tried 2 times and stopped there. Each attempt costs against your Claude usage."))
    );
    c = await cardText(page);
    assert(
      c.notes.some((n) => n.includes("tried 2 times")),
      "the count reaches the screen: " + JSON.stringify(c.notes)
    );
    return `${before} note(s) before, ${c.notes.length} after`;
  });

  // =====================================================================================
  // The `429` — the row's fifth answer, on screen
  // =====================================================================================

  await run.check("a 429 says something DIFFERENT from a 529 on the same card", async () => {
    await page.evaluate((s) => window.__render(s), snapshot(quotaItem()));
    const c = await cardText(page);
    assertEqual(c.body, [QUOTA], "the quota sentence");
    assert(!c.body[0].includes("at capacity"), "and it must not read as an overload");
    assert(c.body[0].includes("schedule"), "it names the schedule, which IS the difference");
    assert(OVERLOAD !== QUOTA, "the two sentences differ at the source");
    return "529 and 429 render two different sentences";
  });

  // =====================================================================================
  // NEGATIVE CONTROL — the ordinary failure card is untouched
  // =====================================================================================

  await run.check("NEGATIVE CONTROL: a failure with NO outage still gets the generic card", async () => {
    await page.evaluate((s) => window.__render(s), snapshot(null));
    const c = await cardText(page);
    assert(c, "the generic failure card must still render");
    assert(c.body[0].includes(GENERIC_BODY), "the generic body: " + JSON.stringify(c.body));
    assert(c.notes.some((n) => n.includes(GENERIC_NOTE)), "the generic note: " + JSON.stringify(c.notes));
    assertEqual(c.action, "Pick it back up");
    return "unchanged for every failure that is not the model API";
  });

  await run.check("NEGATIVE CONTROL: a COMPLETED turn draws no card at all", async () => {
    const ok = snapshot(null);
    ok.items = ok.items.map((i) =>
      i.kind === "work_duration" ? Object.assign({}, i, { state: "completed" }) : i
    );
    await page.evaluate((s) => window.__render(s), ok);
    const n = await page.evaluate(() => document.querySelectorAll(".tl-intervention").length);
    assertEqual(n, 0, "a healthy turn must not grow an intervention card");
    return "0 cards on a completed turn";
  });

  // =====================================================================================
  // CONTRAST — WCAG AA, BOTH THEMES, COMPUTED
  // =====================================================================================

  for (const theme of ["dark", "light"]) {
    await run.check(`CONTRAST ${theme}: every line of the outage card clears WCAG AA`, async () => {
      await page.evaluate((t) => {
        document.documentElement.dataset.theme = t;
      }, theme);
      await page.evaluate((s) => window.__render(s), snapshot(overloadItem("RichOS tried 2 times and stopped there.")));
      await page.waitForSelector(".tl-intervention");
      const rows = await contrastOfCard(page);
      assert(rows.length >= 3, `expected at least 3 measured lines, got ${rows.length}`);
      const fails = [];
      for (const r of rows) {
        // 3:1 only for large text (>=24px, or >=18.66px bold). Nothing on this card is
        // large, so every line here is held to 4.5:1 — the floor is derived from the
        // MEASURED size, never assumed.
        const floor = r.px >= 24 || (r.bold && r.px >= 18.66) ? 3 : 4.5;
        if (r.ratio < floor) fails.push(`${r.cls} ${r.px}px ${r.ratio}:1 < ${floor}:1 — "${r.text}"`);
        // §15's type scale: nothing readable below 14px.
        if (r.px < 14) fails.push(`${r.cls} is ${r.px}px, below the 14px floor`);
      }
      assertEqual(fails, [], `contrast/type failures in ${theme} mode`);
      return rows.map((r) => `${r.px}px ${r.ratio}:1`).join(", ");
    });
  }

  await run.check("no page errors anywhere in this suite", async () => {
    assertEqual(page.__errors, [], "the shell logged errors while rendering an outage");
    return "0 uncaught errors, 0 console errors";
  });

  await page.close();
  await browser.close();
  process.exit(run.report() > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

// **THE TEMPORARY LINE DOES NOT LEAVE ONE WORD ON A LINE OF ITS OWN** — candidate-.2 #9.
//
// `docs/verification/2026-09-17-nightly-1.2.0-20260917.2-onscreen-audit-2.md` §4:
//
//   *"#9 — the temporary line wraps awkwardly. Ran it on screen. '→ 1 new memory' splits
//    across two lines, the second right-aligned. Legible, just untidy."*  (frame 33)
//
// ## WHAT IS ASSERTED IS THE RENDERED FRAME, NOT THE DECLARATION
//
// The fix is one CSS property, `text-wrap: pretty`, and a property is a hint. A check reading
// `getComputedStyle(...).textWrapStyle === "pretty"` would pass on a webview that parsed the
// value and did nothing with it, which is the one outcome worth catching. So every check here
// measures LINE BOXES — `Range.getClientRects()` over the element's own contents, grouped by
// their top edge — and asks how many words ended up on the last one.
//
// ## THE STRINGS ARE THE ENGINE'S, NOT THIS FILE'S
//
// Two sources, and neither is invented:
//
//   * the audit's own sentence, copied out of frame 33, which is the case that was reported;
//   * whatever `__loro.ingest()` actually writes, captured over a run of live lines and then
//     replayed into the same element so each one can be measured without racing its 2,600ms
//     life.
//
// `field-engine.js` composes that sentence from a specialist codename, a source word, a domain
// label and a count, so the population is real and this samples it rather than describing it.
//
// Run: node ticker-wrap.js   (or `npm test` for every suite in this directory)

"use strict";

const path = require("path");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");

/// Frame 33, verbatim — including the `<i>` the engine wraps the domain label in, because the
/// markup is part of what the line breaker is given.
const AUDIT_LINE = "Gantry learned from an email thread · <i>Legal &amp; Risk</i> → 1 new memory";

/// How many live lines to collect. `ingest()` is driven directly rather than waited for, so
/// this is a count of samples and not a stretch of time.
const SAMPLES = 24;

/// Render a sentence into the REAL ticker, with the real stylesheet and the real width clamp,
/// and report its line boxes.
///
/// Shipped into the page as source text and called through `eval`, the same way
/// `lib/contrast.js` ships its arithmetic: `page.evaluate` takes either a function or a string
/// expression, and a string expression cannot be given an argument.
const MEASURE = `(html) => {
  const t = document.getElementById("home-ticker");
  t.innerHTML = html;
  t.classList.add("on");
  t.getBoundingClientRect();
  const r = document.createRange();
  r.selectNodeContents(t);
  const lines = [];
  for (const b of Array.from(r.getClientRects())) {
    if (b.width <= 0.5) continue;
    const hit = lines.find((l) => Math.abs(l.top - b.top) < 3);
    if (hit) { hit.left = Math.min(hit.left, b.left); hit.right = Math.max(hit.right, b.right); }
    else lines.push({ top: b.top, left: b.left, right: b.right });
  }
  lines.sort((a, b) => a.top - b.top);
  const text = t.textContent.replace(/\\s+/g, " ").trim();
  // Which words are on the LAST line: walk the text word by word and keep the ones whose own
  // rect shares the last line's top. Reading the words rather than guessing from widths,
  // because "one word" is the thing the audit complained about and it should be counted.
  const node = t;
  const words = [];
  if (lines.length > 1) {
    const last = lines[lines.length - 1].top;
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = walker.nextNode())) {
      const s = n.nodeValue;
      let i = 0;
      while (i < s.length) {
        while (i < s.length && /\\s/.test(s[i])) i++;
        const start = i;
        while (i < s.length && !/\\s/.test(s[i])) i++;
        if (i === start) break;
        const rr = document.createRange();
        rr.setStart(n, start); rr.setEnd(n, i);
        const bb = rr.getBoundingClientRect();
        if (bb.width > 0.5 && Math.abs(bb.top - last) < 3) words.push(s.slice(start, i));
      }
    }
  }
  return {
    text: text,
    lines: lines.length,
    widths: lines.map((l) => Math.round(l.right - l.left)),
    lastLineWords: words,
    boxWidth: Math.round(t.getBoundingClientRect().width),
  };
}`;

const measure = (page, html) => page.evaluate((a) => eval("(" + a.fn + ")")(a.html), { fn: MEASURE, html });

/// A line is untidy when it wrapped and the last line carries exactly one word. That is the
/// audit's own complaint, stated as something countable rather than as taste.
const orphaned = (m) => m.lines > 1 && m.lastLineWords.length === 1;
const describe = (m) =>
  `${m.lines} line(s) ${m.widths.join("/")}px` + (m.lines > 1 ? `, last line ${JSON.stringify(m.lastLineWords.join(" "))}` : "");

async function openHome(browser, viewport) {
  const page = await browser.newPage({ viewport });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  page.__errors = errors;
  await page.goto(APP);
  await page.waitForFunction("typeof window.RichHome === 'object'", { timeout: 15000 });
  await page.evaluate(() => window.RichSplash && window.RichSplash.yieldNow("ticker-wrap"));
  await page.evaluate(() => window.RichHome.startField());
  await page.waitForFunction("window.RichHome.state.field === 'live'", { timeout: 60000 });
  await page.waitForTimeout(600);
  return page;
}

async function main() {
  const run = createRun("the temporary line: no word left on a line of its own");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  // The walk's own window for this frame.
  const page = await openHome(browser, { width: 1400, height: 880 });

  await run.check("NEGATIVE CONTROL: the audit's own sentence still wraps here", async () => {
    // Without this, every check below would pass on a sentence that happens to fit — which is
    // the empty-corpus failure in its smallest form.
    const m = await measure(page, AUDIT_LINE);
    assertEqual(m.lines, 2, `the reported case no longer wraps at all: ${describe(m)}`);
    assert(m.boxWidth >= 400, `the line's box is ${m.boxWidth}px, so it is not the clamped 460px case`);
    return `${JSON.stringify(m.text)} -> ${describe(m)} in a ${m.boxWidth}px box`;
  });

  await run.check("the audit's own sentence does not orphan its last word", async () => {
    const m = await measure(page, AUDIT_LINE);
    assert(
      !orphaned(m),
      `the last line is one word, ${JSON.stringify(m.lastLineWords.join(" "))} — ${describe(m)}`
    );
    return describe(m);
  });

  await run.check(`${SAMPLES} lines the engine actually wrote, none of them orphaned`, async () => {
    // Driven, captured, then replayed: a line lives 2,600ms and measuring it in flight would
    // read whatever survived the round trip.
    const seen = [];
    for (let k = 0; k < SAMPLES; k++) {
      // `ingest()` launches a spark; `landSpark` writes the line when the spark ARRIVES, so
      // the line is a consequence of the call and not its return value. Wait for the class
      // the engine itself sets, then take the markup it wrote.
      await page.evaluate(() => window.__loro.ingest());
      await page.waitForFunction(
        "document.getElementById('home-ticker').classList.contains('on')",
        { timeout: 20000 }
      );
      const html = await page.evaluate(() => document.getElementById("home-ticker").innerHTML);
      if (html && html.trim() && seen.indexOf(html) < 0) seen.push(html);
      // Let the engine take its own line down, so the next `ingest` is a fresh one rather than
      // a re-read of this one.
      await page.evaluate(() => document.getElementById("home-ticker").classList.remove("on"));
    }
    assert(seen.length >= 5, `the engine wrote only ${seen.length} distinct line(s); this sampled almost nothing`);
    const measured = [];
    for (const html of seen) measured.push(await measure(page, html));
    const bad = measured.filter(orphaned);
    const wrapped = measured.filter((m) => m.lines > 1);
    assertEqual(
      bad.map((m) => `${JSON.stringify(m.text)} -> ${describe(m)}`),
      [],
      "lines the engine wrote that end with one word alone"
    );
    const longest = measured.reduce((a, b) => (b.text.length > a.text.length ? b : a));
    return (
      `${measured.length} distinct line(s), ${wrapped.length} of them wrapped, 0 orphaned\n          ` +
      `longest: ${JSON.stringify(longest.text)} -> ${describe(longest)}`
    );
  });

  await run.check("no page errors", async () => {
    assertEqual(page.__errors, [], "the page reported errors");
    return "0 errors";
  });

  await page.close();
  await browser.close();
  // `report()` returns the FAILED COUNT, not a verdict. Same form as every other suite here.
  process.exit(run.report() > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

// TECHY MODE, criterion by criterion — open-items row 3.1, Phase 2.
//
// Phase 1 (richos `48561e4`) routed every non-text agent frame, unified the per-turn `seq`,
// wrote the day-sharded journal and shipped `rich://machinery`, with 22 passing tests — and
// `grep -rn machinery app/ui/` returned three comments. A correct, tested core with no
// caller. This suite is about the caller, and about the two things the brief said must stay
// true while it was built.
//
// THE COMPLETION CRITERION IS OBSERVABLE, NOT INTERNAL: open a thread with techy mode on and
// see THAT TURN'S REAL MACHINERY — the tool calls and the status each actually returned —
// and toggle it off and on per thread. Checks 4-8 are that sentence, clause by clause.
//
// THE TWO THINGS THAT WERE ALREADY TRUE AND HAD TO STAY TRUE:
//
//   1. A thread from before the routing commit shows the HONEST empty state. "No machinery
//      was recorded for this conversation" and "this conversation had no machinery" are
//      different sentences and only the first is true. Check 12 is that; check 13 is its
//      harder half — a store the OS refuses to open is NOT an empty one, and a renderer
//      that serves the empty sentence over it is lying about the system.
//   3. §1.5's BETWEEN-TURN LANE, added 2026-08-30 (checks 18-21). Everything the session
//      says with NO turn in flight used to hit no sink at all. It now attaches to the
//      THREAD — `turnId: None` is a first-class state, not a bug — and renders in its own
//      section, because a record with no turn has no position in the conversation and
//      drawing one inside the stream would claim a position nothing witnessed. Check 19 is
//      the honest empty state for it, check 21 the standing order on the rendered surface.
//
//   2. No row is drawn for an event that provably never arrives. Readable thinking text
//      fires ZERO times on EITHER wire (0 on claude-agent-acp 0.70.0; 7 signature-only
//      blocks with empty text on the native binary) and client-directed `fs/*` never fires
//      at all — the native CLI was OBSERVED doing its own file IO — so §5's
//      own day-one mockup — which opens with `● thinking ⌄` — cannot be delivered. Check 16
//      asserts the absence, because an always-empty affordance tells the CEO the model is
//      not thinking when the truth is that the adapter does not say.
//
// NOTHING IS ASSERTED AGAINST A HAND-WRITTEN COPY WHERE THE REAL THING CAN BE READ OFF DISK.
// The four state sentences come from `src-tauri/src/machinery_view.rs` and `main.rs` through
// `rustSentenceAfter`; the payload SHAPE comes from `fixtures/machinery-payload.json`, which
// `examples/machinery_payload.rs` writes from the live Rust types against a real ledger and
// a real journal. So the chain renderer -> mock -> live types has no free end.
//
// EVERY CHECK HERE WAS RUN RED ONCE by breaking the shipped source; the mutations are listed
// against their check numbers at the bottom of this file.
//
// Run: node techy.js   (or `npm test` for every suite in this directory)
//      RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node techy.js

"use strict";

const fs = require("fs");
const path = require("path");
const { leaveHome,
  loadPlaywright,
  shot,
  createRun,
  assert,
  assertEqual,
  rustSentenceAfter: rustSentence,
  UI_DIR,
} = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");
const SRC = path.resolve(UI_DIR, "..", "src-tauri", "src");
const MACHINERY_RS = fs.readFileSync(path.join(SRC, "machinery_view.rs"), "utf8");
const MAIN_RS = fs.readFileSync(path.join(SRC, "main.rs"), "utf8");
const SHOTS = path.join(__dirname, "shots-3-1");
const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "machinery-payload.json"), "utf8"));

/// The five CEO-facing sentences, read out of the Rust that ships them. A reworded const
/// reaches this file as a failing check rather than as a stale expectation.
///
/// EVERY MARKER IS A PHRASE THAT APPEARS ONLY IN THE CONST BODY, never in the doc comment
/// above it. `rustSentenceAfter` scans BACKWARD from the marker to the nearest opening
/// quote, and the doc comments here quote their own sentences to explain them — so a marker
/// taken from the opening clause finds the DOC COMMENT's quote and returns a fragment. That
/// is not hypothetical; it is what the first version of this file did, and the fragment it
/// returned was a prefix of the real sentence, so `assertEqual` was the only thing between
/// a green run and four checks silently asserting a substring.
const NOTHING_RECORDED = rustSentence(MACHINERY_RS, "Retention started on 2026-08-28");
const NOT_RETAINED = rustSentence(MACHINERY_RS, "it fills up as Rich works");
const UNREADABLE = rustSentence(MACHINERY_RS, "something is refusing to open it");
const RAW_NOT_RETAINED = rustSentence(MAIN_RS, "what's above is the whole record that was");
const RAW_TRUNCATED = rustSentence(MAIN_RS, "you're seeing the start of it");
const BETWEEN_TURNS_QUIET = rustSentence(MACHINERY_RS, "not proof the");

// ---------------------------------------------------------------------------------------
// Driving the REAL shell — nothing stubbed that mock.js does not already own
// ---------------------------------------------------------------------------------------

async function openApp(browser, viewport) {
  const page = await browser.newPage({ viewport: viewport || { width: 1400, height: 950 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.goto(APP);
  // The home screen is the landing surface now; this suite is about the app UI behind it.
  await leaveHome(page);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

async function openThread(page, threadId) {
  await page.click('.nav-thread[data-thread-id="' + threadId + '"]');
  await page.waitForFunction(
    (id) => document.querySelector("#techy-chip") && window.__lastThread !== undefined ? true : true,
    threadId
  );
  // The load is two awaited invokes deep; settle on the conversation being drawn for it.
  await page.waitForTimeout(250);
}

/// The CEO's own path: the keyboard shortcut, which pins THIS conversation (§3.3).
async function pressToggle(page) {
  await page.keyboard.press("Meta+Shift+T");
  await page.waitForTimeout(250);
}

/// The state line's SENTENCE, without the operator-facing reason appended after it.
const sentenceOf = (page) =>
  page.evaluate(() => {
    const el = document.getElementById("techy-state");
    if (!el || el.hidden) return null;
    return el.childNodes[0] ? el.childNodes[0].textContent : "";
  });

const techRows = (page) =>
  page.$$eval(".tl-tech", (rows) =>
    rows.map((r) => ({
      title: r.querySelector(".tl-tech-title").textContent,
      state: r.dataset.state,
      word: r.querySelector(".tl-activity-state") ? r.querySelector(".tl-activity-state").textContent : null,
      vendor: r.dataset.vendor || null,
      paths: Array.from(r.querySelectorAll(".tl-tech-path")).map((p) => p.textContent),
    }))
  );

async function main() {
  const pw = loadPlaywright();
  const run = createRun("techy mode — the renderer, the per-thread toggle and techy_default (row 3.1)");
  const browser = await pw.webkit.launch();
  fs.mkdirSync(SHOTS, { recursive: true });

  // ---- 1. the calm default, untouched -------------------------------------------------
  //
  // §3.3's constraint is the one that makes Urban's v1 direction need no amendment: with
  // techy mode off, the conversation surface is byte-identical to today. NOT "tidy" — no
  // affordance AT ALL, because a visible affordance IS a change to the default experience.
  let calmHTML = null;
  await run.check("1. off: no technical row, no chip, no state line, no hint", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    calmHTML = await page.innerHTML("#messages");
    assertEqual(await page.locator(".tl-tech").count(), 0, "a technical row cannot exist in the calm view");
    assert(await page.locator("#techy-chip").isHidden(), "no chip");
    assert(await page.locator("#techy-state").isHidden(), "no state line");
    // `innerText`, not `textContent`: the chip is IN the document and `hidden`, and the
    // claim being made is about what the CEO can SEE. `textContent` reads hidden nodes and
    // would fail this check over the very element that is correctly invisible.
    const text = await page.evaluate(() => document.getElementById("stage").innerText);
    for (const hint of ["technical detail", "Technical view", "Show technical", "machinery"]) {
      assert(!text.includes(hint), "the conversation must not hint at techy mode: found " + hint);
    }
    await shot(page, "../shots-3-1/3-1-01-off-nothing-changed");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return "the calm surface carries no affordance at all";
  });

  // ---- 2. the sentences on screen are the ones Rust ships ------------------------------
  await run.check("2. the state sentences are the Rust constants, verbatim", async () => {
    // Read off disk on both sides. A copy in mock.js that drifted from `machinery_view.rs`
    // would let every other check below pass over a sentence the product no longer says.
    const page = await openApp(browser);
    const mockCopies = await page.evaluate(() => ({
      nothing: window.__RICHOS_MOCK__.TECHY_NOTHING_RECORDED,
      notRetained: window.__RICHOS_MOCK__.TECHY_NOT_RETAINED,
      unreadable: window.__RICHOS_MOCK__.TECHY_UNREADABLE,
      rawNotRetained: window.__RICHOS_MOCK__.TECHY_RAW_NOT_RETAINED,
      rawTruncated: window.__RICHOS_MOCK__.TECHY_RAW_TRUNCATED,
      betweenQuiet: window.__RICHOS_MOCK__.TECHY_BETWEEN_TURNS_QUIET,
    }));
    assertEqual(mockCopies.nothing, NOTHING_RECORDED, "the empty-state sentence");
    assertEqual(mockCopies.notRetained, NOT_RETAINED, "the never-retained sentence");
    assertEqual(mockCopies.unreadable, UNREADABLE, "the unreadable sentence");
    assertEqual(mockCopies.rawNotRetained, RAW_NOT_RETAINED, "the evicted-raw sentence");
    assertEqual(mockCopies.rawTruncated, RAW_TRUNCATED, "the truncated-raw sentence");
    assertEqual(mockCopies.betweenQuiet, BETWEEN_TURNS_QUIET, "the quiet-between-turns sentence");
    // And the three that answer "why is there nothing" are three DIFFERENT sentences.
    const distinct = new Set([NOTHING_RECORDED, NOT_RETAINED, UNREADABLE]);
    assertEqual(distinct.size, 3, "three states, three sentences — never one sentence for three facts");
    await page.close();
    return "6 sentences joined to their Rust consts";
  });

  // ---- 3. §7.2 is not answered in copy -------------------------------------------------
  //
  // "How long do raw payloads survive?" is the CEO's, and open. A sentence naming a
  // duration would answer it in copy, and then the answer would live in two places.
  await run.check("3. no sentence names a retention duration (§7.2 stays his)", async () => {
    for (const [name, sentence] of [
      ["NOTHING_RECORDED", NOTHING_RECORDED],
      ["NOT_RETAINED", NOT_RETAINED],
      ["UNREADABLE", UNREADABLE],
      ["RAW_NOT_RETAINED", RAW_NOT_RETAINED],
      ["RAW_TRUNCATED", RAW_TRUNCATED],
      ["BETWEEN_TURNS_QUIET", BETWEEN_TURNS_QUIET],
    ]) {
      assert(!/\b14 days?\b|\b2 ?GB\b|\bfortnight\b|\btwo weeks\b/i.test(sentence), name + " names a window");
    }
    // The retroactivity DATE is different and is deliberately allowed: it is a fact about
    // what was recorded, not a policy about what will be kept.
    assert(NOTHING_RECORDED.includes("2026-08-28"), "the routing date IS stated — that is a fact, not a policy");
    assert(BETWEEN_TURNS_QUIET.includes("2026-08-30"), "and so is the lane's own start date, for the same reason");
    return "no window in any sentence; the routing date is named";
  });

  // ---- 4. THE CRITERION: the turn's real machinery ------------------------------------
  await run.check("4. on: the tool calls that actually ran, one row each", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page);
    const rows = await techRows(page);
    assert(rows.length >= 6, "expected the turn's tool calls, got " + rows.length);
    // The MERGED title — the real command — never the opening event's placeholder. The wire
    // sends `title: "Terminal"` on the open and the command on a later update (probe run1
    // n=11 vs n=12), so a renderer reading only the open event shows a column of "Terminal".
    assert(!rows.some((r) => r.title === "Terminal" || r.title === "Preparing file…"),
      "a placeholder title reached the screen: " + JSON.stringify(rows.map((r) => r.title)));
    assert(rows.some((r) => r.title.startsWith("python3 scripts/counter-model.py --list")),
      "the full command, not an ellipsis: " + JSON.stringify(rows.map((r) => r.title)));
    assert(rows.some((r) => r.paths.length), "a touched path is on screen");
    await shot(page, "../shots-3-1/3-1-02-the-turns-real-machinery");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return rows.length + " rows: " + rows.map((r) => r.state).join(", ");
  });

  // ---- 5. ...and the status each actually returned -------------------------------------
  await run.check("5. every outcome is drawn as its own word, and `unknown` is never `done`", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page);
    const rows = await techRows(page);
    const byState = {};
    for (const r of rows) byState[r.state] = r.word;
    // §18: status never by color alone. In technical mode EVERY state is spelled out —
    // `done` included, because it is what he is looking at.
    assertEqual(byState.completed, "done", "a completed call says done");
    assertEqual(byState.failed, "failed", "a failed call says failed");
    assertEqual(byState.unknown, "outcome not recorded",
      "34 of 58 measured tool events carried no status — that is not a completion claim");
    assert(byState.unknown !== "done", "an unrecorded outcome must NEVER read as done");
    await page.close();
    return JSON.stringify(byState);
  });

  // ---- 6. no rollup in technical mode --------------------------------------------------
  await run.check("6. three reads stay three commands, not `Read 3 files`", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    // The CALM view rolls them up, correctly: "Read a file" three times says one thing. The
    // turn is settled, so its work transcript is collapsed (§6.4) — open it the way the CEO
    // does, through the summary line, rather than reaching into the model.
    await page.click(".tl-collapsed-summary");
    await page.waitForTimeout(200);
    const calmLabels = await page.$$eval(".tl-activity-text", (n) => n.map((x) => x.textContent));
    assert(calmLabels.includes("Read 3 files"), "the calm view DOES roll up: " + JSON.stringify(calmLabels));
    await pressToggle(page);
    const rows = await techRows(page);
    const reads = rows.filter((r) => r.title.startsWith("Read "));
    assertEqual(reads.length, 3, "three distinct reads, three rows");
    assertEqual(new Set(reads.map((r) => r.title)).size, 3, "and three distinct commands");
    assert(!rows.some((r) => /^Read \d+ files$/.test(r.title)), "no rollup label in technical mode");
    await page.close();
    return "calm labels " + JSON.stringify(calmLabels) + " -> " + reads.length + " technical rows";
  });

  // ---- 7. the rows that exist ONLY here ------------------------------------------------
  await run.check("7. the untyped vendor kind and the auto-approved permission are here, and only here", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    const calm = await page.textContent("#messages");
    assert(!calm.includes("message_delta"), "an accounting frame is not something Rich DID");
    assert(!calm.includes("auto-approved"), "and nobody was asked to approve anything");
    await pressToggle(page);
    const rows = await techRows(page);
    const vendor = rows.find((r) => r.vendor === "stream_event:message_delta");
    assert(vendor, "§1.4 G5: an untyped kind is retained and rendered as one dim line, with its kind name");
    assert((await page.textContent("#messages")).includes("auto-approved"),
      "a permission request is recorded as a FACT and shown here — never as a decision awaiting him");
    await page.close();
    return "vendorKind row present; both absent from the calm view";
  });

  // ---- 8. per thread, and reversible ---------------------------------------------------
  await run.check("8. the shortcut pins ONE conversation and leaves the others alone", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page);
    assert(await page.locator("#techy-chip").isVisible(), "acme is on");
    assertEqual(await page.textContent("#techy-chip-label"), "Technical view · this conversation",
      "and the chip says WHICH switch is holding it, so turning it off is predictable");
    await openThread(page, "hiring");
    assert(await page.locator("#techy-chip").isHidden(), "hiring is untouched");
    assertEqual(await page.locator(".tl-tech").count(), 0, "and shows no technical row");
    await openThread(page, "acme");
    assert(await page.locator("#techy-chip").isVisible(), "acme kept its pin across the switch away and back");
    const state = await page.evaluate(() => window.__RICHOS_MOCK__.techyState());
    assertEqual(state, { default: false, threads: { acme: true } }, "one thread pinned, the global default untouched");
    await page.close();
    return "per-thread override, and the global default never moved";
  });

  // ---- 9. the global switch (§3.1: "all" must be ONE switch) ----------------------------
  await run.check("9. Settings switches every conversation, and pins survive it", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page); // pin acme ON
    await pressToggle(page); // ...then pin it OFF, deliberately against the default below
    await page.click("#rail-settings");
    await page.waitForSelector("#assertiveness-popover:not([hidden])");
    await page.check("#techy-default");
    await page.waitForTimeout(250);
    await shot(page, "../shots-3-1/3-1-03-one-switch-for-all-of-them");
    const state = await page.evaluate(() => window.__RICHOS_MOCK__.techyState());
    assertEqual(state, { default: true, threads: { acme: false } }, "global on, acme's own answer kept");
    assert(await page.locator("#techy-chip").isHidden(), "acme is pinned off and stays off");
    await openThread(page, "hiring");
    assert(await page.locator("#techy-chip").isVisible(), "an unpinned thread follows the global switch");
    assertEqual(await page.textContent("#techy-chip-label"), "Technical view · everywhere",
      "and says so, rather than implying he chose it here");
    await page.close();
    return "global default reaches the unpinned; the pin holds against it";
  });

  // ---- 10. §7.1 stays reversible -------------------------------------------------------
  //
  // Without a way back to the default a pin is one-way, "all of their conversations" stops
  // reaching any thread he ever touched, and the product has answered the CEO's open
  // question for him. The clearing arm is `set_techy_mode(enabled: null)`.
  await run.check("10. a pinned conversation can be handed back to the default (§7.1 stays open)", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page);
    let mode = await page.evaluate(() => window.RichBridge.invoke("techy_mode", { threadId: "acme" }));
    assertEqual(mode, { enabled: true, source: "thread", default: false }, "pinned");
    mode = await page.evaluate(() => window.RichBridge.invoke("set_techy_mode", { threadId: "acme", enabled: null }));
    assertEqual(mode, { enabled: false, source: "default", default: false }, "handed back, not stuck at its old value");
    await page.evaluate(() => window.RichBridge.invoke("set_techy_default", { enabled: true }));
    mode = await page.evaluate(() => window.RichBridge.invoke("techy_mode", { threadId: "acme" }));
    assertEqual(mode, { enabled: true, source: "default", default: true }, "and now follows the global switch");
    await page.close();
    return "pin -> clear -> follows the default, in both directions";
  });

  // ---- 11. the §3.3 invariant, measured ------------------------------------------------
  await run.check("11. on and back off leaves the conversation BYTE-IDENTICAL", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    const before = await page.innerHTML("#messages");
    await pressToggle(page);
    await page.click("#mach\\:mach_a1"); // open a raw pane, so the round trip is not trivial
    await page.waitForTimeout(200);
    await pressToggle(page);
    const after = await page.innerHTML("#messages");
    assertEqual(after.length, before.length, "same length");
    assert(after === before, "the calm view must be byte-identical after a round trip");
    assert(await page.locator("#techy-state").isHidden(), "and the state line is gone with it");
    assert(await page.locator("#techy-chip").isHidden(), "and so is the chip");
    await shot(page, "../shots-3-1/3-1-04-off-again-and-identical");
    await page.close();
    return before.length + " bytes of DOM, unchanged";
  });

  // ---- 12. THE HONEST EMPTY STATE ------------------------------------------------------
  await run.check("12. a conversation from before the routing commit says what was RECORDED", async () => {
    const page = await openApp(browser);
    await openThread(page, "partner");
    await pressToggle(page);
    assertEqual(await sentenceOf(page), NOTHING_RECORDED, "verbatim from machinery_view.rs");
    assertEqual(await page.getAttribute("#techy-state", "data-state"), "nothing_recorded", "and it is that state");
    assertEqual(await page.locator(".tl-tech").count(), 0, "there is genuinely nothing to draw");
    // The conversation itself is still there. An empty machinery column is not an empty
    // thread, and the CEO did not lose his conversation by turning a view on.
    assert((await page.textContent("#messages")).includes("carry split"), "his conversation still renders");
    await shot(page, "../shots-3-1/3-1-05-nothing-was-recorded-for-this-one");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return "nothing_recorded, with the conversation intact";
  });

  // ---- 13. ...and the state that is NOT that one ---------------------------------------
  await run.check("13. a store that cannot be read is NOT reported as an empty one", async () => {
    const page = await openApp(browser);
    await page.evaluate(() => window.__RICHOS_MOCK__.breakMachinery("acme"));
    await openThread(page, "acme");
    await pressToggle(page);
    const said = await sentenceOf(page);
    assertEqual(said, UNREADABLE, "verbatim from machinery_view.rs");
    assert(said !== NOTHING_RECORDED, "and it is NOT the empty-state sentence");
    assertEqual(await page.getAttribute("#techy-state", "data-state"), "unreadable", "a different state, drawn differently");
    // The operator-facing reason is on screen too — the CEO is told plainly it is not his
    // to fix, and whoever set RichOS up gets the path.
    const reason = await page.textContent("#techy-state .techy-reason");
    assert(reason.includes("acme"), "the reason names the path: " + reason);
    assert(said.includes("haven't lost it"), "and it does not imply the record is gone");
    // And NO rows: `Spine::timeline` reads the journal through `read_thread`, which returns
    // nothing for a directory the OS refused, so the technical view of an unreadable thread
    // is prose and a duration row. The sentence is the only thing standing between the CEO
    // and "he did nothing" — which is why it must not be the empty-state one.
    assertEqual(await page.locator(".tl-tech").count(), 0, "the journal gave nothing back");
    assert((await page.textContent("#messages")).includes("comparables"), "his conversation still renders");
    await shot(page, "../shots-3-1/3-1-06-i-cannot-read-it-which-is-not-empty");
    await page.close();
    return "unreadable, with the operator's reason: " + reason;
  });

  // ---- 14. the raw pane's three answers -------------------------------------------------
  await run.check("14. expanding a row shows the output, or says honestly why it cannot", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page);

    await page.click("#mach\\:mach_a1");
    await page.waitForSelector("#raw\\:mach_a1");
    await page.waitForTimeout(200);
    const retained = await page.textContent("#raw\\:mach_a1");
    assert(retained.includes("q3-acme.csv"), "the raw payload is on screen: " + retained.slice(0, 80));
    assertEqual(await page.getAttribute("#raw\\:mach_a1", "data-note"), null, "no note over real bytes");

    // §2.4's honest degrade: the Tier-B window has passed over this one. The NORMALIZED
    // record above it is untouched — structure, title, status, paths, summary — and the
    // pane says why the bytes are gone rather than showing a blank.
    await page.click("#mach\\:mach_a5");
    await page.waitForTimeout(200);
    assertEqual(await page.textContent("#raw\\:mach_a5"), RAW_NOT_RETAINED, "verbatim from main.rs");
    assertEqual(await page.getAttribute("#raw\\:mach_a5", "data-note"), "not_retained", "and it is that state");
    const stillThere = (await techRows(page)).find((r) => r.title.startsWith("grep -rn"));
    assert(stillThere && stillThere.word === "done", "the record still renders with its outcome");

    // §2.4's 32 KB cap fired: what is on screen is a PREFIX, and it is labelled. A prefix
    // that looks whole is worse than one that says it is not.
    await page.click("#mach\\:mach_a6");
    await page.waitForTimeout(200);
    assertEqual(await page.textContent("#raw\\:mach_a6 .tl-tech-note"), RAW_TRUNCATED, "verbatim from main.rs");
    await shot(page, "../shots-3-1/3-1-07-the-output-and-the-two-honest-degrades");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return "retained / not retained / truncated — three answers, three sentences";
  });

  // ---- 15. a window, not a cockpit ------------------------------------------------------
  await run.check("15. techy mode adds no control of any kind", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page);
    // The ONLY button inside a technical row is its own disclosure head. R2 business-action
    // governance is deferred to V2 by CEO decision for v1 and all 1.x, and an approve, a
    // re-run or an interrupt here is how that gets un-deferred by accident (§5, §9).
    const buttons = await page.$$eval(".tl-tech button", (b) => b.map((x) => x.className));
    assert(buttons.every((c) => c === "tl-tech-head"), "unexpected control in a technical row: " + JSON.stringify(buttons));
    const text = await page.textContent("#messages");
    for (const verb of ["Approve", "Deny", "Re-run", "Rerun", "Interrupt", "Kill"]) {
      assert(!text.includes(verb), "a control verb reached the technical view: " + verb);
    }
    await page.close();
    return buttons.length + " buttons, all of them the row's own disclosure";
  });

  // ---- 16. the two rows that are NOT drawn, and why -------------------------------------
  await run.check("16. no row exists for an event that provably never arrives", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page);
    const text = await page.textContent("#messages");
    // §5's own day-one mockup opens with `● thinking ⌄`. Readable thinking text fires ZERO
    // times on either wire — 0 `agent_thought_chunk` on claude-agent-acp 0.70.0, and 7
    // `thinking` blocks with EMPTY text on the native binary — including in probe runs built
    // for nothing else.
    assert(!/thinking/i.test(text), "a thinking row would tell him the model is not thinking, which is not what is true");
    // And `fs/read_text_file` / `fs/write_text_file` never fire with both capabilities
    // declared and both tools exercised — `ClientFsCall` is real and inert on 0.70.0.
    assert(!text.includes("fs/read_text_file") && !text.includes("fs/write_text_file"),
      "an inert route must not get a permanently empty affordance");
    const rows = await techRows(page);
    assert(!rows.some((r) => r.vendor === "agent_thought_chunk"), "and no thought row by vendor kind either");
    await page.close();
    return "no thinking row, no fs row — both routes stay built in richos-core";
  });

  // ---- 17. the mock is joined to the live Rust payload ----------------------------------
  await run.check("17. the mock's shape is the shape the real command emits", async () => {
    // `fixtures/machinery-payload.json` is written by `examples/machinery_payload.rs` from
    // the live types, a real ledger and a real journal. Without this join every check above
    // proves the renderer against a mock and nothing about the backend.
    const page = await openApp(browser);
    const got = await page.evaluate(() => window.RichBridge.invoke("get_machinery", { threadId: "acme" }));
    const real = FIXTURE.recorded;
    assertEqual(Object.keys(got).sort(), Object.keys(real).sort(), "the envelope's keys");
    assertEqual(got.state, real.state, "both are `recorded`");
    assertEqual(got.timeline.mode, real.timeline.mode, "both are the technical view");
    const realAct = real.timeline.items.find((i) => i.kind === "activity" && i.detail);
    const mockAct = got.timeline.items.find((i) => i.kind === "activity" && i.detail);
    assert(realAct && mockAct, "both carry an activity with a technical half");
    for (const key of ["kind", "state", "activityType", "detailRef", "summary", "visibility"]) {
      assert(key in mockAct, "the mock activity is missing " + key);
      assert(key in realAct, "the real activity is missing " + key);
    }
    for (const key of ["title", "locations"]) {
      assert(key in mockAct.detail && key in realAct.detail, "detail." + key + " on both sides");
    }
    // And the empty state's envelope agrees too — that is the one the renderer branches on.
    assertEqual(FIXTURE.nothingRecorded.state, "nothing_recorded", "the fixture carries the empty state");
    assertEqual(FIXTURE.nothingRecorded.sentence, NOTHING_RECORDED, "with the same sentence the UI shows");
    await page.close();
    return "envelope and item shapes agree with the live payload";
  });

  // ---- 18. §1.5's between-turn lane: the update that used to have nowhere to go ---------
  //
  // THE COMPLETION CRITERION, on the rendered surface. The client delivered a frame only
  // while `current_prompt` was `Some`; anything the adapter said at session start or after
  // a turn's answer had already been returned hit no sink at all. It now attaches to the
  // thread and shows here.
  await run.check("18. what the session said between turns is on screen, in its own section", async () => {
    const page = await openApp(browser);
    await openThread(page, "acme");

    // OFF: not a trace of it. §3.3's rule is about the whole conversation surface, and a
    // heading the CEO can read is an affordance whatever its rows say.
    assert(await page.locator("#between-turns").isHidden(), "the section does not exist for a calm view");
    const calm = await page.evaluate(() => document.getElementById("stage").innerText);
    assert(!calm.includes("Between turns"), "and its heading is not readable either");

    await pressToggle(page);
    assert(await page.locator("#between-turns").isVisible(), "the section is here in technical mode");
    const rows = await page.$$eval("#between-turns-rows .bt-row", (r) =>
      r.map((x) => ({ kind: x.dataset.vendor, title: x.querySelector(".tl-tech-title").textContent }))
    );
    assertEqual(rows.map((r) => r.kind), ["system:init", "system:status"],
      "the two frames measured between turns on 2026-08-31, in journal order");
    // The vendor frame name IS the row (§1.4 G5's "one dim line"), because there is no
    // CEO-safe semantic line for "the agent restated its tool list" and inventing one would
    // be worse than the frame name.
    assertEqual(rows.map((r) => r.title), ["system:init", "system:status"], "frame name as label");
    assert(await page.locator("#between-turns-quiet").isHidden(), "no empty-state sentence over a full lane");
    await shot(page, "../shots-3-1/3-1-08-between-turns-has-somewhere-to-go");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return rows.length + " between-turn rows, present only in technical mode";
  });

  // ---- 19. the honest empty state for the lane -----------------------------------------
  await run.check("19. a quiet lane SAYS it is quiet, and says why", async () => {
    // An empty box under a heading reads as a broken feature. The sentence distinguishes
    // the two things an empty lane can mean — nothing arrived, or nothing was ever written
    // because the conversation predates the lane — exactly as `NOTHING_RECORDED` does for
    // the thread as a whole.
    const page = await openApp(browser);
    await page.evaluate(() => window.__RICHOS_MOCK__.clearBetweenTurns("acme"));
    await openThread(page, "acme");
    await pressToggle(page);
    assert(await page.locator("#between-turns").isVisible(), "the section still appears — silence is a state, not an absence");
    assertEqual(await page.$$eval("#between-turns-rows .bt-row", (r) => r.length), 0, "no rows");
    assertEqual(await page.textContent("#between-turns-quiet"), BETWEEN_TURNS_QUIET, "verbatim from machinery_view.rs");
    // And the conversation above it is untouched: an empty lane is not an empty thread.
    assert((await page.locator(".tl-tech").count()) > 0, "the turn's own machinery still renders");
    await shot(page, "../shots-3-1/3-1-09-a-quiet-lane-says-so");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return "the quiet sentence, with the conversation intact above it";
  });

  // ---- 20. an unreadable store does not get a SECOND claim ------------------------------
  await run.check("20. over an unreadable store the lane says nothing at all", async () => {
    // "Nothing was recorded between turns" is a claim a store that refused to open never
    // supported. `machinery_view.rs` returns `null` in that state and the state line above
    // already speaks for the whole view — this is check 13's rule, one level down.
    const page = await openApp(browser);
    await page.evaluate(() => window.__RICHOS_MOCK__.breakMachinery("acme"));
    await openThread(page, "acme");
    await pressToggle(page);
    assertEqual(await sentenceOf(page), UNREADABLE, "the state line owns this screen");
    assert(await page.locator("#between-turns").isHidden(), "and the lane makes no second claim");
    assertEqual(await page.textContent("#between-turns-quiet"), "", "not even hidden text to leak later");
    await page.close();
    return "one honest sentence, not two contradictory ones";
  });

  // ---- 21. the standing order, on the rendered surface -----------------------------------
  await run.check("21. no between-turn row names a turn, a session, or a rotation", async () => {
    // Re-prime and rotation machinery is `internal: true` and refused at the timeline's
    // guard, which `richos-core` proves. What THIS checks is the surface: the lane's rows
    // arrive at session boundaries, so it is the one place a session identifier would
    // become a rotation tell — and `BetweenTurnItem` carries none.
    const page = await openApp(browser);
    await openThread(page, "acme");
    await pressToggle(page);
    const payload = await page.evaluate(() => window.RichBridge.invoke("get_machinery", { threadId: "acme" }));
    const lane = payload.timeline.betweenTurns;
    assert(lane.length > 0, "there is a lane to inspect");
    for (const row of lane) {
      assert(!("turnId" in row), "a lane row must carry no turn: " + JSON.stringify(row));
      assert(!("sessionId" in row), "and no session id: " + JSON.stringify(row));
      assertEqual(row.visibility, "technical", "every row is technical, so a CEO view is empty by construction");
    }
    const section = await page.textContent("#between-turns");
    for (const word of ["rotat", "re-prime", "reprime", "successor", "lease", "session id"]) {
      assert(!section.toLowerCase().includes(word), "the lane referenced " + word);
    }
    // The live fixture agrees — this is not a property of the mock.
    for (const row of FIXTURE.recorded.timeline.betweenTurns) {
      assert(!("turnId" in row) && !("sessionId" in row), "the LIVE payload leaks one: " + JSON.stringify(row));
    }
    await page.close();
    return lane.length + " rows, none of them naming a turn or a session";
  });

  await browser.close();
  const failed = run.report();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

// =========================================================================================
// THE MUTATIONS — every check above was run RED once, by breaking the SHIPPED source
// =========================================================================================
//
//  1  main.js `renderTechyChip`: drop the `techyChipEl.hidden = !on` line  -> the chip is
//     visible in the calm view; check 1 fails on "no chip".
//  2  mock.js: change one word of `TECHY_UNREADABLE` -> check 2 fails against the Rust const.
//  3  machinery_view.rs: append " (kept for 14 days)" to NOTHING_RECORDED -> check 3 fails.
//  4  timeline.js `technicalLabel`: return `item.summary` first -> every row reads "Ran a
//     command"; check 4 fails on the missing full command.
//  5  timeline.js `ACTIVITY_STATE_LABEL.unknown = "done"` -> check 5 fails on the fold.
//  6  timeline.js `rollupActivity`: drop the `!item.detail` clause -> the three reads roll
//     up into one row; check 6 fails on `reads.length === 1`.
//  7  timeline.js `visible()`: return `item.visibility === "ceo"` -> the vendor and
//     permission rows vanish; check 7 fails. (This was a REAL defect, found by running it.)
//  8  main.js `toggleTechyThread`: pass `enabled: null` instead of `enabled: next` -> the
//     shortcut clears an override instead of setting one, so nothing ever turns on;
//     11 checks go red including 8.
//  9  mock.js `techyModeOf`: ignore `techyThreads` -> the pin does not survive the global
//     switch; check 9 fails.
// 10  mock.js `set_techy_mode`: `techyThreads.set(id, false)` on the null arm -> the clear
//     becomes a pin-to-false; check 10 fails on `source: "thread"`.
// 11  timeline.js `applySnapshot`: `model.technical = snapshot.mode === "technical" ||
//     model.technical` -> the flag survives the toggle back off, so the calm view keeps its
//     technical rows and its expanded transcript; check 11 fails on the byte comparison,
//     and ONLY check 11 — which is what makes it the right mutation for this claim.
//     (The first attempt at this one — dropping `renderTechyState(null)` — did NOT go red,
//     because the thread under test HAS machinery and its state line is already hidden. It
//     is recorded here rather than quietly replaced.)
// 12  machinery_view.rs: return NOT_RETAINED for `NothingRecorded` -> check 12 fails on the
//     sentence, and the two states stop being distinguishable.
// 13  mock.js `machineryStateOf`: return the `nothing_recorded` shape for an unreadable
//     thread -> check 13 fails on both the sentence and the state. THIS IS THE ONE THE
//     BRIEF NAMED, and it was ALSO run against the Rust half: `journal.rs`'s
//     `read_thread_checked` mapping every read_dir error to `NothingRecorded` turns
//     `a_directory_the_os_refuses_is_unreadable_and_is_never_reported_as_empty` red and
//     takes two assertions of `examples/machinery_payload.rs` with it.
// 14  mock.js: give `mach_a5` a raw payload -> the evicted state never renders; check 14
//     fails on the sentence.
// 15  timeline.js `renderTechnicalRow`: append a `<button class="tl-tech-rerun">Re-run` ->
//     check 15 fails on both the class and the verb.
// 16  mock.js: add an activity with `detail.vendorKind = "agent_thought_chunk"` and the
//     title "thinking" -> check 16 fails twice.
// 17  mock.js `get_machinery`: drop the `rowCount` key -> check 17 fails on the envelope.
// 18  main.js `renderBetweenTurns`: end with `betweenTurnsEl.hidden = true` -> the section
//     never appears; checks 18 AND 19 fail.
// 19  main.js `renderBetweenTurns`: delete the `if (!rows.length && sentence)` branch -> an
//     empty lane draws an empty box under a heading; check 19 fails and ONLY check 19.
// 20  machinery_view.rs + mock.js: drop the `Unreadable => None` arm, so an unreadable store
//     also gets "nothing was recorded between turns" -> check 20 fails.
//     THE FIRST ATTEMPT AT THIS ONE DID NOT GO RED, and the reason was a real mock defect,
//     not a weak check: the mock computed the sentence from the raw lane fixture instead of
//     from the PROJECTION, so an unreadable thread still counted rows the renderer would
//     never receive. `machinery_view.rs` asks `view.between_turns()` — the gated lane — and
//     the mock now asks the same projection it returns. Recorded rather than quietly fixed.
// 21  timeline.rs `BetweenTurnItem`: add a `session_id` field and fill it from the record ->
//     `between_turn_thread_tests::a_lane_row_carries_no_session_id...` fails, and so does
//     `examples/machinery_payload.rs` (which exits 1). The mock-side half — adding
//     `sessionId` in `betweenTurnsFor` -> check 21 fails here too.
//
// The whole sweep, with the run output and the two Rust-side mutations, is recorded at
// `docs/verification/techy-mode-2026-08-30/mutation-runs.txt`.

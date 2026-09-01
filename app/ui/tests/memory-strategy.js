// §26 — THE DETERMINISTIC `memory-strategy` FIXTURE, DRIVEN END TO END THROUGH THE REAL SHELL.
//
// This is the acceptance instrument for Phase 3's exit gate ("the representative
// memory-strategy fixture renders correctly from start to finish"), so it runs against the
// thing that ships: `index.html` + `main.js` + `mock.js` + `timeline.js` + `style.css`, all
// loaded from disk under WebKit, with nothing stubbed but the Tauri bridge that `mock.js`
// already replaces. The turn is STARTED BY TYPING THE PROMPT AND PRESSING ENTER — not by a
// side door into the renderer — so the CEO bubble is the shell's own optimistic bubble,
// re-keyed by `adoptPendingUserMessage` when `rich://turn-status: queued` names the turn.
//
// ---------------------------------------------------------------------------------------
// THE NEGATIVE HALF, WHICH IS THE POINT
// ---------------------------------------------------------------------------------------
//
// §26 prescribes sixteen steps. Two of them — "Sage failure" and "Plan update from step 2
// of 5 to step 3 of 5" — have no signal anywhere in this runtime, and eight more are only
// partly producible. Emitting them anyway would light up renderer branches production can
// never reach, and a green run over those branches would certify states that cannot occur.
//
// So `mock.js` emits none of them, and this suite ASSERTS THEIR ABSENCE. `MEMORY_STRATEGY_STEPS`
// carries a row per step with `status`, what is produced, what is not, and the file:line
// that makes it so; the checks below walk that table and require the DOM to agree with it in
// both directions. "We did not fake it" is a test here, not a promise — and if a signal
// lands later, these checks fail loudly and point at the row to update.
//
// ---------------------------------------------------------------------------------------
// THE CLOCK
// ---------------------------------------------------------------------------------------
//
// Injected as an anchor: the wall-clock instant the scenario's virtual t=0 maps onto. Every
// timestamp is `anchor + offset`, and the renderer derives the display from those timestamps
// exactly as §6.2 requires ("Persist timestamps and derive the display locally"). Nothing is
// monkey-patched, nothing sleeps, and the full two-hour turn is walked in under a
// millisecond. `Working for 18s` is produced by anchoring 18.6s in the past and reading the
// real row.
//
//   2h 17m 50s = (2 x 3600) + (17 x 60) + 50 = 7200 + 1020 + 50 = 8270 s = 8_270_000 ms
//
// which is asserted below as a MEASURED span (`endedAt - startedAt`), never as a literal.

"use strict";

const path = require("path");
const fs = require("fs");
const { leaveHome, loadPlaywright, shot, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");

// §26 names nine screenshots as required deliverables, so unlike `.shots/` — the per-run
// scratch every other suite writes and gitignores — these NINE are committed. They are the
// first visual record this UI has ever had; the display on this machine has been locked for
// three slices and `screencapture` returns a valid single-color (0,0,0) PNG, so every one
// of them comes out of WebKit's own compositor and is pixel-counted before it counts.
const SHOTS_26 = path.join(__dirname, "shots-26");

// The lease handoff (t=0 accepted -> the clock starts) plus the 18s §26 asks to see.
const ANCHOR_18S = 18600;
const ANCHOR_SUB_SECOND = 700; // 100ms of elapsed time: §6.1's under-one-second row

const shots = [];
async function evidence(page, name, note) {
  const s = await shot(page, name); // throws unless the pixels are a real render
  fs.mkdirSync(SHOTS_26, { recursive: true });
  fs.copyFileSync(s.file, path.join(SHOTS_26, name + ".png"));
  shots.push({ name, note, distinct: s.distinct, bytes: s.bytes });
  return `${name}.png — ${s.width}x${s.height}, ${s.distinct} distinct colors, ${s.bytes} bytes`;
}

async function openApp(browser, viewport) {
  const page = await browser.newPage({ viewport: viewport || { width: 1440, height: 960 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.goto(APP);
  // The home screen is the landing surface now; this suite is about the app UI behind it.
  await leaveHome(page);
  await page.waitForFunction("typeof window.RichTimeline === 'object'");
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

/// Open §10.1's thread, set the injected clock, and send the CEO's prompt through the
/// composer — the real path, including the composer clearing only after acceptance.
async function sendTheBrief(page, anchorBackMs) {
  await page.click('.nav-thread[data-thread-id="memory"]');
  await page.waitForSelector("#composer, #input, textarea", { state: "attached" });
  const prompt = await page.evaluate((back) => {
    window.__RICHOS_MOCK__.setMemoryStrategyAnchor(Date.now() - back);
    return window.__RICHOS_MOCK__.MEMORY_STRATEGY_PROMPT;
  }, anchorBackMs);
  const box = await page.$("#input");
  await box.click();
  await box.fill(prompt);
  await page.keyboard.press("Enter");
  await page.waitForSelector(".tl-user-bubble");
  await settle(page);
  return prompt;
}

/// The shell coalesces renders into an animation frame (§15: "at most once per animation
/// frame"), so a test that reads the DOM in the same tick it emitted an event reads the
/// PREVIOUS frame. Two frames is one full scheduled render plus its flush.
async function settle(page) {
  await page.evaluate(
    () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
  );
}

/// Walk the scenario to step `n`. Instant: the driver never waits on a clock.
async function runTo(page, n) {
  const applied = await page.evaluate((step) => {
    const s = window.__RICHOS_MOCK__.activeMemoryStrategy();
    if (!s) throw new Error("no scenario running — the send did not start one");
    return s.runTo(step).map((r) => `${r.n}. ${r.spec} [${r.status}] :: ${r.did}`);
  }, n);
  await settle(page);
  return applied;
}

/// §10.8 — the CEO leaves the thread and comes back. This is also the ONLY route worker
/// rows have to the screen today: `rich://worker-upserted` is deferred in the emitter
/// (live.rs:26) and unwired in `main.js`, so workers arrive on the `get_timeline` snapshot.
async function leaveAndReturn(page) {
  await page.click('.nav-thread[data-thread-id="acme"]');
  await page.waitForFunction("document.querySelectorAll('.tl-turn').length > 0");
  await page.click('.nav-thread[data-thread-id="memory"]');
  await page.waitForSelector('.tl-turn[data-turn-id="turn_memory_01"]');
  await settle(page);
}

async function setTranscript(page, open) {
  await page.evaluate((wantOpen) => {
    const btn = document.querySelector('.tl-turn[data-turn-id="turn_memory_01"] .tl-duration-btn');
    if (!btn || !btn.classList) return;
    const isOpen = btn.getAttribute("aria-expanded") === "true";
    if (isOpen !== wantOpen) btn.click();
  }, open);
  await settle(page);
}

async function expandLiveTranscript(page) {
  await setTranscript(page, true);
}

async function expandTranscript(page) {
  await setTranscript(page, true);
  await page.waitForSelector(".tl-chip", { state: "attached" });
}

async function readTurn(page) {
  return page.evaluate(() => {
    const sec = document.querySelector('.tl-turn[data-turn-id="turn_memory_01"]');
    if (!sec) return null;
    const q = (s) => Array.from(sec.querySelectorAll(s));
    return {
      duration: sec.querySelector(".tl-duration-label")
        ? sec.querySelector(".tl-duration-label").textContent
        : (sec.querySelector(".tl-duration-btn") || {}).textContent,
      durationExpanded: (sec.querySelector(".tl-duration-btn") || {}).getAttribute
        ? sec.querySelector(".tl-duration-btn").getAttribute("aria-expanded")
        : null,
      activityRows: q(".tl-activity-text").map((n) => n.textContent),
      chips: q(".tl-chip").map((c) => ({
        id: c.id,
        name: c.querySelector(".tl-chip-name").textContent,
        role: c.querySelector(".tl-chip-role") ? c.querySelector(".tl-chip-role").textContent : null,
        state: c.querySelector(".tl-chip-state").textContent,
        qualifier: c.querySelector(".tl-chip-qualifier") ? c.querySelector(".tl-chip-qualifier").textContent : null,
      })),
      workerGroups: q(".tl-workers").length,
      prose: q(".tl-rich").map((n) => n.innerText),
      userText: (sec.querySelector(".tl-user-text") || {}).textContent || "",
      text: sec.innerText,
    };
  });
}

/// The projected snapshot, straight off the mock bridge — the same bytes `get_timeline`
/// hands `applySnapshot`.
async function snapshot(page) {
  return page.evaluate(() => window.RichBridge.invoke("get_timeline", { threadId: "memory" }));
}

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("§26 memory-strategy — real shell, real renderer, WebKit");

  // =====================================================================================
  // PASS A — the first second. §10.2's scaffold, before any duration exists.
  // =====================================================================================
  const a = await openApp(browser);

  await run.check("§26.1-2 the CEO's prompt lands and the turn is accepted", async () => {
    const prompt = await sendTheBrief(a, ANCHOR_SUB_SECOND);
    const t = await readTurn(a);
    assert(t, "the turn section rendered");
    assert(t.userText.includes("design a proper replacement for Claude auto memory"), "the prompt is the CEO's");
    assert(t.userText.includes("https://docs.anthropic.com/en/docs/claude-code/memory"), "URL 1 present");
    assert(t.userText.includes("https://code.claude.com/docs/en/memory"), "URL 2 present");
    assert(t.userText.includes("/Users/alex/ab/richos/docs/plans/"), "a file path present");
    const composer = await a.evaluate(() => document.getElementById("input").value);
    assertEqual(composer, "", "§10.2: the composer clears after the message is accepted");
    // The bubble is the SHELL's optimistic one, re-keyed onto the real turn id.
    const id = await a.evaluate(() =>
      (document.querySelector(".tl-user-bubble").closest("[data-turn-id]") || {}).dataset.turnId
    );
    assertEqual(id, "turn_memory_01", "the optimistic bubble was adopted onto the real turn");
    return `${prompt.split("\n").length}-line prompt, composer cleared, adopted onto turn_memory_01`;
  });

  await run.check("§6.1 under one second the row reads `Working` — no number invented", async () => {
    const t = await readTurn(a);
    assertEqual(t.duration.trim(), "Working", "§6.1's first row: accepted, under one second");
    return `"${t.duration.trim()}" at ~${ANCHOR_SUB_SECOND - 600}ms of measured elapsed time`;
  });

  await run.check("§5.1 the long prompt clamps with an accessible Show more", async () => {
    const before = await a.evaluate(() => ({
      clamped: document.querySelector(".tl-user-bubble").classList.contains("is-clamped"),
      label: document.querySelector(".tl-more").textContent,
      expanded: document.querySelector(".tl-more").getAttribute("aria-expanded"),
    }));
    await a.click(".tl-more");
    await settle(a);
    const after = await a.evaluate(() => ({
      clamped: document.querySelector(".tl-user-bubble").classList.contains("is-clamped"),
      label: document.querySelector(".tl-more").textContent,
      expanded: document.querySelector(".tl-more").getAttribute("aria-expanded"),
    }));
    await a.click(".tl-more");
    await settle(a);
    const back = await a.evaluate(() => document.querySelector(".tl-user-bubble").classList.contains("is-clamped"));
    assert(before.clamped, "a 22-line prompt is over §5.1's 18-line clamp and starts clamped");
    assertEqual(before.label, "Show more");
    assertEqual(before.expanded, "false");
    assert(!after.clamped, "Show more expands it");
    assertEqual(after.label, "Show less");
    assertEqual(after.expanded, "true");
    assert(back, "Show less re-clamps it");
    return "clamped -> Show more -> Show less -> clamped, aria-expanded tracked both ways";
  });

  await run.check("SCREENSHOT 1/9: just after send", async () =>
    evidence(a, "ms-01-just-after-send", "§26 shot 1")
  );

  await a.close();

  // =====================================================================================
  // PASS B — the whole turn. Anchored 18.6s in the past so the live row reads 18s.
  // =====================================================================================
  const b = await openApp(browser);
  await sendTheBrief(b, ANCHOR_18S);

  await run.check(
    "§6.4 a LIVE turn's work transcript is expanded BY DEFAULT — and the CEO still wins",
    async () => {
      await runTo(b, 5);
      const live = await b.evaluate(() => {
        const sec = document.querySelector('.tl-turn[data-turn-id="turn_memory_01"]');
        return {
          expanded: sec.querySelector(".tl-duration-btn").getAttribute("aria-expanded"),
          activityRows: sec.querySelectorAll(".tl-activity-text").length,
        };
      });
      // §6.4 opens: "While active, the work activity beneath the duration row is expanded by
      // default." Until 2026-08-29 nothing put a live turn into `model.expanded` — that set
      // was written by the CEO's own toggle alone — so a running turn started closed and the
      // CEO watched a chevron instead of the work. `RichTimeline.isTurnExpanded` now carries
      // §6.4's two defaults, and the CEO's explicit choice overrules both.
      assertEqual(live.expanded, "true", "§6.4: while active, expanded by default");
      assert(live.activityRows > 0, "and the work is on screen without a click: " + live.activityRows);

      // THE CEO'S OWN COLLAPSE, MID-TURN, IS NOT OVERRULED. This is the half a naive fix
      // breaks: re-deriving "expanded" from liveness on every render re-opens what he just
      // closed, on the very next event.
      await setTranscript(b, false);
      const closed = await b.evaluate(() => {
        const sec = document.querySelector('.tl-turn[data-turn-id="turn_memory_01"]');
        return sec.querySelector(".tl-duration-btn").getAttribute("aria-expanded");
      });
      assertEqual(closed, "false", "the CEO closed it while the turn is still running");
      await runTo(b, 5);
      const stillClosed = await b.evaluate(() => {
        const sec = document.querySelector('.tl-turn[data-turn-id="turn_memory_01"]');
        return sec.querySelector(".tl-duration-btn").getAttribute("aria-expanded");
      });
      assertEqual(stillClosed, "false", "and further live events do not re-open it over him");

      // Back to the default state for the rest of this pass.
      await setTranscript(b, true);
      return (
        "live turn: aria-expanded=true with " + live.activityRows + " work rows, no click.\n" +
        "          CEO collapse mid-turn holds across further live events."
      );
    }
  );

  await run.check("§26.3-5 commentary, seven reads rolled into one summary, one search", async () => {
    const applied = await runTo(b, 5);
    await expandLiveTranscript(b);
    const t = await readTurn(b);
    assert(t.prose.length >= 1, "Rich's commentary is on screen");
    assert(t.prose[0].includes("reading the full source set"), "the commentary is his, verbatim");
    assert(t.activityRows.includes("Read 7 files"), "§26.4 seven reads, ONE summary: " + t.activityRows.join(" | "));
    assert(t.activityRows.includes("Searched"), "§26.5 one web search");
    assert(
      !t.activityRows.some((r) => /Read a file/.test(r)),
      "the seven individual rows are rolled up, not listed: " + t.activityRows.join(" | ")
    );
    return applied.join("\n          ");
  });

  await run.check("§26 the clock reads exactly `Working for 18s` — injected, not waited for", async () => {
    const t = await readTurn(b);
    assertEqual(t.duration.trim(), "Working for 18s", "the anchored elapsed time");
    const m = await b.evaluate(() => {
      const s = window.__RICHOS_MOCK__.activeMemoryStrategy();
      return { startedAt: s.startedAt, anchor: s.anchor, elapsed: Date.now() - s.startedAt };
    });
    assert(m.elapsed >= 18000 && m.elapsed < 19000, "measured elapsed " + m.elapsed + "ms floors to 18s");
    return `startedAt = anchor + 600; Date.now() - startedAt = ${m.elapsed}ms -> "18s". No sleep, no patched Date.now.`;
  });

  await run.check("SCREENSHOT 2/9: active at `Working for 18s`", async () =>
    evidence(b, "ms-02-working-for-18s", "§26 shot 2")
  );

  await run.check("§26.6 three workers start — LIVE, and the reload says the same thing", async () => {
    await runTo(b, 6);
    // MEASURED THE WAY THE GAP WAS MEASURED: read the chips with no snapshot in between.
    // This is the assertion that was `0` before `rich://worker-upserted` stopped being
    // deferred — a delegation reached the screen only after a `get_timeline` read, and
    // showed as a nameless "Worked" row for the rest of the turn.
    const live = await readTurn(b);
    const liveChips = live.chips.map((c) => `${c.name}/${c.role}/${c.state}`);
    assertEqual(
      liveChips,
      ["Sage/architecture/Working", "Frank/red team/Working", "Clark/research/Working"],
      "three chips, DURING the turn, with no snapshot read"
    );
    assertEqual(live.workerGroups, 1, "§7.1: one group, not three identical rows");
    assert(
      live.text.includes("Sage, Frank and Clark started working"),
      "§7.1's grouped summary, verbatim, live: " + live.text.slice(0, 400)
    );

    // AND THE TWO PATHS AGREE. A row that changed when the snapshot arrived would be a new
    // defect, not a fix — so the same three chips are re-read after leaving the thread and
    // coming back, which forces a real `get_timeline`.
    await leaveAndReturn(b);
    await expandTranscript(b);
    const t = await readTurn(b);
    assertEqual(
      t.chips.map((c) => `${c.name}/${c.role}/${c.state}`),
      liveChips,
      "the reloaded rows must be the SAME rows: same worker, same role, same state"
    );
    assertEqual(t.chips.map((c) => c.id), live.chips.map((c) => c.id), "and the same ids — an upsert, not a duplicate");
    return "live: " + liveChips.join(", ") + "\n          after a get_timeline read: identical, same ids";
  });

  await run.check("SCREENSHOT 3/9: three workers active", async () =>
    evidence(b, "ms-03-three-workers-active", "§26 shot 3")
  );

  await run.check("§26.7-9 states update INDEPENDENTLY and in place — one run, one row", async () => {
    await runTo(b, 9);
    await leaveAndReturn(b);
    await expandTranscript(b);
    const t = await readTurn(b);
    assertEqual(
      t.chips.map((c) => `${c.name}/${c.state}`),
      ["Sage/Working", "Frank/Ended", "Clark/Working"],
      "Clark updated, Frank's run ended, Sage updated — three different states, one group"
    );
    assertEqual(t.chips.length, 3, "still three rows: a run is ONE row however many events it produced");
    assertEqual(t.workerGroups, 1);
    const frank = t.chips.find((c) => c.name === "Frank");
    assertEqual(frank.qualifier, "outcome not recorded", "§26.8: `Ended`, never `finished`");
    return t.chips.map((c) => `${c.name}=${c.state}${c.qualifier ? " (" + c.qualifier + ")" : ""}`).join(", ");
  });

  await run.check("§26.10-12 the run ends, Rich says only what was witnessed, a second run opens", async () => {
    await runTo(b, 12);
    await leaveAndReturn(b);
    await expandTranscript(b);
    const t = await readTurn(b);
    const sage1 = t.chips.find((c) => c.id === "chip:agt_ms_sage_1");
    assertEqual(sage1.state, "Ended");
    assertEqual(sage1.qualifier, "outcome not recorded");
    assert(t.chips.some((c) => c.id === "chip:agt_ms_sage_2" && c.state === "Working"), "a second Sage run is open");
    assertEqual(t.workerGroups, 2, "§10.6: the replacement opens its OWN group, below the commentary");
    const recovery = t.prose.find((p) => p.includes("Sage's run ended"));
    assert(recovery, "Rich's recovery commentary is in the transcript");
    // THE SUBTLE HALF. Prose is the one channel that accepts any string, so the failure
    // must not be faked through Rich's mouth either.
    for (const word of ["failed", "failure", "crashed", "died", "error"]) {
      assert(
        !new RegExp("\\b" + word + "\\b", "i").test(recovery),
        `Rich claimed "${word}" about a run whose outcome nothing recorded: ${recovery}`
      );
    }
    assert(recovery.includes("nothing recorded how"), "he says what was actually witnessed");
    return `2 groups; sage_1=Ended(outcome not recorded), sage_2=Working; recovery prose carries no failure claim`;
  });

  await run.check("SCREENSHOT 4/9: the ended run with Rich's recovery commentary", async () =>
    evidence(
      b,
      "ms-04-run-ended-with-recovery-commentary",
      "§26 shot 4 asks for `Sage FAILED with Rich recovery commentary`. The failure half does " +
        "not exist in this runtime, so this is the honest analogue: the run ended, the outcome " +
        "was not recorded, and Rich's commentary says exactly that."
    )
  );

  await run.check("§7.2 worker detail opens BESIDE the thread, both panes readable", async () => {
    await b.click('[id="chip:agt_ms_sage_1"]');
    await b.waitForSelector("#inspector:not([hidden])");
    const r = await b.evaluate(() => {
      const insp = document.getElementById("inspector");
      const conv = document.getElementById("conversation");
      const ir = insp.getBoundingClientRect();
      const cr = conv.getBoundingClientRect();
      return {
        title: document.getElementById("inspector-title").textContent,
        modal: insp.getAttribute("aria-modal"),
        overlaps: ir.left < cr.right - 1 && cr.left < ir.right - 1,
        conversationWidth: Math.round(cr.width),
        inspectorWidth: Math.round(ir.width),
        body: document.getElementById("inspector-body").innerText,
      };
    });
    assertEqual(r.title, "Sage");
    assertEqual(r.modal, null, "§7.2: a sibling pane, not a modal");
    assert(!r.overlaps, "beside, not over");
    assert(r.body.includes("Ended"), "the state it actually has");
    // §26's fifth shot wants "its file-change card visible". §7.2 item 6 has no source
    // (timeline.js:1177-1201) — Phase 5 owns artifacts — so the card is ABSENT, and that
    // absence is asserted rather than papered over with an invented diff.
    for (const fake of ["+234", "-28", "Undo", "Review", "Edited 4 files"]) {
      assert(!r.body.includes(fake), "a file-change card was invented: " + fake);
    }
    return `conversation ${r.conversationWidth}px | inspector ${r.inspectorWidth}px, side by side, no invented diff`;
  });

  await run.check("SCREENSHOT 5/9: worker detail beside the main thread", async () =>
    evidence(
      b,
      "ms-05-worker-detail-beside-thread",
      "§26 shot 5 asks for the file-change card too. §7.2 item 6 has no source — Phase 5 owns " +
        "artifacts and changed files — so the pane shows the three things that are sourced and " +
        "the card is absent, asserted absent above."
    )
  );

  await run.check("§26.13 NO PLAN IS DRAWN, at either step count", async () => {
    const snap = await snapshot(b);
    const kinds = Array.from(new Set(snap.items.map((i) => i.kind)));
    assert(!kinds.includes("plan"), "no plan item on the wire: " + kinds.join(", "));
    const t = await readTurn(b);
    for (const s of ["Step 2 / 5", "Step 3 / 5", "Step 2 of 5", "Step 3 of 5", "tasks completed"]) {
      assert(!t.text.includes(s), "a plan was rendered anyway: " + s);
    }
    const planNodes = await b.evaluate(() => document.querySelectorAll(".tl-plan, [data-kind='plan']").length);
    assertEqual(planNodes, 0);
    return "kinds on the wire: " + kinds.join(", ") + " — no `plan`, and no plan copy in the DOM";
  });

  await run.check("§26.14-16 the turn completes at a MEASURED 2h 17m 50s", async () => {
    const applied = await runTo(b, 16);
    // `rich://turn-completed` triggers the shell's own reconciliation reload (main.js).
    await b.waitForFunction(
      "!!document.querySelector('.tl-turn[data-turn-id=\"turn_memory_01\"] .tl-duration-btn')"
    );
    const m = await b.evaluate(() => {
      const snap = null;
      const s = window.__RICHOS_MOCK__.activeMemoryStrategy();
      return { startedAt: s.startedAt, activeMs: s.activeMs, snap };
    });
    const snap = await snapshot(b);
    const dur = snap.items.find((i) => i.kind === "work_duration");
    assertEqual(dur.state, "completed");
    assertEqual(dur.endedAt - dur.startedAt, 8270000, "MEASURED span, endedAt - startedAt");
    assertEqual(dur.activeMs, 8270000, "and that is what the projection reports");
    const t = await readTurn(b);
    assert(t.duration.includes("Worked for 2h 17m 50s"), "the frozen row: " + t.duration);
    assertEqual(m.activeMs, 8270000);
    return (
      applied.join("\n          ") +
      `\n          (2 x 3600) + (17 x 60) + 50 = 7200 + 1020 + 50 = 8270 s = 8270000 ms; ` +
      `endedAt - startedAt = ${dur.endedAt - dur.startedAt} ms`
    );
  });

  await run.check("§6.4 the transcript collapses, the five questions stay visible", async () => {
    // This page's CEO opened the transcript himself several steps ago, and §6.4's settle
    // deliberately does not fight him (main.js:1176-1179: "Only if the CEO has not opened it
    // himself in the meantime"). The AUTOMATIC collapse is proved on its own page below,
    // with the disclosure never touched. Here the collapse is the CEO's.
    await setTranscript(b, false);
    const t = await readTurn(b);
    assertEqual(t.chips.length, 0, "worker rows collapsed under the duration row");
    assertEqual(t.activityRows.filter((r) => r === "Read 7 files").length, 0, "activity collapsed");
    assert(t.text.includes("1. What is the first deliverable"), "the final response stays expanded");
    assert(t.text.includes("5. On cutover day"), "all five questions, below the divider");
    const order = await b.evaluate(() => {
      const sec = document.querySelector('.tl-turn[data-turn-id="turn_memory_01"]');
      const row = sec.querySelector(".tl-duration");
      const last = Array.from(sec.querySelectorAll(".tl-rich")).pop();
      return row.compareDocumentPosition(last) & Node.DOCUMENT_POSITION_FOLLOWING ? "below" : "above";
    });
    assertEqual(order, "below", "§25: the final response appears below the completed-duration divider");
    return "collapsed to the duration row; five questions still on screen, below the divider";
  });

  await run.check("SCREENSHOT 6/9: final response with collapsed `Worked for 2h 17m 50s`", async () =>
    evidence(b, "ms-06-final-collapsed", "§26 shot 6")
  );

  await run.check("§6.4 expanding restores the original chronology in place", async () => {
    await expandTranscript(b);
    const t = await readTurn(b);
    assertEqual(t.chips.length, 4, "all four worker runs are back");
    assert(t.activityRows.includes("Read 7 files"), "and the activity");
    assert(t.prose[0].includes("reading the full source set"), "commentary in its ORIGINAL order, first");
    assert(t.text.includes("5. On cutover day"), "the final response never left");
    return `4 chips, ${t.activityRows.length} activity rows, ${t.prose.length} prose runs, in order`;
  });

  await run.check("SCREENSHOT 7/9: expanded completed activity", async () =>
    evidence(b, "ms-07-expanded-completed-activity", "§26 shot 7")
  );

  await run.check("§25 both panes resize by keyboard and the widths persist", async () => {
    const before = await b.evaluate(() => ({
      rail: document.getElementById("rail").getBoundingClientRect().width,
      insp: document.getElementById("inspector").getBoundingClientRect().width,
    }));
    await b.focus("#rail-resizer");
    for (let i = 0; i < 12; i++) await b.keyboard.press("ArrowRight");
    await b.focus("#inspector-resizer");
    for (let i = 0; i < 12; i++) await b.keyboard.press("ArrowLeft");
    // `commitRailWidth` debounces its write by 150ms (main.js:2067-2073) while
    // `persistInspectorWidth` writes straight through — so the store is read after the
    // debounce has had time to land rather than racing it.
    await b.waitForTimeout(500);
    const after = await b.evaluate(async () => ({
      rail: document.getElementById("rail").getBoundingClientRect().width,
      insp: document.getElementById("inspector").getBoundingClientRect().width,
      stored: await window.RichBridge.invoke("nav_state"),
    }));
    assert(after.rail > before.rail, `rail ${before.rail} -> ${after.rail}`);
    assert(after.insp > before.insp, `worker pane ${before.insp} -> ${after.insp}`);
    assertEqual(
      [after.stored.sidebar_width, after.stored.inspector_width],
      [Math.round(after.rail), Math.round(after.insp)],
      `the widths the store accepted must be the widths on screen ` +
        `(rail ${Math.round(after.rail)}px, worker pane ${Math.round(after.insp)}px)`
    );
    return `rail ${Math.round(before.rail)} -> ${Math.round(after.rail)}px, worker pane ${Math.round(
      before.insp
    )} -> ${Math.round(after.insp)}px, both persisted (nav_state agrees)`;
  });

  await run.check("SCREENSHOT 8/9: resized left navigation and resized worker pane", async () =>
    evidence(b, "ms-08-resized-panes", "§26 shot 8")
  );

  // The snapshot as it stands, for the reload comparison below.
  const snapBefore = await snapshot(b);

  await run.check("§14/§26 the same thread, restored after an app reload", async () => {
    // A real reload of the shell. `mock.js` has no ledger on disk, so the durable record is
    // re-derived from the SAME anchor — which is exactly the claim a deterministic fixture
    // makes, and it is checked below by comparing the two snapshots byte for byte. The
    // renderer then rebuilds from `get_timeline` alone: ZERO live events reach this page.
    const anchor = await b.evaluate(() => window.__RICHOS_MOCK__.activeMemoryStrategy().anchor);
    await b.goto(APP);
    await leaveHome(b);
    await b.waitForFunction("typeof window.RichTimeline === 'object'");
    await b.waitForSelector(".nav-thread", { state: "attached" });
    await b.evaluate((a) => window.__RICHOS_MOCK__.memoryStrategy({ anchor: a }).runTo(16), anchor);
    await b.click('.nav-thread[data-thread-id="memory"]');
    await b.waitForSelector('.tl-turn[data-turn-id="turn_memory_01"]');
    await settle(b);
    const t = await readTurn(b);
    assert(t.duration.includes("Worked for 2h 17m 50s"), "the frozen duration survived: " + t.duration);
    assert(t.text.includes("1. What is the first deliverable"), "the final response is expanded on arrival");
    assert(t.userText.includes("design a proper replacement"), "the CEO's prompt is back");
    await expandTranscript(b);
    const e = await readTurn(b);
    assertEqual(e.chips.length, 4, "and the full work transcript reopens");
    return `restored from get_timeline alone: "${t.duration.trim()}", 4 worker runs under it`;
  });

  await run.check("SCREENSHOT 9/9: same thread restored after app reload", async () =>
    evidence(b, "ms-09-restored-after-reload", "§26 shot 9")
  );

  await run.check("DETERMINISM: the same anchor twice produces identical bytes", async () => {
    const again = await snapshot(b);
    assertEqual(again, snapBefore, "the re-derived snapshot differs from the first run");
    // And a THIRD construction in a fresh page, compared as JSON text.
    const third = await b.evaluate((a) => {
      window.__RICHOS_MOCK__.memoryStrategy({ anchor: a }).runTo(16);
      return window.RichBridge.invoke("get_timeline", { threadId: "memory" });
    }, snapBefore.items[0].createdAt);
    assertEqual(JSON.stringify(third), JSON.stringify(snapBefore), "a third run differs");
    return `${snapBefore.items.length} items, identical across three constructions from one anchor`;
  });

  // =====================================================================================
  // PASS C — §6.4 point 3, with the disclosure NEVER touched.
  // =====================================================================================
  const c = await openApp(browser);
  await sendTheBrief(c, ANCHOR_18S);

  await run.check("§6.4 completion collapses the work transcript on its own", async () => {
    // THE TWO DEFAULTS, ON ONE PAGE, WITH THE DISCLOSURE NEVER TOUCHED. §6.4 asks for
    // expanded while active and collapsed after a settling transition, and the second must
    // not be defeated by the first: an implementation that simply derives "expanded" from
    // liveness would snap the transcript shut the instant the terminal status arrived,
    // leaving the 180ms settle with nothing to do and no transition to see.
    await runTo(c, 9);
    const midTurn = await c.evaluate(() => {
      const sec = document.querySelector('.tl-turn[data-turn-id="turn_memory_01"]');
      return {
        expanded: sec.querySelector(".tl-duration-btn").getAttribute("aria-expanded"),
        chips: sec.querySelectorAll(".tl-chip").length,
      };
    });
    assertEqual(midTurn.expanded, "true", "expanded by default while the turn is running");
    assertEqual(midTurn.chips, 3, "with the delegations visible, unclicked");

    await runTo(c, 16);
    await c.waitForFunction(
      () => {
        const btn = document.querySelector('.tl-turn[data-turn-id="turn_memory_01"] .tl-duration-btn');
        return btn && btn.getAttribute("aria-expanded") === "false" && /Worked for/.test(btn.textContent);
      },
      { timeout: 5000 }
    );
    // Nothing in this page ever clicked the disclosure, so the 180ms settle owns the state.
    const t = await readTurn(c);
    assert(t.duration.includes("Worked for 2h 17m 50s"), "frozen: " + t.duration);
    assertEqual(t.chips.length, 0, "worker rows are inside the collapsed transcript");
    assert(t.text.includes("1. What is the first deliverable"), "the final response stays out of it");
    assert(t.text.includes("5. On cutover day"), "all five questions");
    return (
      "mid-turn: aria-expanded=true, 3 chips, never clicked -> after completion: collapsed " +
      "by the 180ms settle; five questions still on screen"
    );
  });

  await run.check("no page errors in the untouched pass", async () => {
    assertEqual(c.__errors, []);
    return "0 uncaught errors, 0 console errors";
  });

  await c.close();

  // =====================================================================================
  // THE MANIFEST — the DOM must agree with the table, in BOTH directions
  // =====================================================================================

  await run.check("every one of §26's sixteen steps is represented or declared", async () => {
    const steps = await b.evaluate(() => window.__RICHOS_MOCK__.MEMORY_STRATEGY_STEPS);
    assertEqual(steps.length, 16, "§26 lists sixteen steps");
    assertEqual(
      steps.map((s) => s.n),
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    );
    for (const s of steps) {
      assert(
        ["represented", "partial", "unrepresentable"].includes(s.status),
        `step ${s.n} has no status`
      );
      assert(s.source && /\.(rs|js):\d/.test(s.source), `step ${s.n} cites no file:line — "${s.source}"`);
      if (s.status !== "represented") assert(s.gap, `step ${s.n} is ${s.status} with no stated reason`);
    }
    const counts = steps.reduce((a, s) => ((a[s.status] = (a[s.status] || 0) + 1), a), {});
    return (
      `${counts.represented} represented, ${counts.partial} partial, ${counts.unrepresentable} unrepresentable\n          ` +
      steps
        .filter((s) => s.status !== "represented")
        .map((s) => `${s.n}. ${s.spec} [${s.status}] — ${s.source}`)
        .join("\n          ")
    );
  });

  await run.check("NEGATIVE CONTROL: no unwitnessable worker state reaches the wire or the DOM", async () => {
    const snap = await snapshot(b);
    const workers = snap.items.filter((i) => i.kind === "worker_activity");
    assertEqual(workers.length, 4, "four runs across the turn");
    const observed = Array.from(new Set(workers.map((w) => w.worker.observedState))).sort();
    for (const o of observed) {
      assert(
        ["created", "started", "updated", "run_ended"].includes(o),
        "an observed state the emitters cannot produce: " + o
      );
    }
    const states = Array.from(new Set(workers.map((w) => w.worker.state))).sort();
    for (const forbidden of ["failed", "completed", "interrupted", "waiting", "not_found"]) {
      assert(!states.includes(forbidden), "`" + forbidden + "` has no witness and is on the wire");
    }
    await expandTranscript(b);
    const t = await readTurn(b);
    for (const word of ["Failed", "Done", "Finished", "Completed", "Stopped", "Unavailable"]) {
      assert(
        !t.chips.some((c) => c.state === word),
        `a chip claims "${word}" — see MEMORY_STRATEGY_STEPS[9] and worker_events.rs:137`
      );
    }
    return `observed: ${observed.join(", ")} -> states: ${states.join(", ")}; chips: ${t.chips
      .map((c) => c.state)
      .join(", ")}`;
  });

  await run.check("SCREENSHOT INVENTORY", async () => {
    assertEqual(shots.length, 9, "§26 asks for nine");
    return shots.map((s) => `${s.name}.png (${s.distinct} colors) — ${s.note}`).join("\n          ");
  });

  await run.check("no page errors", async () => {
    assertEqual(b.__errors, []);
    return "0 uncaught errors, 0 console errors";
  });

  await b.close();
  await browser.close();
  return run.report();
}

main().then(
  (failed) => process.exit(failed ? 1 : 0),
  (e) => {
    console.error(e);
    process.exit(1);
  }
);

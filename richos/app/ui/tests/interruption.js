// **THE FAILURE CARD, WHEN THE FAILURE IS LOCAL** — the 2026-09-17 nightly's D2, rendered
// by the REAL renderer under WebKit, the engine Tauri ships on macOS.
//
// `docs/verification/2026-09-17-nightly-1.2.0-20260917.1-onscreen-audit.md` §D2. The
// published nightly held this in its own ledger:
//
//     "reason":"cognition protocol: \"Not logged in · Please run /login\""
//
// and showed him this:
//
//     Stopped after 1s
//     I hit a snag mid-thought and had to stop — say the word and I'll pick it back up.
//     Everything I'd already written above is saved.
//     [Pick it back up]
//
// Three untruths in four lines: a permanent condition called a passing hiccup, a promise
// about saved work when nothing had been written, and a retry control for a state no number
// of presses can clear. This suite makes each one unreachable on the surface the CEO sees.
//
// **THE BYTES ARE THE BACKEND'S, NOT THIS FILE'S.** Every sentence asserted below is scraped
// out of `crates/richos-core/src/interruption.rs` at run time by `lib/state-strings.js` —
// the same scrape `outage.js` and `affordances.js` use. Nothing here types a sentence, so a
// reworded `ceo_message()` moves this suite with it instead of leaving it green over copy
// the product no longer says.
//
// Run: node interruption.js   (or `npm test` for every suite in this directory)

"use strict";

const { loadPlaywright, openFixture, createRun, assert, assertEqual } = require("./lib/harness");
const { rustStrings, normalize } = require("./lib/state-strings");
const C = require("./lib/contrast");

const THREAD = "thr_interruption";
const TURN = "turn_interruption";

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

const NOT_SIGNED_IN = rustSentence("not connected to your Anthropic account");
const TRANSIENT = rustSentence("lost my connection to the part of me that thinks");
// The route is a WHOLE authored sentence, relayed verbatim — not a breadcrumb this file or
// the renderer wraps. `InterruptionCause::route`.
const ROUTE = rustSentence("under Account connection");

// The exact sentence `InterruptionRecord::new` writes when Rich had written nothing. It is
// a `format`-free literal in Rust, but it lives in `InterruptionRecord::new` rather than in
// a `ceo_message()` body, so the scraper does not see it and this is the one string the
// suite states. The core test `nothing_written_means_no_claim_about_a_saved_answer_is_made`
// pins the same bytes on the Rust side, so a change breaks there first.
const ONLY_HIS_WORDS = "Your message is saved. I hadn't written any of my answer yet.";

// The two generic sentences, which must NOT appear when a cause is known.
const GENERIC_BODY = "I hit a snag mid-thought and had to stop";
const GENERIC_NOTE = "Everything I'd already written above is saved.";

// ---------------------------------------------------------------------------------------
// FIXTURES
// ---------------------------------------------------------------------------------------

function snapshot(interruption, opts) {
  const withPartial = !!(opts && opts.withPartial);
  const b = (id, extra) =>
    Object.assign(
      {
        id,
        entityId: "northwind",
        threadId: THREAD,
        turnId: TURN,
        bindingRevision: 1,
        createdAt: 1789000000000,
        sequence: null,
        slot: "stream",
        visibility: "ceo",
      },
      extra || {}
    );
  const items = [
    Object.assign(b(TURN + ":user", { slot: "opening", createdAt: 1788000000000 }), {
      kind: "user_message",
      text: "What did I decide about nightly releases?",
      source: "text",
    }),
  ];
  // THE AUDIT'S CASE HAS NO PROSE ABOVE THE CARD, and that is load-bearing: the old note
  // claimed "everything I'd already written above is saved" with nothing above it at all.
  if (withPartial) {
    items.push(
      Object.assign(b(TURN + ":text:0", { sequence: 0 }), {
        kind: "rich_message",
        phase: "unknown",
        text: "Pulling the decision record now.",
      })
    );
  }
  items.push(
    Object.assign(b(TURN + ":duration", { slot: "terminal", createdAt: 1788000000000 }), {
      kind: "work_duration",
      state: "interrupted",
      startedAt: 1788000000000,
      endedAt: 1788000001000,
      activeMs: 1000,
    })
  );
  if (interruption) {
    items.push(
      Object.assign(b(TURN + ":interruption", { slot: "terminal", createdAt: 1788000001000 }), interruption)
    );
  }
  return { entityId: "northwind", threadId: THREAD, mode: "ceo", bindingRevision: 1, items };
}

/// The nightly's own turn, exactly as `richos-core` now projects it.
function notSignedInItem() {
  return {
    kind: "turn_interruption",
    cause: "not-signed-in",
    ceoMessage: NOT_SIGNED_IN,
    lossMessage: ONLY_HIS_WORDS,
    route: ROUTE,
    offersRetry: false,
  };
}

/// A lost pipe — the one class where asking again is honest advice.
function transientItem() {
  return {
    kind: "turn_interruption",
    cause: "transient",
    ceoMessage: TRANSIENT,
    lossMessage:
      "On disk: what you asked for is saved, the 31 characters of the answer that had " +
      "already arrived are saved. Not on disk: everything the session had worked out in " +
      "its head and had not yet said. Asking again starts that part over.",
    offersRetry: true,
  };
}

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
      actionCount: card.querySelectorAll(".tl-intervention-action").length,
    };
  });

const CARD_PARTS = ["tl-intervention-body", "tl-intervention-note", "tl-intervention-action"];

/// The whole fixture page, measured by `lib/contrast.js`'s shared probe — never arithmetic
/// of this file's own. Same reasoning as `outage.js`'s header records at length: a second
/// implementation that agrees today is one that will disagree silently later.
async function contrastOfPage(page, theme) {
  await page.evaluate(C.pageScript());
  const out = await page.evaluate((o) => window.__contrastProbe(o), {
    surface: "interruption-card",
    theme: theme,
  });
  return {
    measured: out.measuredPaths || [],
    failures: Object.values(out.failures),
    unresolvable: Object.values(out.unresolvable),
  };
}

/// Which of the card's own parts the probe measured, matched against the DOM rather than
/// against a guess at the probe's path format — so "the page is clean" can never mean "the
/// card was not on it".
async function cardNodes(page, measured) {
  const wanted = await page.evaluate((parts) => {
    const sel = parts.map((c) => "." + c).join(", ");
    return Array.from(document.querySelectorAll(sel)).map((el) => {
      const tag = el.tagName.toLowerCase();
      return el.id ? tag + "#" + el.id : tag + "." + String(el.className).split(/\s+/)[0];
    });
  }, CARD_PARTS);
  const missing = wanted.filter((w) => !measured.some((m) => m.indexOf(w) >= 0));
  return { wanted, missing };
}

// ---------------------------------------------------------------------------------------

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("nightly D2 — a failed turn says the cause the app is holding");

  const page = await openFixture(browser);

  // =====================================================================================
  // THE NIGHTLY'S CASE
  // =====================================================================================

  await run.check("the sign-in case replaces the generic card with the backend's sentence", async () => {
    await page.evaluate((s) => window.__render(s), snapshot(notSignedInItem()));
    await page.waitForSelector(".tl-intervention");
    const c = await cardText(page);
    assert(c, "no failure card rendered at all");
    assertEqual(c.body, [NOT_SIGNED_IN], "the body is the authored sentence, verbatim");
    assert(
      !c.body.concat(c.notes).some((t) => t.includes(GENERIC_BODY)),
      "UNTRUTH 1 — the generic snag sentence must be replaced, not appended to"
    );
    return "body = the authored sign-in sentence";
  });

  await run.check("it names the account and the route that exists", async () => {
    const c = await cardText(page);
    const whole = c.body.concat(c.notes).join(" ");
    assert(whole.includes("Anthropic account"), "the account is never mentioned: " + whole);
    assert(
      c.notes.indexOf(ROUTE) >= 0,
      "the authored route sentence must be relayed verbatim: " + JSON.stringify(c.notes)
    );
    return "names the account + Settings → Account connection";
  });

  await run.check("UNTRUTH 2 — it claims no saved answer when none was written", async () => {
    const c = await cardText(page);
    assert(
      !c.notes.some((n) => n.includes(GENERIC_NOTE)),
      '"Everything I\'d already written above is saved" must be gone: ' + JSON.stringify(c.notes)
    );
    assert(
      !c.notes.some((n) => n.includes("already written above")),
      "no claim about prose above the card, because there is none: " + JSON.stringify(c.notes)
    );
    assert(
      c.notes.some((n) => n.includes(ONLY_HIS_WORDS)),
      "the one true thing — HIS message is saved — must still be said: " + JSON.stringify(c.notes)
    );
    // And the screen agrees with the claim: there is genuinely no Rich prose above it.
    const prose = await page.evaluate(() => document.querySelectorAll(".tl-rich, .tl-message--rich").length);
    assertEqual(prose, 0, "the fixture must have no answer above the card for this to mean anything");
    return "no saved-answer claim; his message named; 0 prose rows above";
  });

  await run.check("UNTRUTH 3 — there is no retry control on a state a retry cannot clear", async () => {
    const c = await cardText(page);
    assertEqual(c.actionCount, 0, "a button that cannot work is worse than no button");
    assertEqual(c.action, null, "no control at all, not a disabled one with the same promise");
    return "0 retry controls";
  });

  // =====================================================================================
  // THE POSITIVE CONTROL — without it, "no button" could be "the card never renders one"
  // =====================================================================================

  await run.check("a transient failure DOES get the retry control, and the one verb", async () => {
    await page.evaluate((s) => window.__render(s), snapshot(transientItem(), { withPartial: true }));
    await page.waitForSelector(".tl-intervention");
    const c = await cardText(page);
    assertEqual(c.body, [TRANSIENT], "the body is the authored transient sentence");
    assertEqual(c.actionCount, 1, "exactly one control");
    assertEqual(c.action, "Pick it back up", "same verb as every other failure — one thing to learn");
    assert(
      c.notes.some((n) => n.includes("31 characters of the answer")),
      "what IS on disk is counted: " + JSON.stringify(c.notes)
    );
    return "Pick it back up — present, and the partial reply counted";
  });

  await run.check("an unclassified turn still falls back to the generic card", async () => {
    // A turn written before 2026-09-17 carries no cause. It must render exactly as it
    // always did rather than losing its card — the record is absent, not the failure.
    await page.evaluate((s) => window.__render(s), snapshot(null));
    await page.waitForSelector(".tl-intervention");
    const c = await cardText(page);
    assert(
      c.body.some((t) => t.includes(GENERIC_BODY)),
      "the legacy card must survive for records that carry no cause: " + JSON.stringify(c.body)
    );
    assertEqual(c.actionCount, 1, "and it keeps its control");
    return "legacy record -> generic card, unchanged";
  });

  // =====================================================================================
  // CONTRAST — WCAG AA in BOTH themes, computed, never eyeballed
  // =====================================================================================

  for (const theme of ["dark", "light"]) {
    await run.check(`the card meets WCAG AA in the ${theme} theme`, async () => {
      await page.evaluate((t) => {
        document.documentElement.setAttribute("data-theme", t);
      }, theme);
      await page.evaluate((s) => window.__render(s), snapshot(notSignedInItem()));
      await page.waitForSelector(".tl-intervention");
      const r = await contrastOfPage(page, theme);
      const nodes = await cardNodes(page, r.measured);
      assertEqual(
        nodes.missing.length,
        0,
        `the card's own parts were not measured: ${JSON.stringify(nodes.missing)}`
      );
      assertEqual(
        r.unresolvable.length,
        0,
        `a color the probe could not resolve is a failure to prove: ${JSON.stringify(r.unresolvable)}`
      );
      assertEqual(
        r.failures.length,
        0,
        `WCAG AA failures in ${theme}: ${JSON.stringify(r.failures)}`
      );
      return `${theme}: ${r.measured.length} node(s) measured, ${nodes.wanted.length} card part(s), 0 failures`;
    });
  }

  // =====================================================================================
  // THE TYPE FLOOR — §15: nothing a person is expected to read below 14px
  // =====================================================================================

  await run.check("no part of the card sits below the 14px floor", async () => {
    const sizes = await page.evaluate((parts) => {
      const sel = parts.map((c) => "." + c).join(", ");
      return Array.from(document.querySelectorAll(sel)).map((el) => ({
        cls: String(el.className),
        px: parseFloat(getComputedStyle(el).fontSize),
      }));
    }, CARD_PARTS);
    assert(sizes.length > 0, "nothing measured");
    const small = sizes.filter((s) => s.px < 14);
    assertEqual(small.length, 0, `below the floor: ${JSON.stringify(small)}`);
    return sizes.map((s) => `${s.cls.split(/\s+/)[0]}=${s.px}px`).join(" ");
  });

  await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"));
  await browser.close();
  // `report()` returns the FAILED COUNT, not a verdict. Same form as every other suite here.
  process.exit(run.report() > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

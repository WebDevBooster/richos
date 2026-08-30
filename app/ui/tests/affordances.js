// THE AFFORDANCE RULE, ENFORCED BY MACHINE.
//
//   A state the user could change must be rendered together with the control that changes
//   it. A state change requiring a human action is not a status, it is a request.
//
// Everything else in this pass was one-time cleanup. This is the part that outlives it: a
// rule with nothing enforcing it is the single defect this project has found eleven times
// in two days, and the eleventh was a set of guards that had landed, were inert, and were
// reported as a DATE rather than as a five-second action.
//
// FIVE PARTS, AND WHICH OF THEM BLOCK
// ===================================
//   1  Inventory vs registry              BLOCKING   exact set comparison
//   2  Every ACTIONABLE names a control   BLOCKING   exact, static
//   3  The control is really on screen    BLOCKING   exact, real DOM under WebKit
//   4  Negative and positive controls     BLOCKING   the suite proving it can fail
//   5  The heuristic second opinion       REPORT ONLY, and the number is printed
//
// WHY PART 5 DOES NOT BLOCK, WITH THE MEASUREMENT RATHER THAN A FEELING. Part 5 asks a
// different question from parts 1-3: not "does this classified state have its control?" but
// "does this string READ like a request, whatever the registry calls it?" — the second
// opinion that stops a future engineer silencing part 2 by writing INFORMATIONAL over an
// actionable sentence. Measured against the hand classification of all 112 states on
// 2026-08-30:
//
//     flagged 24, genuinely ACTIONABLE or NEEDS-SOMEONE-ELSE 17  ->  PRECISION 70.8%
//     of the 31 states that are one of those two, it flags 17    ->  RECALL    54.8%
//
// Roughly one flag in three is noise and it misses nearly half the real ones. A tightened
// clause-initial-imperative variant was also measured — precision 78.6%, recall 35.5% —
// which trades a third of the recall for eight points of precision and is not a better
// gate. Neither is fit to fail a build: a check that cries wolf gets deleted within a day
// and then the CEO is worse off than he is now. Two guards landed today were demoted to
// report-only on exactly this basis (file paths at 2.6% false positives, prose at 17%
// precision) and it was the right call both times.
//
// So part 5 prints its disagreements with the registry's recorded reason beside each, and
// the number, and returns success. Parts 1-4 are exact and fail the run.
//
// RUN IT:  node affordances.js      (or `npm test` in this directory, which discovers it)
//          RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node affordances.js

"use strict";

const path = require("path");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");
const { inventory, normalize } = require("./lib/state-strings");
const REGISTRY = require("./lib/state-registry");

const APP = "file://" + path.join(UI_DIR, "index.html");

const ACTION_CLASSES = ["ACTIONABLE", "NEEDS-SOMEONE-ELSE"];
const ALL_CLASSES = [
  "ACTIONABLE",
  "NEEDS-SOMEONE-ELSE",
  "INFORMATIONAL",
  "CONTROL",
  "FRAGMENT",
  "UNREACHABLE",
  "NOT-RENDERED",
];

/// A party the CEO can be pointed AT. Deliberately a small, closed set: the point is that a
/// future edit which deletes "whoever set RichOS up" from a NEEDS-SOMEONE-ELSE line fails
/// the suite rather than quietly leaving him with a fault and no owner.
const PARTY = /whoever set RichOS up|an operator|An operator|whoever installed RichOS/;

// ---------------------------------------------------------------------------------------
// Shell driving
// ---------------------------------------------------------------------------------------

/// The REAL shell — index.html, main.js, mock.js, style.css, timeline.js, all from disk,
/// with nothing stubbed but the Tauri bridge that mock.js already replaces.
///
/// `addInitScript` installs a property hook on `window.RichBridge` BEFORE mock.js assigns
/// it, so the test can (a) capture the listeners main.js registers and replay a
/// `rich://…` payload into them exactly as the Rust emitter would, and (b) override one
/// command's answer. Neither touches product code, and every handler that runs is the
/// shipping one.
async function openApp(browser, viewport) {
  const page = await browser.newPage({ viewport: viewport || { width: 1400, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.addInitScript(() => {
    let real = null;
    window.__listeners = {};
    window.__overrides = {};
    Object.defineProperty(window, "RichBridge", {
      configurable: true,
      get() {
        return real;
      },
      set(v) {
        real = v;
        const origListen = v.listen.bind(v);
        const origInvoke = v.invoke.bind(v);
        v.listen = function (name, cb) {
          (window.__listeners[name] = window.__listeners[name] || []).push(cb);
          return origListen(name, cb);
        };
        v.invoke = function (cmd, args) {
          if (Object.prototype.hasOwnProperty.call(window.__overrides, cmd)) {
            const o = window.__overrides[cmd];
            return o && o.reject ? Promise.reject(o.value) : Promise.resolve(o ? o.value : undefined);
          }
          return origInvoke(cmd, args);
        };
      },
    });
    window.__emit = function (name, payload) {
      for (const cb of window.__listeners[name] || []) cb({ event: name, payload });
    };
  });
  await page.goto(APP);
  await page.waitForFunction("typeof window.RichTimeline === 'object'");
  await page.waitForSelector(".nav-thread", { state: "attached" });
  const railHidden = await page.evaluate(() => {
    const r = document.getElementById("rail");
    return getComputedStyle(r).display === "none" || document.body.classList.contains("rail-closed");
  });
  if (railHidden) await page.click("#rail-toggle");
  await page.waitForSelector(".nav-thread", { state: "visible" });
  page.__errors = errors;
  return page;
}

/// EVERYTHING A READER CAN READ on this screen, normalised the way the inventory is: the
/// rendered text, plus the placeholders, titles and accessible names of visible elements.
/// A state that lives in a `placeholder` ("Send is off for this thread") is as visible to
/// the CEO as one in a paragraph, and a check that only read `innerText` would report it
/// absent and pass by accident.
async function readableText(page) {
  const raw = await page.evaluate(() => {
    const seen = [];
    const visible = (e) => {
      const r = e.getBoundingClientRect();
      const s = getComputedStyle(e);
      return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none";
    };
    for (const e of document.querySelectorAll("*")) {
      if (!visible(e)) continue;
      for (const a of ["placeholder", "title", "aria-label"]) {
        const v = e.getAttribute(a);
        if (v) seen.push(v);
      }
    }
    seen.push(document.body.innerText || "");
    return seen.join("\n");
  });
  return normalize(raw);
}

/// Is the named control PRESENT, VISIBLE, ENABLED and actually interactive?
///
/// "Interactive" is checked rather than assumed: a `<p>` matching the selector would
/// satisfy a naive querySelector and satisfy nobody else. A link to a doc is not an
/// affordance either — an `<a href>` counts only if it goes somewhere in the app, and today
/// nothing in this registry names one.
async function findControl(page, selector) {
  return page.evaluate((sel) => {
    const INTERACTIVE = ["BUTTON", "INPUT", "TEXTAREA", "SELECT"];
    const els = Array.from(document.querySelectorAll(sel));
    const out = { found: els.length, visible: 0, enabled: 0, interactive: 0, sample: null };
    for (const e of els) {
      const r = e.getBoundingClientRect();
      const s = getComputedStyle(e);
      const vis =
        r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none" && !e.hidden;
      if (!vis) continue;
      out.visible++;
      if (e.disabled === true || e.getAttribute("aria-disabled") === "true") continue;
      out.enabled++;
      const interactive =
        INTERACTIVE.indexOf(e.tagName) >= 0 ||
        e.getAttribute("role") === "button" ||
        (e.tagName === "A" && e.hasAttribute("href")) ||
        e.hasAttribute("tabindex");
      if (!interactive) continue;
      out.interactive++;
      if (!out.sample) out.sample = e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") + (e.className ? "." + String(e.className).split(/\s+/)[0] : "");
    }
    return out;
  }, selector);
}

/// THE CHECK, as one function, so the positive control below exercises the same code path
/// the real assertions do rather than a re-implementation of it.
async function assertAffordance(page, entry, opts) {
  opts = opts || {};
  if (opts.requireText) {
    const text = await readableText(page);
    assert(
      text.indexOf(entry.s) >= 0,
      "the state does not render in this fixture: " + JSON.stringify(entry.s.slice(0, 70) + "…")
    );
  }
  // A row with no control is a deliberate claim — INFORMATIONAL, or a NEEDS-SOMEONE-ELSE
  // state where there is genuinely nothing to press. Part 2 has already refused that
  // combination for ACTIONABLE, so reaching here without a control means the only thing
  // left to prove is that the sentence renders at all.
  if (!entry.control) return "(no control by design)";
  const c = await findControl(page, entry.control);
  assert(
    c.found > 0,
    "ACTIONABLE state renders with NO control in the DOM at all.\n" +
      "          state:   " + JSON.stringify(entry.s.slice(0, 80)) + "\n" +
      "          control: " + entry.control
  );
  assert(
    c.visible > 0,
    "ACTIONABLE state names a control that is in the DOM but NOT VISIBLE — a sentence " +
      "pointing at something the CEO cannot see is worse than silence.\n" +
      "          state:   " + JSON.stringify(entry.s.slice(0, 80)) + "\n" +
      "          control: " + entry.control
  );
  assert(
    c.enabled > 0,
    "ACTIONABLE state names a control that is visible but DISABLED.\n" +
      "          state:   " + JSON.stringify(entry.s.slice(0, 80)) + "\n" +
      "          control: " + entry.control
  );
  assert(
    c.interactive > 0,
    "the named control is not something anyone can press — no button, field, link or " +
      "role=button matched.\n" +
      "          state:   " + JSON.stringify(entry.s.slice(0, 80)) + "\n" +
      "          control: " + entry.control
  );
  return c.sample;
}

// ---------------------------------------------------------------------------------------
// Fixtures — each one drives the REAL shell into one state
// ---------------------------------------------------------------------------------------

const TURN = "turn_ok";
const THREAD = "thr_fem";

/// A `get_timeline` snapshot in the exact wire shape, with one CEO message and a duration
/// row in `state`. `working` with no live turn is §14's unknown outcome; `interrupted` is
/// §5.5's failure.
function snapshotWithDuration(state, activeMs) {
  const b = (id, extra) =>
    Object.assign(
      {
        id,
        entityId: "femcboost",
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
  return {
    entityId: "femcboost",
    threadId: THREAD,
    mode: "ceo",
    bindingRevision: 1,
    items: [
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
        state,
        startedAt: 1787948100000,
        endedAt: activeMs === null ? null : 1787948100000 + activeMs,
        activeMs,
      }),
    ],
  };
}

/// Force the next thread open to load a crafted snapshot through the shell's OWN reload
/// path (`loadTimeline` -> `get_timeline` -> `applySnapshot`), then click a thread.
async function loadSnapshot(page, snap) {
  await page.evaluate((s) => {
    window.__overrides.get_timeline = { value: s };
  }, snap);
  await page.click('.nav-thread[data-thread-id="hiring"]');
  await page.waitForSelector(".tl-turn");
}

const FIXTURES = {
  /// The app as it opens. Proves the controls that the voice instructions NAME are on the
  /// screen those instructions render on.
  async shell(browser) {
    return openApp(browser);
  },

  /// §21 entity binding failure: the seeded `legacy` thread has `entity_id: null`, and the
  /// mock's `get_timeline` refuses it exactly as the real command does.
  async unbound(browser) {
    const page = await openApp(browser);
    await page.click('.nav-thread[data-thread-id="legacy"]');
    await page.waitForSelector("#unbound-view:not([hidden])");
    return page;
  },

  /// §14: a turn still `working` on disk with nothing live for it in this session.
  async "unknown-turn"(browser) {
    const page = await openApp(browser);
    await loadSnapshot(page, snapshotWithDuration("working", null));
    await page.waitForSelector(".tl-intervention--quiet");
    return page;
  },

  /// §5.5: a turn that ended without finishing, AND the §18 announcement that goes with it.
  /// The announcement is replayed through the shipping `rich://turn-status` handler rather
  /// than written into #live-region, because the thing worth proving is that when the app
  /// says "Rich stopped before finishing" to a screen reader, the card's control is in the
  /// DOM beside it — and only the real handler decides whether that sentence is said at all.
  async "failed-turn"(browser) {
    const page = await openApp(browser);
    await loadSnapshot(page, snapshotWithDuration("interrupted", 461000));
    await page.waitForSelector(".tl-intervention:not(.tl-intervention--quiet)");
    // The binding is read OFF the model rather than typed here, because §13's fence is real:
    // an event whose entityId/threadId do not match is rejected, and a hand-typed payload
    // that silently fails the fence would make this fixture prove nothing.
    await page.evaluate((t) => {
      const m = window.__RICHOS_TIMELINE__();
      window.__emit("rich://turn-status", {
        entityId: m.entityId,
        threadId: m.threadId,
        bindingRevision: m.bindingRevision,
        turnId: t,
        status: "failed",
      });
    }, TURN);
    await page.waitForFunction(() =>
      (document.getElementById("live-region").textContent || "").length > 0
    );
    return page;
  },

  /// `create_thread_in` refuses on the first send in a draft thread. Driven the way the CEO
  /// gets there: open an entity area, type, press Enter.
  async "thread-create-refused"(browser) {
    const page = await openApp(browser);
    await page.click(".nav-group-label");
    await page.waitForSelector("#entity-view:not([hidden])");
    await page.evaluate(() => {
      window.__overrides.create_thread_in = { reject: true, value: "scope mismatch on thread thr_x" };
    });
    await page.fill("#input", "start the Acme workstream");
    await page.press("#input", "Enter");
    await page.waitForSelector("#composer-blocked:not([hidden])");
    return page;
  },

  /// The mic is open and healthy and delivering nothing. `start_voice_capture` is unwired
  /// in the mock, so it is overridden to resolve — and then the panel's state comes from
  /// the SHIPPING `rich://voice-state` handler, replayed with the payload shape main.js's
  /// own contract comment documents. Nothing about the row is set by this test.
  async "voice-no-audio"(browser) {
    const page = await openApp(browser);
    await page.evaluate(() => {
      window.__overrides.start_voice_capture = { value: {} };
    });
    await page.click("#talk-toggle");
    await page.waitForSelector("#voice-panel:not([hidden])");
    await page.evaluate(() => {
      window.__emit("rich://voice-state", { state: "hearing", level: 0, noAudio: true, at: Date.now() });
    });
    await page.waitForSelector("#voice-state-no-audio:not([hidden])");
    return page;
  },

  /// A live turn, from the mock's own `simulateSlowTurn`, with words in the composer — the
  /// §9.2 mode where Stop and Send are both up.
  async "working-turn"(browser) {
    const page = await openApp(browser);
    await page.evaluate(() => window.__RICHOS_MOCK__.simulateSlowTurn(null, "run the numbers", 200));
    await page.waitForSelector('#composer-row[data-mode="working"]');
    await page.fill("#input", "and check the Q4 line");
    await page.waitForSelector("#send:not([hidden])");
    return page;
  },

  /// §3.5 entity overview, reached the way the CEO reaches it.
  async "entity-view"(browser) {
    const page = await openApp(browser);
    await page.click(".nav-group-label");
    await page.waitForSelector("#entity-view:not([hidden])");
    return page;
  },

  /// §3.4 search with no hits.
  async "search-empty"(browser) {
    const page = await openApp(browser);
    await page.click("#nav-search");
    await page.waitForSelector("#search-overlay:not([hidden])");
    await page.fill("#search-input", "zzzqqqxyzzy");
    await page.waitForSelector("#search-empty:not([hidden])");
    return page;
  },

  /// The lease is down. The mock's `_notConnected` switch rejects `send_message` before any
  /// turn starts, which is what main.rs does when `lease_ready` is false — so this is the
  /// real refusal path through the real send handler, started by typing and pressing Enter.
  async "not-connected"(browser) {
    const page = await openApp(browser);
    await page.evaluate(() => window.__RICHOS_MOCK__.setNotConnected(true));
    await page.fill("#input", "book the Acme call for Thursday");
    await page.press("#input", "Enter");
    await page.waitForFunction(() =>
      (document.getElementById("messages").innerText || "").includes("back in the box below")
    );
    return page;
  },

  /// The rail's status marks. Nothing is driven: the seeded `legacy` thread carries the
  /// `unbound` mark on load, and the structural claim is checked over every mark present.
  async "rail-mark"(browser) {
    return openApp(browser);
  },
};

/// Which fixtures actually put the state's own words on screen. `shell` does not — the
/// voice `ceo_message()` lines need a real CaptureError from a live audio device — so for
/// those the suite proves the weaker, still-worth-proving thing: the control the sentence
/// names is present and usable on the screen the sentence appears on. Said here rather than
/// left as an unexplained asymmetry.
const TEXT_RENDERING_FIXTURES = new Set([
  "unbound",
  "unknown-turn",
  "failed-turn",
  "voice-no-audio",
  "not-connected",
  "search-empty",
  "entity-view",
  "thread-create-refused",
]);

// ---------------------------------------------------------------------------------------
// The heuristic second opinion (part 5)
// ---------------------------------------------------------------------------------------

/// Does this string READ like a request, whatever the registry calls it? Text only — it
/// never consults the classification, which is the whole point of a second opinion.
const READS_ACTIONABLE = [
  /\b(check|try|press|tap|click|plug|quit|restart|launch|install|enable|choose|pick|set)\b/i,
  /\byou (can|could|need|must|should|'ll need)\b/i,
  /\b(not connected|unavailable|offline|not signed in|update available|restart required|will sync|waiting for you|pending)\b/i,
  /\bsay (it|the word) again\b/i,
];

function readsActionable(s) {
  return READS_ACTIONABLE.some((re) => re.test(s));
}

// ---------------------------------------------------------------------------------------

async function main() {
  const run = createRun("the affordance rule — a state the user could change renders its control");

  const inv = inventory();
  const byString = new Map(REGISTRY.map((r) => [r.s, r]));

  // ---- PART 1: the inventory and the registry agree ------------------------------------

  await run.check("NEGATIVE CONTROL: the scrape examined a real corpus, not an empty one", async () => {
    assert(
      inv.length >= 50,
      "the derived inventory is " + inv.length + " states — that is not a scrape of this UI, " +
        "it is a broken scrape reporting green over nothing. This session already caught one " +
        "scanner reporting CLEAN because its corpus was empty."
    );
    // A sentinel that must always be there: index.html's own first-run voice footnote.
    const sentinel = "I can't hear anything. Check your mic isn't muted, then try again.";
    assert(
      inv.some((r) => r.normal === sentinel),
      "the sentinel state is missing from the inventory — the extractor is not reading index.html"
    );
    return inv.length + " states derived from index.html, main.js, timeline.js and the Rust bridge scrape";
  });

  await run.check("every derived state is classified, and every classification is a real state", async () => {
    const invSet = new Set(inv.map((r) => r.normal));
    const unclassified = inv.filter((r) => !byString.has(r.normal));
    const stale = REGISTRY.filter((r) => !invSet.has(r.s));
    assertEqual(
      unclassified.map((r) => r.normal + "   <- " + r.sites.join(" ")),
      [],
      "NEW USER-VISIBLE STATE, NOT CLASSIFIED. Add a row to lib/state-registry.js saying " +
        "whether the CEO can act on it. If he can, it needs a control in the same view."
    );
    assertEqual(
      stale.map((r) => r.s),
      [],
      "the registry classifies a string the product no longer renders — delete the row"
    );
    assertEqual(REGISTRY.length, inv.length, "registry and inventory must be the same size");
    return inv.length + "/" + inv.length + " classified, 0 unclassified, 0 stale";
  });

  await run.check("no duplicate rows, and every class is one of the declared buckets", async () => {
    const seen = new Set();
    for (const r of REGISTRY) {
      assert(!seen.has(r.s), "duplicate registry row: " + JSON.stringify(r.s.slice(0, 60)));
      seen.add(r.s);
      assert(ALL_CLASSES.indexOf(r.c) >= 0, "unknown class " + r.c + " on " + JSON.stringify(r.s.slice(0, 60)));
      assert(typeof r.why === "string" && r.why.length > 12, "every row states its reasoning: " + r.s.slice(0, 60));
    }
    const counts = {};
    for (const r of REGISTRY) counts[r.c] = (counts[r.c] || 0) + 1;
    return ALL_CLASSES.map((c) => c + " " + (counts[c] || 0)).join(", ");
  });

  // ---- PART 2: the rule, statically -----------------------------------------------------

  await run.check("THE RULE: every ACTIONABLE state names a control", async () => {
    const bare = REGISTRY.filter((r) => r.c === "ACTIONABLE" && !r.control);
    assertEqual(
      bare.map((r) => r.s),
      [],
      "an ACTIONABLE state with no control is the defect this suite exists for: a state the " +
        "user could change, rendered apart from the thing that changes it"
    );
    return REGISTRY.filter((r) => r.c === "ACTIONABLE").length + " ACTIONABLE states, each naming a control";
  });

  await run.check("every NEEDS-SOMEONE-ELSE state names the party, or names what explains it", async () => {
    const orphaned = REGISTRY.filter(
      (r) => r.c === "NEEDS-SOMEONE-ELSE" && !r.explainedBy && !PARTY.test(r.s)
    );
    assertEqual(
      orphaned.map((r) => r.s.slice(0, 90)),
      [],
      "a state the CEO cannot fix must say WHO can. Either the sentence names a party " +
        "(" + PARTY.source + ") or the row points at the state in the same view that does."
    );
    const withParty = REGISTRY.filter((r) => r.c === "NEEDS-SOMEONE-ELSE" && PARTY.test(r.s)).length;
    const viaExplainer = REGISTRY.filter((r) => r.c === "NEEDS-SOMEONE-ELSE" && r.explainedBy).length;
    return withParty + " name a party in the sentence, " + viaExplainer + " are explained by a state beside them";
  });

  await run.check("no INFORMATIONAL state is secretly an instruction", async () => {
    // The narrow half of the heuristic: a bare second-person imperative aimed at the reader.
    // An INFORMATIONAL row is a promise that there is nothing to do, and "Press …" breaks it.
    const IMPERATIVE = /(^|[.;:]\s+)(press|tap|click|check|plug|quit|restart|sign in|type in)\b/i;
    const liars = REGISTRY.filter((r) => r.c === "INFORMATIONAL" && IMPERATIVE.test(r.s));
    assertEqual(
      liars.map((r) => r.s.slice(0, 90)),
      [],
      "an INFORMATIONAL state that issues an instruction is mis-classified — it is ACTIONABLE " +
        "and owes a control"
    );
    return REGISTRY.filter((r) => r.c === "INFORMATIONAL").length + " INFORMATIONAL states, none issuing an instruction";
  });

  // ---- PART 3: the control is really on screen ------------------------------------------

  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  let statesChecked = 0;

  // Every row that names a fixture, INCLUDING the ones with no control. A
  // NEEDS-SOMEONE-ELSE state with nothing to press still has to actually render the
  // sentence that names the party — otherwise the registry is describing a screen nobody
  // has seen.
  const needFixture = REGISTRY.filter((r) => r.fixture);
  const byFixture = new Map();
  for (const r of needFixture) {
    if (!byFixture.has(r.fixture)) byFixture.set(r.fixture, []);
    byFixture.get(r.fixture).push(r);
  }

  for (const [name, entries] of byFixture) {
    await run.check(
      `[${name}] ${entries.length} state(s) render with a usable control`,
      async () => {
        assert(FIXTURES[name], "no fixture named " + name);
        const page = await FIXTURES[name](browser);
        const requireText = TEXT_RENDERING_FIXTURES.has(name);
        const samples = [];
        for (const entry of entries) {
          const sample = await assertAffordance(page, entry, { requireText });
          samples.push(entry.control ? entry.control + " -> " + sample : sample);
          statesChecked++;
        }
        assert(
          page.__errors.length === 0,
          "the shell logged errors while in this state: " + page.__errors.join(" | ")
        );
        await page.close();
        return (requireText ? "state text asserted present; " : "control-presence only (state needs live hardware); ") +
          Array.from(new Set(samples)).join(", ");
      }
    );
  }

  await run.check("NEGATIVE CONTROL: the browser half examined a non-zero number of states", async () => {
    assert(
      statesChecked >= 20,
      "only " + statesChecked + " states were checked in a real DOM. A suite that verifies " +
        "nothing and reports green is the failure this session has already caught twice — once " +
        "in a scanner with an empty corpus, once in a reporting layer whose fixtures lacked a field."
    );
    return statesChecked + " states asserted against the real DOM under WebKit";
  });

  await run.check("the §21 way out actually goes somewhere", async () => {
    const page = await FIXTURES.unbound(browser);
    await page.click("#unbound-new-thread");
    await page.waitForSelector("#entity-picker:not([hidden])");
    const n = await page.evaluate(() => document.querySelectorAll("#entity-picker .picker-item").length);
    assert(n > 0, "the picker opened with no entities in it — the button leads nowhere");
    await page.close();
    return "#unbound-new-thread opens the §3.3 picker with " + n + " entities, defaulting to none";
  });

  await run.check("a rail status mark can never render outside the control that acts on it", async () => {
    const page = await FIXTURES["rail-mark"](browser);
    const r = await page.evaluate(() => {
      const marks = Array.from(document.querySelectorAll(".nav-status"));
      return {
        total: marks.length,
        inButton: marks.filter((m) => m.closest("button.nav-thread")).length,
      };
    });
    assert(r.total > 0, "no status marks rendered — this check would pass by finding nothing");
    assertEqual(r.inButton, r.total, "a status mark rendered outside a thread button");
    await page.close();
    return r.total + "/" + r.total + " marks are inside the button that opens their thread";
  });

  await run.check("a refused send leaves no ghost bubble claiming the message went", async () => {
    const page = await FIXTURES["not-connected"](browser);
    const r = await page.evaluate(() => ({
      userBubbles: document.querySelectorAll(".tl-user").length,
      pending: window.__RICHOS_TIMELINE__().pendingUser.length,
      composer: document.getElementById("input").value,
      sendVisible: !document.getElementById("send").hidden,
    }));
    assertEqual(r.userBubbles, 0, "the withdrawn bubble is still on screen, looking like a sent message");
    assertEqual(r.pending, 0, "the model still holds a pending user message that will never be adopted");
    assertEqual(r.composer, "book the Acme call for Thursday", "the CEO's words were not returned to the box");
    assert(r.sendVisible, "the notice names Send and Send is hidden");
    await page.close();
    return "bubble withdrawn, words restored verbatim, Send up";
  });

  await run.check(
    "mock.js rehearses the SAME lease-down sentence the product ships",
    async () => {
      const fs = require("fs");
      const rust = fs.readFileSync(path.join(UI_DIR, "..", "src-tauri", "src", "main.rs"), "utf8");
      const mock = fs.readFileSync(path.join(UI_DIR, "mock.js"), "utf8");
      const entry = REGISTRY.find((r) => r.s.indexOf("I'm not connected to my thinking") === 0);
      assert(entry, "the lease-down state is missing from the registry");
      assert(rust.indexOf("LEASE_UNAVAILABLE_MESSAGE") > 0, "the Rust const is gone");
      assert(
        normalize(mock).indexOf(entry.s) >= 0,
        "app/ui/mock.js still rehearses a lease-down sentence the product no longer says. The " +
          "browser preview would teach the CEO one thing and the app another."
      );
      return "the const, the registry and the preview all carry one sentence";
    }
  );

  // ---- PART 4: the positive control -----------------------------------------------------

  await run.check(
    "POSITIVE CONTROL: an ACTIONABLE state with no affordance IS flagged",
    async () => {
      const page = await browser.newPage();
      await page.setContent(
        "<!doctype html><html><body><p id=liar>Not connected — check the thing and try again.</p></body></html>"
      );
      const fake = {
        s: "Not connected — check the thing and try again.",
        c: "ACTIONABLE",
        control: "#a-button-that-does-not-exist",
      };
      let threw = null;
      try {
        await assertAffordance(page, fake, { requireText: true });
      } catch (e) {
        threw = e.message;
      }
      await page.close();
      assert(threw, "the checker PASSED a state that renders with no control — it proves nothing");
      assert(
        threw.indexOf("NO control") >= 0,
        "flagged, but for the wrong reason: " + threw
      );
      return "flagged: " + threw.split("\n")[0];
    }
  );

  await run.check(
    "POSITIVE CONTROL: a control that exists but is hidden IS flagged",
    async () => {
      const page = await browser.newPage();
      await page.setContent(
        "<!doctype html><html><body><p>Not connected — press Fix.</p>" +
          "<button id=fix hidden>Fix</button></body></html>"
      );
      let threw = null;
      try {
        await assertAffordance(page, { s: "Not connected — press Fix.", c: "ACTIONABLE", control: "#fix" }, {});
      } catch (e) {
        threw = e.message;
      }
      await page.close();
      assert(threw && threw.indexOf("NOT VISIBLE") >= 0, "a hidden control passed the check: " + threw);
      return "flagged: " + threw.split("\n")[0];
    }
  );

  await run.check(
    "POSITIVE CONTROL: a paragraph dressed as a control IS flagged",
    async () => {
      const page = await browser.newPage();
      await page.setContent(
        "<!doctype html><html><body><p>Not connected — see the docs.</p>" +
          "<p id=fix>Read the documentation</p></body></html>"
      );
      let threw = null;
      try {
        await assertAffordance(page, { s: "x", c: "ACTIONABLE", control: "#fix" }, {});
      } catch (e) {
        threw = e.message;
      }
      await page.close();
      assert(threw && threw.indexOf("not something anyone can press") >= 0, "prose passed as a control: " + threw);
      return "flagged: " + threw.split("\n")[0];
    }
  );

  await run.check("POSITIVE CONTROL: an unclassified new state IS flagged", async () => {
    // The drift comparator, run against a corpus with one extra string, so the part-1 check
    // is proven able to fail rather than merely observed passing.
    const fakeInv = inv.concat([{ normal: "A brand new thing the CEO must go and do.", sites: ["fake.js:1"] }]);
    const unclassified = fakeInv.filter((r) => !byString.has(r.normal));
    assertEqual(
      unclassified.map((r) => r.normal),
      ["A brand new thing the CEO must go and do."],
      "the drift comparator did not notice an unclassified state"
    );
    return "the comparator names the exact string and its site";
  });

  await browser.close();

  // ---- PART 5: the heuristic second opinion — REPORT ONLY --------------------------------

  // Only strings the registry knows. An UNCLASSIFIED string means part 1 has already
  // failed and named it; part 5 must not crash on the way to reporting that — a reporting
  // layer that dies before it prints the verdict is how a check goes silently dead, which
  // this session has already caught once.
  const flagged = inv.map((r) => r.normal).filter((s) => byString.has(s) && readsActionable(s));
  const genuine = flagged.filter((s) => ACTION_CLASSES.indexOf(byString.get(s).c) >= 0);
  const allAction = REGISTRY.filter((r) => ACTION_CLASSES.indexOf(r.c) >= 0);
  const precision = (100 * genuine.length / flagged.length).toFixed(1);
  const recall = (100 * genuine.length / allAction.length).toFixed(1);

  const failed = run.report();

  console.log("\n== part 5: heuristic second opinion — REPORT ONLY, and here is why ==");
  console.log(
    `  flagged ${flagged.length}, genuinely ACTIONABLE or NEEDS-SOMEONE-ELSE ${genuine.length}` +
      `  ->  precision ${precision}%, recall ${recall}%`
  );
  console.log(
    "  Roughly one flag in three is noise and it misses nearly half the real ones, so it does"
  );
  console.log(
    "  NOT fail the run. A check that cries wolf is deleted within a day, and then nothing runs."
  );
  const disagreements = flagged.filter((s) => ACTION_CLASSES.indexOf(byString.get(s).c) < 0);
  console.log(`  ${disagreements.length} disagreement(s) with the registry, each with its recorded reason:`);
  for (const s of disagreements) {
    const r = byString.get(s);
    console.log(`    [${r.c}] ${JSON.stringify(s.slice(0, 74))}`);
    console.log(`           ${r.why.slice(0, 110)}`);
  }

  console.log(
    failed
      ? `\n${failed} check(s) FAILED — an actionable state is rendering without its control.`
      : "\nthe affordance rule holds."
  );
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

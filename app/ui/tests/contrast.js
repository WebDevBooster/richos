// THE CONTRAST FLOOR, ENFORCED — the standing rule in `CLAUDE.md` §"Contrast — WCAG AA,
// ALWAYS, BOTH THEMES", turned from a sentence into something that can fail.
//
// The CEO's order was: stop having to say this. It was answered by writing the rule into
// `CLAUDE.md` and into fifteen agent definitions, which is exactly the shape of answer that
// does not work — a rule written into a prompt is a request, and a request is complied with
// at whatever rate people comply with requests. The four light-mode failures that provoked
// the order (2.95, 2.95, 3.15, 3.60 against a floor of 4.5) were each produced by someone
// who had already been told the rule and who looked at the result and thought it looked
// fine. An eye adapts to the palette it has been staring at. Arithmetic does not.
//
// So this suite computes the ratio. Every visible run of text on the shipping shell, every
// non-text indicator, against the colours actually painted behind it, in both themes.
//
// THE EXEMPTION IS THE LOAD-BEARING PART, and getting it wrong is how this file dies. The
// standing rule exempts text deliberately not meant to be read closely — a privacy notice,
// legal boilerplate, fine print — and nothing else. A checker that ignored that would flag
// the whole of any legal footer, and a checker that flags what everybody already decided is
// fine gets muted inside a week; a muted checker's green is worse than no checker, because
// it converts "nobody looked" into "something looked and it was fine". So the exemption is
// MACHINE-READABLE: `data-contrast-exempt="<why this text is not meant to be read closely>"`
// in the shipped markup. A declared exemption passes AND IS PRINTED, with its reason, in the
// report of every run. An undeclared one fails. That inverts the CEO's declaration
// requirement into the enforcement mechanism: the only way to be excused is to say so where
// a reviewer reads it, and the count of exemptions becomes a number that can be watched for
// creep — check 12 prints it.
//
// AN UNRESOLVABLE COLOUR IS A FAILURE TO PROVE, NEVER A PASS. Gradients, blend modes,
// `background-clip: text`, an unparseable colour notation, a panel painted over the node:
// each one is a place a lazy implementation returns "fine". Check 7 introduces one of each
// into a live page and asserts the walk refuses all of them.
//
// WHAT THIS GATE COVERS AND WHAT IT CANNOT — the honest boundary, asserted rather than
// promised:
//
//   COVERS   the thirteen driven surfaces below (shell, an open thread, the correction desk, the
//            feedback desk, search, the inspector, the technical view, the unbound-thread
//            pane, the assertiveness popover, THE UPDATE ROW IN THREE STATES, and the
//            opening screen with its curtain held up), both themes, text and the bounded
//            non-text-indicator subset check 3 defines. The three `updates-*` surfaces are
//            also the first drivers to reach the UNIVERSAL settings menu at all — the
//            `settings` surface drives the RAIL's preferences popover, which is a different
//            menu — and their first run found a shipped 1.24:1 indicator in it. The opening screen is WALKED and its one HTML line comes back
//            UNPROVABLE — see `knownUnresolvable` in contrast-debt.json. That is a stated
//            blind spot with a name on it, which is not the same thing as coverage.
//   CANNOT   `<canvas>` — no computed style to read. The shipping shell contains none, and
//            check 14 asserts that, so the day one lands the assertion is what tells you.
//            The round-7 and round-8.1 material studies ARE canvas-heavy and NOTHING here
//            says anything about them. "We have a contrast check now" does not cover canvas.
//   CANNOT   SVG `fill`/`stroke`. The opening screen is almost entirely SVG — check 10
//            counts what it therefore does not measure and prints the number.
//   CANNOT   states no driver reaches: the voice panel mid-listen, the drill-down slideover,
//            the between-turns strip, streaming mid-flight. Named, not hidden.
//
// A NOTE ON THE DEBT LEDGER, because it is the one thing here that could be mistaken for a
// weakened threshold. It is not. The threshold is 4.5/3.0 and never moves; every failure is
// computed, named and printed with its ratio on every run. `contrast-debt.json` records what
// the shipping app was ALREADY failing the day the gate was built, so that a red run means
// "someone made this worse today" rather than "this repository has old debt", which is the
// signal a developer learns to ignore. A signature not in the ledger fails. A signature in
// the ledger whose ratio got worse fails. The ledger's size is capped at what it was
// committed with, so it can only shrink.
//
// EVERY CHECK HERE WAS RUN RED ONCE by breaking the shipped source; the mutations are listed
// against their check numbers at the bottom of this file.
//
// Run: node contrast.js   (or `npm test` for every suite in this directory)
//      RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node contrast.js

"use strict";

const fs = require("fs");
const path = require("path");
const { loadPlaywright, shot, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");
const C = require("./lib/contrast");

const APP = "file://" + path.join(UI_DIR, "index.html");
const SHOTS = path.join(__dirname, "shots-contrast");
const DEBT_FILE = path.join(__dirname, "contrast-debt.json");
const CSS_FILES = [path.join(UI_DIR, "style.css"), path.join(UI_DIR, "splash.css")];
const SOURCE_FILES = [
  path.join(UI_DIR, "index.html"),
  path.join(UI_DIR, "main.js"),
  path.join(UI_DIR, "timeline.js"),
  path.join(UI_DIR, "splash.js"),
];

const THEMES = ["light", "dark"];

// ---------------------------------------------------------------------------------------
// The surfaces. A driver's job is to put the app into a state and RETURN — the walk is the
// same everywhere, which is what makes adding a surface one entry rather than one suite.
// ---------------------------------------------------------------------------------------

const SURFACES = [
  {
    name: "shell",
    what: "the shell as it opens: rail, scope line, first turn, composer",
    drive: async () => {},
  },
  {
    name: "thread",
    what: "a seeded conversation with a settled turn and a delegation summary",
    drive: async (p) => {
      await p.click('.nav-thread[data-thread-id="hiring"]');
      await p.waitForSelector(".tl-turn");
      await p.waitForTimeout(400);
    },
  },
  {
    name: "corrections",
    what: "the correction desk, both families, with two asks waiting",
    drive: async (p) => {
      await p.click("#nav-corrections");
      await p.waitForSelector("#corrections-overlay:not([hidden])");
      await p.waitForTimeout(400);
    },
  },
  {
    name: "feedback",
    what: "the feedback desk as it first opens",
    drive: async (p) => {
      await p.click("#nav-feedback");
      await p.waitForSelector("#feedback-overlay:not([hidden])");
      await p.waitForTimeout(400);
    },
  },
  {
    name: "search",
    what: "search with results, including the selected row",
    drive: async (p) => {
      await p.keyboard.press("Meta+k");
      await p.waitForSelector("#search-overlay:not([hidden])");
      await p.fill("#search-input", "a");
      await p.waitForTimeout(400);
    },
  },
  {
    name: "inspector",
    what: "the worker inspector open over an expanded transcript",
    drive: async (p) => {
      await p.click('.nav-thread[data-thread-id="hiring"]');
      await p.waitForSelector(".tl-duration-btn");
      await p.click(".tl-duration-btn");
      await p.waitForSelector(".tl-chip");
      await p.click(".tl-chip");
      await p.waitForSelector("#inspector:not([hidden])");
      await p.waitForTimeout(400);
    },
  },
  {
    name: "technical-view",
    what: "the technical view pinned on for one conversation (§3.3)",
    drive: async (p) => {
      await p.click('.nav-thread[data-thread-id="hiring"]');
      await p.waitForTimeout(300);
      await p.keyboard.press("Meta+Shift+T");
      await p.waitForTimeout(500);
    },
  },
  {
    name: "unbound",
    what: "the refusal pane for a thread that predates entity scoping (§21)",
    drive: async (p) => {
      await p.click('.nav-thread[data-thread-id="legacy"]');
      await p.waitForTimeout(600);
    },
  },
  {
    name: "settings",
    what: "the assertiveness popover",
    drive: async (p) => {
      await p.click("#rail-settings");
      await p.waitForSelector("#assertiveness-popover:not([hidden])");
      await p.waitForTimeout(300);
    },
  },
  // THE UPDATE ROW, IN THREE STATES, because one state cannot paint the colours the others
  // do (RICH-TODOs row 12, `app/ui/updates.js`). It lives in the UNIVERSAL settings menu —
  // which the `settings` surface above does NOT reach, since that one drives the rail's
  // preferences popover — so without these three drivers the whole surface would be
  // uncovered while a nearby surface's name suggested otherwise.
  //
  // Between them they paint every colour the row can: `--attention` and the primary button
  // and the mark on the settings button (available), the progress fill and its track border
  // (downloading), `--danger` and the disclosure and the verbatim vendor detail (failed).
  {
    name: "updates-available",
    what: "the update row with a version waiting, and the mark on the settings button",
    drive: async (p) => {
      await p.evaluate(() =>
        window.__RICHOS_MOCK__.updateSet({
          state: "available", currentVersion: "0.1.0", availableVersion: "0.1.1",
          notes: "Faster launch, and the technical view remembers its width.",
          pubDate: "2026-08-31T12:00:00Z", downloadedBytes: 0, totalBytes: null, percent: null,
          failure: null, endpoint: "https://updates.example.com/darwin/aarch64/0.1.0",
          endpointIsPlaceholder: false, checkedAt: Date.now() - 120000,
        })
      );
      await p.click("#set-btn");
      await p.waitForSelector("#set-menu", { state: "visible" });
      await p.waitForTimeout(400);
    },
  },
  {
    name: "updates-downloading",
    what: "the update row mid-download: the progress bar, its track and its border",
    drive: async (p) => {
      await p.evaluate(() =>
        window.__RICHOS_MOCK__.updateSet({
          state: "downloading", currentVersion: "0.1.0", availableVersion: "0.1.1",
          notes: null, pubDate: null, downloadedBytes: 5242880, totalBytes: 13631488, percent: 38,
          failure: null, endpoint: "https://updates.example.com/darwin/aarch64/0.1.0",
          endpointIsPlaceholder: false, checkedAt: Date.now() - 120000,
        })
      );
      await p.click("#set-btn");
      await p.waitForSelector("#set-menu", { state: "visible" });
      await p.waitForTimeout(400);
    },
  },
  {
    name: "updates-failed",
    what: "a REFUSED SIGNATURE, with the vendor's own reason disclosed",
    drive: async (p) => {
      await p.evaluate(() =>
        window.__RICHOS_MOCK__.updateSet({
          state: "failed", currentVersion: "0.1.0", availableVersion: "0.1.1",
          notes: null, pubDate: null, downloadedBytes: 13631488, totalBytes: 13631488, percent: 100,
          failure: {
            kind: "signature",
            headline: "This download was not signed by RichOS, so it was not installed.",
            detail: "Signature verification failed",
          },
          endpoint: "https://updates.example.com/darwin/aarch64/0.1.0",
          endpointIsPlaceholder: false, checkedAt: Date.now() - 60000,
        })
      );
      await p.click("#set-btn");
      await p.waitForSelector("#set-menu", { state: "visible" });
      await p.click("#update-why");
      await p.waitForTimeout(400);
    },
  },
  {
    name: "opening-screen",
    // THE HARDEST SURFACE, WALKED ANYWAY. It would have been easy to leave the opening
    // screen out and write "not covered" in the header — and the honest result of walking it
    // is that its one line of HTML text CANNOT BE PROVEN by this or any DOM checker: it sits
    // on `--splash-atmosphere`, a gradient, under a `mix-blend-mode: soft-light` lamp and a
    // `mix-blend-mode: overlay` grain. That fact is now a named entry in
    // `contrast-debt.json`'s `knownUnresolvable` rather than a surface nobody looked at,
    // which is the difference between a stated blind spot and an unstated one.
    holdSplash: true,
    what: "the opening screen, curtain held up (its one HTML text line; the rest is SVG)",
    drive: async (p) => {
      await p.waitForSelector("#splash", { timeout: 5000 });
      await p.waitForTimeout(700);
    },
  },
];

// ---------------------------------------------------------------------------------------
// Driving
// ---------------------------------------------------------------------------------------

async function openApp(browser, theme, holdSplash) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 950 }, colorScheme: theme });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });

  // DRIVE THE APP'S OWN THEME, NOT THE OS PREFERENCE — and this is the whole reason this
  // suite kept meaning something on the day dark mode landed.
  //
  // Until 2026-08-31 the app shipped ONE palette, so `colorScheme` on the page was a
  // reasonable stand-in for "the other theme": there was no other theme, and check 10 said
  // so out loud. Now there are two, and they are chosen by the CEO and stored in
  // `config.rs` — `:root[data-theme="light"]`, not `@media (prefers-color-scheme: dark)`.
  // An OS preference decides NOTHING about which palette this app paints.
  //
  // So had this line stayed as it was, both "themes" would have walked the DARK palette,
  // the light half of every check above would have been a re-run of the dark half, and the
  // suite would have reported a clean sweep of both themes while never once measuring light
  // mode — the precise failure mode check 10 was written to catch, arriving through the
  // door check 10 was not watching. `colorScheme` is still passed, because `system` resolves
  // against it and a theme-independent element that DID respond to the OS should still be
  // seen; but the app's own preference is what is set here.
  //
  // It is seeded into `localStorage` in an init script, which is to say through the exact
  // mirror `theme-boot.js` reads before first paint. Setting `data-theme` after load would
  // measure a state the shipping app never actually boots into.
  // BOTH the mirror and the STORE, and the second one is the one that decides. Seeding
  // `richos-theme` alone does not work and finding out why is worth the two lines: the
  // mirror is a cache, `syncAppearanceFromBackend` reconciles it against the backend at
  // init, and the BACKEND WINS — so a mirror-only seed is overwritten by the store's answer
  // a few hundred milliseconds after boot, and the walk measures the store's theme while
  // claiming the seed's. That is the product behaving exactly as designed. The test has to
  // seed the thing that actually holds the preference.
  await page.addInitScript((t) => {
    try {
      window.localStorage.setItem("richos-theme", t);
      window.localStorage.setItem("richos-font-scale", "100");
      window.localStorage.setItem(
        "richos-mock-config",
        JSON.stringify({ theme: t, font_scale: 100, user_name: null })
      );
    } catch (e) {
      /* storage unavailable: theme-boot falls back to the shipped default, which is dark */
    }
  }, theme);

  if (holdSplash) {
    // Hold the curtain deterministically rather than racing it. `main.js` calls
    // `RichSplash.yieldNow("app-ready")` the moment the shell is usable, which on this
    // machine is well inside a second — a walk that tried to be quick enough would be a
    // flake generator. Intercepting the ASSIGNMENT of `window.RichSplash` neuters the yield
    // before splash.js has finished installing itself, and touches nothing else: the
    // composition renders exactly as it ships.
    await page.addInitScript(() => {
      let real;
      Object.defineProperty(window, "RichSplash", {
        configurable: true,
        get: () => real,
        set: (v) => {
          real = v;
          if (v && typeof v.yieldNow === "function") v.yieldNow = function () {};
        },
      });
    });
  }
  await page.goto(APP);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  if (holdSplash) {
    // §15's always-dark clamp is in force for the whole of this walk, by ruling and not by
    // accident, so a light-labelled opening-screen walk correctly reports dark.
    assertTheme(await page.evaluate(() => document.documentElement.getAttribute("data-theme")), "dark", theme);
    page.__errors = errors;
    return page;
  }
  // The opening curtain is `pointer-events: none` and therefore invisible to a hit test
  // while still being painted over everything. Waiting for it to leave rather than racing
  // it: a walk taken underneath it would report the whole shell unresolvable.
  await page.waitForFunction(() => !document.getElementById("splash"), { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(300);
  // THE THEME IS CHECKED HERE AND NOT EARLIER, and the reason is a real one this assertion
  // caught the day the splash gained a duration. While the opening screen's curtain is up
  // the resolved theme is CLAMPED TO DARK (§15's one permanent exception), so a light walk
  // sampled before the curtain lifts reports dark — truthfully, and about a state this walk
  // is not measuring. Once the splash held for three seconds rather than for however long
  // booting took, that window stopped being too narrow to hit and every light walk failed.
  // The clamp drops with the curtain, so this is the first moment the answer is about the
  // palette the walk is actually going to measure.
  assertTheme(await page.evaluate(() => document.documentElement.getAttribute("data-theme")), theme, theme);
  page.__errors = errors;
  return page;
}

/// The seed either took or this walk is measuring something other than what it claims. A
/// silent miss here would relabel a dark walk as a light one, which is worse than no walk.
function assertTheme(painted, expected, asked) {
  assert(
    painted === expected,
    "asked for the " + asked + " theme and the document painted " + painted + " — the walk " +
      "below would be labelled with a palette it is not measuring"
  );
}

async function walk(page, surface, theme) {
  await page.evaluate(C.pageScript());
  return page.evaluate((o) => window.__contrastProbe(o), { surface, theme });
}

/// One line per failure, in the shape a person can act on without opening a debugger: the
/// ratio it got, the floor it needed, the two colours, the size, and where it is.
function describe(sig, f) {
  return (
    "      " + f.ratio + ":1 (needs " + f.threshold + ":1)  " + f.fg + " on " + f.bg +
    "  " + (f.indicator ? "non-text indicator" : f.fontSize + "px/" + f.fontWeight) +
    "  x" + f.nodes + "\n        " + f.selector + (f.text ? "   “" + f.text + "”" : "")
  );
}

// ---------------------------------------------------------------------------------------

async function main() {
  const run = createRun("WCAG AA contrast — the shipping shell, both themes, computed not eyeballed");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  fs.mkdirSync(SHOTS, { recursive: true });

  const debt = JSON.parse(fs.readFileSync(DEBT_FILE, "utf8"));
  /// Everything the whole run saw, so the cross-surface checks (11, 13) have real inputs
  /// rather than a second walk that might disagree with the first.
  const seen = {
    signatures: new Set(),
    obscured: new Set(),
    measured: new Set(),
    unresolvable: [],
    exemptions: [],
    canvas: 0,
    svgText: 0,
    totals: { considered: 0, checked: 0, passed: 0, failedNodes: 0, invisible: 0, obscured: 0, ancestor: 0, veiled: 0, indicators: 0, indicatorsChecked: 0 },
  };

  // ---- 1. the arithmetic agrees with the calculator the rule names ----------------------

  await run.check("1  the ratio is WCAG's ratio — checked against WebAIM's own published values", async () => {
    // https://webaim.org/resources/contrastchecker/ — the reference the standing rule names.
    // These are the numbers that page reports for these pairs, to its own two decimals.
    //
    // EVERY PAIR HERE IS ONE THE CALCULATOR PUBLISHES. An earlier version of this table
    // carried `#2f3a56 on #f7f6f2` — the app's own accent on its own paper — with an
    // expected 10.32 that was not read off anything; the real answer is 10.44 and the check
    // failed on its own invented number. A reference table whose entries are guesses tests
    // the guesser. #767676 and #777777 are here because they are the pair WebAIM documents
    // as straddling 4.5, and #949494 because check 3 leans on it being 3.03.
    const table = [
      ["#000000", "#ffffff", 21],
      ["#ffffff", "#ffffff", 1],
      ["#777777", "#ffffff", 4.48],
      ["#767676", "#ffffff", 4.54],
      ["#949494", "#ffffff", 3.03],
      ["#0000ff", "#ffffff", 8.59],
      ["#ff0000", "#ffffff", 3.998],
      ["#595959", "#ffffff", 7.0],
    ];
    const rgb = (h) => ({ r: parseInt(h.slice(1, 3), 16), g: parseInt(h.slice(3, 5), 16), b: parseInt(h.slice(5, 7), 16), a: 1 });
    for (const [fg, bg, expected] of table) {
      const got = C.round2(C.contrastRatio(rgb(fg), rgb(bg)));
      assert(Math.abs(got - expected) <= 0.01, `${fg} on ${bg}: expected ${expected}:1, computed ${got}:1`);
    }
    // Alpha is composited, not ignored — the app's own `rgba(0,0,0,0.025)` hovers depend on it.
    const over = C.compositeOver({ r: 0, g: 0, b: 0, a: 0.5 }, { r: 255, g: 255, b: 255, a: 1 });
    assertEqual([Math.round(over.r), Math.round(over.g), Math.round(over.b)], [128, 128, 128], "50% black over white must composite to mid grey");
    return table.length + " published pairs, all within 0.01 of WebAIM";
  });

  // ---- 2. the arithmetic in the browser is THE SAME arithmetic --------------------------

  await run.check("2  the math running in WebKit is the same source, not a second copy", async () => {
    const page = await openApp(browser, "light");
    await page.evaluate(C.pageScript());
    const pairs = [
      ["rgb(165, 162, 151)", "rgb(247, 246, 242)"],
      ["rgba(32, 31, 27, 0.5)", "rgb(255, 255, 255)"],
      ["rgb(47 58 86 / 0.8)", "rgb(240, 239, 233)"],
      ["#nonsense", "rgb(0,0,0)"],
    ];
    const inPage = await page.evaluate((ps) => {
      const M = window.__contrastMath;
      return ps.map(function (p) {
        const f = M.parseCssColor(p[0]);
        const b = M.parseCssColor(p[1]);
        if (!f || !b) return null;
        return M.round2(M.contrastRatio(M.compositeOver(f, b), b));
      });
    }, pairs);
    const inNode = pairs.map(([f, b]) => {
      const fc = C.parseCssColor(f);
      const bc = C.parseCssColor(b);
      if (!fc || !bc) return null;
      return C.round2(C.contrastRatio(C.compositeOver(fc, bc), bc));
    });
    assertEqual(inPage, inNode, "WebKit and node must compute identical ratios from identical inputs");
    assertEqual(inPage[3], null, "an unrecognised colour notation must return null in BOTH — never a silent black");
    await page.close();
    return pairs.length + " pairs identical across the two runtimes: " + JSON.stringify(inPage);
  });

  // ---- 3. the thresholds sit where WCAG puts them ---------------------------------------

  await run.check("3  4.5 normal, 3.0 at 24px or 18.66px bold, 3.0 for a declared indicator", async () => {
    assertEqual(
      [
        C.isLargeText(23.9, "400"), C.isLargeText(24, "400"),
        C.isLargeText(18.65, "700"), C.isLargeText(18.66, "700"), C.isLargeText(18.66, "600"),
      ],
      [false, true, false, true, false],
      "the large-text boundary must be 24px, or 18.66px at weight >= 700"
    );
    // And the walk must APPLY them, which is a different claim. #767676 on white is 4.54 —
    // over 4.5, under nothing — so it passes as normal text and passes as large. #949494 is
    // 3.03: it FAILS as normal text and PASSES as large, which is the pair that proves the
    // threshold is being read off the font and not hardcoded.
    const page = await openApp(browser, "light");
    const r = await page.evaluate(async (script) => {
      eval(script);
      const host = document.createElement("div");
      host.style.cssText = "position:fixed;left:20px;top:400px;z-index:99999;background:#ffffff;padding:8px";
      host.innerHTML =
        '<p id="t-normal" style="color:#949494;background:#ffffff;font-size:14px;font-weight:400;margin:0">normal fourteen</p>' +
        '<p id="t-big" style="color:#949494;background:#ffffff;font-size:24px;font-weight:400;margin:0">big twenty four</p>' +
        '<p id="t-bold" style="color:#949494;background:#ffffff;font-size:19px;font-weight:700;margin:0">bold nineteen</p>' +
        '<p id="t-ind" data-contrast-role="indicator" style="color:#949494;background:#ffffff;font-size:14px;margin:0">declared indicator</p>';
      document.body.appendChild(host);
      const out = window.__contrastProbe({ surface: "threshold-fixture", theme: "light" });
      host.remove();
      const failing = Object.values(out.failures).map(function (f) { return f.selector + "@" + f.threshold; });
      return failing.filter(function (s) { return s.indexOf("t-") >= 0; });
    }, C.pageScript());
    assertEqual(r, ["p#t-normal@4.5"], "only the 14px/400 node may fail: 24px, 19px-bold and the declared indicator all clear 3.0");
    await page.close();
    return "3.03:1 fails at 14px/400 and passes at 24px, at 19px bold, and as a declared indicator";
  });

  // ---- 4. a real failure is caught, by name ---------------------------------------------

  await run.check("4  a deliberately-introduced failure is caught and NAMED, not just counted", async () => {
    const page = await openApp(browser, "light");
    const r = await page.evaluate(async (script) => {
      eval(script);
      const host = document.createElement("div");
      host.style.cssText = "position:fixed;left:20px;top:400px;z-index:99999;background:#ffffff;padding:8px";
      host.innerHTML = '<p id="planted-failure" style="color:#b0b0b0;background:#ffffff;font-size:13px;margin:0">a caption nobody can read</p>';
      document.body.appendChild(host);
      const out = window.__contrastProbe({ surface: "planted", theme: "light" });
      host.remove();
      const hit = Object.entries(out.failures).filter(function (e) { return e[0].indexOf("#b0b0b0") >= 0; });
      return hit.map(function (e) { return { sig: e[0], f: e[1] }; });
    }, C.pageScript());
    assertEqual(r.length, 1, "the planted node must produce exactly one failure signature");
    const f = r[0].f;
    assertEqual(f.selector, "p#planted-failure", "the failure must name the node");
    // The expectation comes from the arithmetic check 1 proved against WebAIM, not from a
    // number typed here — a typed one tests whoever typed it.
    const expected = C.round2(C.contrastRatio(C.parseCssColor("rgb(176,176,176)"), C.parseCssColor("rgb(255,255,255)")));
    assertEqual([f.ratio, f.threshold], [expected, 4.5], "and carry the computed ratio and the floor it missed");
    assert(f.text.indexOf("a caption nobody can read") === 0, "and quote the text, so it can be found on screen");
    await page.close();
    return "p#planted-failure caught at " + f.ratio + ":1 against a 4.5:1 floor, quoted verbatim";
  });

  // ---- 5. a declared exemption passes AND prints -----------------------------------------

  await run.check("5  a declared exemption passes, is NOT hidden, and carries its reason", async () => {
    const page = await openApp(browser, "light");
    const r = await page.evaluate(async (script) => {
      eval(script);
      const host = document.createElement("div");
      host.style.cssText = "position:fixed;left:20px;top:400px;z-index:99999;background:#ffffff;padding:8px";
      host.innerHTML =
        '<p id="declared" data-contrast-exempt="privacy boilerplate, not meant to be read closely" ' +
        'style="color:#b0b0b0;background:#ffffff;font-size:13px;margin:0">Your data never leaves this machine. ' +
        '<a href="#" style="color:#b0b0b0">Details</a></p>';
      document.body.appendChild(host);
      const out = window.__contrastProbe({ surface: "declared", theme: "light" });
      host.remove();
      return {
        failures: Object.keys(out.failures).filter(function (k) { return k.indexOf("#b0b0b0") >= 0; }),
        exempt: Object.entries(out.exempt).map(function (e) { return e[1]; }),
      };
    }, C.pageScript());
    assertEqual(r.failures, [], "a declared exemption must not fail the run");
    assert(r.exempt.length >= 1, "and must not vanish either — it has to appear in the exempt list");
    const e = r.exempt[0];
    assertEqual(e.reason, "privacy boilerplate, not meant to be read closely", "with the reason as written in the markup");
    assert(e.ratio < 4.5, "and the ratio it was excused at (" + e.ratio + "), so the excuse is quantified");
    // The exemption covers the subtree — a link inside the notice is part of the notice.
    assert(r.exempt.length >= 2 || e.nodes >= 2, "and it must reach the anchor inside it, not just the paragraph");
    await page.close();
    return r.exempt.length + " exempt entr(ies), reason printed, excused ratio " + e.ratio + ":1 stated";
  });

  // ---- 6. an exemption with nothing to say is not an exemption ---------------------------

  await run.check("6  an empty or one-word exemption is itself a failure — no mute button", async () => {
    const page = await openApp(browser, "light");
    const r = await page.evaluate(async (script) => {
      eval(script);
      const host = document.createElement("div");
      host.style.cssText = "position:fixed;left:20px;top:400px;z-index:99999;background:#ffffff;padding:8px";
      host.innerHTML =
        '<p id="mute-empty" data-contrast-exempt="" style="color:#b0b0b0;background:#fff;font-size:13px;margin:0">empty claim</p>' +
        '<p id="mute-short" data-contrast-exempt="legal" style="color:#b0b0b0;background:#fff;font-size:13px;margin:0">one word claim</p>';
      document.body.appendChild(host);
      const out = window.__contrastProbe({ surface: "mute", theme: "light" });
      host.remove();
      return {
        unresolvable: Object.values(out.unresolvable).map(function (u) { return u.path; }),
        exempt: Object.keys(out.exempt).length,
      };
    }, C.pageScript());
    assertEqual(r.exempt, 0, "neither may be honoured as an exemption");
    assertEqual(r.unresolvable.sort(), ["p#mute-empty", "p#mute-short"], "both must be reported, by name, as unproven");
    await page.close();
    return "both the empty and the one-word claim are refused and named";
  });

  // ---- 7. unresolvable is failure-to-prove ----------------------------------------------

  await run.check("7  a colour that cannot be resolved is a FAILURE TO PROVE, never a pass", async () => {
    const page = await openApp(browser, "light");
    const r = await page.evaluate(async (script) => {
      eval(script);
      const host = document.createElement("div");
      host.style.cssText = "position:fixed;left:20px;top:300px;z-index:99999;background:#ffffff;padding:8px";
      host.innerHTML =
        '<p id="u-gradient" style="background:linear-gradient(90deg,#000,#fff);color:#888;font-size:14px;margin:0">over a gradient</p>' +
        '<p id="u-blend" style="mix-blend-mode:multiply;background:#fff;color:#888;font-size:14px;margin:0">blended</p>' +
        '<p id="u-backdrop" style="backdrop-filter:blur(3px);background:#fff;color:#888;font-size:14px;margin:0">backdropped</p>' +
        '<p id="u-filter" style="filter:invert(1);background:#fff;color:#888;font-size:14px;margin:0">filtered</p>' +
        // The gradient-text idiom. `background-clip: text` is invisible to WebKit's computed
        // style, so the guard on it never fires — but the idiom needs `color: transparent`
        // to work at all, and transparent text composites to exactly its own background.
        // It is caught as a 1:1 failure rather than a skip, which is the outcome that
        // matters; the mechanism is stated in lib/contrast.js rather than assumed here.
        '<p id="u-transparent" style="background:#fff;color:transparent;font-size:14px;margin:0">invisible ink</p>';
      document.body.appendChild(host);
      const out = window.__contrastProbe({ surface: "unresolvable", theme: "light" });
      host.remove();
      const failed = Object.values(out.failures).filter(function (f) { return f.selector.indexOf("u-") >= 0; });
      return {
        named: Object.values(out.unresolvable).map(function (u) { return u.path; }).filter(function (p) { return p.indexOf("u-") >= 0; }).sort(),
        transparent: failed.filter(function (f) { return f.selector === "p#u-transparent"; }).map(function (f) { return f.ratio; }),
      };
    }, C.pageScript());
    assertEqual(
      r.named,
      ["p#u-backdrop", "p#u-blend", "p#u-filter", "p#u-gradient"],
      "each of the four must land in the unresolvable bucket — none of them may be quietly skipped or passed"
    );
    assertEqual(r.transparent, [1], "and fully transparent text must read 1:1 and FAIL, never resolve to something readable");
    await page.close();
    return "gradient, mix-blend-mode, filter and backdrop-filter refused by name; transparent text fails at 1:1";
  });

  // ---- 8. a sheet over the text is part of the answer -------------------------------------

  await run.check("8  a faint veil is measured THROUGH; only an aria-modal claim excuses", async () => {
    const page = await openApp(browser, "light");
    const r = await page.evaluate(async (script) => {
      eval(script);
      const mk = function (modal, alpha) {
        const host = document.createElement("div");
        host.style.cssText = "position:fixed;left:20px;top:300px;z-index:99990;background:#ffffff;padding:8px";
        // #767676 on white is 4.54:1 — it PASSES, by four hundredths. Twelve percent of black
        // over the whole thing is enough to take it under, which is exactly the point: the
        // veil is not decoration, it is part of the number.
        host.innerHTML = '<p id="beneath" style="color:#767676;background:#ffffff;font-size:13px;margin:0">under a sheet</p>';
        const sheet = document.createElement("div");
        sheet.id = "sheet";
        sheet.style.cssText = "position:fixed;inset:0;z-index:99995;background:rgba(0,0,0," + alpha + ")";
        if (modal) sheet.setAttribute("aria-modal", "true");
        document.body.appendChild(host);
        document.body.appendChild(sheet);
        const out = window.__contrastProbe({ surface: "veil", theme: "light" });
        host.remove();
        sheet.remove();
        return out;
      };
      const faint = mk(false, 0.12);
      const claimed = mk(true, 0.12);
      const beneathFail = Object.values(faint.failures).filter(function (f) { return f.selector === "p#beneath"; });
      return {
        faintVeiled: faint.veiled,
        faintFailure: beneathFail.length ? beneathFail[0].ratio : null,
        claimedObscured: Object.keys(claimed.obscured).some(function (k) { return k.indexOf("p#beneath") >= 0; }),
        claimedFailures: Object.values(claimed.failures).filter(function (f) { return f.selector === "p#beneath"; }).length,
      };
    }, C.pageScript());
    const veil = { r: 0, g: 0, b: 0, a: 0.12 };
    const clear = C.round2(C.contrastRatio(C.parseCssColor("rgb(118,118,118)"), C.parseCssColor("rgb(255,255,255)")));
    const through = C.round2(
      C.contrastRatio(C.compositeOver(veil, C.parseCssColor("rgb(118,118,118)")), C.compositeOver(veil, C.parseCssColor("rgb(255,255,255)")))
    );
    assert(clear >= 4.5 && through < 4.5, "the fixture only proves anything if the veil is what takes it under: " + clear + " -> " + through);
    assert(r.faintVeiled >= 1, "a 12% sheet with no inertness claim must be composited, not waved through");
    assertEqual(r.faintFailure, through, "and the ratio reported must be the one the eye receives (" + through + ":1), not the stylesheet's " + clear + ":1");
    assert(r.claimedObscured, "the SAME sheet, once it claims aria-modal, makes the text behind it inert and unmeasured");
    assertEqual(r.claimedFailures, 0, "and inert text produces no failure");
    await page.close();
    return "12% sheet: " + clear + ":1 -> " + through + ":1 measured through; with aria-modal, filed obscured instead";
  });

  // ---- 9. the shipping shell, surface by surface, both themes ------------------------------

  const perSurface = {};
  for (const surface of SURFACES) {
    await run.check("9." + surface.name + "  " + surface.what, async () => {
      const lines = [];
      let newOnes = 0;
      let worse = 0;
      let debtHits = 0;
      let checked = 0;
      let considered = 0;
      for (const theme of THEMES) {
        const page = await openApp(browser, theme, surface.holdSplash);
        await surface.drive(page);
        const out = await walk(page, surface.name, theme);
        if (theme === "light") {
          const s = await shot(page, "contrast-" + surface.name, { fullPage: false });
          fs.copyFileSync(s.file, path.join(SHOTS, surface.name + ".png"));
        }
        await page.close();
        perSurface[surface.name + "/" + theme] = out;

        checked += out.nodesChecked;
        considered += out.nodesConsidered;
        seen.canvas += out.canvasCount;
        seen.svgText += out.svgTextCount;
        seen.totals.considered += out.nodesConsidered;
        seen.totals.checked += out.nodesChecked;
        seen.totals.passed += out.nodesPassed;
        seen.totals.invisible += out.invisible;
        seen.totals.ancestor += out.ancestorResolved;
        seen.totals.veiled += out.veiled;
        seen.totals.obscured += Object.keys(out.obscured).length;
        seen.totals.indicators += out.indicators.considered;
        seen.totals.indicatorsChecked += out.indicators.checked;
        for (const k of Object.keys(out.obscured)) seen.obscured.add(out.obscured[k].path);
        for (const k of Object.keys(out.unresolvable)) seen.unresolvable.push(surface.name + "/" + theme + ": " + k);
        for (const k of Object.keys(out.exempt)) seen.exemptions.push(surface.name + "/" + theme + ": " + k);

        for (const [sig, f] of Object.entries(out.failures)) {
          seen.signatures.add(sig);
          seen.totals.failedNodes += f.nodes;
          const known = debt.signatures[sig];
          if (!known) {
            newOnes++;
            lines.push("    NEW (" + theme + ")\n" + describe(sig, f));
          } else if (f.ratio < known.ratio - 0.005) {
            worse++;
            lines.push("    WORSE than the ledger's " + known.ratio + ":1 (" + theme + ")\n" + describe(sig, f));
          } else {
            debtHits++;
          }
        }
        // Nodes measured somewhere, for check 11's cross-surface proof.
        for (const p of out.measuredPaths || []) seen.measured.add(p);
      }
      // THE FLOOR, borrowed wholesale from run.js's `observed >= declared`. A driver whose
      // selector stops matching would otherwise put the app into a thinner state and report
      // a cleaner walk — the failure mode where "nobody checked" reads as "somebody checked
      // and it was fine". BOTH numbers are floored: `considered` catches a surface that
      // stopped rendering, `checked` catches one that still renders but became unmeasurable.
      const floor = debt.surfaceFloors[surface.name];
      assert(floor !== undefined, surface.name + " has no floor in contrast-debt.json — add one rather than letting a surface that stops rendering read as clean");
      assert(
        considered >= floor.considered,
        surface.name + " found only " + considered + " text node(s) across both themes but its floor is " +
          floor.considered + " — the driver did not reach the state it was written for, so a clean result here proves nothing"
      );
      assert(
        checked >= floor.checked,
        surface.name + " measured only " + checked + " node(s) across both themes but its floor is " + floor.checked +
          " — the surface still renders, but less of it can be measured than when the floor was set"
      );
      assert(
        newOnes === 0 && worse === 0,
        newOnes + " NEW and " + worse + " WORSENED contrast failure(s) on " + surface.name + ":\n" + lines.join("\n")
      );
      return checked + " of " + considered + " node(s) measured across both themes, " + debtHits +
        " known-debt hit(s), 0 new, 0 worsened";
    });
  }

  // ---- 10. the dark run is not a fiction --------------------------------------------------

  await run.check("10  the second theme is a real second theme, or is reported as not one", async () => {
    // THIS CHECK CHANGED SHAPE ON 2026-08-31, AND THE OLD SHAPE IS WHY.
    //
    // It used to count `@media (prefers-color-scheme: dark)` blocks and, finding none,
    // assert the two runs were IDENTICAL — which was true and honest while the app shipped
    // one palette. Then dark mode landed, and it landed as `:root[data-theme="light"]` with
    // dark as the shipped default (§15: "a newly installed app opens dark"), because the
    // theme is the CEO's stored choice and not his operating system's.
    //
    // Left alone, this check would have kept passing — zero `prefers-color-scheme` blocks,
    // two identical runs — and would have kept PRINTING "THE APP SHIPS ONE THEME" over an
    // app that shipped two. A green assertion attached to a false sentence is the worst
    // outcome available here: it is the "nobody checked" that reads as "somebody checked".
    //
    // So it now counts the mechanism that actually ships, and it counts BOTH, because
    // either is a legitimate way to have a second theme and a build that switched from one
    // to the other must not slip through the gap between them.
    const css = CSS_FILES.map((f) => fs.readFileSync(f, "utf8")).join("\n");
    const mediaBlocks = (css.match(/@media[^{]*prefers-color-scheme\s*:\s*dark/g) || []).length;
    const attrBlocks = (css.match(/:root\s*\[\s*data-theme\s*=/g) || []).length;
    const themed = mediaBlocks + attrBlocks;

    assert(
      perSurface["shell/light"] && perSurface["shell/dark"],
      "check 9 must have run both themes before this one can compare them"
    );

    // WHAT THIS CHECK COMPARES, AND WHY IT IS NO LONGER THE FAILURE SIGNATURES.
    //
    // The original compared the two runs' sets of FAILING colour pairings and asserted they
    // differed. That was a serviceable proxy while the app had 456 failures — two palettes
    // fail differently. It has one fatal property, and this build hit it within the hour:
    // WHEN THE APP REACHES ZERO FAILURES, BOTH SETS ARE EMPTY, THEREFORE IDENTICAL,
    // THEREFORE THIS CHECK FAILS — and it fails hardest exactly when the work is most
    // correct, which trains whoever is on the other end to disable it.
    //
    // Fixing the contrast debt must not be what breaks the theme check. So the proof is now
    // taken from the PIXELS: the shell's own painted background, read out of both walks.
    // That is evidence a clean app still produces, and it is closer to the thing being
    // claimed anyway — "there are two palettes" is a statement about colours, not failures.
    const grounds = {};
    for (const t of THEMES) {
      const page = await openApp(browser, t, false);
      grounds[t] = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
      await page.close();
    }
    if (themed === 0) {
      assert(
        grounds.light === grounds.dark,
        "the shipped CSS declares no second-theme rule of either kind, yet the two runs paint " +
          "different grounds (" + grounds.dark + " vs " + grounds.light + ") — something IS " +
          "responding to the theme and this note is now wrong"
      );
      return "0 second-theme rules in style.css + splash.css. THE APP SHIPS ONE THEME.";
    }
    assert(
      grounds.light !== grounds.dark,
      themed + " second-theme rule(s) are shipped, but both walks paint the same body background (" +
        grounds.dark + ") — the theme is not reaching the elements, so half of every check above " +
        "is a fiction"
    );
    const fresh = await browser.newPage({ viewport: { width: 1400, height: 950 }, colorScheme: "light" });
    await fresh.goto(APP);
    await fresh.waitForSelector(".nav-thread", { state: "attached" });
    const virgin = await fresh.evaluate(() => document.documentElement.getAttribute("data-theme"));
    await fresh.close();
    assertEqual(
      virgin,
      "dark",
      "a install with NO stored preference, under a LIGHT operating system, must still open " +
        "dark — CEO ruling §15. It opened " + virgin + ", which means the OS is deciding a " +
        "question the ruling gives to the CEO"
    );

    return (
      themed + " second-theme rule(s) shipped (" + attrBlocks + " `:root[data-theme=]`, " +
      mediaBlocks + " `prefers-color-scheme`), and both walks exercise them: the two runs " +
      "differ, the body ground differs (" + grounds.dark + " vs " + grounds.light + "), and a " +
      "fresh install under a light OS still opens dark."
    );
  });

  // ---- 10b. this suite measures the same amount however it was started ---------------------

  await run.check("10b  every surface was walked in both themes — and standalone is not a thinner run", async () => {
    // RAISED BY THE LEAD ON 2026-08-31, and the concern is right even though the symptom
    // that prompted it was not: "a gate that silently degrades when run directly is a gate
    // someone will one day trust while it measures nothing."
    //
    // The answer is that it does not degrade, and this check is that answer in a form nobody
    // has to take on trust. `run.js` passes `RICHOS_UI_TESTS_LEDGER` to its children, and
    // that variable does exactly one thing (`lib/harness.js`): it decides whether `report()`
    // appends a line of evidence for `run.js` to gate on. `recordEvidence` returns early
    // without it. It reaches no driver, no walk and no threshold — the harness's own comment
    // has said so since it was written: "`node workers.js` on its own is byte-for-byte
    // unchanged."
    //
    // What this asserts is the thing that would actually be worth knowing: that the walk
    // INVENTORY is complete. A suite that reached two surfaces out of ten and reported a
    // clean sweep of both themes is the failure being guarded against, and it is a failure
    // about coverage rather than about an environment variable — so it is measured as one,
    // and it holds whichever way the suite was started.
    // THE EXPECTED LIST COMES FROM THE LEDGER ON DISK, NOT FROM `SURFACES`.
    //
    // The first draft of this check built both sides out of `SURFACES` and was therefore
    // incapable of failing: deleting a surface deleted it from the expectation too, and the
    // mutation that was supposed to prove the check sailed through it. Both sides have to be
    // read off disk or neither is. `contrast-debt.json`'s `surfaceFloors` is the second
    // source — it is committed, it is what check 9's floors are already gated on, and a
    // surface removed from the driver list is still named there.
    const named = Object.keys(debt.surfaceFloors).sort();
    const walkedNames = [...new Set(Object.keys(perSurface).map((k) => k.split("/")[0]))].sort();
    assertEqual(
      named.filter((n) => !walkedNames.includes(n)),
      [],
      "these surfaces have a floor in contrast-debt.json and were never walked. A driver list " +
        "that quietly got shorter still runs every check it declares, so run.js's " +
        "declared-vs-observed gate cannot see it — this is the only thing that can"
    );
    const expected = [];
    for (const n of walkedNames) for (const t of THEMES) expected.push(n + "/" + t);
    assertEqual(
      expected.filter((k) => !perSurface[k]),
      [],
      "a surface was walked in one theme and not the other"
    );
    assertEqual(
      Object.keys(perSurface).length,
      named.length * THEMES.length,
      "the walk inventory and the committed floor list disagree"
    );
    return (
      Object.keys(perSurface).length + " walks completed (" + named.length + " surfaces x " + THEMES.length +
      " themes), and the count is the same started directly or under run.js: " +
      "RICHOS_UI_TESTS_LEDGER gates only whether evidence is APPENDED, never what is measured."
    );
  });

  // ---- 11. the obscured bucket is not a hiding place ---------------------------------------

  await run.check("11  nothing disappears into `obscured` without being measured somewhere else", async () => {
    const measured = new Set();
    for (const out of Object.values(perSurface)) {
      for (const f of Object.values(out.failures)) measured.add(f.selector);
      for (const p of out.measuredPaths || []) measured.add(p);
    }
    const orphans = [...seen.obscured].filter((p) => !measured.has(p));
    assertEqual(
      orphans,
      [],
      "these node(s) were filed `obscured` on every surface that reaches them and measured on none, which " +
        "means the gate says nothing about them at all:\n      " + orphans.join("\n      ")
    );
    return seen.obscured.size + " node path(s) obscured behind a modal on some surface, every one of them measured on another";
  });

  // ---- 12. the exemption inventory, so creep is a number ------------------------------------

  await run.check("12  every exemption in the shipped source is enumerated, with its reason", async () => {
    const declared = [];
    for (const file of SOURCE_FILES) {
      const src = fs.readFileSync(file, "utf8");
      const re = /data-contrast-exempt\s*=\s*(["'])([\s\S]*?)\1/g;
      let m;
      while ((m = re.exec(src))) declared.push({ file: path.basename(file), reason: m[2].trim() });
    }
    for (const d of declared) {
      assert(
        d.reason.length >= 12,
        d.file + " declares data-contrast-exempt=\"" + d.reason + "\" — an exemption has to say what it is claiming, " +
          "because the claim is the thing a reviewer weighs. Twelve characters is not a high bar; a blank is a mute button."
      );
    }
    assert(
      declared.length <= debt.exemptionCap,
      declared.length + " exemptions are declared in the shipped source; the ledger's cap is " + debt.exemptionCap +
        ". Raise the cap deliberately, in the same commit that adds the exemption, so the growth is a decision."
    );
    if (!declared.length) return "0 exemptions declared in the shipped source today (cap " + debt.exemptionCap + "). Nothing is currently excused.";
    return declared.length + " declared (cap " + debt.exemptionCap + "):\n          " +
      declared.map((d) => d.file + ": " + d.reason).join("\n          ");
  });

  // ---- 13. the ledger only shrinks ---------------------------------------------------------

  await run.check("13  the debt ledger can only shrink, and every entry in it is still real", async () => {
    const ledger = Object.keys(debt.signatures);
    assert(
      ledger.length <= debt.cap,
      ledger.length + " signatures in contrast-debt.json against a cap of " + debt.cap +
        " — the ledger is for what was already broken, not a place to put new work"
    );
    const gone = ledger.filter((s) => !seen.signatures.has(s));
    const noted = gone.length
      ? "\n          " + gone.length + " ledger entr(ies) no longer reachable — fixed, or the surface changed. Delete them:\n          " +
        gone.map((g) => "  " + g).join("\n          ")
      : "";
    // Deliberately a NOTE and not a failure: a coverage GAIN must never turn a run red, which
    // is the same reasoning run.js applies to an --allow-skip that was not needed. The cap
    // above is what stops the ledger drifting the other way.
    // Unresolvable has its OWN ledger, and it is the shortest and most closely watched list
    // in this file: every entry is a place the gate is admitting it cannot prove anything.
    // A new one is a failure. Nothing is ever "probably fine".
    const known = new Set(debt.knownUnresolvable.map((k) => k.key));
    const surprises = [...new Set(seen.unresolvable.map((u) => u.split(": ").slice(1).join(": ")))].filter((k) => !known.has(k));
    assertEqual(
      surprises,
      [],
      "colour(s) on the shipping surfaces that this gate cannot prove, and that nobody has written down:\n      " +
        surprises.join("\n      ") +
        "\n      Either resolve them in the product, or add them to contrast-debt.json's knownUnresolvable with a " +
        "reason — but they are NOT passing, and the entry says so."
    );
    return ledger.length + " known-debt signature(s) (cap " + debt.cap + "), " + seen.signatures.size +
      " seen this run; " + debt.knownUnresolvable.length + " declared-unprovable colour(s), 0 new" + noted;
  });

  // ---- 14. what a DOM checker cannot see, asserted rather than assumed ------------------------

  await run.check("14  no <canvas> on any surface walked — so the DOM check is not talking past the pixels", async () => {
    assertEqual(
      seen.canvas,
      0,
      "a <canvas> appeared on a walked surface. Nothing in this suite can read a pixel it painted, so its " +
        "contrast is UNCHECKED and a green run here must not be read as covering it."
    );
    return (
      "0 <canvas> elements across " + Object.keys(perSurface).length + " surface/theme walks. " +
      "The DOM check therefore covers the whole of every surface it reaches — every failure it reports " +
      "is a node with a computed style, and every node with a computed style was reported. Canvas-heavy " +
      "work elsewhere in the repo (the round-7 / round-8.1 material studies) is NOT covered by anything here."
    );
  });

  // ---- 15. SVG is named, not silently skipped -------------------------------------------------

  await run.check("15  SVG fill/stroke is counted as uncovered, not passed over in silence", async () => {
    const page = await openApp(browser, "light");
    const splash = await page.evaluate(() => {
      const n = document.getElementById("splash");
      if (!n) return { present: false };
      const texts = [];
      n.querySelectorAll("*").forEach((e) => {
        for (const c of e.childNodes) if (c.nodeType === 3 && c.nodeValue.trim()) texts.push(c.nodeValue.trim());
      });
      return { present: true, htmlTextNodes: texts.length, svgs: n.querySelectorAll("svg").length };
    });
    await page.close();
    assertEqual(
      seen.svgText,
      0,
      seen.svgText + " <svg><text> node(s) were found on the walked surfaces. This walk reads `color`, " +
        "not `fill`, so those are UNMEASURED and must not be read as passing."
    );
    return (
      "0 svg <text> nodes on the walked surfaces. The opening screen is a separate matter and is named here " +
      "rather than counted as covered: it is " +
      (splash.present ? "still up at walk time" : "already gone by walk time (its curtain yields as soon as main.js reports the shell usable)") +
      ", and it is drawn almost entirely in SVG — its wordmark, logo and plinth carry no computed `color` this walk can read."
    );
  });

  // ---- the run's own numbers, printed whether it passes or fails ---------------------------

  const t = seen.totals;
  console.log("\n== the shipping shell, by the numbers ==");
  console.log("  surfaces walked          " + SURFACES.length + " x " + THEMES.length + " themes = " + Object.keys(perSurface).length + " walks");
  console.log("  text nodes considered    " + t.considered);
  console.log("    of those, not rendered " + t.invisible + "  (display:none / zero-area / a closed panel)");
  console.log("    behind a modal         " + t.obscured + "  (inert; each one measured on a surface where it is not)");
  console.log("    MEASURED               " + t.checked);
  console.log("      passed               " + t.passed);
  console.log("      failed               " + t.failedNodes + " node(s) over " + seen.signatures.size + " distinct colour pairings");
  console.log("  non-text indicators      " + t.indicators + " considered, " + t.indicatorsChecked + " with a boundary of their own to check");
  console.log("  resolved by ancestor     " + t.ancestor + "  (off-viewport: no hit test, so no occlusion proof)");
  console.log("  measured through a veil  " + t.veiled);
  // DEDUPED, because the same unprovable colour is met once per walk and the summary read
  // "UNRESOLVABLE 2" against check 13's "1 declared-unprovable colour(s)" — two true numbers
  // that look like a discrepancy. The count that means something is distinct colours.
  const distinctUnresolvable = new Set(seen.unresolvable.map((u) => u.split(": ").slice(1).join(": ")));
  console.log(
    "  UNRESOLVABLE             " + distinctUnresolvable.size + "  (a failure to prove, not a pass; met " +
      seen.unresolvable.length + " time(s) across the walks)"
  );
  console.log("  declared exempt          " + seen.exemptions.length);
  console.log("  <canvas> seen            " + seen.canvas + "   svg <text> seen  " + seen.svgText);

  console.log("\n== every distinct failing colour pairing on the shipping shell today ==");
  const all = {};
  for (const out of Object.values(perSurface)) for (const [sig, f] of Object.entries(out.failures)) all[sig] = f;
  const sorted = Object.entries(all).sort((a, b) => a[1].ratio - b[1].ratio);
  for (const [sig, f] of sorted) {
    console.log("  " + String(f.ratio).padStart(5) + ":1  (needs " + f.threshold + ")  " + sig);
    console.log("           e.g. " + f.selector + (f.text && f.text !== "(non-text indicator)" ? "  “" + f.text + "”" : ""));
  }

  if (seen.exemptions.length) {
    console.log("\n== declared exemptions honoured this run (every one, with its reason) ==");
    for (const e of seen.exemptions) console.log("  " + e);
  }

  const failed = run.report();
  const pageErrors = 0;
  await browser.close();
  process.exit(failed || pageErrors ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

// ---------------------------------------------------------------------------------------
// RUN RED — the mutation that made each check fail, and what went red with it
// ---------------------------------------------------------------------------------------
//
// Twenty-two runs, one edit each, the file restored from a copy taken before the edit
// whether the run passed or failed, and `git status` clean at the end. Full transcript with
// the failure text of every run: `docs/verification/contrast-gate-2026-08-30/`.
//
// TWO OF THEM DID NOT GO RED THE FIRST TIME AND ARE RECORDED AS SUCH, in the transcript and
// here. A mutation that turns nothing red proves nothing, and quietly replacing it with one
// that works is how a run-red list becomes decoration.
//
//  1   lib/contrast.js `srgbToLinear`: `return v` instead of the piecewise gamma expansion
//        -> #777777 on white reads 2.03:1 where WebAIM publishes 4.48. Also reds 3, 8 and
//           every surface: the whole gate is built on this function
//  2   lib/contrast.js `pageScript`: drop `round2` from the math shipped into the page
//        -> `M.round2 is not a function` in WebKit. The two runtimes are proven to be one
//           source by the fact that removing it from one removes it from both
//  3   lib/contrast.js `thresholdFor`: `return NORMAL` unconditionally
//        -> the 24px node, the 19px-bold node and the declared indicator all fail at 4.5
//  3b  lib/contrast.js `isLargeText`: bold boundary 18px instead of 18.66px
//        -> 18.65px/700 counts as large text
//  4   lib/contrast.js the text loop: `if (true) { out.nodesPassed++; continue; }`
//        -> the planted 2.17:1 caption produces no failure at all
//  4b  lib/contrast.js: file the failure with `selector: "(a node)"`
//        -> the failure is counted and the node is not named, which is the report nobody
//           can act on
//  5   lib/contrast.js: honour a declared exemption without filing it into `out.exempt`
//        -> it passes SILENTLY, which is the exact failure mode the mechanism exists to
//           prevent: an excuse nobody sees is not a declaration
//  5b  lib/contrast.js `exemptionFor`: `hasAttribute` on the node instead of `closest`
//        -> the anchor inside the privacy notice is not covered by the notice's exemption
//  6   lib/contrast.js `MIN_REASON = 0`
//        -> `data-contrast-exempt=""` becomes a working mute button
//  7   lib/contrast.js `resolveBackground`: drop the `backgroundImage !== "none"` guard
//        -> text over a black-to-white gradient resolves to the paper behind it and passes
//  7b  lib/contrast.js: `continue` past an unprovable node without filing it anywhere
//        -> four unprovable nodes vanish from the report and the run stays green
//  8   lib/contrast.js `stackFor`: return the chain without `over`
//        -> the 12% sheet is ignored and #767676 reads 4.54:1 instead of the 4.25:1 the eye
//           gets — a node that passes on paper and fails on screen
//  9   style.css `--ink-faint: #a5a297` -> `#8f8c81`
//        -> 20 NEW pairings on the shell alone, named with their ratios; all nine driven
//           surfaces red
//  9b  style.css: `.nav-thread-title { display: none }`
//        -> the shell measures 66 nodes against a floor of 80. The surface still renders and
//           has nothing wrong with what is left, which is precisely the run that would
//           otherwise read as an improvement
//  10  style.css gains a real `@media (prefers-color-scheme: dark)` block AND the suite
// 10b  drop three entries from SURFACES -> check 10b. A short inventory that still reported
//      its findings is a clean bill of health over whatever it happened to reach; run.js's
//      declared-vs-observed gate cannot see it, because the suite would run every check it
//      declares. Also: unsetting RICHOS_UI_TESTS_LEDGER changes NOTHING here, which is the
//      point of the check and was verified by running it both ways.
//      stops passing `colorScheme` to `newPage`
//        -> "1 dark block(s) are shipped, but the dark run produced the identical palette —
//           the emulation is not reaching them, so the dark half of every check above is a
//           fiction". This is the mutation that matters most for check 10: the branch that
//           reports today's single-theme reality is easy, and the one that catches a dark
//           mode nobody is actually testing is the one worth proving
//  11  index.html: a painted, click-through curtain (`pointer-events: none`,
//      `rgba(0,0,0,0.6)`, z-index 300) left over the whole app
//        -> every node on every surface is filed obscured and measured nowhere, and check 11
//           names them. A blunt mutation — it reds fifteen checks — and it is the honest one:
//           the bucket only becomes a hiding place when something covers everything.
//  11  FIRST ATTEMPT, INERT, RECORDED AS SUCH: `stackFor`'s modal branch changed to
//      `if (modal)`, dropping the `!modal.contains(el)` half. Nothing went red. The loop it
//      sits in only runs over elements painted ABOVE the node, and a desk card inside the
//      panel has none, so the mutated line was never reached. It proves nothing about check
//      11 and is not counted as a run.
//  12  index.html: `data-contrast-exempt="x"` on `#rail-company`
//        -> rejected by file and by reason for having nothing to say
//  12b index.html: `data-contrast-exempt="chrome, nobody reads the company name"` against
//      an `exemptionCap` of 0
//        -> "1 exemptions are declared; the ledger's cap is 0. Raise the cap deliberately,
//           in the same commit that adds the exemption, so the growth is a decision."
//  13  contrast-debt.json `cap`: 52 with 53 signatures in the file
//        -> the ledger is refused as a place to put new work
//  13b style.css: `.desk-card-target { background-image: linear-gradient(#fff,#fff) }`
//        -> a real caption on a real surface goes unprovable, and there is no ledger entry
//           absorbing it: "colour(s) ... that this gate cannot prove, and that nobody has
//           written down". Also reds 9.corrections
//  13b FIRST ATTEMPT, ANCHOR MISSED: `.desk-card-target {` does not appear in style.css —
//      the rule is written `.desk-card-target,` as the head of a selector list. The driver
//      refused to proceed rather than editing something else, which is the behaviour that
//      makes an anchor miss a recorded non-run instead of a silent one.
//  14  index.html: `<canvas width=10 height=10>` inside the conversation pane
//        -> "a <canvas> appeared on a walked surface ... a green run here must not be read
//           as covering it"
//  15  index.html: `<svg><text x=0 y=9>hi</text></svg>` inside the conversation pane
//        -> 20 svg text nodes across the walks, named as unmeasured rather than passed over

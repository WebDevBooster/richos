// The browser acceptance harness for `app/ui` — a HOME for the tests every UI slice was
// otherwise re-inventing and throwing away.
//
// THREE RULES, each one a thing an earlier slice got wrong:
//
//  1. THE REAL RENDERER, NEVER A COPY. Every page below loads `../timeline.js` and
//     `../style.css` from disk by relative path. A test that re-implements a rule proves
//     the test, not the product.
//  2. WEBKIT, NOT CHROMIUM. Tauri renders through WKWebView on macOS (§3.3 of the
//     architecture doc names the webview-consistency tradeoff explicitly). A green
//     Chromium run says nothing about what the CEO sees.
//  3. NO FAKED SCREENSHOTS. `screencapture` on this machine has returned an all-black
//     1920x1080 PNG for three slices running (display locked). Screenshots here come out
//     of WebKit's own compositor, which does not depend on a display server — and every
//     one is checked for non-uniform pixels before it counts as evidence.
//
// Playwright is a devDependency (`npm install` in this directory). It is resolved leniently
// so the harness also runs from an existing install on the machine via NODE_PATH or
// RICHOS_PLAYWRIGHT — installing a browser engine into every worktree is not free.
//
// `npm install` HAS TO INSTALL THE ENGINE TOO, and for a while it did not. Playwright 1.61
// ships no `postinstall` script (its installed package.json has no `scripts` key at all), so
// `npm install` here produced the JS API and zero browsers, and the only thing that made the
// suites run was a webkit binary some OTHER project had already put in the shared
// ~/Library/Caches/ms-playwright. That is why six consecutive runs of this directory needed
// RICHOS_PLAYWRIGHT pointed into an unrelated repository: not a preference, a missing step.
// `package.json` now carries `postinstall: playwright install webkit`, which is what makes
// the README's one-command setup true. RICHOS_PLAYWRIGHT stays as what it was meant to be —
// the deliberate opt-out for someone who does not want the download — and is no longer the
// only way in.

"use strict";

const path = require("path");
const fs = require("fs");

const UI_DIR = path.resolve(__dirname, "..", "..");
const SHOT_DIR = path.resolve(__dirname, "..", ".shots");

function loadPlaywright() {
  const candidates = [];
  if (process.env.RICHOS_PLAYWRIGHT) candidates.push(process.env.RICHOS_PLAYWRIGHT);
  candidates.push("playwright");
  for (const c of candidates) {
    try {
      return require(c);
    } catch (_e) {
      /* keep looking */
    }
  }
  throw new Error(
    "playwright not found. Run `npm install` in app/ui/tests (its postinstall fetches WebKit too), " +
      "or point RICHOS_PLAYWRIGHT at an existing install."
  );
}

// ---------------------------------------------------------------------------------------
// The fixture page
// ---------------------------------------------------------------------------------------

/// A page that is the shipping renderer and nothing else: the real stylesheet, the real
/// `timeline.js`, and a `#messages` container shaped exactly as `index.html` shapes it.
///
/// `window.__render(snapshot, opts)` applies a `get_timeline` snapshot through
/// `RichTimeline.applySnapshot` — the SAME reload path `main.js` uses — and renders it. It
/// returns the turn projection so a test can assert on the model and the DOM together.
function fixtureHtml() {
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<link rel="stylesheet" href="file://${UI_DIR}/style.css">
</head><body>
  <div id="app"><main id="stage">
    <div id="conversation" role="log" aria-live="off" tabindex="0"><div id="messages"></div></div>
  </main></div>
  <script src="file://${UI_DIR}/timeline.js"></script>
  <script>
    window.__events = [];
    window.__model = window.RichTimeline.createModel();
    window.__opts = {};
    window.__renderOnly = function () {
      const opts = Object.assign({
        now: 1787950000000,
        expandedMessages: new Set(),
        avatarAlreadyShown: true,
        // THE SHIPPING RULE, NOT A COPY OF IT (harness rule 1). Section 6.4 has two
        // defaults - expanded while the turn is active, collapsed after it settles - and
        // the CEO's own choice overrules both. All three live in
        // RichTimeline.isTurnExpanded / toggleTurn, which is what main.js calls; a
        // re-implementation here would prove the harness rather than the product.
        // (No backticks in this comment: it sits inside the fixture page's template
        // literal, where one would end the string.)
        isExpanded: function (id) { return window.RichTimeline.isTurnExpanded(window.__model, id); },
        toggle: function (id) {
          window.RichTimeline.toggleTurn(window.__model, id);
          window.__renderOnly();
        },
        rerender: function () { window.__renderOnly(); },
        copy: function () {},
        retry: function () {},
        openWorker: function (w) { window.__events.push({ type: "openWorker", agentId: w.agentId }); },
      }, window.__opts);
      return window.RichTimeline.render(window.__model, document.getElementById("messages"), opts);
    };
    window.__render = function (snapshot, opts) {
      window.__opts = opts || {};
      window.__model = window.RichTimeline.createModel();
      window.RichTimeline.bind(window.__model, snapshot.entityId, snapshot.threadId, snapshot.bindingRevision);
      window.RichTimeline.applySnapshot(window.__model, snapshot);
      return window.__renderOnly();
    };
  </script>
</body></html>`;
}

async function openFixture(browser, viewport) {
  const page = await browser.newPage({ viewport: viewport || { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  // A `file://` base URL so the two relative script/stylesheet loads resolve.
  await page.goto("file://" + path.join(UI_DIR, "index.html"));
  await page.setContent(fixtureHtml(), { waitUntil: "load" });
  await page.waitForFunction("typeof window.RichTimeline === 'object'");
  page.__errors = errors;
  return page;
}

// ---------------------------------------------------------------------------------------
// Evidence
// ---------------------------------------------------------------------------------------

/// Take a screenshot AND prove it is a real render. An all-black or all-white PNG is what a
/// locked display produces; a genuine WebKit paint has hundreds of distinct pixel values.
/// A shot that fails this check is reported as evidence of NOTHING, never counted as a pass.
///
/// THIS CHECK WAS DOCUMENTED HERE BEFORE IT WAS DONE. Until this commit the function
/// measured `fs.statSync(...).size` and nothing else — and a byte count is exactly what an
/// all-black PNG passes: `screencapture` on this machine has been returning a valid,
/// several-kilobyte, single-color (0,0,0) 1920x1080 file for three slices running. A file
/// size is not a render. So the pixels are now counted, in the browser that just painted
/// them: the PNG is handed back to WebKit, decoded, drawn to a canvas and sampled. No new
/// dependency, and the decoder is the same engine the CEO's app renders through.
///
/// `distinct` is the number of unique RGB values over a bounded grid sample. A locked
/// display returns 1. A real UI returns dozens to hundreds.
const SHOT_MIN_DISTINCT = 8;

async function shot(page, name, opts) {
  opts = opts || {};
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  const file = path.join(SHOT_DIR, name + ".png");
  const buf = await page.screenshot({ path: file, fullPage: opts.fullPage !== false });
  const bytes = fs.statSync(file).size;

  const stats = await page.evaluate(async (b64) => {
    const img = new Image();
    await new Promise((res, rej) => {
      img.onload = res;
      img.onerror = () => rej(new Error("the PNG did not decode"));
      img.src = "data:image/png;base64," + b64;
    });
    const c = document.createElement("canvas");
    c.width = img.naturalWidth;
    c.height = img.naturalHeight;
    const ctx = c.getContext("2d");
    ctx.drawImage(img, 0, 0);
    // A bounded grid — a 120x120 sample is enough to tell a painted UI from a flat fill and
    // costs nothing on a 2000px-tall full-page shot.
    const stepX = Math.max(1, Math.floor(c.width / 120));
    const stepY = Math.max(1, Math.floor(c.height / 120));
    const seen = new Set();
    const d = ctx.getImageData(0, 0, c.width, c.height).data;
    let sampled = 0;
    for (let y = 0; y < c.height; y += stepY) {
      for (let x = 0; x < c.width; x += stepX) {
        const i = (y * c.width + x) * 4;
        seen.add((d[i] << 16) | (d[i + 1] << 8) | d[i + 2]);
        sampled++;
      }
    }
    return { width: c.width, height: c.height, distinct: seen.size, sampled };
  }, buf.toString("base64"));

  if (stats.distinct < SHOT_MIN_DISTINCT) {
    throw new Error(
      `${name}.png is ${stats.width}x${stats.height} with only ${stats.distinct} distinct ` +
        `color(s) across ${stats.sampled} samples — that is a flat fill, not a render. ` +
        `Evidence of NOTHING (${file}).`
    );
  }
  return Object.assign({ file, bytes }, stats);
}

// ---------------------------------------------------------------------------------------
// A very small test runner. No framework: one dependency is enough for a harness whose
// whole point is that it is cheap enough to keep.
// ---------------------------------------------------------------------------------------

// ---------------------------------------------------------------------------------------
// The evidence ledger
// ---------------------------------------------------------------------------------------
//
// A suite prints PASS/FAIL lines for a human. `run.js` needs the same facts as NUMBERS, so
// it can refuse to report green over a suite that ran and checked nothing — the failure this
// repository has now produced twice: a scanner reporting CLEAN over an empty corpus, and a
// `run.js` reporting "all 4 suites passed" over a suite it was not running. Neither was
// detectable from a suite's exit code, because both exited 0 honestly.
//
// So every `report()` appends one JSON line naming how many checks it actually ran, and
// `skipSuite()` writes the other kind of record: this suite produced no evidence, and here
// is why. `run.js` reads them back and gates on them.
//
// Written ONLY when RICHOS_UI_TESTS_LEDGER is set, which `run.js` does for its children.
// `node workers.js` on its own is byte-for-byte unchanged.

const LEDGER = process.env.RICHOS_UI_TESTS_LEDGER || "";

function recordEvidence(rec) {
  if (!LEDGER) return;
  const suite = path.basename(process.argv[1] || "unknown");
  fs.appendFileSync(LEDGER, JSON.stringify(Object.assign({ suite }, rec)) + "\n");
}

/// A suite that CANNOT run says so here rather than returning 0 quietly. The distinction is
/// the whole point: "did not run" and "ran and found nothing wrong" are different facts, and
/// only one of them is evidence. `run.js` fails on any skip it was not told to expect.
function skipSuite(label, reason) {
  console.log("\n== " + label + " ==");
  console.log("  SKIP  this suite did not run");
  console.log("        " + reason);
  console.log("        SKIPPED, not passed.");
  recordEvidence({ label, skipped: reason });
}

function createRun(label) {
  const results = [];
  return {
    label,
    async check(name, fn) {
      try {
        const detail = await fn();
        results.push({ name, ok: true, detail: detail || "" });
      } catch (e) {
        results.push({ name, ok: false, detail: (e && e.message) || String(e) });
      }
    },
    report() {
      let failed = 0;
      console.log("\n== " + label + " ==");
      for (const r of results) {
        if (!r.ok) failed++;
        console.log(`  ${r.ok ? "PASS" : "FAIL"}  ${r.name}${r.detail ? "\n          " + r.detail : ""}`);
      }
      recordEvidence({ label, checks: results.length, failed });
      return failed;
    },
  };
}

/// The verbatim body of a `const NAME: &str = "…";` in Rust source, with rustc's
/// line-continuation rules applied — the same way `lib/state-strings.js` reads them, and for
/// the same reason: every CEO-facing sentence in `main.rs` is written across two or three
/// lines with a trailing backslash.
///
/// It lives here because two suites now join `mock.js`'s copy of a product sentence to the
/// const the product ships (`corrections.js` check 12, `feedback.js` check 8), and a
/// subtle parser copied into both is the drift those checks exist to catch, one level out.
///
/// `marker` is any text inside the literal. The scan goes BACKWARD to the literal's opening
/// quote: forward would find its CLOSING one and read the code after it, which is what the
/// first version of this did — it reported `.to_string() }) .map(|d| d.lock()…` as the
/// sentence the CEO sees.
function rustSentenceAfter(src, marker) {
  const at = src.indexOf(marker);
  assert(at >= 0, "marker not found in the Rust source: " + marker);
  const open = src.lastIndexOf('"', at);
  assert(open >= 0, "no opening quote before the marker: " + marker);
  let out = "";
  for (let i = open + 1; i < src.length; i++) {
    const c = src[i];
    if (c === "\\") {
      const n = src[i + 1];
      if (n === "\n") {
        i++;
        while (src[i + 1] === " " || src[i + 1] === "\t") i++;
        continue;
      }
      out += n;
      i++;
      continue;
    }
    if (c === '"') break;
    out += c;
  }
  return out.replace(/\s+/g, " ").trim();
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

function assertEqual(actual, expected, msg) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${msg}\n          expected ${e}\n          actual   ${a}`);
}

module.exports = {
  loadPlaywright,
  openFixture,
  skipSuite,
  shot,
  createRun,
  assert,
  assertEqual,
  rustSentenceAfter,
  UI_DIR,
  SHOT_DIR,
};

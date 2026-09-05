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
const png = require("./png");

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

// ---------------------------------------------------------------------------------------
// PUBLISHING A SHOT — the one place a PNG is written
// ---------------------------------------------------------------------------------------
//
// THE PROBLEM THIS SOLVES, MEASURED. On 2026-09-05, against `5e00651`, one `node run.js` left
// 96 of the 96 committed PNGs under `../shots-*/` modified, with byte deltas from -12 to
// +679,604. Seventy of them held a picture that differed in THIRTY-THREE pixels out of 1.33
// million — the antialiased left edge of the wordmark — and a handful held a genuinely
// different screen. `git status` was therefore dirty after every run; `git checkout --
// app/ui/tests/` became a habit; and a real visual regression would have arrived as one more
// modified PNG in a list of ninety-six, which is camouflage, not evidence.
//
// The rule is now: A SHOT IS WRITTEN ONLY WHEN THE PICTURE CHANGED. Not when the file bytes
// changed — two PNGs can hold the same picture and differ, and `git diff` cannot tell that
// from a regression. Both sides are decoded (`./png.js`) and every sample compared.
//
// AND THE DOUBT ALWAYS WRITES. If either side cannot be decoded, or is a PNG shape that
// decoder will not guess at, `samePicture` is false and the file is written. One redundant
// write costs a line in `git status`; a wrongly-skipped write costs a regression nobody sees.
//
// When a committed shot IS rewritten, the change is announced with the pixel count that made
// it necessary — so the diff arrives already explained, rather than as a binary blob.
function publishShot(buf, file) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let existing = null;
  try {
    existing = fs.readFileSync(file);
  } catch (_e) {
    /* no previous shot — first write */
  }
  if (existing && png.samePicture(existing, buf)) {
    return { file, written: false, bytes: existing.length };
  }
  if (existing && !file.startsWith(SHOT_DIR + path.sep)) {
    // A COMMITTED shot changed. `.shots/` is per-run scratch and gitignored; saying anything
    // about it every run would be the noise this whole change exists to remove.
    console.log(
      "  shot changed: " +
        path.relative(path.resolve(__dirname, ".."), file) +
        " — " +
        png.describeDifference(existing, buf)
    );
  }
  fs.writeFileSync(file, buf);
  return { file, written: true, bytes: buf.length };
}

/// The same rule for a shot that already exists as a file — the `.shots/` scratch copy a suite
/// took first and now wants to keep. Replaces `fs.copyFileSync`, which always writes.
function publishShotFile(src, dest) {
  return publishShot(fs.readFileSync(src), dest);
}

// ---------------------------------------------------------------------------------------
// A LOOP CANNOT BE WAITED OUT
// ---------------------------------------------------------------------------------------
//
// A suite that photographs a fade waits for it — `corrections.js` waits 300ms for the overlay,
// `home.js` waits for the chip slide to land. That works because a transition ENDS. An
// `iteration-count: infinite` animation never does, so a shot of one is a photograph of an
// arbitrary phase and the file differs every run for no reason anybody can read.
//
// Measured 2026-09-05, two consecutive runs at `5e00651`: `shots-contrast/inspector.png` and
// `technical-view.png` differed in exactly 25 pixels each, in a 5x5 box — the pulse dot inside
// the `WORKING` pill. `shots-26/ms-02-working-for-18s.png`, 42 pixels in a 10x10 box, same dot.
// Three files of churn from one CSS keyframe.
//
// So looping animations are pinned to phase 0 for the length of the capture and released
// immediately after. FINITE ones are left exactly as they are — a suite that waited for a fade
// gets the fade it waited for, and one that deliberately catches a rise mid-flight still does.
// The pin is scoped to the screenshot because `steering.js` and `workers.js` read the computed
// opacity of animated elements, and a harness that quietly left the page frozen would be
// answering their questions about a state the product never sits in.
async function pinLoops(page) {
  const pinned = await page
    .evaluate(() => {
      window.__richosPinnedLoops = [];
      for (const a of document.getAnimations()) {
        const timing = a.effect && a.effect.getComputedTiming ? a.effect.getComputedTiming() : null;
        if (!timing || timing.iterations !== Infinity) continue;
        try {
          a.pause();
          a.currentTime = 0;
          window.__richosPinnedLoops.push(a);
        } catch (_e) {
          /* an animation that refuses to be pinned is left running and reported by the count */
        }
      }
      return window.__richosPinnedLoops.length;
    })
    .catch(() => 0);
  if (pinned) {
    // Two frames: one for the style change to be taken up, one for it to be painted.
    await page
      .evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
      .catch(() => {});
  }
  return pinned;
}

/// Wait for every FINITE animation and transition on the page to finish, so the shutter opens
/// on a settled surface rather than partway through one.
///
/// Every suite in this directory was already doing this by hand and by guess —
/// `corrections.js` sleeps 300ms for a 160ms overlay fade, `updates.js` sleeps 150ms after
/// opening the menu, `retention.js` sleeps 120ms after the popover. A sleep is a bet that the
/// machine is not busy, and the bet loses quietly: measured 2026-09-05, two runs of
/// `updates.js` produced `updates-mark-on-the-button.png` differing in 1,085 pixels and
/// `updates-cue-opened-the-row.png` in 3,525, all of them inside the settings panel and none by
/// more than 3 of 255 — the panel photographed at 99-point-something percent of its fade rather
/// than at the end of it.
///
/// `Animation.finished` is the end state itself, so this waits on the thing rather than on a
/// number somebody chose. Bounded, because an animation can be paused or infinite and a
/// screenshot helper must not be able to hang a suite; the bound is generous and never silent
/// about what it gave up on — anything still running is either infinite (and `pinLoops` takes
/// it next) or a real stall the shot will show.
async function awaitSettled(page, timeoutMs) {
  const budget = timeoutMs || 2000;
  await page
    .evaluate(
      (ms) =>
        new Promise((resolve) => {
          const finite = document.getAnimations().filter((a) => {
            const t = a.effect && a.effect.getComputedTiming ? a.effect.getComputedTiming() : null;
            return t && t.iterations !== Infinity && a.playState === "running";
          });
          if (!finite.length) return resolve(0);
          const done = Promise.all(finite.map((a) => a.finished.catch(() => {})));
          const cap = new Promise((r) => setTimeout(r, ms));
          Promise.race([done, cap]).then(() => resolve(finite.length));
        }),
      budget
    )
    .catch(() => 0);
}

async function releaseLoops(page) {
  await page
    .evaluate(() => {
      for (const a of window.__richosPinnedLoops || []) {
        try {
          a.play();
        } catch (_e) {
          /* nothing to restore */
        }
      }
      window.__richosPinnedLoops = null;
    })
    .catch(() => {});
}

/// One capture, settled. Everything that opens a shutter in this directory goes through here:
/// the finite animations are waited out, the looping ones are pinned, the frame is taken, and
/// the page is handed back exactly as it was.
///
/// `opts.onShutter` runs at the INSTANT of capture, before anything slow. `splash.js` has to
/// prove its photograph is of the curtain and not of the screen behind it, and it was proving
/// that after a decode and a file comparison had finished — a second or more later, on a
/// surface whose ceiling is one second past its hold. That is a claim about a different moment.
async function captureSettled(page, opts) {
  opts = opts || {};
  // `opts.settleMs` shortens the wait for a caller that has ALREADY proved the surface is
  // settled some other way and is working against a clock. `splash.js` is the one: it waits for
  // the curtain's own bar to report it has landed, and then has exactly the one second of
  // ceiling grace to take the picture in.
  await awaitSettled(page, opts.settleMs);
  await pinLoops(page);
  try {
    const buf = await page.screenshot(opts.screenshot || {});
    if (opts.onShutter) await opts.onShutter();
    return buf;
  } finally {
    await releaseLoops(page);
  }
}

async function shot(page, name, opts) {
  opts = opts || {};
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  const file = path.join(SHOT_DIR, name + ".png");
  // Captured to a BUFFER and published, never straight to `path`: `page.screenshot({ path })`
  // writes every time it is called, which is the habit this replaces.
  const buf = await captureSettled(page, {
    screenshot: { fullPage: opts.fullPage !== false },
    settleMs: opts.settleMs,
    onShutter: opts.onShutter,
  });
  const bytes = publishShot(buf, file).bytes;

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

  // THE TWO DECODERS ARE JOINED HERE, on every shot. `publishShot` decides whether to write a
  // file by reading it with `./png.js`; the check above reads the SAME bytes with WebKit's own
  // decoder. If the two ever disagree about what image this is, the skip-when-unchanged rule
  // is being applied to a picture nobody has seen — so they are compared rather than each
  // trusted alone. Dimensions, because that is what both sides report about the whole image
  // without either one having to sample it the other's way.
  const local = png.decode(buf);
  if (local.width !== stats.width || local.height !== stats.height) {
    throw new Error(
      `${name}.png decodes as ${local.width}x${local.height} in lib/png.js and ` +
        `${stats.width}x${stats.height} in WebKit — the two decoders disagree, so no ` +
        `screenshot comparison in this directory can be trusted.`
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


// ---------------------------------------------------------------------------------------
// LEAVING THE HOME SCREEN
// ---------------------------------------------------------------------------------------

/// THE APP'S LANDING SURFACE MOVED (CEO, 2026-09-01): "This start screen/home screen ... must
/// be shown in the app after the splash screen." So `index.html` now opens on `#home`, which
/// covers the shell and marks `#app` inert — and every suite in this directory that drives the
/// APP UI has to do first what the CEO does first, which is leave it.
///
/// IT LEAVES THROUGH `RichHome.hide` AND NOT BY CLICKING THE CONTROL, deliberately. The visible
/// switch on the home screen is PROVISIONAL — the CEO is choosing the real affordance from six
/// designs (`round-11.2`) — and a suite that clicked it would go red the day he picks one,
/// with nothing about that suite's own subject having changed. `home.js` is where the control
/// itself is tested; this is only how the other suites get past it.
///
/// It also restores the theme: the home screen holds §15's always-dark clamp while it is up,
/// and `hide()` drops it, so a suite that asserts on light mode sees the CEO's own preference
/// rather than the clamp.
/// THE CURTAIN IS THE OTHER LAUNCH SURFACE, and it has to go the same way.
///
/// `splash.js` holds the opening screen for THREE SECONDS (`SPLASH_SECONDS`) and then fades it
/// over 180ms. It is `pointer-events: none`, so it is invisible to a hit test and to
/// `waitForSelector` — a suite that never mentions it drives the app perfectly well UNDERNEATH
/// it, and photographs it.
///
/// THAT IS NOT A COSMETIC PROBLEM, and it is the second half of what row r4 was about. Measured
/// 2026-09-05 across two consecutive runs on one machine at `5e00651`:
/// `shots-7-2/7-2-01-the-window-is-a-setting.png` differed in 83.8% of its pixels and
/// `7-2-03-a-window-that-is-on-no-menu.png` in 94.4% — not encoder noise, not antialiasing:
/// one run photographed the whole opening screen sitting over the settings panel and the next
/// did not. `retention.js` reaches its first shot either side of the three-second mark
/// depending on how busy the machine is, so the committed evidence flipped between two
/// completely different pictures, and a `git diff` could not tell that from a regression.
///
/// `appearance.js`, `contrast.js` and `updates.js` had each already written their own wait for
/// this, one line at a time, and the other twelve app-driving suites had not. So it moves here,
/// where the surface is left rather than where somebody remembered.
///
/// A SUITE THAT HOLDS THE CURTAIN ON PURPOSE IS NOT OVERRIDDEN. `appearance.js` and
/// `contrast.js` neuter `yieldNow` before splash.js installs itself, precisely so the
/// composition can be photographed as it ships. That is detected — the yield leaves
/// `state.reason` null — and this returns immediately rather than waiting out a timeout for a
/// curtain that was asked to stay.
async function leaveSplash(page) {
  const outcome = await page
    .evaluate(() => {
      const s = window.RichSplash;
      if (!s || !s.state) return "absent";
      // It declined to draw (switched off, or not a fresh start), or it has already gone.
      if (!s.state.shown) return "not-drawn";
      if (s.state.reason) return "already-yielding";
      // A reason of our own, never "app-ready": that one WAITS OUT the remainder of the hold
      // by design, which is the three seconds this is here to stop paying.
      s.yieldNow("acceptance-suite");
      return s.state.reason ? "yielded" : "held";
    })
    .catch(() => "absent");
  if (outcome === "absent" || outcome === "not-drawn" || outcome === "held") return outcome;
  // The end state, not a timer: `removeSelf` takes the node out 220ms after the yield.
  await page.waitForFunction(() => !document.getElementById("splash"), { timeout: 5000 });
  return outcome;
}

async function leaveHome(page) {
  // The curtain first: it is ABOVE the home screen, and `RichHome.hide()` deliberately keeps
  // §15's always-dark clamp raised while it is still up (`home.js`'s `splashStillUp`). Clearing
  // it first is what lets one call leave a CEO on light mode actually on light mode.
  await leaveSplash(page);
  const present = await page
    .waitForFunction("typeof window.RichHome === 'object'", { timeout: 5000 })
    .then(() => true)
    .catch(() => false);
  if (!present) return false;
  await page.evaluate(() => {
    if (window.RichHome && window.RichHome.isOpen()) window.RichHome.hide("acceptance-suite");
  });
  // `hide()` fades before it un-mounts, so the wait is on the end state and not on a timer.
  await page.waitForFunction(() => {
    const h = document.getElementById("home");
    return !h || h.hidden;
  });
  return true;
}

module.exports = {
  loadPlaywright,
  openFixture,
  leaveHome,
  leaveSplash,
  skipSuite,
  shot,
  captureSettled,
  publishShot,
  publishShotFile,
  createRun,
  assert,
  assertEqual,
  rustSentenceAfter,
  UI_DIR,
  SHOT_DIR,
};

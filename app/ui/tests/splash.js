// THE OPENING SCREEN — the surface, its library, its honest states, and its off switch.
//
// Driven through the REAL SHELL: `index.html`, `splash.css`, `splash-library.js`,
// `splash.js`, `style.css` and `main.js`, all loaded from disk, under WebKit — the engine
// Tauri renders through on macOS (`lib/harness.js` rule 2). Nothing is stubbed that
// `mock.js` does not already own.
//
// The completion criterion this suite exists to make observable, in the words it was set in:
// launch the app repeatedly and see different variations, with a measured number showing
// the splash adds no time to launch, then turn it off and see it stay off.
//
// TWO HARNESS-SIDE PATCHES ARE USED, both named here rather than buried:
//
//   * `holdOpen()` replaces the EXPORTED `RichSplash.yieldNow` with a no-op so a surface
//     that is over in a quarter of a second can be photographed. It patches only the
//     export, which is only what `main.js` calls — the internal ceiling timer and the two
//     input listeners hold their own reference and are untouched, which is exactly what
//     makes check 10 able to observe the ceiling with the app-ready path muted.
//   * `forceVariation()` replaces the library the page is about to receive with a
//     one-entry version of itself, so a specific composition can be asserted on. It filters
//     the SHIPPED library; it never supplies one.
//
// Run: node splash.js   (or `npm test` for every suite in this directory)

"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { leaveHome, loadPlaywright, shot, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");
const { contrastRatio, round2, hex } = require("./lib/contrast");

const APP = "file://" + path.join(UI_DIR, "index.html");
const LIB_FILE = path.join(UI_DIR, "splash-library.js");
const RENDERER_FILE = path.join(UI_DIR, "splash.js");
const CSS_FILE = path.join(UI_DIR, "splash.css");
const MAIN_JS = path.join(UI_DIR, "main.js");
const MAIN_RS = path.resolve(UI_DIR, "..", "src-tauri", "src", "main.rs");
const CONFIG_RS = path.resolve(UI_DIR, "..", "crates", "richos-core", "src", "config.rs");
const LAUNCH_RS = path.resolve(UI_DIR, "..", "crates", "richos-core", "src", "launch.rs");
const SHOTS = path.join(__dirname, "shots-splash");

/// WHERE THE STUDIES LIVE, and why this is a lookup rather than a path. The round-8.1
/// mockups are in a DIFFERENT REPOSITORY (`richos-hq`), which is why every entry's `source`
/// names them by that repository rather than by a relative path. Check 18 photographs the
/// shipping renderer either way; it can only put the study beside it on a machine that has
/// one, and it says which of the two it did.
const HQ = process.env.RICHOS_HQ || path.join(os.homedir(), "ab", "richos-hq");

/// The study an ENTRY says it came from. Reading it out of `source` rather than rebuilding
/// it from the id is the point: `source` stops being a comment and becomes a claim that
/// check 18 goes and tests.
function studyOf(entry) {
  const m = /^richos-hq (\S+)$/.exec(entry.source);
  return m ? path.join(HQ, m[1]) : null;
}

/// The library, read the way check 1 proves it can be read: as JSON.
///
/// THE FAILURE IS CAUGHT, NOT THROWN, and that is not tidiness. The first version of this
/// parsed at module load, so a library file that had grown a function took the whole suite
/// down before check 1 existed — `run.js` would have reported it correctly as a suite that
/// produced no evidence, but the check written to catch exactly that would never have run
/// and could never have been shown to go red. A check that cannot fail out loud is the
/// thing this directory's whole evidence gate exists to refuse.
let LIBRARY_ERROR = null;
function libraryFromDisk() {
  try {
    const src = fs.readFileSync(LIB_FILE, "utf8");
    const at = src.indexOf("window.RichSplashLibrary =");
    if (at < 0) throw new Error("splash-library.js does not assign window.RichSplashLibrary");
    const body = src.slice(at + "window.RichSplashLibrary =".length).trim().replace(/;\s*$/, "");
    return JSON.parse(body);
  } catch (e) {
    LIBRARY_ERROR = (e && e.message) || String(e);
    return { schemaVersion: null, round: null, variations: [] };
  }
}
const LIBRARY = libraryFromDisk();

/// `#RRGGBB` as the `rgb(r, g, b)` a computed style reports. The expected colour is always
/// derived from the library rather than typed here — a hex written into this file would be
/// a second copy of a value the whole design says lives in one place.
function rgbOf(hex) {
  const h = hex.replace("#", "");
  const n = parseInt(h, 16);
  return `rgb(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255})`;
}

// ---------------------------------------------------------------------------------------
// Driving the shell
// ---------------------------------------------------------------------------------------

const HOLD_OPEN = () => {
  let sp;
  Object.defineProperty(window, "RichSplash", {
    configurable: true,
    get: () => sp,
    set: (x) => {
      sp = x;
      x.yieldNow = function () {};
    },
  });
};

/// Shape the library on its way into the page: keep one entry, and/or hand every entry a
/// `seconds`. ONE script rather than two, because both work by `defineProperty` on the same
/// property and the second installed would silently replace the first.
const SHAPE = (o) => {
  let lib;
  Object.defineProperty(window, "RichSplashLibrary", {
    configurable: true,
    get: () => lib,
    set: (x) => {
      const kept = JSON.parse(JSON.stringify(x.variations.filter((v) => !o.id || v.id === o.id)));
      if (o.seconds != null) kept.forEach((v) => (v.tokens.seconds = String(o.seconds)));
      lib = { schemaVersion: x.schemaVersion, round: x.round, variations: kept };
    },
  });
};

// ---------------------------------------------------------------------------------------
// THE CURTAIN'S OWN CLOCK — and the reason every timing check in this file now reads it
// ---------------------------------------------------------------------------------------
//
// THE DEFECT, IN ONE SENTENCE: this suite used to time the product from the moment
// `page.goto()` RETURNED, which is a fact about the harness and not about the curtain.
//
// `goto` resolves on `load`, and `load` waits for every subresource; the curtain is inserted
// far earlier, during script execution. On this machine the gap between the two is ~55 ms
// (measured over six launches, 10-22 ms into the page for the insert, 51-72 ms for the first
// instruction after it) and every check here was written inside that margin. On the first
// public `ui-suite-ci` runner the gap was ~2,000 ms, and eight of this suite's twenty-five
// checks went red at once:
//
//   * 12b measured a 3,000 ms hold as 1,024 ms — it had started its stopwatch two seconds
//     into the hold;
//   * 8 sampled "300 ms in, before the bar starts at 600 ms" and read a bar 331 px along;
//   * 12c got its keystroke in after the hold had already been served, so the surface
//     reported "held" where the check demanded "first-input";
//   * 15, 18 and 23 dereferenced `#splash` after the ceiling had taken it away;
//   * 22 got 8 samples of a bar it needed 40 of.
//
// One cause, six symptoms, and none of them a fault in the product.
//
// So the harness stops keeping its own clock. This script goes in before any page script and
// records, ON THE PAGE'S OWN `performance.now()`: when the curtain went up, when it came
// down, when the first key reached it, and — where a reading has to be taken at an instant
// the harness cannot be trusted to be present for — the reading itself, sampled by a timer
// inside the page. A check then asks for a fact instead of racing to observe one.
//
// WHAT IT DOES NOT DO is hold the curtain open. The ceiling is the product's failsafe and
// check 10 exists to watch it fire; a harness that defeated it would be testing a surface
// nobody ships. Checks that need longer than the default ceremony ASK for it, through the
// `seconds` token the product already supports, and say so at the call site.
const CURTAIN_CLOCK = (cfg) => {
  cfg = cfg || {};
  const c = { shownAt: null, goneAt: null, firstKeyAt: null, mid: null, trace: [] };
  window.__curtain = c;

  const bits = () => {
    const n = document.getElementById("splash");
    if (!n) return null;
    const fill = n.querySelector('.splash-bar [data-role="progress"]');
    // The run, not the track — see check 22. An entry with no rhythm uses the strap itself,
    // so the two are the same element there.
    const track = n.querySelector('.splash-bar [data-role="rhythm"]') || n.querySelector(".splash-bar");
    return fill && track ? { n, fill, track } : null;
  };

  const readMid = () => {
    const b = bits();
    if (!b) return { gone: true };
    const foot = b.n.querySelector(".splash-rise--4");
    return {
      at: Math.round(performance.now() - c.shownAt),
      fill: Math.round(b.fill.getBoundingClientRect().width),
      track: Math.round(b.track.getBoundingClientRect().width),
      foot: Number(getComputedStyle(foot).opacity),
      settled: b.n.classList.contains("splash--settled"),
      reason: window.RichSplash.state.reason,
    };
  };

  const onShown = () => {
    c.shownAt = performance.now();
    if (cfg.midAt != null) setTimeout(() => { c.mid = readMid(); }, cfg.midAt);
    if (cfg.trace) {
      const every = cfg.every || 40;
      const step = () => {
        const b = bits();
        if (!b) return;
        c.trace.push({
          t: performance.now() - c.shownAt,
          p: b.fill.getBoundingClientRect().width / b.track.getBoundingClientRect().width,
        });
        setTimeout(step, every);
      };
      step();
    }
  };

  new MutationObserver(() => {
    const there = !!document.getElementById("splash");
    if (there && c.shownAt === null) onShown();
    else if (!there && c.shownAt !== null && c.goneAt === null) c.goneAt = performance.now();
  }).observe(document, { childList: true, subtree: true });

  // Capture phase and installed first, so this sees the key whatever the surface does with
  // it. It only records; it never consumes.
  window.addEventListener("keydown", () => {
    if (c.firstKeyAt === null) c.firstKeyAt = performance.now();
  }, true);
};

/// A DELIBERATE SLOW RUNNER, on demand. `RICHOS_SPLASH_LAG_MS=2000 node splash.js`
/// reproduces the ~2,000 ms harness lag a GitHub `macos-latest` runner produced on
/// 2026-09-04 — which is the only way to run the fixed checks against the condition that
/// broke them without waiting for a real run. Zero, and no delay at all, unless it is set.
const LAG_MS = Number(process.env.RICHOS_SPLASH_LAG_MS || 0);
const lag = async (page) => {
  if (LAG_MS > 0) await page.waitForTimeout(LAG_MS);
};

/// Wait until the PAGE says `ms` have passed since the curtain went up. Returns immediately
/// if that instant is already behind us — the point is never to add the harness's own
/// latency to the product's clock, not to guarantee the harness was quick.
async function atCurtain(page, ms) {
  await page.waitForFunction(
    (m) => window.__curtain && window.__curtain.shownAt !== null && performance.now() - window.__curtain.shownAt >= m,
    ms,
    { timeout: 20000 }
  );
}

/// Is the curtain still up, and how far into its life are we? Used to fail a check that
/// arrived too late OUT LOUD, rather than letting it read a null and blame the product.
const curtainNow = (page) =>
  page.evaluate(() => {
    const c = window.__curtain || {};
    return {
      up: !!document.getElementById("splash"),
      shownAt: c.shownAt,
      goneAt: c.goneAt,
      age: c.shownAt == null ? null : Math.round(performance.now() - c.shownAt),
      life: c.shownAt == null || c.goneAt == null ? null : Math.round(c.goneAt - c.shownAt),
    };
  });

/// The curtain must still be on screen for what comes next. A check that has fallen behind
/// its own subject says THAT, instead of dereferencing a node that is not there.
async function stillUp(page, what) {
  const c = await curtainNow(page);
  assert(
    c.up,
    what + ": the curtain was already gone " + (c.life == null ? "" : "(it lived " + c.life + "ms) ") +
      "— this check fell behind the surface it is measuring, which is a harness fault, not a product one"
  );
  return c;
}

const MARK_READY = () => {
  let sp;
  Object.defineProperty(window, "RichSplash", {
    configurable: true,
    get: () => sp,
    set: (x) => {
      sp = x;
      const orig = x.yieldNow;
      x.yieldNow = function (reason) {
        if (reason === "app-ready" && window.__readyAt == null) window.__readyAt = performance.now();
        return orig.apply(this, arguments);
      };
    },
  });
};

async function newPage(ctx) {
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  page.__errors = errors;
  return page;
}

/// A launch. `opts.hold` photographs it, `opts.force` chooses the composition, `opts.off`
/// starts from a machine where the CEO has already switched it off.
async function launch(browser, opts) {
  opts = opts || {};
  const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1280, height: 800 } });
  const page = await newPage(ctx);
  if (opts.off) await page.addInitScript(() => window.localStorage.setItem("richos.splash.enabled", "false"));
  // FIRST, so the clock is running before anything else the page or this suite does.
  await page.addInitScript(CURTAIN_CLOCK, opts.clock || {});
  if (opts.hold) await page.addInitScript(HOLD_OPEN);
  if (opts.force || opts.seconds != null) {
    await page.addInitScript(SHAPE, { id: opts.force || null, seconds: opts.seconds == null ? null : opts.seconds });
  }
  if (opts.init) await page.addInitScript(opts.init, opts.initArg);
  await page.goto(APP);
  await lag(page);
  page.__ctx = ctx;
  return page;
}

const splashState = (page) =>
  page.evaluate(() => {
    const n = document.getElementById("splash");
    return {
      present: !!n,
      variation: n ? n.dataset.variation : null,
      state: JSON.parse(JSON.stringify(window.RichSplash.state)),
    };
  });

/// A settled screenshot of the composition, copied into `shots-splash/` beside the suite.
/// ON THE CURTAIN'S CLOCK, AND PROVED TO BE OF THE CURTAIN.
///
/// This waited 3,000 ms from `goto` returning and photographed whatever was on screen. On the
/// first public runner that instant was ~5,000 ms into a surface with a 4,000 ms ceiling, so
/// what it photographed was the HOME SCREEN — and check 5 passed, because `shot()` only asks
/// a PNG to have more than eight distinct colors and a home screen has thousands. The
/// evidence file in that run carries 8,283 distinct colors against 464 here, which is the two
/// pictures being different pictures.
///
/// A green check over a photograph of the wrong screen is exactly what this directory's
/// evidence gate exists to refuse, so the wait is now the page's and the surface is
/// ASSERTED, before and after the shutter.
async function settledShot(page, name) {
  // 2,000 ms rather than 3,000: the four `splash-rise` stages are landed by ~1.4 s (delay
  // 0.48 s over a 0.9 s curve), so this is the settled composition either way, and it leaves
  // twice the room before the ceiling for the shutter itself.
  await atCurtain(page, 2000);
  await stillUp(page, "the settled photograph");
  fs.mkdirSync(SHOTS, { recursive: true });
  const s = await shot(page, name, { fullPage: false });
  const after = await curtainNow(page);
  assert(after.up, name + ": the curtain left DURING the exposure — this photograph is of the screen behind it");
  fs.copyFileSync(s.file, path.join(SHOTS, name + ".png"));
  return name + ".png (" + s.width + "x" + s.height + ", " + s.distinct + " distinct colors, taken " + after.age + "ms into the curtain)";
}

/// A photograph of the MAT ALONE, and what was laid on it. `mute` empties the entry's
/// material stack and changes nothing else — which is what makes check 15's comparison a
/// comparison of the material rather than of two different versions.
async function matShot(browser, id, mute) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await newPage(ctx);
  await page.addInitScript(CURTAIN_CLOCK, {});
  await page.addInitScript(HOLD_OPEN);
  await page.addInitScript((o) => {
    let lib;
    Object.defineProperty(window, "RichSplashLibrary", {
      configurable: true,
      get: () => lib,
      set: (x) => {
        lib = {
          schemaVersion: x.schemaVersion,
          round: x.round,
          variations: x.variations.filter((v) => v.id === o.id).map((v) => {
            const c = JSON.parse(JSON.stringify(v));
            if (o.mute) c.tokens.materials = [];
            // FIVE SECONDS, THROUGH THE PRODUCT'S OWN TOKEN, and it changes nothing in the
            // photograph. The clip is the PLINTH, and the bar is the plinth's SIBLING inside
            // the rising frame — so the one element the hold's length moves is not in the
            // frame. What it buys is a 6,000 ms ceiling instead of 4,000 for a page that has
            // to survive a measurement and a screenshot, on a runner where the harness's
            // first instruction landed ~2,000 ms in.
            c.tokens.seconds = "5";
            return c;
          }),
        };
      },
    });
  }, { id, mute });
  await page.goto(APP);
  await lag(page);
  await atCurtain(page, 2200);
  await stillUp(page, "the mat photograph for " + id);
  const r = await page.evaluate(() => {
    const n = document.querySelector("#splash .splash-plinth");
    const q = n.getBoundingClientRect();
    const kids = Array.from(n.children);
    const mats = kids.filter((c) => c.classList.contains("splash-material"));
    const rises = kids.filter((c) => c.classList.contains("splash-rise"));
    const first = rises.length ? kids.indexOf(rises[0]) : Number.POSITIVE_INFINITY;
    return {
      clip: { x: Math.round(q.x), y: Math.round(q.y), width: Math.round(q.width), height: Math.round(q.height) },
      layers: mats.length,
      above: mats.filter((m) => kids.indexOf(m) > first).length,
    };
  });
  const png = (await page.screenshot({ clip: r.clip })).toString("base64");
  const after = await curtainNow(page);
  assert(after.up, id + ": the curtain left during the mat exposure — this is a photograph of the screen behind it");
  assert(page.__errors.length === 0, id + " errors: " + page.__errors.join("; "));
  await ctx.close();
  return { png, layers: r.layers, above: r.above };
}

/// Two PNGs, decoded by the same engine that painted them and compared pixel for pixel. A
/// channel has to move by MORE THAN 3 to count, so subpixel antialiasing noise cannot
/// manufacture a difference; mismatched sizes report 0% rather than throwing, which fails
/// the check that called this rather than the run.
const DIFF = async (pair) => {
  const load = (s) =>
    new Promise((res, rej) => {
      const i = new Image();
      i.onload = () => res(i);
      i.onerror = () => rej(new Error("a PNG did not decode"));
      i.src = "data:image/png;base64," + s;
    });
  const [ia, ib] = await Promise.all([load(pair[0]), load(pair[1])]);
  const px = (i) => {
    const c = document.createElement("canvas");
    c.width = i.naturalWidth;
    c.height = i.naturalHeight;
    const x = c.getContext("2d");
    x.drawImage(i, 0, 0);
    return x.getImageData(0, 0, c.width, c.height).data;
  };
  const A = px(ia);
  const B = px(ib);
  if (A.length !== B.length) return { changed: 0, sampled: 0, pct: 0 };
  let n = 0;
  let s = 0;
  for (let i = 0; i < A.length; i += 4) {
    s++;
    if (Math.abs(A[i] - B[i]) > 3 || Math.abs(A[i + 1] - B[i + 1]) > 3 || Math.abs(A[i + 2] - B[i + 2]) > 3) n++;
  }
  return { changed: n, sampled: s, pct: (100 * n) / s };
};

/// Two mats into one picture, drawn by the same engine that painted both, with a label over
/// each so the file says what it is without a caption anywhere else. `b` may be null on a
/// machine that does not have the study repository — the shipping side is still the
/// evidence, and the label says so.
const SIDE_BY_SIDE = async (o) => {
  const load = (s) =>
    new Promise((res, rej) => {
      const i = new Image();
      i.onload = () => res(i);
      i.onerror = () => rej(new Error("a PNG did not decode"));
      i.src = "data:image/png;base64," + s;
    });
  const a = await load(o.a);
  const b = o.b ? await load(o.b) : null;
  const GAP = 14;
  const BAR = 24;
  // THE WHOLE MAT AT HALF SCALE, AND A CORNER OF IT AT FULL. Both are needed and neither is
  // enough: half scale shows the material across the mat and loses the pitch of a stitch,
  // and a native crop shows the stitch and loses the mat. Together they are 38% of the
  // pixels of a native-scale pair, which matters because these are rewritten on every run
  // and a megabyte of grain is a megabyte of binary diff every time.
  const S = 0.5;
  const CW = 300;
  const CH = 220;
  const halfW = Math.round(a.naturalWidth * S);
  const halfH = Math.round(a.naturalHeight * S);
  const w = Math.max(halfW * (b ? 2 : 1) + (b ? GAP : 0), CW * (b ? 2 : 1) + (b ? GAP : 0));
  const h = BAR + halfH + BAR + CH;
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  const x = c.getContext("2d");
  x.fillStyle = "rgb(8,12,22)";
  x.fillRect(0, 0, w, h);
  x.imageSmoothingEnabled = true;
  x.drawImage(a, 0, BAR, halfW, halfH);
  if (b) x.drawImage(b, halfW + GAP, BAR, Math.round(b.naturalWidth * S), Math.round(b.naturalHeight * S));
  // The corner: native pixels, from the same place in both, where the keyline, the corner
  // treatment and the material field all are.
  x.drawImage(a, 0, 0, CW, CH, 0, BAR + halfH + BAR, CW, CH);
  if (b) x.drawImage(b, 0, 0, CW, CH, CW + GAP, BAR + halfH + BAR, CW, CH);
  x.fillStyle = "rgb(150,168,200)";
  // The caption on the comparison sheet. Named the vendored family rather than three
  // platform faces — this is evidence, not product, so nothing here reaches a customer,
  // but a platform face name is a platform face name and leaving one here is how the next
  // person learns that the rule has exceptions (ceo-decisions.md §22).
  x.font = "12px Inter, sans-serif";
  x.fillText(o.left + " — whole mat, half scale", 2, 16);
  if (b) x.fillText(o.right + " — whole mat, half scale", halfW + GAP + 2, 16);
  x.fillText(o.left + " — top-left corner, native", 2, BAR + halfH + 16);
  if (b) x.fillText(o.right + " — top-left corner, native", CW + GAP + 2, BAR + halfH + 16);
  return c.toDataURL("image/png").split(",")[1];
};

// ---------------------------------------------------------------------------------------
// TWO RELIEF SPECS, AS FIXTURES — and why they are fixtures and not entries.
//
// `relief` is an SVG filter written as values: a noise field clipped inside the mark, and
// bands of shadow or light laid inside or outside it. It is the mechanism behind "blocked
// into leather", "cut into slate" and "dusted with maki-e gold", and it is not going
// anywhere: the CEO has said the splash array grows, and the material studies it was built
// for are the obvious source of later screens.
//
// NEITHER OF THE TWO APPROVED SCREENS USES ONE. So checks 16 and 17 had a choice: keep an
// unapproved round-8.1 composition in the SHIPPING library to have something to test, or
// test the mechanism against a fixture. Keeping a screen the CEO has not approved alive in
// the product to satisfy a test is the tail wagging the product, so these are fixtures —
// verbatim the specs the removed `round-8.1/v8` (bridle leather, the mark blocked in) and
// `round-8.1/v10` (urushi lacquer, dusted with maki-e gold) carried, which is what makes
// them a real exercise of the filter rather than a shape invented to pass.
//
// They are injected onto a SHIPPED entry on its way into the page. Nothing on disk changes.
const RELIEF_FIXTURES = {
  /// Bands only, on the whole mark: two inner bands, which is a letterform pressed INTO the
  /// material. There is no CSS filter function for an inner shadow on an SVG shape, which is
  /// the entire reason this mechanism is an SVG filter.
  mark: {
    target: "mark",
    region: "-20% -20% 140% 140%",
    noise: null,
    matrix: null,
    bands: [
      { color: "#000008", opacity: ".55", dx: "0", dy: "2.2", blur: "1.4", placement: "inner" },
      { color: "#FFF3DA", opacity: ".26", dx: "0", dy: "-1.6", blur: "1.2", placement: "inner" },
    ],
  },
  /// A noise field and no bands, on the gold alone: dust sitting in the lacquered arrow,
  /// with the ink left flat. The other half of the vocabulary.
  signal: {
    target: "signal",
    region: "-5% -5% 110% 110%",
    noise: { type: "fractalNoise", baseFrequency: "0.9", octaves: "2", seed: "11" },
    matrix: "0 0 0 0 1  0 0 0 0 0.92  0 0 0 0 0.62  1.5 1.5 0 0 -1.35",
    bands: [],
  },
};

/// What WebKit actually built, read out of the page. Shared by both halves of check 16 and
/// written once so the two cannot drift.
const READ_RELIEF = () => {
  const n = document.querySelector("#splash filter#richos-splash-relief");
  const cs = (sel) => getComputedStyle(document.querySelector("#splash " + sel)).filter;
  return {
    present: !!n,
    region: n ? [n.getAttribute("x"), n.getAttribute("y"), n.getAttribute("width"), n.getAttribute("height")].join(" ") : null,
    floods: n ? Array.from(n.querySelectorAll("feFlood")).map((e) => e.getAttribute("flood-color") + "@" + e.getAttribute("flood-opacity")) : [],
    offsets: n ? Array.from(n.querySelectorAll("feOffset")).map((e) => e.getAttribute("dx") + "," + e.getAttribute("dy")) : [],
    blurs: n ? Array.from(n.querySelectorAll("feGaussianBlur")).map((e) => e.getAttribute("stdDeviation")) : [],
    noise:
      n && n.querySelector("feTurbulence")
        ? ["type", "baseFrequency", "numOctaves", "seed"].map((a) => n.querySelector("feTurbulence").getAttribute(a)).join(" ")
        : null,
    merge: n ? Array.from(n.querySelectorAll("feMerge feMergeNode")).map((e) => e.getAttribute("in")) : [],
    ink: cs(".splash-ink"),
    signal: cs(".splash-signal"),
    // What the ENTRY asked for, as opposed to what is on the element right now: a screen
    // performing a strike is mid-`filter`-animation at this instant, so the computed value
    // there is the ceremony, not the entry's answer.
    inkVar: document.getElementById("splash").style.getPropertyValue("--splash-mark-filter"),
    signalVar: document.getElementById("splash").style.getPropertyValue("--splash-signal-filter"),
  };
};

/// Hand one shipped entry a relief on its way into the page, and keep only that entry.
const WITH_RELIEF = (o) => {
  let lib;
  Object.defineProperty(window, "RichSplashLibrary", {
    configurable: true,
    get: () => lib,
    set: (x) => {
      const one = JSON.parse(JSON.stringify(x.variations.find((v) => v.id === o.id)));
      one.tokens.relief = o.relief;
      lib = { schemaVersion: x.schemaVersion, round: x.round, variations: [one] };
    },
  });
};

/// SAMPLE A COMPOSITED SCREENSHOT, which is the only place this surface's real colors are.
///
/// Not the CSS values, and this is the whole point of measuring here rather than in
/// `tests/contrast.js`: the opening screen puts a `mix-blend-mode: soft-light` lamp, a
/// vignette and a `mix-blend-mode: overlay` grain ABOVE the plinth. What a DOM checker reads
/// off `.splash-line` is not what the eye receives, and `contrast-debt.json` already records
/// that as a named `knownUnresolvable`. A photograph has no such problem.
///
/// Two modes, and they are the ones the round-11 study used so the two sets of numbers are
/// comparable:
///
///   "bright"  the median of the brightest 5% of pixels in the box — a glyph's core, or a
///             thread's, rather than its antialiased edge, which would understate it.
///   "mode"    the modal color of the box, quantized to 4 levels per channel — a flat
///             background, unaffected by anything that happens to cross the box.
const SAMPLE = async (o) => {
  const img = await new Promise((res, rej) => {
    const i = new Image();
    i.onload = () => res(i);
    i.onerror = () => rej(new Error("the screenshot did not decode"));
    i.src = "data:image/png;base64," + o.png;
  });
  const c = document.createElement("canvas");
  c.width = img.naturalWidth;
  c.height = img.naturalHeight;
  const x = c.getContext("2d");
  x.drawImage(img, 0, 0);
  return o.rects.map((r) => {
    const w = Math.max(1, Math.round(r.w * o.dpr));
    const h = Math.max(1, Math.round(r.h * o.dpr));
    const d = x.getImageData(Math.round(r.x * o.dpr), Math.round(r.y * o.dpr), w, h).data;
    const px = [];
    for (let i = 0; i < d.length; i += 4) px.push([d[i], d[i + 1], d[i + 2]]);
    if (r.mode === "bright") {
      px.sort((a, b) => b[0] + b[1] + b[2] - (a[0] + a[1] + a[2]));
      const n = Math.max(1, Math.round(px.length * 0.05));
      const top = px.slice(0, n);
      const mid = top[top.length >> 1];
      return { r: mid[0], g: mid[1], b: mid[2], n: px.length };
    }
    const bins = new Map();
    for (const p of px) {
      const k = ((p[0] >> 6) << 8) | ((p[1] >> 6) << 4) | (p[2] >> 6);
      const e = bins.get(k) || { n: 0, r: 0, g: 0, b: 0 };
      e.n++;
      e.r += p[0];
      e.g += p[1];
      e.b += p[2];
      bins.set(k, e);
    }
    let best = null;
    for (const e of bins.values()) if (!best || e.n > best.n) best = e;
    return { r: Math.round(best.r / best.n), g: Math.round(best.g / best.n), b: Math.round(best.b / best.n), n: px.length };
  });
};

/// The median of a list of numbers, which is what every launch figure below is reported as:
/// one slow run on a loaded laptop must not be able to move the answer.
function median(xs) {
  const s = xs.slice().sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// ---------------------------------------------------------------------------------------

async function main() {
  const run = createRun("the opening screen — his two screens, his order, a bar that runs once, and no delay");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const shotNames = [];

  // ---- the library is data, and the renderer holds none of it ---------------------------

  await run.check("1  the library is DATA — it parses as JSON, so it cannot contain code", async () => {
    // The rule the whole feature rests on: adding a variation is adding an entry. A file
    // that JSON.parses has no function in it, no branch in it and no way to render
    // anything — which is the only form of that promise that cannot quietly stop being
    // true. `libraryFromDisk()` already threw if it did not parse; this joins the parsed
    // text to what the page actually receives, so the two cannot drift either.
    assertEqual(LIBRARY_ERROR, null, "splash-library.js is not JSON");
    const page = await launch(browser, { hold: true });
    const inPage = await page.evaluate(() => JSON.parse(JSON.stringify(window.RichSplashLibrary)));
    assertEqual(inPage, LIBRARY, "the page's library is not the file's library");
    assertEqual(typeof LIBRARY.schemaVersion, "number", "schemaVersion");
    assert(Array.isArray(LIBRARY.variations) && LIBRARY.variations.length >= 1, "variations");

    // AND EVERY ENTRY IS A SPLASH SCREEN HE APPROVED AS ONE.
    //
    // The count is not pinned, because the CEO has said the array grows: "eventually, there
    // will be many splash screens added to the array". What IS pinned is the mistake this
    // library was making — eighteen round-8.1 PALETTE STUDIES were shipping as splash
    // screens on the strength of an approval that was of a palette and a visual standard
    // (`ceo-decisions.md` §14), not of eighteen opening ceremonies. A round-8.1 id here is
    // that mistake coming back, so it is refused by name.
    //
    // The second half is his definition: "A splash screen is something that has a 'loading'
    // progress bar under the `plinth` element." An entry without a bar is not one.
    for (const v of LIBRARY.variations) {
      assert(
        !/^round-8\.1\//.test(v.id),
        v.id + " is a round-8.1 palette study. Round 8.1 was approved as a palette and a " +
          "visual standard, never as a set of splash screens."
      );
      assert(v.tokens.bar && Array.isArray(v.tokens.bar.layers) && v.tokens.bar.layers.length,
        v.id + " carries no loading bar, so it is not a splash screen");
      assert(
        v.tokens.bar.layers.some((l) => l.role === "progress"),
        v.id + "'s bar has no layer that progresses — it is a decoration, not a loading bar"
      );
    }
    await page.__ctx.close();
    return `${LIBRARY.variations.length} entries (${LIBRARY.variations.map((v) => v.id).join(", ")}), ` +
      `round ${LIBRARY.round}, JSON-parsed from disk and matching the page, each with a progressing bar`;
  });

  await run.check("2  the RENDERER carries no variation value — not one colour literal", async () => {
    // The other half of the same promise, from the other side. If a hex can live in
    // `splash.js`, then one day a variation will be half data and half code, and adding the
    // next one will mean editing the renderer after all.
    const src = fs.readFileSync(RENDERER_FILE, "utf8");
    const hex = src.match(/#[0-9a-fA-F]{3,8}(?![0-9a-zA-Z_-])/g) || [];
    const funcs = src.match(/\b(rgba?|hsla?|color-mix)\s*\(/g) || [];
    assertEqual(hex, [], "hex colour literal(s) in splash.js");
    assertEqual(funcs, [], "colour function(s) in splash.js");
    // And the stylesheet holds structure, not values: every colour it paints comes through
    // a custom property. The one exception is the transparent stop the studies themselves
    // write into the lamp gradient, which is not a colour choice.
    const css = fs.readFileSync(CSS_FILE, "utf8");
    const cssHex = css.match(/#[0-9a-fA-F]{3,8}(?![0-9a-zA-Z_-])/g) || [];
    assertEqual(cssHex, [], "hex colour literal(s) in splash.css");
    const cssRgba = (css.match(/rgba?\([^)]*\)/g) || []).filter((c) => !/rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\)/.test(c));
    assertEqual(cssRgba, [], "non-transparent colour literal(s) in splash.css");
    return "splash.js: 0 hex, 0 colour functions · splash.css: 0 hex, 0 opaque colour literals";
  });

  await run.check("3  every entry the library ships actually draws", async () => {
    // A library is only data if the renderer will take all of it. Each entry is forced in
    // turn and has to produce the whole composition — the mat, both marks, the rule — with
    // a real paint behind it, not a flat fill (`lib/harness.js` rule 3).
    const drawn = [];
    for (const v of LIBRARY.variations) {
      const page = await launch(browser, { hold: true, force: v.id });
      const r = await page.evaluate(() => {
        const n = document.getElementById("splash");
        if (!n) return null;
        return {
          id: n.dataset.variation,
          plinth: !!n.querySelector(".splash-plinth"),
          logo: n.querySelectorAll(".splash-logo path").length,
          wordmark: n.querySelectorAll(".splash-wordmark path").length,
          rule: !!n.querySelector(".splash-rule"),
          signal: n.querySelectorAll(".splash-signal").length,
          bar: !!n.querySelector(".splash-bar"),
          barLayers: n.querySelectorAll(".splash-bar .splash-bar-layer").length,
          // The bar is EXACTLY as wide as the plinth, at whatever size the window is. That
          // is the CEO's own framing — the bar is "under the `plinth` element" — and it is
          // the difference between a composition and two things that happen to be stacked.
          barW: n.querySelector(".splash-bar") ? Math.round(n.querySelector(".splash-bar").getBoundingClientRect().width) : -1,
          plinthW: Math.round(n.querySelector(".splash-plinth").getBoundingClientRect().width),
        };
      });
      assert(r, "nothing drawn for " + v.id);
      assertEqual(r.id, v.id, "the forced entry is the one drawn");
      assert(r.plinth && r.rule, v.id + ": the composition is incomplete");
      assert(r.bar, v.id + ": no loading bar was drawn");
      assertEqual(r.barLayers, v.tokens.bar.layers.length, v.id + ": the bar in the DOM is not the bar in the entry");
      assertEqual(r.barW, r.plinthW, v.id + ": the bar is not the width of the plinth");
      assert(r.logo === 2, v.id + ": the mark has " + r.logo + " paths");
      assert(r.wordmark === 7, v.id + ": the wordmark has " + r.wordmark + " paths");
      assert(r.signal === 2, v.id + ": " + r.signal + " gold paths");
      drawn.push(v.id);
      await page.__ctx.close();
    }
    const ids = LIBRARY.variations.map((v) => v.id);
    assertEqual(ids.length, new Set(ids).size, "duplicate ids in the library");
    // And the pool the renderer would draw from is the WHOLE library — nothing shipped is
    // silently being skipped by the validator.
    const page = await launch(browser, { hold: true });
    const pool = await page.evaluate(() => window.RichSplash.pool().map((v) => v.id));
    assertEqual(pool, ids, "the drawable pool is not the shipped library");
    await page.__ctx.close();
    return drawn.length + " entries, each drawn in full with a bar the width of its plinth: " + drawn.join(", ");
  });

  // ---- the mechanic ---------------------------------------------------------------------

  await run.check("4  the screen he meets is his TABLE, not a draw — #1, #2, then #1 forever", async () => {
    // CEO, 2026-09-01, verbatim: *"USE THE APPROVED SPLASH SCREEN #1 to always
    // deterministically show as SPLASH SCREEN #1 and splash screen #2 to always show as
    // splash screen for the SECOND APP START in RichOS v1. From the third app start onwards:
    // Only splash screen #1."*
    //
    // THIS REPLACED A CHECK THAT ASSERTED THE OPPOSITE. Until this commit the suite launched
    // twelve times and demanded that no two consecutive launches be the same, because the
    // surface drew uniformly at random with a no-immediate-repeat guard. That is the
    // mechanic his LATER framing asks for and it is not the v1 rule; a green run of it now
    // would mean the rule is not being followed.
    //
    // Driven through the shell the way the shell delivers it: `window.__RICHOS_LAUNCH__`,
    // frozen, injected before any of the page's own scripts — the same seam check 19 uses,
    // and the same one `launch_init_script` writes.
    const seen = [];
    for (let n = 1; n <= 6; n++) {
      const page = await launch(browser, {
        hold: true,
        init: (o) => {
          window.__RICHOS_LAUNCH__ = Object.freeze({ kind: "fresh", ordinal: o });
        },
        initArg: n,
      });
      const r = await page.evaluate(() => ({
        id: window.RichSplash.state.variationId,
        ordinal: window.RichSplash.state.ordinal,
      }));
      assertEqual(r.ordinal, n, "the surface misreports which start it was told this is");
      seen.push(r.id);
      assert(page.__errors.length === 0, "errors: " + page.__errors.join("; "));
      await page.__ctx.close();
    }
    const first = LIBRARY.variations[0].id;
    const second = LIBRARY.variations.length > 1 ? LIBRARY.variations[1].id : first;
    assertEqual(seen, [first, second, first, first, first, first], "the CEO's v1 table");

    // THE RULE ITSELF, driven directly rather than only through six launches. It is a pure
    // function of the pool and the ordinal, which is what makes the later criteria a change
    // to one place; and it is read off the SHIPPED renderer, so the table cannot drift from
    // the code that implements it.
    const bare = await launch(browser, { hold: true });
    const table = await bare.evaluate(() => {
      const pool = window.RichSplash.pool();
      const out = {};
      for (const n of [1, 2, 3, 4, 17, 100]) out[n] = window.RichSplash.choose(pool, n).id;
      // Nobody said which start this is: the honest answer is the first screen, never none.
      out.absent = window.RichSplash.choose(pool, null).id;
      // A library of one cannot obey "the second start shows the second screen", and
      // refusing to draw would be a worse answer than drawing the one there is.
      out.lonely = window.RichSplash.choose([pool[0]], 2).id;
      return out;
    });
    // AND THE UNINJECTED LAUNCH ABOVE IS ITSELF THE ABSENT CASE: no shell, no ordinal, #1.
    assertEqual(await bare.evaluate(() => window.RichSplash.state.variationId), first, "an uninjected launch");
    assertEqual(await bare.evaluate(() => window.RichSplash.state.ordinal), null, "an uninjected ordinal");
    await bare.__ctx.close();
    for (const n of [1, 3, 4, 17, 100]) assertEqual(table[n], first, "start " + n);
    assertEqual(table[2], second, "start 2");
    assertEqual(table.absent, first, "an unknown start");
    assertEqual(table.lonely, first, "a library of one");
    return (
      "six real launches: " + seen.map((id, i) => (i + 1) + "→" + id.replace("round-11/", "")).join(", ") +
      " · the rule direct: " + [1, 2, 3, 4, 17, 100].map((n) => n + "→" + table[n].replace("round-11/", "")).join(" ") +
      " · absent→" + table.absent.replace("round-11/", "") + " · a pool of one→" + table.lonely.replace("round-11/", "")
    );
  });

  await run.check("5  two launches, two compositions, photographed", async () => {
    // The completion criterion's first clause, as evidence. Held open with `holdOpen()`
    // because the real surface is gone in a quarter of a second and a photograph of it has
    // to be taken while it is up; the compositions themselves are the shipped ones.
    const [a, b] = [LIBRARY.variations[0], LIBRARY.variations[LIBRARY.variations.length - 1]];
    const names = [];
    for (const v of [a, b]) {
      const page = await launch(browser, { hold: true, force: v.id });
      // The photograph is only evidence if what it shows is this entry's own values. The
      // mat's colour is the cheapest one to join back to the library, and it is the one
      // that would go wrong first if the renderer ever stopped reading the data.
      const mat = await page.evaluate(() => getComputedStyle(document.querySelector("#splash .splash-plinth")).backgroundColor);
      assertEqual(mat, rgbOf(v.tokens.surface), v.id + ": the mat is not the entry's own surface colour");
      const slug = "splash-" + (names.length + 1).toString().padStart(2, "0") + "-" + v.id.replace(/[^a-z0-9]+/gi, "-");
      names.push(await settledShot(page, slug) + " — mat " + mat);
      shotNames.push(slug + ".png");
      assert(page.__errors.length === 0, "errors: " + page.__errors.join("; "));
      await page.__ctx.close();
    }
    assert(a.tokens.surface !== b.tokens.surface, "the two photographed compositions are the same");
    return names.join(" · ");
  });

  // ---- what was left behind in the study ------------------------------------------------

  await run.check("6  the palette study is left behind — no chips, no hexes, no labels", async () => {
    // The mockups are palette STUDIES: a rail of five colour chips with role names and hex
    // values, three corner labels, a hint line, and click-to-try-it-on interactions. What
    // was extracted is the composition. Checked as an inventory rather than by eye: every
    // element on this surface has to be one of the eleven kinds the composition is made of,
    // and the only text on it is the line the approved compositions carry.
    const ALLOWED = new Set([
      "splash", "splash-lamp", "splash-vignette", "splash-grain", "splash-stage",
      "splash-rise", "splash-rise--1", "splash-rise--2", "splash-rise--3", "splash-rise--4",
      "splash-plinth", "splash-sheen", "splash-material", "splash-logo", "splash-wordmark",
      "splash-ink", "splash-signal", "splash-foot", "splash-rule", "splash-line",
      "splash--strike-fill", "splash--strike-bloom", "splash--settled", "splash--yielding",
      // The loading bar, added in round 11. Three names for the whole mechanism: the track,
      // a layer on it, and the wrapper a leading-edge layer rides in. Everything else about
      // a bar — which layer progresses, which one flares — is a `data-role`, not a class,
      // precisely so this list does not have to grow with the vocabulary.
      "splash-bar", "splash-bar-layer", "splash-bar-lead",
    ]);
    // EVERY entry, not one. This check used to inspect v6 alone, which was enough when the
    // library was seven colour variations of one composition and is not enough now: v7-v17
    // each carry a material stack lifted from a study that also carries a rail of chips, a
    // hint line and three corner labels, and the entry that let one of those across would
    // be exactly the entry nobody looked at.
    const swept = [];
    let r = null;
    for (const v of LIBRARY.variations) {
    const page = await launch(browser, { hold: true, force: v.id });
    r = await page.evaluate(() => {
      const n = document.getElementById("splash");
      const classes = [];
      const tags = [];
      const walk = (el) => {
        tags.push(el.tagName.toLowerCase());
        (el.getAttribute("class") || "").split(/\s+/).filter(Boolean).forEach((c) => classes.push(c));
        for (const c of el.children) walk(c);
      };
      walk(n);
      return {
        classes: Array.from(new Set(classes)),
        tags: Array.from(new Set(tags)),
        text: (n.innerText || "").replace(/\s+/g, " ").trim(),
        buttons: n.querySelectorAll("button, a, input, [role=button]").length,
        // §15's type floor, on the only text this surface has. The CEO set the size himself:
        // 18px. It was 12px, which is below the 16px minimum for text meant to be read.
        lineSize: getComputedStyle(n.querySelector(".splash-line")).fontSize,
        canvases: n.querySelectorAll("canvas").length,
      };
    });
    const stray = r.classes.filter((c) => !ALLOWED.has(c));
    assertEqual(stray, [], v.id + ": elements the composition is not made of");
    assertEqual(r.buttons, 0, v.id + ": the study's five clickable chips came across");
    assertEqual(r.text, "The Operating System for the AI-Enabled CEO", v.id + ": the only text on the surface");
    assertEqual(r.lineSize, "18px", v.id + ": the CEO set the tagline at 18px");
    // NO CANVAS ANYWHERE ON THIS SURFACE, and this is not tidiness. `tests/contrast.js`
    // check 14 asserts zero canvas elements on every walked surface so that a green contrast
    // run cannot be read as covering pixels no DOM checker can see. The round-11/v2 mockup
    // draws its strap on a canvas; the shipped entry draws the same stitching as an SVG tile
    // for exactly this reason, and this is the assertion that keeps it that way.
    assertEqual(r.canvases, 0, v.id + ": a <canvas> reached the opening screen");
    // Which also settles it: nothing here reads as a hex value, a role name or a round
    // number, because nothing here reads as anything but that one line.
    assert(!/[0-9]/.test(r.text), v.id + ": a digit reached the surface: " + r.text);
    swept.push(v.id);
    await page.__ctx.close();
    }
    return `${swept.length} entries swept, ${r.classes.length} class names on the last, all from the composition · tags: ${r.tags.join(", ")} · 0 canvas · text: "${r.text}" at ${r.lineSize}`;
  });

  await run.check("7  nothing here can catch his hand", async () => {
    // §5.5 refuses anything clickable, dismissible or delaying on this surface. The way
    // that is kept true is not "we did not add a button" — it is that the whole curtain is
    // click-through, so the live app underneath is reachable from the first frame even
    // while the composition is still on screen.
    const page = await launch(browser, { hold: true });
    const r = await page.evaluate(() => {
      const n = document.getElementById("splash");
      const pe = [];
      const walk = (el) => {
        pe.push(getComputedStyle(el).pointerEvents);
        for (const c of el.children) walk(c);
      };
      walk(n);
      const cx = Math.round(innerWidth / 2);
      const cy = Math.round(innerHeight / 2);
      const hit = document.elementFromPoint(cx, cy);
      return {
        distinct: Array.from(new Set(pe)),
        nodes: pe.length,
        hitInsideSplash: !!(hit && n.contains(hit)),
        hitTag: hit ? hit.tagName.toLowerCase() + (hit.id ? "#" + hit.id : "") : "nothing",
      };
    });
    assertEqual(r.distinct, ["none"], "some part of the curtain is not click-through");
    assert(!r.hitInsideSplash, "a click in the middle of the screen lands on the splash");
    await page.__ctx.close();
    return `${r.nodes} nodes, all pointer-events:none · a click at centre reaches ${r.hitTag}`;
  });

  // ---- the honest states ------------------------------------------------------------------

  await run.check("8  the ceremony is cut, the mark never is — and the bar is pinned FULL", async () => {
    // §2 says the splash yields mid-animation, unfinished, the instant the app is up. Taken
    // literally that leaves a half-drawn mark and a loading bar frozen at some fraction —
    // and the fraction is the worse of the two, because it is the one frame on this surface
    // that would be saying something untrue. The curtain only leaves when the app is up or
    // when he touches something, and in both cases loading is over.
    //
    // So yielding PINS: every stage of the settle to where it was going, and the bar to
    // FULL. The performance is cut; nothing on screen is left unfinished.
    //
    // THIS CHECK USED TO RUN AGAINST A STRIKE ENTRY — an entry whose gold arrives on a
    // timeline — which the library no longer has: the two approved screens carry
    // `strike: "none"`, and keeping an unapproved screen alive to satisfy a test would be
    // the tail wagging the product. It now runs against what they DO have: a four-stage
    // settle and a bar, both unfinished at 300ms by construction.
    const v = LIBRARY.variations[0];
    // 300ms in: the bar has not begun (it starts at 600ms) and the fourth stage of the
    // settle — the rule and the line — is still rising (delay 0.48s over a 0.9s curve).
    // Without this half the check would pass on a surface that had simply never animated.
    //
    // AND THE PAGE TAKES THAT READING, NOT THIS FILE. A 300 ms mark cannot be hit from
    // outside by a harness whose first instruction may arrive at 2,000 ms — on the first
    // public runner this read a bar 331 px along and called it "the bar has not started
    // yet". The instant is inside the page's own timeline, so the sample is scheduled
    // there, off the curtain's own clock, and this file collects it afterwards. Five
    // seconds of hold for the same reason `matShot` takes it: room for what follows.
    const page = await launch(browser, { hold: true, force: v.id, seconds: 5, clock: { midAt: 300 } });
    await page.waitForFunction(() => window.__curtain && window.__curtain.mid !== null, null, { timeout: 20000 });
    const before = await page.evaluate(() => window.__curtain.mid);
    assert(!before.gone, "the curtain was gone before its own 300ms sample — nothing was measured");
    const read = () => {
      const n = document.getElementById("splash");
      const fill = n.querySelector('.splash-bar [data-role="progress"]');
      // The run, not the track — see check 22. #1 has no rhythm, so for it the two are the
      // same element; reading it this way keeps the check true if a later screen has one.
      const track = n.querySelector('.splash-bar [data-role="rhythm"]') || n.querySelector(".splash-bar");
      const foot = n.querySelector(".splash-rise--4");
      return {
        fill: Math.round(fill.getBoundingClientRect().width),
        track: Math.round(track.getBoundingClientRect().width),
        foot: Number(getComputedStyle(foot).opacity),
        settled: n.classList.contains("splash--settled"),
        reason: window.RichSplash.state.reason,
      };
    };
    assertEqual(before.fill, 0, "mid-ceremony the bar has not started yet (sampled " + before.at + "ms in)");
    assert(before.foot < 1, "mid-ceremony the last stage of the settle has not landed yet (" + before.foot + ")");
    // His first keystroke is one of the three things that make the surface yield.
    await stillUp(page, "the keystroke half of check 8");
    await page.keyboard.press("a");
    const after = await page.evaluate(read);
    assert(after.settled, "the surface did not pin itself on the way out");
    assertEqual(after.foot, 1, "pinning left a stage of the settle half-risen");
    assertEqual(after.fill, after.track, "the bar was left standing at a fraction on the way out");
    assertEqual(after.reason, "first-input", "what made it yield");
    await page.__ctx.close();
    return `${v.id}: at ${before.at}ms a 0px bar and a stage at opacity ${before.foot.toFixed(2)}; on his first keystroke the bar is ${after.fill}px of ${after.track}px and the settle is landed, then gone`;
  });

  await run.check("9  an unusable library is a normal launch, never a half-drawn frame", async () => {
    // Three ways the library can fail to give the renderer anything, and one answer to all
    // three: no splash, no partial DOM, and an app that boots exactly as it would have.
    const cases = [
      ["no library at all", () => { Object.defineProperty(window, "RichSplashLibrary", { configurable: true, get: () => undefined, set: () => {} }); }],
      ["an empty library", () => { let l; Object.defineProperty(window, "RichSplashLibrary", { configurable: true, get: () => l, set: (x) => { l = { schemaVersion: x.schemaVersion, variations: [] }; } }); }],
      ["every entry malformed", () => { let l; Object.defineProperty(window, "RichSplashLibrary", { configurable: true, get: () => l, set: (x) => { l = { schemaVersion: x.schemaVersion, variations: x.variations.map((v) => { const c = JSON.parse(JSON.stringify(v)); delete c.tokens.surface; return c; }) }; } }); }],
    ];
    const told = [];
    for (const [label, init] of cases) {
      const page = await launch(browser, { init });
      await page.waitForSelector(".nav-thread", { state: "attached" });
      const r = await page.evaluate(() => ({
        splashNodes: document.querySelectorAll("#splash, .splash, .splash-plinth").length,
        declined: window.RichSplash.state.declined,
        shown: window.RichSplash.state.shown,
        composerFocused: document.activeElement === document.getElementById("composer-input"),
        rows: document.querySelectorAll(".nav-thread").length,
      }));
      assertEqual(r.splashNodes, 0, label + ": something was left on screen");
      assertEqual(r.shown, false, label + ": it thinks it drew");
      assert(r.declined, label + ": it declined without saying why");
      assert(r.rows > 0, label + ": the app did not boot");
      assert(page.__errors.length === 0, label + " errors: " + page.__errors.join("; "));
      told.push(`${label} → "${r.declined}"`);
      await page.__ctx.close();
    }
    return told.join(" · ");
  });

  await run.check("10  a launch that never reports ready still clears", async () => {
    // A doorway that can become a wall is worse than no doorway. `holdOpen()` mutes the
    // app-ready path — the same patch every photograph above uses — and the surface has to
    // leave anyway, on its own ceiling, with no help from `main.js` and no input from him.
    const page = await launch(browser, { hold: true });
    const up = await splashState(page);
    assert(up.present, "nothing was drawn to observe the ceiling against");
    await page.waitForTimeout(4400);
    const r = await page.evaluate(() => ({
      present: !!document.getElementById("splash"),
      reason: window.RichSplash.state.reason,
    }));
    assertEqual(r.present, false, "the curtain was still up 4.4s after a launch that never reported ready");
    assertEqual(r.reason, "ceiling", "what cleared it");
    await page.__ctx.close();
    return `app-ready muted; gone by 4.4s on its own ceiling (reason "${r.reason}")`;
  });

  // ---- the off switch ---------------------------------------------------------------------

  await run.check("11  the switch is where he would look, and off stays off", async () => {
    // The second constraint on this work, and the reason it shipped in the same commit as
    // the surface: the failure mode is silent. He switches it off behind the same gear as
    // the only other preference this product has, and the next launch is plain.
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await newPage(ctx);
    await page.goto(APP);
    await page.waitForSelector(".nav-thread", { state: "attached" });
    // The gear this check reaches for is in the RAIL, behind both the curtain and the home
    // screen. The curtain has always been click-through; the home screen is not, and is not
    // meant to be. Everything above and below still tests the curtain itself.
    await leaveHome(page);
    await page.click("#rail-settings");
    await page.waitForSelector("#assertiveness-popover:not([hidden])");
    const before = await page.isChecked("#splash-enabled");
    assertEqual(before, true, "the opening screen is on by default");
    await page.uncheck("#splash-enabled");
    await page.waitForTimeout(200);
    fs.mkdirSync(SHOTS, { recursive: true });
    const sw = await shot(page, "splash-03-the-off-switch", { fullPage: false });
    fs.copyFileSync(sw.file, path.join(SHOTS, "splash-03-the-off-switch.png"));
    shotNames.push("splash-03-the-off-switch.png");

    // Relaunch in the same webview, exactly as reopening the app does.
    await page.goto(APP);
    await page.waitForSelector(".nav-thread", { state: "attached" });
    await leaveHome(page);
    const after = await page.evaluate(() => ({
      splashNodes: document.querySelectorAll("#splash, .splash").length,
      shown: window.RichSplash.state.shown,
      declined: window.RichSplash.state.declined,
      checked: document.getElementById("splash-enabled").checked,
    }));
    assertEqual(after.splashNodes, 0, "it came back after being switched off");
    assertEqual(after.shown, false, "it thinks it drew");
    assertEqual(after.declined, "switched off", "why it declined");
    assertEqual(after.checked, false, "the control does not remember his answer");
    const off = await shot(page, "splash-04-a-launch-with-it-off", { fullPage: false });
    fs.copyFileSync(off.file, path.join(SHOTS, "splash-04-a-launch-with-it-off.png"));
    shotNames.push("splash-04-a-launch-with-it-off.png");
    assert(page.__errors.length === 0, "errors: " + page.__errors.join("; "));
    await ctx.close();
    return `on by default → unchecked behind the gear → relaunched plain ("${after.declined}"), control still unchecked`;
  });

  await run.check("12  the switch is durable in Rust, and both sides agree absent means ON", async () => {
    // The webview's `localStorage` is an instant cache so the surface can decide before it
    // can await anything — the pattern `main.js` already uses for the assertiveness dial.
    // The CEO's actual preference lives in `config.rs` beside it. The two have to agree on
    // what NO stored value means, or a first launch disagrees with itself; and the Rust
    // default has to be a named function, because `#[serde(default)]` on a bool is `false`
    // and would have silently switched the surface off for everyone who already had a
    // config file.
    const cfg = fs.readFileSync(CONFIG_RS, "utf8");
    const rs = fs.readFileSync(MAIN_RS, "utf8");
    const js = fs.readFileSync(MAIN_JS, "utf8");
    assert(/fn splash_default\(\) -> bool \{\s*true\s*\}/.test(cfg), "config.rs's splash default is not `true`");
    assert(/#\[serde\(default = "splash_default"\)\]\s*\n\s*splash_enabled: bool/.test(cfg), "splash_enabled does not use the named default");
    assert(/read\(KEY_ENABLED\) !== "false"/.test(fs.readFileSync(RENDERER_FILE, "utf8")), "splash.js does not treat an absent value as ON");
    for (const cmd of ["splash_enabled", "set_splash_enabled", "splash_note_shown"]) {
      assert(new RegExp("#\\[tauri::command\\]\\s*\\nfn " + cmd + "\\b").test(rs), cmd + " is not a command");
      assert(new RegExp("^\\s*" + cmd + "[,\\s]*$", "m").test(rs), cmd + " is not registered in generate_handler!");
      assert(js.includes('"' + cmd + '"'), cmd + " is never invoked by main.js");
    }
    // And the three timestamps §7 needs are stored, not displayed: nothing reads them back.
    assert(/splash_first_shown_at/.test(cfg) && /splash_disabled_at/.test(cfg), "the two measurement timestamps");
    assert(!/splash_first_shown_at|splash_disabled_at/.test(js), "a measurement timestamp reached the UI");
    return "config.rs default true via a named fn · 3 commands declared, registered and invoked · 2 timestamps stored, 0 displayed";
  });

  // ---- the number the whole thing turns on -------------------------------------------------

  await run.check("12b  THREE SECONDS, named once, measured — and five when a screen asks for it", async () => {
    // CEO, 2026-09-01, verbatim: *"And I said '3 seconds default'. How many times do I have
    // to repeat that? 3 SECONDS. Unless I say otherwise."* With, from the same brief:
    // *"Maximum 5 seconds for some."*
    //
    // BEFORE ANY OF THIS, THE ANSWER TO "HOW LONG?" WAS "HOWEVER LONG THE BOOT TOOK".
    // `main.js` calls `yieldNow("app-ready")` the moment the shell is usable, which on this
    // machine is about a tenth of a second — so no line anywhere expressed a duration. Half
    // the value of this check is that the number is FINDABLE: it asserts the constant exists,
    // is named `SPLASH_SECONDS`, and is 3.
    const source = fs.readFileSync(RENDERER_FILE, "utf8");
    const m = source.match(/var SPLASH_SECONDS = (\d+);/);
    assert(m, "no named SPLASH_SECONDS in splash.js — the duration is a literal again, or gone");
    assertEqual(Number(m[1]), 3, "the CEO's default");
    const cap = source.match(/var MAX_SPLASH_SECONDS = (\d+);/);
    assert(cap, "no named MAX_SPLASH_SECONDS — nothing bounds a per-screen override");
    assertEqual(Number(cap[1]), 5, "the ceiling on a per-screen override");
    // And there is no SECOND number: the constant is the only literal duration on the path.
    assert(!/var HOLD_MS = \d+/.test(source), "HOLD_MS is a literal again beside SPLASH_SECONDS");

    /// One real launch, timed ON THE PAGE from the curtain going up to the curtain coming
    /// down.
    ///
    /// IT USED TO START ITS STOPWATCH WHEN `page.goto()` RETURNED, which is when the LOAD
    /// event fired and not when the curtain went up. The gap is ~55 ms here and was ~2,000 ms
    /// on the first public runner, where this reported a 3,000 ms hold as 1,024 ms and went
    /// red over the product obeying the CEO exactly. A hold is an interval between two things
    /// the PAGE does, so both ends are read off the page's clock.
    const timeIt = async (opts) => {
      const page = await launch(browser, opts);
      await page.waitForFunction(() => window.__curtain && window.__curtain.goneAt !== null, null, { timeout: 20000 });
      const r = await page.evaluate(() => ({
        gone: Math.round(window.__curtain.goneAt - window.__curtain.shownAt),
        reason: window.RichSplash.state.reason,
        seconds: window.RichSplash.state.seconds,
      }));
      await page.__ctx.close();
      return r;
    };

    // THE DEFAULT, OBEYED — which the constant alone does not prove.
    const three = await timeIt({});
    assertEqual(three.reason, "held", "it left for some reason other than the hold being served");
    assertEqual(three.seconds, 3, "the screen reports a duration other than the default");
    // The floor is the hold itself; the ceiling allows the fade and the removal timer on
    // top of it. Anything under 3000 means the app-ready path cut the ceremony short again.
    assert(
      three.gone >= 3000 && three.gone < 3000 + 900,
      "the curtain cleared at " + three.gone + "ms; expected the 3000ms hold plus its fade"
    );

    // FIVE, WHEN A SCREEN ASKS FOR IT. The `seconds` token is the seam the CEO's "up to 5
    // for some" needs and it is exercised here rather than described: the shipped entries
    // are handed a `seconds` of "5" on their way into the page, nothing else is touched, and
    // the curtain has to stay up two seconds longer. This also proves the CEILING moved with
    // it — it used to be a flat 4000ms and would have cut this launch off at four seconds.
    const five = await timeIt({ seconds: 5 });
    assertEqual(five.reason, "held", "the five-second screen left on something other than its hold");
    assertEqual(five.seconds, 5, "the screen did not take the duration it asked for");
    assert(
      five.gone >= 5000 && five.gone < 5000 + 900,
      "a screen that asked for 5s cleared at " + five.gone + "ms"
    );

    // AND THE CEILING IS A CEILING. A screen asking for more than the maximum is clamped to
    // it, not granted it — "up to 5" is a limit, and an entry is data, not an authority.
    const greedy = await timeIt({ seconds: 12 });
    assertEqual(greedy.seconds, 5, "a screen asking for 12 seconds was not clamped to the ceiling");
    assert(greedy.gone < 5900, "a screen asking for 12 seconds was on screen for " + greedy.gone + "ms");

    return (
      "SPLASH_SECONDS = 3 and MAX_SPLASH_SECONDS = 5, both named in splash.js · " +
      "default cleared at " + three.gone + "ms (reason \"held\") · " +
      "a screen asking 5 cleared at " + five.gone + "ms · " +
      "a screen asking 12 was clamped to 5 and cleared at " + greedy.gone + "ms"
    );
  });

  await run.check("12c  the hold never catches his hand, and never defers the failsafe", async () => {
    // THE TWO THINGS A DURATION COULD BREAK, and they are the two this surface must not
    // break. §5.5 forbids anything on it that is delaying, so his first keystroke has to win
    // against the hold; and a ceiling that could itself be deferred is not a failsafe.
    // THE KEYSTROKE HAS TO LAND INSIDE THE HOLD, and it used to be assumed rather than
    // established. This waited for the rail and typed; on the first public runner that took
    // longer than the whole 3,000 ms hold, so the curtain had already left on "held" and the
    // check demanded "first-input" of a surface that was no longer there. It went red over
    // the harness being slow.
    //
    // Two changes, and neither loosens anything. The wait is now on the EVENT that makes the
    // hold real — `main.js` calling `yieldNow("app-ready")`, which is when a hold gets
    // scheduled at all, and pressing before it would prove nothing about the hold. And the
    // screen is asked for five seconds, through the token the product already honours, so a
    // slow machine still has room to get a hand in. The landing is then PROVED rather than
    // hoped for: if the key arrived after the hold was served, this fails and says so, which
    // is what stops the fix from becoming a check that cannot fail.
    const typed = await launch(browser, { seconds: 5, init: MARK_READY });
    await typed.waitForFunction(() => window.__readyAt != null, null, { timeout: 20000 });
    await typed.keyboard.press("a");
    await typed.waitForFunction(() => window.__curtain.goneAt !== null, null, { timeout: 20000 });
    const hand = await typed.evaluate(() => ({
      reason: window.RichSplash.state.reason,
      hold: window.RichSplash.state.seconds * 1000,
      keyInto: Math.round(window.__curtain.firstKeyAt - window.__curtain.shownAt),
      byHand: Math.round(window.__curtain.goneAt - window.__curtain.firstKeyAt),
    }));
    assert(
      hand.keyInto < hand.hold,
      "the keystroke landed " + hand.keyInto + "ms in, past the " + hand.hold + "ms hold — this machine was too slow to " +
        "put a hand inside the ceremony, so nothing about the hold was tested"
    );
    assertEqual(hand.reason, "first-input", "his keystroke was swallowed by the hold and reported as something else");
    // The fade is 180ms and the node leaves 40ms after it, so anything near half a second is
    // the hold having caught his hand rather than the curtain simply leaving.
    assert(hand.byHand < 500, "his hand waited " + hand.byHand + "ms on a " + hand.hold + "ms hold — the hold caught it");
    await typed.__ctx.close();

    // And with app-ready muted entirely, the ceiling still clears it — check 10 proves the
    // timing; this proves the HOLD did not quietly become the thing that clears it, which
    // would leave a hung boot showing the curtain forever.
    const hung = await launch(browser, { hold: true });
    await hung.waitForFunction(() => window.__curtain.goneAt !== null, null, { timeout: 20000 });
    assertEqual(
      await hung.evaluate(() => window.RichSplash.state.reason),
      "ceiling",
      "with app-ready muted the curtain must still leave on its own ceiling"
    );
    await hung.__ctx.close();
    return "his key landed " + hand.keyInto + "ms into a " + hand.hold + "ms hold and cleared the curtain in " +
      hand.byHand + "ms; the ceiling still fires with app-ready muted";
  });

  await run.check("13  the splash costs the launch less than one frame — cold and warm", async () => {
    // THE CEO'S CONSTRAINT, MEASURED RATHER THAN ASSERTED: the splash must never delay
    // launch by a frame. A frame is 16.7ms at 60Hz, and that is the bar this check holds it
    // to — not "roughly the same", not "no noticeable difference".
    //
    // WHAT IS TIMED: navigation start to the instant `main.js` reports the app usable — the
    // line where the rail is drawn, the thread is open and the composer is focused, which
    // is where `main.js` calls `yieldNow("app-ready")`. `MARK_READY` wraps that call and
    // records `performance.now()`; it wraps and calls through, so it changes nothing. The
    // call happens on BOTH arms, because it happens whether or not anything was drawn.
    //
    // COLD is a brand-new browser context every run: empty cache, empty storage, the shape
    // of a first-ever launch. WARM is the same context reloaded, everything cached.
    //
    // WHAT IS NOT MEASURED HERE, said plainly: the Rust half of a real launch — process
    // start, `setup()`, the window. This slice does not touch it. `setup()` is unchanged,
    // and the three commands it adds are called after the app is up, so there is nothing on
    // that side for the splash to have slowed. What the splash CAN slow is the webview
    // boot, and that is exactly what is timed, under the engine Tauri renders through.
    const RUNS = 12;
    const FRAME_MS = 1000 / 60;

    async function timeOne(page) {
      await page.goto(APP);
      await page.waitForFunction(() => window.__readyAt != null, { timeout: 20000 });
      return page.evaluate(() => {
        const t = window.__readyAt;
        window.__readyAt = null;
        return t;
      });
    }

    async function cold(off) {
      const out = [];
      for (let i = 0; i < RUNS; i++) {
        const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
        const page = await newPage(ctx);
        if (off) await page.addInitScript(() => window.localStorage.setItem("richos.splash.enabled", "false"));
        await page.addInitScript(MARK_READY);
        out.push(await timeOne(page));
        await ctx.close();
      }
      return out;
    }

    async function warm(off) {
      const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
      const page = await newPage(ctx);
      if (off) await page.addInitScript(() => window.localStorage.setItem("richos.splash.enabled", "false"));
      await page.addInitScript(MARK_READY);
      await timeOne(page); // prime: the first load of a fresh context is a cold one
      const out = [];
      for (let i = 0; i < RUNS; i++) out.push(await timeOne(page));
      await ctx.close();
      return out;
    }

    const coldOn = await cold(false);
    const coldOff = await cold(true);
    const warmOn = await warm(false);
    const warmOff = await warm(true);

    const cOn = median(coldOn), cOff = median(coldOff);
    const wOn = median(warmOn), wOff = median(warmOff);
    const dCold = cOn - cOff;
    const dWarm = wOn - wOff;

    const fmt = (n) => n.toFixed(1);
    const detail =
      `cold: ${fmt(cOn)}ms with, ${fmt(cOff)}ms without → ${dCold >= 0 ? "+" : ""}${fmt(dCold)}ms · ` +
      `warm: ${fmt(wOn)}ms with, ${fmt(wOff)}ms without → ${dWarm >= 0 ? "+" : ""}${fmt(dWarm)}ms · ` +
      `${RUNS} runs each, medians, one frame = ${fmt(FRAME_MS)}ms`;

    assert(dCold < FRAME_MS, "cold launch is slower by " + fmt(dCold) + "ms, which is a frame or more — " + detail);
    assert(dWarm < FRAME_MS, "warm launch is slower by " + fmt(dWarm) + "ms, which is a frame or more — " + detail);
    return detail;
  });

  // ---- the material, which is the whole of v7 onwards --------------------------------------

  await run.check("14  a material layer may use only the vocabulary the renderer knows", async () => {
    // The widening's own guard rail. `materials` is the one token that is a structure rather
    // than a string, so it is the one place a library could quietly grow an expectation the
    // renderer has never heard of — a `shine` key that nobody implements, sitting in the
    // entry that was supposed to be suede. The vocabulary is read OFF THE RENDERER, not
    // typed here, so the two cannot drift; and an entry using a key outside it is DROPPED,
    // which is the only behaviour that makes the mistake visible.
    const src = fs.readFileSync(RENDERER_FILE, "utf8");
    const props = src.slice(src.indexOf("var LAYER_PROPS = {"), src.indexOf("var LAYER_KEYS"));
    const known = new Set((props.match(/^\s{4}(\w+):/gm) || []).map((m) => m.trim().replace(":", "")));
    for (const k of (src.match(/var LAYER_KEYS = \[([^\]]*)\]/) || ["", ""])[1].match(/"(\w+)"/g) || []) {
      known.add(k.replace(/"/g, ""));
    }
    assert(known.size >= 10, "the renderer's layer vocabulary did not parse: " + known.size + " keys");

    let layers = 0;
    const used = new Set();
    for (const v of LIBRARY.variations) {
      for (const l of v.tokens.materials) {
        layers++;
        for (const k of Object.keys(l)) {
          assert(known.has(k), v.id + ': a material layer uses "' + k + '", which the renderer does not know');
          used.add(k);
        }
      }
    }
    // And the refusal itself, driven rather than described: one shipped layer grows one key
    // outside the vocabulary and the whole entry has to leave the pool.
    const victim = LIBRARY.variations.find((v) => v.tokens.materials.length);
    assert(victim, "no entry carries a material stack to test the refusal against");
    const page = await launch(browser, {
      hold: true,
      initArg: victim.id,
      init: (wanted) => {
        let l;
        Object.defineProperty(window, "RichSplashLibrary", { configurable: true, get: () => l, set: (x) => {
          l = { schemaVersion: x.schemaVersion, round: x.round, variations: x.variations.map((v) => {
            const c = JSON.parse(JSON.stringify(v));
            if (c.id === wanted) c.tokens.materials[0].shine = "1";
            return c;
          }) };
        } });
      },
    });
    const pool = await page.evaluate(() => window.RichSplash.pool().map((v) => v.id));
    assert(pool.indexOf(victim.id) < 0, victim.id + " was still drawable with a key the renderer ignores");
    assertEqual(pool.length, LIBRARY.variations.length - 1, "exactly one entry should have been refused");
    await page.__ctx.close();
    return `${layers} layers across ${LIBRARY.variations.length} entries, every key in the renderer's own vocabulary (${Array.from(used).sort().join(", ")}) · one added key drops its entry from the pool`;
  });

  await run.check("15  the material REACHES the mat — no version is v0 under a different name", async () => {
    // THE CONSTRAINT THIS WHOLE ROUND TURNS ON, measured rather than eyeballed. v7-v17 vary
    // the MATERIAL, and a suede that renders as a flat navy rectangle is not v7 — it is v0
    // with a different name, and shipping it as v7 would be a lie about what the CEO chose.
    //
    // So each entry is photographed twice at the mat: as it ships, and with its material
    // stack emptied and NOTHING else touched. The second is precisely "this version minus
    // the thing that is the point of it", and the two have to differ over a large part of
    // the mat. The same photograph is then compared against v0's mat, which is the other
    // half of the claim: not merely different from itself, different from the one it would
    // otherwise be a rename of.
    const FLOOR = 25;
    // The floor is ONE and not eleven. It was eleven when the library held eighteen
    // round-8.1 material studies; the approved set is two, of which one — the midnight suede
    // — is a material screen. A floor written for a library that no longer exists is a floor
    // that fails for a reason nobody wants to read.
    const withMaterial = LIBRARY.variations.filter((v) => v.tokens.materials.length);
    assert(withMaterial.length >= 1, "no entry carries a material stack, so this check is inert");
    const v0 = await matShot(browser, LIBRARY.variations[0].id, false);
    const cmp = await browser.newContext({ viewport: { width: 400, height: 300 } });
    const judge = await cmp.newPage();
    await judge.goto("about:blank");
    const told = [];
    for (const v of withMaterial) {
      const on = await matShot(browser, v.id, false);
      const off = await matShot(browser, v.id, true);
      const a = await judge.evaluate(DIFF, [on.png, off.png]);
      const b = await judge.evaluate(DIFF, [on.png, v0.png]);
      assert(a.pct >= FLOOR, v.id + ": emptying its material stack changed only " + a.pct.toFixed(2) + "% of the mat — the material is not reaching the screen");
      assert(b.pct >= FLOOR, v.id + ": its mat is " + b.pct.toFixed(2) + "% different from v0's — that is v0 under a different name");
      // The layers are also there, in the entry's own order, under the composition and
      // click-through — the stack is data the renderer laid out, not a coincidence.
      assertEqual(on.layers, v.tokens.materials.length, v.id + ": the stack in the DOM is not the stack in the entry");
      assertEqual(on.above, 0, v.id + ": a material layer is painting over the mark");
      told.push(v.id.replace("round-8.1/", "") + " " + a.pct.toFixed(0) + "%/" + b.pct.toFixed(0) + "%");
    }
    await cmp.close();
    return `mat pixels changed vs the same entry with its material emptied / vs v0, floor ${FLOOR}%: ` + told.join(" · ");
  });

  await run.check("16  the mark's relief is built from the ENTRY's numbers, in an order that cannot be data", async () => {
    // `relief` is an SVG filter written as values. The renderer fixes its SHAPE — outer
    // bands under the mark, the mark, then the noise field and the inner bands over it —
    // because any other order draws a shadow on top of the thing casting it. Everything
    // else comes off the entry, and this joins each number in the filter WebKit built back
    // to the number it came from.
    //
    // TWO HALVES, and the second is new. First: every SHIPPED screen, which must not have a
    // filter built for it, because neither of the CEO's two asks for one — a renderer that
    // fabricates a relief nobody requested is the failure this half catches. Second: the
    // mechanism itself, driven against `RELIEF_FIXTURES` rather than against an unapproved
    // composition kept alive in the product to be its test subject.
    const told = [];
    for (const v of LIBRARY.variations) {
      const t = v.tokens;
      const page = await launch(browser, { hold: true, force: v.id });
      const f = await page.evaluate(READ_RELIEF);
      assertEqual(f.present, false, v.id + ": a relief filter was built for an entry that asked for none");
      assertEqual(f.inkVar, t.markFilter || "none", v.id + ": the ink's filter is not what the entry asked for");
      assertEqual(f.signalVar, t.signalFilter || "none", v.id + ": the gold's filter is not what the entry asked for");
      if (t.signalFilter) assert(f.signal !== "none", v.id + ": its CSS signal filter did not reach the gold");
      // A composition that is not performing a strike has nothing else that could be
      // putting a filter on its paths, so there had better not be one.
      else if (!t.markFilter && t.strike === "none") assertEqual(f.signal, "none", v.id + ": the gold carries a filter it did not ask for");
      await page.__ctx.close();
    }

    const host = LIBRARY.variations[0].id;
    for (const which of ["mark", "signal"]) {
      const spec = RELIEF_FIXTURES[which];
      const page = await launch(browser, {
        hold: true,
        init: WITH_RELIEF,
        initArg: { id: host, relief: spec },
      });
      const f = await page.evaluate(READ_RELIEF);
      assert(f.present, which + ": it asked for a relief and none was built");
      assertEqual(f.region, spec.region, which + ": the filter region");
      assertEqual(f.floods, spec.bands.map((b) => b.color + "@" + b.opacity), which + ": the bands' floods");
      assertEqual(f.offsets, spec.bands.map((b) => b.dx + "," + b.dy), which + ": the bands' offsets");
      assertEqual(f.blurs, spec.bands.map((b) => b.blur), which + ": the bands' blurs");
      assertEqual(
        f.noise,
        spec.noise ? [spec.noise.type, spec.noise.baseFrequency, spec.noise.octaves, spec.noise.seed].join(" ") : null,
        which + ": the noise field"
      );
      // The order. Outer bands, then the mark, then the noise and the inner bands.
      const outer = spec.bands.map((b, i) => [b, i]).filter(([b]) => b.placement === "outer").map(([, i]) => "band" + i);
      const inner = spec.bands.map((b, i) => [b, i]).filter(([b]) => b.placement === "inner").map(([, i]) => "band" + i);
      const want = outer.concat(["SourceGraphic"], spec.noise ? ["grain"] : [], inner);
      assertEqual(f.merge, want, which + ": the merge order");
      assert(f.signal.indexOf("richos-splash-relief") >= 0, which + ": the relief did not reach the gold");
      if (spec.target === "mark") assert(f.ink.indexOf("richos-splash-relief") >= 0, which + ": a mark relief did not reach the ink");
      else assertEqual(f.ink, "none", which + ": a signal-only relief reached the ink");
      told.push(which + " " + spec.target + "/" + spec.bands.length + "band" + (spec.noise ? "+noise" : ""));
      assert(page.__errors.length === 0, "errors: " + page.__errors.join("; "));
      await page.__ctx.close();
    }
    assertEqual(told.length, 2, "both halves of the relief vocabulary have to be exercised");
    return (
      LIBRARY.variations.length + " shipped screens, 0 of which build a filter they did not ask for · " +
      "the mechanism driven against 2 fixtures: " + told.join(" · ")
    );
  });

  await run.check("17  the ceremony is cut, and the MATERIAL still is not", async () => {
    // Check 8's rule, one layer deeper. Yielding pins the composition where it was going,
    // and it used to do that by setting `filter: none` on the gold — which was right when
    // the only filter there was the bloom strike and wrong the moment an entry can give the
    // mark a relief: pinning would have flattened the metal the version is made of, on
    // exactly the fast launches the CEO sees most.
    //
    // Driven against the mark fixture for the reason check 16 gives: the mechanism is still
    // in the renderer and still has to be proved, and neither approved screen uses it.
    const host = LIBRARY.variations[0].id;
    const page = await launch(browser, {
      hold: true,
      init: WITH_RELIEF,
      initArg: { id: host, relief: RELIEF_FIXTURES.mark },
    });
    // 300ms into the CURTAIN, not 300ms into this file's turn — the same correction check 8
    // carries and for the same reason. The relief does not move with time, so this arrived
    // at an honest answer on the runner by luck; the sentence it returns was still false.
    await atCurtain(page, 300);
    await stillUp(page, "the relief reading");
    const before = await page.evaluate(() => getComputedStyle(document.querySelector("#splash .splash-signal")).filter);
    await page.keyboard.press("a");
    const after = await page.evaluate(() => {
      const n = document.getElementById("splash");
      return {
        settled: n.classList.contains("splash--settled"),
        signal: getComputedStyle(n.querySelector(".splash-signal")).filter,
        ink: getComputedStyle(n.querySelector(".splash-ink")).filter,
      };
    });
    assert(after.settled, "the surface did not pin itself on the way out");
    assert(before.indexOf("richos-splash-relief") >= 0, "the relief was not on the gold to begin with");
    assert(after.signal.indexOf("richos-splash-relief") >= 0, "pinning the composition flattened the gold's relief");
    assert(after.ink.indexOf("richos-splash-relief") >= 0, "pinning the composition flattened the ink's relief");
    await page.__ctx.close();
    return `${host} + the mark fixture: relief on the gold at 300ms and still on it after his first keystroke (${after.signal})`;
  });

  await run.check("18  every version the round added is photographed by the SHIPPING renderer, beside its study", async () => {
    // THE COMPLETION CRITERION FOR THIS ROUND, and it is deliberately not "the entry
    // validates". v7-v17 vary the MATERIAL, and the only honest way to say a material
    // survived the reduction from a 20 KB study to a JSON entry is to put the two mats next
    // to each other and look. So: the mat as the SHIPPED renderer draws it, beside the mat
    // the study draws, in one file per version.
    //
    // The mats only, at native scale — the composition either side of them is identical by
    // construction (same geometry, same ink, same gold, same rule) and a full-window pair
    // would be four times the bytes to show the same thing twice.
    // EVERY SHIPPED SCREEN, not only the ones with a material stack. Two screens is a set
    // small enough that "photograph the ones that vary" and "photograph all of them" are the
    // same list, and the second is the one that stays true as the array grows.
    const added = LIBRARY.variations;
    assert(added.length >= 1, "nothing to photograph");
    const haveStudies = fs.existsSync(HQ);
    fs.mkdirSync(SHOTS, { recursive: true });
    const cmp = await browser.newContext({ viewport: { width: 400, height: 300 } });
    const judge = await cmp.newPage();
    await judge.goto("about:blank");
    const made = [];
    for (const v of added) {
      const slug = v.id.replace(/[^a-z0-9]+/gi, "-");
      const ship = await matShot(browser, v.id, false);
      let study = null;
      if (haveStudies) {
        const file = studyOf(v);
        assert(file, slug + ': its `source` does not name a study in the studies repository — "' + v.source + '"');
        assert(fs.existsSync(file), slug + ": the entry names a study that is not there — " + v.source);
        const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
        const page = await newPage(ctx);
        await page.goto("file://" + file);
        await page.waitForTimeout(2200);
        const clip = await page.evaluate(() => {
          const q = document.querySelector(".plinth").getBoundingClientRect();
          return { x: Math.round(q.x), y: Math.round(q.y), width: Math.round(q.width), height: Math.round(q.height) };
        });
        study = (await page.screenshot({ clip })).toString("base64");
        await ctx.close();
      }
      const png = await judge.evaluate(SIDE_BY_SIDE, { a: ship.png, b: study, left: "SHIPPING RENDERER", right: "THE STUDY" });
      const out = path.join(SHOTS, "material-" + slug + ".png");
      fs.writeFileSync(out, Buffer.from(png, "base64"));
      made.push("material-" + slug + ".png");
      shotNames.push("material-" + slug + ".png");
    }
    await cmp.close();
    return `${made.length} pairs — each the whole mat at half scale over the same corner at native scale` +
      (haveStudies ? " — shipping renderer LEFT, the study each entry NAMES right" : " — SHIPPING SIDE ONLY: no study repository at " + HQ);
  });

  // ---- WHICH LAUNCHES GET A CEREMONY (CEO ruling, 2026-08-31) --------------------------

  await run.check("19  a fresh launch draws; a crash-restart and a second window do not", async () => {
    // THE RULING, DRIVEN. "The splash screen is only for when the user starts the app fresh
    // (after quitting." A crash-restart shows nothing — the app just died in front of him
    // and a ceremony would be the wrong instrument at the worst moment — and a second window
    // begins nothing at all.
    //
    // The verdict is injected the way the SHELL injects it: `window.__RICHOS_LAUNCH__`,
    // frozen, before any of the page's own scripts. `addInitScript` runs at exactly the
    // same point `WebviewWindowBuilder::initialization_script` does, which is the whole
    // reason `tauri.conf.json` carries `"create": false`.
    const seen = [];
    for (const kind of ["fresh", "crash-restart", "second-window"]) {
      const page = await launch(browser, {
        hold: true,
        init: (k) => {
          window.__RICHOS_LAUNCH__ = Object.freeze({ kind: k });
        },
        initArg: kind,
      });
      const r = await splashState(page);
      seen.push({ kind, present: r.present, reported: r.state.kind, declined: r.state.declined });
      if (kind === "fresh") {
        assert(r.present, "a fresh launch drew nothing");
        assert(r.state.shown, "a fresh launch reports shown=false");
        assertEqual(r.state.declined, null, "a fresh launch declined");
      } else {
        assert(!r.present, kind + " drew a splash");
        assert(!r.state.shown, kind + " reports shown=true");
        assert(
          typeof r.state.declined === "string" && r.state.declined.includes(kind),
          kind + " did not say why it declined: " + r.state.declined
        );
      }
      assertEqual(r.state.kind, kind, "the surface misreports the kind it was told");
      await page.__ctx.close();
    }
    return seen
      .map((x) => x.kind + ": " + (x.present ? "SPLASH" : "no splash — " + x.declined))
      .join(" · ");
  });

  await run.check("20  absent means fresh, and the wire strings are one set, not two", async () => {
    // ABSENT MEANS FRESH is the same rule the off switch already follows, and it is what
    // keeps `index.html` opened straight off disk, a webview the shell could not inject
    // into, and this harness working. The opposite default would let a shell bug silently
    // delete the feature and nobody would see a thing.
    const page = await launch(browser, { hold: true });
    const bare = await splashState(page);
    assert(bare.present && bare.state.shown, "an uninjected launch drew nothing");
    assertEqual(bare.state.kind, "fresh", "an uninjected launch is not reported as fresh");
    // A nonsense verdict is NOT fresh: absent is an absent opinion, but a stated one that
    // this build does not recognise is a stated opinion and must not be read as consent.
    const odd = await launch(browser, {
      hold: true,
      init: () => {
        window.__RICHOS_LAUNCH__ = Object.freeze({ kind: "resumed-from-sleep" });
      },
    });
    const oddState = await splashState(odd);
    assert(!oddState.present, "an unrecognised kind drew a splash");
    await odd.__ctx.close();

    // AND THE TWO SIDES SPELL IT THE SAME WAY. `splash.js` compares against its own
    // constant and `launch.rs` writes the string the shell injects; if those drift by one
    // character every launch reads as unrecognised and the splash silently never appears
    // again. Both are read off disk here rather than typed a third time.
    const fresh = await page.evaluate(() => window.RichSplash.KIND_FRESH);
    const rs = fs.readFileSync(LAUNCH_RS, "utf8");
    const wire = (rs.match(/LaunchKind::\w+ => "([a-z-]+)"/g) || []).map((m) => m.match(/"([a-z-]+)"/)[1]);
    assertEqual(wire, ["fresh", "crash-restart", "second-window"], "launch.rs's wire strings");
    assert(wire.includes(fresh), "splash.js's KIND_FRESH (" + fresh + ") is not one of launch.rs's kinds");
    assertEqual(fresh, "fresh", "the kind that draws");
    await page.__ctx.close();
    return "absent → fresh (drew) · unrecognised → no splash · wire set " + wire.join("/") + " shared by both sides";
  });

  await run.check("21  what was ON SCREEN reaches the recency ring, with his LOCAL calendar", async () => {
    // The record's two live wires, driven end to end through the real bridge.
    //
    // THE RING TAKES `state.variationId`, which is set where the node is inserted — so it
    // holds what was drawn, not what was chosen. `splash.js` has three paths that choose an
    // entry and then decline to render it, and all three must leave the ring untouched.
    const page = await launch(browser, { hold: true, force: LIBRARY.variations[0].id });
    await page.waitForFunction("window.__RICHOS_MOCK__ && window.__RICHOS_MOCK__.launchCalls().stateReads.length > 0");
    const drew = await page.evaluate(() => ({
      calls: window.__RICHOS_MOCK__.launchCalls(),
      shownId: window.RichSplash.state.variationId,
      // The offset the browser itself would compute, derived here independently of main.js.
      expectedOffset: -new Date().getTimezoneOffset(),
    }));
    assertEqual(drew.calls.splashShown, [drew.shownId], "the ring was not fed the id that was drawn");
    assertEqual(drew.shownId, LIBRARY.variations[0].id, "the forced entry is the one recorded");
    assertEqual(drew.calls.stateReads.length, 1, "the record was read once at boot");
    // STORE UTC, BUCKET LOCAL. The offset handed to Rust is offset-from-UTC-positive-east,
    // which is the NEGATION of getTimezoneOffset(). A missing minus sign puts every bucket
    // boundary up to fourteen hours out and nothing looks broken.
    assertEqual(
      drew.calls.stateReads[0].utcOffsetMinutes,
      drew.expectedOffset,
      "the offset handed to the record is not this machine's local offset, negated"
    );
    await page.__ctx.close();

    // AND A LAUNCH THAT DREW NOTHING FEEDS THE RING NOTHING — the crash-restart case, which
    // is the whole reason the ring is fed from `shown` rather than from the draw.
    const quiet = await launch(browser, {
      hold: true,
      init: () => {
        window.__RICHOS_LAUNCH__ = Object.freeze({ kind: "crash-restart" });
      },
    });
    await quiet.waitForFunction("window.__RICHOS_MOCK__ && window.__RICHOS_MOCK__.launchCalls().stateReads.length > 0");
    const quietCalls = await quiet.evaluate(() => window.__RICHOS_MOCK__.launchCalls());
    assertEqual(quietCalls.splashShown, [], "a crash-restart pushed something onto the ring");
    await quiet.__ctx.close();
    return (
      "fresh: ring ← " + drew.shownId + ", offset " + drew.calls.stateReads[0].utcOffsetMinutes +
      " min from UTC · crash-restart: ring ← nothing, record still read once"
    );
  });

  // ---- the bar itself: it runs, it lands on time, and it runs ONCE -----------------------

  await run.check("22  the bar runs ONCE — monotonic, landing exactly on the hold, and never restarting", async () => {
    // CEO, 2026-09-01, verbatim: *"The animation is only supposed to happen ONCE. NO LOOPING.
    // And I said '3 seconds default'. How many times do I have to repeat that? 3 SECONDS.
    // Unless I say otherwise."*
    //
    // Three legs, because no one of them is enough on its own.
    //
    // LEG 1 — STRUCTURAL. A loop needs something to restart it. `splash.js` has no
    // `setInterval`, no replay flag, and no `focus` / `visibilitychange` / `pageshow`
    // listener; `requestAnimationFrame` appears in exactly two places, the one that starts
    // the single pass and the one inside the pass that continues it. The approved mockups
    // carry an `AUTO_REPLAY` flag for judging, and nothing of the sort exists here.
    // COMMENTS STRIPPED FIRST, and that is not fussiness — it is the difference between
    // reading the code and reading the prose about the code. The first version of this leg
    // grepped the whole file for "replay" and went red on the sentence explaining that there
    // is no replay path, which is a check that punishes the documentation for existing.
    const source = fs.readFileSync(RENDERER_FILE, "utf8");
    const code = source.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/^[ \t]*\/\/.*$/gm, " ");
    assertEqual((code.match(/setInterval/g) || []).length, 0, "a timer that repeats");
    assertEqual((code.match(/AUTO_REPLAY|replay|restart/gi) || []).length, 0, "a replay path in the code");
    assertEqual(
      (code.match(/addEventListener\(\s*"(focus|visibilitychange|pageshow|blur)"/g) || []).length,
      0,
      "a listener that could wake the animation"
    );
    const rafs = (code.match(/requestAnimationFrame\(/g) || []).length;
    assertEqual(rafs, 2, "requestAnimationFrame call sites — one to start the pass, one to continue it");
    // And the strip has to have left something to read, or all four assertions above are
    // vacuous — the failure mode a negative check dies of.
    assert(code.indexOf("function tick(") > 0, "the comment strip ate the renderer");

    // LEG 2 — OBSERVED, for the whole life of the curtain. `holdOpen()` mutes the app-ready
    // path, so what clears this surface is its own ceiling at 4000ms; the bar lands at 3000.
    // That leaves just under a second of watching after it has landed.
    //
    // AND THAT WINDOW IS NOT ENOUGH ON ITS OWN, which is why leg 3 exists and is stated here
    // rather than left as a gap. This leg was written first and run against a deliberate
    // restart injected at the end of the landing flare — 3950ms, one sample past the last
    // one it takes — and it passed. Watching the width can only ever see a loop whose period
    // is shorter than the second the curtain has left; leg 3 sees any loop at all.
    //
    // THE PAGE KEEPS THE TRACE NOW, AND THAT IS THE FIX FOR THE FIRST PUBLIC RUNNER, where
    // this got EIGHT samples of the forty it needs. Two faults, one cause: the loop started
    // when `page.goto()` returned rather than when the curtain went up, so a two-second
    // harness lag was spent before the first sample; and every sample cost a round trip out
    // of the browser, which on a loaded shared VM is the dominant term. A sampler inside the
    // page starts on the curtain's own first frame, times against the curtain's own clock,
    // and costs one round trip for the whole trace instead of sixty.
    const told = [];
    for (const v of LIBRARY.variations) {
      const page = await launch(browser, { hold: true, force: v.id, clock: { trace: true, every: 40 } });
      await page.waitForFunction(() => window.__curtain.goneAt !== null, null, { timeout: 20000 });
      const trace = await page.evaluate(() => window.__curtain.trace);
      assert(trace.length > 40, v.id + ": only " + trace.length + " samples — the curtain went too early to observe");
      // MONOTONIC. It never stalls and never jumps back, which is what "the empty run to the
      // right IS the distance left" requires to be true.
      for (let i = 1; i < trace.length; i++) {
        assert(
          trace[i].p >= trace[i - 1].p - 0.002,
          v.id + ": the bar went BACKWARDS at " + Math.round(trace[i].t) + "ms (" + trace[i - 1].p.toFixed(3) + " → " + trace[i].p.toFixed(3) + ")"
        );
      }
      // NOTHING BEFORE THE BAR STARTS, and full by the hold.
      const early = trace.filter((s) => s.t < 500);
      assert(early.every((s) => s.p === 0), v.id + ": the bar was already moving before it starts");
      const atHold = trace.filter((s) => s.t >= 3050 && s.t <= 3150);
      assert(atHold.length && atHold.every((s) => s.p > 0.995), v.id + ": the bar had not landed at the 3000ms hold");
      // AND IT STAYS LANDED. Every sample after it lands is still full — a restart would
      // show as a return to zero here, and this is the window one could happen in.
      const after = trace.filter((s) => s.t > 3200);
      assert(after.length > 8, v.id + ": only " + after.length + " samples after the landing to prove it does not loop");
      assert(after.every((s) => s.p > 0.995), v.id + ": the bar restarted after it landed");
      // LEG 3 — THE LOOP IS STOPPED, and the bar says so itself. `state.barStopped` is set
      // by the one function every non-scheduling exit from `tick()` goes through, and
      // `state.barPasses` counts landings. A restart cannot leave the first true or the
      // second at one, whenever it happens — including after this observation ends.
      const own = await page.evaluate(() => ({
        passes: window.RichSplash.state.barPasses,
        stopped: window.RichSplash.state.barStopped,
      })).catch(() => null);
      assert(own, v.id + ": the surface went before its own account could be read");
      assertEqual(own.passes, 1, v.id + ": the bar reached the end " + own.passes + " times");
      assertEqual(own.stopped, true, v.id + ": the frame loop is still running after the bar landed");
      told.push(
        v.id.replace("round-11/", "") + " " + trace.length + " samples over " +
          Math.round(trace[trace.length - 1].t) + "ms, " + after.length + " after the landing · " +
          own.passes + " pass, loop stopped"
      );
      assert(page.__errors.length === 0, "errors: " + page.__errors.join("; "));
      await page.__ctx.close();
    }
    return "no interval, no replay path, no wake listener, 2 rAF call sites · " + told.join(" · ");
  });

  // ---- the floor, measured where the eye is ----------------------------------------------

  await run.check("23  WCAG AA on the COMPOSITED frame — text 4.5:1, the bar 3:1, both themes", async () => {
    // The standing rule (`CLAUDE.md`, "Contrast — WCAG AA, ALWAYS, BOTH THEMES"), measured on
    // this surface the only way it can honestly be measured: from a photograph.
    //
    // WHY NOT `tests/contrast.js`. That suite walks the DOM and reads computed styles, and on
    // this surface those are not what the eye receives — a `soft-light` lamp, a vignette and
    // an `overlay` grain all sit ABOVE the plinth. `contrast-debt.json` already carries the
    // tagline as a named `knownUnresolvable` for exactly that reason. This check answers the
    // question that one cannot.
    //
    // BOTH THEMES, and the honest answer is that they are the same frame. §15 carries one
    // permanent exception — "because of its nature the start screen will always need to be in
    // dark mode" — and `splash.js` clamps it with `RichTheme.forceDark(true)`. So this walks
    // BOTH schemes and asserts the numbers MATCH, which is a stronger claim than measuring
    // one: it proves the clamp holds rather than assuming it.
    const cmp = await browser.newContext({ viewport: { width: 400, height: 300 } });
    const judge = await cmp.newPage();
    await judge.goto("about:blank");
    const rows = [];
    for (const v of LIBRARY.variations) {
      const perTheme = {};
      for (const theme of ["dark", "light"]) {
        const ctx = await browser.newContext({
          viewport: { width: 1440, height: 900 },
          deviceScaleFactor: 2,
          colorScheme: theme,
        });
        const page = await newPage(ctx);
        await page.addInitScript(CURTAIN_CLOCK, {});
        await page.addInitScript(HOLD_OPEN);
        // Five seconds, through the product's own token, for the room a 1440x900 shot at
        // deviceScaleFactor 2 needs before the ceiling. The instant sampled below moves with
        // it, so the frame photographed is the same frame it always was.
        await page.addInitScript(SHAPE, { id: v.id, seconds: 5 });
        await page.goto(APP);
        await lag(page);
        await page.waitForSelector("#splash", { timeout: 20000 });
        // MID-LOAD, so the bar has BOTH a sewn part and an empty one to compare — and
        // mid-load is a fraction of the HOLD, not a number of milliseconds. `1800` was that
        // fraction written out for a 3,000 ms hold (the bar starts at 600 ms and runs the
        // rest, so 600 + half of 2,400 is exactly half a bar); computing it puts the sample
        // at half a bar whatever the screen asked for. On the first public runner the old
        // literal, counted from `page.goto()` returning, landed after the curtain had gone
        // and this check dereferenced a `#splash` that was not there.
        const half = await page.evaluate(() => {
          const start = 600;
          const hold = window.RichSplash.state.seconds * 1000;
          return Math.round(start + (hold - start) / 2);
        });
        await atCurtain(page, half);
        await stillUp(page, "the composited frame for " + v.id + " (" + theme + ")");
        const geo = await page.evaluate(() => {
          const q = (s) => document.querySelector("#splash " + s).getBoundingClientRect();
          const plinth = q(".splash-plinth");
          const line = q(".splash-line");
          const rule = q(".splash-rule");
          const word = q(".splash-wordmark");
          const bar = q(".splash-bar");
          const fill = q('.splash-bar [data-role="progress"]');
          const p = fill.width / bar.width;
          return {
            // the tagline's glyphs, and a bare strip of mat just above them
            line: { x: line.x, y: line.y, w: line.width, h: line.height },
            mat: { x: line.x, y: line.y - 14, w: line.width, h: 8 },
            // the short rule inside the plinth, and the mat beside it
            rule: { x: rule.x, y: rule.y, w: rule.width, h: Math.max(2, rule.height) },
            ruleMat: { x: plinth.x + 16, y: rule.y - 4, w: 40, h: 10 },
            // a band across the wordmark's stems
            word: { x: word.x, y: word.y + word.height * 0.35, w: word.width, h: word.height * 0.3 },
            wordMat: { x: plinth.x + 14, y: word.y, w: 24, h: word.height },
            // the bar: the sewn half, the empty half, and the ground under it
            barFilled: { x: bar.x + bar.width * 0.1, y: bar.y, w: bar.width * (p - 0.18), h: bar.height },
            barEmpty: { x: bar.x + bar.width * (p + 0.12), y: bar.y, w: bar.width * (0.88 - p), h: bar.height },
            barEdgeTop: { x: bar.x + bar.width * 0.3, y: bar.y - 1, w: bar.width * 0.4, h: 2 },
            ground: { x: bar.x, y: bar.y + bar.height + 10, w: bar.width, h: 14 },
            progress: p,
          };
        });
        const png = (await page.screenshot()).toString("base64");
        const shutter = await curtainNow(page);
        assert(
          shutter.up,
          v.id + " (" + theme + "): the curtain left during the exposure — these are the colors of the screen behind it"
        );
        const want = [
          ["taglineGlyph", geo.line, "bright"],
          ["mat", geo.mat, "mode"],
          ["ruleGold", geo.rule, "bright"],
          ["ruleMat", geo.ruleMat, "mode"],
          ["wordInk", geo.word, "bright"],
          ["wordMat", geo.wordMat, "mode"],
          ["barFill", geo.barFilled, "bright"],
          ["barTrack", geo.barEmpty, "mode"],
          ["barEdge", geo.barEdgeTop, "bright"],
          ["ground", geo.ground, "mode"],
        ];
        const got = await judge.evaluate(SAMPLE, {
          png,
          dpr: 2,
          rects: want.map(([, r, mode]) => ({ ...r, mode })),
        });
        const at = {};
        want.forEach(([name], i) => {
          at[name] = { r: got[i].r, g: got[i].g, b: got[i].b, a: 1 };
        });
        perTheme[theme] = at;
        assert(page.__errors.length === 0, "errors: " + page.__errors.join("; "));
        await ctx.close();
      }

      // THE CLAMP, asserted on what holds still. §15's permanent exception says this
      // surface is always dark; if that is true, the two photographs are the same
      // photograph. But the two are two separate launches, and the BAR IS MOVING at the
      // instant they are taken — a few milliseconds of difference moves the fill's leading
      // edge and, with it, the median of the brightest 5% inside the box. Comparing the
      // moving parts pixel-for-pixel measures scheduler jitter and calls it a theme
      // difference; it went red doing exactly that before this was written.
      //
      // So the identity claim is made about the elements that do not move, which is where
      // the theme would show if the clamp ever failed — the mat, the mark, the rule, the
      // tagline, the ground and the track. The moving parts are held to something stronger
      // instead: their AA floors are asserted in BOTH themes below, not in one, so a theme
      // that changed one of them would fail on the ratio rather than on the pixel.
      //
      // `barEdge` JOINED THIS LIST ON 2026-09-04, AND THE PARAGRAPH ABOVE IS WHY. It was
      // classified as a still element and it is not one. `barFilled` and `barEmpty` are
      // deliberately offset away from the fill's leading edge — `p - 0.18` and `p + 0.12`,
      // written that way a few lines up for exactly this reason — while `barEdgeTop` is a
      // fixed band from 30% to 70% of the bar's width, which at mid-load is the band the
      // leading edge is INSIDE. So it was the one sample in the list that the moving fill
      // sweeps through, compared pixel-for-pixel across two separate launches.
      //
      // Measured rather than argued, five runs of this suite on 2026-09-04 with `splash.js`,
      // `splash.css`, `splash-library.js` and this file byte-identical throughout:
      //
      //     PASS  PASS  PASS
      //     FAIL  barEdge #60708e dark vs #657188 light
      //     FAIL  barEdge #60708e dark vs #64708a light
      //
      // The dark reading is the SAME BYTE on both failures and the light reading is not the
      // same as itself — which is the signature of a moving sample and the opposite of a
      // theme leak, where both sides would be stable and different. Two failures in five, on
      // a loaded machine; a CI runner is a shared VM, so `ui-suite-ci` would have been red
      // roughly half the time it ran, over a difference that is scheduler jitter.
      //
      // NOTHING ABOUT THE CONTRAST FLOOR CHANGES. The strap's edge is still asserted at
      // 3:1 against the ground, in BOTH themes, in the `pairs` loop below — which is the
      // substitute this paragraph names for a moving element, and it is the assertion that
      // would actually catch a clamp failure on it. Eight still samples continue to carry
      // the pixel-identity claim.
      //
      // WHAT IT COSTS, stated rather than glossed: `pairs` adds the edge only for a bar that
      // HAS one, so #1 — `outline: none` — now carries no assertion on that sample at all,
      // where before it carried the identity one. That is a real loss and it is taken
      // knowingly, because the geometry above is variant-independent: the band is 30%-70%
      // of the bar either way, so #1's reading is the same moving mixture #2's is, and an
      // assertion that cannot fail for the right reason is not coverage. Neither observed
      // failure was #1.
      const MOVING = ["barFill", "barEdge"];
      const still = Object.keys(perTheme.dark).filter((k) => MOVING.indexOf(k) < 0);
      for (const k of still) {
        const d = perTheme.dark[k];
        const l = perTheme.light[k];
        assert(
          Math.abs(d.r - l.r) <= 3 && Math.abs(d.g - l.g) <= 3 && Math.abs(d.b - l.b) <= 3,
          v.id + ": " + k + " differs between themes (" + hex(d) + " dark vs " + hex(l) + " light) — " +
            "§15 says this surface is always dark and splash.js clamps it, so it must not"
        );
      }

      const at = perTheme.dark;
      const pairs = [
        ["the tagline, 18px", "taglineGlyph", "mat", 4.5],
        ["the rule", "ruleGold", "ruleMat", 3],
        ["the wordmark", "wordInk", "wordMat", 3],
        ["the bar's fill on the ground", "barFill", "ground", 3],
        ["the bar's fill on its own track", "barFill", "barTrack", 3],
      ];
      // A BAR WITH AN EDGE HAS TO SHOW ITS EXTENT. #2's strap is an object: the distance
      // still to sew is the part of it that is not sewn, so the strap's own edge is carrying
      // state and takes the 3:1 non-text floor. #1's bar has no edge (`outline: none`) — its
      // extent is the ghost of the rule, which is declared below rather than asserted.
      if (v.tokens.bar.outline && v.tokens.bar.outline !== "none") {
        pairs.push(["the strap's edge on the ground", "barEdge", "ground", 3]);
      }
      for (const [label, fg, bg, floor] of pairs) {
        // BOTH THEMES, every pair. On a surface that is always dark these are the same
        // number twice — which is the point: it is measured rather than assumed, and it is
        // the assertion that catches a moving element the clamp comparison cannot.
        const each = {};
        for (const theme of ["dark", "light"]) {
          const t = perTheme[theme];
          const ratio = round2(contrastRatio(t[fg], t[bg]));
          each[theme] = ratio;
          assert(
            ratio >= floor,
            v.id + ": " + label + " measures " + ratio.toFixed(2) + ":1 on the composited frame in " +
              theme + " mode, below its " + floor + ":1 floor"
          );
        }
        rows.push(
          v.id.replace("round-11/", "") + " · " + label + ": " + hex(at[fg]) + " on " + hex(at[bg]) +
            " = " + each.dark.toFixed(2) + ":1 dark / " + each.light.toFixed(2) + ":1 light (floor " + floor + ")"
        );
      }
    }
    await cmp.close();
    return (
      rows.join(" · ") +
      " · both color schemes photographed; every ratio met in both, and every element that " +
      "holds still is pixel-identical across them (§15's always-dark start screen) · " +
      "DECLARED, with the arithmetic: neither bar's UNFILLED track is asserted against the ground. " +
      "It is unfilled material, not the state — the boundary that conveys progress is the fill " +
      "against the track and against the ground, and both are asserted above. For #1 the two " +
      "cannot both pass at once within this palette: clearing 3:1 on the ground needs a track " +
      "luminance >= 0.118 and clearing 3:1 against the gold fill needs <= 0.095, and no value is " +
      "both. For #2 the strap's own EDGE marks the bar's extent and is measured instead."
    );
  });

  await browser.close();
  if (shotNames.length) console.log("\n  shots → " + path.relative(process.cwd(), SHOTS) + "/: " + shotNames.join(", "));
  return run.report();
}

// ---------------------------------------------------------------------------------------
// THE MUTATIONS, against their check numbers.
//
// Every check above was run RED once by making exactly one of these edits to the SHIPPED
// source and watching this suite say so. A check that has never failed has proven nothing,
// and this repository has produced both kinds of green in one week.
//
// TWO PASSES, because the round-11 work rewrote six checks and added two, and a mutation
// run against a check that no longer exists proves nothing about the check that replaced it.
//
// THE ORIGINAL THIRTEEN — `docs/verification/opening-screen-2026-08-30/mutation-runs.txt`.
// Eleven still stand as written. Two are struck through by the round-11 pass and are listed
// with what happened to them rather than quietly dropped:
//
//   1   splash-library.js  `"round": "8.1"` → `"round": String("8.1")` — valid JS, not JSON
//   2   splash.js          a hex literal added beside GILD_ID
//   3   splash-library.js  a `"surface"` token renamed, i.e. removed
//   4   RETIRED            it broke `pick()`, the uniform random draw. There is no draw:
//                          the CEO's v1 rule is a table, and check 4's replacement mutation
//                          breaks `choose()` instead.
//   5   splash.js          the `--splash-surface` assignment deleted
//   6   splash.js          a `.splash-corner` element appended, as the studies carry
//   7   splash.css         `pointer-events: none` → `auto` on the curtain
//   8   STILL VALID        the `splash--settled` class no longer added on the way out —
//                          and check 8 now also has the bar mutation below
//   9   splash.js          pool() returns the library unvalidated
//  10   splash.js          the ceiling timer deleted
//  11   main.js            the switch stops writing the local mirror
//  12   config.rs          `splash_default()` returns false
//  13   splash.js          a 40ms busy-wait, BELOW the switch check so only a drawn splash
//                          pays it — above it, both arms pay and the delta does not move,
//                          which is the measurement working rather than failing
//
// THE ROUND-11 NINE — `docs/verification/splash-screens-2026-09-01/mutation-runs.txt`.
//
//   1   splash-library.js  a round-8.1 palette study put back into the shipping library
//   3   splash.js          the rising frame stops stretching, so the bar leaves the plinth's
//                          width                                       (also reddens 22, 23)
//   4   splash.js          `choose()` ignores the ordinal and always returns the first
//   6   splash.js          `LINE_SIZE` back to 12px
//   8   splash.js          `settleBar()` removed from the yield, so the bar is left standing
//                          at a fraction on the way out                    (also reddens 23)
//  12b  splash.js          `secondsFor()` stops clamping to MAX_SPLASH_SECONDS
//  22   splash.js          the bar restarts itself the instant the landing flare ends.
//                          THIS ONE PASSED FIRST TIME AND THE CHECK WAS FIXED, not the
//                          mutation abandoned: watching the width can only see a loop whose
//                          period is shorter than the second the curtain has left, and this
//                          restart began at 3950ms — one sample past the last one taken.
//                          `state.barPasses` and `state.barStopped` exist because of it.
//  22   splash.js          a `focus` listener that restarts the bar, which is the shape a
//                          naive "make it replay" fix would take. Leg 1 catches it without
//                          the bar being watched at all.
//  23   splash-library.js  `tagline` back to the trim the round-8.1 sources set it in —
//                          2.65:1 against a 4.5:1 floor, the failure the lift fixed
// ---------------------------------------------------------------------------------------

main().then(
  (failed) => process.exit(failed ? 1 : 0),
  (e) => {
    console.error(e);
    process.exit(1);
  }
);

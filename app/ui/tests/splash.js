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

const FORCE = (wanted) => {
  let lib;
  Object.defineProperty(window, "RichSplashLibrary", {
    configurable: true,
    get: () => lib,
    set: (x) => {
      lib = {
        schemaVersion: x.schemaVersion,
        round: x.round,
        variations: x.variations.filter((v) => v.id === wanted),
      };
    },
  });
};

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
  if (opts.hold) await page.addInitScript(HOLD_OPEN);
  if (opts.force) await page.addInitScript(FORCE, opts.force);
  if (opts.init) await page.addInitScript(opts.init, opts.initArg);
  await page.goto(APP);
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
async function settledShot(page, name) {
  await page.waitForTimeout(3000);
  fs.mkdirSync(SHOTS, { recursive: true });
  const s = await shot(page, name, { fullPage: false });
  fs.copyFileSync(s.file, path.join(SHOTS, name + ".png"));
  return name + ".png (" + s.width + "x" + s.height + ", " + s.distinct + " distinct colors)";
}

/// A photograph of the MAT ALONE, and what was laid on it. `mute` empties the entry's
/// material stack and changes nothing else — which is what makes check 15's comparison a
/// comparison of the material rather than of two different versions.
async function matShot(browser, id, mute) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await newPage(ctx);
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
            return c;
          }),
        };
      },
    });
  }, { id, mute });
  await page.goto(APP);
  await page.waitForTimeout(2200);
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
  x.font = "12px -apple-system, Helvetica, Arial, sans-serif";
  x.fillText(o.left + " — whole mat, half scale", 2, 16);
  if (b) x.fillText(o.right + " — whole mat, half scale", halfW + GAP + 2, 16);
  x.fillText(o.left + " — top-left corner, native", 2, BAR + halfH + 16);
  if (b) x.fillText(o.right + " — top-left corner, native", CW + GAP + 2, BAR + halfH + 16);
  return c.toDataURL("image/png").split(",")[1];
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
  const run = createRun("the opening screen — a library, a random draw, an off switch, and no delay");
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
    assert(Array.isArray(LIBRARY.variations) && LIBRARY.variations.length >= 7, "variations");
    await page.__ctx.close();
    return `${LIBRARY.variations.length} entries, round ${LIBRARY.round}, JSON-parsed from disk and matching the page`;
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
        };
      });
      assert(r, "nothing drawn for " + v.id);
      assertEqual(r.id, v.id, "the forced entry is the one drawn");
      assert(r.plinth && r.rule, v.id + ": the composition is incomplete");
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
    return drawn.length + " entries, each drawn in full: " + drawn.join(", ");
  });

  // ---- the mechanic ---------------------------------------------------------------------

  await run.check("4  he meets a different one — real launches, no immediate repeat", async () => {
    // The CEO's own mechanic, observed rather than asserted: launch repeatedly, see
    // different compositions. Nothing is forced and nothing is held here — these are the
    // draws the shipped renderer makes, read back off `state` after the surface has already
    // gone. The no-immediate-repeat guard is the other half: unpredictable is not the same
    // as "occasionally the same one twice in a row", which is what a bare `Math.random()`
    // gives you about one launch in seven.
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await newPage(ctx);
    const seen = [];
    for (let i = 0; i < 12; i++) {
      await page.goto(APP);
      await page.waitForFunction(() => window.RichSplash && window.RichSplash.state.variationId);
      seen.push(await page.evaluate(() => window.RichSplash.state.variationId));
    }
    assert(page.__errors.length === 0, "errors: " + page.__errors.join("; "));
    const distinct = new Set(seen);
    assert(distinct.size >= 2, "12 launches produced one composition: " + seen[0]);
    for (let i = 1; i < seen.length; i++) {
      assert(seen[i] !== seen[i - 1], `launch ${i} repeated ${seen[i]} immediately`);
    }
    await ctx.close();
    return `12 launches, ${distinct.size} distinct compositions, 0 immediate repeats: ${seen.join(" → ")}`;
  });

  await run.check("5  two launches, two compositions, photographed", async () => {
    // The completion criterion's first clause, as evidence. Held open with `holdOpen()`
    // because the real surface is gone in a quarter of a second and a photograph of it has
    // to be taken while it is up; the compositions themselves are the shipped ones.
    const [a, b] = [LIBRARY.variations[0], LIBRARY.variations[6]];
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
      };
    });
    const stray = r.classes.filter((c) => !ALLOWED.has(c));
    assertEqual(stray, [], v.id + ": elements the composition is not made of");
    assertEqual(r.buttons, 0, v.id + ": the study's five clickable chips came across");
    assertEqual(r.text, "The AI Operating System for CEOs", v.id + ": the only text on the surface");
    // Which also settles it: nothing here reads as a hex value, a role name or a round
    // number, because nothing here reads as anything but that one line.
    assert(!/[0-9]/.test(r.text), v.id + ": a digit reached the surface: " + r.text);
    swept.push(v.id);
    await page.__ctx.close();
    }
    return `${swept.length} entries swept, ${r.classes.length} class names on the last, all from the composition · tags: ${r.tags.join(", ")} · text: "${r.text}"`;
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

  await run.check("8  the ceremony is cut, the mark never is", async () => {
    // §2 says the splash yields mid-animation, unfinished, the instant the app is up. Taken
    // literally that leaves the ceremonial compositions showing an arrow of unlit steel and
    // a rule of zero width on a fast launch — a half-drawn mark, which is the one thing
    // this surface must never show. So the yield PINS the composition where it was going
    // and then fades it: the performance is cut, the mark is not.
    const v5 = LIBRARY.variations.find((v) => v.tokens.strike === "fill");
    assert(v5, "no colour-strike entry in the library to test the pin against");
    const page = await launch(browser, { hold: true, force: v5.id });
    // 300ms in: the strike does not start until 1.75s, so the gold is genuinely unlit and
    // the rule genuinely has no width. Without this half the check would pass on a surface
    // that had simply never animated.
    await page.waitForTimeout(300);
    const before = await page.evaluate(() => ({
      fill: getComputedStyle(document.querySelector("#splash .splash-signal")).fill,
      ruleWidth: Math.round(document.querySelector("#splash .splash-rule").getBoundingClientRect().width),
    }));
    assertEqual(before.fill, rgbOf(v5.tokens.strikeFrom), "mid-ceremony the gold has not arrived yet");
    assertEqual(before.ruleWidth, 0, "mid-ceremony the rule has not drawn yet");
    // His first keystroke is one of the three things that make the surface yield.
    await page.keyboard.press("a");
    const after = await page.evaluate(() => {
      const n = document.getElementById("splash");
      return {
        settled: n.classList.contains("splash--settled"),
        fill: getComputedStyle(n.querySelector(".splash-signal")).fill,
        ruleWidth: Math.round(n.querySelector(".splash-rule").getBoundingClientRect().width),
        reason: window.RichSplash.state.reason,
      };
    });
    assert(after.settled, "the surface did not pin itself on the way out");
    assertEqual(after.fill, rgbOf(v5.tokens.signal), "the gold it leaves on");
    assertEqual(after.ruleWidth, parseInt(v5.tokens.ruleWidth, 10), "the rule it leaves on");
    assertEqual(after.reason, "first-input", "what made it yield");
    await page.__ctx.close();
    return `${v5.id}: at 300ms unlit steel and a 0px rule; on his first keystroke ${after.fill} and ${after.ruleWidth}px, then gone`;
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
    // screen. The curtain has always been click-through; the home screen is not, and it is
    // not meant to be. Everything above and below still tests the curtain itself.
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

  await run.check("12b  the composition shows for a NAMED three seconds, not for however long booting took", async () => {
    // CEO, 2026-08-31: "the splash shows for 3 seconds by default", 3-5 s by type later.
    //
    // BEFORE THIS, THE ANSWER TO "HOW LONG?" WAS "HOWEVER LONG THE BOOT TOOK". `main.js`
    // calls `yieldNow("app-ready")` the moment the shell is usable, which on this machine is
    // about a tenth of a second — so the composition was gone before it had been seen, and
    // no line anywhere expressed a duration. Half the value of this check is that the number
    // is now findable: it asserts the constant EXISTS and is 3000, so the per-type range can
    // be added later without anyone hunting through the removal path for a literal.
    const src = fs.readFileSync(RENDERER_FILE, "utf8");
    const m = src.match(/var HOLD_MS = (\d+);/);
    assert(m, "no named HOLD_MS in splash.js — the duration is a literal again, or gone");
    assertEqual(Number(m[1]), 3000, "the CEO's default");

    // ...and it is HONOURED, which the constant alone does not prove.
    const page = await launch(browser);
    const t0 = Date.now();
    await page.waitForFunction(() => !document.getElementById("splash"), { timeout: 15000 });
    const gone = Date.now() - t0;
    const reason = await page.evaluate(() => window.RichSplash.state.reason);
    assertEqual(reason, "held", "it left for some reason other than the hold being served");
    // The floor is the hold itself; the ceiling allows the fade and the removal timer on top
    // of it. Anything under 3000 means the app-ready path cut the ceremony short again.
    assert(
      gone >= 3000 && gone < 3000 + 900,
      "the curtain cleared at " + gone + "ms; expected the 3000ms hold plus its fade"
    );
    await page.__ctx.close();
    return "HOLD_MS = 3000, named in splash.js, and the curtain cleared at " + gone + "ms with reason \"held\"";
  });

  await run.check("12c  the hold never catches his hand, and never defers the failsafe", async () => {
    // THE TWO THINGS A DURATION COULD BREAK, and they are the two this surface must not
    // break. §5.5 forbids anything on it that is delaying, so his first keystroke has to win
    // against the hold; and a ceiling that could itself be deferred is not a failsafe.
    const typed = await launch(browser);
    await typed.waitForSelector(".nav-thread", { state: "attached" });
    const t0 = Date.now();
    await typed.keyboard.press("a");
    await typed.waitForFunction(() => !document.getElementById("splash"), { timeout: 4000 });
    const byHand = Date.now() - t0;
    assertEqual(
      await typed.evaluate(() => window.RichSplash.state.reason),
      "first-input",
      "his keystroke was swallowed by the hold and reported as something else"
    );
    assert(byHand < 1500, "his hand waited " + byHand + "ms on a 3000ms hold — the hold caught it");
    await typed.__ctx.close();

    // And with app-ready muted entirely, the ceiling still clears it — check 10 proves the
    // timing; this proves the HOLD did not quietly become the thing that clears it, which
    // would leave a hung boot showing the curtain forever.
    const hung = await launch(browser, { hold: true });
    await hung.waitForTimeout(4400);
    assertEqual(
      await hung.evaluate(() => window.RichSplash.state.reason),
      "ceiling",
      "with app-ready muted the curtain must still leave on its own ceiling"
    );
    await hung.__ctx.close();
    return "first-input cleared it in " + byHand + "ms against a 3000ms hold; the ceiling still fires with app-ready muted";
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
    const withMaterial = LIBRARY.variations.filter((v) => v.tokens.materials.length);
    assert(withMaterial.length >= 11, "only " + withMaterial.length + " entries carry a material stack");
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
    // to the number in the library it came from.
    const told = [];
    for (const v of LIBRARY.variations) {
      const t = v.tokens;
      const page = await launch(browser, { hold: true, force: v.id });
      const f = await page.evaluate(() => {
        const n = document.querySelector("#splash filter#richos-splash-relief");
        const cs = (sel) => getComputedStyle(document.querySelector("#splash " + sel)).filter;
        return {
          present: !!n,
          region: n ? [n.getAttribute("x"), n.getAttribute("y"), n.getAttribute("width"), n.getAttribute("height")].join(" ") : null,
          floods: n ? Array.from(n.querySelectorAll("feFlood")).map((e) => e.getAttribute("flood-color") + "@" + e.getAttribute("flood-opacity")) : [],
          offsets: n ? Array.from(n.querySelectorAll("feOffset")).map((e) => e.getAttribute("dx") + "," + e.getAttribute("dy")) : [],
          blurs: n ? Array.from(n.querySelectorAll("feGaussianBlur")).map((e) => e.getAttribute("stdDeviation")) : [],
          noise: n && n.querySelector("feTurbulence")
            ? ["type", "baseFrequency", "numOctaves", "seed"].map((a) => n.querySelector("feTurbulence").getAttribute(a)).join(" ")
            : null,
          merge: n ? Array.from(n.querySelectorAll("feMerge feMergeNode")).map((e) => e.getAttribute("in")) : [],
          ink: cs(".splash-ink"),
          signal: cs(".splash-signal"),
          // What the ENTRY asked for, as opposed to what is on the element right now: v5
          // and v6 are mid-strike at this instant and the strike is a `filter` animation,
          // so the computed value there is the ceremony, not the entry's answer.
          inkVar: document.getElementById("splash").style.getPropertyValue("--splash-mark-filter"),
          signalVar: document.getElementById("splash").style.getPropertyValue("--splash-signal-filter"),
        };
      });
      if (!t.relief) {
        assertEqual(f.present, false, v.id + ": a relief filter was built for an entry that asked for none");
        assertEqual(f.inkVar, t.markFilter || "none", v.id + ": the ink's filter is not what the entry asked for");
        assertEqual(f.signalVar, t.signalFilter || "none", v.id + ": the gold's filter is not what the entry asked for");
        if (t.signalFilter) assert(f.signal !== "none", v.id + ": its CSS signal filter did not reach the gold");
        // A composition that is not performing a strike has nothing else that could be
        // putting a filter on its paths, so there had better not be one.
        else if (!t.markFilter && t.strike === "none") assertEqual(f.signal, "none", v.id + ": the gold carries a filter it did not ask for");
        await page.__ctx.close();
        continue;
      }
      assert(f.present, v.id + ": it asked for a relief and none was built");
      assertEqual(f.region, t.relief.region, v.id + ": the filter region");
      assertEqual(f.floods, t.relief.bands.map((b) => b.color + "@" + b.opacity), v.id + ": the bands' floods");
      assertEqual(f.offsets, t.relief.bands.map((b) => b.dx + "," + b.dy), v.id + ": the bands' offsets");
      assertEqual(f.blurs, t.relief.bands.map((b) => b.blur), v.id + ": the bands' blurs");
      assertEqual(f.noise, t.relief.noise
        ? [t.relief.noise.type, t.relief.noise.baseFrequency, t.relief.noise.octaves, t.relief.noise.seed].join(" ")
        : null, v.id + ": the noise field");
      // The order. Outer bands, then the mark, then the noise and the inner bands.
      const outer = t.relief.bands.map((b, i) => [b, i]).filter(([b]) => b.placement === "outer").map(([, i]) => "band" + i);
      const inner = t.relief.bands.map((b, i) => [b, i]).filter(([b]) => b.placement === "inner").map(([, i]) => "band" + i);
      const want = outer.concat(["SourceGraphic"], t.relief.noise ? ["grain"] : [], inner);
      assertEqual(f.merge, want, v.id + ": the merge order");
      assert(f.signal.indexOf("richos-splash-relief") >= 0, v.id + ": the relief did not reach the gold");
      if (t.relief.target === "mark") assert(f.ink.indexOf("richos-splash-relief") >= 0, v.id + ": a mark relief did not reach the ink");
      else assertEqual(f.ink, "none", v.id + ": a signal-only relief reached the ink");
      told.push(v.id.replace("round-8.1/", "") + " " + t.relief.target + "/" + t.relief.bands.length + "band" + (t.relief.noise ? "+noise" : ""));
      await page.__ctx.close();
    }
    // The check has to have exercised something: every entry the library says carries a
    // relief was reached, and there is more than a token number of them. The count is read
    // off the library rather than typed, so removing an entry cannot quietly weaken this.
    const declared = LIBRARY.variations.filter((x) => x.tokens.relief).length;
    assertEqual(told.length, declared, "entries with a relief that this check actually reached");
    assert(declared >= 5, "only " + declared + " entries carry a relief — this check is barely exercising anything");
    return `${declared} of ${LIBRARY.variations.length} entries carry one: ` + told.join(" · ");
  });

  await run.check("17  the ceremony is cut, and the MATERIAL still is not", async () => {
    // Check 8's rule, one layer deeper. Yielding pins the composition where it was going,
    // and it used to do that by setting `filter: none` on the gold — which was right when
    // the only filter there was the bloom strike and wrong the moment an entry can give the
    // mark a relief: pinning would have flattened the metal the version is made of, on
    // exactly the fast launches the CEO sees most.
    const v = LIBRARY.variations.find((x) => x.tokens.relief && x.tokens.relief.target === "mark");
    assert(v, "no mark-relief entry in the library to test the pin against");
    const page = await launch(browser, { hold: true, force: v.id });
    await page.waitForTimeout(300);
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
    assert(before.indexOf("richos-splash-relief") >= 0, v.id + ": the relief was not on the gold to begin with");
    assert(after.signal.indexOf("richos-splash-relief") >= 0, v.id + ": pinning the composition flattened the gold's relief");
    assert(after.ink.indexOf("richos-splash-relief") >= 0, v.id + ": pinning the composition flattened the ink's relief");
    await page.__ctx.close();
    return `${v.id}: relief on the gold at 300ms and still on it after his first keystroke (${after.signal})`;
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
    const added = LIBRARY.variations.filter((v) => v.tokens.materials.length);
    assert(added.length >= 11, "only " + added.length + " material versions to photograph");
    const haveStudies = fs.existsSync(HQ);
    fs.mkdirSync(SHOTS, { recursive: true });
    const cmp = await browser.newContext({ viewport: { width: 400, height: 300 } });
    const judge = await cmp.newPage();
    await judge.goto("about:blank");
    const made = [];
    for (const v of added) {
      const slug = v.id.replace("round-8.1/", "");
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
    const page = await launch(browser, { hold: true, force: "round-8.1/v3" });
    await page.waitForFunction("window.__RICHOS_MOCK__ && window.__RICHOS_MOCK__.launchCalls().stateReads.length > 0");
    const drew = await page.evaluate(() => ({
      calls: window.__RICHOS_MOCK__.launchCalls(),
      shownId: window.RichSplash.state.variationId,
      // The offset the browser itself would compute, derived here independently of main.js.
      expectedOffset: -new Date().getTimezoneOffset(),
    }));
    assertEqual(drew.calls.splashShown, [drew.shownId], "the ring was not fed the id that was drawn");
    assertEqual(drew.shownId, "round-8.1/v3", "the forced entry is the one recorded");
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

  await browser.close();
  if (shotNames.length) console.log("\n  shots → " + path.relative(process.cwd(), SHOTS) + "/: " + shotNames.join(", "));
  return run.report();
}

// ---------------------------------------------------------------------------------------
// THE THIRTEEN MUTATIONS, against their check numbers.
//
// Every check above was run RED once by making exactly one of these edits to the SHIPPED
// source and watching this suite say so. The full runs, with the suite's own output and
// three notes on mutations that were wrong before they were right, are in
// `docs/verification/opening-screen-2026-08-30/mutation-runs.txt`. They are listed here as
// well so the record and the checks cannot drift apart silently.
//
//   1   splash-library.js  `"round": "8.1"` → `"round": String("8.1")` — valid JS, not JSON
//   2   splash.js          a hex colour constant added beside GILD_ID
//   3   splash-library.js  v3's `"surface"` token renamed, i.e. removed
//   4   splash.js          pick() returns candidates[0] — no draw, no repeat guard
//   5   splash.js          the `--splash-surface` assignment deleted
//   6   splash.js          a `.splash-corner` element appended, as the studies carry
//   7   splash.css         `pointer-events: none` → `auto` on the curtain
//   8   splash.js          the `splash--settled` class no longer added on the way out
//   9   splash.js          pool() returns the library unvalidated
//  10   splash.js          the ceiling timer deleted
//  11   main.js            the switch stops writing the local mirror
//  12   config.rs          `splash_default()` returns false
//  13   splash.js          a 40ms busy-wait, BELOW the switch check so only a drawn splash
//                          pays it — above it, both arms pay and the delta does not move,
//                          which is the measurement working rather than failing
// ---------------------------------------------------------------------------------------

main().then(
  (failed) => process.exit(failed ? 1 : 0),
  (e) => {
    console.error(e);
    process.exit(1);
  }
);

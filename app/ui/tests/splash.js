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
const { loadPlaywright, shot, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");
const LIB_FILE = path.join(UI_DIR, "splash-library.js");
const RENDERER_FILE = path.join(UI_DIR, "splash.js");
const CSS_FILE = path.join(UI_DIR, "splash.css");
const MAIN_JS = path.join(UI_DIR, "main.js");
const MAIN_RS = path.resolve(UI_DIR, "..", "src-tauri", "src", "main.rs");
const CONFIG_RS = path.resolve(UI_DIR, "..", "crates", "richos-core", "src", "config.rs");
const SHOTS = path.join(__dirname, "shots-splash");

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
  if (opts.init) await page.addInitScript(opts.init);
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
      "splash-plinth", "splash-sheen", "splash-logo", "splash-wordmark", "splash-ink",
      "splash-signal", "splash-foot", "splash-rule", "splash-line",
      "splash--strike-fill", "splash--strike-bloom", "splash--settled", "splash--yielding",
    ]);
    const page = await launch(browser, { hold: true, force: LIBRARY.variations[6].id });
    const r = await page.evaluate(() => {
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
    assertEqual(stray, [], "elements the composition is not made of");
    assertEqual(r.buttons, 0, "the study's five clickable chips came across");
    assertEqual(r.text, "The AI Operating System for CEOs", "the only text on the surface");
    // Which also settles it: nothing here reads as a hex value, a role name or a round
    // number, because nothing here reads as anything but that one line.
    assert(!/[0-9]/.test(r.text), "a digit reached the surface: " + r.text);
    await page.__ctx.close();
    return `${r.classes.length} class names, all from the composition · tags: ${r.tags.join(", ")} · text: "${r.text}"`;
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

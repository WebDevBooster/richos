// THE HOME SCREEN — the surface the CEO lands on, driven through the REAL SHELL.
//
// `index.html`, `home.js`, `home.css`, `home/field-*.js`, `main.js`, `mock.js` and
// `settings-button.js`, all loaded from disk, in WebKit — the engine Tauri renders through on
// macOS. Nothing is stubbed but the Tauri bridge, which `mock.js` already replaces exactly as
// an operator opening the file does.
//
// WHAT THIS SUITE IS FOR, in the CEO's own words (2026-09-01):
//
//   "This start screen/home screen (I'm going to refer to it as the home screen only from now)
//    must be shown in the app after the splash screen. Oh, and there needs to be some way for
//    the user to switch from the home screen to the regular app screen/UI. And in the regular
//    app UI a click on the logo (in the upper left corner) brings the user back to the home
//    screen."
//
//   "At the very top there should be a slim row with buttons named after the user's
//    entities/companies ... the company buttons should only appear if the user has more than
//    one company ... the user should also be able to customize in the settings the labels on
//    those company buttons and well as which to display on their home screen ... if the user
//    wanted to anonymize their home screen (for sharing on social media), they could change the
//    label buttons to something like '1', '2', '3' etc."
//
// HOW CONTRAST IS MEASURED HERE, AND WHY IT IS NOT THE DOM WALK `contrast.js` USES.
//
// Nearly everything on this screen sits over a `<canvas>`, and `lib/contrast.js` says so about
// itself in its own header: "`<canvas>` — pixels with no computed style. Nothing in this walk
// can read them." A DOM walk would report every line of this screen UNRESOLVABLE, which is the
// honest answer for that method and a useless one here.
//
// So this suite measures from the PIXELS, which is the method `round-11.1/v1/NOTES.md` used on
// the same composition: render, let it settle, set every glyph to `color: transparent` —
// layout, and therefore the renderer's own quiet rectangles, stay byte-identical — screenshot,
// and then sample the element's box and take THE PIXEL THAT MINIMIZES CONTRAST WITH THE INK.
// Not the average, not the token: the worst case that is actually on screen, which is what a
// moving nebula behind a caption demands.
//
// The arithmetic is `lib/contrast.js`'s, shipped into the page as its own source text, for the
// reason that file gives: a checker whose in-browser math is a COPY of the math its unit test
// proves is a checker with an unproven half.

"use strict";

const path = require("path");
const fs = require("fs");
const { loadPlaywright, leaveHome, shot, publishShotFile, createRun, assert, assertEqual, UI_DIR, SHOT_DIR } = require("./lib/harness");
const contrastLib = require("./lib/contrast");

const APP = "file://" + path.join(UI_DIR, "index.html");
const SHOTS = path.join(__dirname, "shots-home");

/// A DELIBERATE SLOW RUNNER, on demand — the same knob `splash.js` carries, deliberately the
/// same NAME, because it reproduces the same condition and one condition should not need two
/// switches. `page.goto()` resolves on `load`; the harness's next instruction after that landed
/// 51-72ms later on this machine and about 2,000ms later on a GitHub `macos-latest` runner.
///
///     RICHOS_SPLASH_LAG_MS=2000 node home.js
///
/// That gap is why the cold-launch check below was red on 2026-09-05: it SAMPLED the screen
/// once, from outside, at whatever moment the harness happened to get its turn, and on the
/// runner that moment was after the picture had finished. Zero, and no delay at all, unless it
/// is set.
const LAG_MS = Number(process.env.RICHOS_SPLASH_LAG_MS || 0);

/// The harness's six companies, as `mock.js` holds them and in its order. Written down HERE
/// so the suite can prove the row is the registry's rather than merely non-empty — a row that
/// had drifted to four, which is what `mock.js` carried until 2026-09-01, would otherwise pass
/// every other check in this file.
///
/// THEY BELONG TO NOBODY, and they used to be the CEO's own six. `mock.js` ships — `build.rs`
/// stages `app/ui` into `ui-dist` and Tauri embeds every file under it in the executable — so
/// that fixture put one man's company list inside every copy of RichOS ever built. The
/// registry is per-user since 2026-09-04 and its shipping default is empty; a harness fixture
/// is the only place a company list belongs.
const REGISTRY = [
  ["northwind", "Northwind Traders"],
  ["lumen", "Lumen Labs"],
  ["meridian", "Meridian Group"],
  ["harbor", "Harbor Analytics"],
  ["tidewater", "Tidewater Films"],
  ["kestrel", "Kestrel Supply"],
];

/// The row as it renders: the ids, what each button SAYS at rest, and the name each one is
/// hiding. A chip carries both labels at all times now, so `textContent` on the button is the
/// two of them run together and is never the right thing to read.
const READ_ROW = `(() => {
  const chips = Array.from(document.querySelectorAll('.home-chip'));
  return {
    ids: chips.map(c => c.getAttribute('data-entity')),
    rest: chips.map(c => (c.querySelector('.home-chip-rest') || {}).textContent),
    names: chips.map(c => { const n = c.querySelector('.home-chip-name'); return n ? n.textContent : null; }),
    aria: chips.map(c => c.getAttribute('aria-label')),
    pressed: chips.filter(c => c.getAttribute('aria-pressed') === 'true')
                  .map(c => (c.querySelector('.home-chip-rest') || {}).textContent),
    widths: chips.map(c => Math.round(c.getBoundingClientRect().width)),
    heights: chips.map(c => Math.round(c.getBoundingClientRect().height)),
  };
})()`;

async function openApp(browser, viewport) {
  const page = await browser.newPage({ viewport: viewport || { width: 1440, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.goto(APP);
  await page.waitForFunction("typeof window.RichHome === 'object'");
  await page.waitForFunction("typeof window.RichTimeline === 'object'");
  // The curtain is a separate feature with its own suite. Send it away so this one is about
  // what is underneath it, which is the surface this file exists for.
  await page.evaluate(() => window.RichSplash && window.RichSplash.yieldNow("acceptance-suite"));
  page.__errors = errors;
  return page;
}

/// Wait for the picture. `startField()` rather than the idle callback: a headless run's main
/// thread may never go idle on the schedule a real launch does, and this suite is about what
/// the field looks like once it is there — `perf` below is what measures WHEN it gets there.
async function withField(page) {
  await page.evaluate(() => window.RichHome.startField());
  await page.waitForFunction("window.RichHome.state.field === 'live'", { timeout: 60000 });
  await page.waitForFunction("window.__loro && !window.__loro.blooming", { timeout: 90000 });
  await page.waitForTimeout(300);
}

// ---------------------------------------------------------------------------------------
// Contrast, from the pixels
// ---------------------------------------------------------------------------------------

/// Install the arithmetic and the sampler in the page. Called once per page.
///
/// FOUR KINDS OF TARGET, because "the element's bounding box" is the wrong region for three of
/// them and a measurement over the wrong region is not a measurement:
///
///   text   the ink against what is behind the GLYPHS. The region is the text's own line boxes
///          (`Range.getClientRects`), never the element box — a `<button>`'s box includes its
///          border and the ground showing through its rounded corners, and a wide block's box
///          includes empty space the text never crosses. Measuring those reports a failure the
///          reader could not experience, which is as useless as missing one they could.
///   edge   a BORDER, which owes 3:1 to what is painted on BOTH sides of it (WCAG 1.4.11).
///          Measured against the ring just outside the box AND against the interior fill.
///   paint  a filled indicator with no text — the live dot. Its own fill is the ink and the
///          region is the ring around it, because what it owes contrast to is its surroundings.
///   svg    a path. Ink is the computed `fill`; region is the path's own box, with the fill
///          blanked so the background is what is measured.
async function installMeter(page) {
  await page.addScriptTag({ content: contrastLib.pageScript() });
  await page.addScriptTag({
    content: `
      window.__meter = {
        /// Hide every glyph WITHOUT moving anything: \`color: transparent\` leaves layout, and
        /// layout is what the field renderer's quiet-rectangle pass reads, so the background
        /// being measured is the background that was really there.
        ///
        /// It CANNOT hide canvas text, and that is deliberate rather than a gap: a label the
        /// picture draws inside a caption's line box is a real legibility problem and should
        /// show up as one.
        blank() {
          const style = document.createElement('style');
          style.id = '__blank';
          style.textContent =
            // TRANSITIONS OFF FIRST, and this line is not housekeeping — without it the
            // measurement is wrong and looks right. The chips transition their color over
            // 180ms and the signal numbers over 900ms, so a transparent color ANIMATES, and the
            // screenshot catches the glyphs still fully inked. Both came back at exactly
            // 1:1 against their own ink, which is the signature of measuring the text
            // against itself.
            '#home *, .home-prefs * { transition: none !important; animation: none !important; }' +
            '#home, #home * { color: transparent !important; }' +
            '#home svg * { fill: transparent !important; stroke: none !important; }' +
            '.home-prefs, .home-prefs * { color: transparent !important; }' +
            '.home-prefs input::placeholder { color: transparent !important; }';
          document.head.appendChild(style);
        },
        unblank() {
          const s = document.getElementById('__blank');
          if (s) s.remove();
        },

        /// The line boxes of an element's OWN text, in viewport coordinates.
        lineBoxes(el) {
          const out = [];
          for (const n of el.childNodes) {
            if (n.nodeType !== 3 || !n.textContent.trim()) continue;
            const r = document.createRange();
            r.selectNodeContents(n);
            for (const b of r.getClientRects()) {
              if (b.width > 0.5 && b.height > 0.5) out.push({ x: b.left, y: b.top, w: b.width, h: b.height });
            }
          }
          return out;
        },

        /// The interior of a box, inside its border and clear of its corner radius.
        ///
        /// padX steps the region further in from BOTH ends, and it exists because a control
        /// can carry an indicator of its own inside the area an edge measurement samples.
        /// The door does: its breathing dot starts 29px from the left edge, one pixel inside
        /// the default inset, so the door's gold border came back at 1.77:1 against
        /// rgb(121,106,69) — which is not the border against its own fill, it is the border
        /// against THE DOT. A boundary measured against a different indicator is not a
        /// measurement of anything.
        ///
        /// NO BACKTICKS ANYWHERE IN THIS BLOCK. Everything from installMeter's opening brace
        /// down is a template literal handed to addScriptTag, so one backtick in a comment
        /// ends the string and the file stops parsing.
        interior(el, padX) {
          const r = el.getBoundingClientRect();
          const cs = getComputedStyle(el);
          const bw = Math.max(
            parseFloat(cs.borderTopWidth) || 0, parseFloat(cs.borderLeftWidth) || 0,
            parseFloat(cs.borderRightWidth) || 0, parseFloat(cs.borderBottomWidth) || 0);
          let rad = parseFloat(cs.borderTopLeftRadius) || 0;
          rad = Math.min(rad, r.height / 2, r.width / 2);
          const insetX = bw + rad + 1 + (padX || 0);
          const insetY = bw + 1;
          const w = Math.max(1, r.width - insetX * 2);
          const h = Math.max(1, r.height - insetY * 2);
          return [{ x: r.left + insetX, y: r.top + insetY, w, h }];
        },

        /// The ring immediately OUTSIDE a box — four thin strips, which is where the other
        /// side of a border actually is.
        /// The ring immediately outside a box. TWO pixels by default, deliberately: WCAG
        /// 1.4.11 asks about what is painted ADJACENT to a boundary, and on this screen the
        /// thing adjacent to every control's edge is its own dark halo — sampling further out
        /// measures the picture two chips away rather than the boundary.
        ///
        /// THE CORNERS ARE EXCLUDED, and that is geometry rather than convenience: on a pill
        /// the area diagonally past a rounded corner is outside BOTH the control and the halo
        /// that surrounds it, so a strip that ran the full width would sample the raw picture
        /// and call it the boundary's neighbor. It did: the switch measured 2.15:1 against a
        /// river strand at rgb(199,46,110) that was never touching its edge at all. Each strip
        /// is inset by the corner radius, which leaves exactly the straight runs of the edge.
        ring(el, thickness, gap) {
          const raw = el.getBoundingClientRect();
          const g = gap || 0;
          // The gap steps the ring OUTWARD past a glow the element paints itself. Without it the
          // live dot would be measured against its own 7px halo, which is the indicator
          // against itself.
          const r = { left: raw.left - g, top: raw.top - g, right: raw.right + g, bottom: raw.bottom + g,
                      width: raw.width + 2 * g, height: raw.height + 2 * g };
          const t = thickness || 2;
          const cs = getComputedStyle(el);
          let rad = parseFloat(cs.borderTopLeftRadius) || 0;
          rad = Math.min(rad, r.height / 2, r.width / 2);
          const hx = Math.max(0, rad);
          const vy = Math.max(0, rad);
          const out = [];
          if (r.width - 2 * hx > 1) {
            out.push({ x: r.left + hx, y: r.top - t, w: r.width - 2 * hx, h: t });
            out.push({ x: r.left + hx, y: r.bottom, w: r.width - 2 * hx, h: t });
          }
          if (r.height - 2 * vy > 1) {
            out.push({ x: r.left - t, y: r.top + vy, w: t, h: r.height - 2 * vy });
            out.push({ x: r.right, y: r.top + vy, w: t, h: r.height - 2 * vy });
          }
          // A shape whose radius eats the whole box — a circle, which is what the live dot is
          // — has no straight run to inset. The four points due left, right, above and below
          // its center are exactly on its edge, so those are what get sampled.
          if (!out.length) {
            const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
            out.push({ x: r.left - t, y: cy - 0.5, w: t, h: 1 });
            out.push({ x: r.right, y: cy - 0.5, w: t, h: 1 });
            out.push({ x: cx - 0.5, y: r.top - t, w: 1, h: t });
            out.push({ x: cx - 0.5, y: r.bottom, w: 1, h: t });
          }
          return out;
        },

        /// The regions and the ink, read BEFORE blanking so the ink is the real one.
        targets(list) {
          return list.map(t => {
            const el = document.querySelector(t.sel);
            if (!el) return { name: t.name, missing: true, needs: t.needs };
            const cs = getComputedStyle(el);
            const kind = t.kind || 'text';
            let ink = t.ink;
            let regions = [];
            if (kind === 'text') {
              ink = ink || cs.color;
              regions = this.lineBoxes(el);
              if (!regions.length) regions = this.interior(el);
            } else if (kind === 'edge') {
              ink = ink || cs.borderTopColor;
              regions = this.ring(el, 3).concat(this.interior(el, t.padX));
            } else if (kind === 'paint') {
              ink = ink || cs.backgroundColor;
              regions = this.ring(el, t.ringWidth || 4, t.ringGap || 0);
            } else if (kind === 'svg') {
              ink = ink || cs.fill;
              regions = this.interior(el);
            } else if (kind === 'fill') {
              ink = ink || cs.color;
              regions = this.interior(el, t.padX);
            }
            // THE ELEMENT'S OWN OPACITY IS PART OF ITS INK. The live dot is painted in the
            // ruled signal at 55 percent opacity while it rests; measuring the token as though it
            // were opaque would report a control that is half again more visible than the one
            // on screen.
            const op = parseFloat(cs.opacity);
            if (isFinite(op) && op < 1 && ink) {
              const m = String(ink).match(/^rgba?\(([^)]+)\)$/);
              if (m) {
                const parts = m[1].split(/[,/\s]+/).filter(Boolean);
                const a = parts.length === 4 ? parseFloat(parts[3]) : 1;
                ink = 'rgba(' + parts[0] + ',' + parts[1] + ',' + parts[2] + ',' + (a * op) + ')';
              }
            }
            return {
              name: t.name,
              needs: t.needs,
              kind,
              ink,
              fontPx: parseFloat(cs.fontSize),
              bold: (parseInt(cs.fontWeight, 10) || 400) >= 700,
              regions,
            };
          });
        },

        /// Decode the screenshot and, for each target, find the pixel across its regions that
        /// MINIMIZES contrast with its ink. Worst case on the frame, not an average of it.
        async worst(b64, targets) {
          const img = new Image();
          await new Promise((res, rej) => { img.onload = res; img.onerror = () => rej(new Error('the PNG did not decode')); img.src = 'data:image/png;base64,' + b64; });
          const c = document.createElement('canvas');
          c.width = img.naturalWidth; c.height = img.naturalHeight;
          const ctx = c.getContext('2d');
          ctx.drawImage(img, 0, 0);
          const scale = img.naturalWidth / window.innerWidth;
          return targets.map(t => {
            if (t.missing) return t;
            const ink = window.__contrastMath.parseCssColor(t.ink);
            if (!ink) return Object.assign({}, t, { unresolvable: 'ink is ' + t.ink });
            if (!t.regions.length) return Object.assign({}, t, { unresolvable: 'nothing to sample' });
            let worst = Infinity, worstPx = null, sampled = 0;
            for (const reg of t.regions) {
              const x0 = Math.max(0, Math.round(reg.x * scale));
              const y0 = Math.max(0, Math.round(reg.y * scale));
              const w = Math.min(c.width - x0, Math.max(1, Math.round(reg.w * scale)));
              const h = Math.min(c.height - y0, Math.max(1, Math.round(reg.h * scale)));
              if (w < 1 || h < 1) continue;
              const d = ctx.getImageData(x0, y0, w, h).data;
              for (let y = 0; y < h; y++) {
                for (let x = 0; x < w; x++) {
                  const i = (y * w + x) * 4;
                  const bg = { r: d[i], g: d[i + 1], b: d[i + 2], a: 1 };
                  const over = window.__contrastMath.compositeOver(ink, bg);
                  const ratio = window.__contrastMath.contrastRatio(over, bg);
                  sampled++;
                  if (ratio < worst) { worst = ratio; worstPx = [d[i], d[i + 1], d[i + 2]]; }
                }
              }
            }
            if (!sampled) return Object.assign({}, t, { unresolvable: 'no pixels in range' });
            return Object.assign({}, t, {
              ratio: window.__contrastMath.round2(worst),
              worstPx,
              sampled,
              large: window.__contrastMath.isLargeText(t.fontPx, t.bold),
            });
          });
        },
      };
    `,
  });
}

/// Measure a list of `{ name, sel, needs, kind?, ink? }` against the rendered frame.
async function measure(page, list) {
  const targets = await page.evaluate((l) => window.__meter.targets(l), list);
  await page.evaluate(() => window.__meter.blank());
  const buf = await page.screenshot({ fullPage: false });
  await page.evaluate(() => window.__meter.unblank());
  // PUT THE PAGE BACK BEFORE ANYTHING ELSE LOOKS AT IT. `unblank` removes the sheet that was
  // holding every transition at zero, so the inks the sheet had driven to transparent now
  // ANIMATE BACK — the signal numbers over 900ms. A screenshot taken by a later check in that
  // window catches them half-lit and commits a frame that looks like a rendering defect. It
  // did: `home-named.png` shipped once with five ghosted numbers down the left column.
  await page.waitForTimeout(1100);
  return page.evaluate(
    ({ b64, targets }) => window.__meter.worst(b64, targets),
    { b64: buf.toString("base64"), targets }
  );
}

function reportRatios(rows) {
  return rows
    .map((r) => {
      if (r.missing) return r.name + ": MISSING";
      if (r.unresolvable) return r.name + ": UNRESOLVABLE (" + r.unresolvable + ")";
      return `${r.name} ${r.ink} on rgb(${r.worstPx.join(",")}) = ${r.ratio}:1 (needs ${r.needs}, ${Math.round(r.fontPx)}px)`;
    })
    .join("\n          ");
}

function failures(rows) {
  return rows.filter((r) => r.missing || r.unresolvable || r.ratio < r.needs);
}

// ---------------------------------------------------------------------------------------

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("The home screen — round-11.1/v1 in the app, real shell, WebKit");
  fs.mkdirSync(SHOTS, { recursive: true });

  const page = await openApp(browser);
  await installMeter(page);

  await run.check("the home screen is the surface the app lands on, over the shell", async () => {
    const r = await page.evaluate(() => {
      const h = document.getElementById("home");
      const app = document.getElementById("app");
      const hr = h.getBoundingClientRect();
      return {
        present: !!h,
        hidden: h.hidden,
        open: window.RichHome.state.open,
        coversViewport: Math.round(hr.width) === innerWidth && Math.round(hr.height) === innerHeight,
        z: parseInt(getComputedStyle(h).zIndex, 10),
        appInert: app.hasAttribute("inert"),
        bodyClass: document.body.classList.contains("home-open"),
      };
    });
    assert(r.present && !r.hidden && r.open, "the home screen is not the surface in front");
    assert(r.coversViewport, "the home screen does not cover the window");
    assert(r.appInert, "#app is not inert behind it — the composer can still take his keystrokes");
    assertEqual(r.z, 150, "the home screen must sit under the curtain (200) and the settings button (300)");
    return `mounted, open, covering ${await page.evaluate(() => innerWidth + "x" + innerHeight)}, z-index ${r.z}, #app inert`;
  });

  await run.check("§15's permanent exception: the home screen is dark, and the settings floor still holds", async () => {
    const r = await page.evaluate(() => ({
      theme: document.documentElement.getAttribute("data-theme"),
      forced: window.RichTheme.forcedDark(),
      pref: window.RichTheme.theme(),
      settingsPresent: !!document.querySelector(".setbtn"),
    }));
    assertEqual(r.theme, "dark", "the home screen is not rendering dark");
    assert(r.forced, "the always-dark clamp is not raised");
    // The clamp is a FORCE flag, never a write — the CEO's own choice has to survive it.
    await page.evaluate(() => window.RichTheme.setTheme("light"));
    const still = await page.evaluate(() => ({
      theme: document.documentElement.getAttribute("data-theme"),
      pref: window.RichTheme.theme(),
    }));
    assertEqual(still.theme, "dark", "light mode reached the home screen");
    assertEqual(still.pref, "light", "the CEO's own preference was overwritten rather than clamped");
    // §15: the settings button is on EVERY screen and its floor is "Bust a bug".
    await page.click(".setbtn");
    const menu = await page.evaluate(() => ({
      open: !document.getElementById("set-menu").hidden,
      theme: !!document.querySelector(".theme-seg"),
      bug: !!document.getElementById("bug-btn"),
      home: !!document.getElementById("set-home-open"),
    }));
    await page.keyboard.press("Escape");
    assert(menu.open, "the settings menu did not open on the home screen");
    assert(!menu.theme, "the theme row is offered on a screen no switch reaches");
    assert(menu.bug, "Bust a bug is missing — that is the floor §15 names");
    assert(menu.home, 'the "Home screen" row is missing from the settings menu');
    await page.evaluate(() => window.RichTheme.setTheme("dark"));
    return "rendered dark with pref=light held underneath; menu has Bust a bug and Home screen, no theme row";
  });

  await run.check("the picture is the round's, and it is the app's own dataset that draws it", async () => {
    await withField(page);
    const r = await page.evaluate(() => ({
      N: window.__loro.N,
      L: window.__loro.L,
      S: window.__loro.S,
      variant: window.__loro.V.name,
      exported: Object.keys(window.RichHome.VARIANT).length,
      nodeScale: window.__loro.V.nodeScale,
      clickZoom: window.__loro.V.clickZoom,
      visible: window.__loro.snapshot().visible,
    }));
    assertEqual(r.N, 7500, "the object count is not the round's 7,500");
    assertEqual(r.L, 12817, "the link count is not the round's 12,817");
    assertEqual(r.S, 4800, "the source count is not the round's 4,800");
    assertEqual(r.variant, "v1 Constellation", "the variant is not round-11.1/v1");
    // The two constants a well-meaning tuning pass would move first.
    assertEqual(r.nodeScale, 1.75, "nodeScale drifted from v5's value");
    assertEqual(r.clickZoom, 1.45, "clickZoom drifted from v5's value");
    return `${r.N} objects, ${r.L} links, ${r.S} sources, ${r.visible} on screen, variant "${r.variant}"`;
  });

  // -------------------------------------------------------------------------------------
  // The entity row
  // -------------------------------------------------------------------------------------

  await run.check("THE ROW IS `All 1 2 3 4 5 6` FOR EVERYONE, and the names are the registry's", async () => {
    // CEO, 2026-09-02: *"This will be the default for company buttons for everyone. Note: I
    // removed the word 'companies' from the 'All companies' button."*
    await page.waitForFunction("window.RichHome.state.entitySource === 'registry'");
    const r = await page.evaluate(READ_ROW);
    const state = await page.evaluate(() => ({
      source: window.RichHome.state.entitySource,
      count: window.RichHome.state.entityCount,
    }));
    assertEqual(r.ids, [""].concat(REGISTRY.map((e) => e[0])), "the row is not the registry, in registry order");
    // WHAT IT SAYS OUT OF THE BOX. Numbers, not names — this is the reversal, and it is the
    // one assertion that would catch it being quietly put back.
    assertEqual(r.rest, ["All", "1", "2", "3", "4", "5", "6"], "the row is not his ruled default");
    // ...and the names are still the registry's, waiting behind them.
    assertEqual(r.names.slice(1), REGISTRY.map((e) => e[1]), "the hidden names are not the registry's display names");
    assertEqual(r.names[0], null, "the All button is carrying a second label with nothing to reveal");
    // BOTH LABELS IN THE ACCESSIBLE NAME — a screen reader saying "1, button" says nothing.
    assertEqual(r.aria.slice(1), REGISTRY.map((e, i) => String(i + 1) + " " + e[1]), "a numbered button does not name its company to assistive technology");
    assertEqual(state.count, 6, "the row is not carrying his six companies");
    // `richos` is ONE entity with TWO roots. A row built from directories would show two.
    assertEqual(r.ids.filter((i) => i === "harbor").length, 1, "richos appeared more than once — two roots became two buttons");
    return `${r.rest.join(" ")} — and behind them, in registry order: ${r.names.slice(1).join(", ")}`;
  });

  await run.check('"All" is a visible DEFAULT STATE, not the absence of a selection', async () => {
    const before = await page.evaluate(() => ({
      pressed: Array.from(document.querySelectorAll('.home-chip[aria-pressed="true"]')).map((c) => c.querySelector(".home-chip-rest").textContent),
      entity: window.RichHome.state.entity,
    }));
    assertEqual(before.pressed, ["All"], "the default is not the pressed state on arrival");
    assertEqual(before.entity, "", "the default is not recorded as the selection");
    // The buttons do NOTHING to the picture in v1 — but they are real controls, not decoration.
    const framesBefore = await page.evaluate(() => window.__loro.frames);
    await page.click('.home-chip[data-entity="lumen"]');
    const after = await page.evaluate(() => ({
      pressed: Array.from(document.querySelectorAll('.home-chip[aria-pressed="true"]')).map((c) => c.querySelector(".home-chip-name").textContent),
      entity: window.RichHome.state.entity,
      disabled: !!document.querySelector(".home-chip[disabled]"),
      N: window.__loro.N,
    }));
    assertEqual(after.pressed, ["Lumen Labs"], "the selection did not move to the button that was pressed");
    assertEqual(after.entity, "lumen", "the selection is not carried as the entity id");
    assert(!after.disabled, "a button is disabled — these are real controls with an effect that is not built yet, not dead ones");
    assertEqual(after.N, 7500, "the picture changed — v1 filtering is NOT in scope and must not have shipped");
    await page.click('.home-chip[data-entity=""]');
    return `default pressed on arrival; pressing Lumen Labs moves the selection and leaves the picture at 7,500 (frames ${framesBefore} -> ${await page.evaluate(() => window.__loro.frames)})`;
  });

  await run.check("the row is ONE line of discs, centered, and does NOT fill the gap between the two columns", async () => {
    const r = await page.evaluate(() => {
      const box = document.getElementById("home-entities");
      const b = box.getBoundingClientRect();
      const tops = {};
      document.querySelectorAll(".home-chip").forEach((c) => {
        const t = Math.round(c.getBoundingClientRect().top);
        tops[t] = (tops[t] || 0) + 1;
      });
      const brand = document.getElementById("home-brand").getBoundingClientRect();
      const live = document.getElementById("home-live").getBoundingClientRect();
      return {
        vw: innerWidth,
        left: Math.round(b.left),
        right: Math.round(b.right),
        width: Math.round(b.width),
        bottom: Math.round(b.bottom),
        rows: Object.keys(tops).length,
        perRow: Object.keys(tops).sort((a, c) => a - c).map((k) => tops[k]),
        wrap: getComputedStyle(box).flexWrap,
        content: Math.round(Array.from(document.querySelectorAll(".home-chip")).reduce((w, c) => w + c.getBoundingClientRect().width, 0) + 6 * 12),
        clearLeft: Math.round(b.left),
        clearRight: Math.round(innerWidth - b.right),
        brandTop: Math.round(brand.top),
        liveTop: Math.round(live.top),
        inset: getComputedStyle(document.getElementById("home")).getPropertyValue("--home-top-inset").trim(),
      };
    });
    // ONE LINE, and that is the numbering's doing rather than a relaxed requirement. Seven
    // NAMED capsules measured about 790px in `round-11.3` and had to wrap; seven discs measure
    // 311px. `flex-wrap: wrap` is still declared and still asserted below, because a customer
    // with more companies than his six is exactly who it is for.
    assertEqual(r.rows, 1, "the numbered row is not on one line");
    assertEqual(r.wrap, "wrap", "the row can no longer wrap — a customer with more companies than his six would be cut off");
    assert(r.width <= 500, `the row is ${r.width}px wide; the cap is 500px so it cannot sprawl`);
    // Centered: the clear space on the two sides is equal to within a pixel.
    assert(Math.abs(r.clearLeft - r.clearRight) <= 1, `the row is not centered (${r.clearLeft}px left, ${r.clearRight}px right)`);
    // "shouldn't take up all of the empty space between the left and the right text column"
    assert(r.width < r.vw * 0.4, `the row takes ${Math.round((r.width / r.vw) * 100)}% of the window width`);
    // ...and the composition it displaces is BELOW it, by a measured inset rather than a guess.
    assert(r.brandTop > r.bottom, "the mark is not clear of the row");
    assert(r.liveTop > r.bottom, "the workforce list is not clear of the row");
    return `${r.rows} row (${r.perRow.join("+")}), ${r.content}px of controls in a ${r.width}px box capped at 500, ${r.clearLeft}px clear each side of a ${r.vw}px window, flex-wrap still ${r.wrap}, inset ${r.inset}, mark at ${r.brandTop} clear of a row ending at ${r.bottom}`;
  });

  await run.check("every numbered button is a DISC — width equal to height, not a shrunken capsule", async () => {
    // The check before this one leaves a selection moving. A pill measured mid-slide is a
    // lozenge by construction, which is how this first ran: `2` came back 84x33 because
    // "Lumen Labs" was still collapsing. `--home-chip-slide` is 240ms.
    await page.waitForFunction(
      () => Array.from(document.querySelectorAll('.home-chip:not([aria-pressed="true"])')).every((c) => {
        const b = c.getBoundingClientRect();
        return Math.abs(b.width - b.height) <= 1 || c.classList.contains("plain");
      }),
      { timeout: 4000 }
    );
    const r = await page.evaluate(READ_ROW);
    // The numerals are the default now, so this is no longer a state somebody switches on: it
    // is what a stranger opening the app sees, and a numeral in a lozenge reads as a mistake.
    // `round-11.3`'s rule, verbatim: "A single character is a disc, not a shrunken capsule.
    // The minimum width equals the height and the padding is symmetric."
    const discs = r.widths.slice(1);
    const tall = r.heights.slice(1);
    for (let i = 0; i < discs.length; i++) {
      assert(Math.abs(discs[i] - tall[i]) <= 1, `button ${r.rest[i + 1]} is ${discs[i]}x${tall[i]} — that is a lozenge, not a disc`);
    }
    // `All` is a capsule and is meant to be: it is a word, not a numeral.
    assert(r.widths[0] > r.heights[0], "the All button came out as a disc — it is a word and needs its own room");
    await shot(page, "home-anonymized", { fullPage: false });
    publishShotFile(path.join(SHOT_DIR, "home-anonymized.png"), path.join(SHOTS, "home-anonymized.png"));
    return `All ${r.widths[0]}x${r.heights[0]}; six discs at ${discs.join("/")}px wide x ${tall.join("/")}px tall`;
  });

  await run.check("clicking a number SLIDES the company's name out, left to right, over the number", async () => {
    // CEO, 2026-09-02: *"Only when the user clicks one of the numbers, will the company name
    // slide out (from left to right) and replace the number on the button."*
    //
    // WHAT IS PLACEHOLDER AND WHOSE IT IS: the finer conduct of the row — what the other
    // buttons do while one is expanded, whether a name persists, what `All` does to an expanded
    // one — is `iris-opus-row1`'s design and is deliberately not decided here. What is
    // implemented, and what this checks, is his sentence and nothing more: THE EXPANSION IS
    // THE SELECTION.
    const before = await page.evaluate(() => {
      const c = document.querySelector('.home-chip[data-entity="kestrel"]');
      const nm = c.querySelector(".home-chip-name");
      const cs = getComputedStyle(c.querySelector(".home-chip-track"));
      return {
        pill: Math.round(c.getBoundingClientRect().width),
        nameLeft: Math.round(nm.getBoundingClientRect().left),
        pillLeft: Math.round(c.getBoundingClientRect().left),
        track: cs.transform,
        rowH: Math.round(document.getElementById("home-entities").getBoundingClientRect().height),
        rowRows: new Set(Array.from(document.querySelectorAll(".home-chip")).map((x) => Math.round(x.getBoundingClientRect().top))).size,
        overflow: getComputedStyle(c).overflow,
        slide: getComputedStyle(document.getElementById("home")).getPropertyValue("--home-chip-slide").trim(),
      };
    });
    // AT REST the name is parked OFF TO THE LEFT of the pill — which is what makes the reveal
    // travel rightward rather than leftward. Not the transform string, the actual geometry.
    assert(before.nameLeft < before.pillLeft, `the hidden name is not parked left of the pill (name at ${before.nameLeft}, pill at ${before.pillLeft})`);
    assertEqual(before.overflow, "hidden", "the pill does not clip its track — the second label would be sitting in the open");

    // THE WHOLE TRAJECTORY, SAMPLED BY THE PAGE — because "mid-slide" is an instant inside a
    // 240ms transition and this file cannot be relied on to be present for it.
    //
    // It used to click, wait 80ms of ITS OWN clock and call that a third of the way through.
    // On the first public `ui-suite-ci` runner (33872963879) that instant arrived after the
    // slide had finished, so `mid` and `after` were both the resting position and differed by
    // three pixels of rounding — in the wrong direction. The check went red saying "the name
    // did not keep moving right (793 -> 790)" about an animation that had run correctly and
    // finished before anybody looked.
    //
    // A rAF sampler inside the page records the name's left edge every frame from the click
    // to the end of the transition. The direction, the monotonicity and the arrival are then
    // read off the recorded path, which is the property the CEO's sentence describes and is
    // true whatever speed the machine runs at.
    await page.evaluate(() => {
      window.__slide = [];
      const c = document.querySelector('.home-chip[data-entity="kestrel"]');
      const nm = c.querySelector(".home-chip-name");
      const step = () => {
        window.__slide.push({
          t: performance.now(),
          nameLeft: Math.round(nm.getBoundingClientRect().left),
          pill: Math.round(c.getBoundingClientRect().width),
        });
        if (window.__slide.length < 240) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    });
    await page.click('.home-chip[data-entity="kestrel"]');
    // The transition's own duration, off the stylesheet, plus a frame or two to settle —
    // never a number typed here.
    const slideMs = await page.evaluate(() =>
      parseFloat(getComputedStyle(document.getElementById("home")).getPropertyValue("--home-chip-slide")) || 240
    );
    await page.waitForTimeout(slideMs + 200);
    const path = await page.evaluate(() => window.__slide);
    const after = await page.evaluate(() => {
      const c = document.querySelector('.home-chip[data-entity="kestrel"]');
      const nm = c.querySelector(".home-chip-name");
      const num = c.querySelector(".home-chip-rest");
      return {
        pill: Math.round(c.getBoundingClientRect().width),
        nameLeft: Math.round(nm.getBoundingClientRect().left),
        nameRight: Math.round(nm.getBoundingClientRect().right),
        pillLeft: Math.round(c.getBoundingClientRect().left),
        pillRight: Math.round(c.getBoundingClientRect().right),
        numLeft: Math.round(num.getBoundingClientRect().left),
        rowH: Math.round(document.getElementById("home-entities").getBoundingClientRect().height),
        rowRows: new Set(Array.from(document.querySelectorAll(".home-chip")).map((x) => Math.round(x.getBoundingClientRect().top))).size,
        rowW: Math.round(document.getElementById("home-entities").getBoundingClientRect().width),
        others: Array.from(document.querySelectorAll('.home-chip:not([data-entity="kestrel"])')).map((x) => x.querySelector(".home-chip-rest").textContent),
        pressedNames: Array.from(document.querySelectorAll('.home-chip[aria-pressed="true"] .home-chip-name')).map((x) => x.textContent),
      };
    });

    // THE DIRECTION, from the recorded path: the name's left edge moved RIGHT, monotonically,
    // from outside the pill to inside it — and it TRAVELLED rather than jumping, which is
    // what makes it a slide and not a swap.
    assert(path.length > 4, `the slide was never sampled (${path.length} frames)`);
    const lefts = path.map((f) => f.nameLeft);
    const pills = path.map((f) => f.pill);
    for (let i = 1; i < lefts.length; i++) {
      assert(lefts[i] >= lefts[i - 1] - 1, `the name went BACKWARDS mid-slide (${lefts[i - 1]} -> ${lefts[i]})`);
      assert(pills[i] >= pills[i - 1] - 1, `the pill shrank mid-slide (${pills[i - 1]} -> ${pills[i]})`);
    }
    assert(lefts[lefts.length - 1] > lefts[0], `the name did not move right at all (${lefts[0]} -> ${lefts[lefts.length - 1]})`);
    assert(pills[pills.length - 1] > pills[0], `the pill did not grow with it (${pills[0]} -> ${pills[pills.length - 1]})`);
    // A SWAP WOULD SHOW NOTHING HERE: at least one frame strictly between the two ends, which
    // no instant replacement can produce however fast the machine is.
    const between = lefts.filter((x) => x > lefts[0] && x < lefts[lefts.length - 1]).length;
    assert(between > 0, `the name jumped from ${lefts[0]} to ${lefts[lefts.length - 1]} without travelling — that is a swap, not a slide`);
    // ...and it ENDED inside the pill, with the number pushed out past the right edge.
    assert(after.nameLeft >= after.pillLeft && after.nameRight <= after.pillRight + 1, "the revealed name is not inside its pill");
    assert(after.numLeft >= after.pillRight - 1, "the number is still inside the pill it was replaced on");
    // ONE name out, and it is the selected one — the whole of the placeholder rule.
    assertEqual(after.pressedNames, ["Kestrel Supply"], "more or fewer than one company's name is out");
    assertEqual(after.others, ["All", "1", "2", "3", "4", "5"], "the other buttons did not stay on their numbers");
    // AND THE COMPOSITION DID NOT MOVE. His longest name is the worst case for this.
    assertEqual(after.rowH, before.rowH, "the row got taller when a name came out — the whole composition sits on that height");
    assertEqual(after.rowRows, 1, "the row wrapped when a name came out");
    assert(after.rowW <= 500, `the row went past its cap at ${after.rowW}px`);

    await page.click('.home-chip[data-entity=""]');
    await page.waitForTimeout(400);
    const back = await page.evaluate(READ_ROW);
    assertEqual(back.rest, ["All", "1", "2", "3", "4", "5", "6"], "the name did not collapse back to its number");

    return (
      `at rest the name is parked at x=${before.nameLeft}, ${before.pillLeft - before.nameLeft}px left of a ${before.pill}px pill\n          ` +
      `on click it travels right over ${path.length} sampled frames, ${lefts[0]} -> ${lefts[lefts.length - 1]} with ${between} frame(s) strictly in between, while the pill grows ${pills[0]} -> ${pills[pills.length - 1]}px over ${before.slide}\n          ` +
      `one name out (the selected one), the other six on their numbers, row still 1 line at ${after.rowH}px and ${after.rowW}px wide`
    );
  });

  await run.check("clearing a label puts the NUMBER back — a customer's own label is the exception, not the default", async () => {
    await page.evaluate(async () => {
      await window.RichBridge.invoke("set_home_entity_label", { entityId: "kestrel", label: "WB" });
      await window.RichHome.reloadEntities();
    });
    const typed = await page.evaluate(READ_ROW);
    assertEqual(typed.rest, ["All", "1", "2", "3", "4", "5", "WB"], "a customer's own label did not replace the number on its button");
    assertEqual(typed.names[6], "Kestrel Supply", "the company's real name stopped being what the button reveals");
    await page.evaluate(async () => {
      await window.RichBridge.invoke("set_home_entity_label", { entityId: "kestrel", label: null });
      await window.RichHome.reloadEntities();
    });
    const cleared = await page.evaluate(READ_ROW);
    assertEqual(cleared.rest, ["All", "1", "2", "3", "4", "5", "6"], "clearing the override did not put the number back");
    return `typed "WB" -> All 1 2 3 4 5 WB, still revealing "Kestrel Supply"; cleared -> All 1 2 3 4 5 6`;
  });

  await run.check("with one company shown the row is ABSENT, and the composition is the round's", async () => {
    await page.evaluate(async () => {
      for (const id of ["lumen", "meridian", "harbor", "tidewater", "kestrel"]) {
        await window.RichBridge.invoke("set_home_entity_visible", { entityId: id, visible: false });
      }
      await window.RichHome.reloadEntities();
    });
    const r = await page.evaluate(() => ({
      hidden: document.getElementById("home-entities").hidden,
      chips: document.querySelectorAll(".home-chip").length,
      inset: getComputedStyle(document.getElementById("home")).getPropertyValue("--home-top-inset").trim(),
      brandTop: Math.round(document.getElementById("home-brand").getBoundingClientRect().top),
      shown: window.RichHome.state.entityCount,
    }));
    assert(r.hidden, "the row is still on screen with one company — he asked for it to be absent, not lonely");
    assertEqual(r.chips, 0, "a button is still drawn");
    assertEqual(r.inset, "0px", "the composition is still displaced by a row that is not there");
    assertEqual(r.brandTop, 30, "the mark is not back at the round's own 30px");
    // ...and back again, so this is not a one-way door either.
    await page.evaluate(async () => {
      for (const id of ["lumen", "meridian", "harbor", "tidewater", "kestrel"]) {
        await window.RichBridge.invoke("set_home_entity_visible", { entityId: id, visible: true });
      }
      await window.RichHome.reloadEntities();
    });
    const back = await page.evaluate(READ_ROW);
    assertEqual(back.rest.length, 7, "un-hiding did not bring the row back");
    // AND THE NUMBERING FOLLOWS WHAT IS SHOWN, not the registry. Hide the middle two and the
    // rest close up rather than leaving gaps where they were.
    await page.evaluate(async () => {
      for (const id of ["meridian", "harbor"]) await window.RichBridge.invoke("set_home_entity_visible", { entityId: id, visible: false });
      await window.RichHome.reloadEntities();
    });
    const gapped = await page.evaluate(READ_ROW);
    assertEqual(gapped.rest, ["All", "1", "2", "3", "4"], "the numbering left holes where the hidden companies were");
    assertEqual(gapped.names.slice(1), ["Northwind Traders", "Lumen Labs", "Tidewater Films", "Kestrel Supply"], "the row is not the shown companies in registry order");
    await page.evaluate(async () => {
      for (const id of ["meridian", "harbor"]) await window.RichBridge.invoke("set_home_entity_visible", { entityId: id, visible: true });
      await window.RichHome.reloadEntities();
    });
    return `1 company shown -> row absent, inset 0px, mark back at y=30; 6 shown -> All 1..6 again; 4 shown -> All 1 2 3 4 with no holes`;
  });

  // -------------------------------------------------------------------------------------
  // The first-run banner
  //
  //   "On first launch, the home screen draws synthetic data, yes. Show a small banner in the
  //    top right corner saying something like: 'This is what your home screen could look like
  //    once Rich gets enough information about you and your business.'" (CEO, 2026-09-01)
  // -------------------------------------------------------------------------------------

  await run.check("THE FIRST-RUN BANNER: his sentence, top right, while the picture is synthetic", async () => {
    const r = await page.evaluate(() => {
      const box = document.getElementById("home-note");
      const line = document.getElementById("home-note-line");
      const cs = getComputedStyle(line);
      const bcs = getComputedStyle(box);
      const rect = (e) => {
        const b = e.getBoundingClientRect();
        return { l: Math.round(b.left), t: Math.round(b.top), r: Math.round(b.right), b: Math.round(b.bottom) };
      };
      return {
        present: !!box && !box.hidden,
        text: line.textContent,
        source: window.RichHome.NOTE,
        px: Math.round(parseFloat(cs.fontSize)),
        family: cs.fontFamily,
        border: bcs.borderTopWidth + "/" + bcs.borderRightWidth + "/" + bcs.borderBottomWidth + "/" + bcs.borderLeftWidth,
        role: box.getAttribute("role"),
        dataSource: window.RichHome.state.dataSource,
        noteShown: window.RichHome.state.noteShown,
        dataIsCustomers: window.RichHome.state.dataIsCustomers,
        // What the picture is really drawing, read off the object the engine reads.
        metaName: window.MATURE_LORO.meta.name,
        metaSynthetic: window.MATURE_LORO.meta.synthetic,
        note: rect(box),
        text_: rect(line),
        live: rect(document.getElementById("home-live")),
        setbtn: rect(document.querySelector(".setbtn")),
        row: rect(document.getElementById("home-entities")),
        vw: innerWidth,
        vh: innerHeight,
      };
    });

    assert(r.present, "the banner is not on the screen while the picture is synthetic");
    // The rendered string is asserted against the SOURCE of the string, never against a copy
    // typed in here — a test that carries its own copy passes after somebody edits one of them.
    assertEqual(r.text, r.source, "the rendered sentence is not the one home.js holds");
    assert(/^This is what your home screen could look like once Rich knows enough about you and your business\.$/.test(r.text),
      "the sentence has drifted from the CEO's: " + JSON.stringify(r.text));

    // It is the DATA that is being reported on, and the data says what it is.
    assertEqual(r.metaSynthetic, true, "the dataset under this run is not the synthetic one");
    assertEqual(r.dataSource, "synthetic", "the banner's condition was not derived from the dataset");
    assertEqual(r.dataIsCustomers, false, "the screen thinks this synthetic picture is the customer's");
    assertEqual(r.noteShown, true, "state and DOM disagree about whether the banner is up");

    // §15: this sentence is meant to be read, so it takes the 16px reading floor and NOT the
    // 14px skippable tier. No exemption is claimed for it anywhere.
    assertEqual(r.px, 16, "the banner is not at §15's 16px reading floor");
    // §22: vendored faces only.
    assert(/^"?Newsreader"?,\s*serif$/.test(r.family.trim()), "the banner names a face that is not vendored: " + r.family);
    // There is no non-text indicator on this element — see home.css. If a border ever appears
    // it owes 3:1 and nothing measures it, so the absence is asserted rather than assumed.
    assertEqual(r.border, "0px/0px/0px/0px", "the banner grew a border, which owes 3:1 and is measured by nothing");
    assertEqual(r.role, "status", "the banner is not a status");

    // TOP RIGHT, and clear of everything already in that corner.
    assert(r.text_.r === r.vw - 34, `the sentence is not on the composition's 34px right margin (right edge ${r.text_.r} of ${r.vw})`);
    assert(r.note.t > r.setbtn.b, `the banner overlaps the settings button (banner top ${r.note.t}, button bottom ${r.setbtn.b})`);
    assert(r.note.t >= r.row.b, `the banner overlaps the entity row (banner top ${r.note.t}, row bottom ${r.row.b})`);
    assert(r.note.b < r.live.t, `the banner crowds the "Working now" aside (banner bottom ${r.note.b}, aside top ${r.live.t})`);
    assert(r.note.b < r.vh / 2, `the banner is not in the top half of the window (bottom ${r.note.b} of ${r.vh})`);

    return (
      `"${r.text}"\n          ` +
      `16px Newsreader, no border, role=status; dataset "${r.metaName}" synthetic=${r.metaSynthetic} -> dataSource "${r.dataSource}"\n          ` +
      `banner box y=[${r.note.t},${r.note.b}] x=[${r.note.l},${r.note.r}]; text right edge ${r.text_.r} = ${r.vw}-34; ` +
      `settings button ends y=${r.setbtn.b}, entity row ends y=${r.row.b}, aside starts y=${r.live.t}`
    );
  });

  await run.check("THE CONDITION, BOTH WAYS: the banner goes when the data is the customer's", async () => {
    // WHAT THIS CAN AND CANNOT DRIVE, said plainly.
    //
    // Nothing in the product can produce a customer's own loro in the shape the field reads —
    // there is no `home_field_data` command, and `home/field-data.js` is the only dataset that
    // exists. So the real-data side is exercised the only honest way there is: by handing the
    // condition the input a real compile would produce, `meta.synthetic === false`, on the very
    // object `home/field-engine.js:99` reads, and driving the same `refreshNote()` the field's
    // own settle calls. What is NOT covered by this, and is stated in the handoff rather than
    // implied away: that a real compiler, when one exists, actually stamps that field.
    const before = await page.evaluate(() => {
      const b = document.getElementById("home-live").getBoundingClientRect();
      return {
        liveTop: Math.round(b.top),
        inset: getComputedStyle(document.getElementById("home")).getPropertyValue("--home-note-inset").trim(),
      };
    });

    const real = await page.evaluate(() => {
      window.MATURE_LORO.meta.synthetic = false;
      window.RichHome.refreshNote();
      const box = document.getElementById("home-note");
      const b = document.getElementById("home-live").getBoundingClientRect();
      return {
        hidden: box.hidden,
        displayed: getComputedStyle(box).display,
        state: window.RichHome.state.dataSource,
        isCustomers: window.RichHome.state.dataIsCustomers,
        noteShown: window.RichHome.state.noteShown,
        liveTop: Math.round(b.top),
        inset: getComputedStyle(document.getElementById("home")).getPropertyValue("--home-note-inset").trim(),
      };
    });
    assert(real.hidden, "the banner is still up over a dataset that says it is the customer's");
    assertEqual(real.displayed, "none", "the banner is hidden but still taking space");
    assertEqual(real.state, "customer", "the condition did not re-derive from the dataset");
    assert(real.isCustomers && !real.noteShown, "state did not follow the DOM");
    assertEqual(real.inset, "0px", "the reservation was not released");
    // The composition has to be EXACTLY the one the CEO approved once the banner is gone.
    assertEqual(real.liveTop, before.liveTop - parseInt(before.inset, 10),
      "the aside did not return to the line it sits on without the banner");

    // THE NEGATIVE CONTROLS — positive signal only. Neither of these is evidence.
    const unknown = await page.evaluate(() => {
      const out = {};
      delete window.MATURE_LORO.meta.synthetic; // a dataset that simply does not say
      window.RichHome.refreshNote();
      out.omitted = { shown: window.RichHome.state.noteShown, src: window.RichHome.state.dataSource };
      const meta = window.MATURE_LORO.meta;
      delete window.MATURE_LORO.meta; // no dataset metadata at all
      window.RichHome.refreshNote();
      out.nometa = { shown: window.RichHome.state.noteShown, src: window.RichHome.state.dataSource };
      window.MATURE_LORO.meta = meta;
      window.MATURE_LORO.meta.synthetic = true; // back to the truth
      window.RichHome.refreshNote();
      out.restored = { shown: window.RichHome.state.noteShown, src: window.RichHome.state.dataSource };
      return out;
    });
    assert(unknown.omitted.shown && unknown.omitted.src === "unknown",
      "a dataset that does not say was read as the customer's — absence of evidence became evidence");
    assert(unknown.nometa.shown && unknown.nometa.src === "unknown",
      "no dataset at all was read as the customer's");
    assert(unknown.restored.shown && unknown.restored.src === "synthetic", "the fixture did not restore");

    const after = await page.evaluate(() => Math.round(document.getElementById("home-live").getBoundingClientRect().top));
    assertEqual(after, before.liveTop, "the aside did not come back to where it was");

    return (
      `synthetic=true -> banner up, --home-note-inset ${before.inset}, aside at y=${before.liveTop}\n          ` +
      `synthetic=false -> banner display:none, inset 0px, aside back at y=${real.liveTop} (the approved composition)\n          ` +
      `omitted -> up ("unknown"); no meta at all -> up ("unknown"). Only an explicit false takes it down.`
    );
  });

  // -------------------------------------------------------------------------------------
  // Contrast — from the pixels, on the rendered frame
  // -------------------------------------------------------------------------------------

  await run.check("CONTRAST: every line of the home screen, measured on the rendered frame", async () => {
    await page.waitForTimeout(400);
    const rows = await measure(page, [
      { name: "the mark, letterforms", sel: "#home-brand .p-ink", needs: 3, kind: "svg" },
      { name: "the mark, swoosh", sel: "#home-brand .p-signal", needs: 3, kind: "svg" },
      { name: "owner line", sel: "#home-owner", needs: 4.5 },
      { name: "sub line", sel: "#home-brand-line", needs: 4.5 },
      { name: "signal number", sel: "#home-signals .sig .n .v", needs: 3 },
      { name: "signal label", sel: "#home-signals .sig .l", needs: 4.5 },
      { name: "Working now", sel: "#home-live .cap", needs: 4.5 },
      { name: "workforce name", sel: "#home-live li", needs: 4.5 },
      // Stepped out past its own 7px glow, or the indicator would be measured against itself.
      { name: "the live dot", sel: "#home-live li .dot", needs: 3, kind: "paint", ringGap: 9, ringWidth: 4 },
      // The label is in a span now — a chip carries two of them and the button itself has no
      // text node, so measuring the button would measure its box and not its glyphs.
      { name: "a numbered button", sel: '.home-chip[data-entity="northwind"] .home-chip-rest', needs: 4.5 },
      { name: "a numbered button's edge", sel: '.home-chip[data-entity="northwind"]', needs: 3, kind: "edge" },
      { name: '"All", selected', sel: '.home-chip[data-entity=""] .home-chip-rest', needs: 4.5 },
      // The selected chip's indicator is its FILL — its border is struck in the same tone, so
      // an `edge` measurement would be the fill against itself. What it owes 3:1 to is what
      // surrounds it.
      { name: "chip, selected fill", sel: '.home-chip[data-entity=""]', needs: 3, kind: "paint" },
      { name: "the door's label", sel: "#home-enter .home-enter-label", needs: 4.5 },
      // `padX` steps the inward half of this measurement past the breathing dot — see
      // `interior()`. Without it the door's border is measured against the dot, which is a
      // different indicator with its own floor, on the line below.
      { name: "the door's edge", sel: "#home-enter", needs: 3, kind: "edge", padX: 24 },
      // The breathing dot at the DIMMEST point of its cycle, which is what `opacity` reports
      // while the animation is held at zero by the meter's own transition-killing sheet.
      { name: "the door's dot", sel: "#home-enter .dot", needs: 3, kind: "paint", ringGap: 3, ringWidth: 3 },
      { name: '"Enter" under the door', sel: "#home-door-cap", needs: 4.5 },
      // The first-run banner. `needs: 4.5` — it is normal text meant to be read, and no
      // exemption is claimed for it. Its plate has NO border, so there is no `edge` target
      // here; the plate's own boundary is measured and reported in the check below.
      { name: "the first-run banner", sel: "#home-note-line", needs: 4.5 },
    ]);
    const bad = failures(rows);
    assertEqual(bad.length, 0, "these are under the floor:\n" + reportRatios(bad));
    return reportRatios(rows) + `\n          worst on the screen: ${Math.min.apply(null, rows.map((r) => r.ratio))}:1`;
  });

  await run.check("CONTRAST, BOTH THEMES: the three new things, with the CEO's own choice set to light", async () => {
    // "BOTH THEMES" ON THIS SURFACE IS A CLAIM THAT NEEDS PROVING RATHER THAN ASSUMING, and
    // the honest answer is not "it was checked twice" — it is that there is only one lighting
    // here BY RULING. §15's one permanent exception: *"Because of its nature the start screen
    // will always need to be in dark mode."* The clamp is a FORCE flag over the CEO's own
    // preference, not a write to it, so the case that matters is a CEO who has CHOSEN light.
    //
    // So this drives that case and MEASURES the result, rather than asserting the attribute and
    // stopping. If the clamp ever leaked, these numbers would move and this check would say so
    // in the same breath as the ones above.
    const targets = [
      { name: "the first-run banner", sel: "#home-note-line", needs: 4.5 },
      { name: "the door's label", sel: "#home-enter .home-enter-label", needs: 4.5 },
      { name: "the door's edge", sel: "#home-enter", needs: 3, kind: "edge", padX: 24 },
      { name: '"Enter" under the door', sel: "#home-door-cap", needs: 4.5 },
      { name: "a numbered button", sel: '.home-chip[data-entity="northwind"] .home-chip-rest', needs: 4.5 },
      { name: "a numbered button's edge", sel: '.home-chip[data-entity="northwind"]', needs: 3, kind: "edge" },
    ];
    const seen = {};
    for (const theme of ["dark", "light"]) {
      await page.evaluate((t) => window.RichTheme.setTheme(t), theme);
      await page.waitForTimeout(400);
      const state = await page.evaluate(() => ({
        pref: window.RichTheme.theme(),
        rendered: document.documentElement.getAttribute("data-theme"),
        forced: window.RichTheme.forcedDark(),
      }));
      assertEqual(state.pref, theme, "the CEO's own preference was not set to " + theme);
      assertEqual(state.rendered, "dark", "§15's clamp let " + theme + " mode reach the home screen");
      assert(state.forced, "the always-dark clamp is not raised while the preference is " + theme);
      const rows = await measure(page, targets);
      const bad = failures(rows);
      assertEqual(bad.length, 0, "under the floor with the preference set to " + theme + ":\n" + reportRatios(bad));
      seen[theme] = rows.map((r) => r.name + " " + r.ratio + ":1");
    }
    await page.evaluate(() => window.RichTheme.setTheme("dark"));
    // The two runs must agree, because there is one lighting. A drift here IS the leak.
    assertEqual(seen.light, seen.dark, "the same elements measured differently under the two preferences — the clamp is leaking");
    return (
      "preference dark and preference light both render dark, and measure identically:\n          " +
      seen.dark.join("\n          ")
    );
  });

  await run.check("TYPE SCALE §15: nothing readable on the home screen is below 14px", async () => {
    const r = await page.evaluate(() => {
      const out = [];
      const walk = (el) => {
        for (const n of el.childNodes) {
          if (n.nodeType === 3 && n.textContent.trim()) {
            const cs = getComputedStyle(el);
            // The visually-hidden grouping label is for assistive technology and has no
            // rendered size to hold to a floor.
            const r = el.getBoundingClientRect();
            if (r.width > 2 && r.height > 2) out.push({ px: Math.round(parseFloat(cs.fontSize)), text: n.textContent.trim().slice(0, 28) });
            break;
          }
        }
        for (const c of el.children) walk(c);
      };
      walk(document.getElementById("home"));
      return out;
    });
    const under = r.filter((x) => x.px < 14);
    assertEqual(under.length, 0, "below the floor: " + JSON.stringify(under));
    const sizes = Array.from(new Set(r.map((x) => x.px))).sort((a, b) => a - b);
    // A numeral a CEO is meant to aim at is not fine print — the discs take §15's 16px reading
    // floor, exactly as the names they hide do.
    const disc = r.find((x) => x.text === "1");
    const name = r.find((x) => x.text === "Northwind Traders");
    assertEqual(disc && disc.px, 16, "the numbered buttons are not at §15's 16px reading floor");
    assertEqual(name && name.px, 16, "the names behind them are not at 16px either");
    return `${r.length} rendered strings, sizes ${sizes.join("/")}px, smallest ${sizes[0]}px; the company buttons are 16px, numbered and named alike`;
  });

  await run.check("§22: no system font is named, and every string resolves to a vendored face", async () => {
    const r = await page.evaluate(async () => {
      await document.fonts.ready;
      const faces = Array.from(document.fonts).map((f) => f.family + "/" + f.style + "/" + f.weight + "=" + f.status);
      const stacks = new Set();
      const walk = (el) => {
        const cs = getComputedStyle(el);
        if (el.getBoundingClientRect().width > 2) stacks.add(cs.fontFamily);
        for (const c of el.children) walk(c);
      };
      walk(document.getElementById("home"));
      return { faces, stacks: Array.from(stacks) };
    });
    // The only families this surface may name are the vendored ones; a stack may list more
    // than one of them — `#home-live .ticker` names Newsreader and then Inter, because the
    // engine writes a `\u2192` into it that Newsreader does not carry — and whatever comes
    // last must be a GENERIC keyword, never a platform face. Split and check every entry
    // rather than pattern-matching the whole stack: a regex over the join was already wrong
    // for two families and would be wrong again for three.
    const VENDORED = new Set(["Newsreader", "Inter", "RichOS Symbols"]);
    const GENERIC = new Set(["serif", "sans-serif", "monospace", "system-ui"]);
    const named = (stack) => stack.split(",").map((f) => f.trim().replace(/^["']|["']$/g, ""));
    const bad = r.stacks.filter((s) => named(s).some((f) => !VENDORED.has(f) && !GENERIC.has(f)));
    assertEqual(bad, [], "these stacks name something that is not a vendored face or a generic keyword");
    const loaded = r.faces.filter((f) => f.endsWith("=loaded"));
    assert(loaded.length >= 2, "the vendored faces did not load: " + JSON.stringify(r.faces));
    return `${r.stacks.length} distinct stacks, all vendored: ${r.stacks.join(" | ")}; faces ${r.faces.join(", ")}`;
  });

  await run.check("§22: every non-ASCII character on this screen is drawn by a vendored face", async () => {
    // THE HALF OF THE RULING A STYLESHEET AUDIT CANNOT SEE. A browser that cannot find a
    // character in the named family does not fail — it silently walks to the next family, and
    // the next family here is a generic keyword, which is the machine's own font. That is §22
    // broken in a way nothing in the CSS shows: `fonts/fonts.css` had to vendor three Noto
    // subsets for exactly seven characters the interface was drawing out of Unicode.
    //
    // So every non-ASCII character this surface RENDERS is collected off the live DOM and
    // asked of the face that is actually set on it, two ways — `FontFaceSet.check`, and an
    // advance-width probe against a family that certainly does not exist. Either one alone can
    // be fooled; both agreeing is what makes this a measurement.
    const r = await page.evaluate(async () => {
      await document.fonts.ready;
      const found = new Map(); // char -> the family stack it is set in
      const walk = (el) => {
        const cs = getComputedStyle(el);
        for (const n of el.childNodes) {
          if (n.nodeType !== 3) continue;
          for (const ch of n.textContent) {
            if (ch.codePointAt(0) > 127 && !found.has(ch)) found.set(ch, cs.fontFamily);
          }
        }
        for (const c of el.children) walk(c);
      };
      walk(document.getElementById("home"));

      const c = document.createElement("canvas").getContext("2d");
      const probe = (family, ch) => {
        c.font = '16px ' + family;
        return c.measureText(ch).width;
      };
      const GENERIC = new Set(["serif", "sans-serif", "monospace", "system-ui", "cursive", "fantasy"]);
      const fallbackWidth = Math.round(probe('"__a_face_that_does_not_exist__"', "x") * 100) / 100;
      const out = [];
      for (const [ch, stack] of found) {
        // EVERY NAMED FAMILY AHEAD OF THE FIRST GENERIC KEYWORD gets asked, not just the first
        // one. That is what the cascade really does: the browser walks the stack and stops at
        // the first family that has the character, and only reaches the generic — the machine's
        // own font, which is what this check exists to catch — if none of them did.
        //
        // It used to ask the first family alone, which was right while every stack on this
        // screen named exactly one. `#home-live .ticker` now names two, because the engine
        // writes an arrow into it that Newsreader does not carry and Inter does, so the old
        // form reported a pass as a failure.
        const families = [];
        for (const raw of stack.split(",")) {
          const f = raw.trim().replace(/^["']|["']$/g, "");
          if (GENERIC.has(f)) break;
          families.push(f);
        }
        const asked = families.map((f) => {
          const w = Math.round(probe('"' + f + '"', ch) * 100) / 100;
          return { f, declared: document.fonts.check('16px "' + f + '"', ch), w, has: w !== Math.round(probe('"__a_face_that_does_not_exist__"', ch) * 100) / 100 };
        });
        const drawn = asked.find((a) => a.declared && a.has);
        out.push({
          ch,
          code: "U+" + ch.codePointAt(0).toString(16).toUpperCase().padStart(4, "0"),
          family: drawn ? drawn.f : families.join(" -> "),
          declared: !!drawn,
          width: drawn ? drawn.w : 0,
          fallbackWidth: Math.round(probe('"__a_face_that_does_not_exist__"', ch) * 100) / 100,
          covered: !!drawn,
        });
      }
      return out;
    });
    const uncovered = r.filter((g) => !g.covered);
    assertEqual(
      uncovered.map((g) => g.code + " " + g.ch + " in " + g.family),
      [],
      "these characters are in NONE of the vendored faces they are set in, so a system font is drawing them"
    );
    assert(r.length > 0, "POSITIVE CONTROL: no non-ASCII character was found at all, so this check proved nothing");
    return r.map((g) => `${g.code} ${g.ch} in ${g.family} (${g.width}px vs ${g.fallbackWidth}px fallback)`).join(", ");
  });

  // -------------------------------------------------------------------------------------
  // The switch, and the way back
  // -------------------------------------------------------------------------------------

  await run.check("the switch takes him to the app UI, and the picture stops", async () => {
    await shot(page, "home-named", { fullPage: false });
    publishShotFile(path.join(SHOT_DIR, "home-named.png"), path.join(SHOTS, "home-named.png"));
    const framesAt = await page.evaluate(() => window.__loro.frames);
    await page.click("#home-enter");
    await page.waitForFunction(() => document.getElementById("home").hidden);
    await page.waitForTimeout(1200);
    const r = await page.evaluate(() => ({
      open: window.RichHome.state.open,
      appInert: document.getElementById("app").hasAttribute("inert"),
      bodyClass: document.body.classList.contains("home-open"),
      running: window.__loro.running,
      frames: window.__loro.frames,
      focus: document.activeElement ? document.activeElement.id : null,
      forced: window.RichTheme.forcedDark(),
      composerReachable: !!document.getElementById("input") && !document.getElementById("input").disabled,
    }));
    assert(!r.open && !r.appInert && !r.bodyClass, "the app UI is not the surface in front");
    assert(!r.running, "the picture is still running behind an opaque conversation view");
    assert(r.frames - framesAt < 30, `the loop ran on for ${r.frames - framesAt} frames after the switch`);
    assertEqual(r.focus, "input", "focus did not follow the surface to the composer");
    assert(!r.forced, "the always-dark clamp is still up in the app UI");
    await shot(page, "home-app-ui", { fullPage: false });
    publishShotFile(path.join(SHOT_DIR, "home-app-ui.png"), path.join(SHOTS, "home-app-ui.png"));
    await page.waitForTimeout(1500);
    const later = await page.evaluate(() => window.__loro.frames);
    assertEqual(later, r.frames, "the frame loop is still running while the CEO is in the app UI");
    return `switched; #app live, focus on the composer, clamp dropped, frames stopped at ${r.frames} and still ${later} 1.5s later`;
  });

  await run.check("clicking the logo in the corner brings him back, and NOTHING is rebuilt", async () => {
    const before = await page.evaluate(() => ({
      frames: window.__loro.frames,
      N: window.__loro.N,
      role: document.getElementById("rail-wordmark").getAttribute("role"),
      label: document.getElementById("rail-wordmark").getAttribute("aria-label"),
      tabindex: document.getElementById("rail-wordmark").getAttribute("tabindex"),
    }));
    assertEqual(before.role, "button", "the wordmark is not a control");
    assert(/home screen/i.test(before.label || ""), "the wordmark does not say where it goes: " + before.label);
    assertEqual(before.tabindex, "0", "the wordmark cannot be reached from the keyboard");
    const t0 = Date.now();
    await page.click("#rail-wordmark");
    await page.waitForFunction("window.__loro.running === true");
    const resumeMs = Date.now() - t0;
    await page.waitForTimeout(900);
    const r = await page.evaluate(() => ({
      open: window.RichHome.state.open,
      hidden: document.getElementById("home").hidden,
      appInert: document.getElementById("app").hasAttribute("inert"),
      frames: window.__loro.frames,
      N: window.__loro.N,
      forced: window.RichTheme.forcedDark(),
      focus: document.activeElement ? document.activeElement.id : null,
      field: window.RichHome.state.field,
    }));
    assert(r.open && !r.hidden && r.appInert, "the logo did not bring the home screen back");
    assert(r.frames > before.frames, "the picture is not running again");
    assertEqual(r.N, before.N, "the field was rebuilt rather than resumed");
    assertEqual(r.field, "live", "the picture went back through its loading state");
    assert(r.forced, "the always-dark clamp did not come back with the screen");
    assertEqual(r.focus, "home-enter", "focus did not follow the surface back");
    await shot(page, "home-returned", { fullPage: false });
    publishShotFile(path.join(SHOT_DIR, "home-returned.png"), path.join(SHOTS, "home-returned.png"));
    return `back in ${resumeMs}ms, frames ${before.frames} -> ${r.frames}, still ${r.N} objects, no reload, clamp back up`;
  });

  await run.check("the keyboard reaches both directions", async () => {
    await page.keyboard.press("Enter"); // focus is on the switch
    await page.waitForFunction(() => document.getElementById("home").hidden);
    await page.evaluate(() => document.getElementById("rail-wordmark").focus());
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => !document.getElementById("home").hidden);
    const open = await page.evaluate(() => window.RichHome.state.open);
    assert(open, "Enter on the focused wordmark did not come home");
    return "Enter on the switch leaves; Enter on the focused wordmark returns";
  });

  await run.check("THE DOOR is round-11.2/v1's sill, in the LEFT COLUMN, off the picture", async () => {
    // Ruled by the owner, 2026-09-02: nothing may cover the spectacle of the home screen, so
    // the `round-11.2/v1` button sits in the LEFT COLUMN under "your attention saved", with the
    // label "Talk to Rich". Wording in the private record (`wiki/ceo-decisions.md`).
    const r = await page.evaluate(() => {
      const box = document.getElementById("home-switch");
      const b = document.getElementById("home-enter");
      const cap = document.getElementById("home-door-cap");
      const sig = document.getElementById("home-signals");
      const brand = document.getElementById("home-brand");
      const last = sig.querySelector(".sig:last-child .l");
      const R = (e) => {
        const x = e.getBoundingClientRect();
        return { l: Math.round(x.left), t: Math.round(x.top), r: Math.round(x.right), b: Math.round(x.bottom), w: Math.round(x.width), h: Math.round(x.height) };
      };
      const bs = getComputedStyle(b);
      const cs = getComputedStyle(cap);
      return {
        box: R(box),
        sill: R(b),
        cap: R(cap),
        sig: R(sig),
        brand: R(brand),
        lastSignal: last ? last.textContent.trim() : null,
        lastSignalRect: last ? R(last) : null,
        label: b.querySelector(".home-enter-label").textContent,
        capText: cap.textContent,
        arrow: !!b.querySelector("svg, .home-enter-arrow"),
        h: bs.height,
        radius: bs.borderTopLeftRadius,
        px: Math.round(parseFloat(bs.fontSize)),
        color: bs.color,
        capPx: Math.round(parseFloat(cs.fontSize)),
        capColor: cs.color,
        gap: getComputedStyle(box).rowGap,
        keys: b.getAttribute("aria-keyshortcuts"),
        vw: innerWidth,
        vh: innerHeight,
      };
    });

    assertEqual(r.label, "Talk to Rich", "the door does not carry his label");
    assert(!r.arrow, "the arrow is still there — his ruling names the label and nothing else");
    assertEqual(r.capText, "Enter", "the word under the button is not `Enter`");
    // round-11.2/v1's `.sill` and `#door .cap`, carried.
    assertEqual(r.h, "52px", "the capsule is not the sill's 52px");
    assertEqual(r.radius, "26px", "the capsule is not the sill's 26px radius");
    assertEqual(r.px, 17, "the label is not the sill's 17px");
    assertEqual(r.color, "rgb(234, 238, 246)", "the label is not the sill's #EAEEF6");
    assertEqual(r.capPx, 14, "the caption is not the mockup's 14px");
    assertEqual(r.capColor, "rgb(166, 179, 203)", "the caption is not the mockup's #A6B3CB");
    assertEqual(r.gap, "15px", "the block's gap is not the mockup's 15px");
    assertEqual(r.keys, "Enter", "the caption's claim is not in the accessibility tree");

    // THE LEFT COLUMN, under the last signal. Not centered, not at the foot of the screen.
    assertEqual(r.lastSignal, "of your attention saved", "the last signal is not the line he named");
    assert(r.sill.l === r.sig.l && r.sill.l === r.brand.l, `the sill is not on the left column's line (sill ${r.sill.l}, signals ${r.sig.l}, mark ${r.brand.l})`);
    assert(r.sill.t > r.lastSignalRect.b, `the sill is not under "of your attention saved" (sill top ${r.sill.t}, that line ends at ${r.lastSignalRect.b})`);
    const mid = r.box.l + r.box.w / 2;
    assert(mid < r.vw * 0.25, `the door is still near the middle of the window (its midpoint is at ${Math.round(mid)} of ${r.vw})`);
    assert(r.box.b < r.vh - 60, "the door is at the foot of the screen rather than in the column");

    // NOTHING CAN COVER THE SPECTACLE. The measurable form of that: the whole block stays
    // inside the width the left column already occupies, so it takes no picture the
    // composition was not already taking.
    const columnRight = Math.max(r.sig.r, r.brand.r);
    assert(r.box.r <= columnRight, `the door reaches ${r.box.r - columnRight}px further into the picture than the column it sits in`);

    // ...and the provisional pill at the foot of the screen is gone rather than hidden.
    const stale = await page.evaluate(() => document.querySelectorAll("#home-switch").length);
    assertEqual(stale, 1, "there is more than one door on the screen");

    return (
      `"${r.label}" in a ${r.sill.w}x${r.sill.h} capsule at radius ${r.radius}, ${r.px}px ${r.color}, with "${r.capText}" ${r.capPx}px ${r.capColor} ${r.gap} under it\n          ` +
      `left column: mark at x=${r.brand.l}, signals at x=${r.sig.l}, sill at x=${r.sill.l}; "of your attention saved" ends at y=${r.lastSignalRect.b}, the sill starts at y=${r.sill.t}\n          ` +
      `the block ends at x=${r.box.r}, inside the column's own ${columnRight}; its midpoint is at x=${Math.round(mid)} of a ${r.vw}px window`
    );
  });

  await run.check('the word "Enter" is a promise the key keeps, from anywhere on the screen', async () => {
    // The caption is not decoration: *"So, the user can either click the button or hit the
    // Enter key on their keyboard."* The button already answered Enter WHEN IT HAD FOCUS, which
    // is not what the caption says.
    assert(await page.evaluate(() => window.RichHome.isOpen()), "the home screen is not up to start with");
    // Focus deliberately NOT on the door — the case the older arrangement did not cover.
    await page.evaluate(() => {
      const b = document.getElementById("home-enter");
      if (b && b.blur) b.blur();
      document.body.focus && document.body.focus();
    });
    const focused = await page.evaluate(() => (document.activeElement && document.activeElement.id) || document.activeElement.tagName);
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.getElementById("home").hidden, { timeout: 4000 });
    const why = await page.evaluate(() => window.RichHome.state.lastLeaveReason);
    assertEqual(why, "enter-key", "the home screen left for some other reason than the key");

    // AND IT DOES NOT FIRE WHERE ENTER ALREADY MEANS SOMETHING. Back home, open the panel, and
    // press Enter inside it: the screen must stay.
    await page.evaluate(() => window.RichHome.show("suite"));
    await page.waitForFunction(() => !document.getElementById("home").hidden);
    await page.evaluate(() => window.RichHome.openSettings());
    await page.waitForFunction(() => document.querySelectorAll(".home-prefs-row").length > 0);
    await page.focus('.home-prefs-label[data-entity="northwind"]');
    await page.keyboard.press("Enter");
    await page.waitForTimeout(150);
    const stillHome = await page.evaluate(() => window.RichHome.isOpen());
    await page.evaluate(() => window.RichHome.closeSettings());
    assert(stillHome, "Enter inside the company-buttons panel walked out of the home screen");

    // ...and it still works from the door itself, which is where focus lands on arrival.
    await page.evaluate(() => document.getElementById("home-enter").focus());
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.getElementById("home").hidden, { timeout: 4000 });
    const why2 = await page.evaluate(() => window.RichHome.state.lastLeaveReason);
    await page.evaluate(() => window.RichHome.show("suite"));
    await page.waitForFunction(() => !document.getElementById("home").hidden);

    return `Enter with focus on <${focused}> leaves ("${why}"); Enter inside the settings panel does not; Enter on the door itself leaves ("${why2}")`;
  });

  // -------------------------------------------------------------------------------------
  // The settings panel — both themes
  // -------------------------------------------------------------------------------------

  for (const theme of ["dark", "light"]) {
    await run.check(`CONTRAST: the company-button settings, ${theme} mode, measured on the rendered frame`, async () => {
      // The panel is reached from the APP UI here, because that is where the CEO can be in
      // light mode — on the home screen §15's clamp makes light mode unreachable by design.
      await page.evaluate((t) => {
        if (window.RichHome.isOpen()) window.RichHome.hide("suite");
        window.RichTheme.setTheme(t);
      }, theme);
      await page.waitForFunction(() => document.getElementById("home").hidden);
      await page.evaluate(() => window.RichHome.openSettings());
      await page.waitForFunction(() => document.querySelectorAll(".home-prefs-row").length > 0);
      const shape = await page.evaluate(() => ({
        rows: document.querySelectorAll(".home-prefs-row").length,
        names: Array.from(document.querySelectorAll(".home-prefs-name")).map((n) => n.textContent),
        placeholders: Array.from(document.querySelectorAll(".home-prefs-label")).map((i) => i.placeholder),
        values: Array.from(document.querySelectorAll(".home-prefs-label")).map((i) => i.value),
        foot: document.getElementById("home-prefs-foot").textContent,
        theme: document.documentElement.getAttribute("data-theme"),
      }));
      assertEqual(shape.theme, theme, "the panel is not rendering in the theme under test");
      assertEqual(shape.rows, 6, "the panel does not list every company — a hidden one could never come back");
      assertEqual(shape.names, REGISTRY.map((e) => e[1]), "the panel is not listing the registry");
      // THE PLACEHOLDER IS THE NUMBER NOW, because an empty field means the button shows its
      // number. It said the company's name until 2026-09-02, and that would be the panel
      // describing a default the product no longer has.
      assertEqual(shape.placeholders, ["1", "2", "3", "4", "5", "6"], "an empty field does not show the number the button will carry");
      assertEqual(shape.values, ["", "", "", "", "", ""], "a field is pre-filled — clearing it would then be indistinguishable from leaving it");
      // An `<input>` has no text node, so its ink is measured over its own interior — that is
      // the surface a typed label sits on, and it is the region a value would occupy.
      const all = await measure(page, [
        { name: "panel heading", sel: ".home-prefs-title", needs: 3 },
        { name: "panel note", sel: ".home-prefs-note", needs: 4.5 },
        { name: "a company name", sel: ".home-prefs-name", needs: 4.5 },
        { name: "the label field's ink", sel: ".home-prefs-label", needs: 4.5, kind: "fill" },
        { name: "the label field's edge", sel: ".home-prefs-label", needs: 3, kind: "edge" },
        { name: '"Show"', sel: ".home-prefs-show span", needs: 4.5 },
        { name: "the count line", sel: ".home-prefs-foot", needs: 4.5 },
        { name: "Done", sel: ".home-prefs-done", needs: 4.5 },
      ]);
      const bad = failures(all);
      assertEqual(bad.length, 0, "under the floor in " + theme + ":\n" + reportRatios(bad));
      await shot(page, "home-settings-" + theme, { fullPage: false });
      publishShotFile(path.join(SHOT_DIR, "home-settings-" + theme + ".png"), path.join(SHOTS, "home-settings-" + theme + ".png"));
      await page.evaluate(() => window.RichHome.closeSettings());
      return reportRatios(all) + `\n          ${shape.foot}`;
    });
  }

  await run.check("the settings write through: a label typed there reaches the home screen", async () => {
    await page.evaluate(() => window.RichTheme.setTheme("dark"));
    await page.evaluate(() => window.RichHome.openSettings());
    await page.waitForFunction(() => document.querySelectorAll(".home-prefs-row").length > 0);
    await page.fill('.home-prefs-label[data-entity="kestrel"]', "WB");
    await page.evaluate(() => document.querySelector('.home-prefs-label[data-entity="kestrel"]').blur());
    await page.waitForFunction(() => Array.from(document.querySelectorAll(".home-chip-rest")).some((c) => c.textContent === "WB"));
    await page.uncheck('.home-prefs-show input[data-entity="tidewater"]');
    await page.waitForFunction(() => !Array.from(document.querySelectorAll(".home-chip-name")).some((c) => c.textContent === "Tidewater Films"));
    const r = await page.evaluate(() => ({
      labels: Array.from(document.querySelectorAll(".home-chip-rest")).map((c) => c.textContent),
      names: Array.from(document.querySelectorAll(".home-chip-name")).map((c) => c.textContent),
      foot: document.getElementById("home-prefs-foot").textContent,
      // the panel still lists the hidden one, or he could never bring it back
      panelRows: document.querySelectorAll(".home-prefs-row").length,
    }));
    assert(r.labels.includes("WB"), "the typed label did not reach the home screen");
    assert(!r.names.includes("Tidewater Films"), "the hidden company is still on the home screen");
    // With one company off the row the numbering closes up: five shown, numbered 1-5, and the
    // one carrying a label of its own keeps it.
    assertEqual(r.labels, ["All", "1", "2", "3", "4", "WB"], "the numbering did not follow what is shown: " + JSON.stringify(r.labels));
    assertEqual(r.panelRows, 6, "the hidden company vanished from the panel too");
    assert(/5 of 6/.test(r.foot), "the count line does not say what is showing: " + r.foot);
    // put it back
    await page.check('.home-prefs-show input[data-entity="tidewater"]');
    await page.fill('.home-prefs-label[data-entity="kestrel"]', "");
    await page.evaluate(() => document.querySelector('.home-prefs-label[data-entity="kestrel"]').blur());
    await page.evaluate(() => window.RichHome.closeSettings());
    return `typed "WB" -> button says WB; unchecked Tidewater Films -> off the row, still in the panel, "${r.foot}"`;
  });

  // -------------------------------------------------------------------------------------

  await run.check("the picture lands inside the curtain's hold, on a cold launch", async () => {
    // A FRESH page, and the shipping trigger — the idle callback, not `startField()`.
    //
    // WHAT THIS CHECK LEARNED ON 2026-09-04. It asserted one number — field live before the
    // curtain's 3,000 ms hold — and that number is 473ms here and was 3,330ms on the first
    // public `ui-suite-ci` runner, which failed it. Six times the headroom on the machine it
    // was written for, and gone on a three-vCPU VM rasterizing in software.
    //
    // Three sentences are worth separating, because only one of them is about the machine:
    //
    //   1. THE PICTURE IS KICKED OFF AT LAUNCH, not on entry to the home screen. `home.js`
    //      hands `startField` to `requestIdleCallback` with a 1,200 ms timeout floor,
    //      "so a busy boot cannot postpone the picture past the curtain" — its words. Whether
    //      that floor holds is about scheduling, not about horsepower, and it is asserted
    //      strictly, against the constant read off the product rather than typed here.
    //   2. A PICTURE THAT IS LATE LANDS ON A DESIGNED STATE, not on a pop. `#home-loading`
    //      covers the surface with the breathing mark and leaves on an 0.8s opacity
    //      transition. That is what a slow machine gets, it is deliberate, and it is asserted.
    //   3. AND THE BUILD FINISHES BEFORE THE CURTAIN LIFTS. This one IS horsepower, and there
    //      is no denominator that makes it otherwise. It is reported every run, decomposed
    //      into the wait and the build so the next runner says WHICH half is slow, and it
    //      fails on a gross miss rather than on a machine being three times slower than a
    //      Mac. `docs`-level honesty: on hardware slower than that, the CEO meets the loading
    //      state for a moment. He is not shown a blank screen and he is not shown a pop.
    //
    // AND WHAT IT LEARNED ON 2026-09-05, WHICH IS ABOUT THIS CHECK AND NOT ABOUT THE PRODUCT.
    // Assertion 2 used to SAMPLE the surface once — `goto`, then `waitForFunction`, then an
    // `evaluate` — and require the loading state to be up at that instant. That instant is not
    // a moment in the product's life; it is whenever the harness got its turn. Here that is
    // ~100ms after navigation and the picture lands at ~490ms, so it read "still building" and
    // passed. On a `macos-latest` runner the harness's first instruction after `load` arrives
    // about 2,000 ms late (measured, `README.md` "Making this machine behave like a runner")
    // and the picture lands at 1,669-2,544 ms — so the sample lands AFTER the picture, reads a
    // dismissed cover, and reports `the loading state was already dismissed before the field
    // was live` about a launch in which everything happened in the right order. Reproduced on
    // this machine, three runs out of three, with `RICHOS_SPLASH_LAG_MS=2000`.
    //
    // SO NOTHING IS SAMPLED FROM OUTSIDE ANY MORE. The page records the ORDER of its own
    // launch and the order is what is asserted — which is both immune to when the harness
    // wakes up AND strictly stronger than what a single sample could say: a cover that went
    // early would be caught wherever it went, not only if the harness happened to be looking.
    const p2 = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await p2.addInitScript(() => {
      // WHEN THE BUILD ACTUALLY STARTED, which no state flag records — `state.field` is
      // "loading" from the first line to the last. The first observable act of `startField`
      // is `loadScript` inserting `home/field-*.js`, so that insertion IS the start, seen
      // from outside. Deliberately not patching `RichHome.startField`: the idle callback
      // holds the closure, not the export, so a wrapper on the export never runs (it read
      // null, first try). And deliberately not patching `requestIdleCallback` either — that
      // would test the branch this WebKit build happens to take rather than the product.
      window.__fieldStartedAt = null;
      // AND WHAT WAS ON SCREEN AT THAT INSTANT, recorded by the page rather than asked for
      // later: the cover has to be up and undismissed when the build begins, or the CEO is
      // watching a bare surface while 5 MB loads.
      window.__coverAtKickoff = null;
      // WHEN THE COVER LEFT, and — the assertion that matters — WHAT EXISTED WHEN IT DID.
      // `field-engine.js` adds `.gone` and publishes `window.__loro` in the same synchronous
      // block, so an observer that fires after it sees both. A cover dismissed on a timer, or
      // moved ahead of the engine, would be seen with no picture behind it.
      window.__gone = null;
      const look = () => {
        const l = document.getElementById("home-loading");
        if (window.__fieldStartedAt == null && document.querySelector('script[src*="home/field-"]')) {
          window.__fieldStartedAt = performance.now();
          window.__coverAtKickoff = { present: !!l, gone: !!(l && l.classList.contains("gone")) };
        }
        if (window.__gone == null && l && l.classList.contains("gone")) {
          window.__gone = {
            at: performance.now(),
            loro: !!window.__loro,
            frames: window.__loro ? window.__loro.frames : null,
            fadeMs: Math.round(parseFloat(getComputedStyle(l).transitionDuration) * 1000),
            field: window.RichHome ? window.RichHome.state.field : null,
          };
        }
      };
      new MutationObserver(look).observe(document, {
        childList: true, subtree: true, attributes: true, attributeFilter: ["class"],
      });
      // AND THE ORIGIN THE FLOOR IS MEASURED FROM. `home.js` arms the idle callback in
      // `afterShell`, which runs on DOMContentLoaded — so the 1,200 ms timeout is 1,200 ms
      // from THERE, not from navigation. Comparing it against a from-navigation figure would
      // charge the picture for the shell's boot and go red on a slow machine for a floor
      // that held perfectly.
      window.__domReadyAt = null;
      document.addEventListener("DOMContentLoaded", () => {
        if (window.__domReadyAt == null) window.__domReadyAt = performance.now();
      }, true);
      // AND WHEN THE PICTURE ACTUALLY LANDED, timed BY THE PAGE. `performance.now()` read from
      // an `evaluate` after the field is live reports when the HARNESS got its turn, and on a
      // runner that is about 2,000 ms after the fact — which is why the numbers this check used
      // to print from CI (1,669-2,544 ms) were mostly harness lag charged to the product. A
      // 10 ms poll costs nothing next to a 5 MB script load and it is the product's own clock.
      window.__liveAt = null;
      (function pollLive() {
        if (window.RichHome && window.RichHome.state.field === "live") {
          window.__liveAt = performance.now();
          return;
        }
        setTimeout(pollLive, 10);
      })();
    });
    await p2.goto(APP);
    if (LAG_MS > 0) await p2.waitForTimeout(LAG_MS);
    await p2.waitForFunction("typeof window.RichHome === 'object'");
    await p2.waitForFunction("window.RichHome.state.field === 'live'", { timeout: 60000 });
    const t = await p2.evaluate(() => ({
      live: window.__liveAt == null ? null : Math.round(window.__liveAt),
      sampledAt: Math.round(performance.now()),
      started: window.__fieldStartedAt == null ? null : Math.round(window.__fieldStartedAt),
      domReady: window.__domReadyAt == null ? null : Math.round(window.__domReadyAt),
      cover: window.__coverAtKickoff,
      left: window.__gone,
      present: !!document.getElementById("home-loading"),
      gone: document.getElementById("home-loading").classList.contains("gone"),
    }));
    await p2.close();

    // The two numbers the product names, read off the product.
    const homeSrc = fs.readFileSync(path.join(UI_DIR, "home.js"), "utf8");
    const idleFloor = Number((homeSrc.match(/var FIELD_IDLE_TIMEOUT_MS = (\d+);/) || [])[1]);
    assert(idleFloor > 0, "home.js no longer names FIELD_IDLE_TIMEOUT_MS — nothing floors the kick-off");
    const splashSrc = fs.readFileSync(path.join(UI_DIR, "splash.js"), "utf8");
    const hold = Number((splashSrc.match(/var SPLASH_SECONDS = (\d+);/) || [])[1]) * 1000;
    assert(hold > 0, "splash.js no longer names SPLASH_SECONDS");

    // 1. STRICT. The kick-off is floored by a TIMER, not by the machine's speed, so a slow
    //    runner has no excuse here — 300ms of slack for timer imprecision and nothing more.
    assert(t.started != null, "the field scripts were never requested — nothing kicked the picture off");
    assert(t.live != null, "nothing recorded WHEN the picture landed — the number below would be the harness's clock, not the product's");
    assert(t.domReady != null, "DOMContentLoaded was never seen, so the floor has no origin to be measured from");
    const armed = t.started - t.domReady;
    assert(
      armed <= idleFloor + 300,
      `the picture was not kicked off inside its own ${idleFloor}ms floor — it started ${armed}ms after ` +
        `DOMContentLoaded (at ${t.started}ms from navigation)`
    );
    // 2. STRICT, AND IN THE PAGE'S OWN ORDER RATHER THAN AT THE HARNESS'S CONVENIENCE. What he
    //    sees while it builds is the designed state; it is still up when the build STARTS; it
    //    leaves only once there is a picture to leave onto; and it leaves on a cross-fade.
    assert(t.present, "there is no loading state — a late picture would arrive on a blank surface");
    assert(t.cover != null, "nothing recorded what was on screen when the build started");
    assert(t.cover.present, "the loading state was not on screen when the picture began building");
    assert(!t.cover.gone, "the loading state had already been dismissed when the picture began building");
    assert(t.left != null, "the loading state never left — the field went live behind a cover");
    assert(
      t.left.at >= t.started,
      `the loading state left at ${Math.round(t.left.at)}ms, before the picture even began building at ${t.started}ms`
    );
    // THE ONE THAT SAYS THE DISMISSAL IS GATED ON READINESS RATHER THAN ON A GUESS. The cover
    // is lifted by `field-engine.js` in the same synchronous block that publishes the picture,
    // so `window.__loro` is there when it goes. Put the dismissal on a timer, or ahead of the
    // engine, and this reads false.
    assert(t.left.loro, "the loading state was dismissed with no picture published behind it");
    assert(t.left.fadeMs >= 500, `the loading state leaves in ${t.left.fadeMs}ms — that is a pop, not a cross-fade`);
    assert(t.gone, "the field went live and the loading state stayed up");
    // 3. THE MACHINE-DEPENDENT ONE, reported always and failed only on a gross miss. Three
    //    curtain-holds is where the loading state stops being a moment and becomes the
    //    experience; anything under it is a slow machine, which is a fact about the machine.
    const inside = t.live < hold;
    assert(
      t.live < hold * 3,
      `the picture landed at ${t.live}ms against a ${hold}ms hold — that is past three holds, so the loading ` +
        `state IS the launch on this machine (kick-off ${t.started}ms, build ${t.live - t.started}ms)`
    );
    return (
      `field live at ${t.live}ms from navigation, timed by the page (the harness only got its turn at ` +
      `${t.sampledAt}ms) — shell ready ${t.domReady}ms, kick-off ${armed}ms after it ` +
      `inside a ${idleFloor}ms floor, build ${t.live - t.started}ms — ${inside ? `inside the curtain's ${hold}ms hold` : `PAST the ${hold}ms hold on this machine, so the designed loading state carries it`}` +
      `\n          the cover was up when the build started and left at ${Math.round(t.left.at)}ms with the picture ` +
      `published, on a ${t.left.fadeMs}ms cross-fade — ${t.left.frames} frames drawn at that moment, so the first ` +
      `frame lands inside the fade rather than before it` +
      (LAG_MS > 0 ? ` · run with RICHOS_SPLASH_LAG_MS=${LAG_MS}` : "")
    );
  });

  await run.check("a display that will not draw the picture says so AT ONCE, and never shouts", async () => {
    // THE FAILURE THE RUNNER FOUND, DRIVEN. `ui-suite-ci` run 33879245990 on a GitHub
    // `macos-latest` runner logged this, three times, in three different suites:
    //
    //     console: WebGL: context lost.
    //     Unhandled Promise Rejection: Error: null
    //     attribute vec2 a_pos; attribute float a_z; …
    //
    // That is `field-engine.js`'s `shader()` throwing `getShaderInfoLog(s) + '\n' + src`
    // with a NULL info log, because the context had gone — and the throw is inside an async
    // IIFE, so nobody was holding the promise. `home.js` recovered correctly and it took
    // eight seconds to do it, because the only way it could learn was to time out.
    //
    // The engine now catches its own throw into `window.__loroFailed` and `settled()` reads
    // it. This check is what makes that a claim rather than a comment: it reproduces the
    // runner's throw AT ITS OWN SITE — `getShaderParameter` returning false is exactly what
    // sends `shader()` into that `throw` — and holds the product to three things.
    //
    // THIS MACHINE HAS WORKING WEBGL, WHICH IS WHY THE FAILURE IS PLANTED. A check that
    // passes because the environment lacks the thing that breaks it is not a check; the
    // environment is given the defect here instead of being trusted not to have it.
    const p5 = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const noise = [];
    p5.on("pageerror", (e) => noise.push("pageerror: " + String(e)));
    p5.on("console", (m) => {
      if (m.type() === "error") noise.push("console: " + m.text());
    });
    await p5.addInitScript(() => {
      const proto = WebGLRenderingContext.prototype;
      const orig = proto.getShaderParameter;
      proto.getShaderParameter = function (sh, pname) {
        if (pname === this.COMPILE_STATUS) return false;
        return orig.apply(this, arguments);
      };
      // And the null info log the runner really returned, so the message shape matches too.
      proto.getShaderInfoLog = function () {
        return null;
      };
    });
    await p5.goto(APP);
    await p5.waitForFunction("typeof window.RichHome === 'object'");
    const t0 = Date.now();
    await p5.waitForFunction("window.RichHome.state.field === 'degraded'", { timeout: 20000 });
    const took = Date.now() - t0;
    const r = await p5.evaluate(() => ({
      field: window.RichHome.state.field,
      why: window.RichHome.state.fieldError,
      said: (document.getElementById("home-loading").textContent || "").trim(),
      loro: !!window.__loro,
      failed: window.__loroFailed || null,
      switchReachable: !!document.getElementById("home-enter"),
      settingsReachable: !!document.querySelector(".setbtn"),
    }));
    // 1. IT DEGRADES, and says the true sentence rather than sitting on "waking loro…".
    assertEqual(r.field, "degraded", "a display that cannot draw the picture left the surface claiming it could");
    assert(!r.loro, "the engine published itself after failing to start");
    assert(
      /I couldn't draw the picture on this display/.test(r.said),
      "the honest sentence is not on screen — it says: " + JSON.stringify(r.said)
    );
    // 2. AT ONCE. The eight-second deadline is the backstop for a failure nothing can be
    //    told about; a failure the engine KNOWS about must not wait for it. Two seconds is
    //    generous for a page load on any machine and a third of the deadline it replaces.
    assert(r.failed, "the engine did not report its own failure — settled() is back on the timeout");
    assert(took < 2000, `the surface took ${took}ms to admit it — that is the eight-second deadline, not the report`);
    // 3. AND IT DOES NOT SHOUT. An unhandled rejection is what a crash reporter files, what a
    //    console fills with, and what made three unrelated splash checks red on that runner.
    const unhandled = noise.filter((n) => /Unhandled Promise Rejection|pageerror/.test(n));
    assertEqual(unhandled, [], "the failure reached the console as an unhandled rejection");
    // ...and the way through is still there, which is the whole point of degrading.
    assert(r.switchReachable && r.settingsReachable, "degrading took the way out or the settings button with it");
    await p5.close();
    return (
      `the shader refused, the surface admitted it in ${took}ms (was an 8000ms deadline), said ` +
      `"${r.said}", published no picture, kept the switch and the settings button, and reached ` +
      `the console with 0 unhandled rejections · the engine's own words: ${JSON.stringify(r.failed)}`
    );
  });

  await run.check("a launch with NO curtain at all lands on the home screen, dark, and usable", async () => {
    // THE CEO'S OWN MACHINE IS ABOUT TO TAKE THIS PATH. His `launches.json` carries a start
    // this branch's own `open(1)` runs put there, and `splash.js` declines to draw on anything
    // that is not a fresh launch — so the next thing he sees may well be the home screen with
    // nothing in front of it. It is also what every reload, every crash-restart and every
    // second window gets, and what a CEO who switched the opening screen off gets forever.
    //
    // The reason it is worth its own check rather than being covered by the others: the
    // always-dark clamp has TWO owners, and every other check in this file runs after the
    // curtain has yielded, which means after it has handed the clamp over. This one runs where
    // the curtain never held it at all.
    const p4 = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    // The shell injects this before any page script; `"reload"` is one of the kinds `splash.js`
    // declines on. Nothing here disables the home screen — that is the point.
    await p4.addInitScript(() => {
      window.__RICHOS_LAUNCH__ = Object.freeze({ kind: "reload" });
    });
    await p4.goto(APP);
    await p4.waitForFunction("typeof window.RichHome === 'object'");
    await p4.waitForFunction("typeof window.RichTimeline === 'object'");
    const r = await p4.evaluate(() => ({
      splashDrew: window.RichSplash.state.shown,
      splashDeclined: window.RichSplash.state.declined,
      homeOpen: window.RichHome.state.open,
      homeHidden: document.getElementById("home").hidden,
      curtainNodes: document.querySelectorAll("#splash, .splash").length,
      theme: document.documentElement.getAttribute("data-theme"),
      forced: window.RichTheme.forcedDark(),
      appInert: document.getElementById("app").hasAttribute("inert"),
      switchReachable: !!document.getElementById("home-enter"),
      settingsReachable: !!document.querySelector(".setbtn"),
    }));
    assert(!r.splashDrew, "the curtain drew on a launch it should have declined");
    assert(/not a fresh launch/.test(r.splashDeclined || ""), "it declined for the wrong reason: " + r.splashDeclined);
    assertEqual(r.curtainNodes, 0, "a curtain node is in the document");
    assert(r.homeOpen && !r.homeHidden, "the home screen is not the surface he landed on");
    assertEqual(r.theme, "dark", "§15's exception did not hold without a curtain to hand it over");
    assert(r.forced, "the always-dark clamp was never raised — it was the curtain's to raise, and there was none");
    assert(r.appInert, "#app is live behind the home screen");
    assert(r.switchReachable && r.settingsReachable, "the way out or the settings button is missing");
    // ...and it is still a working surface, not just a correct one.
    await p4.evaluate(() => window.RichHome.startField());
    await p4.waitForFunction("window.RichHome.state.field === 'live'", { timeout: 60000 });
    await p4.click("#home-enter");
    await p4.waitForFunction(() => document.getElementById("home").hidden);
    const left = await p4.evaluate(() => ({
      open: window.RichHome.state.open,
      forced: window.RichTheme.forcedDark(),
    }));
    assert(!left.open && !left.forced, "the switch did not work on a launch with no curtain");
    await p4.close();
    return `curtain declined ("${r.splashDeclined}"), 0 curtain nodes, home screen up and dark with the clamp raised by itself, switch works`;
  });

  await run.check("no page errors, across all of it", async () => {
    assertEqual(page.__errors, [], "uncaught errors in the real shell");
    return `${page.__errors.length} uncaught errors, ${page.__errors.length} console errors, over the whole run`;
  });

  await run.check("the suites' own way past this surface still works", async () => {
    const p3 = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await p3.goto(APP);
    const left = await leaveHome(p3);
    const r = await p3.evaluate(() => ({
      hidden: document.getElementById("home").hidden,
      inert: document.getElementById("app").hasAttribute("inert"),
      railClickable: !!document.querySelector(".nav-thread"),
    }));
    await p3.close();
    assert(left, "leaveHome did not find the home screen");
    assert(r.hidden && !r.inert, "leaveHome left the shell unreachable");
    return "leaveHome(page) returns true, un-mounts the surface and hands the shell back";
  });

  await browser.close();
  // THE RETURN VALUE IS THE EXIT CODE, and this file was the one suite in the directory that
  // dropped it. On 2026-09-04's first public `ui-suite-ci` run that cost two real failures on
  // the CEO's home screen: `run.js` printed "FAIL home.js — 2 failed (exit 0)" in its evidence
  // table and then named only scale.js and splash.js as failed, because it gated on the exit
  // code. `run.js` now gates on the ledger as well, so this line is belt to its braces rather
  // than the only thing standing between a red check and a green badge.
  return run.report();
}

main().then(
  (failed) => process.exit(failed ? 1 : 0),
  (e) => {
    console.error(e);
    process.exit(1);
  }
);

// ---------------------------------------------------------------------------------------
// THE COLD-LAUNCH CHECK, AND WHY THE PRODUCT WAS NOT CHANGED — 2026-09-05
// ---------------------------------------------------------------------------------------
//
// `ui-suite-ci` run 33933067025 failed this suite on one line:
//
//     FAIL  the picture lands inside the curtain's hold, on a cold launch
//           the loading state was already dismissed before the field was live
//
// READ AS WRITTEN, that says a customer on a slow machine meets a dismissed cover over a
// surface with nothing on it. It is not what happened, and the evidence is here rather than
// in a claim:
//
//  1. THE SENTENCE WAS ABOUT A SAMPLE, NOT ABOUT THE SCREEN. The check did `goto`, then
//     `waitForFunction`, then one `evaluate`, and required the cover to be up at whatever
//     instant that `evaluate` ran. That instant belongs to the harness. Here it lands ~100ms
//     after navigation with the picture arriving at ~460ms, so it read "still building". On a
//     `macos-latest` runner the harness's first instruction after `load` arrives about
//     2,000 ms late — measured on this repository's own runners and already documented in
//     `README.md` — and the picture arrives at 1,669-2,544 ms, so the sample lands after
//     everything and reads a dismissed cover over a LIVE picture. `state.field` in that same
//     sample read `live`, which is the tell.
//
//  2. REPRODUCED, THREE OUT OF THREE, ON THIS MACHINE. `RICHOS_SPLASH_LAG_MS=2000` puts the
//     lag in and the old assertion fails every time with the runner's exact wording, on a
//     launch in which the cover was up for the whole build. The same knob against the check
//     as it now stands passes: `field live at 464ms from navigation, timed by the page (the
//     harness only got its turn at 2172ms)`.
//
//  3. THE PRODUCT'S ORDER WAS ALREADY RIGHT, and it is not gated on a duration.
//     `field-engine.js` lifts `#home-loading` in the same synchronous block that publishes
//     `window.__loro`, so the cover leaves at the moment the picture exists. Measured over
//     five launches: cover up at kick-off, gone at 449-494ms, `window.__loro` present at that
//     instant every time. The one fixed number on the path is the 0.8s CSS cross-fade, and the
//     first frame is drawn 25-35ms into it.
//
// SO THE PRODUCT IS UNCHANGED AND THE CHECK IS. Nothing is sampled from outside any more: the
// page records the ORDER of its own launch and the order is asserted, which is both immune to
// when the harness wakes up and strictly more than one sample could say. The old form could
// only catch an early dismissal if the harness happened to be looking at that moment; this one
// catches it wherever it happens.
//
// ALSO FIXED, AND IT WAS QUIETLY WRONG THE WHOLE TIME: assertion 3's `t.live` was
// `performance.now()` read from an `evaluate` AFTER the field went live, so it timed the
// harness, not the picture. The 1,669-2,544 ms this check has been printing from CI was mostly
// harness lag charged to the product. It is now recorded by the page at the moment the state
// flips; under a 2,000 ms lag it reads 464ms while the harness's own turn reads 2,172ms.
//
// THE MUTATION RUNS BEHIND THE TWO NEW ASSERTIONS, both against the shipped `app/ui/home.js`:
//
//  1. LIFT THE COVER AT KICK-OFF — `classList.add("gone")` at the top of `startField()`, which
//     is a dismissal that is a guess about how fast the machine is. RED:
//     `the loading state had already been dismissed when the picture began building`.
//
//  2. LIFT IT WHEN THE DATA LANDS, BEFORE THE ENGINE RUNS — the same line in `loadScript`'s
//     `onload`, so the cover goes with `window.__loro` still undefined. RED:
//     `the loading state was dismissed with no picture published behind it`.
//
// A third shape — a `setTimeout` inside `startField` — does NOT reproduce, and the reason is
// worth keeping: the engine's whole build is synchronous, so a timer armed at kick-off cannot
// fire until after the picture is up. A duration-based dismissal on this path has to be armed
// before the scripts load to beat them, which is what mutation 1 does.

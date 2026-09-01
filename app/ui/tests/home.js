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
const { loadPlaywright, leaveHome, shot, createRun, assert, assertEqual, UI_DIR, SHOT_DIR } = require("./lib/harness");
const contrastLib = require("./lib/contrast");

const APP = "file://" + path.join(UI_DIR, "index.html");
const SHOTS = path.join(__dirname, "shots-home");

/// His six, as `EntityRegistry::ceos_companies` holds them (richos-core entity.rs:227-238) and
/// in its order. Written down HERE so the suite can prove the row is the registry's rather than
/// merely non-empty — a row that had drifted to four, which is what `mock.js` carried until
/// today, would otherwise pass every other check in this file.
const REGISTRY = [
  ["femcboost", "FemcBoost"],
  ["deeply", "Deeply"],
  ["prospects", "Prospects"],
  ["richos", "RichOS"],
  ["gpt-exporter", "GPT Exporter"],
  ["webinar-booster", "Webinar Booster"],
];

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
        interior(el) {
          const r = el.getBoundingClientRect();
          const cs = getComputedStyle(el);
          const bw = Math.max(
            parseFloat(cs.borderTopWidth) || 0, parseFloat(cs.borderLeftWidth) || 0,
            parseFloat(cs.borderRightWidth) || 0, parseFloat(cs.borderBottomWidth) || 0);
          let rad = parseFloat(cs.borderTopLeftRadius) || 0;
          rad = Math.min(rad, r.height / 2, r.width / 2);
          const insetX = bw + rad + 1;
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
              regions = this.ring(el, 3).concat(this.interior(el));
            } else if (kind === 'paint') {
              ink = ink || cs.backgroundColor;
              regions = this.ring(el, t.ringWidth || 4, t.ringGap || 0);
            } else if (kind === 'svg') {
              ink = ink || cs.fill;
              regions = this.interior(el);
            } else if (kind === 'fill') {
              ink = ink || cs.color;
              regions = this.interior(el);
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

  await run.check("the company buttons are the REGISTRY's six, not a list somebody typed", async () => {
    await page.waitForFunction("window.RichHome.state.entitySource === 'registry'");
    const r = await page.evaluate(() => ({
      ids: Array.from(document.querySelectorAll(".home-chip")).map((c) => c.getAttribute("data-entity")),
      labels: Array.from(document.querySelectorAll(".home-chip")).map((c) => c.textContent),
      source: window.RichHome.state.entitySource,
      count: window.RichHome.state.entityCount,
    }));
    assertEqual(r.ids, [""].concat(REGISTRY.map((e) => e[0])), "the row is not the registry, in registry order");
    assertEqual(r.labels, ["All companies"].concat(REGISTRY.map((e) => e[1])), "the labels are not the registry's display names");
    assertEqual(r.count, 6, "the row is not carrying his six companies");
    // `richos` is ONE entity with TWO roots. A row built from directories would show two.
    assertEqual(r.ids.filter((i) => i === "richos").length, 1, "richos appeared more than once — two roots became two buttons");
    return `${r.count} companies from the registry, in order: ${r.labels.slice(1).join(", ")}`;
  });

  await run.check('"All companies" is a visible DEFAULT STATE, not the absence of a selection', async () => {
    const before = await page.evaluate(() => ({
      pressed: Array.from(document.querySelectorAll('.home-chip[aria-pressed="true"]')).map((c) => c.textContent),
      entity: window.RichHome.state.entity,
    }));
    assertEqual(before.pressed, ["All companies"], "the default is not the pressed state on arrival");
    assertEqual(before.entity, "", "the default is not recorded as the selection");
    // The buttons do NOTHING to the picture in v1 — but they are real controls, not decoration.
    const framesBefore = await page.evaluate(() => window.__loro.frames);
    await page.click('.home-chip[data-entity="deeply"]');
    const after = await page.evaluate(() => ({
      pressed: Array.from(document.querySelectorAll('.home-chip[aria-pressed="true"]')).map((c) => c.textContent),
      entity: window.RichHome.state.entity,
      disabled: !!document.querySelector(".home-chip[disabled]"),
      N: window.__loro.N,
    }));
    assertEqual(after.pressed, ["Deeply"], "the selection did not move to the button that was pressed");
    assertEqual(after.entity, "deeply", "the selection is not carried as the entity id");
    assert(!after.disabled, "a button is disabled — these are real controls with an effect that is not built yet, not dead ones");
    assertEqual(after.N, 7500, "the picture changed — v1 filtering is NOT in scope and must not have shipped");
    await page.click('.home-chip[data-entity=""]');
    return `default pressed on arrival; pressing Deeply moves the selection and leaves the picture at 7,500 (frames ${framesBefore} -> ${await page.evaluate(() => window.__loro.frames)})`;
  });

  await run.check("the row wraps into rows, is centered, and does NOT fill the gap between the two columns", async () => {
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
        clearLeft: Math.round(b.left),
        clearRight: Math.round(innerWidth - b.right),
        brandTop: Math.round(brand.top),
        liveTop: Math.round(live.top),
        inset: getComputedStyle(document.getElementById("home")).getPropertyValue("--home-top-inset").trim(),
      };
    });
    assert(r.rows >= 2, "his six did not wrap — the requirement is rows, and this is one line");
    assert(r.width <= 500, `the row is ${r.width}px wide; the cap is 500px so it cannot sprawl`);
    // Centered: the clear space on the two sides is equal to within a pixel.
    assert(Math.abs(r.clearLeft - r.clearRight) <= 1, `the row is not centered (${r.clearLeft}px left, ${r.clearRight}px right)`);
    // "shouldn't take up all of the empty space between the left and the right text column"
    assert(r.width < r.vw * 0.4, `the row takes ${Math.round((r.width / r.vw) * 100)}% of the window width`);
    // ...and the composition it displaces is BELOW it, by a measured inset rather than a guess.
    assert(r.brandTop > r.bottom, "the mark is not clear of the row");
    assert(r.liveTop > r.bottom, "the workforce list is not clear of the row");
    return `${r.rows} rows (${r.perRow.join("+")}), ${r.width}px wide in a ${r.vw}px window, ${r.clearLeft}px clear each side, inset ${r.inset}, mark at ${r.brandTop} clear of a row ending at ${r.bottom}`;
  });

  await run.check("a one-character label is a considered pill, not a cramped lozenge", async () => {
    await page.evaluate(async () => {
      const ids = ["femcboost", "deeply", "prospects", "richos", "gpt-exporter", "webinar-booster"];
      for (let i = 0; i < ids.length; i++) {
        await window.RichBridge.invoke("set_home_entity_label", { entityId: ids[i], label: String(i + 1) });
      }
      await window.RichHome.reloadEntities();
    });
    const r = await page.evaluate(() => {
      const chips = Array.from(document.querySelectorAll(".home-chip"));
      const tops = {};
      chips.forEach((c) => {
        const t = Math.round(c.getBoundingClientRect().top);
        tops[t] = (tops[t] || 0) + 1;
      });
      return {
        labels: chips.map((c) => c.textContent),
        ids: chips.map((c) => c.getAttribute("data-entity")),
        widths: chips.map((c) => Math.round(c.getBoundingClientRect().width)),
        heights: chips.map((c) => Math.round(c.getBoundingClientRect().height)),
        rows: Object.keys(tops).length,
        inset: getComputedStyle(document.getElementById("home")).getPropertyValue("--home-top-inset").trim(),
      };
    });
    assertEqual(r.labels, ["All companies", "1", "2", "3", "4", "5", "6"], "the anonymized labels are not what he typed");
    // A LABEL IS A MASK, NEVER A RENAME. This is the check that would catch an anonymized home
    // screen having re-homed his work.
    assertEqual(r.ids, [""].concat(REGISTRY.map((e) => e[0])), "the entity ids moved when the labels did");
    const single = r.widths.slice(1);
    assert(single.every((w) => w >= 46), `a single-character chip came out ${Math.min.apply(null, single)}px wide`);
    assert(single.every((w, i) => w > r.heights[i + 1]), "a single-character chip is taller than it is wide — that reads as a mistake, not a chip");
    await shot(page, "home-anonymized", { fullPage: false });
    fs.copyFileSync(path.join(SHOT_DIR, "home-anonymized.png"), path.join(SHOTS, "home-anonymized.png"));
    return `labels ${r.labels.slice(1).join(" ")} at ${single.join("/")}px wide x ${r.heights[1]}px, ${r.rows} row(s), inset ${r.inset}; every entity id unchanged`;
  });

  await run.check("clearing a label puts the real name back — anonymizing is reversible", async () => {
    await page.evaluate(async () => {
      const ids = ["femcboost", "deeply", "prospects", "richos", "gpt-exporter", "webinar-booster"];
      for (const id of ids) await window.RichBridge.invoke("set_home_entity_label", { entityId: id, label: null });
      await window.RichHome.reloadEntities();
    });
    const labels = await page.evaluate(() => Array.from(document.querySelectorAll(".home-chip")).map((c) => c.textContent));
    assertEqual(labels, ["All companies"].concat(REGISTRY.map((e) => e[1])), "clearing the overrides did not restore the registry's names");
    return "cleared six overrides; every button reads its registry name again";
  });

  await run.check("with one company shown the row is ABSENT, and the composition is the round's", async () => {
    await page.evaluate(async () => {
      for (const id of ["deeply", "prospects", "richos", "gpt-exporter", "webinar-booster"]) {
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
      for (const id of ["deeply", "prospects", "richos", "gpt-exporter", "webinar-booster"]) {
        await window.RichBridge.invoke("set_home_entity_visible", { entityId: id, visible: true });
      }
      await window.RichHome.reloadEntities();
    });
    const back = await page.evaluate(() => document.querySelectorAll(".home-chip").length);
    assertEqual(back, 7, "un-hiding did not bring the row back");
    return `1 company shown -> row absent, inset 0px, mark back at y=30; 6 shown -> 7 buttons again`;
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
      { name: "chip, unselected", sel: '.home-chip[data-entity="femcboost"]', needs: 4.5 },
      { name: "chip, unselected edge", sel: '.home-chip[data-entity="femcboost"]', needs: 3, kind: "edge" },
      { name: "chip, selected", sel: '.home-chip[data-entity=""]', needs: 4.5 },
      // The selected chip's indicator is its FILL — its border is struck in the same tone, so
      // an `edge` measurement would be the fill against itself. What it owes 3:1 to is what
      // surrounds it.
      { name: "chip, selected fill", sel: '.home-chip[data-entity=""]', needs: 3, kind: "paint" },
      { name: "the switch", sel: "#home-enter", needs: 4.5 },
      { name: "the switch arrow", sel: "#home-enter .home-enter-arrow", needs: 3 },
      { name: "the switch edge", sel: "#home-enter", needs: 3, kind: "edge" },
    ]);
    const bad = failures(rows);
    assertEqual(bad.length, 0, "these are under the floor:\n" + reportRatios(bad));
    return reportRatios(rows) + `\n          worst on the screen: ${Math.min.apply(null, rows.map((r) => r.ratio))}:1`;
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
    const chip = r.find((x) => x.text === "FemcBoost");
    assertEqual(chip && chip.px, 16, "the company buttons are not at §15's 16px reading floor");
    return `${r.length} rendered strings, sizes ${sizes.join("/")}px, smallest ${sizes[0]}px; the company buttons are 16px`;
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
    // The only families this surface may name are the two vendored ones; everything after
    // them must be a GENERIC keyword, never a platform face.
    const allowed = /^("Newsreader"|"Inter"|Newsreader|Inter)(,\s*(serif|sans-serif|monospace|system-ui))?$/;
    const bad = r.stacks.filter((s) => !allowed.test(s.trim()));
    assertEqual(bad, [], "these stacks name something that is not a vendored face or a generic keyword");
    const loaded = r.faces.filter((f) => f.endsWith("=loaded"));
    assert(loaded.length >= 2, "the vendored faces did not load: " + JSON.stringify(r.faces));
    return `${r.stacks.length} distinct stacks, all vendored: ${r.stacks.join(" | ")}; faces ${r.faces.join(", ")}`;
  });

  // -------------------------------------------------------------------------------------
  // The switch, and the way back
  // -------------------------------------------------------------------------------------

  await run.check("the switch takes him to the app UI, and the picture stops", async () => {
    await shot(page, "home-named", { fullPage: false });
    fs.copyFileSync(path.join(SHOT_DIR, "home-named.png"), path.join(SHOTS, "home-named.png"));
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
    fs.copyFileSync(path.join(SHOT_DIR, "home-app-ui.png"), path.join(SHOTS, "home-app-ui.png"));
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
    fs.copyFileSync(path.join(SHOT_DIR, "home-returned.png"), path.join(SHOTS, "home-returned.png"));
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
      assertEqual(shape.placeholders, REGISTRY.map((e) => e[1]), "an empty field does not show the real name as its hint");
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
      fs.copyFileSync(path.join(SHOT_DIR, "home-settings-" + theme + ".png"), path.join(SHOTS, "home-settings-" + theme + ".png"));
      await page.evaluate(() => window.RichHome.closeSettings());
      return reportRatios(all) + `\n          ${shape.foot}`;
    });
  }

  await run.check("the settings write through: a label typed there reaches the home screen", async () => {
    await page.evaluate(() => window.RichTheme.setTheme("dark"));
    await page.evaluate(() => window.RichHome.openSettings());
    await page.waitForFunction(() => document.querySelectorAll(".home-prefs-row").length > 0);
    await page.fill('.home-prefs-label[data-entity="webinar-booster"]', "WB");
    await page.evaluate(() => document.querySelector('.home-prefs-label[data-entity="webinar-booster"]').blur());
    await page.waitForFunction(() => Array.from(document.querySelectorAll(".home-chip")).some((c) => c.textContent === "WB"));
    await page.uncheck('.home-prefs-show input[data-entity="gpt-exporter"]');
    await page.waitForFunction(() => !Array.from(document.querySelectorAll(".home-chip")).some((c) => c.textContent === "GPT Exporter"));
    const r = await page.evaluate(() => ({
      labels: Array.from(document.querySelectorAll(".home-chip")).map((c) => c.textContent),
      foot: document.getElementById("home-prefs-foot").textContent,
      // the panel still lists the hidden one, or he could never bring it back
      panelRows: document.querySelectorAll(".home-prefs-row").length,
    }));
    assert(r.labels.includes("WB"), "the typed label did not reach the home screen");
    assert(!r.labels.includes("GPT Exporter"), "the hidden company is still on the home screen");
    assertEqual(r.panelRows, 6, "the hidden company vanished from the panel too");
    assert(/5 of 6/.test(r.foot), "the count line does not say what is showing: " + r.foot);
    // put it back
    await page.check('.home-prefs-show input[data-entity="gpt-exporter"]');
    await page.fill('.home-prefs-label[data-entity="webinar-booster"]', "");
    await page.evaluate(() => document.querySelector('.home-prefs-label[data-entity="webinar-booster"]').blur());
    await page.evaluate(() => window.RichHome.closeSettings());
    return `typed "WB" -> button says WB; unchecked GPT Exporter -> off the row, still in the panel, "${r.foot}"`;
  });

  // -------------------------------------------------------------------------------------

  await run.check("the picture lands inside the curtain's hold, on a cold launch", async () => {
    // A FRESH page, and the shipping trigger — the idle callback, not `startField()`.
    const p2 = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await p2.goto(APP);
    await p2.waitForFunction("typeof window.RichHome === 'object'");
    await p2.waitForFunction("window.RichHome.state.field === 'live'", { timeout: 60000 });
    const t = await p2.evaluate(() => Math.round(performance.now()));
    await p2.close();
    // splash.js: HOLD_MS = 3000.
    assert(t < 3000, `the picture landed at ${t}ms, after the curtain's 3000ms hold — the CEO would see it arrive`);
    return `field live at ${t}ms from navigation, inside the curtain's 3000ms hold`;
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
  run.report();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

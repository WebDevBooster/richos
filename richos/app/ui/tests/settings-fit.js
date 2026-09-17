// **THE SETTINGS PANEL FITS THE WINDOW THE APP RESTORES ITSELF TO** — candidate-.4 audit,
// defect 3.
//
// `docs/verification/2026-09-17-nightly-1.2.0-20260917.4-onscreen-audit.md` §4:
//
//   *"The window is 1024x700 at (664,108) — the app's own minimum, restored by the app. The
//    Settings panel measures: menu 'Settings' size 267,738 -> bottom edge at y=940; window
//    size 1024,700 -> bottom edge at y=808. 132 pt of the panel hangs below the window. It does
//    not scroll ... Below the edge are the technical reason, the update-server address, and the
//    'Bust a bug!' button — so from the default window a person cannot reach the control for
//    reporting a bug."*
//
// ## WHY THIS IS ITS OWN SUITE AND NOT A CHECK IN `appearance.js`
//
// `appearance.js` opens every one of its pages at **1400x950** and `ticker-wrap.js` at
// **1400x880**. The app's own minimum, and the size it restores itself to, is **1024x700**.
// Three of the candidate-.4 defects — the home picture, this panel, and the overlapped `CAPITAL`
// count — are all the same shape: something measured at a comfortable size and shipped to a
// smaller one. A suite that only ever opens a roomy window cannot see any of them.
//
// So the window size is the subject here, and every check states it.
//
// ## THE PAIR
//
// A negative control that reproduces Ray's geometry, and the positive control the brief asks
// for. The panel's natural height depends on state — 9 rows measure 523px, and his 738px is the
// same panel with the Updates block opened on an error — so the reproduction GROWS the panel to
// his measured 738px deterministically rather than hoping the fixture renders the same state.
//
// Run: node settings-fit.js   (or `npm test` for every suite in this directory)

"use strict";

const path = require("path");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");

/// The window the app restores itself to, and its own minimum. Every check runs here.
const WINDOW = { width: 1024, height: 700 };

/// The panel height Ray measured on the shipped candidate, in CSS pixels.
const AUDIT_PANEL_HEIGHT = 738;

/// Open the app, dismiss the curtain, and open the settings panel.
async function openMenu(browser, viewport) {
  const page = await browser.newPage({ viewport });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  page.__errors = errors;
  await page.goto(APP);
  await page.waitForSelector("#set-btn", { timeout: 15000 });
  await page.evaluate(() => window.RichSplash && window.RichSplash.yieldNow("settings-fit"));
  await page.click("#set-btn");
  await page.waitForSelector("#set-menu", { state: "visible" });
  // `.setmenu` rises over 0.2s; measuring mid-animation reads a translated box.
  await page.evaluate(async () => {
    const m = document.getElementById("set-menu");
    if (m) await Promise.all(m.getAnimations({ subtree: true }).map((a) => a.finished.catch(() => {})));
  });
  return page;
}

/// Grow the panel to a target height by adding one spacer, and report the geometry.
///
/// `bare` drops the bound and the scrolling, which is the shipped candidate's state — that is
/// how the negative control reproduces the defect rather than describing it.
const MEASURE = `(a) => {
  const menu = document.getElementById("set-menu");
  const bug = document.getElementById("bug-btn");
  const old = document.getElementById("zz-settings-fit-spacer");
  if (old) old.remove();
  if (a.bare) { menu.style.maxHeight = "none"; menu.style.overflowY = "visible"; }
  else { menu.style.maxHeight = ""; menu.style.overflowY = ""; }
  menu.scrollTop = 0;
  const natural = menu.getBoundingClientRect().height;
  if (a.grow) {
    // One spacer, inserted BEFORE the bug button's row so the button stays last exactly as
    // CEO ruling §15 requires, and sized so the panel lands on the audited height.
    const pad = Math.max(0, a.grow - natural);
    const s = document.createElement("div");
    s.id = "zz-settings-fit-spacer";
    s.style.height = pad + "px";
    menu.insertBefore(s, menu.lastElementChild);
  }
  menu.getBoundingClientRect();
  const r = menu.getBoundingClientRect();
  const br = bug.getBoundingClientRect();
  return {
    vh: window.innerHeight,
    top: Math.round(r.top),
    bottom: Math.round(r.bottom),
    height: Math.round(r.height),
    contentHeight: menu.scrollHeight,
    clientHeight: menu.clientHeight,
    scrollable: menu.scrollHeight > menu.clientHeight + 1,
    bugBottom: Math.round(br.bottom),
    bugInWindow: br.top >= 0 && br.bottom <= window.innerHeight,
  };
}`;

const measure = (page, opts) =>
  page.evaluate((a) => eval("(" + a.fn + ")")(a), Object.assign({ fn: MEASURE }, opts));

/// Scroll the panel to its end the way a person would, then re-read the button.
const REACH = `() => {
  const menu = document.getElementById("set-menu");
  menu.scrollTop = menu.scrollHeight;
  menu.getBoundingClientRect();
  const br = document.getElementById("bug-btn").getBoundingClientRect();
  return {
    scrollTop: Math.round(menu.scrollTop),
    bugTop: Math.round(br.top),
    bugBottom: Math.round(br.bottom),
    bugInWindow: br.top >= 0 && br.bottom <= window.innerHeight,
  };
}`;

async function main() {
  const run = createRun("Settings fits the window the app restores itself to (1024x700)");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const page = await openMenu(browser, WINDOW);

  await run.check("the panel as it comes up at 1024x700 is inside the window", async () => {
    const m = await measure(page, {});
    assertEqual(m.vh, WINDOW.height, "the viewport is not the audited window");
    assert(m.top === 66, `the panel's anchor moved to ${m.top}px; the 84px bound in style.css is derived from 66`);
    assert(m.bottom <= m.vh, `the panel's bottom edge is at ${m.bottom} in a ${m.vh}px window`);
    assert(m.bugInWindow, `"Bust a bug!" ends at ${m.bugBottom} in a ${m.vh}px window`);
    return `panel ${m.height}px at top ${m.top}, bottom ${m.bottom} of ${m.vh}; Bust a bug ends at ${m.bugBottom}`;
  });

  await run.check("NEGATIVE CONTROL: at the audited 738px, an unbounded panel puts the button off-window", async () => {
    // Ray's geometry, reproduced: the same panel grown to the height he measured, with the
    // bound and the scrolling removed — which is exactly the shipped candidate. If this check
    // ever passes without failing the way he described, the check below proves nothing.
    const m = await measure(page, { grow: AUDIT_PANEL_HEIGHT, bare: true });
    assertEqual(m.height, AUDIT_PANEL_HEIGHT, "the panel did not reach the audited height");
    assert(!m.scrollable, "the unbounded panel scrolls, so it is not the state that was audited");
    assert(
      !m.bugInWindow,
      `"Bust a bug!" is reachable even unbounded (ends at ${m.bugBottom} of ${m.vh}), so this reproduces nothing`
    );
    const over = m.bottom - m.vh;
    return `panel ${m.height}px, bottom ${m.bottom} of ${m.vh} — ${over}px below the edge, Bust a bug ends at ${m.bugBottom}`;
  });

  await run.check("POSITIVE CONTROL: bounded, the same 738px panel scrolls and the button is reachable", async () => {
    const m = await measure(page, { grow: AUDIT_PANEL_HEIGHT });
    assert(m.bottom <= m.vh, `the bounded panel still ends at ${m.bottom} in a ${m.vh}px window`);
    assert(
      m.scrollable,
      `the panel does not scroll (content ${m.contentHeight}px in ${m.clientHeight}px), so the rest of it is unreachable`
    );
    const after = await page.evaluate((fn) => eval("(" + fn + ")")(), REACH);
    assert(
      after.bugInWindow,
      `after scrolling to the end, "Bust a bug!" is at ${after.bugTop}..${after.bugBottom} in a ${m.vh}px window`
    );
    return (
      `panel clamped to ${m.height}px (content ${m.contentHeight}px), bottom ${m.bottom} of ${m.vh}; ` +
      `scrolled ${after.scrollTop}px and Bust a bug ends at ${after.bugBottom}`
    );
  });

  await run.check("the bound follows the window rather than a fixed number", async () => {
    // A `max-height` in px would pass every check above and still clip a shorter window. The
    // panel is grown past ANY plausible bound so the clamp is the thing being read.
    const page2 = await openMenu(browser, { width: 1024, height: 520 });
    const m = await measure(page2, { grow: 1200 });
    assert(m.bottom <= m.vh, `at a ${m.vh}px window the panel still ends at ${m.bottom}`);
    assert(m.scrollable, "the panel did not become scrollable at the smaller window");
    const after = await page2.evaluate((fn) => eval("(" + fn + ")")(), REACH);
    assert(after.bugInWindow, `"Bust a bug!" ends at ${after.bugBottom} in a ${m.vh}px window`);
    const errs = page2.__errors;
    await page2.close();
    assertEqual(errs, [], "the smaller window reported page errors");
    return `at 1024x520: panel clamped to ${m.height}px, bottom ${m.bottom} of ${m.vh}, Bust a bug ends at ${after.bugBottom}`;
  });

  await run.check("no page errors", async () => {
    assertEqual(page.__errors, [], "the page reported errors");
    return "0 errors";
  });

  await page.close();
  await browser.close();
  // `report()` returns the FAILED COUNT, not a verdict. Same form as every other suite here.
  process.exit(run.report() > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error(e && e.stack ? e.stack : e);
  process.exit(1);
});

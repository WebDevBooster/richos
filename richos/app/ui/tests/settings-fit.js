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
// ## AND THE SURFACE IS THE HOME SCREEN, WHICH THIS HEADER SHOULD HAVE SAID FROM THE START
//
// `openMenu` sends the CURTAIN away and then clicks the button. It does not call `leaveHome`,
// so the surface in front of every check in this file is the home screen, not a thread. That
// has always been true here and cost nothing while the settings button had one position on
// every screen. It stopped costing nothing on 2026-09-19, when the CEO gave the button two —
// centered on the regular screens, back in the corner on the home screen and the held opening
// screen — at which point the anchor this suite pins is a number that only means something once
// the surface is named. It is named here, and again beside the assertion.
//
// Left ON the home screen deliberately, rather than made to leave it. Measured at 1024x700,
// dark, with the bound lifted so the panel reports its natural height:
//
//     home screen   12 rows, 620px natural, no theme row   against a 616px bound
//     a thread      13 rows, 658px natural, theme row      against a 628px bound
//
// §15 clamps this surface dark and `settings-button.js` OMITS the theme row rather than
// disabling it, which is the missing row. Both surfaces overflow their bound and both therefore
// scroll — this one by 4px, a thread by 30px — so this file is measuring the case it exists for
// on either, and it is measuring it on the surface the audited window was audited from. Moving
// it would be a change of subject, not an improvement.
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
    // **66, AND THIS SUITE MEASURES ON THE HOME SCREEN — which nothing said out loud until
    // 2026-09-19 and which is the reason this number moved twice in one day.** `openMenu` above
    // dismisses the CURTAIN and then clicks the button; it never calls `leaveHome`, so the
    // surface in front throughout every check in this file is the home screen. That was true
    // when this line was written and is not a change made here.
    //
    // WHY IT MATTERS NOW: since the CEO's afternoon ruling the settings button has two positions
    // rather than one — 6px on the regular screens, 18px on the home screen and the held
    // opening screen (`style.css`, `--settings-top`) — so "the anchor" is a question with two
    // answers and the surface has to be named before either is right. This panel hangs 8px
    // below the 40px button, so on THIS surface it is 18 + 40 + 8 = 66, and the bound is
    // `calc(100vh - (18px + 66px))` = `100vh - 84px`. Measured here: anchor 66, panel clamped to
    // 616px in a 700px window.
    //
    // IT WAS 66 UNTIL `dcfb87c9`, WENT TO 54 WITH THE MORNING'S CENTERING, AND IS 66 AGAIN.
    // The 54 was not wrong arithmetic; it was right arithmetic about a different surface, and it
    // passed here only because that commit moved the button on all three at once.
    //
    // THE NUMBER IS STILL PINNED RATHER THAN COMPUTED, for the reason it always was: a panel
    // that quietly stopped hanging from the button would still satisfy every fit check below it.
    // `chrome-align.js` owns the other half — that the button is where the CEO asked for it, on
    // each of the three surfaces — and pins the thread's 54 there, so nothing is lost by this
    // file naming only the surface it is actually on.
    assert(m.top === 66, `the panel's anchor moved to ${m.top}px; on the home screen the bound is derived from 66`);
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

  // ---- G12: it opens where it was left, and it must not ----------------------------------

  await run.check("G12  the panel opens at its top, whatever scroll it was closed at", async () => {
    // Urban found this by being bitten by it rather than by looking for it: *"I toggled `Splash
    // screen` on by accident — the Settings panel reopens at its previous scroll position (G12)
    // and my click landed a row off."* A popover that remembers a scroll offset it never showed
    // the user is a popover whose rows are not where they were the last time they looked, and
    // this one genuinely scrolls at 1024x700 — the app's own minimum.
    const p = await openMenu(browser, WINDOW);
    // Grow it so it certainly scrolls in this window, scroll it to the end the way a person
    // would to reach `Bust a bug!`, then close and reopen from the same control he uses.
    await measure(p, { grow: AUDIT_PANEL_HEIGHT });
    const scrolledTo = await p.evaluate(() => {
      const m = document.getElementById("set-menu");
      m.scrollTop = m.scrollHeight;
      return Math.round(m.scrollTop);
    });
    await p.click("#set-btn");
    await p.waitForSelector("#set-menu", { state: "hidden" });
    await p.click("#set-btn");
    await p.waitForSelector("#set-menu", { state: "visible" });
    const reopened = await p.evaluate(async () => {
      const m = document.getElementById("set-menu");
      await Promise.all(m.getAnimations({ subtree: true }).map((a) => a.finished.catch(() => {})));
      const title = document.querySelector("#set-menu .setmenu-title");
      const r = m.getBoundingClientRect();
      const t = title.getBoundingClientRect();
      return { scrollTop: Math.round(m.scrollTop), titleOffset: Math.round(t.top - r.top) };
    });
    const errs = p.__errors;
    await p.close();
    assert(scrolledTo > 40, `the panel only scrolled ${scrolledTo}px, so reopening proves nothing`);
    assertEqual(reopened.scrollTop, 0, "THE DEFECT: the panel reopened at the scroll position it was closed at");
    // AND THE FIRST ROW IS ACTUALLY AT THE TOP, not merely `scrollTop === 0` over a panel whose
    // content moved: "Settings" is the first thing in it and it has to be within its padding.
    assert(
      reopened.titleOffset >= 0 && reopened.titleOffset < 24,
      `"Settings" is ${reopened.titleOffset}px from the panel's top edge on reopen`
    );
    assertEqual(errs, [], "the reopen reported page errors");
    return `closed at scrollTop ${scrolledTo}, reopened at ${reopened.scrollTop} with "Settings" ${reopened.titleOffset}px in`;
  });

  // ---- G10: a row you can press does not look like a heading -------------------------------

  await run.check("G10  the rows that open a sheet are told apart from the panel's two headings", async () => {
    // Urban's G10, his frame 10: `Connected repositories`, `Account connection`, `Memory folder`
    // and `Use Rich from your phone` were `1rem/600/--ink` — which is exactly what `Settings`
    // (`.setmenu-title`) and `Updates` (`.update-title`, taking its weight and ink from
    // `.set-name`) are. Four things a person can press, indistinguishable from two they cannot.
    //
    // The two headings are read off the panel rather than assumed, so a third heading added
    // later is covered by the same check instead of slipping past a hard-coded pair.
    const p = await openMenu(browser, WINDOW);
    const panel = await p.evaluate(() => {
      const menu = document.getElementById("set-menu");
      const headings = [...menu.querySelectorAll(".setmenu-title, .update-title")].map((h) => ({
        text: h.textContent.trim(),
        chevron: !!h.querySelector("svg"),
      }));
      const rows = [...menu.querySelectorAll("button.bugbtn")].map((b) => ({
        id: b.id,
        text: b.textContent.trim(),
        disclosure: b.classList.contains("bugbtn--disclosure"),
        icons: b.querySelectorAll("svg").length,
        // `aria-hidden` on the glyph: the row's own label is what a screen reader needs, and a
        // chevron announced as "chevron" is noise in a menu.
        hiddenFromReaders: [...b.querySelectorAll("svg")].every((s) => s.getAttribute("aria-hidden") === "true"),
      }));
      return { headings, rows };
    });
    const errs = p.__errors;
    await p.close();

    assert(panel.headings.length >= 2, "the panel no longer has the two headings this check is about: " +
      JSON.stringify(panel.headings));
    for (const h of panel.headings) {
      assert(!h.chevron, `the heading ${JSON.stringify(h.text)} carries a chevron, which makes it look pressable`);
    }
    const disclosures = panel.rows.filter((r) => r.disclosure);
    assertEqual(
      disclosures.map((r) => r.id).sort(),
      ["set-account-open", "set-memory-open", "set-phone-open", "set-repositories-open"],
      "THE DEFECT: the rows that open a sheet are not marked as disclosures"
    );
    for (const r of disclosures) {
      assert(r.icons === 1, `${r.id} carries ${r.icons} glyphs; a disclosure has exactly one chevron`);
      assert(r.hiddenFromReaders, `${r.id}'s chevron is not aria-hidden`);
    }
    // AND `Bust a bug!` KEEPS ITS OWN ICON AND NO CHEVRON, which is now a distinction that
    // carries information: it is the one row here that is not a disclosure.
    const bug = panel.rows.find((r) => r.id === "bug-btn");
    assert(bug && !bug.disclosure && bug.icons === 1, "the bug row changed shape: " + JSON.stringify(bug));
    assertEqual(errs, [], "the panel reported page errors");
    return `${disclosures.length} disclosure rows with a chevron each, ${panel.headings.length} headings with none ` +
      `(${panel.headings.map((h) => JSON.stringify(h.text)).join(", ")}); "Bust a bug!" keeps its own icon`;
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

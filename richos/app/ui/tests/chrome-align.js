// **THE SETTINGS BUTTON IS CENTERED WITH 15px OF RIGHT PADDING, AND THE TWO COMPOSER BUTTONS
// MATCH THE TEXT INPUT** — CEO, 2026-09-19, on the nightly he watched at 8pm the evening
// before. His screenshot is `docs/briefs/assets/ceo-2026-09-18-composer-and-settings-button.png`
// in `richos-hq`; his three arrows mark the three spots this suite measures.
//
//   *"So, if those things haven't been fixed since, then the settings button needs to be
//    properly centered vertically and the right padding for that button needs to be reduced to
//    15px. And the 2 buttons at the bottom need to be either vertically center aligned relative
//    to the text input or have the same height as the text input because otherwise it looks
//    weird."*
//
// ## THE THREE NUMBERS, MEASURED ON `f918f185` BEFORE ANY OF THIS WAS WRITTEN
//
// Read through this same WebKit, at 1024x700 and at 1400x950, identical at both:
//
//     #stage-header        top 0, bottom 52            center y = 26
//     #set-btn             top 18, bottom 58           center y = 38   -> 12px LOW
//     #set-btn right edge  1009 wanted, 1006 measured                  -> 18px of padding
//     #input-shell         46px tall, center y = 661
//     #talk-toggle / #send 40px tall, center y = 664    -> 6px SHORT and 3px LOW
//
// The settings button did not merely sit low: its box ended at y=58 against a header whose
// bottom border is at y=52, so six pixels of it hung through the line. That is the overhang his
// arrow points at, and it is the reason "properly centered" is a measurement here and not an
// opinion.
//
// ## WHICH OF HIS TWO OPTIONS THE COMPOSER TOOK, AND WHY THE SUITE ACCEPTS EITHER
//
// `style.css` takes **the same height as the text input** — the reasoning is in the comment
// above `#composer-row`, and the short version is that the field grows with what he types, so
// centering is only available in one of the composer's states while matching the height
// degrades to bottom-flush in the rest. The checks below assert **his sentence**, not that
// choice: a button passes if its center matches the field's OR its height does. A later
// redesign that centers them instead is still right by the CEO, and this suite should not be
// the thing that stops it.
//
// THE FIELD IS `#input-shell`, NOT `#input`. The box a person sees is the bordered shell (46px);
// the textarea inside it is 44px. Both are reported by every check, so a reading can never be
// ambiguous about which one it matched.
//
// ## THE NEGATIVE CONTROL IS FIRST, AND IT IS NOT A DESCRIPTION
//
// Check 1 puts the three pre-fix declarations back through the CSSOM and requires the defect to
// measure EXACTLY as it measured on `f918f185` — 12px low, 18px of padding, 6px short and 3px
// low. If that check ever comes back clean, the four after it are proving nothing and say so.
//
// Run: node chrome-align.js   (or `npm test` for every suite in this directory)

"use strict";

const path = require("path");
const {
  loadPlaywright,
  leaveHome,
  bootSettled,
  createRun,
  assert,
  assertEqual,
  SEED_THEME,
  UI_DIR,
} = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");

/// The app's own minimum, and the size it restores itself to — `window_geometry.rs`'s
/// `PREFERRED_MIN_WIDTH` / `MIN_HEIGHT`. Everything here is measured at this AND at the roomy
/// size the rest of this directory uses, because a fixed-position control is the exact shape of
/// thing that lines up at one window size and not at another.
const SMALL = { width: 1024, height: 700 };
const LARGE = { width: 1400, height: 950 };

/// His number, verbatim: the gap from the button's right edge to the right edge of the content
/// area. No tolerance — it is a declared inset, not a computed layout.
const RIGHT_PADDING = 15;

/// What `f918f185` shipped, so the negative control reproduces a geometry rather than asserting
/// one. `style.css`'s own comments carry the same three numbers.
const BEFORE = { settingsTop: 18, settingsRight: 18, controlHeight: 40 };

// ---------------------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------------------

/// The bridge wrapper `affordances.js` uses, reduced to the one thing this suite needs: an
/// override for `start_voice_capture`, which `mock.js` does not implement, so voice mode cannot
/// otherwise be reached. Everything else still goes to the real mock.
const BRIDGE_OVERRIDES = () => {
  let real = null;
  window.__overrides = {};
  Object.defineProperty(window, "RichBridge", {
    configurable: true,
    get() {
      return real;
    },
    set(v) {
      real = v;
      const origInvoke = v.invoke.bind(v);
      v.invoke = function (cmd, args) {
        if (Object.prototype.hasOwnProperty.call(window.__overrides, cmd)) {
          const o = window.__overrides[cmd];
          // `echoTurnId` is this suite's own addition to the pattern, and it is what reaches
          // the `stopping` state. `main.js`'s `stopTurn()` sets that state from `stop_turn`'s
          // RETURN and not optimistically — *"setting `stopping` from its RETURN is a
          // statement of durable fact"* — and `mock.js` does not implement `stop_turn` at all,
          // so the shipped mock answers `undefined`, `stopTurn` returns at `if (!report ||
          // !report.stopped)`, and the composer never leaves `working`. The command is called
          // with `{ expectedTurnId }`, so the durable answer it is waiting for can be built
          // from its own argument rather than from a turn id this suite would have to guess.
          if (o && o.echoTurnId) {
            return Promise.resolve({ stopped: true, turnId: args && args.expectedTurnId, reachedLease: true });
          }
          return o && o.reject ? Promise.reject(o.value) : Promise.resolve(o ? o.value : undefined);
        }
        return origInvoke(cmd, args);
      };
    },
  });
};

async function openApp(browser, viewport, theme, scale) {
  const page = await browser.newPage({ viewport, colorScheme: theme === "light" ? "light" : "dark" });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  page.__errors = errors;
  await page.addInitScript(BRIDGE_OVERRIDES);
  // THE TEXT SCALE IS SEEDED BEFORE THE THEME AND THAT ORDER IS LOAD-BEARING: `SEED_THEME`
  // merges into `richos-mock-config` and only defaults `font_scale` when it finds none, so a
  // scale written first survives it and a scale written after would be the one that survives
  // — either way one of them has to know about the other, and this is the order the helper
  // was written for.
  //
  // IT IS SEEDED AT BOOT RATHER THAN SET AFTERWARDS so that check 6 measures the CSS
  // DERIVATION on a page that has never been any other size — a scale set afterwards would
  // measure the derivation and the re-layout together and could not tell them apart. The
  // afterwards case is a defect of its own and has its own check: see check 8, Ray's R1.
  if (scale && scale !== 100) {
    await page.addInitScript((s) => {
      try {
        window.localStorage.setItem("richos-font-scale", String(s));
        let prev = {};
        try {
          prev = JSON.parse(window.localStorage.getItem("richos-mock-config")) || {};
        } catch (e) {
          prev = {};
        }
        prev.font_scale = s;
        window.localStorage.setItem("richos-mock-config", JSON.stringify(prev));
      } catch (e) {
        /* storage unavailable: the default scale applies and the check below says so */
      }
    }, scale);
  }
  // THIS SUITE STATES ITS LIGHTING EVEN THOUGH IT PHOTOGRAPHS NOTHING AND ASSERTS NO COLOR.
  // Since CEO §63 the shipped default preference is `system`, which resolves against the
  // browser context's `colorScheme` — so "said nothing" now means "followed the host". None of
  // the geometry below depends on the palette, and a check that has never been run in a stated
  // lighting cannot say that; this is how it gets to.
  await page.addInitScript(SEED_THEME, theme || "dark");
  await page.goto(APP);
  await leaveHome(page);
  await page.waitForFunction("typeof window.RichTimeline === 'object'");
  await bootSettled(page);
  return page;
}

// ---------------------------------------------------------------------------------------
// The measurement
// ---------------------------------------------------------------------------------------

/// Every box the CEO's sentence is about, in one read, plus the two derived numbers so a
/// failure message carries the arithmetic rather than the raw rectangles.
const MEASURE = `(() => {
  const box = (el) => {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return null;
    return {
      top: +r.top.toFixed(2), bottom: +r.bottom.toFixed(2),
      left: +r.left.toFixed(2), right: +r.right.toFixed(2),
      w: +r.width.toFixed(2), h: +r.height.toFixed(2),
      cy: +((r.top + r.bottom) / 2).toFixed(2),
    };
  };
  const q = (s) => box(document.querySelector(s));
  const header = q("#stage-header");
  const setbtn = q("#set-btn");
  const field = q("#input-shell");
  return {
    vw: window.innerWidth,
    vh: window.innerHeight,
    mode: document.getElementById("composer-row").getAttribute("data-mode"),
    voiceOpen: !document.getElementById("voice-panel").hidden,
    header,
    setbtn,
    settingsRightPadding: setbtn ? +(window.innerWidth - setbtn.right).toFixed(2) : null,
    settingsCenterDelta: header && setbtn ? +(setbtn.cy - header.cy).toFixed(2) : null,
    field,
    textarea: q("#input"),
    controls: ["talk-toggle", "stop", "send"].reduce((acc, id) => {
      const el = document.getElementById(id);
      const b = el && !el.hidden ? box(el) : null;
      if (b && field) acc[id] = { box: b, dCenter: +(b.cy - field.cy).toFixed(2), dHeight: +(b.h - field.h).toFixed(2),
                          dBottom: +(b.bottom - field.bottom).toFixed(2) };
      return acc;
    }, {}),
  };
})()`;

const measure = (page) => page.evaluate(MEASURE);

/// His sentence, as a predicate, per control: centered on the field OR the same height as it.
/// Tolerances are the brief's: +/-1px on a center (it is the sum of two layout computations),
/// +/-0 on a height (it is one declaration).
function holdsForControl(c) {
  return Math.abs(c.dCenter) <= 1 || c.dHeight === 0;
}

function describeControls(m) {
  return Object.keys(m.controls)
    .map((id) => {
      const c = m.controls[id];
      return `${id} ${c.box.h}px center ${c.box.cy} (dh ${c.dHeight}, dc ${c.dCenter})`;
    })
    .join("; ");
}

/// Every state of the composer his sentence has to hold in, each driven through the shipping
/// path rather than by setting an attribute — a fixture that painted the state would be proving
/// the fixture.
const STATES = {
  /// Nothing running, nothing typed. What his screenshot shows.
  async idle() {
    return "idle";
  },
  /// §9.2: a live turn with words in the box, so Stop and Send are BOTH up. The only state in
  /// which all three controls are on screen at once.
  async "working-stop-and-send"(page) {
    await page.evaluate(() => window.__RICHOS_MOCK__.simulateSlowTurn(null, "run the numbers", 200));
    await page.waitForSelector('#composer-row[data-mode="working"]');
    await page.fill("#input", "and check the Q4 line");
    await page.waitForSelector("#stop:not([hidden])");
    await page.waitForSelector("#send:not([hidden])");
    return "working, stop + send";
  },
  /// §11's `stopping`: the controls go quiet and the field does not. A disabled button is still
  /// a button in the row.
  async stopping(page) {
    await STATES["working-stop-and-send"](page);
    await page.evaluate(() => {
      window.__overrides.stop_turn = { echoTurnId: true };
    });
    await page.click("#stop");
    await page.waitForSelector('#composer-row[data-mode="stopping"]');
    return "stopping, both controls disabled";
  },
  /// Voice mode: `#composer` is replaced inline by `#voice-panel` and `#talk-toggle` is the only
  /// control left in the row. The field is gone, so this state is measured against the ROW's own
  /// height rather than against the field — see the check.
  async voice(page) {
    await page.evaluate(() => {
      window.__overrides.start_voice_capture = { value: {} };
    });
    await page.click("#talk-toggle");
    await page.waitForSelector("#voice-panel:not([hidden])");
    return "voice";
  },
};

// ---------------------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------------------

async function main() {
  const run = createRun("The settings button and the composer buttons line up (CEO, 2026-09-19)");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();

  // ---- 1. the negative control ----------------------------------------------------------
  await run.check(
    "NEGATIVE CONTROL: with the pre-fix declarations back, all three defects measure exactly as they did on f918f185",
    async () => {
      const page = await openApp(browser, SMALL);
      await page.addStyleTag({
        content:
          `.settings { top: ${BEFORE.settingsTop}px; right: ${BEFORE.settingsRight}px; }\n` +
          `#talk-toggle, #stop, #send { height: ${BEFORE.controlHeight}px; }\n`,
      });
      const m = await measure(page);
      assertEqual(m.settingsCenterDelta, 12, "the settings button is not 12px below the header's center");
      assertEqual(m.settingsRightPadding, 18, "the settings button's right padding is not the 18px that shipped");
      assert(
        m.setbtn.bottom > m.header.bottom,
        `the button no longer hangs through the header's bottom border (button ${m.setbtn.bottom}, header ${m.header.bottom})`
      );
      for (const id of Object.keys(m.controls)) {
        const c = m.controls[id];
        assertEqual(c.dHeight, -6, `${id} is not 6px shorter than the field`);
        assertEqual(c.dCenter, 3, `${id} is not 3px below the field's center`);
        assert(!holdsForControl(c), `${id} satisfies the CEO's sentence at the PRE-FIX geometry`);
      }
      await page.close();
      return (
        `settings center ${m.setbtn.cy} vs header ${m.header.cy} (+${m.settingsCenterDelta}), ` +
        `right padding ${m.settingsRightPadding}px, box ends ${m.setbtn.bottom} through a border at ${m.header.bottom}; ` +
        describeControls(m)
      );
    }
  );

  // ---- 2. the settings button, at both window sizes --------------------------------------
  for (const vp of [SMALL, LARGE]) {
    await run.check(
      `the settings button is centered in the header and 15px from the right edge, at ${vp.width}x${vp.height}`,
      async () => {
        const page = await openApp(browser, vp);
        const m = await measure(page);
        assertEqual(m.vw, vp.width, "the viewport is not the asked-for window");
        assert(m.header, "there is no #stage-header on this surface to be centered in");
        assert(
          Math.abs(m.settingsCenterDelta) <= 1,
          `the button's center is ${m.setbtn.cy} against the header's ${m.header.cy} ` +
            `(${m.settingsCenterDelta}px out; the CEO asked for properly centered)`
        );
        assertEqual(
          m.settingsRightPadding,
          RIGHT_PADDING,
          `the right padding is ${m.settingsRightPadding}px and the CEO asked for ${RIGHT_PADDING}px`
        );
        assert(
          m.setbtn.top >= m.header.top && m.setbtn.bottom <= m.header.bottom,
          `the button's box (${m.setbtn.top}..${m.setbtn.bottom}) is not inside the header's ` +
            `(${m.header.top}..${m.header.bottom}) — centered but overhanging is not centered`
        );
        assertEqual(page.__errors, [], "the page reported errors");
        await page.close();
        return (
          `header ${m.header.top}..${m.header.bottom} center ${m.header.cy}; ` +
          `button ${m.setbtn.top}..${m.setbtn.bottom} center ${m.setbtn.cy} ` +
          `(${m.settingsCenterDelta}px out); right padding ${m.settingsRightPadding}px of ${m.vw}`
        );
      }
    );
  }

  // ---- 3. the composer, in every state, at both window sizes -----------------------------
  for (const vp of [SMALL, LARGE]) {
    for (const state of ["idle", "working-stop-and-send", "stopping"]) {
      await run.check(
        `the composer buttons match the text input in the "${state}" state, at ${vp.width}x${vp.height}`,
        async () => {
          const page = await openApp(browser, vp);
          const label = await STATES[state](page);
          const m = await measure(page);
          assert(m.field, "there is no #input-shell to match");
          const ids = Object.keys(m.controls);
          assert(ids.length > 0, "no composer control is on screen in this state");
          if (state !== "idle") {
            assert(ids.includes("stop"), `the "${state}" state did not put #stop on screen`);
          }
          for (const id of ids) {
            const c = m.controls[id];
            assert(
              holdsForControl(c),
              `${id} is ${c.box.h}px against the field's ${m.field.h}px and its center is ` +
                `${c.dCenter}px from the field's — neither centered nor the same height`
            );
          }
          assertEqual(page.__errors, [], "the page reported errors");
          await page.close();
          return `${label}: field ${m.field.h}px center ${m.field.cy}; ` + describeControls(m);
        }
      );
    }
  }

  // ---- 4. voice mode ----------------------------------------------------------------------
  await run.check(
    "in voice mode the talk control keeps the field's height and the row it lives in does not move",
    async () => {
      // THE FIELD IS GONE IN THIS STATE, so there is nothing for the CEO's sentence to be
      // about — `#composer` is replaced inline by `#voice-panel` and `#talk-toggle` is the only
      // control left. What is measured instead is that the taller button did not push the
      // composer around, and it is measured as a CONTROLLED comparison: the same page, same
      // state, with the pre-fix 40px put back through the CSSOM.
      //
      // MEASURED, AND IT CORRECTED A GUESS. The guess was that the 40px talk control set the
      // voice-mode row height, so growing it to 46 would grow the row. It does not: the voice
      // panel is the tallest thing in that row at 59px, and the row reads 91px with the button
      // at 40 and 91px with it at 46. That the composer is 78px in text mode and 91px in voice
      // mode is pre-existing, is not what the CEO's sentence is about, and is untouched here.
      const page = await openApp(browser, SMALL);
      const field = (await measure(page)).field.h;
      const row = () =>
        page.evaluate(() => {
          const r = document.getElementById("composer-row").getBoundingClientRect();
          const t = document.getElementById("talk-toggle").getBoundingClientRect();
          const v = document.getElementById("voice-panel").getBoundingClientRect();
          return {
            row: +r.height.toFixed(2),
            talk: +t.height.toFixed(2),
            panel: +v.height.toFixed(2),
            talkBottom: +t.bottom.toFixed(2),
            panelBottom: +v.bottom.toFixed(2),
          };
        });
      const textMode = await row();
      await STATES.voice(page);
      const voiceMode = await row();
      assertEqual(voiceMode.talk, field, "the talk control is not the field's height in voice mode");
      assertEqual(voiceMode.talk, textMode.talk, "the talk control changed height with the mode");
      assertEqual(
        voiceMode.talkBottom,
        voiceMode.panelBottom,
        "the talk control is not flush with the bottom of the voice panel beside it"
      );
      const style = await page.addStyleTag({
        content: `#talk-toggle, #stop, #send { height: ${BEFORE.controlHeight}px; }\n`,
      });
      const asShipped = await row();
      await page.evaluate((el) => el.remove(), style);
      assertEqual(
        voiceMode.row,
        asShipped.row,
        "the taller talk control changed the height of the composer in voice mode"
      );
      assertEqual(page.__errors, [], "the page reported errors");
      await page.close();
      return (
        `text mode: row ${textMode.row}px, talk ${textMode.talk}px (field ${field}px); ` +
        `voice mode: row ${voiceMode.row}px, panel ${voiceMode.panel}px, talk ${voiceMode.talk}px flush at ${voiceMode.talkBottom}; ` +
        `same row at the pre-fix ${BEFORE.controlHeight}px: ${asShipped.row}px`
      );
    }
  );

  // ---- 5. the field when it grows ---------------------------------------------------------
  await run.check(
    "when the field grows past one line the buttons stay flush with its bottom edge",
    async () => {
      // THE DOCUMENTED DEGRADATION OF THE OPTION THIS FILE TOOK, asserted rather than left to
      // be discovered. "Same height as the text input" is a statement about the resting field;
      // `#input` grows to `max-height: 112px` with what he types, and `align-items: flex-end`
      // is what keeps the two controls beside the LAST line rather than beside the middle. So
      // the promise in this state is bottom-flush, and this check holds it to that.
      const page = await openApp(browser, SMALL);
      const restingField = (await measure(page)).field.h;
      await page.fill("#input", "one\ntwo\nthree\nfour\nfive\nsix");
      await page.evaluate(() => {
        const i = document.getElementById("input");
        i.dispatchEvent(new Event("input", { bubbles: true }));
      });
      await page.waitForFunction(
        (h) => document.getElementById("input-shell").getBoundingClientRect().height > h,
        restingField
      );
      const m = await measure(page);
      assert(m.field.h > restingField, `the field did not grow (still ${m.field.h}px)`);
      for (const id of Object.keys(m.controls)) {
        const c = m.controls[id];
        assertEqual(c.dBottom, 0, `${id}'s bottom edge is ${c.dBottom}px from the grown field's`);
      }
      assertEqual(page.__errors, [], "the page reported errors");
      await page.close();
      return (
        `field grew ${restingField}px -> ${m.field.h}px; ` +
        Object.keys(m.controls)
          .map((id) => `${id} bottom ${m.controls[id].dBottom}px from the field's`)
          .join("; ")
      );
    }
  );

  // ---- 6. the derivation, not the number ---------------------------------------------------
  await run.check(
    "at 120% text size the buttons still track the field, so the match is derived and not a typed 46",
    async () => {
      // `--app-font-scale` multiplies the root font size and every size in `style.css` is rem,
      // so a button whose height was TYPED as `46px` would come apart from the field by 4px the
      // moment the CEO used the Text size row. That is what `--control-h:
      // calc(var(--field-h) + 2px)` exists to prevent, and this is the check that would catch
      // it: 120 is a real step in `RichTheme.STEPS` ([80, 90, 100, 110, 120, 135, 150]).
      //
      // THE TOLERANCE HERE IS 1px AND EVERY OTHER CHECK'S IS 0, WHICH IS A MEASUREMENT AND NOT
      // A CONCESSION. `main.js`'s `autoGrow()` writes the field's height inline from
      // `scrollHeight`, which is an INTEGER; the stylesheet's calc keeps the fraction. At 110%
      // the field reads 48px and the buttons 48.39px. At 100% — the default, and what the CEO
      // was looking at — both are exactly 46 and the other checks hold them to that.
      const page = await openApp(browser, SMALL, "dark", 120);
      const scale = await page.evaluate(() => window.RichTheme.scale());
      assertEqual(scale, 120, "the seeded text scale did not take, so this check is a re-run of the default");
      const m = await measure(page);
      assert(
        m.field.h > 46,
        `the field did not respond to the text scale (${m.field.h}px, same as the default)`
      );
      for (const id of Object.keys(m.controls)) {
        const c = m.controls[id];
        assert(
          Math.abs(c.dHeight) <= 1,
          `${id} came apart from the field at 120%: ${c.box.h}px against ${m.field.h}px`
        );
        assert(
          c.box.h > 46,
          `${id} is still ${c.box.h}px at 120%, so its height is typed rather than derived`
        );
      }
      assertEqual(page.__errors, [], "the page reported errors");
      await page.close();
      return `at 120%: field ${m.field.h}px (46 at the default); ` + describeControls(m);
    }
  );

  // ---- 7. the settings menu still hangs from the button it moved with ----------------------
  await run.check(
    "the settings menu's anchor follows the button to 54px, which is what its max-height is derived from",
    async () => {
      // `settings-fit.js` owns the FIT of that panel; this check owns the JOIN between the two
      // numbers, because the panel's `max-height: calc(100vh - 72px)` is derived from this
      // button's `top` and would have gone quietly stale when the button moved.
      const page = await openApp(browser, SMALL);
      await page.click("#set-btn");
      await page.waitForSelector("#set-menu", { state: "visible" });
      await page.evaluate(async () => {
        const m = document.getElementById("set-menu");
        if (m) await Promise.all(m.getAnimations({ subtree: true }).map((a) => a.finished.catch(() => {})));
      });
      const g = await page.evaluate(() => {
        const b = document.getElementById("set-btn").getBoundingClientRect();
        const m = document.getElementById("set-menu").getBoundingClientRect();
        return {
          btnBottom: Math.round(b.bottom),
          menuTop: Math.round(m.top),
          menuBottom: Math.round(m.bottom),
          vh: window.innerHeight,
        };
      });
      assertEqual(g.menuTop, 54, "the panel's anchor is not the 54px style.css derives the 72px bound from");
      assertEqual(g.menuTop - g.btnBottom, 8, "the panel no longer hangs 8px below the button");
      assert(g.menuBottom <= g.vh, `the panel ends at ${g.menuBottom} in a ${g.vh}px window`);
      assertEqual(page.__errors, [], "the page reported errors");
      await page.close();
      return `button ends ${g.btnBottom}, panel top ${g.menuTop} (8px below), bottom ${g.menuBottom} of ${g.vh}`;
    }
  );

  // ---- 8. the Text size row, used the way he uses it ---------------------------------------
  await run.check(
    "changing the text size keeps the field and its buttons the same height, in BOTH directions",
    async () => {
      // **RAY'S CANDIDATE .13, DEFECT R1**, and it is the CEO's own sentence breaking at the one
      // moment he is looking hardest at the composer. Measured by Ray at 5x, both themes, both
      // window sizes:
      //
      //     100% -> 110%   buttons 48px, field stays 46
      //     110% -> 100%   field stays 48, buttons drop to 46
      //     one character typed -> they agree again, 48/48 then 46/46
      //
      // The mechanism: `style.css` derives `--control-h` from `--field-h` and every size is rem
      // off a root the scale multiplies, so the BUTTONS follow on their own. The field does not,
      // because `main.js`'s `autoGrow()` writes its height INLINE in pixels and none of its call
      // sites was a scale change — they are all keystrokes, sends, restored drafts and thread
      // openings. Check 6 above cannot see this: it seeds the scale before boot, so there is no
      // stale inline declaration to survive.
      //
      // DRIVEN THROUGH THE ROW HE ACTUALLY USES — the settings button, then `#font-up` /
      // `#font-down` — rather than by calling `RichTheme.setScale`, because the defect is about
      // what happens when the product changes its own scale.
      const page = await openApp(browser, SMALL);
      const step = async (id) => {
        await page.click("#set-btn");
        await page.waitForSelector("#set-menu", { state: "visible" });
        await page.click(id);
        await page.keyboard.press("Escape");
        await page.waitForSelector("#set-menu", { state: "hidden" });
        // Two frames: one for the root's new font size to lay out, one for anything answering it.
        await page.evaluate(
          () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
        );
        return measure(page);
      };

      const start = await measure(page);
      assertEqual(await page.evaluate(() => window.RichTheme.scale()), 100, "this page did not start at 100%");

      const bigger = await step("#font-up");
      assertEqual(await page.evaluate(() => window.RichTheme.scale()), 110, "the + control did not move the scale");
      assert(
        bigger.field.h > start.field.h,
        `the field did not follow the text size at all (${start.field.h}px -> ${bigger.field.h}px) — ` +
          "it is stuck at the height autoGrow() wrote before the change"
      );
      for (const id of Object.keys(bigger.controls)) {
        const c = bigger.controls[id];
        assert(
          holdsForControl(c),
          `LARGER: ${id} is ${c.box.h}px against the field's ${bigger.field.h}px (dh ${c.dHeight}, dc ${c.dCenter}) — ` +
            "neither centered nor the same height, which is the CEO's sentence broken"
        );
      }

      // AND BACK DOWN, because Ray measured the defect in both directions and the shrinking one
      // is the half where the FIELD is the taller of the two.
      const back = await step("#font-down");
      assertEqual(await page.evaluate(() => window.RichTheme.scale()), 100, "the − control did not move the scale back");
      assertEqual(
        back.field.h,
        start.field.h,
        `the field did not come back to its resting height (${start.field.h}px -> ${back.field.h}px)`
      );
      for (const id of Object.keys(back.controls)) {
        const c = back.controls[id];
        assert(
          holdsForControl(c),
          `SMALLER: ${id} is ${c.box.h}px against the field's ${back.field.h}px (dh ${c.dHeight}, dc ${c.dCenter})`
        );
      }
      assertEqual(page.__errors, [], "the page reported errors");
      await page.close();
      return (
        `100% field ${start.field.h}px; 110% field ${bigger.field.h}px, ${describeControls(bigger)}; ` +
        `back at 100% field ${back.field.h}px, ${describeControls(back)}`
      );
    }
  );

  await browser.close();
  // `report()` returns the FAILED COUNT, not a verdict. Same form as every other suite here.
  process.exit(run.report() > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error(e && e.stack ? e.stack : e);
  process.exit(1);
});

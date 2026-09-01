// TWO LIGHTINGS, ONE TYPE KNOB, AND THE PERSON AT THE FOOT OF THE RAIL.
//
// CEO rulings §14 and §15 (`richos-hq/wiki/ceo-decisions.md`), plus his correction to round
// 10.1. Five things are asserted here that nothing else in this directory can assert,
// because each of them is a claim about the SHIPPING shell rather than about a module:
//
//   1. DARK IS THE DEFAULT — "a newly installed app opens dark" — and it is the default
//      against a LIGHT operating system. That last clause is the whole check: a build that
//      resolved `system` by default would look correct on the CEO's machine and would hand
//      a ruling he made to a setting he did not.
//   2. THE PREFERENCE IS DURABLE, and config.rs wins any disagreement with the pre-paint
//      mirror. The mirror exists only because an async read cannot decide the first frame;
//      the moment it can also DECIDE something, there are two places the answer lives.
//   3. THE OPENING SCREEN IS ALWAYS DARK AND THE BUTTON IS ON IT ANYWAY. §15's one permanent
//      exception and its floor, together, because they are only meaningful together: the
//      switch is the part that can be absent, and "Bust a bug" never is.
//   4. ONE STATE, TWO ENTRANCES, for the font size and for Techy Mode. A settings row and a
//      keyboard shortcut that agree most of the time are two states, and the failure is
//      silent.
//   5. THE FOOT OF THE RAIL IS HIS. Initials and a name — and when there is no name, an
//      honest empty state rather than an invented one or a "??".
//
// WHAT THIS SUITE DELIBERATELY DOES NOT CLAIM. It runs in WebKit under Playwright, not in
// the Tauri shell, so it cannot prove that macOS itself leaves ⌘+ alone. What it CAN prove
// is the two halves that are actually ours: that the page handler calls `preventDefault`
// (check 8), and that `zoomHotkeysEnabled` is `false` in the shipped `tauri.conf.json`
// (check 9) — which is the flag that would otherwise inject a webview zoom polyfill on
// macOS and Linux and set WebView2's `IsZoomControlEnabled` on Windows. The remaining gap —
// a native menu item binding the same accelerator — is stated in the handoff rather than
// papered over. There is no menu in this app today and check 9 is what would notice one
// arriving with a zoom item attached.
//
// EVERY CHECK HERE WAS RUN RED ONCE by breaking the shipped source; the mutations are listed
// against their check numbers at the bottom of this file.
//
// Run: node appearance.js   (or `npm test` for every suite in this directory)
//      RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node appearance.js

"use strict";

const fs = require("fs");
const path = require("path");
const { loadPlaywright, shot, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");
const SHOTS = "../shots-10-1";
const STYLE_CSS = fs.readFileSync(path.join(UI_DIR, "style.css"), "utf8");
const INDEX_HTML = fs.readFileSync(path.join(UI_DIR, "index.html"), "utf8");
const TAURI_CONF = JSON.parse(
  fs.readFileSync(path.resolve(UI_DIR, "..", "src-tauri", "tauri.conf.json"), "utf8")
);
const CONFIG_RS = fs.readFileSync(
  path.resolve(UI_DIR, "..", "crates", "richos-core", "src", "config.rs"),
  "utf8"
);

/// The steps the control walks, read out of the Rust rather than typed here. A ladder
/// changed on one side only reaches this file as a failing check instead of as a `+` that
/// lands somewhere the store will snap away from.
function rustFontSteps() {
  const m = CONFIG_RS.match(/pub const FONT_SCALE_STEPS: \[u16; \d+\] = \[([^\]]+)\]/);
  assert(m, "no FONT_SCALE_STEPS in config.rs");
  return m[1].split(",").map((s) => Number(s.trim()));
}

/// Open the app. `stored` is what the DURABLE side already holds — seeded into the mock
/// harness's own key, which is the thing `get_appearance` answers from, not into the
/// pre-paint mirror. Seeding the mirror alone proves nothing: `syncAppearanceFromBackend`
/// would overwrite it a moment later, which is the product working correctly.
async function openApp(browser, opts) {
  opts = opts || {};
  const page = await browser.newPage({
    viewport: { width: 1400, height: 950 },
    // A LIGHT operating system, on purpose and in every single walk below. Every "it opened
    // dark" in this file is therefore a statement about the ruling and not about the host.
    colorScheme: opts.osScheme || "light",
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.addInitScript(() => {
    // CAPTURE THE FIRST PAINT'S THEME, before anything can correct it.
    //
    // `theme-boot.js` runs in `<head>` and sets `data-theme` synchronously; `main.js`
    // reconciles against the store a few hundred ms later. Sampling after settle therefore
    // says nothing about the FIRST FRAME — and the first frame is the entire reason
    // theme-boot.js exists. An observer installed before any of it runs records the value
    // the CEO's eye actually meets, which is where a full-screen flash of the wrong palette
    // would show up and nowhere else.
    window.__firstTheme = null;
    const capture = () => {
      if (window.__firstTheme === null && document.documentElement) {
        window.__firstTheme = document.documentElement.getAttribute("data-theme");
      }
    };
    // Observing `document` with `subtree` rather than `documentElement` directly: at
    // init-script time the document is empty and `documentElement` can still be null, and an
    // observer attached to null never fires — which reads exactly like "the theme was never
    // set" and is the first thing this check got wrong about itself.
    new MutationObserver(capture).observe(document, {
      attributes: true,
      subtree: true,
      attributeFilter: ["data-theme"],
    });
    // Belt: `readyState === "interactive"` is after every synchronous script (theme-boot.js
    // among them) and before main.js's async reconciliation, so it is still the pre-settle
    // value even if the observer misses.
    document.addEventListener("readystatechange", capture, true);
    document.addEventListener("DOMContentLoaded", capture, true);
  });
  await page.addInitScript((o) => {
    try {
      if (o.stored) window.localStorage.setItem("richos-mock-config", JSON.stringify(o.stored));
      if (o.mirror) window.localStorage.setItem("richos-theme", o.mirror);
      if (o.mirrorScale) window.localStorage.setItem("richos-font-scale", String(o.mirrorScale));
    } catch (e) {
      /* storage unavailable — the shipped defaults apply, which is its own kind of evidence */
    }
    if (o.holdSplash) {
      // Neuter the yield before splash.js finishes installing itself, exactly as
      // contrast.js does. The composition renders precisely as it ships.
      let real;
      Object.defineProperty(window, "RichSplash", {
        configurable: true,
        get: () => real,
        set: (v) => {
          real = v;
          if (v && typeof v.yieldNow === "function") v.yieldNow = function () {};
        },
      });
    }
  }, opts);
  await page.goto(APP);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  if (!opts.holdSplash) {
    await page.waitForFunction(() => !document.getElementById("splash"), { timeout: 15000 }).catch(() => {});
  }
  await page.waitForTimeout(400);
  page.__errors = errors;
  return page;
}

const themeOf = (page) => page.evaluate(() => document.documentElement.getAttribute("data-theme"));
const menuRows = (page) =>
  page.evaluate(() =>
    [...document.querySelectorAll("#set-menu > *")].map((n) =>
      n.querySelector(".set-name") ? n.querySelector(".set-name").textContent.trim() : n.textContent.trim()
    )
  );

async function openMenu(page) {
  await page.click("#set-btn");
  await page.waitForSelector("#set-menu", { state: "visible" });
  await page.waitForTimeout(150);
}

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("Appearance — two lightings, one type knob, and whose rail this is");
  const allErrors = [];
  const track = (p) => {
    allErrors.push(...(p.__errors || []));
    return p;
  };

  // ---- 1. dark is the default, and it is the default against a LIGHT OS -----------------

  await run.check("1  a fresh install opens DARK, under a light operating system", async () => {
    const page = track(await openApp(browser, { osScheme: "light" }));
    const theme = await themeOf(page);
    assertEqual(theme, "dark", "§15: 'a newly installed app opens dark'");
    const pref = await page.evaluate(() => window.RichTheme.theme());
    assertEqual(pref, "dark", "and the stored PREFERENCE is dark, not 'system' resolved to dark");
    const ground = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    assertEqual(ground, "rgb(12, 19, 34)", "painted on the §14 ground, not merely labelled dark");
    // ...and it was dark in the FIRST frame, not corrected into dark afterwards. This is the
    // half that a settled sample cannot see: a pre-paint default of `system` under a light
    // OS gives a full-screen flash of ivory on every launch and then quietly settles right.
    const first = await page.evaluate(() => window.__firstTheme);
    assertEqual(
      first,
      "dark",
      "the FIRST painted theme was " + first + " — theme-boot.js's synchronous default is not dark, " +
        "so every launch flashes the wrong palette before settling"
    );
    await page.close();
    return "no stored preference + a light OS -> first paint dark, settled dark, pref=dark, body #0C1322";
  });

  // ---- 2. durable, and the backend wins ------------------------------------------------

  await run.check("2  the choice is durable, and config.rs wins a disagreement with the mirror", async () => {
    // The store says LIGHT; the pre-paint mirror says DARK. This is a real shape — a
    // preference set on a launch whose mirror was later cleared, or two windows. The first
    // frame is the mirror's (it is all that exists synchronously) and the settled answer
    // must be the STORE's, because a mirror that can win is a second place the decision
    // lives and the CEO's preference starts flipping between launches.
    const page = track(
      await openApp(browser, {
        stored: { theme: "light", font_scale: 100, user_name: null },
        mirror: "dark",
      })
    );
    assertEqual(await themeOf(page), "light", "the durable answer won");
    const mirrored = await page.evaluate(() => {
      try {
        return window.localStorage.getItem("richos-theme");
      } catch (e) {
        return null;
      }
    });
    assertEqual(mirrored, "light", "and the mirror was CORRECTED, not left disagreeing");
    await page.close();
    return "store=light vs mirror=dark -> light wins and the mirror is rewritten to match";
  });

  await run.check("3  switching the theme writes through to the durable store", async () => {
    const page = track(await openApp(browser));
    await openMenu(page);
    await page.click('.theme-opt[data-th="light"]');
    await page.waitForTimeout(300);
    assertEqual(await themeOf(page), "light", "the document crossed over");
    const stored = await page.evaluate(() => JSON.parse(window.localStorage.getItem("richos-mock-config")));
    assertEqual(stored.theme, "light", "and the STORE holds it, not just the mirror");
    const pressed = await page.evaluate(() =>
      [...document.querySelectorAll(".theme-opt")].map((b) => b.dataset.th + ":" + b.getAttribute("aria-pressed"))
    );
    assertEqual(
      pressed,
      ["light:true", "system:false", "dark:false"],
      "and the ported segment reports its state through aria-pressed, as the reference does"
    );
    await page.close();
    return "the segment writes to config.rs and reports itself through aria-pressed";
  });

  // ---- 4-6. the always-dark opening screen, and the floor -------------------------------

  await run.check("4  the opening screen is ALWAYS dark, even for a CEO who chose light", async () => {
    const page = track(
      await openApp(browser, {
        stored: { theme: "light", font_scale: 100, user_name: null },
        mirror: "light",
        holdSplash: true,
      })
    );
    assert(await page.evaluate(() => !!document.getElementById("splash")), "the curtain is up for this walk");
    assertEqual(await themeOf(page), "dark", "§15's one permanent exception");
    // ...and his own preference is UNTOUCHED, which is what makes it a clamp and not a write.
    assertEqual(
      await page.evaluate(() => window.RichTheme.theme()),
      "light",
      "the clamp must not overwrite what he chose — light has to still be there afterwards"
    );
    await page.close();
    return "pref stays light, the resolved theme is dark, and nothing was written";
  });

  await run.check("5  the settings button is ON the opening screen, with NO theme switch", async () => {
    const page = track(
      await openApp(browser, {
        stored: { theme: "light", font_scale: 100, user_name: null },
        holdSplash: true,
      })
    );
    assert(await page.locator("#set-btn").isVisible(), "the button is there — it is on every screen, no exception");
    await openMenu(page);
    const opts = await page.evaluate(() => document.querySelectorAll(".theme-opt").length);
    assertEqual(opts, 0, "no switch reaches the start screen — and it is OMITTED, not disabled");
    assert(
      await page.locator("#bug-btn").isVisible(),
      "...and the floor is intact: 'the very least that settings button always provides is a quick access to Bust a bug'"
    );
    const s = await shot(page, SHOTS + "/10-1-start-screen-always-dark", { fullPage: false });
    await page.close();
    return "button present, 0 theme options, Bust a bug reachable — " + path.basename(s.file);
  });

  await run.check("6  reporting a bug from the opening screen does not leave the opening screen", async () => {
    // The ruling's reason, not just its letter: "reporting a bug must never require
    // navigating away from the screen the bug is on", and the screen a first-run user is
    // most likely to be stuck on is the one the curtain is covering. splash.js dismisses on
    // first input, so touching the settings button had to stop counting as first input.
    const page = track(await openApp(browser, { holdSplash: true }));
    await openMenu(page);
    assert(await page.evaluate(() => !!document.getElementById("splash")), "opening the menu did not lift the curtain");
    await page.click("#bug-btn");
    await page.waitForTimeout(300);
    const after = await page.evaluate(() => ({
      splash: !!document.getElementById("splash"),
      toast: (document.getElementById("bug-toast") || {}).textContent || "",
    }));
    assert(after.splash, "and neither did pressing Bust a bug");
    assert(after.toast.length > 20, "something acknowledged it — a control that appears to do nothing reads as broken");
    // ...while an ordinary click still dismisses, exactly as it did before.
    await page.mouse.click(700, 400);
    await page.waitForTimeout(900);
    assert(
      await page.evaluate(() => !document.getElementById("splash")),
      "the first-input dismissal is otherwise UNCHANGED — the exception is exactly one control wide"
    );
    await page.close();
    return "the curtain survives the settings button and Bust a bug, and still yields to any other input";
  });

  // ---- 7. the button is everywhere, above everything ------------------------------------

  await run.check("7  the settings button is on every surface, above every overlay", async () => {
    const surfaces = [
      ["shell", async () => {}],
      ["thread", async (p) => { await p.click('.nav-thread[data-thread-id="hiring"]'); await p.waitForSelector(".tl-turn"); }],
      ["corrections", async (p) => { await p.click("#nav-corrections"); await p.waitForSelector("#corrections-overlay:not([hidden])"); }],
      ["feedback", async (p) => { await p.click("#nav-feedback"); await p.waitForTimeout(300); }],
      ["search", async (p) => { await p.click("#nav-search"); await p.waitForTimeout(250); }],
      ["preferences", async (p) => { await p.click("#rail-settings"); await p.waitForSelector("#assertiveness-popover", { state: "visible" }); }],
    ];
    const report = [];
    for (const [name, drive] of surfaces) {
      const page = track(await openApp(browser));
      await drive(page);
      await page.waitForTimeout(250);
      // Visible is not enough. ON TOP is the claim — §15 says "above every overlay" — so
      // this is a hit test at the button's own centre, which is what a pointer would do.
      const onTop = await page.evaluate(() => {
        const b = document.getElementById("set-btn");
        if (!b) return "MISSING";
        const r = b.getBoundingClientRect();
        const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        return hit && hit.closest(".settings") ? "ON-TOP" : "COVERED by " + (hit ? hit.tagName + "." + hit.className : "nothing");
      });
      assertEqual(onTop, "ON-TOP", "the settings button is not reachable on the " + name + " surface");
      report.push(name);
      await page.close();
    }

    // AND THE ONE SURFACE A HIT TEST CANNOT SPEAK FOR. The opening screen's curtain is
    // `pointer-events: none` for its whole life, so `elementFromPoint` walks straight
    // through it and returns the button whether the button is above the curtain or buried
    // under it. The hit test would pass over a settings button that was invisible — which
    // is the single most important place for it not to be, since §15's floor exists for
    // exactly the screen a first-run user is stuck on.
    //
    // So this half is structural: `.settings` must out-rank EVERY other z-index the app
    // ships, computed from the stylesheets rather than compared against a number typed
    // here. A new overlay that outranks it fails this check on the day it lands.
    const css = [
      fs.readFileSync(path.join(UI_DIR, "style.css"), "utf8"),
      fs.readFileSync(path.join(UI_DIR, "splash.css"), "utf8"),
    ].join("\n");
    // The COMPONENT is `.settings` plus the toast its Bust a bug raises; both belong to it
    // and the toast is deliberately the higher of the two, so neither is measured against
    // the other. Everything else in the app is.
    const zOf = (sel) => Number(css.match(new RegExp(sel + "\\s*\\{[^}]*z-index:\\s*(\\d+)"))[1]);
    const settingsZ = zOf("\\.settings");
    const toastZ = zOf("#bug-toast");
    const others = [...css.matchAll(/z-index:\s*(\d+)/g)]
      .map((m) => Number(m[1]))
      .filter((z) => z !== settingsZ && z !== toastZ);
    const highest = Math.max(...others);
    assert(
      settingsZ > highest,
      "`.settings` is z-index " + settingsZ + " and something else in the shipped CSS is " +
        highest + ". §15 says the button is above EVERY overlay; the opening screen's curtain " +
        "alone is 200, and a curtain painted over the settings button satisfies the letter of " +
        "'it is on every page' and none of its point."
    );
    assert(
      toastZ >= settingsZ,
      "the Bust a bug toast (" + toastZ + ") is below the button that raises it (" + settingsZ + ")"
    );
    return report.length + " surfaces, the button hit-testable on every one (" + report.join(", ") +
      "); and z-index " + settingsZ + " out-ranks every other z-index shipped (highest other: " + highest + ")";
  });

  // ---- 8. the menu's contents, in §15's order ------------------------------------------

  await run.check("8  the menu is theme, then Text size, then Techy Mode, then the floor", async () => {
    const page = track(await openApp(browser));
    await openMenu(page);
    const rows = await menuRows(page);
    assertEqual(
      rows,
      ["Theme", "Text size", "Techy Mode", "Opening screen", "Company", "Updates", "Bust a bug!"],
      "§15 fixes the first three: Text size 'directly under the theme switch', and 'directly under " +
        "that, a Techy Mode toggle'. The opening screen's off switch sits below them — that ruling " +
        "governs their order and says nothing about this one — and Bust a bug is always the floor. " +
        "Updates (RICH-TODOs row 12) was added on 2026-08-31 BELOW all four and ABOVE the floor, for " +
        "the same reason the opening-screen row sits where it does: the ruling does not name it, and " +
        "the floor stays the floor. Company (2026-09-01, the entity picker's durable half) went in " +
        "at the same rank and for the same reason, above Updates because it is a preference and " +
        "Updates is a status panel."
    );
    await page.close();
    return rows.join(" -> ");
  });

  // ---- 9-11. one state, two entrances -------------------------------------------------

  await run.check("9  the accelerator is the APP's — preventDefault, and it moves the stored number", async () => {
    const page = track(await openApp(browser));
    const steps = rustFontSteps();
    const before = await page.evaluate(() => window.RichTheme.scale());
    assertEqual(before, 100, "starts at the size the type scale is authored at");

    // Did the PAGE take the keystroke? If it did not call preventDefault, the webview's own
    // zoom is free to run: it would scale the whole document including fixed chrome, would
    // not persist, and would be invisible to the Text size row.
    const prevented = await page.evaluate(() => {
      let seen = null;
      const spy = (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "=") seen = e.defaultPrevented;
      };
      window.addEventListener("keyup", () => {}, false);
      document.addEventListener("keydown", spy, false);
      window.__readPrevented = () => seen;
      return true;
    });
    assert(prevented, "spy installed");
    await page.keyboard.down("Meta");
    await page.keyboard.press("=");
    await page.keyboard.up("Meta");
    await page.waitForTimeout(200);
    assertEqual(
      await page.evaluate(() => window.__readPrevented()),
      true,
      "the app did NOT call preventDefault on ⌘= — the webview's zoom is free to run and the two controls will disagree"
    );

    const after = await page.evaluate(() => window.RichTheme.scale());
    assertEqual(after, steps[steps.indexOf(100) + 1], "one step up the ladder config.rs declares");
    const root = await page.evaluate(() => getComputedStyle(document.documentElement).fontSize);
    assertEqual(root, 16 * (after / 100) + "px", "and the ROOT font size followed: 16 x " + after + "/100");
    const stored = await page.evaluate(() => JSON.parse(window.localStorage.getItem("richos-mock-config")));
    assertEqual(stored.font_scale, after, "...and it is durable, not just painted");

    await page.keyboard.down("Meta");
    await page.keyboard.press("0");
    await page.keyboard.up("Meta");
    await page.waitForTimeout(200);
    assertEqual(await page.evaluate(() => window.RichTheme.scale()), 100, "⌘0 resets");
    await page.close();
    return "⌘= 100 -> " + after + "% (root " + root + "), durable, and ⌘0 resets";
  });

  await run.check("10  the Text size row and the shortcut are ONE state, not two that agree", async () => {
    const page = track(await openApp(browser));
    await openMenu(page);
    await page.click("#font-up");
    await page.waitForTimeout(200);
    const viaRow = await page.evaluate(() => ({
      scale: window.RichTheme.scale(),
      reading: document.getElementById("font-val").textContent,
    }));
    assertEqual(viaRow.reading, viaRow.scale + "%", "the row shows what the state is");

    // Now move it by KEYSTROKE while the row is on screen. A second state would not follow.
    await page.keyboard.down("Meta");
    await page.keyboard.press("-");
    await page.keyboard.up("Meta");
    await page.waitForTimeout(200);
    const after = await page.evaluate(() => ({
      scale: window.RichTheme.scale(),
      reading: document.getElementById("font-val").textContent,
    }));
    assertEqual(after.scale, 100, "the keystroke moved it back down");
    assertEqual(after.reading, "100%", "and the ROW followed the keystroke — one state, two entrances");
    await page.close();
    return "row 100->110 by click, 110->100 by ⌘-, and the row's reading tracked both";
  });

  await run.check("11  Techy Mode: the menu row and the rail preference are ONE state", async () => {
    const page = track(await openApp(browser));
    await openMenu(page);
    await page.click("#set-techy");
    await page.waitForTimeout(700);
    await page.click("#rail-settings");
    await page.waitForSelector("#assertiveness-popover", { state: "visible" });
    assertEqual(
      await page.evaluate(() => document.getElementById("techy-default").checked),
      true,
      "the rail's own preference followed the menu"
    );
    // ...and back the other way, which is the direction a one-way binding still passes.
    await page.click("#techy-default");
    await page.waitForTimeout(700);
    await page.click("#rail-settings");
    await openMenu(page);
    assertEqual(
      await page.evaluate(() => document.getElementById("set-techy").checked),
      false,
      "and the menu followed the rail — a binding that only works one way is two states with a lag"
    );
    await page.close();
    return "menu -> rail, and rail -> menu, both observed";
  });

  await run.check("11b  the splash off switch survived the rebuild, and is ONE state behind two doors", async () => {
    // A GUARD-RAIL, not a feature. The gear popover has carried this switch since the
    // opening screen shipped, and the CEO restated on 2026-08-31 that turning the splash off
    // from settings is a requirement. This build rebuilt the settings menu around three new
    // rows, and the way a control dies in a rebuild is that nobody was asserting it was
    // still there. Now something is.
    const page = track(await openApp(browser));
    assert(
      await page.locator("#splash-enabled").count(),
      "the gear popover's own splash switch is GONE — it was not mine to remove and nothing moved it"
    );
    await openMenu(page);
    assert(
      await page.locator("#set-splash").count(),
      "the settings button does not offer the splash switch, and 'from settings' is the CEO's word"
    );
    const both = () =>
      page.evaluate(() => ({
        menu: document.getElementById("set-splash").checked,
        gear: document.getElementById("splash-enabled").checked,
      }));
    assertEqual(await both(), { menu: true, gear: true }, "both start on, which is the shipped default");

    await page.click("#set-splash");
    await page.waitForTimeout(400);
    await page.click("#rail-settings");
    await page.waitForSelector("#assertiveness-popover", { state: "visible" });
    assertEqual(await both(), { menu: false, gear: false }, "the gear followed the menu");

    await page.click("#splash-enabled");
    await page.waitForTimeout(400);
    await page.click("#rail-settings");
    await openMenu(page);
    assertEqual(await both(), { menu: true, gear: true }, "and the menu followed the gear");

    // The mirror is what splash.js reads synchronously on the NEXT launch, before there is a
    // bridge to ask. A switch that only reached the durable store would look right all
    // session and do nothing at the one moment it exists for.
    const mirrored = await page.evaluate(() => window.localStorage.getItem("richos.splash.enabled"));
    assert(mirrored !== "false", "the local mirror disagrees with the switches: " + mirrored);
    await page.close();
    return "present in both places, both directions observed, and the mirror splash.js reads agrees";
  });

  // ---- 12-13. the type scale itself ------------------------------------------------------

  await run.check("12  every font-size in the shipped CSS is rem, so one knob moves all of it", async () => {
    // The knob multiplies the ROOT font size. A surviving `px` font-size is a node that
    // silently refuses to scale, and it is invisible until someone with poor eyesight is
    // looking at the one line that did not grow.
    const px = [...STYLE_CSS.matchAll(/font-size:\s*([0-9.]+)px/g)].map((m) => m[0]);
    assertEqual(
      px.filter((d) => !/font-size:\s*14px/.test(d) && !/font-size:\s*12px/.test(d)),
      [],
      "px font-sizes in style.css outside the two glyph-box exemptions"
    );
    // The two that remain are fixed-size icon boxes with no text of their own, and the
    // reference this component was ported from documents why they are authored in px.
    const glyphBoxes = px.length;
    assert(glyphBoxes <= 2, "only the ported component's two glyph boxes may be px: found " + glyphBoxes);
    assert(
      /font-size:\s*calc\(16px \* var\(--app-font-scale/.test(STYLE_CSS),
      "the root font size is not driven by --app-font-scale, so nothing scales"
    );
    return px.length + " px font-size(s) left, both fixed glyph boxes; every other size is rem off a scaled root";
  });

  await run.check("13  the whole interface scales, not a subset of it", async () => {
    const page = track(await openApp(browser));
    const sample = () =>
      page.evaluate(() => {
        const g = (sel) => {
          const e = document.querySelector(sel);
          return e ? parseFloat(getComputedStyle(e).fontSize) : null;
        };
        return { prose: g(".tl-prose"), rail: g(".nav-thread"), kbd: g(".rail-kbd"), group: g(".nav-group-label") };
      });
    const at100 = await sample();
    assertEqual(at100.prose, 18, "§15: Rich's prose is 18px at 100%");
    assert(at100.rail >= 16, "the readable floor is 16px — the rail thread title is " + at100.rail);
    assert(at100.kbd >= 14, "the skippable floor is 14px — the ⌘K keycap is " + at100.kbd);

    await page.keyboard.down("Meta");
    await page.keyboard.press("=");
    await page.keyboard.up("Meta");
    await page.waitForTimeout(250);
    const at110 = await sample();
    for (const k of Object.keys(at100)) {
      assert(
        Math.abs(at110[k] - at100[k] * 1.1) < 0.05,
        k + " did not scale with the knob: " + at100[k] + " -> " + at110[k] + ", expected " + at100[k] * 1.1
      );
    }
    await page.close();
    return "at 100%: prose 18, rail " + at100.rail + ", keycap " + at100.kbd +
      "; at 110% every one of the four moved by exactly 1.1x";
  });

  // ---- 14. the accelerator is claimed in the shell, not merely by the page ---------------

  await run.check("14  the Tauri shell does not hand ⌘+/- to the webview", async () => {
    const win = (TAURI_CONF.app.windows || [])[0] || {};
    assertEqual(
      win.zoomHotkeysEnabled,
      false,
      "`zoomHotkeysEnabled` must be present and false in tauri.conf.json. It is the seam: with it " +
        "on, Tauri injects a webview zoom polyfill on macOS/Linux and sets WebView2's " +
        "IsZoomControlEnabled on Windows — a second, non-persistent font size the Text size row " +
        "knows nothing about. Its DEFAULT is already false; it is written down so that it is a " +
        "decision rather than a default nobody chose."
    );
    return "zoomHotkeysEnabled: false, claimed explicitly rather than inherited";
  });

  // ---- 15-16. the wordmark, and whose rail this is ---------------------------------------

  await run.check("15  the wordmark replaced 'My Company', and carries the approved treatment", async () => {
    assert(
      /id="rail-wordmark"/.test(INDEX_HTML),
      "the wordmark is not in the rail header"
    );
    const page = track(await openApp(browser));
    const dark = await page.evaluate(() => {
      const w = document.getElementById("rail-wordmark");
      const c = document.getElementById("rail-company");
      return {
        wordmarkVisible: !!w && w.getBoundingClientRect().width > 0,
        label: w ? w.getAttribute("aria-label") : null,
        ink: w ? getComputedStyle(w).color : null,
        // THE SWOOSH. The mark is two-tone by the approved treatment (round-8.1/v0 dark,
        // round-9/v1 light): ink letterforms, signal swoosh. It shipped as a KNOCK-OUT
        // painted `var(--rail-bg)`, which made the app's mark monochrome while the standard
        // it is drawn from has gold in it, and that is exactly what this check exists to
        // stop happening twice.
        swoosh: w ? getComputedStyle(w.querySelector("#arrow")).fill : null,
        companyRendered: !!c && c.getBoundingClientRect().width > 0,
      };
    });
    assert(dark.wordmarkVisible, "the mark does not render");
    assertEqual(dark.label, "RichOS", "and it is announced, since it is an image carrying a name");
    assertEqual(dark.companyRendered, false, "'My Company' must no longer be rendered here (§15)");
    assertEqual(dark.ink, "rgb(223, 228, 238)", "inked with the dark theme's own ink");
    assertEqual(
      dark.swoosh, "rgb(194, 163, 92)",
      "the swoosh inside the R is the ruled signal #C2A35C, not a knock-out — 7.88:1 on the " +
        "dark rail, non-text floor 3:1"
    );
    await openMenu(page);
    await page.click('.theme-opt[data-th="light"]');
    await page.waitForTimeout(350);
    const light = await page.evaluate(() => {
      const w = document.getElementById("rail-wordmark");
      return {
        ink: getComputedStyle(w).color,
        swoosh: getComputedStyle(w.querySelector("#arrow")).fill,
      };
    });
    assertEqual(light.ink, "rgb(12, 19, 34)", "and re-inked when the theme crosses over");
    // THE EXPECTATION FOLLOWS THE RULING, and it did not for one commit. 6fd6fe7 restored
    // the CEO ruled light signal in `index.html` and rewrote this assertion PROSE to say so,
    // but left the VALUE at the struck-darker one the ruling replaced — so main shipped a
    // check asserting a value the app no longer draws, and a value the lead has since said
    // is gone from the whole app. #9C7C34 is rgb(156, 124, 52).
    assertEqual(
      light.swoosh, "rgb(156, 124, 52)",
      "and the swoosh crosses over too — the CEO ruled light signal #9C7C34, which is what " +
        "index.html sets and what the shipped light asset carries."
    );
    await page.close();
    return "wordmark present and announced; company label gone; ink #DFE4EE -> #0C1322 and " +
      "swoosh #C2A35C -> #9C7C34 across the theme";
  });

  await run.check("16  the foot of the rail is HIS — and says nothing it does not know", async () => {
    // The CEO's correction to round 10.1, and the honest-unset half is the load-bearing one:
    // there was no user-name preference in this product until today, so this is the state
    // almost every install is in.
    const page = track(await openApp(browser));
    const unset = await page.evaluate(() => {
      const row = document.getElementById("rail-identity");
      return {
        isUnset: row.classList.contains("is-unset"),
        initials: document.getElementById("rail-initials").textContent,
        label: document.getElementById("rail-user-name").textContent,
        richLabelGone: !document.querySelector(".rail-rich-label"),
      };
    });
    assert(unset.isUnset, "a fresh install has no name and must say so");
    assertEqual(unset.initials, "", "the circle carries NO letters — not invented ones, and not '??'");
    assert(!/\?\?/.test(unset.label), "and the label is not '??' either: " + unset.label);
    assertEqual(unset.label, "Set your name", "it says what is true, and it is an offer rather than a dead end");
    assert(unset.richLabelGone, "Rich's nameplate is gone from the CEO's own rail");

    await page.click("#rail-identity");
    await page.waitForSelector("#assertiveness-popover", { state: "visible" });
    await page.fill("#user-name-input", "Alex Booster");
    await page.dispatchEvent("#user-name-input", "change");
    await page.waitForTimeout(400);
    const named = await page.evaluate(() => ({
      isUnset: document.getElementById("rail-identity").classList.contains("is-unset"),
      initials: document.getElementById("rail-initials").textContent,
      label: document.getElementById("rail-user-name").textContent,
    }));
    assertEqual(named.initials, "AB", "first and last, two letters — the pattern his Codex app uses");
    assertEqual(named.label, "Alex Booster", "with the name beside it");
    assertEqual(named.isUnset, false, "and the row stops being an offer once it is a nameplate");
    await page.close();
    return "unset: empty circle + 'Set your name'; named: AB + Alex Booster";
  });

  // ---- 17. the evidence ------------------------------------------------------------------

  await run.check("17  every surface, photographed in BOTH themes", async () => {
    const surfaces = [
      ["conversation", async (p) => { await p.click('.nav-thread[data-thread-id="hiring"]'); await p.waitForSelector(".tl-turn"); }],
      ["corrections", async (p) => { await p.click("#nav-corrections"); await p.waitForSelector("#corrections-overlay:not([hidden])"); }],
      ["feedback", async (p) => { await p.click("#nav-feedback"); await p.waitForTimeout(400); }],
      ["search", async (p) => { await p.click("#nav-search"); await p.waitForTimeout(300); }],
      ["preferences", async (p) => { await p.click("#rail-settings"); await p.waitForSelector("#assertiveness-popover", { state: "visible" }); }],
      ["settings-menu", async (p) => { await openMenu(p); }],
    ];
    const made = [];
    for (const theme of ["dark", "light"]) {
      for (const [name, drive] of surfaces) {
        const page = track(
          await openApp(browser, {
            stored: { theme, font_scale: 100, user_name: "Alex Booster" },
            mirror: theme,
          })
        );
        assertEqual(await themeOf(page), theme, name + " did not open in the theme it is labelled with");
        await drive(page);
        await page.waitForTimeout(350);
        const s = await shot(page, SHOTS + "/10-1-" + name + "-" + theme, { fullPage: false });
        made.push(path.basename(s.file));
        await page.close();
      }
    }
    assertEqual(made.length, 12, "six surfaces, two themes");
    return made.length + " shots: " + made.join(", ");
  });

  await run.check("18  no page errors anywhere in this suite", async () => {
    assertEqual(allErrors, [], "uncaught errors or console errors during the walks above");
    return allErrors.length + " uncaught errors, " + allErrors.length + " console errors";
  });

  await browser.close();
  const failed = run.report();
  if (failed) {
    console.error("\n" + failed + " check(s) FAILED.");
    process.exit(1);
  }
  console.log("\ntwo lightings, one knob, and the rail is his.");
}

main().catch((e) => {
  console.error(e && e.stack ? e.stack : e);
  process.exit(1);
});

// ---------------------------------------------------------------------------------------
// THE MUTATIONS — every check above was run RED by breaking the shipped source. Each line
// is a mutation that was actually applied and the checks it actually turned red.
// ---------------------------------------------------------------------------------------
//
//  1   theme-boot.js: the pre-paint default `|| "dark"` -> `|| "system"` -> check 1. This is
//      the FIRST-FRAME half: under a light OS the launch flashes ivory and then settles to
//      dark, which no settled sample can see. It is why check 1 captures `data-theme` from a
//      MutationObserver installed before any page script rather than reading it at the end.
//  1b  mock.js: the store's shipped default `theme: "dark"` -> `"light"` -> checks 1, 3, 15.
//      The SETTLED half, and the one that stands in for `Theme::default()` in config.rs.
//  2   main.js `syncAppearanceFromBackend`: drop `RichTheme.sync(durable)` -> check 2. The
//      mirror wins, and a preference set on another launch is silently lost.
//  3   settings-button.js `applyTheme`: `if (T.setTheme(pref)) saveTheme(pref)` ->
//      `T.setTheme(pref)` -> check 3. The theme changes on screen and dies at the next
//      launch: the failure a screenshot cannot see.
//  4   splash.js `start()`: delete `RichTheme.forceDark(true)` -> checks 4 and 5. A CEO on
//      light mode gets an ivory settings button floating on a midnight composition.
//  5   settings-button.js `buildMenu`: `if (!T.forcedDark())` -> always append the theme row
//      -> check 5. A theme switch on the one screen the ruling says no switch reaches.
//  6   splash.js `onInput`: drop the `.closest(".settings")` guard -> checks 5 and 6.
//      Opening the settings menu dismisses the curtain, so a bug report started from the
//      opening screen captures the shell instead — exactly what §15 says must never be
//      required.
//  7   style.css `.settings`: `z-index: 300` -> `100` -> check 7.
//      AND THIS ONE TAUGHT THE CHECK SOMETHING. The first version of check 7 was a hit test
//      on six surfaces, and this mutation did NOT turn it red: 100 still clears the app's
//      overlays (60/70), and the opening screen's curtain is `pointer-events: none`, so
//      `elementFromPoint` walks straight through it and returns the button whether the
//      button is above the curtain or buried under it. A hit test cannot speak for the one
//      surface that matters most. Check 7 gained a structural half — `.settings` must
//      out-rank every z-index the app ships, computed from the stylesheets — and the
//      mutation now fires. It also immediately found that `#bug-toast` is 301, which is
//      correct and is why the component's own two layers are excluded from the comparison
//      rather than from the rule.
//  8   settings-button.js `buildMenu`: append the Techy row before the font row -> check 8.
//      §15 says Text size sits "directly under the theme switch", and it is one line to get
//      wrong.
//  9   settings-button.js keydown: drop `e.preventDefault()` from the `+`/`=` arm -> check 9.
//      The scale still moves, so every other check stays green; what changes is that the
//      webview's own zoom is free to run underneath it.
//  10  settings-button.js `mount`: disable the `T.onChange(...)` subscription -> checks 3
//      and 10. The menu stops tracking state moved by anything but its own buttons.
//      THIS ONE ALSO CHANGED THE SOURCE. The first attempt was "delete the `paint()` inside
//      `stepFont`", and it did not turn anything red — because `T.stepScale` paints and
//      notifies, and this file is a subscriber, so that call was dead code that LOOKED
//      load-bearing. It is now deleted from `stepFont`, `resetFont` and `applyTheme`, and
//      the subscription is the single path, which is what makes check 10 able to fail.
//  12  style.css `.rail-company`: `1rem` -> `13px` -> check 12.
//  12b style.css `html`: `calc(16px * var(--app-font-scale, 1))` -> `16px` -> checks 9, 12,
//      13. Every size is still rem and NONE of them moves — the failure that looks most
//      like success.
//  13  style.css `.tl-prose`: `1.125rem` -> `1rem` -> check 13. Rich's answers back below
//      the CEO's stated 18px default.
//  14a tauri.conf.json: `"zoomHotkeysEnabled": true` -> check 14.
//  14b tauri.conf.json: delete the key entirely -> check 14. An absent key is an undecided
//      one even when its default happens to be the right answer.
//  15  style.css `.rail-wordmark`: `color: var(--ink)` -> `color: #dfe4ee` -> check 15. It
//      looks perfect in dark and stays near-white on the ivory rail in light.
//  15b index.html: un-hide `<span id="rail-company">` -> check 15. "My Company" is back in
//      the corner §15 gave to the wordmark.
//  16  main.js `renderUserIdentity`: initials `|| "??"` and a label of "User" -> check 16.
//      Both halves of the thing the CEO's correction explicitly forbids.
//  17  this file: seed every shot walk with `theme: "dark"` -> check 17. Twelve files claim
//      to show two themes while showing one.
//
// THE RUST HALF — `Theme::default()` being Dark, an absent key reading as dark rather than
// as a choice, the font ladder snapping instead of resetting, and `initials_from` returning
// `None` rather than a guess — is in `crates/richos-core/src/config.rs`, with its own eight
// mutations recorded in this branch's commit messages. The one worth repeating here is that
// a single test which set BOTH the theme and the scale passed even with `set_theme`'s
// `persist()` removed, because `persist()` rewrites the whole file and the scale's write
// carried the unpersisted theme to disk on its behalf. It is now two tests with one setter
// each.

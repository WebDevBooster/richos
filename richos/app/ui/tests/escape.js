// ESCAPE CLOSES EVERY POPUP — the CEO's rule, enforced against the real window.
//
// CEO, 2026-09-17, item 1 of his v1.0.2 list, verbatim:
//
//     "The user must always be able to close any popup of any kind by simply tapping the
//      escape key on the keyboard i.e. without having to click anything"
//
// WHAT HE HAD INSTEAD, measured on richos 7088a57f before this suite existed: `main.js`
// handled Escape for eight named surfaces, and the window ships more than eight. The gear's
// preferences popover — `#assertiveness-popover`, the most-used popup in the product — was
// not one of them. `#setup-sheet`, `#memory-setup`, `#set-menu`, `#permission-sheet`,
// `#repositories-sheet` and `#home-prefs` were not either; three of those carried their own
// Escape listener bound to the popup ELEMENT, so each worked only while focus happened to be
// inside it, and `#home-prefs` on a copy with no companies focused nothing at all and so
// could not be closed from the keyboard under any circumstances.
//
// SO THIS SUITE DOES NOT CARRY A LIST. Every check below derives its surfaces from
// `window.RichDismiss.selector` — the same query the shipped handler enumerates with — so a
// popup written next month is under these checks the day it is written, with nothing for its
// author to remember. Part A refuses a structurally-a-popup element that declares no
// dismissal, and its positive control plants one to prove the refusal fires.
//
// TWO VOCABULARY WORDS, both on the element, both the product's:
//
//   data-dismiss="escape"          Escape closes it outright, through the surface's own
//                                  close function.
//   data-dismiss="control:#a,#b"   Escape does exactly what the first of those controls that
//                                  is on screen and enabled does — and NOTHING when none of
//                                  them is. That is how `#setup-sheet` keeps 704b4596's
//                                  invariant (it cannot be dismissed into a dead app
//                                  mid-install) while still answering the CEO's rule the rest
//                                  of the time: Escape is the named way out, reached by the
//                                  keyboard, never a second quieter one.
//
// Cases:
//   A1  every popup in the booted window declares how it is dismissed
//   A2  positive control — an undeclared popup makes A1 red
//   B1  every declared surface answers Escape, with focus OUTSIDE it   [derived]
//   B2  the gear's preferences popover, by the real path
//   B3  the settings menu, by the real path
//   B4  topmost first, measured against the stacking rather than a chosen order
//   B5  a permission request is DECLINED by Escape from anywhere on screen
//   B6  the home screen's own dialog, on a copy with no companies
//   C1  Escape with nothing open moves nothing and steals no key
//   C2  this suite actually checked something
//
// Run: node escape.js   (or `npm test` for every suite in this directory)

"use strict";

const path = require("path");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR, leaveHome } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");

async function openApp(browser, preset) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 950 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  if (preset) {
    await page.addInitScript((v) => {
      window.__RICHOS_MOCK_PRESET__ = v;
    }, preset);
  }
  await page.goto(APP);
  await leaveHome(page);
  await page.waitForFunction(() => typeof window.RichDismiss === "object");
  page.__errors = errors;
  return page;
}

/// Put the hand somewhere that is NOT inside the popup under test. This is the condition the
/// three element-bound Escape listeners failed under, so every check in part B starts here.
async function focusTheComposer(page) {
  await page.evaluate(() => {
    const input = document.getElementById("input");
    if (input) input.focus();
    else document.body.focus();
  });
}

async function main() {
  const run = createRun("Escape closes every popup of every kind (CEO 2026-09-17, item 1)");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  let assertions = 0;
  const bump = (n) => {
    assertions += n;
    return n;
  };

  // =======================================================================================
  // A — THE DECLARATION. A popup that says nothing about how it closes is a defect.
  // =======================================================================================

  await run.check("A1  every popup in the booted window declares how it is dismissed", async () => {
    const page = await openApp(browser);
    // Everything the boot can create, created: the settings menu is built lazily by the file
    // that owns it, and a surface that does not exist yet cannot be scanned.
    await page.evaluate(() => {
      if (window.RichSettings && window.RichSettings.openMenu) window.RichSettings.openMenu();
    });
    const undeclared = await page.evaluate(() => {
      window.RichDismiss.open(); // stamps the external declarations, changes nothing on screen
      const out = [];
      for (const node of document.querySelectorAll(window.RichDismiss.selector)) {
        if (!node.closest("[data-dismiss]")) {
          out.push(node.id || node.tagName.toLowerCase() + "." + node.className);
        }
      }
      return out;
    });
    assertEqual(
      undeclared,
      [],
      "these are popups by structure and declare no `data-dismiss`, so Escape can only fall " +
        "back to hiding them with none of their own cleanup"
    );
    const declared = await page.evaluate(() =>
      [...document.querySelectorAll("[data-dismiss]")].map((n) => n.id).sort()
    );
    // The floor is the count at the time this was written: ten in `index.html`, the settings
    // menu, and the two sheets built by their own files. A change that DROPS declarations is
    // the regression this number catches; adding more is free.
    assert(
      declared.length >= 13,
      "only " + declared.length + " declared surfaces: " + declared.join(", ")
    );
    // ...and the ones the old eight-line handler never covered are among them, by name,
    // because those are the popups the CEO actually hit.
    for (const id of [
      "assertiveness-popover",
      "setup-sheet",
      "memory-setup",
      "set-menu",
      "permission-sheet",
      "repositories-sheet",
    ]) {
      assert(declared.indexOf(id) >= 0, "#" + id + " is still outside the enumeration");
    }
    bump(8);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return declared.length + " surfaces, every one of them declared: " + declared.join(", ");
  });

  await run.check("A2  positive control — an undeclared popup makes A1 red", async () => {
    const page = await openApp(browser);
    // A1's own scan, run against a window with a popup somebody added and did not declare.
    // If this comes back empty, A1 cannot fail and is decoration.
    const found = await page.evaluate(() => {
      const planted = document.createElement("div");
      planted.id = "planted-popup";
      planted.className = "overlay";
      planted.setAttribute("role", "dialog");
      document.body.appendChild(planted);
      window.RichDismiss.open();
      return [...document.querySelectorAll(window.RichDismiss.selector)]
        .filter((n) => !n.closest("[data-dismiss]"))
        .map((n) => n.id);
    });
    assertEqual(found, ["planted-popup"], "the declaration scan did not see an undeclared popup");
    // AND IT STILL CLOSES. The scan is what makes the omission visible; the CEO's rule has no
    // "unless somebody forgot" in it, so the handler's blunt fallback has to carry the day.
    await focusTheComposer(page);
    await page.keyboard.press("Escape");
    assert(await page.isHidden("#planted-popup"), "an undeclared popup survived Escape");
    bump(2);
    await page.close();
    return "an undeclared popup is reported by A1's scan, and still closes";
  });

  // =======================================================================================
  // B — WHAT IT DOES, from a hand that is not already inside the popup
  // =======================================================================================

  await run.check("B1  every declared surface answers Escape, with focus outside it", async () => {
    const page = await openApp(browser);
    const surfaces = await page.evaluate(() =>
      [...document.querySelectorAll("[data-dismiss]")].map((n) => ({
        id: n.id,
        spec: n.getAttribute("data-dismiss"),
      }))
    );
    assert(surfaces.length >= 11, "only " + surfaces.length + " surfaces were derived");
    const report = [];
    for (const surface of surfaces) {
      // OPENED BY UN-HIDING IT, deliberately. Every surface has its own entrance and several
      // need a backend state to reach; what is under test is the handler's reaction to a
      // popup being ON SCREEN, which is the one thing they all share. The real entrances are
      // B2, B3, B5 and B6, and `setup.js` case 14.
      await page.evaluate((s) => {
        const node = document.getElementById(s.id);
        node.hidden = false;
        window.__escapeClicked = null;
        if (s.spec.indexOf("control:") === 0) {
          for (const sel of s.spec.slice("control:".length).split(",")) {
            const control = document.querySelector(sel.trim());
            if (!control) continue;
            control.hidden = false;
            control.disabled = false;
            control.addEventListener(
              "click",
              () => {
                window.__escapeClicked = control.id;
              },
              { once: true }
            );
            break;
          }
        }
      }, surface);
      await focusTheComposer(page);
      await page.keyboard.press("Escape");
      if (surface.spec.indexOf("control:") === 0) {
        // The contract for these is not "it went away" — it is "Escape did what the named
        // control does". Asserting the click is what makes that exact rather than similar.
        const clicked = await page.evaluate(() => window.__escapeClicked);
        assert(
          clicked !== null,
          "#" + surface.id + " declares " + surface.spec + " and Escape pressed none of them"
        );
        report.push(surface.id + "→" + clicked);
      } else {
        assert(
          await page.isHidden("#" + surface.id),
          "#" + surface.id + " survived Escape from outside it"
        );
        report.push(surface.id);
      }
      bump(1);
      // Leave the window closed whatever the surface did, so the next one is measured alone.
      await page.evaluate((id) => {
        document.getElementById(id).hidden = true;
      }, surface.id);
    }
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return surfaces.length + " derived surfaces, all closed by Escape: " + report.join(", ");
  });

  await run.check("B2  the gear's preferences popover, by the real path", async () => {
    const page = await openApp(browser);
    await page.click("#rail-settings");
    await page.waitForSelector("#assertiveness-popover:not([hidden])");
    await focusTheComposer(page);
    await page.keyboard.press("Escape");
    assert(
      await page.isHidden("#assertiveness-popover"),
      "the popup the CEO opens most often still cannot be closed with Escape"
    );
    // The gear must not go on announcing a popover that is not there.
    assertEqual(
      await page.getAttribute("#rail-settings", "aria-expanded"),
      "false",
      "the gear still reports itself expanded"
    );
    bump(2);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "opened from the gear, closed by Escape, and the gear says so";
  });

  await run.check("B3  the settings menu, by the real path", async () => {
    const page = await openApp(browser);
    await page.click("#set-btn");
    await page.waitForSelector("#set-menu:not([hidden])");
    await focusTheComposer(page);
    await page.keyboard.press("Escape");
    assert(await page.isHidden("#set-menu"), "the settings menu survived Escape");
    assertEqual(
      await page.getAttribute("#set-btn", "aria-expanded"),
      "false",
      "the settings button still reports itself expanded"
    );
    bump(2);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "closed once, and the button's state came with it";
  });

  await run.check("B4  topmost first, measured against the stacking", async () => {
    const page = await openApp(browser);
    // `#inspector` is z-index 20 and `#search-overlay` is 60, so the overlay is painted over
    // the panel and must be the one Escape takes. The order is READ from the stylesheet here
    // rather than asserted from the handler's source, so a restyle that reverses them fails.
    const stack = await page.evaluate(() => {
      document.getElementById("inspector").hidden = false;
      document.getElementById("search-overlay").hidden = false;
      const z = (id) =>
        Number.parseInt(window.getComputedStyle(document.getElementById(id)).zIndex, 10) || 0;
      return { inspector: z("inspector"), search: z("search-overlay") };
    });
    assert(
      stack.search > stack.inspector,
      "this check assumes the overlay is painted above the panel: " + JSON.stringify(stack)
    );
    await focusTheComposer(page);
    await page.keyboard.press("Escape");
    assert(await page.isHidden("#search-overlay"), "the topmost surface was not the one closed");
    assert(
      await page.isVisible("#inspector"),
      "one Escape closed two surfaces — a keypress must undo one thing"
    );
    await focusTheComposer(page);
    await page.keyboard.press("Escape");
    assert(await page.isHidden("#inspector"), "the second Escape did not reach the panel below");
    bump(4);
    await page.close();
    return "z-index " + stack.search + " before " + stack.inspector + ", one surface per press";
  });

  await run.check("B5  a permission request is declined by Escape from anywhere", async () => {
    const page = await openApp(browser);
    await page.evaluate(() => {
      window.__RICHOS_MOCK_PRESET__ = {
        pendingPermission: {
          id: "escape-suite",
          binding: { entity_id: "depot" },
          tool: "Write",
          input: { file_path: "/fictional/one.txt" },
          description: "Write one fictional file",
        },
      };
    });
    await page.waitForSelector("#permission-sheet:not([hidden])");
    // THE CONDITION THE ELEMENT-BOUND LISTENER FAILED UNDER. `permissions.js` puts the hand on
    // Decline when it opens; one click on the dimmed area beside the panel takes it off again,
    // and from there its own keydown handler never fired.
    await focusTheComposer(page);
    await page.keyboard.press("Escape");
    await page.waitForSelector("#permission-sheet", { state: "hidden" });
    // AND IT WAS ANSWERED, not merely hidden. A permission question that vanishes without an
    // answer is the one outcome this sheet may never have.
    assertEqual(
      await page.evaluate(() => window.__RICHOS_MOCK_PRESET__.permissionAnswer),
      false,
      "Escape hid the request without declining it"
    );
    bump(2);
    await page.close();
    return "declined, from a hand that was nowhere near the panel";
  });

  await run.check("B6  the home screen's own dialog, on a copy with no companies", async () => {
    const page = await openApp(browser);
    await page.evaluate(() => window.RichSettings.openMenu());
    await page.click("#set-home-open");
    await page.waitForSelector("#home-prefs:not([hidden])");
    // `home.js` focuses the first company row, which does not exist on the paint that opens
    // this sheet — so its own wrapper-bound Escape listener never got a keystroke at all.
    await focusTheComposer(page);
    await page.keyboard.press("Escape");
    await page.waitForSelector("#home-prefs", { state: "hidden" });
    assert(await page.isHidden("#home-prefs"), "the home dialog survived Escape");
    // ITS SCRIM WENT WITH IT. Hiding the inner panel alone would leave the dimmed sheet over
    // the whole window with nothing on it, which is worse than not closing at all.
    assert(
      await page.isHidden(".home-prefs-scrim"),
      "the panel closed and left its scrim over the window"
    );
    bump(2);
    await page.close();
    return "closed, scrim and all, on the copy where its own listener could never fire";
  });

  // =======================================================================================
  // C — AND IT TAKES NOTHING IT WAS NOT GIVEN
  // =======================================================================================

  await run.check("C1  Escape with nothing open moves nothing and steals no key", async () => {
    const page = await openApp(browser);
    await page.fill("#input", "book the Acme call for Thursday");
    await focusTheComposer(page);
    const before = await page.evaluate(() => window.RichDismiss.open().length);
    assertEqual(before, 0, "something was already on screen, so this proves nothing");
    await page.keyboard.press("Escape");
    assertEqual(
      await page.inputValue("#input"),
      "book the Acme call for Thursday",
      "Escape with nothing open touched what he was typing"
    );
    assertEqual(
      await page.evaluate(() => document.activeElement && document.activeElement.id),
      "input",
      "Escape with nothing open moved the hand"
    );
    bump(3);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "nothing open, nothing moved";
  });

  await run.check("C2  this suite actually checked something", async () => {
    assert(
      assertions >= 25,
      "only " + assertions + " assertions ran. A suite that verifies little and reports green " +
        "is the failure this repository has caught three times."
    );
    return assertions + " assertions against the real DOM under WebKit";
  });

  await browser.close();
  const failed = run.report();
  console.log(
    failed
      ? "\n" + failed + " check(s) FAILED"
      : "\nevery popup in the window closes on Escape, and the next one will too."
  );
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

// ---------------------------------------------------------------------------------------
// RUN RED — the mutation that makes each check fail, applied to the SHIPPED source
// ---------------------------------------------------------------------------------------
//
// A1   index.html: delete `data-dismiss="escape"` from #assertiveness-popover
//        -> "these are popups by structure and declare no `data-dismiss`" names it
// A2   main.js `dismissTopmostPopup`: delete the `top.hidden = true` fallback
//        -> an undeclared popup survives Escape, which is the CEO's rule failing quietly
// B1   main.js: restore the eight-line `if (!someEl.hidden) return closeSomething()` chain
//        -> #assertiveness-popover, #setup-sheet, #memory-setup, #set-menu, #permission-sheet
//           and #repositories-sheet all survive Escape
// B2   main.js `POPUP_CLOSERS`: drop the "assertiveness-popover" entry
//        -> the popover is hidden by the blunt fallback and the gear keeps aria-expanded=true
// B4   main.js `openPopups`: sort ascending instead of descending
//        -> one Escape reaches the panel underneath and leaves the overlay on top of it
// B5   permissions.js: drop the `data-dismiss` attribute
//        -> the sheet is unreachable from the keyboard unless focus is already inside it,
//           which is exactly the published behavior
// B6   main.js: empty `EXTERNAL_DISMISS`
//        -> #home-prefs-panel is hidden and its scrim is left over the whole window
// C1   main.js: make `dismissTopmostPopup` return true unconditionally
//        -> Escape starts eating keystrokes with nothing on screen

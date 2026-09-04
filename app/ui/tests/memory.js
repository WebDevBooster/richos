// FIRST-RUN PROVISIONING, AT THE SURFACE — the click the CEO makes, and everything it must
// and must not do.
//
// WHY THIS SUITE EXISTS. RichOS is installed, signed, and reaches the CEO's memory only
// because an engineer typed a symlink by hand. Measured on 2026-09-01, with the pointer
// removed and put straight back (`docs/verification/first-run-provisioning-2026-09-01/`):
// the app boots saying "no corpus configured", names three candidates, and nothing in the
// product creates any of them. The Rust half of the fix is proved by
// `cargo run --example first_run_demo` on a clean HOME and by 20 unit tests. This file is
// the other half: the question on screen, and the one press that answers it.
//
// WHAT IT HOLDS, and each is a clause of the contract rather than a nicety:
//
//   1. A fresh install ASKS, and asks THIS question first — one dialog at a time, with the
//      company question held back rather than stacked or dropped.
//   2. THE LOCATION IS SHOWN AND IS WHAT GETS SENT. The string the window displays and the
//      string the command receives are compared byte for byte. His part is a choice about a
//      location he can see; it is never a path he types, and the surface never composes a
//      second opinion about where his record goes.
//   3. NO SILENT DEFAULT REACHES THE COMMAND. There is exactly one `provision_memory` call
//      site in the shipped source and it passes the offered location; a build that lost the
//      argument would send nothing, and the backend refuses that by name.
//   4. A REFUSAL REACHES THE SCREEN. `provision`'s messages are written for a human and
//      each names the thing to do, so they are rendered as they stand, never swallowed.
//   5. A CORPUS IT CANNOT READ IS ITS OWN STATE, with the party named and no button drawn
//      for a thing no button could do.
//   6. AN INSTALL THAT IS ALREADY SET UP IS NEVER ASKED.
//
// Run: node memory.js   (or `npm test` for every suite in this directory)

"use strict";

const fs = require("fs");
const path = require("path");
const { leaveHome, loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");
const MAIN_JS = fs.readFileSync(path.join(UI_DIR, "main.js"), "utf8");

/// Open the shell with a preset, recording every `invoke` the page makes so the ARGUMENTS a
/// click produces can be read rather than inferred from what changed on screen.
async function openApp(browser, preset, resolveOverrides) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 950 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.addInitScript(() => {
    let real = null;
    window.__calls = [];
    window.__reject = {};
    window.__resolve = window.__resolve || {};
    Object.defineProperty(window, "RichBridge", {
      configurable: true,
      get() {
        return real;
      },
      set(v) {
        real = v;
        const origInvoke = v.invoke.bind(v);
        v.invoke = function (cmd, args) {
          window.__calls.push({ cmd, args });
          if (Object.prototype.hasOwnProperty.call(window.__reject, cmd))
            return Promise.reject(window.__reject[cmd]);
          if (Object.prototype.hasOwnProperty.call(window.__resolve, cmd))
            return Promise.resolve(window.__resolve[cmd]);
          return origInvoke(cmd, args);
        };
      },
    });
  });
  if (resolveOverrides) {
    await page.addInitScript((v) => {
      window.__resolve = v;
    }, resolveOverrides);
  }
  if (preset) {
    await page.addInitScript((v) => {
      window.__RICHOS_MOCK_PRESET__ = v;
    }, preset);
  }
  await page.goto(APP);
  // The home screen is the landing surface now; this suite is about the app UI behind it.
  await leaveHome(page);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

const dialogText = (page) =>
  page.evaluate(() =>
    (document.getElementById("memory-setup").innerText || "").replace(/\s+/g, " ").trim()
  );

async function main() {
  const run = createRun("first-run provisioning — the question a fresh install asks, and the one click that answers it");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  let assertions = 0;
  const bump = (n) => {
    assertions += n;
    return n;
  };

  await run.check("1  a fresh install asks, and asks this before the company question", async () => {
    const page = await openApp(browser, { memory: "none", chosenEntity: null });
    await page.waitForSelector("#memory-setup:not([hidden])");
    assert(await page.isVisible("#memory-setup"), "a machine with no memory must be asked");
    assert(
      await page.isHidden("#entity-picker"),
      "two modal dialogs at once — the company picker must be held back, not stacked"
    );
    // AND HELD BACK IS NOT DROPPED: dismissing this one asks that one.
    await page.click("#memory-setup-later");
    await page.waitForSelector("#entity-picker:not([hidden])");
    assert(await page.isHidden("#memory-setup"), "the memory dialog stays closed once dismissed");
    bump(4);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "asked first, one at a time, and the second question survives the first being answered";
  });

  await run.check("2  the location is SHOWN, and is exactly what the command is given", async () => {
    // A LOCATION THE SURFACE COULD NOT HAVE GUESSED. The mock's own offer is
    // `/Users/you/RichOS/corpus`, which is also what a hard-coded path would say — so a
    // build that ignored the backend and wrote the path itself would pass against it. This
    // one comes from nowhere but the command's answer.
    const offered = "/Volumes/Archive/somewhere else/corpus";
    const page = await openApp(
      browser,
      { memory: "none" },
      { memory_status: { state: "none", root: null, source: null, compiler: null, tried: [], detail: null, offered_location: offered, provisioned_now: false } }
    );
    await page.waitForSelector("#memory-setup:not([hidden])");
    const shown = (await page.textContent("#memory-setup-location")).trim();
    assertEqual(shown, offered, "the window must show the location the backend offered");
    assert(shown.length > 0, "a location he cannot see is a location he cannot accept");
    assert(shown.startsWith("/"), "the location must be a full path: " + shown);
    // No text input anywhere in this dialog. His part is a choice, never a path he types.
    assertEqual(
      await page.$$eval("#memory-setup input, #memory-setup textarea", (n) => n.length),
      0,
      "the CEO must never be asked to type a path"
    );
    await page.click("#memory-setup-go");
    await page.waitForFunction(() =>
      window.__calls.some((c) => c.cmd === "provision_memory")
    );
    const call = await page.evaluate(() => window.__calls.find((c) => c.cmd === "provision_memory"));
    assertEqual(call.args.location, shown, "the string sent must be the string he was shown");
    bump(5);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "shown " + JSON.stringify(shown) + ", sent byte-identical, and no field to type into";
  });

  await run.check("3  one press, and it says the thing is done", async () => {
    const page = await openApp(browser, { memory: "none" });
    await page.waitForSelector("#memory-setup:not([hidden])");
    await page.click("#memory-setup-go");
    await page.waitForFunction(() =>
      (document.getElementById("memory-setup-note").textContent || "").indexOf("That's set up") === 0
    );
    const text = await dialogText(page);
    assert(text.indexOf("That's set up") >= 0, text);
    assert(await page.isHidden("#memory-setup-go"), "nothing left to set up, so nothing offers to");
    assert(await page.isVisible("#memory-setup-close"), "a finished dialog needs a way out");
    // ONE PRESS. Not two, not a wizard.
    const provisionCalls = await page.evaluate(
      () => window.__calls.filter((c) => c.cmd === "provision_memory").length
    );
    assertEqual(provisionCalls, 1, "his whole part is one click");
    bump(4);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "1 click -> 1 command -> \"That's set up.\"";
  });

  await run.check("4  a refusal reaches the screen, as it stands", async () => {
    // `provision`'s refusals are written for a human and each names the thing to do — "that
    // folder already exists and has things in it that are not a corpus". Paraphrasing one
    // would throw the instruction away; swallowing one is what `affordances.js` exists to
    // forbid.
    const refusal =
      "/Users/you/RichOS/corpus already exists and has things in it that are not a corpus. " +
      "Refusing to write a record into somebody else's folder.";
    const page = await openApp(browser, { memory: "none" });
    await page.waitForSelector("#memory-setup:not([hidden])");
    await page.evaluate((r) => {
      window.__reject.provision_memory = r;
    }, refusal);
    await page.click("#memory-setup-go");
    await page.waitForFunction(
      (r) => document.getElementById("memory-setup-note").textContent === r,
      refusal
    );
    assert(await page.isVisible("#memory-setup-go"), "a refusal must leave the control usable");
    assertEqual(await page.isDisabled("#memory-setup-go"), false, "and enabled, not stuck");
    bump(3);
    await page.close();
    return "the backend's own sentence, on screen, verbatim, with the button still live";
  });

  await run.check("5  a corpus it cannot read names who can fix it, and offers no button", async () => {
    const page = await openApp(browser, { memory: "no-compiler" });
    await page.waitForSelector("#memory-setup:not([hidden])");
    const text = await dialogText(page);
    assert(
      text.indexOf("whoever set RichOS up") >= 0,
      "a state he cannot fix must say who can: " + text
    );
    assert(
      await page.isHidden("#memory-setup-go"),
      "there is nothing to set up — a button here would promise an action that does nothing"
    );
    assert(await page.isVisible("#memory-setup-close"), "and a way out");
    assert(
      (await page.textContent("#memory-setup-location")).trim().length > 0,
      "it names WHERE the memory is, which is the operator's first question"
    );
    bump(4);
    await page.close();
    return "the party is named, no control is invented, and the location is on screen";
  });

  await run.check("6  an install that is already set up is never asked", async () => {
    const page = await openApp(browser, { memory: "ready" });
    await page.waitForTimeout(400);
    assert(await page.isHidden("#memory-setup"), "a machine with memory must not be interrupted");
    const provisionCalls = await page.evaluate(
      () => window.__calls.filter((c) => c.cmd === "provision_memory").length
    );
    assertEqual(provisionCalls, 0, "nothing may provision without him answering a question");
    bump(2);
    await page.close();
    return "no dialog, and no command — his existing arrangement is left alone";
  });

  await run.check("7  there is exactly one call site, and it passes the location", async () => {
    // Structural, because the property is about the SHIPPED SOURCE rather than about one
    // run: a second call site is a second place a default could creep back in, which is the
    // whole thing `wiki/loro-structure.md` §"No silent default" removed from the compiler.
    const sites = MAIN_JS.match(/invoke\(\s*"provision_memory"/g) || [];
    assertEqual(sites.length, 1, "one door, or a default has somewhere to hide");
    assert(
      /invoke\("provision_memory",\s*\{\s*location:\s*memoryState\.offered_location\s*\}\)/.test(MAIN_JS),
      "the one call site must pass the location the window showed"
    );
    // And nothing in the surface composes a path of its own.
    assert(
      !/["'`][^"'`]*\/RichOS\/corpus/.test(MAIN_JS),
      "main.js must not contain a corpus path — the location comes from the backend or not at all"
    );
    bump(3);
    return "1 call site, passing `memoryState.offered_location`, and no path literal in the surface";
  });

  await run.check("NEGATIVE CONTROL: this suite asserted a non-zero number of things", async () => {
    assert(
      assertions >= 20,
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
      : "\na machine with no memory asks once, takes one click, and never picks a location on its own."
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
//  1   main.js `init`: call requireCompanyChoice() unconditionally
//        -> two modal dialogs at once on a fresh install
//  1b  main.js `closeMemorySetup`: drop the companyQuestionDeferred branch
//        -> the company question is asked never, and the composer stays blocked
//  2   main.js `provisionMemory`: invoke with { location: "~/RichOS/corpus" }
//        -> the string sent stops being the string he was shown
//  2b  index.html: add an <input> to the dialog
//        -> the CEO is asked to type a path
//  3   main.js `provisionMemory`: leave memorySetupGoEl visible after success
//        -> a finished dialog still offers to do the thing it just did
//  4   main.js `provisionMemory`: replace the catch body with console.error(e)
//        -> the refusal dies in a console the CEO does not have
//  5   main.js MEMORY_NO_READER: drop "whoever set RichOS up"
//        -> a state he cannot fix names nobody. Also turns affordances.js red, which is the
//           check that owns that rule
//  6   main.js `maybeAskAboutMemory`: return true for every state
//        -> an install that is already set up is interrupted on every launch
//  7   main.js: add a second provision_memory call site
//        -> a second door for a default to come back through

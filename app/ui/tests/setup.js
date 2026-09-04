// FIRST-RUN SETUP, AT THE SURFACE — the one consent step, and everything it must and must
// not do.
//
// WHY THIS SUITE EXISTS. `ceo-decisions.md` §19: "today RichOS runs on his Mac and would not
// run on anyone else's". A customer needs Claude Code AND the engine directory, and the engine
// "ships in no payload and has no route onto another machine at all". The Rust half of the fix
// is proved by 33 tests in `crates/richos-core/tests/setup.rs` and by a fresh-install run on a
// clean HOME. This file is the other half: what he is asked, what he is told, and what happens
// when it goes wrong.
//
// WHAT IT HOLDS, and each is a clause of the contract rather than a nicety:
//
//   1. A CUSTOMER'S MAC ASKS, and asks THIS first — before the memory question and before the
//      company question, because without a binary and an engine there is nothing for a corpus
//      to be read by. One dialog at a time, and held back is not dropped.
//   2. NO TERMINAL, NO PATH, NO VERSION NUMBER anywhere on the sheet. Computed from the
//      rendered text, not from intent.
//   3. THE BYO-ANTHROPIC SENTENCE IS ON THE SHEET, ABOVE THE BUTTON. Row 3.14's second
//      condition: D removes one setup step of two and must not be sold as zero-touch.
//   4. A BUILD THAT CANNOT INSTALL EXPLAINS INSTEAD OF OFFERING A BUTTON THAT WILL FAIL.
//   5. A FAILURE REACHES THE SCREEN, verbatim, and the sheet stays usable — every SetupError's
//      sentence is written for him and names what to do.
//   6. PROGRESS IS LIVE. The events the backend emits are what moves the line; a sheet that
//      only rendered the return value would look hung for the minutes Anthropic's installer
//      takes.
//   7. A MACHINE THAT HAS EVERYTHING IS NEVER ASKED.
//   8. THE BUTTON CANNOT BE PRESSED TWICE. A second press mid-run would start a second
//      installer.
//
// Run: node setup.js   (or `npm test` for every suite in this directory)

"use strict";

const fs = require("fs");
const path = require("path");
const { leaveHome, loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");
const MAIN_JS = fs.readFileSync(path.join(UI_DIR, "main.js"), "utf8");

/// Open the shell with a preset, recording every `invoke` so the arguments a click produces
/// can be READ rather than inferred from what changed on screen.
async function openApp(browser, preset) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 950 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.addInitScript(() => {
    let real = null;
    window.__calls = [];
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
          return origInvoke(cmd, args);
        };
      },
    });
  });
  if (preset) {
    await page.addInitScript((v) => {
      window.__RICHOS_MOCK_PRESET__ = v;
    }, preset);
  }
  await page.goto(APP);
  await leaveHome(page);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

const sheetText = (page) =>
  page.evaluate(() =>
    (document.getElementById("setup-sheet").innerText || "").replace(/\s+/g, " ").trim()
  );

async function main() {
  const run = createRun(
    "first-run setup — the consent step a customer's Mac gets, and what happens when it fails"
  );
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  let assertions = 0;
  const bump = (n) => {
    assertions += n;
    return n;
  };

  await run.check("1  a customer's Mac asks, first, and one dialog at a time", async () => {
    const page = await openApp(browser, {
      setup: "missing-both",
      memory: "none",
      chosenEntity: null,
    });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    assert(await page.isVisible("#setup-sheet"), "a machine missing both must be asked");
    assert(
      await page.isHidden("#memory-setup"),
      "the memory question must be HELD, not stacked on top of this one"
    );
    assert(
      await page.isHidden("#entity-picker"),
      "the company picker must be held back too — three modals at once is not a calm instrument"
    );
    // HELD BACK IS NOT DROPPED. Dismissing this one asks the next.
    await page.click("#setup-later");
    await page.waitForSelector("#memory-setup:not([hidden])");
    assert(await page.isHidden("#setup-sheet"), "the setup sheet stays closed once dismissed");
    // ...and that one hands off to the third.
    await page.click("#memory-setup-later");
    await page.waitForSelector("#entity-picker:not([hidden])");
    bump(5);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "asked first; the memory and company questions both survive being deferred";
  });

  await run.check("2  no terminal, no path, no version number reaches his screen", async () => {
    const page = await openApp(browser, { setup: "missing-both" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    const text = await sheetText(page);
    assert(text.length > 60, "the sheet said almost nothing: " + text);
    // COMPUTED FROM WHAT IS RENDERED. A path, a tilde, a shell prompt, a version number, or
    // the word Terminal each mean the non-technical constraint was lost somewhere between
    // the Rust and the DOM.
    assert(!/\//.test(text), "a path reached his screen: " + text);
    assert(!/~/.test(text), "a home-relative path reached his screen: " + text);
    assert(!/\$/.test(text), "a shell variable reached his screen: " + text);
    assert(!/[Tt]erminal/.test(text), "the Terminal was mentioned: " + text);
    assert(!/\d+\.\d+/.test(text), "a version number reached his screen: " + text);
    // AND THERE IS NO TEXT INPUT. His part is one press, not a path he types.
    const inputs = await page.evaluate(
      () => document.querySelectorAll("#setup-sheet input, #setup-sheet textarea").length
    );
    assertEqual(inputs, 0, "the setup sheet must never ask him to type anything");
    bump(7);
    await page.close();
    return "no path, no tilde, no shell, no version, no Terminal, no input field";
  });

  await run.check("3  the sheet says he still needs his own Anthropic account", async () => {
    const page = await openApp(browser, { setup: "missing-both" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    const note = (await page.textContent("#setup-account")).trim();
    assert(/Anthropic account/.test(note), "row 3.14's second condition is missing: " + note);
    assert(/sign in/i.test(note), "the sign-in he still has to do is not mentioned: " + note);
    assert(
      /never see your password/i.test(note),
      "the sheet must say RichOS never sees his password: " + note
    );
    assert(await page.isVisible("#setup-account"), "the caveat must be visible, not hidden");
    // ABOVE THE BUTTON, not a footnote after it. Compared by document position, because
    // "it is in the DOM" and "he reads it before deciding" are different claims.
    const above = await page.evaluate(() => {
      const a = document.getElementById("setup-account").getBoundingClientRect();
      const b = document.getElementById("setup-go").getBoundingClientRect();
      return a.bottom <= b.top;
    });
    assert(above, "the account caveat must sit ABOVE the button, not after it");
    bump(5);
    await page.close();
    return "BYO-Anthropic stated, in his words, above the button";
  });

  await run.check("4  each missing piece is named and explained, in his language", async () => {
    const page = await openApp(browser, { setup: "missing-both" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    const rows = await page.evaluate(() =>
      [...document.querySelectorAll("#setup-items li")].map((li) => ({
        name: li.querySelector(".setup-item-name").textContent.trim(),
        why: li.querySelector(".setup-item-why").textContent.trim(),
      }))
    );
    assertEqual(rows.length, 2, "a machine missing both must show two rows");
    assertEqual(rows[0].name, "Claude Code", "Claude Code must be named in plain text");
    assert(rows[0].why.length > 20, "a name with no explanation is a package list: " + rows[0].why);
    assert(/Anthropic/.test(rows[0].why), "who it comes from must be said: " + rows[0].why);
    assert(rows[1].why.length > 20, "the engine row explains nothing: " + rows[1].why);
    // ONE ROW ONLY when one thing is missing, and the title agrees with the count. The
    // two-piece page stays open so the singular and plural wordings are compared against each
    // other rather than each against a memory of the other.
    const page2 = page;
    const one = await openApp(browser, { setup: "missing-engine" });
    await one.waitForSelector("#setup-sheet:not([hidden])");
    const count = await one.evaluate(() => document.querySelectorAll("#setup-items li").length);
    assertEqual(count, 1, "only the engine is missing, so only one row");
    const title = (await one.textContent("#setup-title")).trim();
    assert(/one thing/.test(title), "the title must agree with the count: " + title);
    // AND SO MUST THE SENTENCE UNDER IT. Until 2026-09-04 the note was plural under both
    // titles, so this exact screen — the first a customer with Claude Code already installed
    // ever sees — read "There's one thing I need on this Mac. I can get them myself"
    // (ray-opus-a1, finding 7).
    const oneNote = (await one.textContent("#setup-note")).trim();
    assert(
      /I can get it myself/.test(oneNote) && !/get them myself/.test(oneNote),
      "one missing piece is an IT, not a THEM: " + JSON.stringify(title + " " + oneNote)
    );
    const bothNote = (await page2.textContent("#setup-note")).trim();
    assert(
      /I can get them myself/.test(bothNote),
      "and two pieces are still a THEM: " + JSON.stringify(bothNote)
    );
    await page2.close();
    bump(10);
    await one.close();
    return "two rows and a plural title and note, one row and a singular title and note";
  });

  await run.check("5  a build that cannot install EXPLAINS instead of offering a button", async () => {
    const page = await openApp(browser, { setup: "unpinned" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    assert(
      await page.isHidden("#setup-go"),
      "a button that will certainly fail must not be drawn"
    );
    assert(await page.isVisible("#setup-close"), "he must still be able to close the sheet");
    const why = (await page.textContent("#setup-error")).trim();
    assert(why.length > 40, "the reason must be a sentence, not a code: " + why);
    assert(
      /whoever set RichOS up/.test(why),
      "a state he cannot fix must name the party who can: " + why
    );
    bump(4);
    await page.close();
    return "explained, with the party named, and no button he could press in vain";
  });

  await run.check("6  a failure reaches the screen verbatim, and the sheet stays usable", async () => {
    const failure =
      "I couldn't reach the internet, so there's nothing to download yet. Connect and try " +
      "again — nothing has been changed on your Mac.";
    const page = await openApp(browser, { setup: "missing-both", setupFails: failure });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    await page.click("#setup-go");
    await page.waitForSelector("#setup-error:not([hidden])");
    const shown = (await page.textContent("#setup-error")).trim();
    assertEqual(shown, failure, "the backend's sentence must be rendered as it stands");
    // A FAILURE IS NOT A DEAD END. He can try again, and the button says so.
    assert(await page.isVisible("#setup-go"), "he must be able to try again");
    assert(!(await page.evaluate(() => document.getElementById("setup-go").disabled)),
      "the retry button must be enabled again");
    assertEqual(
      (await page.textContent("#setup-go")).trim(),
      "Try again",
      "the button must say what pressing it does now"
    );
    assert(await page.isHidden("#setup-progress"), "a failed run must stop claiming progress");
    bump(5);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "the failure is his to read, and the sheet offers the next move";
  });

  await run.check("7  progress is driven by the backend's events, not by the return value", async () => {
    // THE EVENTS ARE THE SOURCE. A sheet that only rendered `run_setup`'s answer would sit
    // silent for the minutes Anthropic's installer takes — 197,220,928 B on a Mac with no
    // zstd (§19 finding 3).
    const page = await openApp(browser, { setup: "missing-both" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    // Record what the progress line says over the course of the run.
    await page.evaluate(() => {
      window.__progress = [];
      const el = document.getElementById("setup-progress");
      new MutationObserver(() => window.__progress.push(el.textContent)).observe(el, {
        characterData: true,
        childList: true,
        subtree: true,
      });
    });
    await page.click("#setup-go");
    await page.waitForSelector("#setup-close:not([hidden])");
    const seen = await page.evaluate(() => window.__progress);
    assert(seen.length >= 2, "the progress line never moved: " + JSON.stringify(seen));
    assert(
      seen.some((s) => /Claude Code/.test(s)),
      "the Claude Code step was never announced: " + JSON.stringify(seen)
    );
    assert(
      seen.some((s) => /instructions/.test(s)),
      "the engine step was never announced: " + JSON.stringify(seen)
    );
    // AND THE END IS THE BACKEND'S ANSWER, re-read from disk, not "no step threw".
    const done = (await page.textContent("#setup-note")).trim();
    assert(/ready/i.test(done), "the finished sheet must say so: " + done);
    // AND THE HEADING AGREES WITH IT. It went on counting what was missing after the run, so
    // a successful install showed "There's one thing I need on this Mac." directly above
    // "That's everything. I'm ready." — two sentences contradicting each other on screen at
    // the same time (ray-opus-a1, finding 7, 2026-09-04).
    const heading = (await page.textContent("#setup-title")).trim();
    assert(
      !/I need on this Mac/.test(heading),
      "the heading is still asking for what the body just said it has: " +
        JSON.stringify(heading + " / " + done)
    );
    assert(
      /done/.test(heading),
      "the heading must say the state it is in: " + JSON.stringify(heading)
    );
    assert(await page.isHidden("#setup-go"), "a finished sheet must not offer to do it again");
    bump(8);
    await page.close();
    return "each step announced as it started; the ending came from the backend";
  });

  await run.check("8  a machine that has everything is never asked", async () => {
    const page = await openApp(browser, { setup: "ready" });
    await page.waitForTimeout(300);
    assert(
      await page.isHidden("#setup-sheet"),
      "an install that is already set up must not be interrupted on every launch"
    );
    // And the status was still READ — the question is answered from disk, not skipped.
    const asked = await page.evaluate(() =>
      window.__calls.some((c) => c.cmd === "setup_status")
    );
    assert(asked, "the shell must ask the backend rather than assuming a set-up machine");
    bump(2);
    await page.close();
    return "read, and silent";
  });

  await run.check("9  the button cannot be pressed twice", async () => {
    const page = await openApp(browser, { setup: "missing-both" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    // Press, then immediately check the button is disabled — a second press mid-run would
    // start a second copy of Anthropic's installer.
    await page.evaluate(() => document.getElementById("setup-go").click());
    const disabled = await page.evaluate(() => document.getElementById("setup-go").disabled);
    assert(disabled, "the button must be disabled for the duration of the run");
    await page.waitForSelector("#setup-close:not([hidden])");
    const calls = await page.evaluate(
      () => window.__calls.filter((c) => c.cmd === "run_setup").length
    );
    assertEqual(calls, 1, "run_setup must be invoked exactly once per press");
    bump(2);
    await page.close();
    return "one press, one run";
  });

  await run.check("10  there is exactly one run_setup call site in the shipped source", async () => {
    // A SECOND DOOR IS A SECOND PLACE FOR THE GUARD TO BE MISSING. `memory.js` holds the
    // same rule over `provision_memory` for the same reason.
    const sites = (MAIN_JS.match(/invoke\(\s*"run_setup"/g) || []).length;
    assertEqual(sites, 1, "run_setup is invoked from " + sites + " places in main.js");
    // ...and the setup question is asked before the memory one, in the source as well as on
    // screen, so the order is not an accident of two async calls racing.
    const setupAt = MAIN_JS.indexOf("maybeAskAboutSetup()");
    const memoryAt = MAIN_JS.indexOf("maybeAskAboutMemory()");
    assert(setupAt > 0 && memoryAt > 0, "both question helpers must exist");
    bump(2);
    return "one call site; the ordering is explicit in the source";
  });

  // =======================================================================================
  // VOICE IS NOT OFFERED ON A MACHINE THAT CANNOT TRANSCRIBE
  // =======================================================================================
  //
  // Measured on published v1.0.0 by ray-opus-a1, 2026-09-04: the talk button asked for the
  // microphone, showed "listening…" with a level meter and lit the orange menu-bar
  // recording indicator for 25+ seconds. It never transcribed and never said it could not —
  // and the first-run greeting invited it: "You can type, or tap ◉ to talk to me."
  //
  // The shipping bundle carries no whisper binary and no model, so on a customer's Mac the
  // answer is always "no". This is that Mac.
  await run.check("12  a customer's Mac is not offered voice, and is not invited to it", async () => {
    const page = await openApp(browser, { setup: "missing-both", voice: "unavailable" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    // The window ASKED. A surface that decides this without asking is guessing.
    const asked = await page.evaluate(() =>
      window.__calls.some((c) => c.cmd === "voice_readiness")
    );
    assert(asked, "the window must ask voice_readiness before it decides");
    // NOT OFFERED. `[hidden]{display:none!important}` is what makes this real — the button
    // declares its own `display:flex`, which at equal specificity beats the UA rule.
    assert(
      await page.isHidden("#talk-toggle"),
      "the talk button must not be offered on a machine with no speech model"
    );
    // AND NOT INVITED. The greeting must not name a control that cannot work.
    await page.click("#setup-later");
    const greeting = await page.evaluate(() => {
      const n = document.querySelector("#messages .tl-prose");
      return n ? n.textContent : "";
    });
    assert(!/tap ◉/.test(greeting), "the greeting still invites voice: " + greeting);
    assert(!/talk to me/.test(greeting), "the greeting still invites voice: " + greeting);
    bump(4);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "voice_readiness asked; ◉ absent; the greeting names only the composer";
  });

  // The OTHER half, and it is the half that proves the first is a decision rather than a
  // deletion: a machine that can transcribe is still offered voice, and still invited.
  await run.check("13  a machine that can transcribe keeps the invitation", async () => {
    const page = await openApp(browser, { setup: "missing-both" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    assert(await page.isVisible("#talk-toggle"), "◉ must stay where voice can actually work");
    await page.click("#setup-later");
    const greeting = await page.evaluate(() => {
      const n = document.querySelector("#messages .tl-prose");
      return n ? n.textContent : "";
    });
    assert(/tap ◉ to talk to me/.test(greeting), "the invitation is missing: " + greeting);
    bump(2);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "◉ present and the greeting invites it";
  });

  // =======================================================================================
  // THE ENGINE STEP CANNOT BE GOT PAST BY ACCIDENT
  // =======================================================================================
  //
  // MEASURED ON PUBLISHED v1.0.1 (ray-opus-a2, 2026-09-04). A walk from a fresh state ended
  // with `~/Library/Application Support/RichOS/engine` holding zero files, the first-run
  // sheet ADVANCED to the corpus question, and four sends in a row refused with
  // LEASE_UNAVAILABLE_MESSAGE. The click that started it was aimed at "Set it up" and landed
  // in empty space below the panel.
  //
  // It landed on the backdrop. `#setup-sheet` is the full-screen overlay and the sheet the
  // customer sees is `.overlay-panel` inside it, and main.js closed the whole thing on
  // `e.target === setupSheetEl`. Re-measured here before the fix, on both presets: sheet
  // hidden=true, run_setup called=false, memory question showing=true.
  //
  // The bar is not "warn him". It is that a mis-aimed click, and a stranger's habit of
  // clicking beside a dialog to be rid of it, cannot produce an app that looks set up and is
  // not. So: the backdrop does nothing, Escape does nothing, the panel body does nothing, and
  // the only ways out are the two buttons that say what they do.
  await run.check("14  a mis-aimed click cannot skip the engine", async () => {
    for (const preset of ["missing-engine", "missing-both"]) {
      const page = await openApp(browser, { setup: preset, memory: "none", chosenEntity: null });
      await page.waitForSelector("#setup-sheet:not([hidden])");
      const panel = await page.evaluate(() => {
        const r = document.querySelector("#setup-sheet .overlay-panel").getBoundingClientRect();
        return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
      });
      const midX = (panel.left + panel.right) / 2;
      const midY = (panel.top + panel.bottom) / 2;
      // The exact miss ray-opus-a2 made: aimed at the button, landed below the panel.
      const misses = [
        [midX, Math.min(panel.bottom + 60, 940)], // below
        [Math.max(panel.left - 80, 10), midY], // beside
        [midX, Math.max(panel.top - 60, 10)], // above
      ];
      for (const [x, y] of misses) {
        await page.mouse.click(x, y);
        await page.waitForTimeout(120);
        assert(
          await page.isVisible("#setup-sheet"),
          preset + ": a click at " + x + "," + y + " dismissed the engine step"
        );
        assert(
          await page.isHidden("#memory-setup"),
          preset + ": a backdrop click advanced to the corpus question with no engine installed"
        );
      }
      // AND ESCAPE IS INERT. It has never closed this sheet — the global handler names the
      // overlays it closes and this is deliberately not one — and this is what keeps it that
      // way, because "nobody added it to the list" is not a guarantee.
      await page.keyboard.press("Escape");
      await page.waitForTimeout(120);
      assert(await page.isVisible("#setup-sheet"), preset + ": Escape dismissed the engine step");
      // Nor does a click inside the panel that hits no control.
      await page.click("#setup-title");
      await page.waitForTimeout(120);
      assert(
        await page.isVisible("#setup-sheet"),
        preset + ": a click on the panel body dismissed the engine step"
      );
      // NOTHING WAS INSTALLED AND NOTHING WAS CLAIMED — five dismissal attempts, zero runs.
      const ran = await page.evaluate(() =>
        window.__calls.filter((c) => c.cmd === "run_setup").length
      );
      assertEqual(ran, 0, preset + ": run_setup should not have been reached by any of that");
      // THE NAMED WAY OUT STILL WORKS, and still hands off. Refusing the backdrop must not
      // turn the first screen a customer ever sees into a trap.
      await page.click("#setup-later");
      await page.waitForSelector("#memory-setup:not([hidden])");
      assert(await page.isHidden("#setup-sheet"), preset + ": \"Not now\" must still close it");
      bump(12);
      assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
      await page.close();
    }
    // AND IN THE SOURCE, so a later slice that re-adds the one-line convenience fails here
    // rather than on a customer's Mac.
    // COMMENTS STRIPPED FIRST. The note above the (absent) listener quotes the line it
    // replaced, so a naive grep matches the explanation and calls it the defect.
    const code = MAIN_JS.split("\n")
      .filter((l) => !l.trim().startsWith("//"))
      .join(" ")
      .replace(/\s+/g, " ");
    assert(
      !/setupSheetEl\)\s*closeSetupSheet/.test(code),
      "main.js closes the setup sheet on a backdrop click again"
    );
    bump(1);
    return "backdrop, Escape and the panel body are all inert; only the two buttons dismiss it";
  });

  // =======================================================================================
  // A SEND WITH NO ENGINE SAYS SO, AND OFFERS THE INSTALL
  // =======================================================================================
  //
  // ray-opus-a2 sent four messages into a machine with no engine and got the same sentence
  // four times: "I'm not connected to my thinking right now... Quit RichOS and open it again
  // — that clears it most of the time." He had not restarted between them, and restarting
  // would not have helped: the next boot looks for the same absent engine, fails the same
  // attach, and says the same thing. The only instruction the product gave him was one that
  // could not work.
  //
  // That sentence is not wrong — it is written for the OTHER no-lease cause, the signed-out
  // one, which a restart does clear. The two causes were sharing it. `send_message` now asks
  // the disk which cause this is (main.rs) and the window puts the setting up back on screen,
  // so the sentence's promise is kept rather than claimed.
  //
  // NOTE THIS STATE IS STILL REACHABLE ON PURPOSE. "Not now" is a real answer. Case 14 stops
  // an ACCIDENT from skipping the engine; this case is what happens when he skips it
  // deliberately and then tries to send anyway.
  await run.check("15  a send with no engine names the engine and offers the install", async () => {
    const page = await openApp(browser, { setup: "missing-engine", memory: "ready" });
    await page.waitForSelector("#setup-sheet:not([hidden])");
    await page.click("#setup-later"); // he defers, which he is entitled to do
    await page.waitForSelector("#setup-sheet", { state: "hidden" });
    await page.fill("#input", "book the Acme call for Thursday");
    await page.click("#send");
    await page.waitForSelector("#setup-sheet:not([hidden])");

    // WHAT HE IS TOLD. Read off the screen, not off the source — and waited for, because
    // `scheduleRender` batches: the sheet is shown synchronously and the notice lands on the
    // next frame, so a read taken the instant the sheet appears catches the greeting.
    await page.waitForFunction(() =>
      [...document.querySelectorAll("#messages .tl-prose")].some((n) =>
        /take that on yet/.test(n.textContent)
      )
    );
    const notice = await page.evaluate(() => {
      const rows = [...document.querySelectorAll("#messages .tl-prose")];
      const hit = rows.filter((n) => /take that on yet/.test(n.textContent));
      return hit.length ? hit[hit.length - 1].textContent : rows.map((n) => n.textContent).join(" | ");
    });
    assert(/RichOS engine/.test(notice), "the missing piece is not named: " + notice);
    assert(!/Quit RichOS/.test(notice), "it still tells him to restart: " + notice);
    assert(!/open it again/.test(notice), "it still tells him to restart: " + notice);
    assert(
      /nothing to quit and nothing to reopen/.test(notice),
      "it must close the door on the advice that cannot work: " + notice
    );
    assert(/Set it up/.test(notice), "it names no way forward: " + notice);

    // AND THE CONTROL IT NAMES IS ON SCREEN. A sentence that says "I've put the setting up
    // back on your screen" and does not is the same defect as "quit and reopen", one layer up.
    assert(await page.isVisible("#setup-go"), "the sheet must be back, with the button on it");
    assertEqual(
      (await page.textContent("#setup-go")).trim(),
      "Set it up",
      "the notice names this control by its label, so the label must be that"
    );

    // HIS WORDS ARE NOT LOST, and the tail does not contradict the notice — telling him to
    // press Send while a modal covers the composer would be an instruction he cannot follow.
    assertEqual(
      await page.inputValue("#input"),
      "book the Acme call for Thursday",
      "his words were swallowed"
    );
    assert(
      /when the setting up is done/.test(notice),
      "the tail must not send him to a control the sheet is covering: " + notice
    );

    // AND PRESSING IT WORKS FROM HERE. The offer is an offer, not a notice shaped like one.
    await page.click("#setup-go");
    await page.waitForSelector("#setup-close:not([hidden])");
    const done = (await page.textContent("#setup-note")).trim();
    assert(/ready/i.test(done), "the run started from the notice must finish: " + done);
    bump(10);
    assert(page.__errors.length === 0, "the shell logged errors: " + page.__errors.join(" | "));
    await page.close();
    return "named, offered, his words kept, and the install runs from the offer";
  });

  await run.check("16  the preview rehearses the product's own refusal, byte for byte", async () => {
    // The same join `affordances.js` makes on LEASE_UNAVAILABLE_MESSAGE, for the same reason:
    // a preview that teaches the CEO one sentence while the app says another is two products.
    const rust = fs.readFileSync(
      path.join(UI_DIR, "..", "src-tauri", "src", "setup_view.rs"),
      "utf8"
    );
    const mock = fs.readFileSync(path.join(UI_DIR, "mock.js"), "utf8");
    // Rust's `\` + newline + indent joins to nothing; JS's `" +` + newline + `"` likewise.
    const joinedMock = mock.replace(/"\s*\+\s*\n\s*"/g, "");
    let checked = 0;
    for (const name of ["SETUP_INCOMPLETE_ENGINE", "SETUP_INCOMPLETE_CLAUDE", "SETUP_INCOMPLETE_BOTH"]) {
      const m = rust.match(new RegExp("pub const " + name + ": &str =\\s*\"([\\s\\S]*?)\";"));
      assert(m, "the Rust const " + name + " is gone");
      const sentence = m[1].replace(/\\\n\s*/g, "");
      // A LITERAL THAT LOST ITS CONTINUATIONS SHIPS DOUBLE SPACES TO HIS SCREEN. This exact
      // mistake was made and caught by the Rust tests while writing this pass.
      assert(!/ {2}/.test(sentence), name + " carries a run of spaces: " + sentence);
      assert(
        joinedMock.indexOf(sentence) >= 0,
        "app/ui/mock.js rehearses a refusal the product no longer says: " + sentence
      );
      checked++;
    }
    assertEqual(checked, 3, "all three arms must be compared");
    bump(7);
    return "three sentences, one wording, no stray spaces";
  });

  await run.check("11  this suite actually checked something", async () => {
    assert(
      assertions >= 40,
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
      : "\na customer's Mac is asked once, in his language, and told the truth when it fails."
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
//  1   main.js `init`: call maybeAskAboutMemory() unconditionally
//        -> two modal dialogs at once on a customer's Mac
//  1b  main.js `closeSetupSheet`: drop the memoryQuestionDeferred branch
//        -> the memory and company questions are asked never
//  2   setup.rs `Component::why`: return "~/.local/bin/claude"
//        -> a path reaches his screen
//  2b  index.html: add an <input> to #setup-sheet
//        -> the CEO is asked to type something
//  3   setup_view.rs: blank SETUP_ACCOUNT_NOTE
//        -> D is sold as zero-touch, which row 3.14 forbids
//  3b  index.html: move #setup-account below the actions
//        -> the caveat becomes a footnote after the decision
//  4   main.js `openSetupSheet`: stop rendering item.why
//        -> the sheet becomes a package list
//  5   setup_view.rs `ask_for`: set can_install true when blocked
//        -> a button is drawn that will certainly fail
//  6   main.js `runSetup`: replace the catch body with console.error(e)
//        -> the failure dies in a console the CEO does not have
//  6b  main.js `runSetup`: leave setupGoEl disabled after a failure
//        -> a failure becomes a dead end
//  7   main.js: delete the Bridge.listen("richos://setup") block
//        -> the sheet sits silent for the whole run
//  7b  main.js `runSetup`: hard-code the finished sentence to "ready"
//        -> a run that left something missing claims it did not
// 14   main.js: restore setupSheetEl.addEventListener("click", e => { if (e.target ===
//        setupSheetEl) closeSetupSheet(); })
//        -> a click beside the panel skips the engine install and advances to the corpus
//           question, which is published v1.0.1's behavior and ray-opus-a2's dead app
// 14b  main.js: add setupSheetEl to the global Escape handler'''s list
//        -> Escape skips the engine install the same way
//  8   main.js `maybeAskAboutSetup`: return true for every status
//        -> a set-up machine is interrupted on every launch
//  9   main.js `runSetup`: drop `setupGoEl.disabled = true`
//        -> a double press starts two copies of Anthropic's installer
// 10   main.js: add a second run_setup call site
// 12   main.js `refreshVoiceReadiness`: default voiceAvailable to true on an unknown answer
//        -> ◉ is offered on a machine with no speech model, and the mic goes hot
// 12b  main.js `renderFirstRun`: append GREETING_VOICE_INVITE unconditionally
//        -> the first sentence a customer reads names a control that cannot work
// 13   main.js `refreshVoiceReadiness`: hide ◉ unconditionally
//        -> voice is deleted rather than withheld, on every machine

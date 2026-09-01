// THE UPDATE SURFACE — RICH-TODOs row 12, driven through the real renderer.
//
// The row said, verbatim: *"There is no updater of any kind — no `tauri-plugin-updater`, no
// Sparkle, nothing. The CEO's 'automatically download and install whatever the user needs'
// currently rests on zero infrastructure."* This suite is the browser half of the answer.
//
// WHAT THIS SUITE CANNOT DO, said first so nothing here is mistaken for more than it is.
// It CANNOT prove that an update applies. That is a claim about a signed `.app.tar.gz`
// replacing a running bundle and is proven where it happens — `app/scripts/updater-e2e.sh`,
// which builds 0.1.0 and 0.1.1, serves a manifest, and makes 0.1.0 become 0.1.1 on this
// machine, then tampers with one byte of the artifact and shows the updater REFUSE. Nothing
// in a browser can do either, and a suite that asserted a count it got from `mock.js` would
// be proving the mock.
//
// WHAT IT DOES PROVE IS THE HALF THAT LIVES IN THE PAGE, and the four that matter are:
//
//   * THE SURFACE EXISTS AND IS NOT SILENT. Nine states, each with its own sentence, and
//     "never checked" distinguishable from "checked and you are current". A silent updater
//     is one that can be broken for three months without anyone learning it.
//   * A REFUSED SIGNATURE IS NOT OFFERED A RETRY. Every other failure gets "Try again";
//     this one does not, because retrying a tampered artifact refuses identically and a
//     button that invites someone to keep pressing until a security check passes is the
//     wrong control. This is the check most likely to be broken by a well-meaning edit.
//   * NO PERCENTAGE WITHOUT A DENOMINATOR. A server that sends no `Content-Length` gets an
//     indeterminate bar with NO `aria-valuenow` — a determinate bar over an invented total
//     is a lie that looks like a measurement.
//   * THE BUTTONS DO WHAT THEY SAY. Asserted on the commands actually issued
//     (`__RICHOS_MOCK__.updateCalls()`), not on the button looking pressed.
//
// Contrast for this surface is NOT here: it is in `contrast.js`'s three `updates-*`
// surfaces, walked in both themes against the same 4.5 / 3.0 floors as everything else.
// Two checkers for one property is how one of them rots.
//
// EVERY CHECK HERE WAS RUN RED ONCE by breaking the shipped source; the mutations are listed
// at the bottom of this file.
//
// Run: node updates.js   (or `npm test` for every suite in this directory)
//      RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node updates.js

"use strict";

const fs = require("fs");
const path = require("path");
const { leaveHome, loadPlaywright, shot, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");
const UPDATES_RS = fs.readFileSync(
  path.join(UI_DIR, "..", "src-tauri", "src", "updates.rs"),
  "utf8"
);
const SHOTS = "../shots-updates";

/// A view, with only the interesting fields spelled out at each call site.
function view(over) {
  return Object.assign(
    {
      state: "idle",
      currentVersion: "0.1.0",
      availableVersion: null,
      notes: null,
      pubDate: null,
      downloadedBytes: 0,
      totalBytes: null,
      percent: null,
      failure: null,
      endpoint: "https://updates.richos.invalid/{{target}}/{{arch}}/{{current_version}}",
      endpointIsPlaceholder: true,
      checkedAt: null,
    },
    over
  );
}

async function openApp(browser) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.goto(APP);
  // The home screen is the landing surface now; this suite is about the app UI behind it.
  await leaveHome(page);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

async function setState(page, v, script) {
  await page.evaluate(
    ([vv, ss]) => window.__RICHOS_MOCK__.updateSet(vv, ss),
    [v, script || []]
  );
  await page.waitForTimeout(80);
}

async function openMenu(page) {
  await page.click("#set-btn");
  await page.waitForSelector("#set-menu", { state: "visible" });
  await page.waitForTimeout(120);
}

/// What the row says right now: the two sentences, which buttons are visible, and whether
/// the settings button is marked.
async function readRow(page) {
  return page.evaluate(() => {
    const row = document.getElementById("set-updates");
    const vis = (id) => {
      const n = document.getElementById(id);
      return !!n && !n.hidden;
    };
    const txt = (id) => {
      const n = document.getElementById(id);
      return n ? n.textContent.trim() : null;
    };
    const btn = document.getElementById("set-btn");
    const prog = document.getElementById("update-progress");
    return {
      present: !!row,
      state: row ? row.getAttribute("data-update-state") : null,
      failureKind: row ? row.getAttribute("data-update-failure") : null,
      headline: txt("update-line"),
      sub: vis("update-sub") ? txt("update-sub") : null,
      check: vis("update-check") ? txt("update-check") : null,
      checkDisabled: (() => {
        const n = document.getElementById("update-check");
        return n ? n.disabled : null;
      })(),
      install: vis("update-install") ? txt("update-install") : null,
      relaunch: vis("update-relaunch") ? txt("update-relaunch") : null,
      why: vis("update-why") ? txt("update-why") : null,
      detail: vis("update-detail") ? txt("update-detail") : null,
      endpoint: vis("update-endpoint") ? txt("update-endpoint") : null,
      progress: prog && !prog.hidden,
      ariaValueNow: prog ? prog.getAttribute("aria-valuenow") : null,
      indeterminate: prog ? prog.getAttribute("data-indeterminate") : null,
      fillWidth: (() => {
        const n = document.getElementById("update-progress-fill");
        return n ? n.style.width : null;
      })(),
      mark: btn ? btn.getAttribute("data-update-mark") : null,
    };
  });
}

/// The nine `state` strings the Rust actually produces, read out of `updates.rs` rather than
/// typed here. A state added there and not handled in `updates.js` reaches this file as a
/// failing check instead of as a row that renders a blank sentence.
function rustStates() {
  const m = UPDATES_RS.match(/\/\/\/ `unconfigured`[\s\S]*?pub state: &'static str,/);
  assert(m, "no `state` doc comment in updates.rs — the inventory has nowhere to come from");
  const names = [...m[0].matchAll(/`([a-zA-Z]+)`/g)].map((x) => x[1]);
  assert(names.length > 0, "the doc comment named no states");
  return names.sort();
}

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("the update surface (RICH-TODOs row 12) — through the real renderer");

  // ---- 1. it exists, where the CEO can reach it from every screen -----------------------
  await run.check("1. the update row is in the UNIVERSAL settings menu, on every screen", async () => {
    const page = await openApp(browser);
    // Nothing before the button is pressed — this is chrome, not a banner.
    assertEqual(await page.isVisible("#set-updates"), false, "nothing until the menu opens");
    await openMenu(page);
    const row = await readRow(page);
    assert(row.present, "the row is in the menu");
    // ...and it is the menu that is on EVERY screen, not the rail's popover, which is what
    // `#set-btn` being `position: fixed` outside `#app` buys. Prove it from a second surface.
    await page.click("#set-btn"); // close
    await page.click('.nav-thread[data-thread-id="hiring"]');
    await page.waitForTimeout(300);
    await openMenu(page);
    assert((await readRow(page)).present, "and again from inside a conversation");
    await page.close();
    return "present from the shell and from an open thread";
  });

  // ---- 2. every state the Rust can produce has a sentence here --------------------------
  await run.check("2. every state `updates.rs` can produce renders a sentence, and none is blank", async () => {
    const page = await openApp(browser);
    const states = rustStates();
    assert(states.length >= 9, "expected the nine states, got " + states.length + ": " + states);
    await openMenu(page);
    const seen = [];
    for (const s of states) {
      await setState(page, view({ state: s, availableVersion: "0.1.1", checkedAt: Date.now() - 60000 }));
      const row = await readRow(page);
      assert(row.headline && row.headline.length > 0, s + ": the headline is empty");
      assert(row.sub && row.sub.length > 0, s + ": the second line is empty");
      assertEqual(row.state, s, s + ": the row did not take the state");
      seen.push(s + " -> " + row.headline);
    }
    // An UNKNOWN state must report itself as unknown. Falling back to "up to date" is the
    // single worst answer this surface could give, and it is the natural default arm.
    await setState(page, view({ state: "something-nobody-shipped" }));
    const odd = await readRow(page);
    assert(
      /cannot tell/i.test(odd.sub),
      "an unrecognized state must say it is unrecognized, not imply the app is current: " + odd.sub
    );
    await page.close();
    return states.length + " states, each with a sentence; unknown reports unknown";
  });

  // ---- 3. "never checked" is not "up to date" ------------------------------------------
  await run.check("3. `idle` and `upToDate` are different sentences — never checked is a state", async () => {
    const page = await openApp(browser);
    await openMenu(page);
    await setState(page, view({ state: "idle", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x" }));
    const idle = await readRow(page);
    await setState(page, view({ state: "upToDate", checkedAt: Date.now() - 8 * 60000, endpointIsPlaceholder: false, endpoint: "https://u.example.com/x" }));
    const fresh = await readRow(page);
    assert(/has not checked/i.test(idle.sub), "idle must say it has not checked: " + idle.sub);
    assert(/up to date/i.test(fresh.headline), "upToDate must say so: " + fresh.headline);
    assert(/8 minutes ago/.test(fresh.sub), "and WHEN it looked: " + fresh.sub);
    assert(idle.sub !== fresh.sub, "the two are not the same sentence");
    await page.close();
    return "idle: “" + idle.sub + "” / upToDate: “" + fresh.sub + "”";
  });

  // ---- 4. the placeholder endpoint is a THIRD thing, not an error -----------------------
  await run.check("4. `unconfigured` reports a decision that has not been made, not a failure", async () => {
    const page = await openApp(browser);
    await openMenu(page);
    await setState(page, view({ state: "unconfigured" }));
    const row = await readRow(page);
    assertEqual(row.state, "unconfigured", "the row is in the unconfigured state");
    assert(/no update server/i.test(row.sub), "it says there is no server yet: " + row.sub);
    assert(!/failed|error/i.test(row.sub), "and does not call a pending decision a failure");
    assertEqual(row.failureKind, null, "nothing is filed as a failure");
    assertEqual(row.checkDisabled, true, "and Check is not offered against an endpoint that cannot resolve");
    // The placeholder is never printed at the CEO; a non-placeholder endpoint always is.
    assertEqual(row.endpoint, null, "the .invalid placeholder is not paraded on screen");
    await setState(page, view({ state: "upToDate", endpoint: "https://staging.example.com/u", endpointIsPlaceholder: false, checkedAt: Date.now() }));
    const staged = await readRow(page);
    assert(
      staged.endpoint && staged.endpoint.indexOf("staging.example.com") >= 0,
      "a build pointed somewhere unusual says so on screen: " + staged.endpoint
    );
    await page.close();
    return "unconfigured is not an error; a non-default endpoint is disclosed";
  });

  // ---- 5. THE ONE THAT MATTERS: a refused signature is not retryable --------------------
  await run.check("5. a REFUSED SIGNATURE is not offered a retry, and every other failure is", async () => {
    const page = await openApp(browser);
    await openMenu(page);

    await setState(
      page,
      view({
        state: "failed",
        endpointIsPlaceholder: false,
        endpoint: "https://u.example.com/x",
        failure: {
          kind: "signature",
          headline: "This download was not signed by RichOS, so it was not installed.",
          detail: "Signature verification failed",
        },
      })
    );
    const sig = await readRow(page);
    assertEqual(sig.failureKind, "signature", "the kind reaches the DOM, so this is styleable and testable");
    assert(sig.check !== "Try again", "a refused signature must NOT offer a retry — it got: " + sig.check);
    assert(/not signed by RichOS/.test(sig.headline), "and says what happened: " + sig.headline);
    assert(sig.install === null && sig.relaunch === null, "nothing offers to install it anyway");
    await shot(page, SHOTS + "/updates-signature-refused");

    for (const kind of ["offline", "network", "manifest", "install", "configuration", "other"]) {
      await setState(
        page,
        view({
          state: "failed",
          endpointIsPlaceholder: false,
          endpoint: "https://u.example.com/x",
          failure: { kind, headline: "The update did not complete.", detail: kind + " detail" },
        })
      );
      const r = await readRow(page);
      assertEqual(r.check, "Try again", kind + " is plausibly transient and must offer a retry");
    }
    await page.close();
    return "signature: no retry; offline/network/manifest/install/configuration/other: retry";
  });

  // ---- 6. the vendor's own reason is kept, one click away -------------------------------
  await run.check("6. the technical reason is the vendor's text, verbatim, behind a disclosure", async () => {
    const page = await openApp(browser);
    await openMenu(page);
    const detail = "Signature verification failed: comment signature verification failed";
    await setState(
      page,
      view({
        state: "failed",
        endpointIsPlaceholder: false,
        endpoint: "https://u.example.com/x",
        failure: { kind: "signature", headline: "This download was not signed by RichOS, so it was not installed.", detail },
      })
    );
    let row = await readRow(page);
    assertEqual(row.detail, null, "closed by default — the CEO reads a sentence, not a stack");
    assert(row.why === "Show the technical reason", "and is offered it: " + row.why);
    await page.click("#update-why");
    await page.waitForTimeout(80);
    row = await readRow(page);
    assertEqual(row.detail, detail, "verbatim, not summarised — a truncated error cannot be searched for");
    assertEqual(
      await page.getAttribute("#update-why", "aria-expanded"),
      "true",
      "and the disclosure says it is open"
    );
    await page.close();
    return "hidden by default, verbatim when opened";
  });

  // ---- 7. no percentage without a denominator ------------------------------------------
  await run.check("7. a download with no Content-Length shows NO percentage and no aria-valuenow", async () => {
    const page = await openApp(browser);
    await openMenu(page);

    await setState(page, view({ state: "downloading", availableVersion: "0.1.1", downloadedBytes: 5242880, totalBytes: 13631488, percent: 38, endpointIsPlaceholder: false, endpoint: "https://u.example.com/x" }));
    const known = await readRow(page);
    assert(known.progress, "the bar is shown");
    assertEqual(known.ariaValueNow, "38", "a known total gets a real accessible value");
    assertEqual(known.fillWidth, "38%", "and a fill that means it");
    assertEqual(known.indeterminate, null, "not indeterminate");
    assert(/5\.0 MB of 13\.0 MB/.test(known.sub), "and says the bytes: " + known.sub);

    await setState(page, view({ state: "downloading", availableVersion: "0.1.1", downloadedBytes: 5242880, totalBytes: null, percent: null, endpointIsPlaceholder: false, endpoint: "https://u.example.com/x" }));
    const unknown = await readRow(page);
    assert(unknown.progress, "the bar is still shown");
    assertEqual(unknown.ariaValueNow, null, "NO accessible value is invented");
    assertEqual(unknown.indeterminate, "true", "and it is marked indeterminate");
    assert(/5\.0 MB so far/.test(unknown.sub), "bytes, with no total claimed: " + unknown.sub);
    await page.close();
    return "38% with a total; no value and no percentage without one";
  });

  // ---- 8. the mark on the settings button, and when it is NOT there ---------------------
  await run.check("8. the settings button is marked for exactly two states and no others", async () => {
    const page = await openApp(browser);
    // The mark must appear WITHOUT the menu ever being opened — that is the whole point of
    // it, and it arrives on the `rich://update` event the automatic launch check emits.
    await setState(page, view({ state: "available", availableVersion: "0.1.1", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x", checkedAt: Date.now() }));
    assertEqual(await page.getAttribute("#set-btn", "data-update-mark"), "available", "marked while the menu is shut");
    assertEqual(await page.locator("#update-mark").count(), 1, "one mark, not a stack of them");
    await shot(page, SHOTS + "/updates-mark-on-the-button");

    await setState(page, view({ state: "ready", availableVersion: "0.1.1", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x" }));
    assertEqual(await page.getAttribute("#set-btn", "data-update-mark"), "ready", "and changes meaning for ready");
    assertEqual(await page.locator("#update-mark").count(), 1, "still exactly one");

    for (const s of ["idle", "checking", "upToDate", "downloading", "installing", "failed", "unconfigured"]) {
      await setState(page, view({ state: s, availableVersion: "0.1.1", failure: s === "failed" ? { kind: "network", headline: "x", detail: "y" } : null }));
      assertEqual(
        await page.getAttribute("#set-btn", "data-update-mark"),
        null,
        s + " must not mark the button — a permanently marked button is one nobody reads"
      );
    }
    await page.close();
    return "available and ready mark it; the other seven do not";
  });

  // ---- 9. the buttons issue the commands they claim to -----------------------------------
  await run.check("9. Install installs and Restart restarts — asserted on the commands issued", async () => {
    const page = await openApp(browser);
    await openMenu(page);
    await page.evaluate(() => window.__RICHOS_MOCK__.updateCalls()); // drain nothing; just prove it exists

    await setState(
      page,
      view({ state: "available", availableVersion: "0.1.1", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x", checkedAt: Date.now() }),
      [view({ state: "ready", availableVersion: "0.1.1", percent: 100, endpointIsPlaceholder: false, endpoint: "https://u.example.com/x" })]
    );
    let row = await readRow(page);
    assertEqual(row.install, "Download and install", "the install button is offered");
    assertEqual(row.check, null, "and Check is not — the next act is not another check");

    await page.click("#update-install");
    await page.waitForTimeout(150);
    row = await readRow(page);
    assertEqual(row.state, "ready", "the scripted install landed");
    assertEqual(row.relaunch, "Restart to finish", "and the restart is now the offer");
    assertEqual(row.install, null, "the install button is gone");

    await page.click("#update-relaunch");
    await page.waitForTimeout(150);
    const calls = await page.evaluate(() => window.__RICHOS_MOCK__.updateCalls());
    assert(calls.indexOf("update_install") >= 0, "Install issued update_install: " + calls.join(","));
    assert(calls.indexOf("update_relaunch") >= 0, "Restart issued update_relaunch: " + calls.join(","));
    assert(
      calls.indexOf("update_relaunch") > calls.indexOf("update_install"),
      "and in that order: " + calls.join(",")
    );
    await page.close();
    return calls.join(" -> ");
  });

  // ---- 10. the row survives a menu rebuild ----------------------------------------------
  await run.check("10. a menu rebuild does not leave an empty Updates row", async () => {
    const page = await openApp(browser);
    await setState(page, view({ state: "available", availableVersion: "0.1.1", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x", checkedAt: Date.now() }));
    await openMenu(page);
    assert((await readRow(page)).headline.indexOf("0.1.1") >= 0, "painted before the rebuild");
    // `RichSettings.forceDark` throws the whole menu away and builds a new one — the same
    // path §15's opening screen takes. The row is a NEW element afterwards, so a renderer
    // that cached its nodes would paint into a detached tree and leave a blank row.
    await page.evaluate(() => window.RichSettings.forceDark(true));
    await page.waitForTimeout(200);
    await page.evaluate(() => window.RichSettings.forceDark(false));
    await page.waitForTimeout(200);
    const after = await readRow(page);
    assert(after.present, "the row survived the rebuild");
    assert(after.headline.indexOf("0.1.1") >= 0, "and is still painted: " + after.headline);
    await page.close();
    return "rebuilt and repainted: “" + after.headline + "”";
  });

  // ---- 11. no page errors ----------------------------------------------------------------
  await run.check("11. no page errors anywhere in this suite", async () => {
    const page = await openApp(browser);
    await openMenu(page);
    for (const s of ["unconfigured", "idle", "checking", "upToDate", "available", "downloading", "installing", "ready", "failed"]) {
      await setState(page, view({ state: s, availableVersion: "0.1.1", failure: s === "failed" ? { kind: "signature", headline: "h", detail: "d" } : null }));
    }
    const errs = page.__errors;
    assertEqual(errs, [], "uncaught errors: " + errs.join(" | "));
    await page.close();
    return "0 uncaught errors across all nine states";
  });

  await browser.close();
  const failed = run.report();
  process.exit(failed ? 1 : 0);
}

// =========================================================================================
// THE MUTATIONS — every check above was RUN RED, by breaking the SHIPPED source
// =========================================================================================
//
// Recorded as run on 2026-08-31, with the ACTUAL set of checks each one reddened rather
// than the set I expected. Two of them reddened more than their own check, and that is
// reported here rather than tidied away: a mutation that takes ten checks down with it says
// something true about how much of this surface rests on one line.
//
//    #  mutation (all against the shipped source, then restored)          checks reddened
//   ---------------------------------------------------------------------------------------
//    1  settings-button.js: deleted `if (updates) menu.appendChild(          1,2,3,4,5,
//       buildUpdatesRow())` — the row stops existing                         6,7,8,9,10
//    2  updates.js: made `sentences()`'s `default:` arm return the           2
//       `upToDate` sentence — an unknown state claiming the app is current
//    3  updates.js: made the `idle` arm return the `upToDate` sentence       3
//    4  updates.js: dropped `|| v.state === "unconfigured"` from the         4
//       Check button's `disabled`
//    5  updates.js: removed `&& !isSignature(v)` from the Check label —      5
//       a refused signature offered "Try again"
//    6  updates.js: made `nodes.detail.textContent` a 40-character slice     6
//    7  updates.js: made the `pct === null` arm unreachable, so an           7
//       unknown total painted a determinate bar
//    8  updates.js: made `marker()` mark every state but `ready` and         8
//       `unconfigured`
//    9  updates.js: made the Restart button call `update_check`              9
//   10  updates.js: `render()` builds only when `!nodes`, never comparing    10
//       `nodes.container` — paints into the detached pre-rebuild tree
//   11  updates.js: threw inside `sentences()`'s `installing` arm            2,8,11
//
// Check 11 (no page errors) is the one that catches #11, and #11 also reddens 2 and 8
// because both drive the `installing` state on their way through.
// =========================================================================================

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

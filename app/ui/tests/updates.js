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
//   * IT ANNOUNCES ITSELF WITHOUT BEING OPENED, and only when there is something to say
//     (checks 12-14, added 2026-09-04 for §26's placement ruling). Everything above this
//     line was green on the day the CEO said *"the user can't be bothered to hunt for some
//     update button somewhere"* — which is the point: the row was correct and it was inside
//     a menu, so nobody met it. The half that carries the ruling is the ABSENCE half: with
//     nothing to install there is no element at all, proven by count, by the wrapper's own
//     geometry, and by driving the state back after the element has once existed.
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

/// Wait for the opening curtain to yield before taking EVIDENCE of the chrome.
///
/// `openApp` above deliberately does not wait — the checks it serves are about the DOM, and
/// the curtain is `pointer-events: none`, so it changes nothing they assert. A screenshot is
/// the one place it matters: the cue sits above the curtain (correctly — so does the settings
/// button, §15), and a shot taken through it is a picture of the opening screen with a pill on
/// it rather than a picture of the cue in the app it announces into.
async function settled(page) {
  await page.waitForFunction(() => !document.getElementById("splash"), { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(150);
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

/// THE CUE, read the way a person meets it: is there an element at all, what does it say, and
/// is the thing at its own center actually it.
///
/// `count` is asked FIRST and everything else is conditional on it, because the property under
/// test is existence. A helper that returned `visible: false` for a hidden placeholder and for
/// a removed element alike would make the two indistinguishable, and telling them apart is the
/// entire point of the ruling.
async function readCue(page) {
  return page.evaluate(() => {
    const n = document.getElementById("update-cue");
    // THE GEOMETRY IS MEASURED ON BOTH BRANCHES, and that is not tidiness. It was measured
    // only on the absent branch first, so `wrapWidth` and `btnWidth` were both `undefined`
    // whenever a cue existed — and check 13's footprint assertion then compared undefined
    // with undefined and passed. The `always-present` mutation, which is precisely the defect
    // that check exists to catch, went red on check 12 alone and left 13 green. A negative
    // assertion that cannot fail is not a check.
    const wrap = document.getElementById("settings");
    const btn = document.getElementById("set-btn");
    const w = wrap ? wrap.getBoundingClientRect() : null;
    const b = btn ? btn.getBoundingClientRect() : null;
    const box = {
      // The wrapper's own footprint, so "absent" can be proven to mean "costs no layout"
      // rather than "present and painted like the background".
      wrapWidth: w ? Math.round(w.width) : null,
      btnWidth: b ? Math.round(b.width) : null,
      wrapLeft: w ? Math.round(w.left) : null,
      btnLeft: b ? Math.round(b.left) : null,
    };
    if (!n) {
      return Object.assign({ count: document.querySelectorAll("#update-cue, .update-cue").length }, box);
    }
    const r = n.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    const menu = document.getElementById("set-menu");
    return Object.assign({}, box, {
      count: document.querySelectorAll("#update-cue, .update-cue").length,
      cueState: n.getAttribute("data-update-cue"),
      text: n.textContent.trim(),
      hidden: n.hidden,
      disabled: n.disabled,
      // Is it actually the thing under the pointer at its own center — "in view", not merely
      // in the document.
      onTop: !!(hit && hit.closest && hit.closest("#update-cue")),
      inViewport: r.top >= 0 && r.left >= 0 && r.bottom <= window.innerHeight && r.right <= window.innerWidth,
      menuOpen: !!(menu && !menu.hidden),
      glyphs: n.querySelectorAll("svg.update-cue-glyph").length,
      ariaLabel: n.getAttribute("aria-label"),
      rowLine: (() => {
        const l = document.getElementById("update-line");
        return l ? l.textContent.trim() : null;
      })(),
    });
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

  // =======================================================================================
  // THE CUE — CEO ruling §26, the placement paragraph added 2026-09-04.
  //
  // *"The user can't be bothered to hunt for some update button somewhere."* Everything above
  // proves the ROW, and the row is inside a menu. Checks 1 to 11 would all have passed on the
  // day the ruling was written, which is exactly the point: a surface can be complete,
  // correct, tested, and still announce nothing to anybody.
  //
  // THE ABSENCE HALF IS THE ONE THAT MATTERS. An affordance that is always present passes a
  // naive "is it there when there is an update" test perfectly and fails the ruling, because
  // the property being asked for is not visibility — it is that a NEW element arrives in
  // chrome the user is already looking at. A control that is always there and occasionally
  // changes color is one an eye has already learned to skip. So the absence is asserted three
  // ways that a hidden placeholder cannot satisfy: element count zero, no layout footprint,
  // and the state driven BACK to absent after the cue has once existed.
  // =======================================================================================

  // ---- 12. it appears when there is something, and does not EXIST when there is not -----
  await run.check("12. the cue APPEARS for a waiting update and does not EXIST otherwise", async () => {
    const page = await openApp(browser);

    // Nothing has been opened, and nothing will be: this is the whole claim.
    await setState(page, view({ state: "upToDate", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x", checkedAt: Date.now() }));
    let cue = await readCue(page);
    assertEqual(cue.count, 0, "with nothing to install there is NO element — not a dimmed one, not an 'up to date' one");

    await setState(page, view({ state: "available", availableVersion: "0.1.2", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x", checkedAt: Date.now() }));
    cue = await readCue(page);
    assertEqual(cue.count, 1, "one element arrived, and exactly one");
    assertEqual(cue.menuOpen, false, "and NOTHING was opened to see it — that is the defect this closes");
    assertEqual(cue.hidden, false, "present means present");
    assertEqual(cue.disabled, false, "and live, not a disabled state");
    assertEqual(cue.onTop, true, "it is the thing under the pointer at its own middle, not covered");
    assertEqual(cue.inViewport, true, "and inside the window, with no scrolling to reach it");
    assertEqual(cue.cueState, "available", "carrying its state for a stylesheet and for this suite");
    assertEqual(cue.glyphs, 1, "one glyph");
    assert(/RichOS 0\.1\.2 is available/.test(cue.text), "and it NAMES THE VERSION: " + cue.text);
    // WCAG 2.5.3 "Label in Name": the accessible name STARTS with the visible words, so
    // someone driving this by voice can say what is on the screen and be understood.
    assert(
      cue.ariaLabel && cue.ariaLabel.indexOf(cue.text) === 0 && cue.ariaLabel.length > cue.text.length,
      "the accessible name carries the visible label verbatim and then says what pressing it does: " + cue.ariaLabel
    );
    await settled(page);
    await shot(page, SHOTS + "/updates-cue-available");

    await setState(page, view({ state: "ready", availableVersion: "0.1.2", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x" }));
    cue = await readCue(page);
    assertEqual(cue.count, 1, "still one for the other waiting state");
    assertEqual(cue.cueState, "ready", "and it changed meaning");
    assert(/RichOS 0\.1\.2 is installed/.test(cue.text), "naming the version again: " + cue.text);
    await settled(page);
    await shot(page, SHOTS + "/updates-cue-ready");

    // AND BACK. A build that only ever ADDS the element passes the half above and is the
    // exact failure the ruling names, so the return trip is asserted rather than assumed.
    for (const s of ["idle", "checking", "upToDate", "downloading", "installing", "failed", "unconfigured", "a-state-nobody-shipped"]) {
      await setState(
        page,
        view({
          state: s,
          availableVersion: "0.1.2",
          failure: s === "failed" ? { kind: "signature", headline: "This download was not signed by RichOS, so it was not installed.", detail: "d" } : null,
        })
      );
      const gone = await readCue(page);
      assertEqual(gone.count, 0, s + " must leave NO element behind — a placeholder is the defect, not the fix");
    }
    await settled(page);
    await shot(page, SHOTS + "/updates-cue-absent");
    await page.close();
    return "available and ready raise exactly one element with the menu shut; the other eight states raise none";
  });

  // ---- 13. absent costs NOTHING, and present is in chrome that is on every screen --------
  await run.check("13. absence reserves no space, and the cue reaches every surface", async () => {
    const page = await openApp(browser);
    await setState(page, view({ state: "upToDate", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x", checkedAt: Date.now() }));
    const empty = await readCue(page);
    // THE CHECK A HIDDEN PLACEHOLDER CANNOT PASS. `visibility: hidden`, `opacity: 0` and a
    // zero-content pill all leave the wrapper wider than its button; a removed element does
    // not. Geometry, not intent.
    assertEqual(empty.wrapWidth, empty.btnWidth, "with no update the settings wrapper is exactly its button, " + empty.wrapWidth + " vs " + empty.btnWidth);
    assertEqual(empty.wrapLeft, empty.btnLeft, "and starts where the button starts — nothing is held open to its left");

    // ...and when it does arrive it grows LEFTWARD: the button the CEO already aims at must
    // not move under his pointer.
    const btnRightBefore = await page.evaluate(() => Math.round(document.getElementById("set-btn").getBoundingClientRect().right));
    await setState(page, view({ state: "available", availableVersion: "0.1.2", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x", checkedAt: Date.now() }));
    const btnRightAfter = await page.evaluate(() => Math.round(document.getElementById("set-btn").getBoundingClientRect().right));
    assertEqual(btnRightAfter, btnRightBefore, "the settings button did not move when the cue arrived");

    // It is mounted in the chrome §15 puts on EVERY screen, so prove it from a second surface
    // rather than from the one it happened to be built on.
    await page.click('.nav-thread[data-thread-id="hiring"]');
    await page.waitForTimeout(300);
    const inThread = await readCue(page);
    assertEqual(inThread.count, 1, "still there inside a conversation");
    assertEqual(inThread.onTop, true, "and still the thing under the pointer, over the conversation");
    await page.close();
    return "absent: wrapper " + empty.wrapWidth + "px = button " + empty.btnWidth + "px; present: the button's right edge never moves, and the cue is on a second surface";
  });

  // ---- 14. it LEADS to the existing flow, and decides nothing itself ---------------------
  await run.check("14. the cue opens the existing row and issues no command of its own", async () => {
    const page = await openApp(browser);
    // THE CURTAIN IS LET GO OF BEFORE ANYTHING IS PRESSED, and this is a focus test so that
    // ordering is load-bearing rather than cosmetic. `main.js` puts focus in the composer the
    // moment the opening screen yields; a check that clicked first and waited afterwards
    // would watch its own assertion be overwritten by the app booting.
    await settled(page);
    await setState(
      page,
      view({ state: "available", availableVersion: "0.1.2", notes: "Faster launch.", endpointIsPlaceholder: false, endpoint: "https://u.example.com/x", checkedAt: Date.now() }),
      [view({ state: "ready", availableVersion: "0.1.2", percent: 100, endpointIsPlaceholder: false, endpoint: "https://u.example.com/x" })]
    );
    const before = await page.evaluate(() => window.__RICHOS_MOCK__.updateCalls().length);

    await page.click("#update-cue");
    await page.waitForSelector("#set-menu", { state: "visible" });
    await page.waitForTimeout(150);

    // THE ROW IS THE AUTHORITY, and the cue speaks with its voice rather than a second one.
    const cue = await readCue(page);
    const row = await readRow(page);
    assert(row.present, "the row the cue leads to is the row this suite has been testing all along");
    // Read in the SAME `evaluate` as the cue's own text, so this is one snapshot rather than
    // two reads a repaint could sit between.
    assertEqual(cue.text, cue.rowLine, "the cue's words ARE the row's words — one sentence, not two that agree today");
    assertEqual(row.headline, cue.text, "and the row agrees when read on its own terms");
    assertEqual(row.install, "Download and install", "and the row's own control is the offer");
    await shot(page, SHOTS + "/updates-cue-opened-the-row");

    // NOTHING WAS INSTALLED BY PRESSING THE ANNOUNCEMENT. §26's mode 1 — install with no
    // click at all — was ruled a separate design session on 2026-09-04, and an announcement
    // that quietly starts an install is that decision taken by an engineer.
    const afterOpen = await page.evaluate(() => window.__RICHOS_MOCK__.updateCalls());
    assertEqual(afterOpen.indexOf("update_install"), -1, "the cue installed nothing: " + afterOpen.slice(before).join(","));
    assertEqual(afterOpen.indexOf("update_relaunch"), -1, "and restarted nothing");

    // The hand is put on the control, so the click that announced the update lands one
    // keystroke from the act rather than one hunt from it.
    assertEqual(
      await page.evaluate(() => document.activeElement && document.activeElement.id),
      "update-install",
      "focus is on the row's own control"
    );
    await page.keyboard.press("Enter");
    await page.waitForTimeout(150);
    const calls = await page.evaluate(() => window.__RICHOS_MOCK__.updateCalls());
    assert(calls.indexOf("update_install") >= 0, "and pressing it reaches the SAME command the row has always issued: " + calls.join(","));
    assertEqual((await readRow(page)).state, "ready", "the scripted install landed, through the existing flow");
    await page.close();
    return "cue -> menu -> the row's own control -> update_install; the cue itself issues nothing";
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
//
// THE CUE (checks 12-14), run 2026-09-04, same rule: every mutation below was applied to the
// SHIPPED source, the suite run, the file restored and compared byte for byte against its
// backup. The reddened set is the one that was OBSERVED, not the one expected.
//
//   12  updates.js: `cue()`'s `want` can never be empty — the pill is built for       12,13
//       every state and merely changes its label. THE defect the ruling names: a
//       permanent control that occasionally changes color is one an eye stops seeing
//   13  updates.js: `cue()`'s host lookup returns null, so the element is never       12,13,14
//       built at all — the state this surface was in before the placement ruling
//   14  updates.js: `openTheRow` calls `update_install` instead of opening the        14
//       menu — the announcement quietly becomes §26's mode 1, which the CEO ruled
//       on 2026-09-04 is a design session of its own
//   15  updates.js: the cue writes its own label, `"Update"`, instead of              12,14
//       `sentences(v).headline` — the version stops being named and the chrome and
//       the row become two vocabularies that agree until one of them is edited
//   16  updates.js: the cue is appended AFTER the settings button instead of          13
//       inserted before it, so the button the CEO already aims at moves out from
//       under his pointer the moment an update arrives
//
// MUTATION 12 IS THE ONE THAT PAID FOR ITSELF, and it is recorded here rather than tidied
// away. On its first run it reddened check 12 and left check 13 GREEN — because `readCue`
// measured the wrapper's geometry only on the branch where no cue existed, so check 13's
// footprint assertion was comparing `undefined` with `undefined` and could not fail. The
// geometry is measured on both branches now. A negative assertion that cannot fail is not a
// check, and only running the mutation says which is which.
//
// AND THE POSITIVE PROBE FOR THE CONTRAST HALF, because a green walk over an element nobody
// looked at is the same as no walk: `.update-cue-label`'s ink was repainted `#b09a6a` and
// `contrast.js` was run. It failed `9.updates-available` by name, in BOTH themes — 1.13:1 on
// the dark fill and 1.44:1 on the light one — which is the evidence that the 7.68 / 4.72 the
// shipped pair computes to is a measurement of this element and not of an assumption about
// it. The backgrounds WebKit resolved (`#c2a35c` and `#9c7c34`) are the two tokens the
// stylesheet's ledger says they are.
// =========================================================================================

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

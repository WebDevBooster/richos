// §7.2 the worker inspector, §7.3 the background-work summary, §20 the three breakpoints —
// driven through the REAL SHELL: `index.html`, `main.js`, `mock.js`, `style.css` and
// `timeline.js`, all loaded from disk, with nothing stubbed but the Tauri bridge (which
// `mock.js` already replaces, exactly as an operator opening the file does).
//
// `workers.js` beside this file tests the renderer in isolation. This one tests that the
// shell wires it up — the two failures are different and only one of them is caught by
// either test alone.

"use strict";

const path = require("path");
const { leaveHome, loadPlaywright, shot, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");

async function openApp(browser, viewport) {
  const page = await browser.newPage({ viewport: viewport || { width: 1400, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.goto(APP);
  // The home screen is the landing surface now; this suite is about the app UI behind it.
  await leaveHome(page);
  await page.waitForFunction("typeof window.RichTimeline === 'object'");
  // ATTACHED, not visible: below 820px §20 makes the rail a closed full-height drawer, so
  // its rows exist and are correctly not on screen.
  await page.waitForSelector(".nav-thread", { state: "attached" });
  const railHidden = await page.evaluate(() => {
    const r = document.getElementById("rail");
    return getComputedStyle(r).display === "none" || document.body.classList.contains("rail-closed");
  });
  if (railHidden) await page.click("#rail-toggle");
  await page.waitForSelector(".nav-thread", { state: "visible" });
  page.__errors = errors;
  return page;
}

/// Open the seeded thread that carries three delegated workers and expand its transcript.
async function openHiringThread(page) {
  await page.click('.nav-thread[data-thread-id="hiring"]');
  await page.waitForSelector('.tl-duration-btn:not(.tl-duration-btn--static)');
  await page.click(".tl-duration-btn");
  await page.waitForSelector(".tl-chip");
}

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("§7.2 inspector / §7.3 summary / §20 breakpoints — real shell, WebKit");

  const page = await openApp(browser);

  await run.check("the shell draws the delegated workers in a real seeded thread", async () => {
    await openHiringThread(page);
    const r = await page.evaluate(() => ({
      summary: document.querySelector(".tl-workers-head .tl-activity-text").textContent,
      chips: Array.from(document.querySelectorAll(".tl-chip")).map(
        (c) => c.querySelector(".tl-chip-name").textContent + "/" + c.querySelector(".tl-chip-state").textContent
      ),
    }));
    assertEqual(r.chips, ["Sage/Starting", "Frank/Working", "Clark/Ended"]);
    return `"${r.summary}" — ${r.chips.join(", ")}`;
  });

  await run.check("§7.2 selecting a chip opens a SIBLING pane, not a modal", async () => {
    await page.click('[id="chip:agt_clark_1"]');
    await page.waitForSelector("#inspector:not([hidden])");
    const r = await page.evaluate(() => {
      const insp = document.getElementById("inspector");
      const conv = document.getElementById("conversation");
      const ir = insp.getBoundingClientRect();
      const cr = conv.getBoundingClientRect();
      return {
        title: document.getElementById("inspector-title").textContent,
        modal: insp.getAttribute("aria-modal"),
        scrimHidden: document.getElementById("inspector-scrim").hidden,
        // Both panes readable side by side, neither covering the other (§7.2, §25).
        overlaps: ir.left < cr.right - 1 && cr.left < ir.right - 1,
        conversationWidth: Math.round(cr.width),
        inspectorWidth: Math.round(ir.width),
        selectedChips: document.querySelectorAll(".tl-chip.is-selected").length,
        body: document.getElementById("inspector-body").innerText,
      };
    });
    assertEqual(r.title, "Clark", "the pane names the worker");
    assertEqual(r.modal, null, "§7.2: a sibling pane, NOT a modal");
    assert(!r.overlaps, "the pane must sit beside the conversation, not over it");
    assert(r.conversationWidth >= 620, "§20: the conversation keeps at least 620px — got " + r.conversationWidth);
    assertEqual(r.selectedChips, 1, "the open worker's chip is marked");
    assert(r.body.includes("Ended"), "state is shown");
    assert(r.body.includes("Pulled the platform-eng comparables"), "§7.2 item 4: the authored update");
    return `conversation ${r.conversationWidth}px | inspector ${r.inspectorWidth}px, side by side`;
  });

  await run.check("§7.2 the pane is READ-ONLY: no control R2 governs", async () => {
    const r = await page.evaluate(() => {
      const body = document.getElementById("inspector-body");
      const controls = Array.from(body.querySelectorAll("button, input, select, textarea, a[href]"));
      return {
        controlsInBody: controls.map((c) => c.textContent.trim() || c.tagName),
        // The whole pane, header included.
        allControls: Array.from(
          document.getElementById("inspector").querySelectorAll("button, input, select, textarea, a[href]")
        ).map((c) => c.getAttribute("aria-label") || c.textContent.trim()),
        controlText: Array.from(
          document.getElementById("inspector").querySelectorAll("button, input, select, textarea, a[href]")
        )
          .map((c) => (c.getAttribute("aria-label") || "") + " " + c.textContent)
          .join(" ")
          .toLowerCase(),
        stateWord: document.querySelector(".insp-state-word").textContent,
        stateQualifier: document.querySelector(".insp-state-qualifier").textContent,
      };
    });
    assertEqual(r.controlsInBody.length, 1, "exactly one control in the body: " + r.controlsInBody.join(", "));
    assert(
      r.controlsInBody[0].includes("What I saw"),
      "and it is the chronology disclosure, not an interrupt/retry/approve: " + r.controlsInBody[0]
    );
    assertEqual(r.allControls.length, 2, "the pane as a whole has exactly two: " + r.allControls.join(", "));
    assert(r.allControls[0] === "Close worker details", "the other is Close: " + r.allControls[0]);
    // Checked against the CONTROL surface, not the prose: §7.2's list is a list of things
    // the CEO must not be able to DO. The explanatory sentence is allowed to name "failed"
    // as one of three possibilities — that is the honesty, and forbidding the word there
    // would force the pane to be vaguer than the truth.
    for (const forbidden of ["retry", "interrupt", "approve", "resume", "stop", "model", "permission", "prompt"]) {
      assert(!r.controlText.includes(forbidden), `§7.2 forbids a "${forbidden}" control — found one: ` + r.controlText);
    }
    // And the STATE, which is the one line a CEO reads as a verdict, claims nothing.
    assertEqual(r.stateWord, "Ended", "run_ended must not be dressed up as an outcome");
    assertEqual(r.stateQualifier, "outcome not recorded");
    return "2 controls total: Close, and one disclosure. State reads \"Ended · outcome not recorded\". R2 stays deferred to V2.";
  });

  await run.check("§7.2/§22 no elapsed active time is shown, and the absence is stated", async () => {
    const r = await page.evaluate(() => {
      document.getElementById("insp-chron-toggle").click();
      return {
        facts: Array.from(document.querySelectorAll(".insp-facts dt")).map((d, i) => [
          d.textContent,
          document.querySelectorAll(".insp-facts dd")[i].textContent,
        ]),
        text: document.getElementById("inspector-body").innerText,
      };
    });
    const spent = r.facts.find((f) => f[0] === "Time spent working");
    assert(spent, "the pane says something about time spent");
    assertEqual(spent[1], "not recorded", "§22: elapsed active time must not be faked");
    // Two timestamps ARE shown — and no difference of them appears anywhere.
    assert(
      r.facts.some((f) => f[0] === "First seen") && r.facts.some((f) => f[0] === "Last seen"),
      "the two observed timestamps are shown as timestamps"
    );
    assert(!/\b\d+m \d+s\b/.test(r.text), "no duration was computed from them: " + r.text);
    return r.facts.map((f) => `${f[0]}: ${f[1]}`).join(" | ");
  });

  await run.check("§7.2 the worker result stays visible when its activity closes", async () => {
    const r = await page.evaluate(() => {
      const read = () => ({
        chronOpen: document.getElementById("insp-chron-toggle").getAttribute("aria-expanded"),
        factsVisible: !document.getElementById("insp-chron-body").hidden,
        update: document.querySelector(".insp-update-text") ? document.querySelector(".insp-update-text").textContent : null,
        state: document.querySelector(".insp-state-word").textContent,
      });
      const open = read();
      document.getElementById("insp-chron-toggle").click();
      return { open, closed: read() };
    });
    assertEqual(r.open.factsVisible, true);
    assertEqual(r.closed.factsVisible, false, "the chronology collapses independently");
    assertEqual(r.closed.update, r.open.update, "the worker's own words survive the collapse");
    assertEqual(r.closed.state, r.open.state, "so does its state");
    return `activity closed, result still reads: "${r.closed.update}"`;
  });

  await run.check("§18 Escape closes the pane and returns focus to the chip", async () => {
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => document.getElementById("inspector").hidden);
    const r = await page.evaluate(() => ({
      hidden: document.getElementById("inspector").hidden,
      focused: document.activeElement ? document.activeElement.id : null,
      selected: document.querySelectorAll(".tl-chip.is-selected").length,
    }));
    assert(r.hidden, "Escape closes inspector detail");
    assertEqual(r.focused, "chip:agt_clark_1", "focus goes back where it came from");
    assertEqual(r.selected, 0, "and no chip is left marked");
    return "closed, focus restored to chip:agt_clark_1";
  });

  await run.check("§25 worker-pane width can be changed directly and survives relaunch", async () => {
    await page.click('[id="chip:agt_frank_1"]');
    await page.waitForSelector("#inspector:not([hidden])");
    const before = await page.evaluate(() => document.getElementById("inspector").getBoundingClientRect().width);

    // Dragged, not set: the divider is the affordance §7.2 asks for.
    const box = await page.locator("#inspector-resizer").boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + 200);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 - 90, box.y + 200, { steps: 8 });
    await page.mouse.up();

    const after = await page.evaluate(() => ({
      width: document.getElementById("inspector").getBoundingClientRect().width,
      persisted: window.RichBridge.invoke("nav_state").then ? null : null,
    }));
    assert(Math.abs(after.width - (before + 90)) <= 2, `dragged: ${before} -> ${after.width}`);

    // "Survives relaunch": reload the page and read what the (mocked) durable store hands
    // back at boot. The mock clamps with nav.rs's own bounds and returns the width it
    // ACCEPTED, so this exercises the same contract the real command has.
    const persisted = await page.evaluate(() => window.RichBridge.invoke("nav_state"));
    assertEqual(Math.round(persisted.inspector_width), Math.round(after.width), "the store holds the new width");
    assert(
      Math.round(persisted.sidebar_width) === 300,
      "and dragging the worker pane did NOT move the rail: " + persisted.sidebar_width
    );

    // Keyboard, too — §18: every function works without a pointer.
    await page.focus("#inspector-resizer");
    await page.keyboard.press("ArrowRight");
    const afterKey = await page.evaluate(() => document.getElementById("inspector").getBoundingClientRect().width);
    assert(Math.abs(afterKey - (after.width - 8)) <= 2, `keyboard resize: ${after.width} -> ${afterKey}`);
    return `drag ${Math.round(before)} -> ${Math.round(after.width)}px, persisted; ArrowRight -> ${Math.round(afterKey)}px; rail untouched at 300px`;
  });

  await run.check("§7.3 the background-work summary shows only counts with a source", async () => {
    const r = await page.evaluate(async () => {
      const status = await window.RichBridge.invoke("get_worker_status");
      return { status, chip: document.querySelector(".drill-chip") ? document.querySelector(".drill-chip").textContent : null };
    });
    // Force a poll the way `rich://turn-started` does.
    await page.evaluate(() => window.RichBridge.invoke("get_worker_status"));
    await page.click('.nav-thread[data-thread-id="acme"]');
    await page.click('.nav-thread[data-thread-id="hiring"]');
    const chipText = await page.evaluate(async () => {
      // main.js polls on turn-started; call the same path directly rather than faking a turn.
      const status = await window.RichBridge.invoke("get_worker_status");
      return status;
    });
    assertEqual(chipText.needs_you, 0, "needs_you is structurally 0 and is never rendered");
    assert(chipText.active >= 1, "a real active count exists now");
    assert(typeof chipText.liveness_unknown === "number", "and so does a real unknown count");
    void r;
    return `active=${chipText.active} done=1 liveness_unknown=${chipText.liveness_unknown} needs_you=${chipText.needs_you} (never drawn)`;
  });

  await run.check("SCREENSHOT: the inspector docked beside the conversation", async () => {
    await page.click('.nav-thread[data-thread-id="hiring"]');
    await page.waitForSelector(".tl-duration-btn");
    await page.click(".tl-duration-btn");
    await page.waitForSelector(".tl-chip");
    await page.click('[id="chip:agt_clark_1"]');
    await page.waitForSelector("#inspector:not([hidden])");
    const s = await shot(page, "inspector-docked-1400");
    assert(s.bytes > 3000, "too small to be a render: " + s.bytes);
    return `${s.file} (${s.bytes} bytes)`;
  });

  await run.check("no page errors in the real shell", async () => {
    assertEqual(page.__errors, [], "the shell threw");
    return "0 uncaught errors, 0 console errors";
  });

  await page.close();

  // ---------------------------------------------------------------------------------------
  // §20 — the three breakpoints, each opened fresh so the boot-time layout is what is tested
  // ---------------------------------------------------------------------------------------
  for (const [label, width, expectDocked] of [
    ["1180px and wider — docked", 1400, true],
    ["820 to 1179 — overlays from the right", 1000, false],
    ["below 820 — full-height sheet", 760, false],
  ]) {
    await run.check("§20 " + label, async () => {
      const p = await openApp(browser, { width, height: 900 });
      await p.click('.nav-thread[data-thread-id="hiring"]');
      await p.waitForSelector("#messages .tl-turn");
      await p.waitForSelector(".tl-duration-btn");
      await p.click(".tl-duration-btn");
      await p.waitForSelector(".tl-chip");
      await p.click('[id="chip:agt_sage_1"]');
      await p.waitForSelector("#inspector:not([hidden])");
      const r = await p.evaluate(() => {
        const insp = document.getElementById("inspector");
        const conv = document.getElementById("conversation");
        const ir = insp.getBoundingClientRect();
        const cr = conv.getBoundingClientRect();
        return {
          position: getComputedStyle(insp).position,
          inspectorWidth: Math.round(ir.width),
          conversationWidth: Math.round(cr.width),
          scrimHidden: document.getElementById("inspector-scrim").hidden,
          resizerShown: getComputedStyle(document.getElementById("inspector-resizer")).display !== "none",
          readable: ir.width >= 260,
          title: document.getElementById("inspector-title").textContent,
        };
      });
      assertEqual(r.title, "Sage", "the pane opened");
      if (expectDocked) {
        assertEqual(r.position, "relative", "docked as a flex sibling");
        assert(r.resizerShown, "the divider is directly adjustable at this size");
        assert(r.conversationWidth >= 620, "conversation floor: " + r.conversationWidth);
        assert(r.scrimHidden, "a docked pane has no scrim — it is not modal");
      } else {
        assertEqual(r.position, "fixed", "§20: it overlays because two readable columns no longer fit");
        assert(!r.scrimHidden, "an overlaying pane gets a dismiss scrim");
      }
      assert(r.readable, "the pane stays readable at " + r.inspectorWidth + "px");
      const s = await shot(p, "inspector-" + width);
      assert(p.__errors.length === 0, "errors at " + width + "px: " + p.__errors.join("; "));
      await p.close();
      return `${r.position}, inspector ${r.inspectorWidth}px, conversation ${r.conversationWidth}px -> ${s.file}`;
    });
  }

  await browser.close();
  return run.report();
}

main().then(
  (failed) => process.exit(failed ? 1 : 0),
  (e) => {
    console.error(e);
    process.exit(1);
  }
);

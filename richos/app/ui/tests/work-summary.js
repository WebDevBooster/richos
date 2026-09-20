"use strict";
const path = require("path");
const {loadPlaywright, createRun, assert, assertEqual, UI_DIR, leaveHome, openThread} = require("./lib/harness");
async function main() {
  const run = createRun("saved work in the shipping renderer");
  const browser = await loadPlaywright().webkit.launch();
  await run.check("saved outcomes remain distinct and scoped when the conversation changes", async () => {
    const page = await browser.newPage({viewport: {width:1280, height:900}});
    const errors = []; page.on("pageerror", e => errors.push(String(e)));
    await page.addInitScript(() => window.__RICHOS_MOCK_PRESET__ = {workSummaries: {
      hiring: {items:[{title:"<img src=x onerror=alert(1)>", role:"worker", repository:"/fictional/one", state:"run-ended", detail:"Worker run ended. Review is still required."}, {title:"Reviewed change", role:"worker", repository:"/fictional/two", state:"integrated", detail:"Reviewed commit integrated locally. Whole assignment remains open."}], omitted:2}
    }});
    await page.goto("file://" + path.join(UI_DIR,"index.html")); await leaveHome(page);
    await openThread(page,"hiring");
    await page.waitForFunction(() => document.getElementById("drill-chip-zone").textContent.includes("2 saved work records"));
    await page.click(".drill-chip");
    assert((await page.textContent("#slideover-body")).includes("Review is still required"), "run end became success");
    assert((await page.textContent("#slideover-body")).includes("Whole assignment remains open"), "integration became whole-task completion");
    assertEqual(await page.locator("#slideover-body img").count(),0,"receipt rendered as markup");
    await page.click("#slideover-close"); await openThread(page,"acme");
    assert(!(await page.textContent("#drill-chip-zone")).includes("2 saved work records"),"old-company receipt leaked");
    await page.evaluate(() => window.__RICHOS_MOCK_PRESET__.workSummaryError = "Synthetic damaged receipt");
    await page.waitForFunction(() => document.getElementById("drill-chip-zone").textContent.includes("Saved work unavailable"));
    await page.click(".drill-chip");
    assert((await page.textContent("#slideover-body")).includes("Synthetic damaged receipt"),"damaged receipt looked empty");
    assertEqual(errors.length,0,"renderer errors"); await page.close();
    return "scoped receipts, explicit outcomes, escaped content and visible read failure";
  });
  // **THE OTHER TWO THINGS THE CHIP IS BUILT FROM, AND THEY WERE NOT BEING SCOPED.**
  //
  // The check above has guarded `savedWork` across a conversation change since it was
  // written — `"old-company receipt leaked"` — and `drillItems` was cleared beside it. But
  // `renderDrillChip` reads FOUR pieces of state, and the other two, `workerCounts` and
  // `assignments.rows`, were not touched by `openThread`. So the chip went on printing the
  // conversation he had just LEFT — "1 working", "1 waiting for you", "2 assignments
  // running" — over the conversation he had just arrived at, until the three-second poll
  // came back with this thread's answer. That is one entity's work beside another entity's
  // conversation, which is the leak `openThread`'s own `closeWorkerInspector()` comment
  // calls "the exact shape of leak every guard in this build exists to stop", arriving
  // through a door nothing was watching.
  //
  // **HELD STILL RATHER THAN RACED.** The refill is on a free-running 3,000 ms interval
  // whose next tick can land ten milliseconds after the switch, so asserting "the chip is
  // clean for a moment" would be a coin toss. Instead `get_assignments` is made to HANG
  // before the switch: `pollWorkerStatus` awaits it and never returns, `workStatusBusy`
  // stays raised, and nothing can refill the chip from anything. What is on screen after
  // that is therefore exactly what `openThread` left there synchronously — which is the
  // thing under test, with the clock taken out of it.
  await run.check("the counts and the assignments do not survive the conversation they belong to", async () => {
    const page = await browser.newPage({viewport: {width:1280, height:900}});
    const errors = []; page.on("pageerror", e => errors.push(String(e)));
    await page.addInitScript(() => window.__RICHOS_MOCK_PRESET__ = {assignments: {
      hiring: [{
        id: "leak-one", title: "landing the three branches", state: "running",
        detail: "Running.", repositories: [], registeredAtMs: 1, canStop: true,
        onTheConnection: true, awaitingYou: null,
      }],
      // `acme` deliberately absent: the mock answers an unknown thread with [], which is
      // the honest shape of "this conversation has no assignments".
    }});
    await page.goto("file://" + path.join(UI_DIR,"index.html")); await leaveHome(page);
    await openThread(page,"hiring");
    // THE POSITIVE PROBE, and it has to come first: the rest of this check asserts that
    // things are ABSENT, and an absence proves nothing unless they were present.
    await page.waitForFunction(() => document.getElementById("drill-chip-zone").textContent.includes("1 assignment running"));
    const onHiring = await page.textContent("#drill-chip-zone");
    assert(onHiring.includes("1 working"), "the worker count is not on the chip to leak: " + JSON.stringify(onHiring));

    await page.evaluate(() => {
      const original = window.RichBridge.invoke.bind(window.RichBridge);
      window.RichBridge.invoke = (cmd, args) =>
        cmd === "get_assignments" ? new Promise(() => {}) : original(cmd, args);
    });
    await openThread(page,"acme");
    const onAcme = await page.textContent("#drill-chip-zone");
    assert(!onAcme.includes("assignment running"), "the previous conversation's assignment leaked: " + JSON.stringify(onAcme));
    assert(!onAcme.includes("waiting for you"), "a previous conversation's decision leaked: " + JSON.stringify(onAcme));
    assert(!onAcme.includes("working"), "the previous conversation's worker count leaked: " + JSON.stringify(onAcme));
    assert(!onAcme.includes("I can't see"), "the previous conversation's unknown-liveness count leaked: " + JSON.stringify(onAcme));
    assertEqual(errors.length,0,"renderer errors"); await page.close();
    return "on hiring: " + JSON.stringify(onHiring.trim()) + " -> on acme, with the refill held: " + JSON.stringify(onAcme.trim());
  });

  // **RAY'S CANDIDATE-.11 DEFECT 1.2 — "1 saved work records".**
  //
  // §1.2 of `docs/verification/2026-09-19-nightly-1.2.0-nightly.20260918.6-mac-and-android-audit.md`,
  // screenshots 06 and 08: a singular count with a plural noun, in the status line he reads
  // most often. The check above waits on the TWO-record form and would have passed for ever
  // with the one-record form broken, which is the whole reason this is a separate check: the
  // fixture that shows the defect is a fixture with exactly one receipt in it.
  //
  // Asserted over the WHOLE chip and not only the saved-work part, because the defect is that
  // the rule existed at three of its four sites. The chip now prints every count through one
  // `counted(n, singular, plural)`, so this check is what notices a fifth part that does not.
  await run.check("every count on the status line agrees with its own noun, at one and at more than one", async () => {
    const page = await browser.newPage({viewport: {width:1280, height:900}});
    const errors = []; page.on("pageerror", e => errors.push(String(e)));
    await page.addInitScript(() => window.__RICHOS_MOCK_PRESET__ = {workSummaries: {
      hiring: {items:[{title:"Reviewed change", role:"worker", repository:"/fictional/one", state:"integrated", detail:"Reviewed commit integrated locally. Whole assignment remains open."}], omitted:0}
    }});
    await page.goto("file://" + path.join(UI_DIR,"index.html")); await leaveHome(page);
    await openThread(page,"hiring");
    await page.waitForFunction(() => document.getElementById("drill-chip-zone").textContent.includes("saved work record"));
    const one = await page.textContent("#drill-chip-zone");
    assert(one.includes("1 saved work record"), `the chip reads ${JSON.stringify(one.trim())}`);
    assert(!one.includes("1 saved work records"), `singular count, plural noun: ${JSON.stringify(one.trim())}`);

    assertEqual(errors.length,0,"renderer errors"); await page.close();

    // POSITIVE CONTROL, on its own page: the plural must still be plural. Without it, "fix the
    // noun" could pass by printing the singular everywhere — the same defect facing the other
    // way, and a check that only ever sees one receipt cannot tell the two apart.
    const many = await browser.newPage({viewport: {width:1280, height:900}});
    await many.addInitScript(() => window.__RICHOS_MOCK_PRESET__ = {workSummaries: {
      hiring: {items:[
        {title:"Reviewed change", role:"worker", repository:"/fictional/one", state:"integrated", detail:"Reviewed commit integrated locally. Whole assignment remains open."},
        {title:"Second change", role:"worker", repository:"/fictional/two", state:"integrated", detail:"Reviewed commit integrated locally. Whole assignment remains open."}
      ], omitted:0}
    }});
    await many.goto("file://" + path.join(UI_DIR,"index.html")); await leaveHome(many);
    await openThread(many,"hiring");
    await many.waitForFunction(() => document.getElementById("drill-chip-zone").textContent.includes("saved work record"));
    const two = await many.textContent("#drill-chip-zone");
    assert(two.includes("2 saved work records"), `two receipts read ${JSON.stringify(two.trim())}`);
    await many.close();
    return `one receipt reads ${JSON.stringify(one.trim())}; two read ${JSON.stringify(two.trim())}`;
  });

  await browser.close(); process.exit(run.report()?1:0);
}
main().catch(e=>{console.error(e);process.exit(1);});

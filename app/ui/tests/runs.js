"use strict";
const path = require("path");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

async function main() {
  const { webkit } = loadPlaywright(); const browser = await webkit.launch();
  const run = createRun("Managed work runs"); const page = await browser.newPage();
  await page.setContent('<div id="managed-run"></div>');
  await page.addScriptTag({ path: path.join(UI_DIR, "runs.js") });
  await page.evaluate(() => {
    window.calls = []; window.listeners = {}; window.failure = "";
    window.snapshot = { threadId: "a", runId: "run-a", revision: 2, goal: "Finish the requested work", state: "paused", tasks: [
      { id: "one", description: "Build the requested result", state: "pending", checks: ["Acceptance"], attempts: 0, evidence: [] }
    ] };
    window.bridge = {
      listen(name, fn) { window.listeners[name] = fn; },
      async invoke(name, args) {
        window.calls.push([name, args]);
        if (name === "drive_run" && window.failure) throw Error(window.failure);
        if (name === "prepare_run") { window.snapshot.state = "paused"; }
        if (name === "pause_run") return;
        return JSON.parse(JSON.stringify(window.snapshot));
      }
    };
    window.RichRuns.mount(window.bridge, document.getElementById("managed-run"));
  });

  await run.check("A paused run stays unfinished when a model turn ends", async () => {
    await page.evaluate(() => window.RichRuns.show("a"));
    assert((await page.locator("summary").first().innerText()).includes("Paused"));
    await page.evaluate(() => { const cb = window.listeners["rich://turn-completed"]; if (cb) cb({ payload: { stopReason: "end_turn" } }); });
    assert(!(await page.locator("#managed-run").innerText()).includes("Completed"));
  });
  await run.check("Only a controller completion event removes the continuation controls", async () => {
    await page.evaluate(() => window.listeners["rich://run-updated"]({ payload: { ...window.snapshot, state: "completed" } }));
    assert((await page.locator("summary").first().innerText()).includes("Completed"));
    assertEqual(await page.getByRole("button", { name: "Start / continue", exact: true }).count(), 0);
  });
  await run.check("An event from another task cannot replace this task's run", async () => {
    await page.evaluate(() => window.listeners["rich://run-updated"]({ payload: { ...window.snapshot, threadId: "other", goal: "PRIVATE OTHER TASK" } }));
    assert(!(await page.locator("#managed-run").innerText()).includes("PRIVATE OTHER TASK"));
  });
  await run.check("An older revision or previous run cannot replace current state", async () => {
    await page.evaluate(() => {
      window.listeners["rich://run-updated"]({ payload: { ...window.snapshot, revision: 1, goal: "STALE SNAPSHOT" } });
      window.listeners["rich://run-updated"]({ payload: { ...window.snapshot, runId: "old-run", revision: 99, goal: "STALE SNAPSHOT" } });
    });
    assert(!(await page.locator("#managed-run").innerText()).includes("STALE SNAPSHOT"));
  });
  await run.check("Cancellation is not completion and offers a new plan", async () => {
    await page.evaluate(() => window.listeners["rich://run-updated"]({ payload: { ...window.snapshot, state: "cancelled" } }));
    assert((await page.locator("summary").first().innerText()).includes("Ended without completion"));
    assert(await page.getByRole("button", { name: "Load another work plan", exact: true }).isVisible());
  });
  await run.check("Execution errors remain visible after controls rerender", async () => {
    await page.evaluate(async () => { window.failure = "Cannot start this attempt"; await window.RichRuns.show("a"); });
    await page.getByRole("button", { name: "Start / continue", exact: true }).click();
    assert((await page.locator('[role="status"]').innerText()).includes("Cannot start this attempt"));
    assert(await page.getByRole("button", { name: "Start / continue", exact: true }).isEnabled());
  });
  await run.check("Pause is a real backend request scoped to this task", async () => {
    await page.getByRole("button", { name: "Pause run", exact: true }).click();
    assert(await page.evaluate(() => window.calls.some(([n, a]) => n === "pause_run" && a.threadId === "a")));
    assert((await page.locator('[role="status"]').innerText()).includes("Pause requested"));
  });
  await run.check("Preparing a file never executes it before Start", async () => {
    await page.evaluate(async () => { window.snapshot = null; await window.RichRuns.show("a"); window.calls = []; });
    await page.evaluate(() => {
      window.snapshot = { threadId: "a", goal: "Imported work", state: "paused", tasks: [] };
    });
    await page.getByLabel("Load a work plan").setInputFiles({ name: "plan.json", mimeType: "application/json", buffer: Buffer.from('{"goal":"Imported work"}') });
    await page.waitForFunction(() => window.calls.some(([n]) => n === "prepare_run"));
    assert(!(await page.evaluate(() => window.calls.some(([n]) => n === "drive_run"))));
  });
  await run.check("Task changes clear the old run and its failure message", async () => {
    await page.evaluate(() => window.RichRuns.show(null));
    assert(await page.locator("#managed-run").isHidden());
    assertEqual(await page.locator("#managed-run").innerText(), "");
  });
  await browser.close(); return run.report();
}
main().then(n => process.exit(n ? 1 : 0), e => { console.error(e); process.exit(1); });

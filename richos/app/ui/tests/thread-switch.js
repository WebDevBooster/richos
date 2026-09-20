"use strict";

const path = require("path");
const { spawnSync } = require("child_process");
const { loadPlaywright, leaveHome, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");
const APP = "file://" + path.join(UI_DIR, "index.html");

async function open(page, id) {
  await page.locator(`.nav-thread[data-thread-id="${id}"]`).click();
  await page.waitForFunction(() => document.querySelector("#composer-row").dataset.mode !== "opening");
}

async function holdActivation(page) {
  await page.evaluate(() => {
    const invoke = window.RichBridge.invoke.bind(window.RichBridge);
    window.activationGates = [];
    window.sentBindings = [];
    window.RichBridge.invoke = async (cmd, args) => {
      if (cmd === "switch_thread") await new Promise((resolve, reject) => {
        window.activationGates.push({ resolve, reject, thread: args.threadId });
      });
      if (cmd === "send_message") window.sentBindings.push(args);
      return invoke(cmd, args);
    };
  });
}

async function clickAndPaint(page, id) {
  return page.evaluate(async (thread) => {
    document.querySelector(`.nav-thread[data-thread-id="${thread}"]`).click();
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const pane = document.querySelector("#conversation");
    return {
      entity: document.querySelector("#scope-entity").textContent,
      title: document.querySelector("#scope-thread").textContent,
      text: pane.innerText,
      visible: !pane.hidden && pane.getBoundingClientRect().height > 0,
      opening: document.querySelector("#composer-row").dataset.mode === "opening",
    };
  }, id);
}

async function release(page, fail = false) {
  await page.waitForFunction(() => window.activationGates.length > 0);
  await page.evaluate(fail => {
    const gate = window.activationGates.shift();
    if (fail) gate.reject(new Error("The conversation could not be opened."));
    else gate.resolve();
  }, fail);
}

async function main() {
  const run = createRun("Thread display while activation is held");
  const browser = await loadPlaywright().webkit.launch();
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const errors = [];
  page.on("pageerror", error => errors.push(String(error)));
  try {
    await page.goto(APP);
    await leaveHome(page);
    await open(page, "hiring");
    const saved = "The hiring cache marker";
    await page.evaluate(text => window.__RICHOS_MOCK__.simulateSlowTurn("hiring", text, 80), saved);
    await page.waitForFunction(text => document.querySelector("#messages").innerText.includes(text), saved);
    const title = await page.locator("#scope-thread").innerText();
    await open(page, "acme");
    await holdActivation(page);

    await run.check("cached destination paints before backend activation", async () => {
      const view = await clickAndPaint(page, "hiring");
      assert(view.opening, "activation must still be held");
      assert(view.visible, "the conversation pane must be visible");
      assertEqual(view.title, title, "the breadcrumb names the selected destination");
      assert(view.text.includes(saved.trim()), "the saved destination messages remain visible");
      assert(!(await page.locator("body").innerText()).includes("Waiting for its saved messages"), "cached messages need no loading placeholder, including the wait band");
    });
    await release(page);
    await page.waitForFunction(() => document.querySelector("#composer-row").dataset.mode !== "opening");

    await run.check("a cache miss paints the destination and a loading state", async () => {
      const view = await clickAndPaint(page, "partner");
      assert(view.opening && view.visible, "cold destination is visible during activation");
      assert(view.title && view.title !== title, "the previous breadcrumb is gone");
      assert(view.text.includes("Waiting for its saved messages"), "the cache miss is explicit");
      assert(!view.text.includes(saved.trim()), "another entity's content cannot carry across");
      const ratios = [];
      for (const theme of ["light", "dark"]) {
        const colors = await page.evaluate(async theme => {
          document.documentElement.setAttribute("data-theme", theme);
          await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          const text = document.querySelector(".thread-loading");
          let background = text;
          while (background && ["rgba(0, 0, 0, 0)", "transparent"].includes(getComputedStyle(background).backgroundColor)) {
            background = background.parentElement;
          }
          return [getComputedStyle(text).color, getComputedStyle(background || document.body).backgroundColor];
        }, theme);
        const contrast = spawnSync("python3", [path.resolve(UI_DIR, "../scripts/qa/contrast.py"), ...colors], { encoding: "utf8" });
        assertEqual(contrast.status, 0, theme + ": " + contrast.stdout + contrast.stderr);
        ratios.push(theme + ": " + contrast.stdout.trim());
      }
      return ratios.join("; ");
    });

    await run.check("rapid navigation cannot let an older activation repaint the latest selection", async () => {
      const latest = await clickAndPaint(page, "hiring");
      await release(page); // partner
      await page.waitForFunction(() => window.activationGates.length > 0);
      assertEqual(await page.locator("#scope-thread").innerText(), latest.title, "late partner activation cannot paint");
      assert((await page.locator("#conversation").innerText()).includes(saved.trim()), "cached hiring remains displayed");
      await release(page); // hiring
      await page.waitForFunction(() => document.querySelector("#composer-row").dataset.mode !== "opening");
      const binding = await page.evaluate(() => window.RichBridge.invoke("active_context"));
      assertEqual(binding.thread_id, "hiring", "serialized activation ends on the last choice");
    });

    await run.check("a send waits for the confirmed destination", async () => {
      await clickAndPaint(page, "acme");
      await page.locator("#input").fill("Queued for Acme only");
      await page.locator("#input").press("Enter");
      assertEqual(await page.evaluate(() => window.sentBindings.length), 0, "activation is still held");
      await release(page);
      await page.waitForFunction(() => window.sentBindings.length === 1);
      const args = await page.evaluate(() => window.sentBindings[0]);
      assertEqual(args.threadId, "acme", "the held send carries the destination thread");
    });

    await run.check("activation failure does not expose cached content as an active conversation", async () => {
      await clickAndPaint(page, "hiring");
      await release(page, true);
      await page.waitForSelector("#unbound-view:not([hidden])");
      assert(await page.locator("#conversation").isHidden(), "failed activation hides the cached pane");
      assertEqual(await page.evaluate(() => window.sentBindings.length), 1, "no send occurred against failed activation");
    });
    await run.check("no browser errors", () => assertEqual(errors.length, 0, errors.join("\n")));
  } finally {
    await browser.close();
  }
  process.exitCode = run.report() ? 1 : 0;
}
main().catch(error => { console.error(error); process.exitCode = 1; });

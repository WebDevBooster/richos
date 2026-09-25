"use strict";
const path = require("path");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR, shot } = require("./lib/harness");

async function main() {
  const run = createRun("Desktop Claude Code quota settings");
  const browser = await loadPlaywright().webkit.launch();
  const errors = [];
  async function open(theme, quota, scale = 100) {
    const page = await browser.newPage({ viewport: { width: 1024, height: 700 } });
    page.setDefaultTimeout(5000);
    page.on("pageerror", e => errors.push(String(e)));
    await page.addInitScript(({ theme, quota, scale }) => {
      localStorage.setItem("richos-theme", theme);
      localStorage.setItem("richos-font-scale", String(scale));
      localStorage.setItem("richos-mock-config", JSON.stringify({ theme, font_scale: scale }));
      window.__RICHOS_MOCK_PRESET__ = { quota };
    }, { theme, quota, scale });
    await page.goto("file://" + path.join(UI_DIR, "index.html"));
    await page.waitForSelector("#set-btn");
    await page.evaluate(() => window.RichSplash.yieldNow("quota-test"));
    await page.click("#set-btn");
    return page;
  }
  async function enableTechnical(page) {
    await page.check("#set-techy");
    await page.waitForFunction(() => !document.getElementById("set-quota-open").hidden || !document.getElementById("techy-scope").hidden);
    if (await page.locator("#techy-scope").isVisible()) await page.click("#techy-scope-confirm");
    if (await page.locator("#set-menu").isHidden()) await page.click("#set-btn");
  }
  const now = Date.now();
  const quota = { state: "fresh", checkedAt: now, retryAt: null, message: null, windows: [
    { id: "five_hour", label: "Five-hour", usedPercent: 94, resetsAt: now + 2 * 3600000, durationMs: 5 * 3600000 },
    { id: "seven_day", label: "Weekly", usedPercent: 32, resetsAt: now + 4 * 86400000, durationMs: 7 * 86400000 },
    { id: "model:Sonnet", label: "Weekly · Sonnet", usedPercent: 12, resetsAt: now + 4 * 86400000, durationMs: 7 * 86400000 },
  ] };
  await run.check("quota stays hidden until technical view is enabled", async () => {
    const page = await open("dark", quota);
    assert(await page.locator("#set-quota-open").isHidden());
    await enableTechnical(page);
    await page.waitForSelector("#set-quota-open", { state: "visible" });
    await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window");
    assertEqual(await page.locator(".quota-window").count(), 3);
    assertEqual(await page.locator(".quota-remaining").first().innerText(), "6% left");
    assertEqual(await page.locator("#quota-threshold").inputValue(), "93");
    await page.check("#quota-enabled");
    await page.click("#quota-save");
    await page.waitForFunction(() => document.getElementById("quota-save-status").textContent === "Saved.");
    assert((await page.locator("#quota-hold-status").innerText()).includes("Holding"));
    await page.click("#quota-close");
    await page.click("#set-btn");
    await page.click("#set-quota-open");
    assert(await page.locator("#quota-enabled").isChecked(), "policy survives reopening");
    await page.uncheck("#quota-enabled");
    await page.click("#quota-save");
    await page.waitForFunction(() => document.getElementById("quota-hold-status").textContent.includes("off"));
    await page.keyboard.press("Escape");
    assert(await page.locator("#quota-sheet").isHidden());
    await page.waitForFunction(() => document.activeElement.id === "set-btn");
    await page.close();
  });
  for (const theme of ["dark", "light"]) {
    await run.check(theme + " layout fits the minimum desktop window and scrolls to all controls", async () => {
      const page = await open(theme, quota);
      await enableTechnical(page);
      await page.click("#set-quota-open");
      await page.waitForSelector(".quota-window");
      // The home screen intentionally stays dark. Set the document theme here to
      // exercise the sheet's light tokens independently of that home-only rule.
      await page.evaluate(t => document.documentElement.setAttribute("data-theme", t), theme);
      const box = await page.locator(".quota-panel").boundingBox();
      assert(box.x >= 0 && box.y >= 0 && box.x + box.width <= 1024 && box.y + box.height <= 700);
      assert(await page.evaluate(() => { const p = document.querySelector(".quota-panel"); return p.scrollWidth <= p.clientWidth; }));
      await page.locator("#quota-save").scrollIntoViewIfNeeded();
      assert(await page.locator("#quota-save").isVisible());
      await page.locator("#quota-title").scrollIntoViewIfNeeded();
      await shot(page, "claude-quota-" + theme, { fullPage: false });
      await page.setViewportSize({ width: 1200, height: 1100 });
      await shot(page, "claude-quota-full-" + theme, { fullPage: false });
      await page.close();
    });
  }
  await run.check("unavailable quota is never rendered as zero usage", async () => {
    const page = await open("dark", null);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector("#quota-empty", { state: "visible" });
    assertEqual(await page.locator("[role=meter]").count(), 0);
    assert((await page.locator("#quota-message").innerText()).includes("unavailable"));
    await page.close();
  });
  await run.check("stale quota is labelled and a failed refresh backoff disables refresh", async () => {
    const page = await open("dark", { ...quota, state: "stale", retryAt: now + 600000, message: "Could not refresh Claude Code quota." });
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window--stale");
    assert(await page.locator("#quota-refresh").isDisabled());
    assert((await page.locator("#quota-freshness").innerText()).includes("Stale"));
    await page.close();
  });
  await run.check("no renderer errors", async () => assertEqual(errors, []));
  await browser.close();
  process.exitCode = run.report() ? 1 : 0;
}
main().catch(e => { console.error(e); process.exitCode = 1; });

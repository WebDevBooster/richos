"use strict";
const path = require("path");
const contrast = require("./lib/contrast");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR, shot } = require("./lib/harness");

async function main() {
  const run = createRun("Desktop Claude Code quota settings");
  const browser = await loadPlaywright().webkit.launch();
  const errors = [];
  async function open(theme, quota, scale = 100, quotaActivity = null, enabled = false) {
    const page = await browser.newPage({ viewport: { width: 1024, height: 700 } });
    page.setDefaultTimeout(5000);
    page.on("pageerror", e => errors.push(String(e)));
    await page.addInitScript(({ theme, quota, scale, quotaActivity, enabled }) => {
      localStorage.setItem("richos-theme", theme);
      localStorage.setItem("richos-font-scale", String(scale));
      localStorage.setItem("richos-mock-config", JSON.stringify({ theme, font_scale: scale }));
      localStorage.setItem("richos-mock-quota-policy", JSON.stringify({enabled, pausePercent: 93}));
      window.__RICHOS_MOCK_PRESET__ = { quota, quotaActivity };
    }, { theme, quota, scale, quotaActivity, enabled });
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
    { id: "model:Fable", label: "Weekly · Fable", usedPercent: 12, resetsAt: now + 4 * 86400000, durationMs: 7 * 86400000 },
  ] };
  await run.check("quota stays hidden until technical view is enabled", async () => {
    const page = await open("dark", quota);
    assert(await page.locator("#set-quota-open").isHidden());
    await enableTechnical(page);
    await page.waitForSelector("#set-quota-open", { state: "visible" });
    await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window");
    assertEqual(await page.locator(".quota-window").count(), 3);
    assertEqual(await page.locator(".quota-window-label").last().innerText(), "Weekly · Fable");
    assertEqual((await page.locator(".quota-used").first().innerText()).replace(/\s+/g, ""), "94%used");
    assertEqual(await page.locator("#quota-threshold").inputValue(), "93");
    await page.click("#quota-enabled");
    await page.waitForFunction(() => document.getElementById("quota-save-status").textContent === "Saved.");
    assert((await page.locator("#quota-hold-status").innerText()).includes("Ready to pause"));
    await page.click("#quota-close");
    await page.click("#set-btn");
    await page.click("#set-quota-open");
    assertEqual(await page.locator("#quota-enabled").getAttribute("aria-checked"), "true");
    await page.click("#quota-enabled");
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
      await page.locator(".quota-boundary").scrollIntoViewIfNeeded();
      assert(await page.locator(".quota-boundary").isVisible());
      await page.locator("#quota-title").scrollIntoViewIfNeeded();
      await shot(page, "claude-quota-" + theme, { fullPage: false });
      await page.setViewportSize({ width: 1440, height: 900 });
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
  await run.check("inline threshold validation, Enter saves and Escape keeps without closing", async () => {
    const page = await open("dark", quota, 100, null, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window");
    for (const invalid of ["0", "100", "abc", ""]) {
      await page.fill("#quota-threshold", invalid);
      assert(await page.locator("#quota-validation").isVisible());
      assert(await page.locator("#quota-save").isDisabled());
    }
    await page.fill("#quota-threshold", "90");
    assertEqual(await page.locator("#quota-save").innerText(), "Save 90%");
    await page.keyboard.press("Escape");
    assert(await page.locator("#quota-sheet").isVisible());
    assertEqual(await page.locator("#quota-threshold").inputValue(), "93");
    await page.fill("#quota-threshold", "90");
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.querySelector(".quota-pause-line").textContent.includes("90%"));
    await page.fill("#quota-threshold", "92");
    await page.waitForTimeout(1200);
    assertEqual(await page.locator("#quota-threshold").inputValue(), "92");
    assertEqual(await page.evaluate(() => document.activeElement.id), "quota-threshold");
    await page.click("#quota-keep");
    assertEqual(await page.locator("#quota-threshold").inputValue(), "90");
    await page.close();
  });
  for (const theme of ["dark", "light"]) await run.check(theme + " actual pauses show names and release turns policy off", async () => {
    const activity = {held: [
      {kind: "agent", id: "worker-1", name: "Fable reviewer", task: "Review desktop settings", sinceAt: now - 120000, threadId: "test"},
      {kind: "agent", id: "worker-2", name: "Fable worker", task: "Check keyboard controls", sinceAt: now - 60000, threadId: "test"},
      {kind: "agent", id: "worker-3", name: "Fable tester", task: "Verify the pause rule", sinceAt: now - 30000, threadId: "test"},
    ], released: []};
    const page = await open(theme, quota, 100, activity, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForFunction(() => document.getElementById("quota-hold-status").textContent.includes("3 agents"));
    await page.evaluate(t => document.documentElement.setAttribute("data-theme", t), theme);
    await page.setViewportSize({width: 1440, height: 900});
    assertEqual(await page.locator("#quota-held li").count(), 3);
    assert(await page.evaluate(() => { const p = document.querySelector(".quota-body"); return p.scrollHeight <= p.clientHeight + 1; }), "holding sheet fits 1440 × 900");
    await shot(page, "claude-quota-holding-" + theme, {fullPage: false});
    await page.click("#quota-release");
    await page.waitForFunction(() => document.getElementById("quota-hold-status").textContent === "Pause released");
    assertEqual(await page.locator("#quota-enabled").getAttribute("aria-checked"), "false");
    await page.close();
  });
  await run.check("missing windows stay absent and low usage keeps the five minute cadence", async () => {
    const page = await open("dark", {...quota, windows: [{...quota.windows[0], usedPercent: 35}]});
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window");
    assertEqual(await page.locator("[role=meter]").count(), 1);
    assertEqual(await page.locator(".quota-absent").count(), 2);
    assert((await page.locator("#quota-freshness").innerText()).includes("5 min"));
    await page.close();
  });
  await run.check("paused conversation status is scoped and quota details require Technical view", async () => {
    const held = [{kind: "agent", id: "agt_frank_1", name: "Frank", sinceAt: now, threadId: "general"},
      {kind: "agent", id: "other", name: "Another thread", sinceAt: now, threadId: "elsewhere"}];
    const page = await open("dark", quota, 100, {held, released: []}, true);
    await page.click("#set-btn");
    await page.waitForFunction(() => !document.getElementById("quota-work-status").hidden);
    assertEqual(await page.locator("#quota-work-status").innerText(), "1 agent paused. Their work is saved.");
    assert((await page.locator("#drill-chip-zone").innerText()).includes("1 paused"));
    assert(!(await page.locator("#drill-chip-zone").innerText()).includes("1 working"));
    await page.evaluate(() => window.RichHome.hide("quota-test"));
    await page.click(".drill-chip");
    assert((await page.locator("#slideover-body").innerText()).includes("Frank · paused"));
    await page.keyboard.press("Escape");
    await page.click("#set-btn"); await enableTechnical(page);
    assert((await page.locator("#quota-work-status").innerText()).includes("for the quota"));
    assert((await page.locator("#quota-work-status").innerText()).includes("resume just after"));
    await page.close();
  });
  for (const theme of ["dark", "light"]) await run.check(theme + " state matrix fits and readable text meets contrast floors", async () => {
    const page = await open(theme, quota, 100, null, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window");
    await page.setViewportSize({width: 1440, height: 900});
    await page.evaluate(t => document.documentElement.setAttribute("data-theme", t), theme);
    await page.addScriptTag({content: contrast.pageScript()});
    const variants = [
      ["fresh", quota], ["low", {...quota, windows: [{...quota.windows[0], usedPercent: 30}, ...quota.windows.slice(1)]}],
      ["one-window", {...quota, windows: [quota.windows[0]]}],
      ["stale", {...quota, state: "stale", checkedAt: now - 3600000}],
      ["refresh-failed", {...quota, state: "stale", retryAt: now + 600000, message: "Could not refresh Claude Code quota."}],
      ["unavailable", {state: "unavailable", windows: [], checkedAt: null, message: "No current Claude Code reading."}],
    ];
    for (const [name, fixture] of variants) {
      await page.evaluate(f => { window.__RICHOS_MOCK_PRESET__.quota = f; }, fixture);
      await page.click("#quota-close"); await page.click("#set-btn"); await page.click("#set-quota-open");
      await page.waitForTimeout(150);
      if (name === "unavailable") assert((await page.locator("#quota-hold-status").innerText()).includes("Waiting for a current reading"));
      assert(await page.evaluate(() => { const p = document.querySelector(".quota-body"); return p.scrollHeight <= p.clientHeight + 1 && p.scrollWidth <= p.clientWidth; }), name + " fits");
      const failures = await page.evaluate(() => {
        const C = window.__contrastMath, failures = [];
        const root = document.querySelector(".quota-panel");
        for (const e of root.querySelectorAll("*")) {
          if (!e.getClientRects().length || e.closest("[hidden]") || e.classList.contains("sr-only")) continue;
          if (![...e.childNodes].some(n => n.nodeType === Node.TEXT_NODE && n.textContent.trim()) && e.tagName !== "INPUT") continue;
          const style = getComputedStyle(e), fg = C.parseCssColor(style.color);
          let bg = C.parseCssColor(getComputedStyle(root).backgroundColor);
          const chain = []; for (let p = e; p !== root; p = p.parentElement) chain.unshift(p);
          for (const p of chain) bg = C.compositeOver(C.parseCssColor(getComputedStyle(p).backgroundColor), bg);
          const size = parseFloat(style.fontSize), floor = size >= 24 || size >= 18.66 && parseInt(style.fontWeight) >= 700 ? 3 : 4.5;
          const ratio = C.round2(C.contrastRatio(C.compositeOver(fg, bg), bg));
          if (ratio < floor) failures.push({text: e.textContent.slice(0, 60), ratio, floor});
          if (size < 16 && !e.closest(".quota-chart-small") && !e.classList.contains("quota-eyebrow")) failures.push({text: e.textContent.slice(0, 60), size});
        }
        const style = getComputedStyle(root), surface = C.parseCssColor(style.backgroundColor);
        for (const token of ["--gold", "--ink", "--line-control"]) {
          const probe = document.createElement("span"); probe.style.color = `var(${token})`; root.appendChild(probe);
          const color = C.parseCssColor(getComputedStyle(probe).color); probe.remove();
          const ratio = C.round2(C.contrastRatio(C.compositeOver(color, surface), surface));
          if (ratio < 3) failures.push({indicator: token, ratio});
        }
        return failures;
      });
      assertEqual(failures, [], name + " contrast and type size");
    }
    await page.close();
  });
  await run.check("no renderer errors", async () => assertEqual(errors, []));
  await browser.close();
  process.exitCode = run.report() ? 1 : 0;
}
main().catch(e => { console.error(e); process.exitCode = 1; });

"use strict";
const path = require("path");
const contrast = require("./lib/contrast");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR, shot } = require("./lib/harness");

async function main() {
  const run = createRun("Desktop Claude Code quota settings");
  const browser = await loadPlaywright().webkit.launch();
  const errors = [];
  async function open(theme, quota, scale = 100, quotaActivity = null, enabled = false, options = {}) {
    const { fixedTime, ...pageOptions } = options;
    const page = await browser.newPage({ viewport: { width: 1024, height: 700 }, ...pageOptions });
    if (fixedTime) await page.clock.setFixedTime(fixedTime);
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
  await run.check("quota clock labels stay stable across second-boundary refreshes", async () => {
    const fixedTime = new Date("2026-09-26T06:20:00Z");
    for (const scenario of [
      { timezoneId: "Europe/London", weekly: "2026-09-30T07:59:59Z", five: ["5:40 AM", "10:40 AM"], week: "Wed 9:00 AM" },
      { timezoneId: "UTC", weekly: "2026-09-30T07:59:59Z", five: ["4:40 AM", "9:40 AM"], week: "Wed 8:00 AM" },
      { timezoneId: "Europe/London", weekly: "2026-10-06T22:59:59Z", five: ["5:40 AM", "10:40 AM"], week: "Wed 12:00 AM" },
    ]) {
      const fixture = { ...quota, checkedAt: +fixedTime, windows: quota.windows.map(w => ({ ...w,
        resetsAt: Date.parse(w.id === "five_hour" ? "2026-09-26T09:39:59Z" : scenario.weekly) })) };
      const page = await open("dark", fixture, 100, null, false,
        { locale: "en-US", timezoneId: scenario.timezoneId, fixedTime });
      try {
        await enableTechnical(page); await page.click("#set-quota-open");
        await page.waitForSelector(".quota-ends");
        const expected = ["began " + scenario.five[0], "resets " + scenario.five[1],
          "began " + scenario.week, "resets " + scenario.week, "began " + scenario.week, "resets " + scenario.week];
        const checkLabels = async () => {
          assertEqual((await page.locator(".quota-ends span").allTextContents()).map(t => t.replace(/\s+/g, " ")), expected);
          assert((await page.locator(".quota-hero .quota-reset").innerText()).replace(/\s+/g, " ").endsWith(scenario.five[1]));
        };
        await checkLabels();
        await page.evaluate(() => {
          const invoke = window.RichBridge.invoke.bind(window.RichBridge);
          window.__quotaTimeRefreshes = 0;
          window.RichBridge.invoke = async (cmd, ...args) => {
            const result = await invoke(cmd, ...args);
            if (cmd !== "claude_quota") return result;
            const n = ++window.__quotaTimeRefreshes;
            return { ...result, windows: result.windows.map(w => ({ ...w,
              usedPercent: 20 + n, resetsAt: w.resetsAt + (n % 2 ? 1000 : 0) })) };
          };
        });
        // Real refreshes alternate :59 and the following :00 for the same window.
        for (const used of [21, 22]) {
          await page.click("#quota-refresh");
          await page.waitForFunction(value => document.querySelector(".quota-used").firstChild.textContent === String(value), used);
          await checkLabels();
        }
      } finally { await page.close(); }
    }
  });
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
    await page.waitForFunction(() => document.getElementById("quota-hold-status").textContent.includes("Off. Nothing is paused."));
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
      await page.locator(".quota-boundary:not([hidden])").scrollIntoViewIfNeeded();
      assert(await page.locator(".quota-boundary:not([hidden])").isVisible());
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
  await run.check("stale quota is marked and a failed refresh says round 16's notice with Refresh still offered", async () => {
    const t = Date.now();
    const page = await open("dark", { ...quota, state: "stale", checkedAt: t - 47 * 60000, retryAt: t + 8 * 60000 + 20000, message: "Claude Code did not answer just now." });
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window--stale");
    // The failure's backoff holds only the automatic check; round 16: "Refresh asks sooner".
    assert(await page.locator("#quota-refresh").isEnabled(), "Refresh is never locked by a backoff");
    // Round 16: "Last reading 47 min ago — stale", in gold.
    assert(/^Last reading .+ ago — stale/.test(await page.locator("#quota-freshness").innerText()));
    assert(await page.locator("#quota-freshness.is-stale").count());
    assertEqual((await page.locator("#quota-message").innerText()).trim(),
      "Claude Code did not answer just now. The figures below are from 47 min ago and may have moved on. RichOS tries again in 8 min; Refresh asks sooner.");
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
    const fit = await page.evaluate(() => { const p = document.querySelector(".quota-body"); return [p.scrollHeight, p.clientHeight]; });
    assert(fit[0] <= fit[1] + 1, "holding sheet fits 1440 × 900: " + JSON.stringify(fit));
    await shot(page, "claude-quota-holding-" + theme, {fullPage: false});
    await page.click("#quota-release");
    await page.waitForFunction(() => document.getElementById("quota-hold-status").textContent === "Pause released");
    assertEqual(await page.locator("#quota-enabled").getAttribute("aria-checked"), "false");
    await page.close();
  });
  await run.check("weekly 99% names the weekly hold without promising the five-hour exception", async () => {
    const weekly = {...quota, windows: quota.windows.map(w => ({...w, usedPercent: w.id === "seven_day" ? 99 : 10}))};
    const activity = {held: [{kind: "agent", id: "weekly-worker", name: "Weekly worker", sinceAt: now - 1000}], released: [], resumesAt: now + 86400000};
    const page = await open("dark", weekly, 100, activity, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForFunction(() => document.getElementById("quota-hold-detail").textContent.includes("Weekly usage reached 99%"));
    assert(!(await page.locator("#quota-hold-detail").innerText()).includes("under 20 minutes"));
    assert(await page.locator("#quota-release").isEnabled());
    await page.click("#quota-release");
    await page.waitForFunction(() => document.getElementById("quota-enabled").getAttribute("aria-checked") === "false");
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
      // Walk of nightly 36, D1: the check came back with no figures (Claude Code's null answer).
      ["no-reading-null", {state: "unavailable", windows: [], checkedAt: null, retryAt: null, message: null, emptyAt: Date.now(), nextCheckAt: Date.now() + 300000}],
      ["null-over-reading", {...quota, windows: [{...quota.windows[0], usedPercent: 41}, quota.windows[1]], state: "stale", checkedAt: Date.now() - 6 * 60000, retryAt: null, message: null, emptyAt: Date.now(), nextCheckAt: Date.now() + 300000}],
      // Fill-first, round 16: two accounts, Switch chosen, fast use (2 points a minute) with
      // both check points recalculated (plan answer 10), one account not read yet.
      // The top-level windows are the account IN USE (quota.rs view_at), here Work.
      ["two-accounts", {...quota, windows: [{...quota.windows[0], usedPercent: 12}, {...quota.windows[1], usedPercent: 40}], refreshIntervalMs: 60000, speeds: {five_hour: 2 / 60000}, rises: {five_hour: {from: 40, to: 71, ms: 12 * 60000}}, agentsWorking: 15, actAt: {five_hour: 92, seven_day: 96}, atThreshold: "switch", accounts: [
        {id: "1", label: "Account 1", inUse: false, windows: quota.windows.slice(0, 2), checkedAt: now, exhaustedUntil: null, message: null},
        {id: "2", label: "Work", inUse: true, windows: [{...quota.windows[0], usedPercent: 12}, {...quota.windows[1], usedPercent: 40}], checkedAt: now, exhaustedUntil: null, message: null},
        {id: "3", label: "Spare", inUse: false, windows: [], checkedAt: null, exhaustedUntil: null, message: null}]}],
    ];
    for (const [name, fixture] of variants) {
      await page.evaluate(f => { window.__RICHOS_MOCK_PRESET__.quota = f; }, fixture);
      await page.click("#quota-close"); await page.click("#set-btn"); await page.click("#set-quota-open");
      await page.waitForTimeout(150);
      // Round 16's `hold-no-reading` while a check is on its way; once one came back empty,
      // nothing is held on the missing number (quota.rs Admission::NoReading).
      if (name === "unavailable") assertEqual(await page.locator("#quota-hold-status").innerText(), "Holding until there is a current reading.");
      if (name === "no-reading-null" || name === "null-over-reading") {
        assertEqual(await page.locator("#quota-hold-status").innerText(), "No current reading, so nothing is held.");
        assert(await page.locator("#quota-account-start").isVisible(), name + ": + Add account is offered");
        assert(await page.locator("#quota-refresh").isEnabled(), name + ": Refresh is offered");
      }
      if (name === "two-accounts") {
        // Round 16: the lanes in handover order (in use first, then by weekly reset, the
        // unread one last), the verb inside the sentence, the moved lines with their ghosts.
        assertEqual(await page.locator(".quota-lane-label").allTextContents(), ["Work", "Account 1", "Spare"]);
        assertEqual(await page.locator(".quota-lane.is-inuse .quota-lane-label").allTextContents(), ["Work"], "in use marks the account in use");
        assertEqual(await page.locator(".quota-lane.is-next .quota-lane-label").allTextContents(), ["Account 1"], "next is the read account with room");
        assertEqual(await page.locator("#quota-verb-switch").getAttribute("aria-checked"), "true", "the saved verb is shown");
        assert((await page.locator("#quota-freshness").innerText()).includes("every minute — usage is fast"));
        assertEqual((await page.locator(".quota-hero .quota-pause-line").innerText()).trim(), "switch at 92% · was 93%");
        assertEqual(await page.locator(".quota-pause-ghost").count(), 2, "both moved lines keep a ghost");
        assert((await page.locator(".quota-row-switch").innerText()).includes("switches at 96%"));
        assertEqual(await page.locator("#quota-hold-status").innerText(), "Usage is fast — checking every minute.");
        // Round 16's fast card: the agents counted and the rise measured, as the alert says them.
        assert((await page.locator("#quota-hold-detail").innerText()).startsWith("15 agents reading at once took Work’s five-hour window from 40% to 71% in 12 minutes."),
          await page.locator("#quota-hold-detail").innerText());
        // Round 16's reading line keeps + Add account and Refresh on its row; a long reading
        // wraps inside its own column (quota.html .reading, no wrap) instead of pushing them down.
        assert(await page.evaluate(() => document.querySelector(".quota-toolbar-actions").getBoundingClientRect().top
          < document.getElementById("quota-freshness").getBoundingClientRect().bottom), "Add account and Refresh stay on the reading's row");
        assertEqual(await page.locator('.quota-lane[data-id="1"] button').allTextContents(), [], "Account 1 has no Remove");
        assertEqual(await page.locator('.quota-lane[data-id="3"] button').allTextContents(), ["Sign in", "Remove"]);
      }
      // Several accounts add a row each, so that state may scroll vertically (never sideways),
      // and every one of its controls must then be reachable by scrolling. Every single-account
      // state, which is today's panel, still fits without scrolling.
      if (name === "two-accounts") {
        assert(await page.evaluate(() => { const p = document.querySelector(".quota-body"); return p.scrollWidth <= p.clientWidth; }), name + " never scrolls sideways");
        for (const control of await page.locator(".quota-lane button, .quota-opt, #quota-account-start").all()) {
          await control.scrollIntoViewIfNeeded(); assert(await control.isVisible(), name + " control reachable");
        }
      } else assert(await page.evaluate(() => { const p = document.querySelector(".quota-body"); return p.scrollHeight <= p.clientHeight + 1 && p.scrollWidth <= p.clientWidth; }), name + " fits");
      const failures = await page.evaluate(() => {
        const C = window.__contrastMath, failures = [];
        const root = document.querySelector(".quota-panel");
        for (const e of root.querySelectorAll("*")) {
          // Declared exemption (style.css, round 16 NOTES.md): the disabled, dimmed verbs while the switch is off.
          if (!e.getClientRects().length || e.closest("[hidden]") || e.classList.contains("sr-only") || e.closest(".quota-opts.is-off")) continue;
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
  const offer = { id: "launch", label: "Claude Opus 5.5 launch reset", remaining: 1,
    startsAt: now - 86400000, expiresAt: now + 27 * 86400000,
    clears: ["five_hour", "seven_day", "seven_day_overage_included"], usableNow: true, requiresLimit: false };
  const resetFixture = { state: "fresh", checkedAt: now, retryAt: null, offers: [offer], approval: null, lastAttempt: null, weeklyThreshold: 99, weeklyUsed: 32 };
  for (const theme of ["dark", "light"]) await run.check(theme + " weekly approval is explicit, early, one-use and revocable", async () => {
    const page = await open(theme, { ...quota, resets: resetFixture });
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector("#quota-reset-prepare-launch");
    await page.evaluate(t => document.documentElement.setAttribute("data-theme", t), theme);
    await page.setViewportSize({ width: 1440, height: 1200 });
    assert((await page.locator("#quota-reset-offers").innerText()).includes("99% weekly usage"));
    assert((await page.locator("#quota-reset-offers").innerText()).includes("weekly quota"));
    assertEqual(await page.evaluate(() => window.__richosResetCalls), []);
    await page.locator("#quota-reset-prepare-launch").scrollIntoViewIfNeeded();
    await shot(page, "claude-reset-offer-" + theme, { fullPage: false });
    await page.click("#quota-reset-prepare-launch");
    assertEqual(await page.evaluate(() => window.__richosResetCalls), []);
    await page.keyboard.press("Escape");
    assert(await page.locator("#quota-sheet").isVisible());
    assertEqual(await page.evaluate(() => window.__richosResetCalls), []);
    await page.click("#quota-reset-prepare-launch");
    await page.click("#quota-reset-confirm");
    await page.waitForSelector("#quota-reset-revoke");
    assertEqual(await page.evaluate(() => window.__richosResetCalls.map(c => c.cmd)), ["approve_claude_reset"]);
    assert((await page.locator("#quota-reset-offers").innerText()).includes("Approved and ready"));
    await page.click("#quota-close"); await page.click("#set-btn"); await page.click("#set-quota-open");
    await page.waitForSelector("#quota-reset-revoke");
    await page.locator("#quota-reset-revoke").scrollIntoViewIfNeeded();
    await shot(page, "claude-reset-armed-" + theme, { fullPage: false });
    await page.click("#quota-reset-revoke");
    await page.waitForSelector("#quota-reset-prepare-launch");
    assertEqual(await page.evaluate(() => window.__richosResetCalls.map(c => c.cmd)), ["approve_claude_reset", "revoke_claude_reset"]);
    await page.setViewportSize({width: 1024, height: 700});
    await page.locator("#quota-reset-prepare-launch").scrollIntoViewIfNeeded();
    assert(await page.evaluate(() => { const p = document.querySelector(".quota-body"); return p.scrollWidth <= p.clientWidth; }));
    await page.close();
  });
  await run.check("unknown, expired, five-hour-only and uncertain reset offers cannot be approved", async () => {
    const variants = [
      { ...resetFixture, state: "unknown", offers: [], message: "Reset availability unknown." },
      { ...resetFixture, offers: [{ ...offer, expiresAt: now - 1000 }] },
      { ...resetFixture, offers: [{ ...offer, clears: ["five_hour"] }] },
      { ...resetFixture, lastAttempt: { grantId: "launch", outcome: "uncertain" } },
      { ...resetFixture, lastAttempt: { grantId: "another-offer", outcome: "uncertain" } },
      { ...resetFixture, lastAttempt: { grantId: "launch", outcome: "notUsed" } },
    ];
    for (const resets of variants) {
      const page = await open("dark", { ...quota, resets });
      await enableTechnical(page); await page.click("#set-quota-open"); await page.waitForSelector(".quota-window");
      // With nothing to approve, revoke or check, round 16 draws nothing below the ruler key.
      const offered = resets.offers.some(o => o.expiresAt > now) || resets.lastAttempt;
      if (!offered) { assert(await page.locator("#quota-reset-offers").isHidden(), "nothing to act on: no reset section"); await page.close(); continue; }
      await page.waitForSelector("#quota-reset-offers p");
      assertEqual(await page.locator("#quota-reset-prepare-launch").count(), 0);
      assertEqual(await page.evaluate(() => window.__richosResetCalls), []);
      if (resets.lastAttempt?.outcome === "uncertain") {
        assert((await page.locator("#quota-reset-offers").innerText()).includes("Automatic retry is blocked"));
        await page.click("#quota-usage-open");
        assertEqual(await page.evaluate(() => window.__RICHOS_OPENED__), ["claude.ai/new#settings/usage"]);
        assertEqual(await page.evaluate(() => window.__richosResetCalls), []);
        await page.evaluate(() => {
          const original = window.RichBridge.invoke.bind(window.RichBridge);
          window.RichBridge.invoke = (cmd, args) => cmd === "open_external" ? Promise.reject("unavailable") : original(cmd, args);
        });
        await page.click("#quota-usage-open");
        await page.waitForFunction(() => document.getElementById("quota-reset-feedback").textContent.includes("Could not open"));
        assert((await page.locator("#quota-reset-feedback").innerText()).includes("claude.ai/new#settings/usage"));
      }
      await page.close();
    }
  });

  // ---- Round 16 (richos-hq design/mockups/rounds/round-16/, the CEO's chosen design) -------
  const twoAccounts = (extra = {}) => ({ ...quota, atThreshold: "pause", accounts: [
    { id: "1", label: "Home", inUse: true, windows: [{ ...quota.windows[0], usedPercent: 41 }, quota.windows[1]], checkedAt: now, exhaustedUntil: null, message: null },
    { id: "2", label: "Work", inUse: false, windows: [{ ...quota.windows[0], usedPercent: 10 }, { ...quota.windows[1], usedPercent: 20, resetsAt: now + 86400000 }], checkedAt: now, exhaustedUntil: null, message: null }],
    windows: [{ ...quota.windows[0], usedPercent: 41 }, quota.windows[1]], ...extra });
  await run.check("round 16, one account: + Add account beside Refresh and the five-minute reading line", async () => {
    const page = await open("dark", quota);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window");
    assertEqual(await page.locator(".quota-toolbar-actions button").allTextContents(), ["+ Add account", "Refresh"]);
    assert((await page.locator("#quota-freshness").innerText()).includes("checks every 5 min"));
    assert(await page.locator("#quota-lanes").isHidden(), "one account draws no lanes");
    assert(await page.locator("#quota-verbs").isHidden(), "one account keeps round 14's sentence");
    assertEqual(await page.locator("#quota-policy-title").innerText(), "Automatic pause");
    await page.close();
  });
  await run.check("round 16, Add account from one account names both, then the lanes and the verb appear", async () => {
    const page = await open("dark", quota, 100, null, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window");
    await page.click("#quota-account-start");
    assert(await page.locator("#quota-account-current").isVisible(), "the first account is named too");
    assertEqual(await page.locator("#quota-addform-title").innerText(), "Add a second Claude account");
    await page.fill("#quota-account-current", "Home");
    await page.fill("#quota-account-label", "Work");
    await page.click("#quota-account-add");
    await page.waitForSelector(".quota-lane");
    assertEqual(await page.locator(".quota-lane-label").allTextContents(), ["Home", "Work"]);
    // The lane waits with a pulse while Claude Code signs in through the browser; when the
    // sign-in ends (the preview's ends at once) it reads "Not read yet" with Sign in.
    assert((await page.locator('.quota-lane[data-id="2"]').innerText()).includes("signing in through your browser"));
    await page.waitForFunction(() => document.querySelector('.quota-lane[data-id="2"]').textContent.includes("Not read yet"));
    assertEqual(await page.locator("#quota-policy-title").innerText(), "Automatic pause or switch");
    assert(await page.locator("#quota-verbs").isVisible());
    assertEqual((await page.locator("#quota-sentence-lead").innerText()).trim(), "Once Home’s five-hour window passes");
    await page.close();
  });
  await run.check("round 16, the one decision: off dims the verbs and draws the line only; on, the verb moves the ruler label", async () => {
    const page = await open("light", twoAccounts(), 100, null, false);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-lane");
    assert(await page.locator("#quota-verb-switch").isDisabled(), "off: the verbs are disabled");
    assertEqual(await page.locator("#quota-hint").innerText(), "Off — nothing happens at 93%; the line is only drawn.");
    assertEqual((await page.locator(".quota-hero .quota-pause-line").innerText()).trim(), "off · 93%");
    assertEqual(await page.locator("#quota-hold-status").innerText(), "Off. Nothing is paused.");
    await page.click("#quota-enabled");
    await page.waitForFunction(() => !document.getElementById("quota-verb-switch").disabled);
    assertEqual((await page.locator(".quota-hero .quota-pause-line").innerText()).trim(), "pause at 93%");
    assertEqual(await page.locator("#quota-hold-status").innerText(), "On. Nothing is waiting.");
    assert((await page.locator("#quota-verb-switch").innerText()).includes("switch to Work, the next account"));
    await page.click("#quota-verb-switch");
    await page.waitForFunction(() => document.getElementById("quota-verb-switch").getAttribute("aria-checked") === "true");
    assertEqual((await page.locator(".quota-hero .quota-pause-line").innerText()).trim(), "switch at 93%");
    assertEqual(await page.locator("#quota-hold-status").innerText(), "On. Rich switches at the line.");
    await page.close();
  });
  await run.check("round 16, a lane shows its account's rulers; Remove asks once inline", async () => {
    const page = await open("dark", twoAccounts(), 100, null, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-lane");
    assertEqual(await page.locator(".quota-lane.is-next .quota-lane-label").allTextContents(), ["Work"]);
    await page.click('.quota-lane[data-id="2"] .quota-lane-label');
    await page.waitForFunction(() => document.querySelector(".quota-hero .quota-window-label").textContent.startsWith("Five-hour window · Work"));
    assertEqual(await page.locator(".quota-hero .quota-pause-line").count(), 0, "the line belongs to the account in use");
    await page.click('.quota-lane[data-id="2"] .quota-lane-remove');
    assert((await page.locator(".quota-lane-confirm").innerText()).includes("Its sign-in here is forgotten; nothing on the account itself changes."));
    await page.click("#quota-remove-no");
    assertEqual(await page.locator(".quota-lane-confirm").count(), 0, "Keep it keeps it");
    await page.click('.quota-lane[data-id="2"] .quota-lane-remove');
    await page.click("#quota-remove-yes");
    await page.waitForFunction(() => document.getElementById("quota-lanes").hidden);
    assertEqual(await page.locator("#quota-policy-title").innerText(), "Automatic pause", "down to one account: round 14's sheet");
    await page.close();
  });
  await run.check("round 16, the sheet after a switch and the hold when every account is used up", async () => {
    const switched = twoAccounts({ lastSwitch: { from: "1", to: "2", at: now - 4 * 60000, why: "fiveHour", used: 94 } });
    switched.accounts = switched.accounts.map(a => ({ ...a, inUse: a.id === "2", exhaustedUntil: a.id === "1" ? now + 2 * 3600000 : null }));
    let page = await open("dark", switched, 100, null, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-lane");
    assertEqual(await page.locator(".quota-lane-label").allTextContents(), ["Work", "Home"]);
    // Round 16's switched state: Home past the line at 94% has no room, but it is not used up
    // (no window at 100%), so its lane has no tag and still reads "week resets".
    assertEqual(await page.locator('.quota-lane[data-id="1"] .quota-lane-tag').count(), 0, "94% past the line is not used up");
    assert((await page.locator('.quota-lane[data-id="1"] .quota-lane-when').innerText()).startsWith("week resets"));
    assertEqual(await page.locator(".quota-lane.is-next").count(), 0, "no account has room, so none is next");
    assert((await page.locator("#quota-hold-status").innerText()).startsWith("In use: Work, since "));
    assert(/Rich switched from Home \d+ min ago at 94% of its five-hour window\./.test(await page.locator("#quota-hold-detail").innerText()));
    await page.close();
    const gone = twoAccounts({ heldUntil: now + 3600000 });
    gone.accounts = gone.accounts.map(a => ({ ...a, exhaustedUntil: now + (a.id === "1" ? 3600000 : 7200000) }));
    page = await open("dark", gone, 100, null, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-lane");
    assertEqual(await page.locator("#quota-hold-status").innerText(), "Every account is used up.");
    assert((await page.locator("#quota-hold-detail").innerText()).includes("when Home’s window resets — the soonest."));
    assertEqual(await page.locator(".quota-lane-tag.is-gone").count(), 1, "the account not in use reads used up");
    await page.close();
  });
  // ---- Round 16, the eleven differences echo-opus-panel16b closed ------------------------
  await run.check("round 16: Refresh has its icon, times read as round 16 writes them, the ruler key is round 16's, nothing below it", async () => {
    const page = await open("dark", twoAccounts(), 100, null, true, { viewport: { width: 1400, height: 835 } });
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-lane");
    assertEqual(await page.locator("#quota-refresh svg").count(), 1, "Refresh carries the circular-arrow icon");
    assertEqual((await page.locator("#quota-refresh").innerText()).trim(), "Refresh");
    // "Resets in <b>2 h</b> · at 3:40 PM": the span bold, then the clock.
    const hero = page.locator(".quota-hero .quota-reset");
    assert(/^Resets in (\d+ h( \d+ min)?|\d+ min) · at .+(AM|PM)$/.test((await hero.innerText()).trim()), await hero.innerText());
    assertEqual(await hero.locator("b").count(), 1, "the span is bold");
    assert(/^resets in \d+ d( \d+ h)?$/.test((await page.locator(".quota-weekly .quota-reset").first().innerText()).trim()));
    assertEqual(await page.locator(".quota-hero .quota-ends b").count(), 2, "began and resets times are bold");
    assertEqual((await page.locator(".quota-legend").innerText()).trim(),
      "The gold bar is what you have used; the tick is how far the clock has run. Bar past the tick means you are spending faster than the window is passing.");
    assertEqual(await page.locator(".quota-legend b").innerText(), "Bar past the tick means you are spending faster than the window is passing.");
    assert(await page.locator("#quota-reset-offers").isHidden(), "no reset offer: no section, no Open Claude Usage");
    assert(await page.locator("#quota-account-feedback").isHidden(), "no feedback line in a steady state");
    // Item 7: the two-account sheet fits the test VM's 1400 × 835 window without a scroll.
    assert(await page.evaluate(() => { const p = document.querySelector(".quota-body"); return p.scrollHeight <= p.clientHeight + 1; }), "two accounts fit 1400 × 835");
    await page.close();
  });
  await run.check("round 16: the working row names the account in use; Add and Remove say it in passing", async () => {
    const page = await open("dark", twoAccounts(), 100, { held: [], released: [] }, true);
    await page.click("#set-btn");
    // The preview's worker status has one agent active (mock.js get_worker_status).
    await page.waitForFunction(() => !document.getElementById("quota-work-status").hidden);
    assertEqual(await page.locator("#quota-work-status").innerText(), "1 agent working on Home");
    // Round 16 draws the row in the message column with a gold dot before it, not at the pane's edge.
    const row = await page.evaluate(() => {
      const box = e => { const r = e.getBoundingClientRect(), s = getComputedStyle(e); return {left: r.left + parseFloat(s.paddingLeft), width: r.width}; };
      const dot = getComputedStyle(document.getElementById("quota-work-status"), "::before");
      return {row: box(document.getElementById("quota-work-status")), messages: box(document.getElementById("messages")),
        dot: dot.content !== "none" && dot.width === "8px"};
    });
    assert(row.messages.width > 0 && Math.abs(row.row.left - row.messages.left) < 1, `the row starts at the message column's text edge: ${JSON.stringify(row)}`);
    assert(row.dot, `the working row has round 16's 8 px dot: ${JSON.stringify(row)}`);
    await page.click("#set-btn"); await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-lane");
    await page.click('.quota-lane[data-id="2"] .quota-lane-remove');
    // The passing line's 3.6 s is run on a fake clock, so the verdict never waits on the host.
    await page.clock.install();
    await page.click("#quota-remove-yes");
    await page.clock.runFor(1);
    assert((await page.locator("#quota-account-feedback").textContent()).includes("removed from this Mac"), "Remove says what it did");
    await page.clock.runFor(3499);
    assert((await page.locator("#quota-account-feedback").textContent()).includes("removed from this Mac"), "still said before 3.6 s");
    await page.clock.runFor(200);
    assertEqual(await page.locator("#quota-account-feedback").textContent(), "", "said in passing, then gone");
    await page.close();
  });
  // ---- Walk of nightly 36 (docs/verification/2026-10-05-nightly-36-candidate-walk.md) -------
  // D1: Claude Code 2.1.289 sometimes answers get_usage with `rate_limits: null`. Two published
  // shapes for that one answer: the service's on this branch (no reading this time, `emptyAt`),
  // and main's (`Malformed`, Refresh's ten-minute `retryAt`). On main's panel both lose
  // + Add account (no windows) and the second locks Refresh.
  await run.check("D1: a null answer is no reading this time: + Add account offered, Refresh never locked, nothing held", async () => {
    const shapes = {
      branch: { state: "unavailable", windows: [], checkedAt: null, retryAt: null, message: null, emptyAt: Date.now(), nextCheckAt: Date.now() + 300000 + 20000 },
      main: { state: "unavailable", windows: [], checkedAt: null, retryAt: Date.now() + 600000,
        message: "Claude Code returned quota data this version of RichOS could not read." },
    };
    for (const [name, fixture] of Object.entries(shapes)) {
      const page = await open("dark", fixture, 100, null, true);
      await enableTechnical(page); await page.click("#set-quota-open");
      await page.waitForSelector("#quota-empty", { state: "visible" });
      assert(await page.locator("#quota-account-start").isVisible(), name + ": + Add account is offered with no reading");
      assert(await page.locator("#quota-refresh").isEnabled(), name + ": Refresh is not locked");
      assertEqual((await page.locator("#quota-freshness").innerText()).trim(), "No reading yet.");
      assertEqual((await page.locator("#quota-refresh").innerText()).trim(), "Ask Claude Code", "round 16's label with no reading");
      if (name === "branch") {
        assert(await page.locator("#quota-message").isHidden(), "nothing is reported as broken");
        assert((await page.locator("#quota-empty").innerText()).includes("Claude Code answered without its usage figures this time"));
        assert((await page.locator("#quota-empty").innerText()).includes("RichOS asks again in 5 min"));
        assertEqual(await page.locator("#quota-hold-status").innerText(), "No current reading, so nothing is held.");
        assert(await page.locator("#quota-release").isHidden(), "nothing is held, so nothing to release");
      } else {
        // An answer that is genuinely unreadable is still named as unreadable.
        assert((await page.locator("#quota-message").innerText()).startsWith("Claude Code returned quota data this version of RichOS could not read."));
      }
      // + Add account opens the form from here.
      await page.click("#quota-account-start");
      assertEqual(await page.locator("#quota-addform-title").innerText(), "Add a second Claude account");
      await page.close();
    }
  });
  // D2: the fast card's dot and the signing lane's pulse breathe by size at full opacity
  // (the working row's 9cbdac8ea); the opacity breath measured 2.11:1 dark in the walk.
  await run.check("D2: the fast dot and the lane pulse keep full opacity at every phase and clear 3:1 in both themes", async () => {
    const fast = { ...quota, windows: [{ ...quota.windows[0], usedPercent: 71 }, quota.windows[1]], refreshIntervalMs: 60000,
      speeds: { five_hour: 3 / 60000 }, rises: { five_hour: { from: 40, to: 71, ms: 12 * 60000 } }, agentsWorking: 3, actAt: { five_hour: 82 } };
    const measured = [];
    for (const theme of ["dark", "light"]) {
      const page = await open(theme, fast, 100, null, true);
      await enableTechnical(page); await page.click("#set-quota-open");
      await page.waitForSelector(".quota-status-dot.is-fast");
      await page.evaluate(t => document.documentElement.setAttribute("data-theme", t), theme);
      await page.addScriptTag({ content: contrast.pageScript() });
      const found = await page.evaluate(() => {
        const C = window.__contrastMath, out = [];
        const probe = document.createElement("span"); probe.className = "quota-lane-pulse";
        document.querySelector(".quota-lane-note, .quota-status-card").appendChild(probe);
        for (const el of [document.querySelector(".quota-status-dot.is-fast"), probe]) {
          const frames = el.getAnimations().flatMap(a => a.effect.getKeyframes());
          const card = C.parseCssColor(getComputedStyle(document.getElementById("quota-status-card")).backgroundColor);
          const surface = C.parseCssColor(getComputedStyle(document.querySelector(".quota-panel")).backgroundColor);
          const gold = C.parseCssColor(getComputedStyle(el).backgroundColor);
          out.push({ cls: el.className, frames: frames.length, opacities: frames.map(f => f.opacity).filter(o => o !== undefined).map(Number),
            onCard: C.round2(C.contrastRatio(gold, C.compositeOver(card, surface))), onSurface: C.round2(C.contrastRatio(gold, surface)) });
        }
        probe.remove();
        return out;
      });
      for (const dot of found) {
        assert(dot.frames > 0, `${theme} ${dot.cls}: it still breathes`);
        assertEqual(dot.opacities.filter(o => o < 1), [], `${theme} ${dot.cls}: no keyframe dims it`);
        assert(dot.onCard >= 3 && dot.onSurface >= 3, `${theme} ${dot.cls}: 3:1 non-text floor ${JSON.stringify(dot)}`);
        measured.push(`${theme} ${dot.cls.replace("quota-", "")}: ${dot.onCard}:1 on the card, ${dot.onSurface}:1 on the surface`);
      }
      await page.close();
    }
    return measured.join("; ");
  });
  // D3: with one account, round 16's words in every state it draws (quota.html renderWindows,
  // renderHold), never round 14's, and never "Five-hour five-hour pause threshold".
  await run.check("D3: one account reads round 16's words: labels, sentence, hints, status card and boundary", async () => {
    const low = { ...quota, windows: [{ ...quota.windows[0], usedPercent: 41, resetsAt: now + (3 * 60 + 22) * 60000 }, quota.windows[1], quota.windows[2]] };
    let page = await open("light", low, 100, null, false);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForSelector(".quota-window");
    const text = id => page.locator(id).innerText().then(t => t.replace(/\s+/g, " ").trim());
    assertEqual(await text("#quota-lede"), "Straight from Claude Code, shared across every app and session on this account.");
    assertEqual(await page.locator(".quota-hero .quota-window-label").evaluate(e => [e.firstChild.textContent, e.querySelector(".quota-muted").textContent]),
      ["Five-hour window", "the one the pause watches"]);
    assertEqual(await page.locator(".quota-weekly .quota-window-label").allTextContents(), ["Weekly window", "Weekly · Fable"]);
    assert(!(await page.locator("#quota-sheet").textContent()).toLowerCase().includes("five-hour five-hour"), "no doubled word");
    assertEqual(await text("#quota-sentence-lead"), "Pause Rich’s agents once the five-hour window passes");
    assertEqual(await page.locator("#quota-sentence-end").textContent(), ", unless the reset is under 20 minutes away.");
    assertEqual(await text("#quota-hint"), "Off — the line is only drawn, not enforced.");
    assertEqual(await text("#quota-hold-status"), "Off. Nothing is paused.");
    assertEqual(await text("#quota-hold-detail"), "Rich’s agents keep working through the limit. When the five-hour window is spent, Claude Code turns them away until it resets — and Rich tells you.");
    assertEqual(await text("#quota-boundary-one"), "A pause is not a stop. Each agent finishes the step it is on, then waits before the next, keeping its place and everything it knows. Because a step is allowed to finish, usage can climb a little past the line. Your conversation with Rich, and any Claude Code you run outside RichOS, are never paused.");
    await page.click("#quota-enabled");
    await page.waitForFunction(() => document.getElementById("quota-hold-status").textContent === "On. Nothing is waiting.");
    assertEqual(await text("#quota-hint"), "Change the number to move the line.");
    assertEqual(await text("#quota-hold-detail"), "The five-hour window is at 41% used. Agents pause the moment it passes 93%, unless the reset is under 20 minutes away — then it is not worth stopping.");
    await page.close();
    // `hold-no-reading`: pause on, the reading 47 minutes old, its check on its way.
    page = await open("dark", { ...low, state: "stale", checkedAt: Date.now() - 47 * 60000 }, 100, null, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForFunction(() => document.getElementById("quota-hold-status").textContent.startsWith("Holding until"));
    assertEqual(await text("#quota-hold-detail"), "The last reading is 47 min old, and a rule needs a fresh one — an old number could let work through past the line. Nothing starts a new step until Claude Code answers.");
    assertEqual(await page.locator("#quota-sheet .quota-status-actions button:visible").allTextContents(), ["Refresh now", "Turn it off"]);
    await page.close();
    // `holding`: three agents past the line.
    const activity = { held: ["Mark", "Andy", "Tom"].map((name, i) => ({ kind: "agent", id: "w" + i, name, sinceAt: now - 41 * 60000, threadId: "test" })), released: [] };
    page = await open("dark", quota, 100, activity, true);
    await enableTechnical(page); await page.click("#set-quota-open");
    await page.waitForFunction(() => document.getElementById("quota-hold-status").textContent.startsWith("Holding 3 agents since "));
    assert(/^The five-hour window is at 94% used, past your 93% line\. Each has kept its place\. They resume at .+, 20 minutes before the reset, or sooner if a fresh reading is back under the line\.$/.test(await text("#quota-hold-detail")),
      await text("#quota-hold-detail"));
    await page.close();
  });
  await run.check("no renderer errors", async () => assertEqual(errors, []));
  await browser.close();
  process.exitCode = run.report() ? 1 : 0;
}
main().catch(e => { console.error(e); process.exitCode = 1; });

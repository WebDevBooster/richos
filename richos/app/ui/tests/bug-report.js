// BUST A BUG — round 21 in the shipping renderer (CEO §115, 2026-10-09).
//
// His words are the acceptance criterion: "When the user has Claude set up in the app (which is
// the expected default), we should just let the user say what's wrong and where and let their
// Rich check and articulate everything properly and then submit a GitHub issue on their behalf."
//
// What this suite holds the window to, against `mock.js`'s stand-in for the shell's six
// `bug_report_*` commands (the shell's own half, and what is private, are tested in Rust:
// crates/richos-core/tests/bug_report_tests.rs):
//
//   1. Bust a bug starts the exchange with Rich in the conversation on screen; no notice.
//   2. The draft is shown before anything is sent: nothing reaches `bug_report_send` until Send.
//   3. Private details are left out: the card shows stand-ins, each saying what it replaced only
//      to the user, and the sheet that is sent carries the stand-ins and never the names.
//   4. Send: the card says Sent with the issue number, from the RichOS reporting account.
//   5. A failed send is kept and resent: offline, the report waits on this Mac and goes out by
//      itself when the connection is back, and Rich and a notice say so.
//   6. Change it (in place, with the privacy heads-up, and by telling Rich), Cancel, and one
//      report at a time.
//   7. Where a window covers the conversation, the exchange happens in the Rich panel beside it.
//   8. Both themes: every word on the card and in the panel meets WCAG AA and the 16px floor,
//      and every indicator 3:1, computed in WebKit.
"use strict";

const path = require("path");
const fs = require("fs");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR, leaveHome, bootSettled, openThread } = require("./lib/harness");
const contrast = require("./lib/contrast");

const PRIVATE = ["Acme deal", "Northwind Traders", "/Users/you/Projects/northwind/notes.txt"];
const ANSWER =
  "In the Acme deal chat the names on the left get cut off when I make the text bigger. " +
  "Northwind Traders keeps its notes in /Users/you/Projects/northwind/notes.txt and those vanish too.";
const SHOTS = process.env.RICHOS_BUG_SHOTS || "";

async function main() {
  const run = createRun("Bust a bug: Rich writes it up, the user approves it, and it is filed");
  const browser = await loadPlaywright().webkit.launch();
  const errors = [];

  async function open(theme, preset, viewport) {
    const page = await browser.newPage({ viewport: viewport || { width: 1440, height: 900 }, locale: "en-US" });
    page.setDefaultTimeout(30000); // a hang guard only; every wait below waits for a fact
    page.on("pageerror", (e) => errors.push(String(e)));
    await page.addInitScript(({ theme, preset }) => {
      localStorage.setItem("richos-theme", theme);
      localStorage.setItem("richos-mock-config", JSON.stringify({ theme, font_scale: 100 }));
      window.__RICHOS_MOCK_PRESET__ = Object.assign({ bugWriteMs: 300 }, preset);
    }, { theme, preset: preset || {} });
    await page.goto("file://" + path.join(UI_DIR, "index.html"));
    await leaveHome(page);
    await bootSettled(page);
    await openThread(page, "acme");
    await page.evaluate((t) => document.documentElement.setAttribute("data-theme", t), theme);
    return page;
  }
  async function bustABug(page) {
    await page.click("#set-btn");
    await page.waitForSelector("#bug-btn");
    await page.click("#bug-btn");
  }
  async function answer(page, text) {
    await page.fill("#input", text);
    await page.keyboard.press("Enter");
    await page.waitForSelector(".bugcard .bug-pill:has-text('Not sent yet')");
  }
  /// Rich's last words in the exchange: his line(s), without the speaker label.
  const lastSaid = (page, scope) =>
    page.locator((scope || "#bug-flows") + " .bug-rich").last().locator(".tl-prose").allInnerTexts().then((t) => t.join("\n"));
  const calls = (page, cmd) => page.evaluate((c) => window.__RICHOS_MOCK_BUG__.calls.filter((x) => x.cmd === c), cmd);
  const settle = (page) => page.evaluate(() => Promise.all(document.getAnimations().filter((a) => a.effect && a.effect.getTiming().iterations !== Infinity).map((a) => a.finished.catch(() => null))));
  async function shot(page, name) {
    if (!SHOTS) return;
    fs.mkdirSync(SHOTS, { recursive: true });
    await settle(page);
    await page.screenshot({ path: path.join(SHOTS, name + ".png") });
  }

  await run.check("Bust a bug starts the exchange with Rich in the conversation on screen, not a notice", async () => {
    const page = await open("dark");
    const before = await page.locator("#messages .tl-user").count();
    await bustABug(page);
    await page.waitForSelector("#bug-flows .bugflow .bug-divider");
    assert(await page.isHidden("#set-menu"), "Settings stayed open");
    assertEqual(await page.locator("#bug-toast:visible").count(), 0, "the old notice is still what the button does");
    const asked = await page.locator("#bug-flows .bug-rich .tl-prose").first().innerText();
    assert(asked.startsWith("What went wrong? Tell me in your own words, typed or out loud"), asked);
    assert(asked.includes("I've noted that you were on the Acme deal conversation."), asked);
    assertEqual(await page.getAttribute("#input", "placeholder"), "Tell Rich what went wrong…", "the composer does not say what it is waiting for");
    assert(await page.isVisible("#bug-never-mind"), "no way out before answering");
    await shot(page, "ask-dark");
    // Never mind ends it with nothing written up, and the composer is Rich's again.
    await page.click("#bug-never-mind");
    await page.waitForSelector("#bug-flows .bug-rich:has-text('No problem. Nothing was written up or sent.')");
    assertEqual(await page.getAttribute("#input", "placeholder"), "Talk to Rich…", "the composer still belongs to the report");
    assertEqual(await page.locator("#messages .tl-user").count(), before, "a message went to Rich's conversation");
    await page.close();
    return asked;
  });

  await run.check("the whole report is shown before anything is sent, and private details are left out", async () => {
    const page = await open("dark");
    const before = await page.locator("#messages .tl-user").count();
    await bustABug(page);
    await page.fill("#input", ANSWER);
    await page.keyboard.press("Enter");
    await page.waitForSelector(".bug-working:has-text('Rich is checking…')");
    await page.waitForSelector(".bugcard .bug-pill:has-text('Not sent yet')");
    // The words were the report's: in the exchange, and not a message to Rich's conversation.
    assertEqual(await page.locator("#messages .tl-user").count(), before, "the answer went to Rich's conversation");
    assert((await page.locator("#bug-flows .bug-user").innerText()).includes("Acme deal chat"), "the answer is not shown as the user's");
    assertEqual((await calls(page, "bug_report_write")).length, 1, "Rich was not asked to write it up");
    assertEqual((await calls(page, "bug_report_send")).length, 0, "something was sent before Send");
    assert((await page.locator(".bug-turn .tl-duration-label").innerText()).startsWith("Worked for "), "no Worked for line");
    // What goes to GitHub is on the card, and the names are not.
    const sheetText = await page.locator(".bugcard .bug-doc").innerText();
    for (const p of PRIVATE) assert(!sheetText.includes(p), `"${p}" is on the report: ${sheetText}`);
    const subs = await page.locator(".bugcard .bug-sub").evaluateAll((n) => n.map((s) => [s.textContent, s.dataset.was]));
    for (const p of PRIVATE) assert(subs.some(([, was]) => was === p), `no stand-in for "${p}": ${JSON.stringify(subs)}`);
    assert(subs.every(([text]) => /^\[.+\]$/.test(text)), JSON.stringify(subs));
    // Each stand-in is MARKED: a dotted rule under it, drawn as a border because the test VM's
    // WKWebView painted no `text-decoration` underline there (walk-aba5c01c19ce).
    const marks = await page.locator(".bugcard .bug-sub").evaluateAll((n) => n.map((s) => { const c = getComputedStyle(s); return c.borderBottomStyle + " " + parseFloat(c.borderBottomWidth); }));
    assert(marks.every((m) => m === "dotted 2"), "a stand-in is not marked: " + JSON.stringify(marks));
    const from = await page.locator(".bugcard .r-from").innerText();
    assertEqual(from, "the RichOS reporting account, because RichOS isn't signed in to a GitHub account of yours", "From");
    assert((await page.locator(".bugcard .lo-text").innerText()).startsWith("Left out, because anyone can read GitHub issues: "), "no left-out line");
    // Pointing at a stand-in (and tabbing to one) says what it replaced, to this user only.
    await page.hover(".bugcard .bug-sub >> nth=0");
    await page.waitForSelector("#bug-subtip.is-shown");
    const tip = await page.locator("#bug-subtip").innerText();
    assert(/^Stands in for “.+”, an? .+\. Only you see this; it isn't in the report\.$/.test(tip), tip);
    await page.mouse.move(5, 5);
    await page.focus(".bugcard .bug-sub >> nth=1");
    await page.waitForSelector("#bug-subtip.is-shown");
    await page.locator(".bugcard .bug-sub >> nth=1").blur();
    for (const id of ["#bug-send", "#bug-change", "#bug-cancel"]) assert(await page.isVisible(id), id + " is not offered");
    await shot(page, "report-dark");
    await page.close();
    return `${subs.length} stand-ins; tooltip: ${tip}`;
  });

  await run.check("Send files it, from the RichOS reporting account, with the words the card showed", async () => {
    const page = await open("dark");
    await bustABug(page);
    await answer(page, ANSWER);
    const shown = await page.locator(".bugcard .bug-doc").innerText();
    await page.click("#bug-send");
    await page.waitForSelector(".bugcard.is-sent .bug-pill:has-text('Sent · #412')");
    const said = await lastSaid(page);
    assert(said.includes("Sent. It's issue #412 on GitHub, filed from the RichOS reporting account, because RichOS isn't signed in to a GitHub account of yours."), said);
    assert(said.includes("github.com/WebDevBooster/richos/issues/412"), said);
    const sent = (await calls(page, "bug_report_send"))[0].sheet;
    const words = [sent.title, ...sent.sections.flatMap((s) => [s.heading, ...s.paragraphs, ...s.steps])].join("\n");
    for (const p of PRIVATE) assert(!words.includes(p), `"${p}" was sent: ${words}`);
    // Word for word what the card showed (the card's text is the title and sections in order).
    assertEqual(words.replace(/\s+/g, " ").trim(), shown.replace(/\s+/g, " ").trim(), "what was sent is not what was shown");
    // The link opens the issue by its number, never by an address the page passes.
    await page.click(".bug-sentrow .bug-link");
    assertEqual((await calls(page, "bug_report_open_issue"))[0].number, 412, "Open issue");
    assertEqual(await page.getAttribute("#input", "placeholder"), "Talk to Rich…", "the composer still belongs to the report");
    await shot(page, "sent-dark");
    await page.close();
    return said.split("\n")[0];
  });

  await run.check("a failed send is kept on this Mac and goes out by itself when the connection is back", async () => {
    const page = await open("dark", { bugNet: "offline" });
    await bustABug(page);
    await answer(page, ANSWER);
    await page.click("#bug-send");
    await page.waitForSelector(".bugcard.is-queued .bug-pill:has-text('Waiting to send · saved on this Mac')");
    const line = await lastSaid(page);
    assert(line.includes("This Mac is offline, so the report didn't go out. Nothing is lost: it's saved on this Mac exactly as you approved it."), line);
    for (const id of ["#bug-try-now", "#bug-change", "#bug-cancel"]) assert(await page.isVisible(id), id + " is not offered");
    assertEqual((await page.evaluate(() => window.__RICHOS_MOCK_BUG__.waiting())).length, 1, "the report is not kept");
    await shot(page, "queued-dark");
    // Try now while still offline: it stays waiting and says so.
    await page.click("#bug-try-now");
    await page.waitForSelector(".bugcard.is-queued");
    // Back online: it goes out by itself, and Rich and a notice say so.
    await page.evaluate(() => window.__RICHOS_MOCK_BUG__.setNet("online"));
    await page.waitForSelector(".bugcard.is-sent .bug-pill:has-text('Sent · #412')");
    const back = await lastSaid(page);
    assert(back.startsWith("You're back online, so I sent your bug report. It's issue #412 on GitHub,"), back);
    await page.waitForSelector("#bug-toast:has-text('Your bug report went out: issue #412 on GitHub.')");
    assertEqual((await page.evaluate(() => window.__RICHOS_MOCK_BUG__.waiting())).length, 0, "still waiting after it went out");
    await page.close();
    return back.split("\n")[0];
  });

  await run.check("GitHub down says so, and a report waiting to send that is changed waits for Send again", async () => {
    const page = await open("dark", { bugNet: "down" });
    await bustABug(page);
    await answer(page, "Not now fades a suggestion but leaves it.");
    await page.click("#bug-send");
    await page.waitForSelector(".bugcard.is-queued");
    const line = await lastSaid(page);
    assert(line.startsWith("GitHub isn't answering right now, so the report didn't go out."), line);
    await page.click("#bug-change");
    await page.waitForSelector(".bugcard.is-editing");
    assertEqual((await page.evaluate(() => window.__RICHOS_MOCK_BUG__.waiting())).length, 0, "the old copy still waits to go out");
    await page.click("#bug-done");
    await page.waitForSelector(".bugcard .bug-pill:has-text('Not sent yet · changed')");
    await page.close();
    return line.split(".")[0];
  });

  await run.check("Change it: in place with a privacy heads-up, by telling Rich, and Cancel", async () => {
    const page = await open("dark");
    await bustABug(page);
    await answer(page, "The names on the left get cut off when the text is bigger.");
    await page.click("#bug-change");
    await page.waitForSelector(".bugcard.is-editing .bug-pill:has-text('Changing it')");
    assert(await page.isVisible(".bug-edithint"), "no hint while changing it");
    assertEqual(await page.evaluate(() => document.activeElement.classList.contains("bug-title")), true, "the title is not where the cursor is");
    await page.keyboard.type(" for Acme deal");
    await page.waitForSelector(".bug-warn:not([hidden])");
    const warn = await page.locator(".bug-warn").innerText();
    assertEqual(warn, "“Acme deal” looks private. Anyone can read this report on GitHub.", "heads-up");
    await shot(page, "warn-dark");
    await page.click("#bug-done");
    await page.waitForSelector(".bugcard .bug-pill:has-text('Not sent yet · changed')");
    assert(await page.isVisible(".bug-warn"), "the heads-up went away while the private word is still there");
    // Told to Rich: he adds it to What happened and says so.
    await page.fill("#input", "Also say it happens in the light theme too");
    await page.keyboard.press("Enter");
    await page.waitForSelector(".bug-sec p.is-added");
    assertEqual(await page.locator(".bug-sec p.is-added").innerText(), "It happens in the light theme too.", "the change");
    await page.waitForSelector("#bug-flows .bug-rich:has-text('Added that to What happened, above. It still waits for you to send it.')");
    await shot(page, "changed-dark");
    // One report at a time: Bust a bug again goes back to this one.
    await bustABug(page);
    assertEqual(await page.locator("#bug-flows .bugflow").count(), 1, "a second report was started");
    await page.click("#bug-cancel");
    await page.waitForSelector(".bugcard.is-canceled .bug-pill:has-text('Canceled · nothing sent')");
    assert((await page.locator(".bug-ctitle").innerText()).includes("for Acme deal"), "the folded card does not show its title");
    await page.waitForSelector("#bug-flows .bug-rich:has-text('Canceled. Nothing was sent.')");
    assertEqual((await calls(page, "bug_report_send")).length, 0, "a canceled report was sent");
    await shot(page, "canceled-dark");
    await page.close();
    return warn;
  });

  await run.check("where a window covers the conversation, the exchange happens in the Rich panel beside it", async () => {
    const page = await open("dark");
    await page.click("#nav-corrections");
    await page.waitForSelector("#corrections-overlay:not([hidden])");
    await bustABug(page);
    await page.waitForSelector("#bugdock:not([hidden])");
    assertEqual(await page.locator("#bugdock-where").innerText(), "· Corrections", "panel header");
    assert(await page.isVisible("#corrections-overlay"), "the window did not stay open");
    assertEqual(await page.locator("#bug-flows .bugflow").count(), 0, "it also started in the conversation");
    const asked = await page.locator("#bugdock-msgs .bug-rich .tl-prose").first().innerText();
    assert(asked.includes("I've noted that you were in Corrections, and it stays open beside us."), asked);
    // Side by side: the window moved left of the panel.
    const panel = await page.locator("#bugdock").boundingBox();
    const win = await page.locator("#corrections-overlay .overlay-panel").boundingBox();
    assert(win.x + win.width <= panel.x, `the window is under the panel: ${JSON.stringify({ win, panel })}`);
    await page.fill("#bugdock-input", "When I press Not now on a suggestion it fades but stays there.");
    await page.keyboard.press("Enter");
    await page.waitForSelector("#bugdock .bugcard .bug-pill:has-text('Not sent yet')");
    assert(await page.isHidden("#bugdock-x"), "the panel can be closed while the report waits on a decision");
    await shot(page, "dock-report-dark");
    await page.click("#bugdock #bug-send");
    await page.waitForSelector("#bugdock .bugcard.is-sent");
    assert(await page.isVisible("#bugdock-x"), "no way to close the panel after sending");
    await page.click("#bugdock-x");
    await page.waitForSelector("#bugdock", { state: "hidden" });
    assert(await page.isVisible("#corrections-overlay"), "closing the panel closed the window");
    await page.close();
    return asked;
  });

  // ---- both themes: contrast, the type floor, indicators ----
  const ROOTS = "#bug-flows, #bugdock:not([hidden]), #bug-subtip.is-shown";
  // Declared skippable, each the conversation's own 14px tier (style.css's Bust a bug note).
  const SKIPPABLE = ".tl-rich-meta, .bug-worked, .bug-digest, .bugdock-send";
  const INDICATORS = [
    [".bugcard.is-sent", "borderTopColor"], [".bugcard.is-queued", "borderTopColor"], [".bug-pill", "borderTopColor"],
    [".bug-sub", "borderBottomColor"], [".bug-warn", "borderLeftColor"], [".bugcard.is-editing .bug-doc", "borderTopColor"],
    [".desk-btn--confirm", "backgroundColor"], [".desk-btn:not(.desk-btn--confirm)", "borderTopColor"], [".bugdock-form", "borderTopColor"],
  ];
  const STATES = [
    ["report", async (p) => { await bustABug(p); await answer(p, ANSWER); await p.hover(".bugcard .bug-sub >> nth=0"); await p.waitForSelector("#bug-subtip.is-shown"); }],
    ["editing", async (p) => { await bustABug(p); await answer(p, ANSWER); await p.click("#bug-change"); await p.keyboard.type(" Acme deal"); await p.waitForSelector(".bug-warn:not([hidden])"); }],
    ["sent", async (p) => { await bustABug(p); await answer(p, ANSWER); await p.click("#bug-send"); await p.waitForSelector(".bugcard.is-sent"); }],
    ["queued", async (p) => { await bustABug(p); await answer(p, ANSWER); await p.click("#bug-send"); await p.waitForSelector(".bugcard.is-queued"); }, { bugNet: "offline" }],
    ["canceled", async (p) => { await bustABug(p); await answer(p, ANSWER); await p.click("#bug-cancel"); await p.waitForSelector(".bugcard.is-canceled"); }],
    ["panel", async (p) => { await p.click("#nav-corrections"); await bustABug(p); await p.fill("#bugdock-input", ANSWER); await p.keyboard.press("Enter"); await p.waitForSelector("#bugdock .bugcard .bug-pill:has-text('Not sent yet')"); }],
  ];
  for (const theme of ["dark", "light"]) {
    await run.check(theme + ": every Bust a bug state meets AA contrast, the 16px floor and 3:1 for indicators", async () => {
      const measured = [];
      for (const [name, drive, preset] of STATES) {
        const page = await open(theme, preset);
        await drive(page);
        await settle(page);
        await shot(page, name + "-" + theme);
        await page.addScriptTag({ content: contrast.pageScript() });
        const result = await page.evaluate(({ ROOTS, SKIPPABLE, INDICATORS }) => {
          const C = window.__contrastMath, failures = [];
          let worst = 99, worstIndicator = 99, nodes = 0;
          const ground = (el) => {
            let bg = { r: 0, g: 0, b: 0, a: 0 };
            const chain = [];
            for (let p = el; p; p = p.parentElement) chain.unshift(p);
            for (const p of chain) bg = C.compositeOver(C.parseCssColor(getComputedStyle(p).backgroundColor), bg);
            return bg;
          };
          const ratioOn = (paint, bg) => { const c = C.parseCssColor(paint); return c ? C.round2(C.contrastRatio(C.compositeOver(c, bg), bg)) : 0; };
          for (const root of document.querySelectorAll(ROOTS)) {
            if (!root.getClientRects().length) continue;
            for (const e of [root, ...root.querySelectorAll("*")]) {
              if (!e.getClientRects().length || e.closest("[hidden]") || e.closest(".sr-only")) continue;
              const own = [...e.childNodes].some((n) => n.nodeType === Node.TEXT_NODE && n.textContent.trim());
              if (!own) continue;
              const style = getComputedStyle(e);
              if (style.visibility === "hidden" || style.display === "none") continue;
              const bg = ground(e), fg = C.compositeOver(C.parseCssColor(style.color), bg);
              const size = parseFloat(style.fontSize), large = size >= 24 || (size >= 18.66 && parseInt(style.fontWeight) >= 700);
              const ratio = C.round2(C.contrastRatio(fg, bg));
              nodes++;
              worst = Math.min(worst, ratio);
              if (ratio < (large ? 3 : 4.5)) failures.push({ text: e.textContent.trim().slice(0, 50), ratio });
              if (size < 16 && !e.closest(SKIPPABLE)) failures.push({ text: e.textContent.trim().slice(0, 50), size });
            }
            for (const [sel, prop] of INDICATORS) {
              for (const e of root.querySelectorAll(sel)) {
                if (!e.getClientRects().length || e.closest("[hidden]")) continue;
                const ratio = ratioOn(getComputedStyle(e)[prop], ground(e.parentElement));
                worstIndicator = Math.min(worstIndicator, ratio);
                if (ratio < 3) failures.push({ indicator: sel, ratio });
              }
            }
          }
          return { failures, worst, worstIndicator, nodes };
        }, { ROOTS, SKIPPABLE, INDICATORS });
        assertEqual(result.failures, [], `${theme} ${name}: contrast and type`);
        assert(result.nodes > 10, `${theme} ${name}: EMPTY INVENTORY (${result.nodes} nodes)`);
        measured.push(`${name} ${result.worst}:1 text / ${result.worstIndicator}:1 indicator over ${result.nodes} nodes`);
        await page.close();
      }
      return measured.join("; ");
    });
  }

  await run.check("no renderer errors on any page", async () => {
    assertEqual(errors, [], "page errors");
    return "0 page errors";
  });

  await browser.close();
  process.exit(run.report() ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

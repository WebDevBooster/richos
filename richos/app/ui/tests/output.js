// THE OUTPUT PANEL — slice S4 of the Output side panel PRD, driven through the REAL SHELL:
// `index.html`, `main.js`, `output-panel.js`, `timeline.js`, `mock.js` and `style.css`, loaded
// from disk, with nothing stubbed but the Tauri bridge (which `mock.js` already replaces).
//
// The CEO, 2026-10-05: "a button here … ideally, at the top and at the bottom, so that the user
// can easily just click a button. And the entire, this entire side panel would open … with a list
// of all the files … that were output by this entire thread. This is what we need."
//
// richos-hq `docs/prds/2026-10-05-output-side-panel.md` §12.4 names what this suite proves, and
// its "Done when": round 17's states `closed`, `open`, `empty`, `from-link`, `from-digest` and
// `arrives` are reproducible in the shell from `mock.js` fixtures. Each of the six is a check
// below, named by the state it reproduces.
//
// THE FIXTURE is `mock.js`'s `{ output: "round-17" }` preset: the mockup's nine files across four
// turns of the `acme` thread, Rich's replies naming files in code spans, one file by a worker; the
// `hiring` thread ("Q4 hiring", the mockup's own empty thread) has none. Without the preset every
// thread's record is empty, which is what every OTHER suite photographs.
//
// THE CLOCK IS FIXED (`page.clock.setFixedTime`, New York, 2026-10-05 09:45) so the group times
// read the same on every run and the committed pictures do not move with the hour of the run.
// Timers still run, so the mock's turns still stream.
//
// TWO COMMITTED PICTURE PAIRS, `shots-output/output-{open,empty}-{dark,light}.png`, published
// through `publishShot`: written only under `RICHOS_SHOTS_REGENERATE`, otherwise compared.
//
// Run: node output.js   (or `npm test` for every suite in this directory)

"use strict";

const path = require("path");
const {
  loadPlaywright,
  leaveHome,
  createRun,
  assert,
  assertEqual,
  shot,
  publishShotFile,
  awaitWorkerChipSettled,
  UI_DIR,
} = require("./lib/harness");
const { parseCssColor, compositeOver, contrastRatio, hex } = require("./lib/contrast");

const APP = "file://" + path.join(UI_DIR, "index.html");
const SHOTS = path.join(__dirname, "shots-output");
const FIXED = new Date("2026-10-05T09:45:00-04:00");

async function openApp(browser, opts) {
  opts = opts || {};
  const context = await browser.newContext({
    viewport: opts.viewport || { width: 1440, height: 900 },
    timezoneId: "America/New_York",
    locale: "en-US",
    reducedMotion: opts.reducedMotion || "no-preference",
  });
  const page = await context.newPage();
  await page.clock.setFixedTime(FIXED);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  const theme = opts.theme || "dark";
  // The app's own stored preference AND its mirror, as `contrast.js` seeds them: the store wins
  // at init, so a mirror-only seed would be overwritten a moment after boot.
  await page.addInitScript((t) => {
    try {
      window.localStorage.setItem("richos-theme", t);
      window.localStorage.setItem("richos-font-scale", "100");
      window.localStorage.setItem("richos-mock-config", JSON.stringify({ theme: t, font_scale: 100, user_name: null }));
    } catch (e) {
      /* storage unavailable: the shipped default */
    }
  }, theme);
  // A repeatable stream for the mock's ids and canned replies.
  await page.addInitScript(() => {
    let state = 0x6a09e667;
    Math.random = () => {
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      return (state >>> 0) / 4294967296;
    };
  });
  if (opts.preset !== null) {
    await page.addInitScript((v) => {
      window.__RICHOS_MOCK_PRESET__ = v;
    }, opts.preset || { output: "round-17" });
  }
  await page.goto(APP);
  await leaveHome(page);
  await page.waitForFunction(() => typeof window.RichOutput === "object" && typeof window.RichTimeline === "object");
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

/// Open a thread from the rail and wait for its record to have been read: the buttons carry the
/// count the mock's record holds (or none), and the conversation's links are drawn.
async function openThread(page, threadId, count) {
  await page.click('.nav-thread[data-thread-id="' + threadId + '"]');
  await page.waitForFunction(
    ({ id, n }) => {
      const s = window.RichOutput.snapshot();
      return s.thread === id && s.count === n;
    },
    { id: threadId, n: count }
  );
  if (count > 0) await page.waitForSelector(".tl-file-link");
}

async function panelState(page) {
  return page.evaluate(() => {
    const panel = document.getElementById("outpanel");
    const btn = (id) => {
      const b = document.getElementById(id);
      return {
        hidden: b.hidden,
        pressed: b.getAttribute("aria-pressed"),
        label: b.getAttribute("aria-label"),
        count: b.querySelector(".out-count").textContent,
        countShown: getComputedStyle(b.querySelector(".out-count")).display !== "none",
      };
    };
    return {
      open: !panel.hidden,
      view: document.getElementById("op-body").dataset.view || null,
      title: document.getElementById("op-title").textContent,
      sub: document.getElementById("op-sub").textContent,
      top: btn("out-top"),
      bottom: btn("out-bottom"),
      focus: document.activeElement ? (document.activeElement.id || document.activeElement.className) : null,
      groups: [...document.querySelectorAll("#op-body .og")].map((g) => ({
        words: g.querySelector(".og-words") ? g.querySelector(".og-words").textContent : "",
        time: g.querySelector("time") ? g.querySelector("time").textContent : "",
        files: [...g.querySelectorAll(".oname")].map((n) => n.textContent),
      })),
    };
  });
}

async function main() {
  const run = createRun("Output panel S4 — the buttons, the list, empty, the links (real shell, WebKit)");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const page = await openApp(browser);
  const record = await page.evaluate(() => window.__RICHOS_MOCK__.outputList("acme"));
  const byName = (name) => record.files.find((f) => f.name === name);

  await run.check("closed — both buttons carry the count of files this thread produced, and nothing opens", async () => {
    await openThread(page, "acme", 9);
    const s = await panelState(page);
    assert(!s.open, "the panel opened by itself (§6.6: nothing opens on its own)");
    for (const b of [s.top, s.bottom]) {
      assert(!b.hidden, "an Output button is hidden on an open thread");
      assertEqual(b.count, "9");
      assert(b.countShown, "the count is not shown");
      assertEqual(b.pressed, "false");
      assertEqual(b.label, "Output — 9 files from this thread");
    }
    const place = await page.evaluate(() => {
      const top = document.getElementById("out-top");
      const bottom = document.getElementById("out-bottom");
      return {
        topInHeader: !!top.closest("#stage-header"),
        bottomInComposer: !!bottom.closest("#composer-row"),
        topRight: Math.round(top.getBoundingClientRect().right),
        headerRight: Math.round(document.getElementById("stage-header").getBoundingClientRect().right),
        bottomH: Math.round(bottom.getBoundingClientRect().height),
        talkH: Math.round(document.getElementById("talk-toggle").getBoundingClientRect().height),
      };
    });
    assert(place.topInHeader && place.bottomInComposer, "the buttons are not where the CEO pointed: " + JSON.stringify(place));
    assertEqual(place.bottomH, place.talkH, "the bottom button is not as tall as the composer's own controls");
    return "9 on both; top at the header's right (" + place.topRight + " of " + place.headerRight + "px), bottom beside the composer at " + place.bottomH + "px";
  });

  await run.check("open — one click opens a docked panel listing every file, grouped by turn, newest first", async () => {
    await page.click("#out-top");
    await page.waitForSelector("#outpanel .orow");
    // The panel slides open (`op-open`, .38s): measured once the slide has landed, never mid-way.
    await page.evaluate(() => Promise.all(document.getElementById("outpanel").getAnimations().map((a) => a.finished)));
    const s = await panelState(page);
    assert(s.open, "the panel did not open");
    assertEqual(s.title, "9 files from this thread");
    assertEqual(s.sub, "Everything written here, newest first.");
    assertEqual(s.top.pressed, "true");
    assertEqual(s.bottom.pressed, "true", "the SAME control in two places: both say it is pressed");
    assertEqual(
      s.groups.map((g) => g.words),
      [
        "and a 30-second walkthrough of the comps for Priya",
        "pull the signed term sheet and the Q3 numbers before I send it",
        "draft it, keep it firm",
        "what's the status on Acme?",
      ],
      "the groups are his words, newest first"
    );
    assertEqual(s.groups.map((g) => g.time), ["Today 9:40 AM", "Today 9:31 AM", "Today 9:15 AM", "Yesterday 1:45 PM"]);
    assertEqual(
      s.groups.map((g) => g.files),
      [
        ["comps-walkthrough.mp4"],
        ["term-sheet-march.pdf", "q3-revenue.csv", "q3-revenue-chart.png"],
        ["counter-draft-v1.docx", "counter-draft-v1.md", "brief.md"],
        ["comps-2026-10-04.xlsx", "comps-summary.md"],
      ]
    );
    const layout = await page.evaluate(() => {
      const p = document.getElementById("outpanel").getBoundingClientRect();
      const c = document.getElementById("conversation").getBoundingClientRect();
      const row = [...document.querySelectorAll(".orow")].find((r) => r.textContent.includes("q3-revenue.csv"));
      return {
        width: Math.round(p.width),
        beside: p.left >= c.right - 1,
        modal: document.getElementById("outpanel").getAttribute("aria-modal"),
        scrim: document.getElementById("outpanel-scrim").hidden,
        by: row.querySelector(".oby") ? row.querySelector(".oby").textContent : null,
        folder: row.querySelector(".opath").textContent,
        tiles: [...document.querySelectorAll(".okind")].map((t) => t.textContent),
      };
    });
    assertEqual(layout.width, 400, "the panel's default width");
    assert(layout.beside, "the panel covers the conversation instead of sitting beside it");
    assertEqual(layout.modal, null, "a docked pane, not a modal");
    assert(layout.scrim, "nothing dims at 1440px");
    assertEqual(layout.by, "by Clark", "a worker's file says who wrote it (§11 row 7)");
    assertEqual(layout.folder, "~/FemcBoost/acme/reference/");
    assertEqual(layout.tiles, ["mp4", "pdf", "csv", "png", "doc", "md", "md", "xls", "md"]);
    return "400px beside the conversation; 4 groups, 9 rows; 'by Clark' on the worker's file";
  });

  await run.check("focus moves into the list on open and back to the button on close", async () => {
    const opened = await page.evaluate(() => ({
      cls: document.activeElement.className,
      name: document.activeElement.querySelector(".oname") ? document.activeElement.querySelector(".oname").textContent : null,
    }));
    assertEqual(opened.cls, "orow", "focus did not move to the first row");
    assertEqual(opened.name, "comps-walkthrough.mp4");
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => document.getElementById("outpanel").hidden);
    const s = await panelState(page);
    assertEqual(s.focus, "out-top", "closing did not return focus to the button that opened it");
    assertEqual(s.top.pressed, "false");
    return "first row focused on open; Escape from the list closed it and focus is back on #out-top";
  });

  await run.check("a row opens the file in the panel; back keeps the row selected; ‹ › walk the files", async () => {
    await page.click("#out-bottom");
    await page.waitForSelector("#outpanel .orow");
    await page.click('.orow[data-output="' + byName("q3-revenue.csv").id + '"]');
    await page.waitForSelector("#of-back");
    let s = await panelState(page);
    assertEqual(s.view, "file");
    assertEqual(s.title, "q3-revenue.csv");
    // A LANDED file (`source: "land"`, S2b): rendered like any other, by its worker, and its
    // earlier write is said — the panel reads `source` nowhere, so there is no unknown-source path.
    assertEqual(byName("q3-revenue.csv").source, "land", "the fixture's landed file is not a land entry");
    assertEqual(s.sub, "Written today 9:33 AM · 1 KB · also written earlier in this thread");
    const file = await page.evaluate(() => ({
      back: document.getElementById("of-back").textContent,
      k: document.querySelector(".of-k").textContent,
      path: document.querySelector(".of-path code").textContent,
      facts: document.querySelector(".of-meta") ? document.querySelector(".of-meta").textContent : null,
      focus: document.activeElement.id,
    }));
    assertEqual(file.back, "All output · 9");
    assertEqual(file.k, "3 of 9");
    assertEqual(file.path, "~/FemcBoost/acme/reference/q3-revenue.csv");
    assertEqual(file.facts, "Comma-separated·1 KB", "the S4 file view states the file's kind and size");
    assertEqual(file.focus, "of-back");
    await page.click('[aria-label="Next file"]');
    assertEqual((await panelState(page)).title, "q3-revenue-chart.png", "‹ › walk the thread's files in list order");
    await page.click("#of-back");
    s = await panelState(page);
    assertEqual(s.view, "list");
    const sel = await page.evaluate(() => {
      const open = document.querySelector(".orow.is-open");
      return {
        open: open ? open.querySelector(".oname").textContent : null,
        focus: document.activeElement.classList.contains("orow") ? document.activeElement.querySelector(".oname").textContent : null,
      };
    });
    assertEqual(sel.open, "q3-revenue-chart.png", "back did not keep the row selected");
    assertEqual(sel.focus, "q3-revenue-chart.png", "back did not put focus on that row");
    return "row → file (3 of 9) → next (4 of 9) → back: the row is selected and focused";
  });

  await run.check("Escape steps back one level at a time: the file, then the list, then closed", async () => {
    await page.keyboard.press("Enter"); // the focused row opens its file
    await page.waitForSelector("#of-back");
    await page.keyboard.press("Escape");
    let s = await panelState(page);
    assert(s.open && s.view === "list", "Escape from a file must go back to the list, not close the panel: " + JSON.stringify(s));
    await page.keyboard.press("Escape");
    s = await panelState(page);
    assert(!s.open, "Escape from the list must close the panel");
    // And from OUTSIDE the panel, the way every popup answers it (main.js `dismissTopmostPopup`).
    await page.click("#out-top");
    await page.waitForSelector("#outpanel .orow");
    await page.focus("#input");
    await page.keyboard.press("Escape");
    s = await panelState(page);
    assert(!s.open, "Escape from the composer did not close the panel");
    return "file → list → closed; and closed from the composer too";
  });

  await run.check("from-link — a file named in Rich's message opens the panel on that file, and the link pulses", async () => {
    const id = byName("q3-revenue-chart.png").id;
    const link = '.tl-prose .tl-file-link[data-output-id="' + id + '"]';
    const before = await page.evaluate((sel) => {
      const l = document.querySelector(sel);
      return l ? { text: l.textContent, inProse: !!l.closest(".tl-prose") } : null;
    }, link);
    assert(before, "the code span `q3-revenue-chart.png` in Rich's reply is not a link");
    await page.click(link);
    await page.waitForSelector("#of-back");
    const s = await panelState(page);
    assertEqual(s.title, "q3-revenue-chart.png");
    const pulsed = await page.evaluate((sel) => document.querySelector(sel).classList.contains("flash"), link);
    assert(pulsed, "the link did not pulse");
    // ONLY RECORDED FILES BECOME LINKS. A code span naming a file nothing witnessed stays code.
    const plain = await page.evaluate(() => {
      const box = document.createElement("div");
      window.RichTimeline.renderMarkdownInto(box, "see `not-recorded.md` and `brief.md`", window.RichOutput.links);
      return { code: [...box.querySelectorAll("code")].map((c) => c.textContent), links: [...box.querySelectorAll(".tl-file-link")].map((c) => c.textContent) };
    });
    assertEqual(plain.code, ["not-recorded.md"]);
    assertEqual(plain.links, ["brief.md"]);
    // The list is one click away, and closing returns focus to the conversation.
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");
    const closed = await panelState(page);
    assert(!closed.open, "two Escapes from a file opened by a link did not close the panel");
    assertEqual(closed.focus, "conversation", "a panel opened from a link returns focus to the conversation");
    return "`" + before.text + "` → the panel on that file; an unrecorded name stays a code span";
  });

  await run.check("from-digest — 'Wrote 3 files' opens the panel at the list and that turn's group pulses", async () => {
    const turn = byName("brief.md").turnId;
    const sel = '[id="wrote:' + turn + '"]';
    const label = await page.evaluate((s) => (document.querySelector(s) ? document.querySelector(s).textContent : null), sel);
    assertEqual(label, "Wrote 3 files");
    const strip = await page.evaluate((t) => {
      const sec = document.querySelector('.tl-turn[data-turn-id="' + t + '"] .tl-produced');
      return sec ? sec.textContent : null;
    }, turn);
    assertEqual(strip, "Produced 3 filescounter-draft-v1.docxcounter-draft-v1.mdbrief.md", "the produced strip under the turn");
    await page.click(sel);
    await page.waitForSelector("#outpanel .orow");
    const g = await page.evaluate((t) => {
      const sec = document.querySelector('.og[data-turn="' + t + '"]');
      return {
        flash: sec.classList.contains("flash"),
        focus: document.activeElement.closest(".og") === sec,
        view: document.getElementById("op-body").dataset.view,
      };
    }, turn);
    assertEqual(g.view, "list");
    assert(g.flash, "the turn's group did not pulse");
    assert(g.focus, "focus is not in that turn's group");
    await page.keyboard.press("Escape");
    return "'Wrote 3 files' → the list, \"draft it, keep it firm\" pulsed and focused";
  });

  await run.check("⌘⇧O toggles the panel, as either button does", async () => {
    await page.focus("#input");
    await page.keyboard.press("Meta+Shift+O");
    await page.waitForSelector("#outpanel .orow");
    assert((await panelState(page)).open, "⌘⇧O did not open the panel");
    await page.keyboard.press("Meta+Shift+O");
    const s = await panelState(page);
    assert(!s.open, "⌘⇧O did not close it");
    assertEqual(s.focus, "input", "⌘⇧O from the composer returns focus to the composer");
    return "open and closed by the shortcut; focus back in the composer";
  });

  await run.check("arrives — files a turn writes slide into an open list at the top, the scroll position holds, both counts tick", async () => {
    const small = await openApp(browser, { viewport: { width: 1400, height: 640 } });
    await openThread(small, "acme", 9);
    await small.click("#out-top");
    await small.waitForSelector("#outpanel .orow");
    const scrolled = await small.evaluate(() => {
      const body = document.getElementById("op-body");
      body.scrollTop = 120;
      return { top: body.scrollTop, max: body.scrollHeight - body.clientHeight };
    });
    assert(scrolled.top === 120, "the list is not tall enough to scroll at 640px, so this would prove nothing: " + JSON.stringify(scrolled));
    await small.evaluate(() => {
      // Every sentence the one polite region carries, in order: the shared region is written by
      // more than this panel, so what is asserted is that the count was among them, once.
      window.__said = [];
      const live = document.getElementById("live-region");
      new MutationObserver(() => {
        if (live.textContent) window.__said.push(live.textContent);
      }).observe(live, { childList: true, characterData: true, subtree: true });
      window.__ticks = 0;
      for (const c of document.querySelectorAll(".out-count")) {
        new MutationObserver(() => {
          if (c.classList.contains("tick")) window.__ticks += 1;
        }).observe(c, { attributes: true, attributeFilter: ["class"] });
      }
      window.__RICHOS_MOCK__.outputArrive("acme");
    });
    await small.waitForFunction(() => window.RichOutput.snapshot().count === 11, null, { timeout: 30000 });
    await small.waitForFunction(() => document.querySelectorAll("#op-body .og").length === 5);
    await small.waitForFunction(() => window.__said.indexOf("11 files from this thread") >= 0);
    const after = await small.evaluate(() => {
      const body = document.getElementById("op-body");
      const first = body.querySelector(".og");
      return {
        top: body.scrollTop,
        firstWords: first.querySelector(".og-words").textContent,
        firstFiles: [...first.querySelectorAll(".oname")].map((n) => n.textContent),
        arrived: first.classList.contains("arrive-group"),
        title: document.getElementById("op-title").textContent,
        counts: [...document.querySelectorAll(".out-count")].map((c) => c.textContent),
        ticks: window.__ticks,
        open: !document.getElementById("outpanel").hidden,
        said: window.__said.filter((t) => /files? from this thread$/.test(t)),
      };
    });
    assertEqual(after.top, 120, "the arrival moved what he was reading");
    assertEqual(after.firstWords, "make me a one-pager for the board");
    assertEqual(after.firstFiles, ["board-one-pager.pdf", "board-one-pager.md"]);
    assert(after.arrived, "the new group did not arrive with the rise");
    assertEqual(after.title, "11 files from this thread");
    assertEqual(after.counts, ["11", "11"]);
    assertEqual(after.ticks, 2, "the count ticks once on each button");
    assert(after.open, "the panel closed");
    assertEqual(after.said, ["11 files from this thread"], "one announcement of the new count, not one per button");
    assertEqual(small.__errors, [], "the page reported errors");
    await small.context().close();
    return "scrollTop 120 before and after; the one-pager group on top; 9 → 11 on both buttons, one tick each";
  });

  await run.check("arrives, panel closed — the count ticks and nothing opens on its own", async () => {
    const p = await openApp(browser);
    await openThread(p, "acme", 9);
    await p.evaluate(() => window.__RICHOS_MOCK__.outputArrive("acme"));
    await p.waitForFunction(() => window.RichOutput.snapshot().count === 11, null, { timeout: 30000 });
    const s = await panelState(p);
    assert(!s.open, "a turn's files opened the panel (§6.6, Iris's decision 8)");
    assertEqual([s.top.count, s.bottom.count], ["11", "11"]);
    // The conversation redraws on the record's revision, one frame after the count.
    await p.waitForFunction(() => document.querySelectorAll(".tl-produced").length === 5);
    const links = await p.evaluate(() => [...document.querySelectorAll(".tl-produced")].pop().textContent);
    assertEqual(links, "Produced 2 filesboard-one-pager.pdfboard-one-pager.md", "the new turn's produced strip");
    await p.context().close();
    return "closed panel stays closed; 11 on both; the new turn names its two files";
  });

  await run.check("empty — a thread that produced nothing: the button without a count, and the one sentence", async () => {
    await openThread(page, "hiring", 0);
    let s = await panelState(page);
    for (const b of [s.top, s.bottom]) {
      assert(!b.countShown, "an empty thread's button shows a count");
      assertEqual(b.label, "Output — nothing produced yet in this thread");
    }
    await page.click("#out-top");
    await page.waitForSelector(".op-empty");
    s = await panelState(page);
    assertEqual(s.title, "Nothing produced yet");
    assertEqual(s.sub, "Q4 hiring");
    const line = await page.evaluate(() => ({
      text: document.querySelector(".op-empty-line").textContent,
      bold: document.querySelector(".op-empty-line b").textContent,
      focus: document.activeElement.className,
    }));
    assertEqual(
      line.text,
      "Nothing in Q4 hiring has produced a file yet. The moment Rich or the team writes one, it is listed here — and the count on the Output button says so."
    );
    assertEqual(line.bold, "Q4 hiring");
    assertEqual(line.focus, "op-empty", "focus moves to the sentence's container");
    return "no count; \"" + line.text.slice(0, 48) + "…\"";
  });

  await run.check("an open panel follows a thread switch to the new thread's list", async () => {
    await page.click('.nav-thread[data-thread-id="acme"]');
    await page.waitForFunction(() => document.querySelectorAll("#op-body .orow").length === 9);
    const s = await panelState(page);
    assert(s.open, "the panel closed on a thread switch");
    assertEqual(s.title, "9 files from this thread");
    return "Q4 hiring's empty panel → Acme deal's nine files, still open";
  });

  await run.check("the worker inspector and the panel are one right-hand pane at a time", async () => {
    await page.click('.nav-thread[data-thread-id="hiring"]');
    await page.waitForFunction(() => window.RichOutput.snapshot().thread === "hiring");
    await page.waitForSelector(".tl-duration-btn:not(.tl-duration-btn--static)");
    const disclosure = page.locator(".tl-duration-btn:not(.tl-duration-btn--static)").first();
    if ((await disclosure.getAttribute("aria-expanded")) !== "true") await disclosure.click();
    await page.waitForSelector(".tl-chip");
    await page.click(".tl-chip");
    await page.waitForSelector("#inspector:not([hidden])");
    assert(!(await panelState(page)).open, "opening the inspector left the Output panel open");
    await page.click("#out-top");
    await page.waitForSelector(".op-empty");
    const both = await page.evaluate(() => ({
      inspector: !document.getElementById("inspector").hidden,
      output: !document.getElementById("outpanel").hidden,
    }));
    assertEqual(both, { inspector: false, output: true }, "opening the panel did not close the inspector");
    await page.click(".tl-chip");
    await page.waitForSelector("#inspector:not([hidden])");
    assert(!(await panelState(page)).open, "opening the inspector did not close the panel");
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => document.getElementById("inspector").hidden);
    return "panel → inspector → panel → inspector: never both";
  });

  await run.check("a missing file stays listed, dimmed, said so — and nothing on its row is an action", async () => {
    await page.evaluate(() => window.__RICHOS_MOCK__.outputMissing("acme", "brief.md"));
    await openThread(page, "acme", 9);
    await page.click("#out-top");
    await page.waitForSelector("#outpanel .orow.is-missing");
    const row = await page.evaluate(() => {
      const r = document.querySelector(".orow.is-missing");
      return {
        name: r.querySelector(".oname").textContent,
        line: r.querySelector(".opath").textContent,
        controls: [...r.querySelectorAll("button, a[href], [data-act]")].filter((c) => !c.disabled).length,
        nameColor: getComputedStyle(r.querySelector(".oname")).color,
        okColor: getComputedStyle(document.querySelector(".orow:not(.is-missing) .oname")).color,
        title: document.getElementById("op-title").textContent,
      };
    });
    assertEqual(row.name, "brief.md");
    assertEqual(row.line, "No longer where it was written");
    assertEqual(row.controls, 0, "an action is enabled on a missing file's row");
    assert(row.nameColor !== row.okColor, "the missing row is not dimmed");
    assertEqual(row.title, "9 files from this thread · 1 no longer where it was written", "the count includes it and the header says so (§4.6)");
    await page.click(".orow.is-missing");
    await page.waitForSelector(".of-missing");
    const sentence = await page.evaluate(() => document.querySelector(".of-missing").textContent);
    assertEqual(
      sentence,
      "This file is no longer where it was written. If it was moved, open it from its new place; if Rich writes it again, it will be listed here."
    );
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");
    return "dimmed, 'No longer where it was written', no enabled action; its view says the §6.7 sentence";
  });

  await run.check("a record that cannot be read: no count, the shell's sentence and Try again", async () => {
    const p = await openApp(browser);
    await p.evaluate(() => window.__RICHOS_MOCK__.outputUnreadable(true));
    await p.click('.nav-thread[data-thread-id="acme"]');
    await p.waitForFunction(() => window.RichOutput.snapshot().error !== null);
    const s = await panelState(p);
    assert(!s.top.countShown && !s.bottom.countShown, "an unreadable record still shows a count");
    assertEqual(s.top.label, "Output", "no number nobody has read");
    await p.click("#out-top");
    await p.waitForSelector(".op-again");
    const text = await p.evaluate(() => document.querySelector(".op-state-line").textContent);
    assertEqual(text, "I can't read this thread's output record right now.");
    await p.evaluate(() => window.__RICHOS_MOCK__.outputUnreadable(false));
    await p.click(".op-again");
    await p.waitForFunction(() => document.querySelectorAll("#op-body .orow").length === 9);
    assertEqual((await panelState(p)).top.count, "9", "Try again did not bring the count back");
    await p.context().close();
    return "\"" + text + "\" with Try again; recovered to 9";
  });

  await run.check("no thread, no button: the company overview hides both and closes the panel", async () => {
    await page.click("#out-top");
    await page.waitForSelector("#outpanel .orow");
    await page.click(".nav-group-label.is-selectable");
    await page.waitForFunction(() => document.getElementById("out-top").hidden);
    const s = await panelState(page);
    assert(s.top.hidden && s.bottom.hidden, "an Output button is shown with no thread open");
    assert(!s.open, "the panel stayed open over a screen with no thread");
    return "both buttons hidden on the company overview; the panel closed with the conversation";
  });

  await run.check("below 1180px the panel overlays with a scrim, and the scrim closes it", async () => {
    const p = await openApp(browser, { viewport: { width: 1000, height: 800 } });
    await openThread(p, "acme", 9);
    await p.click("#out-top");
    await p.waitForSelector("#outpanel .orow");
    const r = await p.evaluate(() => ({
      position: getComputedStyle(document.getElementById("outpanel")).position,
      scrim: !document.getElementById("outpanel-scrim").hidden,
    }));
    assertEqual(r, { position: "fixed", scrim: true });
    await p.mouse.click(40, 400);
    await p.waitForFunction(() => document.getElementById("outpanel").hidden);
    await p.context().close();
    return "fixed over the conversation with a scrim at 1000px; a click on the scrim closed it";
  });

  // ---- both themes: the computed pairs, and the committed pictures --------------------------

  const ratios = [];
  for (const theme of ["dark", "light"]) {
    await run.check(theme + " — every new text pair and indicator clears WCAG AA, computed", async () => {
      const p = await openApp(browser, { theme });
      await openThread(p, "acme", 9);
      // At rest first: the boundary that says "this is a button" before anything is pressed.
      const rest = await p.evaluate(() => ({
        what: "button border at rest, on the composer's ground",
        kind: "indicator",
        fg: getComputedStyle(document.getElementById("out-bottom")).borderTopColor,
      }));
      await p.click("#out-top");
      await p.waitForSelector("#outpanel .orow");
      await p.hover('.orow[data-output="' + byName("q3-revenue.csv").id + '"]');
      const raw = await p.evaluate(() => {
        // The first opaque-ish background up the tree; where the stage is transparent over the
        // speckled ground, the paper token itself, resolved by the browser through a probe.
        const probe = document.createElement("div");
        probe.style.background = "var(--paper)";
        document.body.appendChild(probe);
        const paper = getComputedStyle(probe).backgroundColor;
        probe.remove();
        function ground(node) {
          for (let n = node; n; n = n.parentElement) {
            const bg = getComputedStyle(n).backgroundColor;
            if (bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") return bg;
          }
          return paper;
        }
        const pick = (sel) => document.querySelector(sel);
        const text = (what, sel) => {
          const n = pick(sel);
          return { what, kind: "text", fg: getComputedStyle(n).color, bg: ground(n), size: parseFloat(getComputedStyle(n).fontSize) };
        };
        const edge = (what, sel, prop, against) => {
          const n = pick(sel);
          return { what, kind: "indicator", fg: getComputedStyle(n)[prop], bg: against ? ground(pick(against)) : ground(n.parentElement) };
        };
        return [
          text("button word", "#out-top .out-word"),
          text("count numeral", "#out-top .out-count"),
          text("panel title", "#op-title"),
          text("panel subline", "#op-sub"),
          text("OUTPUT eyebrow (14px)", "#op-eyebrow"),
          text("group words", ".og-words"),
          text("group time", ".og-head time"),
          text("file name", ".oname"),
          text("folder", ".opath"),
          text("worker line, hovered row", ".orow:hover .oby"),
          text("folder, hovered row", ".orow:hover .opath"),
          text("kind tile (14px)", ".okind"),
          text("file link in the prose", ".tl-prose .tl-file-link span"),
          text("Wrote N files", ".tl-wrote"),
          text("Produced label", ".tl-produced-label"),
          { what: "", kind: "rest-ground", bg: ground(pick("#composer-zone")) },
          edge("pressed button border", "#out-top", "borderTopColor", "#stage-header"),
          edge("count border on the count's own fill", "#out-top .out-count", "borderTopColor", "#out-top"),
        ];
      });
      // The at-rest border, against the ground it sits on (read in the same page).
      const restGround = raw.find((r) => r.kind === "rest-ground");
      raw.splice(raw.indexOf(restGround), 1, Object.assign(rest, { bg: restGround.bg }));
      const lines = [];
      for (const r of raw) {
        const bg = parseCssColor(r.bg);
        const fgRaw = parseCssColor(r.fg);
        assert(bg && fgRaw, "could not resolve the colors of " + r.what + ": " + r.fg + " on " + r.bg);
        const base = bg.a < 1 ? compositeOver(bg, parseCssColor(theme === "dark" ? "rgb(12, 19, 34)" : "rgb(234, 230, 221)")) : bg;
        const fg = fgRaw.a < 1 ? compositeOver(fgRaw, base) : fgRaw;
        const ratio = Math.round(contrastRatio(fg, base) * 100) / 100;
        const floor = r.kind === "indicator" ? 3 : 4.5;
        lines.push(r.what + " " + hex(fg) + " on " + hex(base) + " " + ratio + ":1");
        ratios.push({ theme, what: r.what, ratio });
        if (r.what.startsWith("count border")) continue; // decorative: the fill is the indicator
        assert(ratio >= floor, theme + ": " + r.what + " is " + ratio + ":1 against a floor of " + floor + ":1 (" + hex(fg) + " on " + hex(base) + ")");
      }
      assertEqual(p.__errors, [], "the page reported errors");
      await p.context().close();
      return lines.join(" | ");
    });

    await run.check(theme + " — the committed pictures: open and empty", async () => {
      const p = await openApp(browser, { theme });
      await openThread(p, "acme", 9);
      await p.click("#out-top");
      await p.waitForSelector("#outpanel .orow");
      await awaitWorkerChipSettled(p);
      const open = await shot(p, "output-open-" + theme, { fullPage: false, parkPointer: true });
      publishShotFile(open.file, path.join(SHOTS, "output-open-" + theme + ".png"));
      await openThread(p, "hiring", 0);
      await p.waitForSelector(".op-empty");
      await awaitWorkerChipSettled(p);
      const empty = await shot(p, "output-empty-" + theme, { fullPage: false, parkPointer: true });
      publishShotFile(empty.file, path.join(SHOTS, "output-empty-" + theme + ".png"));
      assertEqual(p.__errors, [], "the page reported errors");
      await p.context().close();
      return "shots-output/output-open-" + theme + ".png, shots-output/output-empty-" + theme + ".png";
    });
  }

  await run.check("⌘+ scales the panel with everything else (rem, §6.9)", async () => {
    const p = await openApp(browser);
    await openThread(p, "acme", 9);
    await p.click("#out-top");
    await p.waitForSelector("#outpanel .orow");
    const size = () =>
      p.evaluate(() => ({
        name: parseFloat(getComputedStyle(document.querySelector(".oname")).fontSize),
        title: parseFloat(getComputedStyle(document.getElementById("op-title")).fontSize),
        button: parseFloat(getComputedStyle(document.getElementById("out-top")).fontSize),
      }));
    const before = await size();
    await p.focus("#input");
    await p.keyboard.press("Meta+=");
    await p.waitForFunction((b) => parseFloat(getComputedStyle(document.querySelector(".oname")).fontSize) > b, before.name);
    const after = await size();
    assert(after.title > before.title && after.button > before.button, "the panel did not scale: " + JSON.stringify({ before, after }));
    await p.context().close();
    return "file name " + before.name + " → " + after.name + "px, title " + before.title + " → " + after.title + "px, button " + before.button + " → " + after.button + "px";
  });

  await run.check("reduced motion: no tick, no rise, no pulse — the change still happens", async () => {
    const p = await openApp(browser, { reducedMotion: "reduce" });
    await openThread(p, "acme", 9);
    await p.click("#out-top");
    await p.waitForSelector("#outpanel .orow");
    const anim = await p.evaluate(() => ({
      panel: getComputedStyle(document.getElementById("outpanel")).animationName,
      view: getComputedStyle(document.querySelector(".op-view")).animationName,
    }));
    assertEqual(anim, { panel: "none", view: "none" });
    await p.context().close();
    return "the panel and its view open without animation under prefers-reduced-motion";
  });

  await run.check("no page errors in the main walk", async () => {
    assertEqual(page.__errors, [], "the page reported errors");
    return "0 errors";
  });

  await page.context().close();
  await browser.close();
  process.exit(run.report() > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

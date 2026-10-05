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
          text("OUTPUT eyebrow (11px micro-label)", "#op-eyebrow"),
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

  // ---- S9: the wide pull — the stop, the snap, open completely, the floating composer ---------
  //
  // The CEO: "when I'm dragging up to here, then there's a stop, I'm feeling a stop. But if I keep
  // dragging … then eventually it snaps open completely the output sidebar." PRD §12.9 names the
  // pointer path (100px before the stop, the stop, 44px past, 144px past, 230px back), the keys
  // and the six round-17.1 states this block reproduces: `stop`, `snap`, `full`, `full-list`,
  // `everything` and `wide`. A REAL POINTER throughout: `page.mouse` down on the divider, moved,
  // up — the events WebKit delivers to a hand, not a call into the panel's code.
  await pullChecks(run, browser, byName);

  await run.check("no page errors in the main walk", async () => {
    assertEqual(page.__errors, [], "the page reported errors");
    return "0 errors";
  });

  await page.context().close();
  await browser.close();
  process.exit(run.report() > 0 ? 1 : 0);
}

// =============================================================================================
// S9 — THE WIDE PULL (PRD §9, §12.9; round 17.1)
// =============================================================================================

const STAGE_MIN = 360; // §9.1, re-stated here so the suite derives the stop independently
const SNAP_PAST = 120; // §9.3

function near(actual, expected, tolerance, what) {
  assert(
    Math.abs(actual - expected) <= tolerance,
    (what || "value") + ": " + actual + " is not within " + tolerance + " of " + expected
  );
}

/// The width of the inset spine in a computed `box-shadow` ("rgb(…) 2.1px 0px 0px 0px inset").
function spineWidth(shadow) {
  const m = /(-?[\d.]+)px\s+(-?[\d.]+)px\s+(-?[\d.]+)px\s+(-?[\d.]+)px\s+inset/.exec(shadow || "");
  return m ? Number(m[1]) : 0;
}

/// Everything the pull paints, read in one frame, beside what the panel believes.
async function pullRead(page) {
  return page.evaluate(() => {
    const $ = (id) => document.getElementById(id);
    const rz = $("op-resizer");
    const stage = $("stage");
    const p = window.RichOutput.pull();
    const app = $("app").getBoundingClientRect();
    const away = document.body.classList.contains("rail-closed");
    const pill = $("op-conv");
    return {
      full: p.full,
      split: p.split,
      max: p.max,
      settling: p.settling,
      appRight: app.right,
      appWidth: app.width,
      railWidth: away ? 0 : $("rail").getBoundingClientRect().width,
      panel: $("outpanel").getBoundingClientRect().width,
      open: !$("outpanel").hidden,
      dividerLeft: rz.getBoundingClientRect().left,
      stage: stage.getBoundingClientRect().width,
      stageOpacity: Number(getComputedStyle(stage).opacity),
      stageVisibility: getComputedStyle(stage).visibility,
      spine: getComputedStyle($("outpanel")).boxShadow,
      narrow: stage.classList.contains("narrow"),
      valuenow: rz.getAttribute("aria-valuenow"),
      valuemax: rz.getAttribute("aria-valuemax"),
      valuetext: rz.getAttribute("aria-valuetext"),
      pill: pill.hidden ? null : pill.getAttribute("aria-label"),
      pillText: pill.hidden ? null : pill.textContent,
      composerIn: $("composer-zone").parentElement.id,
      arming: document.body.classList.contains("snap-arming"),
      focus: document.activeElement ? document.activeElement.id : null,
    };
  });
}

/// The snap's 420 ms and every width/opacity transition on the panel and the conversation have
/// landed — a state the page asserts, never a sleep (PRD §10, T3's harness discipline).
async function pullSettled(page) {
  await page.waitForFunction(() => !window.RichOutput.pull().settling);
  await page.evaluate(() =>
    Promise.all(
      ["outpanel", "stage"].flatMap((id) => document.getElementById(id).getAnimations()).map((a) => a.finished)
    )
  );
}

async function openPanelPage(browser, opts) {
  const page = await openApp(browser, opts);
  await openThread(page, "acme", 9);
  await page.click("#out-top");
  await page.waitForSelector("#outpanel .orow");
  await page.evaluate(() => Promise.all(document.getElementById("outpanel").getAnimations().map((a) => a.finished)));
  return page;
}

/// What the (mocked) nav.rs holds for the split width, once it holds `want` — read through the
/// bridge, as `inspector.js` reads its divider's, polled because the write is debounced 150 ms.
async function persistedWidth(page, want) {
  let got = null;
  for (let i = 0; i < 50; i++) {
    got = await page.evaluate(() => window.RichBridge.invoke("nav_state").then((n) => n.output_width));
    if (Math.round(got) === want) return got;
    await page.waitForTimeout(100);
  }
  throw new Error("nav.rs's output_width is " + got + ", never " + want);
}

/// The divider, focused, and one key on it.
async function pullKey(page, key) {
  await page.focus("#op-resizer");
  await page.keyboard.press(key);
  await pullSettled(page);
  return pullRead(page);
}

async function pullChecks(run, browser, byName) {
  await run.check("stop and snap — free to the stop and held there; 44px past it arms; 144px past it opens completely; 230px back returns", async () => {
    const p = await openPanelPage(browser);
    let g = await pullRead(p);
    // The stop, derived from the DOM rather than read from the code under test.
    const stopWidth = Math.floor(g.appWidth - g.railWidth - STAGE_MIN);
    assertEqual(stopWidth, 780, "the stop at 1440px with the 300px rail: 1440 − 300 − 360");
    assertEqual(g.max, stopWidth, "the panel's stop");
    assertEqual(g.valuemax, String(stopWidth), "aria-valuemax is the stop");
    const stopX = g.appRight - stopWidth;
    const y = 460;
    await p.mouse.move(g.dividerLeft + 3, y);
    await p.mouse.down();
    // 100px before the stop: free, and the divider under the pointer.
    await p.mouse.move(stopX + 100, y, { steps: 12 });
    g = await pullRead(p);
    near(g.panel, stopWidth - 100, 1, "100px before the stop");
    near(g.dividerLeft, stopX + 100, 1, "the divider under the pointer");
    assert(!g.arming, "the pull armed before the stop");
    // At the stop: the conversation at its narrowest, and the divider says so.
    await p.mouse.move(stopX, y, { steps: 6 });
    g = await pullRead(p);
    near(g.panel, stopWidth, 1, "at the stop");
    near(g.stage, STAGE_MIN, 1, "the conversation at its narrowest");
    assertEqual(g.valuetext, stopWidth + " pixels, at the stop; pull on to open it completely");
    // 44px past: the divider HOLDS — the stop he feels — and the pull arms.
    await p.mouse.move(stopX - 44, y, { steps: 4 });
    g = await pullRead(p);
    near(g.panel, stopWidth, 1, "past the stop the panel holds");
    near(g.dividerLeft, stopX, 1, "past the stop the divider stays at the stop");
    assert(g.arming, "44px past the stop did not arm");
    const armed = 44 / SNAP_PAST;
    near(g.stageOpacity, 1 - armed * 0.62, 0.01, "the conversation dims with the pull");
    near(spineWidth(g.spine), 1 + armed * 3, 0.06, "the gold spine thickens with the pull");
    const arming = { opacity: g.stageOpacity, spine: spineWidth(g.spine) };
    // 144px past: SNAP_PAST is crossed and the panel opens completely.
    await p.mouse.move(stopX - 144, y, { steps: 10 });
    await pullSettled(p);
    g = await pullRead(p);
    assert(g.full, "144px past the stop did not open it completely");
    near(g.panel, g.appWidth - g.railWidth, 1, "open completely is the whole stage");
    near(g.stage, 0, 0.5, "the conversation at zero width");
    assertEqual(g.stageVisibility, "hidden", "the conversation is hidden, not removed");
    assertEqual(g.pill, "Show the conversation — Acme deal");
    assertEqual(g.pillText, "Acme deal");
    assertEqual(g.composerIn, "op-float", "the composer is not in the panel");
    assertEqual(g.valuetext, "Open completely");
    assert(!g.arming, "still arming after the snap");
    const full = g.panel;
    // 230px back, read in two halves. SNAP_PAST back from where it snapped, the conversation
    // returns at its narrowest and the divider is at the stop, under the pointer...
    await p.mouse.move(stopX, y, { steps: 12 });
    await pullSettled(p);
    g = await pullRead(p);
    assert(!g.full, "pulled back 120px from the snap, the conversation did not return");
    near(g.panel, stopWidth, 1, "the return is at the stop");
    near(g.dividerLeft, stopX, 4, "the divider is under the pointer at the stop");
    assertEqual(g.composerIn, "stage", "the composer did not go home");
    near(g.stageOpacity, 1, 0.001, "the conversation is not fully back");
    // ...and on to 230px: the divider follows the pointer and nothing arms.
    await p.mouse.move(stopX + 86, y, { steps: 9 });
    g = await pullRead(p);
    near(g.dividerLeft, stopX + 86, 1, "after the return the divider follows the pointer");
    assert(!g.arming && !g.full);
    await p.mouse.up();
    // Written when the hand lets go, as nav.rs is written (the mock clamps with its rule).
    await persistedWidth(p, stopWidth - 86);
    assertEqual(p.__errors, [], "the page reported errors");
    await p.context().close();
    return (
      "stop " + stopWidth + "px (stage 360); 44px past: opacity " + arming.opacity.toFixed(3) + ", spine " +
      arming.spine.toFixed(2) + "px; 144px past: open completely at " + Math.round(full) + "px; back at the stop, then " +
      (stopWidth - 86) + "px under the pointer, persisted"
    );
  });

  await run.check("keys — End opens completely, → returns to the stop, ← at the stop snaps, Home and a double-click go to 400px", async () => {
    const p = await openPanelPage(browser);
    const stop = (await pullRead(p)).max;
    let g = await pullKey(p, "End");
    assert(g.full, "End did not open it completely");
    g = await pullKey(p, "ArrowRight");
    assert(!g.full, "→ from open completely did not return");
    near(g.panel, stop, 1, "→ returns to the stop");
    g = await pullKey(p, "ArrowLeft");
    assert(g.full, "← at the stop did not snap");
    g = await pullKey(p, "Home");
    assert(!g.full, "Home from open completely did not return");
    near(g.panel, 400, 1, "Home is the default 400px");
    g = await pullKey(p, "ArrowLeft");
    near(g.panel, 424, 1, "← widens by 24px");
    g = await pullKey(p, "ArrowRight");
    near(g.panel, 400, 1, "→ narrows by 24px");
    g = await pullKey(p, "ArrowRight");
    g = await pullKey(p, "ArrowRight");
    g = await pullKey(p, "ArrowRight");
    g = await pullKey(p, "ArrowRight");
    near(g.panel, 320, 1, "never under 320px");
    const box = await p.locator("#op-resizer").boundingBox();
    await p.mouse.dblclick(box.x + 3, box.y + 300);
    await pullSettled(p);
    g = await pullRead(p);
    near(g.panel, 400, 1, "a double-click goes back to 400px");
    assertEqual(g.focus, "op-resizer");
    await p.context().close();
    return "End → full, → → stop (" + stop + "px), ← → full, Home → 400, ← 424, → floor 320, double-click 400";
  });

  await run.check("close brings the whole conversation back and clears open completely; reopening is at the split width", async () => {
    const p = await openPanelPage(browser);
    await pullKey(p, "Home");
    for (let i = 0; i < 6; i++) await pullKey(p, "ArrowLeft"); // 400 + 6 × 24 = 544
    let g = await pullKey(p, "End");
    assert(g.full);
    // ×
    await p.click("#op-close");
    g = await pullRead(p);
    assert(!g.open, "× did not close the panel");
    assert(!g.full, "closing left the panel open completely");
    assertEqual(g.composerIn, "stage");
    // Home again, the empty field is one line tall. Found on the real app (the S9 walk's close
    // picture): moved into a conversation still at zero width, it measured itself 111px tall.
    const home = await p.evaluate(() => ({
      field: Math.round(document.getElementById("input").getBoundingClientRect().height),
      send: Math.round(document.getElementById("send").getBoundingClientRect().height),
    }));
    assert(home.field <= home.send, "the field came home " + home.field + "px tall beside a " + home.send + "px Send");
    near(g.stage, g.appWidth - g.railWidth, 1, "the whole conversation is back");
    assertEqual(g.stageVisibility, "visible");
    near(g.stageOpacity, 1, 0.001);
    await p.click("#out-top");
    await p.waitForSelector("#outpanel .orow");
    await pullSettled(p);
    g = await pullRead(p);
    assert(!g.full, "reopened open completely");
    near(g.panel, 544, 1, "reopened at the split width it had");
    // Escape from the list, and ⌘⇧O, do the same from open completely.
    await pullKey(p, "End");
    await p.focus("#op-body .orow");
    await p.keyboard.press("Escape");
    g = await pullRead(p);
    assert(!g.open && !g.full, "Escape from the list did not close it: " + JSON.stringify({ open: g.open, full: g.full }));
    await p.click("#out-top");
    await p.waitForSelector("#outpanel .orow");
    await pullKey(p, "End");
    await p.keyboard.press("Meta+Shift+O");
    g = await pullRead(p);
    assert(!g.open && !g.full, "⌘⇧O did not close it");
    near(g.stage, g.appWidth - g.railWidth, 1);
    await p.context().close();
    return "× / Escape / ⌘⇧O from open completely: the conversation whole (" + Math.round(g.stage) + "px); reopened at 544px";
  });

  await run.check("the pill — ‹ Acme deal brings the conversation back at the stop and puts focus in its composer", async () => {
    const p = await openPanelPage(browser);
    await pullKey(p, "End");
    await p.click("#op-conv");
    await pullSettled(p);
    await p.waitForFunction(() => document.activeElement && document.activeElement.id === "input");
    const g = await pullRead(p);
    assert(!g.full);
    near(g.panel, g.max, 1, "the pill returns to the stop");
    near(g.stage, STAGE_MIN, 1);
    assertEqual(g.pill, null, "the pill is shown with the conversation back");
    // And the field, home after the conversation's slide back from zero, is one line tall.
    await p.waitForFunction(
      () => document.getElementById("input").getBoundingClientRect().height <= document.getElementById("send").getBoundingClientRect().height
    );
    await p.context().close();
    return "‹ Acme deal → the stop (" + Math.round(g.panel) + "px), the conversation at 360px, focus in the composer";
  });

  await run.check("sidebar away + open completely = the whole window; the sidebar back gives the room back", async () => {
    const p = await openPanelPage(browser);
    await pullKey(p, "End");
    await p.keyboard.press("Meta+Shift+S");
    await p.waitForFunction(() => document.body.classList.contains("rail-closed"));
    await pullSettled(p);
    let g = await pullRead(p);
    near(g.panel, g.appWidth, 1, "sidebar away and open completely is the window");
    assert(g.full);
    await p.keyboard.press("Meta+Shift+S");
    await p.waitForFunction(() => !document.body.classList.contains("rail-closed"));
    await pullSettled(p);
    g = await pullRead(p);
    near(g.panel, g.appWidth - g.railWidth, 1, "the sidebar back, open completely is the stage");
    // At the split: with the sidebar away the stop moves out to 1440 − 360.
    await pullKey(p, "ArrowRight");
    await p.keyboard.press("Meta+Shift+S");
    await p.waitForFunction(() => document.body.classList.contains("rail-closed"));
    await pullSettled(p);
    const before = (await pullRead(p)).max;
    assertEqual(before, Math.floor(g.appWidth - STAGE_MIN), "the stop with the sidebar away");
    g = await pullKey(p, "End");
    g = await pullKey(p, "ArrowRight");
    near(g.panel, before, 1, "→ returns to the wider stop");
    await p.keyboard.press("Meta+Shift+S");
    await p.waitForFunction(() => !document.body.classList.contains("rail-closed"));
    await pullSettled(p);
    g = await pullRead(p);
    near(g.panel, g.max, 1, "the sidebar back pulls the panel in to the new stop");
    near(g.stage, STAGE_MIN, 1, "and the conversation keeps its 360px");
    await p.context().close();
    return "1440px with the sidebar away; " + Math.round(g.appWidth - g.railWidth) + "px with it; stop " + before + " → " + g.max + "px";
  });

  await run.check("the floating composer is THE composer: a message sent from it lands in the thread; Escape clears its words first", async () => {
    const p = await openPanelPage(browser);
    await p.fill("#input", "half a thought");
    await pullKey(p, "End");
    let g = await pullRead(p);
    assertEqual(g.composerIn, "op-float");
    const draft = await p.evaluate(() => document.getElementById("input").value);
    assertEqual(draft, "half a thought", "the draft did not come along: one draft, two homes");
    const placed = await p.evaluate(() => {
      const f = document.getElementById("op-float").getBoundingClientRect();
      const panel = document.getElementById("outpanel").getBoundingClientRect();
      return { right: Math.round(panel.right - f.right), bottom: Math.round(panel.bottom - f.bottom), width: Math.round(f.width) };
    });
    assertEqual([placed.right, placed.bottom], [18, 18], "the composer floats at the panel's bottom right");
    assertEqual(placed.width, 460);
    // Escape with words in the floating field clears them, and only them.
    await p.focus("#input");
    await p.keyboard.press("Escape");
    g = await pullRead(p);
    assert(g.open && g.full, "Escape with words in the floating composer stepped the panel back");
    assertEqual(await p.evaluate(() => document.getElementById("input").value), "");
    // A send from there lands in the conversation behind.
    const before = await p.evaluate(() => document.querySelectorAll(".tl-user-bubble").length);
    await p.fill("#input", "add Tolliver to the comps and re-run the sheet");
    await p.keyboard.press("Enter");
    await p.waitForFunction((n) => document.querySelectorAll(".tl-user-bubble").length === n + 1, before);
    const sent = await p.evaluate(() => ({
      last: [...document.querySelectorAll(".tl-user-bubble")].pop().textContent,
      field: document.getElementById("input").value,
      home: document.getElementById("composer-zone").parentElement.id,
    }));
    assert(sent.last.includes("add Tolliver to the comps"), "the message is not in the thread: " + sent.last);
    assertEqual(sent.field, "");
    assertEqual(sent.home, "op-float", "sending moved the composer");
    // With the field empty, Escape steps the panel back as everywhere else (the list → closed).
    await p.focus("#input");
    await p.keyboard.press("Escape");
    g = await pullRead(p);
    assert(!g.open && !g.full, "Escape with an empty floating composer did not close the panel");
    assertEqual(g.composerIn, "stage");
    assertEqual(p.__errors, [], "the page reported errors");
    await p.context().close();
    return "draft carried in; Escape cleared the words; the message is in the thread; Escape again closed the panel";
  });

  await run.check("the conversation at its narrowest reflows, keeps everything, and still sends", async () => {
    const p = await openPanelPage(browser);
    await p.evaluate(() => window.RichOutput.setSplitWidth(10000)); // as nav.rs would restore a wide window's
    await pullSettled(p);
    await p.waitForFunction(() => document.getElementById("stage").classList.contains("narrow"));
    const g = await pullRead(p);
    near(g.stage, STAGE_MIN, 1);
    assert(g.narrow, "no `narrow` reflow at 360px of conversation");
    const r = await p.evaluate(() => {
      const stage = document.getElementById("stage").getBoundingClientRect();
      // A control the conversation shows must be inside it; the talk control may be withheld
      // when voice is unavailable on this fixture, and a control not shown cannot spill.
      const optional = { "talk-toggle": true };
      const inside = (id) => {
        const b = document.getElementById(id).getBoundingClientRect();
        if (!b.width) return !!optional[id];
        return b.left >= stage.left - 0.5 && b.right <= stage.right + 0.5;
      };
      const word = document.querySelector("#out-bottom .out-word");
      return {
        wordShown: getComputedStyle(word).display !== "none",
        topWordShown: getComputedStyle(document.querySelector("#out-top .out-word")).display !== "none",
        count: document.querySelector("#out-bottom .out-count").textContent,
        inside: ["rail-toggle", "out-top", "out-bottom", "send", "talk-toggle", "input"].filter((id) => !inside(id)),
        name: document.getElementById("out-bottom").getAttribute("aria-label"),
      };
    });
    assert(!r.wordShown, "the bottom button kept its word at 360px");
    assert(r.topWordShown, "the top button lost its word (only the bottom one drops it)");
    assertEqual(r.count, "9");
    assertEqual(r.name, "Output — 9 files from this thread", "its name is unchanged");
    assertEqual(r.inside, [], "controls spill out of the 360px conversation");
    const before = await p.evaluate(() => document.querySelectorAll(".tl-user-bubble").length);
    await p.fill("#input", "and the narrow one sends");
    await p.keyboard.press("Enter");
    await p.waitForFunction((n) => document.querySelectorAll(".tl-user-bubble").length === n + 1, before);
    await p.context().close();
    return "360px: the bottom button keeps icon and count, every control inside the column, a message sent";
  });

  await run.check("open completely is not persisted across a reload; the split width is", async () => {
    const p = await openPanelPage(browser);
    await pullKey(p, "Home");
    for (let i = 0; i < 5; i++) await pullKey(p, "ArrowLeft"); // 520
    await persistedWidth(p, 520);
    await pullKey(p, "End");
    await p.reload();
    await leaveHome(p);
    await p.waitForFunction(() => typeof window.RichOutput === "object" && typeof window.RichOutput.pull === "function");
    await p.waitForSelector(".nav-thread", { state: "attached" });
    await openThread(p, "acme", 9);
    await p.click("#out-top");
    await p.waitForSelector("#outpanel .orow");
    await pullSettled(p);
    const g = await pullRead(p);
    assert(!g.full, "open completely survived a reload");
    near(g.panel, 520, 1, "the split width did not survive a reload");
    await p.context().close();
    return "520px split, open completely, reload → 520px, not open completely";
  });

  await run.check("below 1180px there is no stop, no snap and no divider — the panel overlays at its split width", async () => {
    const p = await openPanelPage(browser, { viewport: { width: 1000, height: 800 } });
    const r = await p.evaluate(() => ({
      divider: getComputedStyle(document.getElementById("op-resizer")).display,
      width: Math.round(document.getElementById("outpanel").getBoundingClientRect().width),
    }));
    assertEqual(r, { divider: "none", width: 400 });
    // A window narrowing under 1180px while open completely brings the conversation back.
    await p.setViewportSize({ width: 1440, height: 800 });
    await pullKey(p, "End");
    await p.setViewportSize({ width: 1000, height: 800 });
    await p.waitForFunction(() => !window.RichOutput.pull().full);
    const g = await pullRead(p);
    assertEqual(g.composerIn, "stage");
    await p.context().close();
    return "1000px: no divider, 400px overlay; narrowing from open completely returned the conversation";
  });

  await run.check("reduced motion: the snap and the return happen, without the dimming or the slide", async () => {
    const p = await openPanelPage(browser, { reducedMotion: "reduce" });
    const g0 = await pullRead(p);
    const stopX = g0.appRight - g0.max;
    await p.mouse.move(g0.dividerLeft + 3, 460);
    await p.mouse.down();
    await p.mouse.move(stopX - 60, 460, { steps: 10 });
    const armed = await pullRead(p);
    await p.mouse.move(stopX - 140, 460, { steps: 4 });
    await pullSettled(p);
    const full = await pullRead(p);
    await p.mouse.up();
    const t = await p.evaluate(() => getComputedStyle(document.getElementById("outpanel")).transitionDuration);
    assertEqual(armed.stageOpacity, 1, "the conversation dimmed under reduced motion");
    assert(full.full, "the snap did not happen under reduced motion");
    assertEqual(t, "0s", "the panel slides under reduced motion");
    await p.context().close();
    return "no dimming while armed, no slide; the snap still happens";
  });

  // ---- contrast, computed, both themes; and the six round-17.1 states, photographed ----------
  for (const theme of ["dark", "light"]) {
    await run.check(theme + " — the wide pull's pill, its borders, the floating composer and the divider's focus mark clear WCAG AA, computed", async () => {
      const p = await openPanelPage(browser, { theme });
      await pullKey(p, "End");
      await p.focus("#op-resizer");
      const read = () =>
        p.evaluate(() => {
          const $ = (id) => document.getElementById(id);
          const cs = (n) => getComputedStyle(n);
          const plane = cs($("outpanel")).backgroundColor;
          const pill = $("op-conv");
          return {
            plane,
            pillBg: cs(pill).backgroundColor,
            pillText: cs($("op-conv-t")).color,
            pillSize: parseFloat(cs($("op-conv-t")).fontSize),
            pillBorder: cs(pill).borderTopColor,
            chevron: cs(pill.querySelector("svg")).color,
            card: cs($("composer-zone")).borderTopColor,
            cardBg: cs($("composer-zone")).backgroundColor,
            focusMark: cs($("op-resizer")).boxShadow,
          };
        });
      const rest = await read();
      await p.hover("#op-conv");
      await p.waitForFunction(() => getComputedStyle(document.getElementById("op-conv")).borderTopColor !== "");
      const hover = await read();
      const base = parseCssColor(theme === "dark" ? "rgb(12, 19, 34)" : "rgb(234, 230, 221)");
      const solid = (c, under) => {
        const x = parseCssColor(c);
        return x.a < 1 ? compositeOver(x, under) : x;
      };
      const plane = solid(rest.plane, base);
      const pillRest = solid(rest.pillBg, plane);
      const pillHover = solid(hover.pillBg, plane);
      const focusColor = /rgba?\([^)]*\)/.exec(rest.focusMark);
      const pairs = [
        ["pill text at rest (16px)", "text", solid(rest.pillText, pillRest), pillRest],
        ["pill text hovered", "text", solid(hover.pillText, pillHover), pillHover],
        ["pill border at rest, on the panel plane", "indicator", solid(rest.pillBorder, plane), plane],
        ["pill border hovered (--gold-text), on the panel plane", "indicator", solid(hover.pillBorder, plane), plane],
        ["pill chevron at rest", "indicator", solid(rest.chevron, pillRest), pillRest],
        ["pill chevron hovered", "indicator", solid(hover.chevron, pillHover), pillHover],
        ["floating composer's boundary, on the panel plane", "indicator", solid(rest.card, plane), plane],
        ["divider focus mark (--gold-text), on the panel plane", "indicator", solid(focusColor ? focusColor[0] : "rgba(0,0,0,0)", plane), plane],
      ];
      assertEqual(rest.pillSize, 16, "the pill's words are 16px");
      const lines = [];
      for (const [what, kind, fg, bg] of pairs) {
        const ratio = Math.round(contrastRatio(fg, bg) * 100) / 100;
        const floor = kind === "indicator" ? 3 : 4.5;
        lines.push(what + " " + hex(fg) + " on " + hex(bg) + " " + ratio + ":1");
        assert(ratio >= floor, theme + ": " + what + " is " + ratio + ":1 against " + floor + ":1 (" + hex(fg) + " on " + hex(bg) + ")");
      }
      assertEqual(hex(solid(rest.cardBg, plane)), hex(solid(theme === "dark" ? "rgb(12, 19, 34)" : "rgb(234, 230, 221)", plane)), "the floating composer is not on --paper, the plane its lines were computed on");
      await p.context().close();
      return lines.join(" | ");
    });

    await run.check(theme + " — the six round-17.1 states, reproduced and photographed: stop, snap, full, full-list, everything, wide", async () => {
      const made = [];
      const picture = async (p, state, opts) => {
        await awaitWorkerChipSettled(p);
        const s = await shot(p, "output-" + state + "-" + theme, Object.assign({ fullPage: false, parkPointer: true }, opts || {}));
        publishShotFile(s.file, path.join(SHOTS, "output-" + state + "-" + theme + ".png"));
        made.push(state);
      };
      const fileRow = (p, name) => p.click('.orow[data-output="' + byName(name).id + '"]');

      // wide — round 17's 560px, kept in 17.1: the panel restored at 560 on the sheet.
      let p = await openPanelPage(browser, { theme });
      await p.evaluate(() => window.RichOutput.setSplitWidth(560));
      await fileRow(p, "comps-2026-10-04.xlsx");
      await pullSettled(p);
      near((await pullRead(p)).panel, 560, 1, "wide");
      await picture(p, "wide");
      await p.context().close();

      // stop — pulled to the stop, the conversation at its narrowest, with the sheet open.
      p = await openPanelPage(browser, { theme });
      await fileRow(p, "comps-2026-10-04.xlsx");
      await p.evaluate(() => window.RichOutput.setSplitWidth(10000));
      await pullSettled(p);
      let g = await pullRead(p);
      near(g.stage, STAGE_MIN, 1, "stop");
      await picture(p, "stop");

      // snap — the same, held 60px past the stop with the chart open: half armed.
      await p.click("#of-back");
      await fileRow(p, "q3-revenue-chart.png");
      g = await pullRead(p);
      const stopX = g.appRight - g.max;
      await p.mouse.move(g.dividerLeft + 3, 460);
      await p.mouse.down();
      await p.mouse.move(stopX - 60, 460, { steps: 8 });
      g = await pullRead(p);
      assert(g.arming && !g.full, "snap: not arming at 60px past the stop");
      await picture(p, "snap", { parkPointer: false });
      await p.mouse.move(stopX, 460, { steps: 4 });
      await p.mouse.up();
      await p.context().close();

      // full — open completely at the sheet, a message typed in the floating composer.
      p = await openPanelPage(browser, { theme });
      await fileRow(p, "comps-2026-10-04.xlsx");
      await pullKey(p, "End");
      await p.fill("#input", "add Tolliver to the comps and re-run the sheet");
      await p.focus("#op-body");
      g = await pullRead(p);
      assert(g.full && g.composerIn === "op-float", "full");
      await picture(p, "full");
      await p.context().close();

      // full-list — open completely at the list, the sidebar still open beside it.
      p = await openPanelPage(browser, { theme });
      await pullKey(p, "End");
      await p.focus("#op-body");
      g = await pullRead(p);
      assert(g.full && g.railWidth > 0, "full-list");
      await picture(p, "full-list");
      await p.context().close();

      // everything — the sidebar away and open completely: the walkthrough at the window's width.
      p = await openPanelPage(browser, { theme });
      await fileRow(p, "comps-walkthrough.mp4");
      await p.keyboard.press("Meta+Shift+S");
      await p.waitForFunction(() => document.body.classList.contains("rail-closed"));
      await pullKey(p, "End");
      await p.focus("#op-body");
      g = await pullRead(p);
      near(g.panel, g.appWidth, 1, "everything");
      // The empty floating field is one whole line tall, measured in its new home (it was once
      // measured while that home was still `display: none`, and came out 20px with its words cut).
      const field = await p.evaluate(() => ({
        h: Math.round(document.getElementById("input").getBoundingClientRect().height),
        talk: Math.round(document.getElementById("talk-toggle").getBoundingClientRect().height),
      }));
      assert(field.h >= field.talk - 2, "the floating field is " + field.h + "px against its " + field.talk + "px controls");
      await picture(p, "everything");
      assertEqual(p.__errors, [], "the page reported errors");
      await p.context().close();
      return made.map((s) => "shots-output/output-" + s + "-" + theme + ".png").join(", ");
    });
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

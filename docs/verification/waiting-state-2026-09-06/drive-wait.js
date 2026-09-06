"use strict";
// WHAT THE CEO SEES WHILE HE WAITS — the driver behind every frame in `frames/`.
//
// The first outside user of RichOS, 2026-09-06, relayed by the CEO:
//
//   "One thing from a quality perspective, it takes a lot of time to get a reply, a lot of
//    spinning wheels waiting. … no interaction of feedback, so it looks like a crashed
//    application."
//
// This drives the SHIPPING renderer under WebKit — the engine Tauri renders through on
// macOS — with `send_message` never returning and the spine's own `rich://turn-status`
// events on the wire, which is exactly the shape of a real long turn: `send_message` does
// not resolve until the turn ends (`app/src-tauri/src/main.rs`), so for its whole duration
// the screen is driven by events and nothing else.
//
// IT NEVER CALLS A RENDERER FUNCTION DIRECTLY. Events are delivered through the callbacks
// `main.js` registered with `window.RichBridge.listen`, captured by an init script that
// wraps the bridge as mock.js assigns it. A frame here is therefore the same DOM a real
// event produces, not a picture of a function called by hand.
//
// NO AUDIO PATH IS TOUCHED: headless WebKit, no voice mode, no output device.
//
// RUN:
//   node drive-wait.js [outDir] [--pw=/path/to/node_modules/playwright]
//
// Playwright is resolved the same three ways the acceptance harness resolves it: `--pw=`,
// then RICHOS_PLAYWRIGHT, then an ordinary `require("playwright")`.

const path = require("path");
const fs = require("fs");

const UI = path.resolve(__dirname, "..", "..", "..", "app", "ui");
const args = process.argv.slice(2);
const pwArg = (args.find((a) => a.startsWith("--pw=")) || "").slice(5);
const OUT = args.find((a) => !a.startsWith("--")) || path.join(__dirname, "frames");
fs.mkdirSync(OUT, { recursive: true });

function loadPlaywright() {
  for (const c of [pwArg, process.env.RICHOS_PLAYWRIGHT, "playwright"].filter(Boolean)) {
    try {
      return require(c);
    } catch (_e) {
      /* keep looking */
    }
  }
  throw new Error("playwright not found — pass --pw=/path/to/node_modules/playwright");
}

// Wrap the bridge as mock.js assigns it, so every listener `main.js` registers can be driven
// from here and `send_message` can be made to hang the way a long turn makes it hang.
const INIT = `
window.__TAP = { listeners: {}, hang: false };
let _rb;
Object.defineProperty(window, "RichBridge", {
  configurable: true,
  get() { return _rb; },
  set(v) {
    const ol = v.listen.bind(v), oi = v.invoke.bind(v);
    v.listen = (name, cb) => { (window.__TAP.listeners[name] = window.__TAP.listeners[name] || []).push(cb); return ol(name, cb); };
    v.invoke = (cmd, args) => (window.__TAP.hang && cmd === "send_message") ? new Promise(() => {}) : oi(cmd, args);
    _rb = v;
  }
});
window.__emit = (name, payload) => (window.__TAP.listeners[name] || []).forEach((cb) => cb({ payload }));
`;

async function open(pw, theme) {
  const browser = await pw.webkit.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 860 } });
  page.on("pageerror", (e) => console.error("PAGEERROR", String(e)));
  // The STORE, not only the mirror — `syncAppearanceFromBackend` reconciles the two and the
  // backend wins, so a mirror-only seed is overwritten a few hundred ms after boot.
  await page.addInitScript((t) => {
    try {
      window.localStorage.setItem("richos-theme", t);
      window.localStorage.setItem("richos-font-scale", "100");
      window.localStorage.setItem("richos-mock-config", JSON.stringify({ theme: t, font_scale: 100, user_name: null }));
    } catch (e) {
      /* storage unavailable: theme-boot falls back to the shipped default, dark */
    }
  }, theme);
  await page.addInitScript(INIT);
  await page.goto("file://" + UI + "/index.html");
  await page
    .evaluate(() => {
      const s = window.RichSplash;
      if (s && s.state && s.state.shown && !s.state.reason) s.yieldNow("waiting-state-record");
    })
    .catch(() => {});
  await page.waitForFunction(() => !document.getElementById("splash"), { timeout: 8000 }).catch(() => {});
  await page.waitForFunction("typeof window.RichHome === 'object'", { timeout: 8000 }).catch(() => {});
  await page.evaluate(() => {
    if (window.RichHome && window.RichHome.isOpen()) window.RichHome.hide("waiting-state-record");
  });
  await page.waitForFunction(() => { const h = document.getElementById("home"); return !h || h.hidden; }, { timeout: 8000 }).catch(() => {});
  await page.waitForTimeout(400);
  const painted = await page.evaluate(() => document.documentElement.getAttribute("data-theme"));
  if (painted !== theme) throw new Error("asked for " + theme + ", the document painted " + painted);
  return { browser, page };
}

/// Everything a person could READ, plus whether anything is moving. Element-level, so an
/// invisible node cannot be counted as something on screen.
async function describe(page, label) {
  return page.evaluate((label) => {
    const vis = (e) => {
      const r = e.getBoundingClientRect();
      const st = getComputedStyle(e);
      return r.width > 0 && r.height > 0 && st.visibility !== "hidden" && st.display !== "none" && r.bottom > 0 && r.top < innerHeight;
    };
    const texts = [];
    document.querySelectorAll("#stage *").forEach((e) => {
      if (e.children.length) return;
      const t = (e.textContent || "").trim();
      if (t && vis(e)) texts.push(t);
    });
    const band = document.getElementById("turn-wait");
    const dur = document.querySelector(".tl-duration-label");
    const fail = document.querySelector(".tl-failure, .tl-failure-card, [class*='failure']");
    return {
      label,
      band: band
        ? {
            tone: band.dataset.tone,
            head: band.querySelector(".wait-head").textContent,
            time: band.querySelector(".wait-time").textContent,
            detail: band.querySelector(".wait-detail").textContent,
            visible: vis(band),
            markFlashing: !!band.querySelector(".wait-mark--flash"),
          }
        : null,
      durationRow: dur ? dur.textContent : null,
      failureCardOnScreen: !!(fail && vis(fail)),
      composerMode: document.getElementById("composer-row").dataset.mode,
      stopVisible: !document.getElementById("stop").hidden,
      waitModel: window.__RICHOS_WAIT__ ? window.__RICHOS_WAIT__() : null,
      visibleText: texts,
    };
  }, label);
}

async function startTurn(page, turnId) {
  await page.evaluate(() => { window.__TAP.hang = true; });
  const fence = await page.evaluate(() => {
    const m = window.__RICHOS_TIMELINE__();
    return { entityId: m.entityId, threadId: m.threadId, bindingRevision: m.bindingRevision };
  });
  await page.fill("#input", "Draft the Q4 board memo from the numbers in the folder.");
  await page.press("#input", "Enter");
  await page.evaluate(
    (o) => {
      window.__emit("rich://turn-status", Object.assign({}, o.fence, {
        turnId: o.turnId, status: "queued", startedAt: null, activeDurationMs: null, visibility: "ceo", at: Date.now(),
      }));
      setTimeout(() => {
        const startedAt = Date.now();
        window.__emit("rich://turn-started", { threadId: o.fence.threadId, turnId: o.turnId, at: startedAt });
        window.__emit("rich://turn-status", Object.assign({}, o.fence, {
          turnId: o.turnId, status: "working", startedAt, activeDurationMs: null, visibility: "ceo", at: startedAt,
        }));
      }, 900);
    },
    { fence, turnId }
  );
  return fence;
}

async function shot(page, name) {
  await page.screenshot({ path: path.join(OUT, name + ".png") });
}

// =========================================================================================
// The scenarios
// =========================================================================================

/// 1. THE REPORT ITSELF: a long turn that produces nothing observable. Read at 2s, 10s, 30s
///    and 60s — the four instants the brief asks about.
async function silent(pw, theme) {
  const { browser, page } = await open(pw, theme);
  const t0 = Date.now();
  await startTurn(page, "turn_silent");
  const out = [];
  for (const s of [2, 10, 30, 60]) {
    const wait = t0 + s * 1000 - Date.now();
    if (wait > 0) await page.waitForTimeout(wait);
    out.push(await describe(page, s + "s"));
    await shot(page, "silent-" + theme + "-" + String(s).padStart(2, "0") + "s");
  }
  await browser.close();
  return out;
}

/// 2. A TURN THAT IS ACTUALLY DOING THINGS. The band relays the backend's own `summary`
///    verbatim and times it; then the work goes quiet and the band says so.
async function active(pw, theme) {
  const { browser, page } = await open(pw, theme);
  const fence = await startTurn(page, "turn_active");
  const out = [];
  await page.waitForTimeout(2500);
  await page.evaluate((f) => {
    window.__emit("rich://activity-upserted", Object.assign({}, f, {
      kind: "activity", id: "mach_1", turnId: "turn_active", createdAt: Date.now(), sequence: 1,
      slot: "stream", visibility: "ceo", activityType: "command", state: "running",
      summary: "Read the Q3 board pack", at: Date.now(),
    }));
  }, fence);
  await page.waitForTimeout(1200);
  out.push(await describe(page, "activity just arrived"));
  await shot(page, "active-" + theme + "-01-activity");

  await page.waitForTimeout(8000);
  out.push(await describe(page, "8s after that activity"));
  await shot(page, "active-" + theme + "-02-eight-seconds-later");

  // Text starts arriving.
  await page.evaluate((f) => {
    window.__emit("rich://message-started", Object.assign({}, f, {
      turnId: "turn_active", messageId: "turn_active:text:0", phase: "unknown", seq: 2, visibility: "ceo", at: Date.now(),
    }));
    window.__emit("rich://message-delta", Object.assign({}, f, {
      turnId: "turn_active", messageId: "turn_active:text:0", seq: 3, textDelta: "Here is where the numbers land.", visibility: "ceo", at: Date.now(),
    }));
  }, fence);
  await page.waitForTimeout(900);
  out.push(await describe(page, "writing the reply"));
  await shot(page, "active-" + theme + "-03-writing");

  // …and then it goes quiet, past the 25s threshold.
  await page.waitForTimeout(27000);
  out.push(await describe(page, "quiet after the writing stopped"));
  await shot(page, "active-" + theme + "-04-quiet");
  await browser.close();
  return out;
}

/// 3. THE DEAD TURN. A positive termination signal — `rich://turn-error` and the ledger's
///    `turn-status: failed`, which is the ONLY way this app is allowed to conclude a turn
///    has ended (continuity §5.2: never inferred from silence). The band must GO, and the
///    turn's own failure card must be what is left.
async function dead(pw, theme) {
  const { browser, page } = await open(pw, theme);
  const fence = await startTurn(page, "turn_dead");
  const out = [];
  await page.waitForTimeout(6000);
  out.push(await describe(page, "6s in, still working"));
  await shot(page, "dead-" + theme + "-01-before");
  // ONLY the typed terminal. `rich://turn-error` is deliberately NOT emitted here, and the
  // reason is a limitation of this harness rather than a fact about the product: its
  // listener calls `loadTimeline()`, which re-reads `get_timeline` from the browser mock —
  // and the mock never recorded this turn, because the whole scenario rests on
  // `send_message` never returning. In the shipping app the prompt is fsync'd `received`
  // BEFORE anything else (`spine.rs` `submit_prompt`, persist-before-send), so that reload
  // returns the CEO's message and the failed turn. Here it returns an empty thread and
  // wipes the screen back to the greeting — a picture of the mock's empty ledger, not of
  // RichOS. `rich://turn-status: failed` is the event that draws the failure treatment
  // (main.js's own note on the `turn-error` listener says so), and it is what this frame
  // measures.
  await page.evaluate((f) => {
    window.__emit("rich://turn-status", Object.assign({}, f, {
      turnId: "turn_dead", status: "failed", startedAt: Date.now() - 6000, activeDurationMs: 6000, visibility: "ceo", at: Date.now(),
    }));
  }, fence);
  await page.waitForTimeout(1200);
  out.push(await describe(page, "the turn died"));
  await shot(page, "dead-" + theme + "-02-after");
  // And it STAYS dead: nothing re-reassures on the next tick.
  await page.waitForTimeout(4000);
  out.push(await describe(page, "5s after it died"));
  await shot(page, "dead-" + theme + "-03-five-seconds-later");
  await browser.close();
  return out;
}

// =========================================================================================

(async () => {
  const pw = loadPlaywright();
  const record = {};
  for (const theme of ["dark", "light"]) {
    record["silent/" + theme] = await silent(pw, theme);
    record["active/" + theme] = await active(pw, theme);
    record["dead/" + theme] = await dead(pw, theme);
  }
  fs.writeFileSync(path.join(OUT, "readings.json"), JSON.stringify(record, null, 2) + "\n");
  for (const [k, frames] of Object.entries(record)) {
    console.log("\n### " + k);
    for (const f of frames) {
      const b = f.band;
      console.log(
        "  " + String(f.label).padEnd(30),
        b ? "[" + b.tone + "] " + b.head + " | " + b.time + " | " + b.detail : "(no band)",
        "  durationRow=" + JSON.stringify(f.durationRow)
      );
    }
  }
  console.log("\nframes + readings.json ->", OUT);
})().catch((e) => {
  console.error("FAILED", e);
  process.exit(1);
});

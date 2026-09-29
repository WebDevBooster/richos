// NAVIGATION EVIDENCE — what the page was doing when a navigation failed, written down at the
// failure boundary instead of guessed at afterwards.
//
// WHY THIS FILE EXISTS. On 2026-09-21 release run `20260921T114115Z-c0fd6ac5` ran all 56 UI
// suites and 55 passed. `contrast.js` failed on ONE `page.goto: Timeout 30000ms exceeded` at
// `entity-view/dark` — a `file://` load of `index.html` that normally takes well under a
// tenth of a second. The isolated rerun passed all 65 checks (109 loads, slowest 82.296 ms),
// and the only thing the failed run left behind was Playwright's two-line call log. The
// cause is still unknown, and the record's instruction for the next occurrence is: capture
// the actual failing navigation state; do not quarantine the suite and do not widen the
// deadline (richos-hq `docs/verification/2026-09-21-signed-release-rerun/README.md`).
//
// This is that capture, and it is deliberately ALL it is:
//
//   * THE TIMEOUT IS NOT TOUCHED. The wrapped call receives exactly the arguments the suite
//     passed, and the page's own default timeout is never read or set here. The deadline the
//     suite asked for is the deadline Playwright enforces.
//   * THE FAILURE IS NOT TOUCHED. The original error object is rethrown unchanged, after the
//     bundle is written, so the FAIL line a suite prints is byte-identical to what it printed
//     before this file existed. Nothing here retries, and nothing here can turn a failure
//     into a pass: the only path that returns a value is the one where the navigation itself
//     returned one.
//   * A PASSING NAVIGATION COSTS A FEW LISTENERS FOR ITS OWN DURATION and writes nothing. The
//     listeners are attached when the call starts and removed when it settles, so a suite's
//     traffic between navigations is never observed and never paid for.
//
// WHERE IT HOOKS IN. Eighty-odd `page.goto(...)` calls across the suites, and every one of
// them reaches its page through `loadPlaywright()` in `harness.js`. So the capture is
// installed there, on the browser type, once — rather than at eighty call sites that the
// next suite would not know to copy. The approach is the one the 2026-09-21 diagnostic
// (`navigation-diagnostic.cjs` in that record) proved on the real contrast suite, made
// permanent and extended to the state that diagnostic did not have.
//
// WHERE THE BUNDLE GOES. `RICHOS_UI_NAV_EVIDENCE_DIR` when set — `run.js` points it at
// `<receipts>/navigation/`, beside the receipts the build gate already keeps and already
// names in its refusal — and `.shots/navigation-failures/` (gitignored per-run scratch) for a
// suite run by hand. Each failure is one `<suite>-<pid>-<n>.json`, plus a `.png` when the page
// could still paint one, both written to a temporary name and renamed into place so a reader
// never sees half a file. `RICHOS_UI_NAV_EVIDENCE=off` removes the instrumentation entirely.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const SHOT_DIR = path.resolve(__dirname, "..", ".shots");
const MARK = Symbol.for("richos.navigationEvidence");

/// At most this many bundles per suite process. A suite whose every navigation fails is
/// already red and already explained by its first few; the cap keeps a broken run from
/// filling a disk with the same story.
const MAX_BUNDLES = 5;
/// Per-list bounds, so one bundle is always a readable size.
const MAX_EVENTS = 200;
const MAX_CONSOLE = 50;
/// How many recent PASSING navigations each process remembers — the "was this slow all along
/// or did one load suddenly stop" question. Durations only; nothing is written for them.
const MAX_HISTORY = 10;
/// Collection bounds. Each step after a failure is raced against its own ceiling, so a page
/// that is wedged cannot turn the evidence collection into a second hang.
const EVAL_MS = 2000;
const SHOT_MS = 3000;
/// The CPU sample's interval: two readings of the kernel's tick counters this far apart.
const CPU_SAMPLE_MS = 1000;
/// Ceiling for each best-effort helper process (`sysctl`, `ps`). Neither is ever required.
const HOST_MS = 3000;

function enabled() {
  return String(process.env.RICHOS_UI_NAV_EVIDENCE || "").toLowerCase() !== "off";
}

function evidenceDir() {
  return process.env.RICHOS_UI_NAV_EVIDENCE_DIR || path.join(SHOT_DIR, "navigation-failures");
}

// ---------------------------------------------------------------------------------------
// What the suite was doing — set by `createRun().check()`
// ---------------------------------------------------------------------------------------
//
// SURFACE AND THEME WITHOUT A SUITE HAVING TO SAY THEM. The check name carries the surface
// (`9.entity-view  §3.5's company overview…` in the 2026-09-21 failure), and the page's
// context options carry the theme: `contrast.js` opens every walk with
// `browser.newPage({ colorScheme: theme })`, and `appearance.js` and `splash.js` do the same.
// The page's own `data-theme` and stored preference are read too, when it can still answer.

const current = { label: null, check: null };
const history = [];
let navigations = 0;
let bundles = 0;

function setCurrentCheck(label, check) {
  current.label = label;
  current.check = check;
}

// ---------------------------------------------------------------------------------------
// Installation
// ---------------------------------------------------------------------------------------

function instrumentPlaywright(pw) {
  if (!pw || !enabled()) return pw;
  for (const name of ["webkit", "chromium", "firefox"]) {
    const type = pw[name];
    if (!type || typeof type.launch !== "function" || type[MARK]) continue;
    const launch = type.launch.bind(type);
    type.launch = async (...args) => instrumentBrowser(await launch(...args));
    type[MARK] = true;
  }
  return pw;
}

function instrumentBrowser(browser) {
  if (!browser || browser[MARK]) return browser;
  browser[MARK] = true;
  // `Browser.newPage` goes through `this.newContext` (playwright-core 1.61,
  // coreBundle.js `async newPage(options = {})`), so wrapping newContext covers both.
  const newContext = browser.newContext.bind(browser);
  browser.newContext = async (...args) => instrumentContext(await newContext(...args), args[0]);
  for (const ctx of browser.contexts()) instrumentContext(ctx, null);
  return browser;
}

function instrumentContext(ctx, options) {
  if (!ctx || ctx[MARK]) return ctx;
  ctx[MARK] = { options: pickContextOptions(options) };
  ctx.on("page", (page) => instrumentPage(page, ctx));
  const newPage = ctx.newPage.bind(ctx);
  ctx.newPage = async (...args) => instrumentPage(await newPage(...args), ctx);
  for (const page of ctx.pages()) instrumentPage(page, ctx);
  return ctx;
}

function pickContextOptions(o) {
  if (!o || typeof o !== "object") return null;
  const out = {};
  for (const k of ["viewport", "colorScheme", "deviceScaleFactor", "reducedMotion", "locale", "timezoneId"]) {
    if (o[k] !== undefined) out[k] = o[k];
  }
  return out;
}

function instrumentPage(page, ctx) {
  if (!page || page[MARK]) return page;
  page[MARK] = { ctx };
  for (const method of ["goto", "reload"]) {
    const original = page[method].bind(page);
    page[method] = (...args) => observed(page, method, original, args);
  }
  return page;
}

// ---------------------------------------------------------------------------------------
// One observed navigation
// ---------------------------------------------------------------------------------------

async function observed(page, method, original, args) {
  navigations++;
  const rec = startRecording(page, method, args);
  let result;
  try {
    result = await original(...args);
  } catch (error) {
    rec.failedAt = performance.now();
    rec.failedAtIso = new Date().toISOString();
    try {
      await writeBundle(page, rec, error);
    } catch (e) {
      // Evidence collection must never replace the failure it was collecting evidence for.
      process.stderr.write(`  navigation evidence: collection itself failed (${(e && e.message) || e})\n`);
    }
    rec.stop();
    throw error;
  }
  rec.stop();
  history.push({ method, url: rec.url, ms: round(performance.now() - rec.t0) });
  if (history.length > MAX_HISTORY) history.shift();
  return result;
}

function round(n) {
  return Math.round(n * 1000) / 1000;
}

function startRecording(page, method, args) {
  const t0 = performance.now();
  const rec = {
    t0,
    startedAtIso: new Date().toISOString(),
    method,
    url: method === "goto" ? String(args[0]) : safe(() => page.url()),
    options: jsonSafe(method === "goto" ? args[1] : args[0]),
    lifecycle: [],
    requests: new Map(),
    failedRequests: [],
    finishedRequests: 0,
    console: [],
    consoleOther: 0,
    pageErrors: [],
    failedAt: null,
  };
  const at = () => {
    const now = performance.now();
    const o = { ms: round(now - t0) };
    if (rec.failedAt !== null) o.afterFailure = true;
    return o;
  };
  const main = () => safe(() => page.mainFrame());
  const push = (list, item, max) => {
    if (list.length < max) list.push(item);
  };
  const listeners = {
    request: (req) => {
      const r = Object.assign(at(), {
        url: req.url(),
        method: req.method(),
        resourceType: req.resourceType(),
        navigation: safe(() => req.isNavigationRequest() && req.frame() === main()),
        response: null,
        done: false,
      });
      if (rec.requests.size < MAX_EVENTS) rec.requests.set(req, r);
      if (r.navigation) push(rec.lifecycle, Object.assign(at(), { event: "request", url: r.url }), MAX_EVENTS);
    },
    response: (res) => {
      const req = safe(() => res.request());
      const r = req && rec.requests.get(req);
      const o = Object.assign(at(), { status: res.status() });
      if (r) r.response = o;
      if (r && r.navigation) push(rec.lifecycle, Object.assign({ event: "response", url: r.url }, o), MAX_EVENTS);
    },
    requestfinished: (req) => {
      rec.finishedRequests++;
      const r = rec.requests.get(req);
      if (r) r.done = true;
    },
    requestfailed: (req) => {
      const r = rec.requests.get(req);
      if (r) r.done = true;
      push(
        rec.failedRequests,
        Object.assign(at(), { url: req.url(), failure: safe(() => (req.failure() || {}).errorText) || null }),
        MAX_EVENTS
      );
    },
    framenavigated: (frame) => {
      if (frame === main()) push(rec.lifecycle, Object.assign(at(), { event: "commit", url: frame.url() }), MAX_EVENTS);
    },
    domcontentloaded: () => push(rec.lifecycle, Object.assign(at(), { event: "domcontentloaded" }), MAX_EVENTS),
    load: () => push(rec.lifecycle, Object.assign(at(), { event: "load" }), MAX_EVENTS),
    crash: () => push(rec.lifecycle, Object.assign(at(), { event: "crash" }), MAX_EVENTS),
    close: () => push(rec.lifecycle, Object.assign(at(), { event: "close" }), MAX_EVENTS),
    console: (m) => {
      const type = m.type();
      if (type === "error" || type === "warning") {
        push(rec.console, Object.assign(at(), { type, text: String(m.text()).slice(0, 2000) }), MAX_CONSOLE);
      } else {
        rec.consoleOther++;
      }
    },
    pageerror: (e) => push(rec.pageErrors, Object.assign(at(), { error: String(e).slice(0, 2000) }), MAX_CONSOLE),
  };
  for (const [event, fn] of Object.entries(listeners)) page.on(event, fn);
  rec.stop = () => {
    for (const [event, fn] of Object.entries(listeners)) page.off(event, fn);
  };
  return rec;
}

function safe(fn) {
  try {
    return fn();
  } catch (_e) {
    return null;
  }
}

function jsonSafe(v) {
  if (v === undefined) return null;
  try {
    return JSON.parse(JSON.stringify(v));
  } catch (_e) {
    return String(v);
  }
}

/// Race a promise against a ceiling. The loser is left to settle on its own; its rejection is
/// swallowed so a late failure from a wedged page cannot surface as an unhandled rejection.
function bounded(promise, ms, what) {
  let timer;
  const guard = new Promise((resolve) => {
    timer = setTimeout(() => resolve({ unavailable: `${what} did not answer within ${ms} ms` }), ms);
  });
  const wrapped = Promise.resolve(promise).then(
    (value) => ({ value }),
    (e) => ({ unavailable: `${what} failed: ${String((e && e.message) || e).split("\n")[0]}` })
  );
  return Promise.race([wrapped, guard]).finally(() => clearTimeout(timer));
}

// ---------------------------------------------------------------------------------------
// The bundle
// ---------------------------------------------------------------------------------------

async function writeBundle(page, rec, error) {
  const suite = path.basename(process.argv[1] || "unknown", ".js");
  if (bundles >= MAX_BUNDLES) {
    process.stderr.write(
      `  navigation evidence: ${MAX_BUNDLES} bundle(s) already written by this process; ` +
        `not capturing ${rec.method} ${rec.url}\n`
    );
    return;
  }
  bundles++;
  const collectStart = performance.now();
  const dir = evidenceDir();
  fs.mkdirSync(dir, { recursive: true });
  const base = `${suite}-${process.pid}-${bundles}`;

  // The page's own view first: it is the state closest to the failure.
  const dom = await bounded(page.evaluate(domSnapshot), EVAL_MS, "page.evaluate");
  let screenshot;
  const shot = await bounded(screenshotNow(page), SHOT_MS + 500, "page.screenshot");
  if (shot.value) {
    screenshot = base + ".png";
    atomicWrite(path.join(dir, screenshot), shot.value);
  } else {
    screenshot = { unavailable: shot.unavailable };
  }
  const host = await hostContext();

  const reached = {};
  for (const e of ["request", "response", "commit", "domcontentloaded", "load"]) {
    reached[e] = rec.lifecycle.some((l) => l.event === e && !l.afterFailure);
  }
  const requests = [...rec.requests.values()];
  const meta = page[MARK] || {};
  const bundle = {
    kind: "richos-ui-navigation-failure",
    version: 1,
    suite: suite + ".js",
    check: { label: current.label, name: current.check },
    commit: gitHead(),
    pid: process.pid,
    method: rec.method,
    url: rec.url,
    options: rec.options,
    error: { name: error && error.name, message: String((error && error.message) || error) },
    startedAt: rec.startedAtIso,
    failedAt: rec.failedAtIso,
    elapsedMs: round(rec.failedAt - rec.t0),
    reached,
    lifecycle: rec.lifecycle,
    requests: {
      observed: requests.length,
      finished: rec.finishedRequests,
      inFlight: requests.filter((r) => !r.done),
      failed: rec.failedRequests,
    },
    console: { errorsAndWarnings: rec.console, otherMessages: rec.consoleOther },
    pageErrors: rec.pageErrors,
    page: {
      closed: safe(() => page.isClosed()),
      url: safe(() => page.url()),
      frames: safe(() => page.frames().length),
      context: (meta.ctx && meta.ctx[MARK] && meta.ctx[MARK].options) || null,
    },
    dom: dom.value || { unavailable: dom.unavailable },
    screenshot,
    process: {
      navigationsThisProcess: navigations,
      bundleNumber: bundles,
      recentPasses: history.slice(),
      uptimeSeconds: round(process.uptime()),
      rssBytes: process.memoryUsage().rss,
    },
    host,
  };
  bundle.collectionMs = round(performance.now() - collectStart);
  const file = path.join(dir, base + ".json");
  atomicWrite(file, JSON.stringify(bundle, null, 2) + "\n");

  const hit = Object.entries(reached).filter(([, v]) => v).map(([k]) => k);
  const missed = Object.entries(reached).filter(([, v]) => !v).map(([k]) => k);
  process.stderr.write(
    `  navigation evidence: ${file}\n` +
      `        ${rec.method} ${rec.url} failed after ${bundle.elapsedMs} ms; ` +
      `reached ${hit.join(", ") || "nothing"}; not reached ${missed.join(", ") || "nothing"}; ` +
      `${bundle.requests.inFlight.length} request(s) in flight\n`
  );
}

/// A screenshot of a page whose load has NOT finished — which is the only kind this file ever
/// takes. Playwright waits for `document.fonts.ready` before every screenshot, and in WebKit
/// that promise does not settle while the document is still loading: measured on the
/// stalled-image fixture, the screenshot timed out at 3000 ms every time. Playwright's own
/// server reads `PW_TEST_SCREENSHOT_NO_FONTS_READY` to skip that one wait (playwright-core
/// 1.61, `_preparePageForScreenshot`); the server runs in this process, so it is set for this
/// call alone and put back. If a later Playwright drops the variable, the screenshot simply
/// times out again and the bundle says so — the failure path does not depend on it.
async function screenshotNow(page) {
  const had = Object.prototype.hasOwnProperty.call(process.env, "PW_TEST_SCREENSHOT_NO_FONTS_READY");
  const was = process.env.PW_TEST_SCREENSHOT_NO_FONTS_READY;
  process.env.PW_TEST_SCREENSHOT_NO_FONTS_READY = "1";
  try {
    return await page.screenshot({ timeout: SHOT_MS });
  } finally {
    if (had) process.env.PW_TEST_SCREENSHOT_NO_FONTS_READY = was;
    else delete process.env.PW_TEST_SCREENSHOT_NO_FONTS_READY;
  }
}

function atomicWrite(file, data) {
  const tmp = file + ".tmp-" + process.pid;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

/// Runs IN THE PAGE. Plain DOM and Performance APIs only; returns JSON.
function domSnapshot() {
  const ms = (n) => (typeof n === "number" ? Math.round(n * 1000) / 1000 : null);
  const nav = performance.getEntriesByType("navigation")[0] || null;
  const resources = performance.getEntriesByType("resource");
  const seen = new Set(resources.map((r) => r.name));
  const referenced = [];
  for (const el of document.querySelectorAll("script[src], link[href], img[src], iframe[src]")) {
    const url = el.src || el.href;
    const item = { tag: el.tagName.toLowerCase(), url, inResourceTiming: seen.has(url) };
    if (el.tagName === "IMG") item.complete = el.complete;
    referenced.push(item);
    if (referenced.length >= 100) break;
  }
  let storedTheme = null;
  try {
    storedTheme = window.localStorage.getItem("richos-theme");
  } catch (_e) {
    /* storage unavailable on this origin */
  }
  return {
    readyState: document.readyState,
    href: location.href,
    title: document.title,
    dataTheme: document.documentElement ? document.documentElement.getAttribute("data-theme") : null,
    storedTheme,
    pageNowMs: ms(performance.now()),
    navigationTiming: nav
      ? {
          type: nav.type,
          responseEnd: ms(nav.responseEnd),
          domInteractive: ms(nav.domInteractive),
          domContentLoadedEventEnd: ms(nav.domContentLoadedEventEnd),
          loadEventStart: ms(nav.loadEventStart),
          loadEventEnd: ms(nav.loadEventEnd),
        }
      : null,
    resources: resources.slice(-100).map((r) => ({
      name: r.name,
      initiatorType: r.initiatorType,
      startMs: ms(r.startTime),
      responseEndMs: ms(r.responseEnd),
      durationMs: ms(r.duration),
    })),
    referenced,
  };
}

function gitHead() {
  const r = safe(() =>
    spawnSync("git", ["rev-parse", "HEAD"], { cwd: __dirname, encoding: "utf8", timeout: 2000 })
  );
  return r && r.status === 0 ? r.stdout.trim() : null;
}

/// The machine around the failure: was it busy, and with what.
///
/// THE CPU SAMPLE NEEDS NO OTHER PROCESS. Until 2026-09-29 it came from `/usr/bin/top -l 2 -s 1`
/// under a 5-second ceiling, and nightly run `20260929T044015Z-588457c3` (UI suite, script
/// suites and the mutation pool side by side, load average 13.0 on 10 cores, the CPU guard
/// reading 89-92% busy) is where that fails: `spawnSync /usr/bin/top ETIMEDOUT`, no number,
/// and the one moment the sample matters (a loaded host) is the moment it cannot be taken. It
/// is now two readings of the kernel's own per-core tick counters (`os.cpus()`, which libuv
/// reads with `host_processor_info`), `CPU_SAMPLE_MS` apart, taken in this process. Busy is
/// everything that is not idle over that interval: user, nice, system and interrupt time,
/// the same split `scripts/testvm/reserve.py` admits heavy work on (`host_statistics`
/// HOST_CPU_LOAD_INFO, `cpu_policy.busy_percent`), so the two numbers compare directly. A
/// loaded host makes the interval run long, and `cpuSampleMs` records how long it really was.
///
/// Everything else here is BEST-EFFORT and bounded: the kernel's memory-pressure verdict and
/// the busiest processes each come from a helper process under a `HOST_MS` ceiling, and one
/// that cannot answer is written down as unavailable, never waited on and never fatal.
///
/// MEMORY: `freeMemBytes` is `os.freemem()`, which on macOS is free plus speculative pages
/// only. It leaves out the inactive pages the kernel reclaims on demand, so a low number is
/// normal and is NOT a pressure reading (2026-09-29, at pressure NORMAL: 2155 MB "free" beside
/// 6.5 GB inactive). The kernel's own verdict is `memoryPressure` (normal / warn / critical,
/// the level `reserve.py` refuses at CRITICAL) and `memoryAvailablePercent`.
async function hostContext() {
  const out = {
    loadavg: os.loadavg().map(round),
    cpus: os.cpus().length,
    freeMemBytes: os.freemem(),
    totalMemBytes: os.totalmem(),
    cpuBusyPercent: null,
    cpuSampleMs: null,
    memoryPressure: null,
    memoryAvailablePercent: null,
    busiestProcesses: null,
  };
  const cpu = await cpuSample(CPU_SAMPLE_MS);
  if (cpu.unavailable) out.cpuUnavailable = cpu.unavailable;
  else Object.assign(out, { cpuBusyPercent: cpu.busyPercent, cpuSampleMs: cpu.intervalMs });
  if (process.platform !== "darwin") return out;

  const mem = helper("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level", "kern.memorystatus_level"]);
  const lines = mem.stdout ? mem.stdout.trim().split("\n") : [];
  if (lines.length === 2 && /^\d+$/.test(lines[0]) && /^\d+$/.test(lines[1])) {
    const level = Number(lines[0]);
    out.memoryPressure = { 1: "normal", 2: "warn", 4: "critical" }[level] || "level " + level;
    out.memoryAvailablePercent = Number(lines[1]);
  } else {
    out.memoryUnavailable = mem.unavailable || "sysctl answered " + JSON.stringify(mem.stdout);
  }

  // One `ps` snapshot, busiest first. Its %CPU is the kernel's decaying per-process average,
  // which says what was busy around the failure; `cpuBusyPercent` is the measured host number.
  const ps = helper("/bin/ps", ["-A", "-r", "-o", "pid=,%cpu=,comm="]);
  if (ps.stdout) {
    out.busiestProcesses = ps.stdout
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean)
      .slice(0, 10)
      .map((l) => {
        const m = l.match(/^(\d+)\s+([0-9.]+)\s+(.*)$/);
        return m ? { pid: Number(m[1]), cpu: Number(m[2]), command: m[3] } : { raw: l };
      });
  } else {
    out.processesUnavailable = ps.unavailable;
  }
  return out;
}

/// Host CPU busy percent over `ms`, from two readings of the kernel's per-core tick counters.
async function cpuSample(ms) {
  const ticks = () => {
    let idle = 0;
    let total = 0;
    for (const c of os.cpus()) {
      const t = c.times;
      idle += t.idle;
      total += t.user + t.nice + t.sys + t.idle + t.irq;
    }
    return { idle, total };
  };
  try {
    const a = ticks();
    const t0 = performance.now();
    await new Promise((resolve) => setTimeout(resolve, ms));
    const b = ticks();
    const total = b.total - a.total;
    if (!(total > 0)) return { unavailable: "the kernel's CPU tick counters did not advance in " + ms + " ms" };
    const busy = 100 * (1 - (b.idle - a.idle) / total);
    if (!Number.isFinite(busy) || busy < 0 || busy > 100) return { unavailable: "CPU tick counters gave " + busy };
    return { busyPercent: round(busy), intervalMs: round(performance.now() - t0) };
  } catch (e) {
    return { unavailable: "CPU tick counters unreadable: " + ((e && e.message) || e) };
  }
}

/// A short helper process under `HOST_MS`. Returns `{ stdout }` or `{ unavailable }`.
function helper(file, args) {
  const r = safe(() =>
    spawnSync(file, args, {
      encoding: "utf8",
      timeout: HOST_MS,
      env: Object.assign({}, process.env, { LC_ALL: "C" }),
    })
  );
  if (r && r.status === 0 && r.stdout) return { stdout: r.stdout };
  const why = !r
    ? "did not run"
    : r.error
      ? String(r.error.message || r.error)
      : "exited " + (r.status === null ? "on " + r.signal : r.status);
  return { unavailable: file + ": " + why };
}

module.exports = {
  instrumentPlaywright,
  setCurrentCheck,
  evidenceDir,
  MAX_BUNDLES,
};

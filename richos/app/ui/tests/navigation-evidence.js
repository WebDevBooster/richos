// NAVIGATION EVIDENCE — the harness writes down what a page was doing when a navigation
// failed, and changes nothing else about the failure.
//
// THE FAILURE THIS IS FOR. 2026-09-21, release run `20260921T114115Z-c0fd6ac5`: one
// `page.goto: Timeout 30000ms exceeded.` in `contrast.js` at `entity-view/dark`, a `file://`
// load that normally takes under a tenth of a second. The isolated rerun passed, the cause is
// unknown, and the record's instruction is to capture the failing navigation state if it
// recurs — never to quarantine the suite, retry it or widen its deadline. The capture lives in
// `lib/navigation-evidence.js` and is installed for every suite by `loadPlaywright()`.
//
// WHAT THIS SUITE PROVES, and each check is a way the capture could be wrong:
//
//   1. It is really installed, and a navigation that succeeds returns Playwright's own
//      response and writes nothing — a capture proven only on failures could be absent.
//   2. NEGATIVE CONTROL. A load that never completes still turns its suite RED, with
//      Playwright's message byte-for-byte, and leaves a bundle holding the real lifecycle:
//      the document arrived and parsed, `load` never came, and the image holding it up is
//      named as in flight. The navigation failed at the deadline it was given, not later.
//   3. The deadline is the PAGE'S. With no timeout passed, the page's own default decides,
//      and a document that never answers is recorded as exactly that.
//   4. A page whose own script never yields cannot hang the collection: the bundle is still
//      written, says which parts of the page would not answer, and the suite is still red.
//   5. The off switch removes the capture and changes nothing else about the failure.
//   6. What it costs a passing load, measured against the same page without it, and printed.
//
// The failing navigations run in a child process (`fixtures/navigation-hang-suite.js`) so
// their evidence lines and bundles never appear in THIS suite's output or in the run's real
// evidence directory, where they would read as a real failure.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const { spawnSync } = require("child_process");
const { loadPlaywright, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");
const png = require("./lib/png");
const bench = require("./lib/navigation-bench");

const FIXTURE = path.join(__dirname, "fixtures", "navigation-hang-suite.js");

function scratch(label) {
  return fs.mkdtempSync(path.join(os.tmpdir(), "richos-nav-evidence-" + label + "-"));
}

/// Run the fixture suite with its own evidence directory and NO ledger: its red result must
/// never be counted against the run this suite is part of.
function runFixture(mode, dir, extraEnv) {
  const env = Object.assign({}, process.env, { RICHOS_UI_NAV_EVIDENCE_DIR: dir }, extraEnv || {});
  delete env.RICHOS_UI_TESTS_LEDGER;
  if (!extraEnv || !("RICHOS_UI_NAV_EVIDENCE" in extraEnv)) delete env.RICHOS_UI_NAV_EVIDENCE;
  const r = spawnSync(process.execPath, [FIXTURE, mode], { env, encoding: "utf8", timeout: 60000 });
  return { status: r.status, signal: r.signal, stdout: r.stdout || "", stderr: r.stderr || "", error: r.error };
}

function bundlesIn(dir) {
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => ({ file: path.join(dir, f), data: JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")) }));
}

function oneBundle(dir, r) {
  const found = bundlesIn(dir);
  assertEqual(found.length, 1, "bundles written by one failing navigation\n" + r.stderr);
  return found[0];
}

/// The fixture's FAIL line, exactly as `createRun().report()` prints a failed check.
function assertRedWith(r, message) {
  assert(!r.error, "the fixture did not run: " + (r.error && r.error.message));
  assertEqual(r.status, 1, "the fixture suite's exit code — a failed navigation must leave its suite red\n" + r.stdout + r.stderr);
  assert(/^ {2}FAIL {2}hang: /m.test(r.stdout), "no FAIL line for the hanging check:\n" + r.stdout);
  assert(
    r.stdout.includes(message),
    "the FAIL line must carry Playwright's own message, unchanged (" + JSON.stringify(message) + "):\n" + r.stdout
  );
}

function distinctPixels(file) {
  const img = png.decode(fs.readFileSync(file));
  const seen = new Set();
  const step = Math.max(1, Math.floor((img.width * img.height) / 4000));
  for (let i = 0; i < img.width * img.height; i += step) {
    const o = i * img.channels;
    seen.add(img.data[o] * 65536 + img.data[o + 1] * 256 + img.data[o + 2]);
  }
  return seen.size;
}

async function main() {
  const run = createRun("navigation evidence — what a failed page load was doing, and nothing else changed");
  const dirs = [];
  const mk = (label) => {
    const d = scratch(label);
    dirs.push(d);
    return d;
  };

  try {
    // ---- 1. installed, and silent on success ------------------------------------------------
    await run.check("1  installed on every page, and a navigation that succeeds returns Playwright's response and writes nothing", async () => {
      const dir = mk("pass");
      const was = process.env.RICHOS_UI_NAV_EVIDENCE_DIR;
      process.env.RICHOS_UI_NAV_EVIDENCE_DIR = dir;
      const server = http.createServer((req, res) => {
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        res.end("<!doctype html><title>ok</title><p>ok</p>");
      });
      await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
      const browser = await loadPlaywright().webkit.launch();
      try {
        const page = await browser.newPage();
        // THE POSITIVE PROBE. Without it, "wrote nothing" passes just as well when the capture
        // was never installed at all.
        assert(
          page.goto !== Object.getPrototypeOf(page).goto && page.reload !== Object.getPrototypeOf(page).reload,
          "page.goto / page.reload are Playwright's own: the navigation capture is not installed"
        );
        const res = await page.goto(`http://127.0.0.1:${server.address().port}/ok`);
        assertEqual(res && res.status(), 200, "the response a successful goto returns");
        const again = await page.reload();
        assertEqual(again && again.status(), 200, "the response a successful reload returns");
        const shell = await page.goto("file://" + path.join(UI_DIR, "index.html"));
        assert(shell !== undefined, "a successful file:// goto returned undefined");
        assertEqual(fs.readdirSync(dir), [], "files written by three successful navigations");
      } finally {
        await browser.close();
        server.closeAllConnections();
        server.close();
        if (was === undefined) delete process.env.RICHOS_UI_NAV_EVIDENCE_DIR;
        else process.env.RICHOS_UI_NAV_EVIDENCE_DIR = was;
      }
      return "goto 200, reload 200 and the shipping index.html over file://; 0 files written";
    });

    // ---- 2. the negative control -------------------------------------------------------------
    await run.check("2  NEGATIVE CONTROL: a load that never completes stays RED with Playwright's message, at its own deadline, and leaves the real lifecycle", async () => {
      const dir = mk("stall");
      const r = runFixture("stall-subresource", dir);
      assertRedWith(r, "page.goto: Timeout 1500ms exceeded.");
      const { file, data: b } = oneBundle(dir, r);
      assert(r.stderr.includes("navigation evidence: " + file), "the run's output must name the bundle:\n" + r.stderr);
      assertEqual(b.error.name, "TimeoutError", "the recorded error type");
      assert(b.error.message.startsWith("page.goto: Timeout 1500ms exceeded."), "recorded message: " + b.error.message);
      assertEqual(b.options, { timeout: 1500 }, "the options the suite passed, recorded as passed");
      // THE DEADLINE IS UNCHANGED: the navigation rejected at the 1500 ms it was given, never
      // before it and nowhere near a doubled or default one. The upper bound is scheduling
      // slack for a saturated machine (measured 1501.7-1503.8 ms on 2026-09-22), not a second
      // deadline — evidence collection starts only after the rejection and is not in this number.
      assert(b.elapsedMs >= 1500 && b.elapsedMs < 2500, "navigation rejected after " + b.elapsedMs + " ms, not at its 1500 ms deadline");
      assertEqual(
        b.reached,
        { request: true, response: true, commit: true, domcontentloaded: true, load: false },
        "lifecycle reached before the failure"
      );
      const stuck = b.requests.inFlight.map((q) => new URL(q.url).pathname);
      assertEqual(stuck, ["/never"], "requests still in flight at the failure");
      assertEqual(b.check.name, "hang: stall-subresource", "the check the failure happened in");
      assertEqual(b.page.context && b.page.context.colorScheme, "dark", "the theme the page was opened in");
      assertEqual(b.dom.readyState, "interactive", "the document's own readyState at the failure");
      assert(typeof b.screenshot === "string", "no screenshot of a page that could still paint: " + JSON.stringify(b.screenshot));
      const distinct = distinctPixels(path.join(dir, b.screenshot));
      assert(distinct >= 2, "the screenshot is one flat color (" + distinct + " distinct), not a render");
      if (process.platform === "darwin") {
        assert(typeof b.host.cpuBusyPercent === "number", "no CPU sample in the host context: " + JSON.stringify(b.host));
      }
      return (
        "exit 1, FAIL line unchanged, rejected at " + b.elapsedMs + " ms of 1500; reached request, response, commit, " +
        "domcontentloaded, not load; in flight: /never; screenshot " + distinct + " distinct colors; collection " +
        b.collectionMs + " ms"
      );
    });

    // ---- 3. the page's own default deadline ---------------------------------------------------
    await run.check("3  with no timeout passed, the page's own default decides — and a document that never answers is recorded as that", async () => {
      const dir = mk("nodoc");
      const r = runFixture("never-document", dir);
      assertRedWith(r, "page.goto: Timeout 1200ms exceeded.");
      const { data: b } = oneBundle(dir, r);
      assertEqual(b.options, null, "options recorded for a goto that passed none");
      assert(b.elapsedMs >= 1200 && b.elapsedMs < 2200, "navigation rejected after " + b.elapsedMs + " ms, not at the page's 1200 ms default");
      assertEqual(
        b.reached,
        { request: true, response: false, commit: false, domcontentloaded: false, load: false },
        "lifecycle reached before the failure"
      );
      assertEqual(b.requests.inFlight.map((q) => [new URL(q.url).pathname, q.resourceType]), [["/never-document", "document"]], "in flight");
      return "exit 1 at " + b.elapsedMs + " ms of the page's 1200 ms default; only the request was ever sent";
    });

    // ---- 4. a wedged page cannot hang the collection -------------------------------------------
    await run.check("4  a page whose script never yields cannot hang the collection — the bundle says what would not answer, and the suite stays red", async () => {
      const dir = mk("wedged");
      const t0 = Date.now();
      const r = runFixture("wedged", dir);
      const wall = Date.now() - t0;
      assertRedWith(r, "page.goto: Timeout 1500ms exceeded.");
      const { data: b } = oneBundle(dir, r);
      assertEqual(b.reached.commit, true, "the wedged document was committed");
      assertEqual(b.reached.domcontentloaded, false, "a script that never yields cannot reach domcontentloaded");
      assert(b.dom.unavailable, "the DOM snapshot of a wedged page should be recorded as unavailable: " + JSON.stringify(b.dom).slice(0, 300));
      assert(b.collectionMs < 15000, "collection took " + b.collectionMs + " ms: it is not bounded");
      return "exit 1 in " + wall + " ms wall; dom: " + b.dom.unavailable + "; screenshot: " +
        (typeof b.screenshot === "string" ? "captured" : b.screenshot.unavailable) + "; collection " + b.collectionMs + " ms";
    });

    // ---- 5. the way out --------------------------------------------------------------------------
    await run.check("5  RICHOS_UI_NAV_EVIDENCE=off removes the capture and leaves the failure exactly as it was", async () => {
      const dir = mk("off");
      const r = runFixture("stall-subresource", dir, { RICHOS_UI_NAV_EVIDENCE: "off" });
      assertRedWith(r, "page.goto: Timeout 1500ms exceeded.");
      assertEqual(fs.readdirSync(dir), [], "files written with the capture switched off");
      assert(!r.stderr.includes("navigation evidence"), "the capture spoke while switched off:\n" + r.stderr);
      return "exit 1, same FAIL line, 0 files, no evidence line";
    });

    // ---- 6. what it costs on a passing run ---------------------------------------------------------
    await run.check("6  the capture's cost on a passing load is measured, against the same page without it", async () => {
      // REPORTED, NOT GATED. Measured 2026-09-22 the median difference was under a millisecond
      // on a quiet machine and about two on a busy one, while the p95 difference swung from -40
      // to +128 ms between runs, so a threshold here would be a flake with a number on it. What this check does hold: the bench still runs, and its "observed"
      // side really goes through the capture — `measure` refuses a page without it.
      const browser = await loadPlaywright().webkit.launch();
      try {
        const m = await bench.measure(browser, 20);
        assertEqual([m.observed.n, m.raw.n], [20, 20], "loads measured on each side");
        return (
          "20 loads of index.html each way: median " + m.observed.medianMs + " ms with the capture, " +
          m.raw.medianMs + " ms without (difference " + m.deltaMedianMs + " ms; p95 difference " + m.deltaP95Ms + " ms)"
        );
      } finally {
        await browser.close();
      }
    });
  } finally {
    for (const d of dirs) fs.rmSync(d, { recursive: true, force: true });
  }

  process.exit(run.report() ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});

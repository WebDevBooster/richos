// THE UI GATES MUST BE ABLE TO FAIL — part-2 hunt (2026-09-29), sections 25, 26 and 42.
//
// Three places where the UI test machinery reported green over a defect it was built to catch:
//
//   25. a picture that differs from its committed reference printed one log line and the suite
//       passed, so screenshot comparison could not fail anything;
//   26. `run.js`'s coverage floor counted the harness-appended housekeeping check (the
//       tracked-tree guard) as one of the suite's own, so a suite could skip a declared check
//       and still meet `observed >= declared`;
//   42. `appearance.js` copied each page's error array into its aggregate once, right after the
//       page opened, so its "no page errors anywhere" check never saw an error raised later.
//
// The suite needs no browser: the picture comparison and the ledger are exercised through child
// suites (`fixtures/changed-shot-suite.js`) that run the real harness, and `run.js`'s floor
// through its real `--coverage` command over fabricated receipts. The reference picture is
// never rewritten by any of it, and the check that would notice is check 1.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { EventEmitter } = require("events");
const { createRun, assert, assertEqual } = require("./lib/harness");
const { collectPageErrors, createErrorTracker } = require("./lib/page-errors");
const SOURCES = require("./lib/ui-sources");

/// A page that is only what `collectPageErrors` touches: `on`, and something to emit from.
function fakePage() {
  return new EventEmitter();
}

async function main() {
  const run = createRun("the UI gates can fail — a changed picture, the coverage floor, page errors");
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "richos-gate-honesty-"));
  try {
    await run.check("5  page errors raised AFTER a page is tracked reach the suite-wide aggregate", async () => {
      const tracker = createErrorTracker();
      const page = tracker.track(fakePage());
      collectPageErrors(page);
      assertEqual(tracker.all(), [], "no errors yet");
      // An error from a later click or shortcut — after the page was tracked.
      page.emit("pageerror", new Error("boom during the walk"));
      page.emit("console", { type: () => "error", text: () => "late console error" });
      page.emit("console", { type: () => "log", text: () => "not an error" });
      const all = tracker.all();
      assertEqual(all.length, 2, "the two late errors (the log line is not one)");
      assert(all[0].includes("boom during the walk"), "the page error is missing: " + JSON.stringify(all));
      assertEqual(all[1], "console: late console error", "the console error");
      // And a second page tracked later adds to the same aggregate.
      const other = tracker.track(fakePage());
      collectPageErrors(other);
      other.emit("pageerror", new Error("second page"));
      assertEqual(tracker.all().length, 3, "errors across two pages");
      return "3 errors across 2 pages, all raised after tracking";
    });

    await run.check("6  appearance.js uses the tracker and no longer snapshots a page's errors", async () => {
      const src = SOURCES.stripJsComments(fs.readFileSync(path.join(__dirname, "appearance.js"), "utf8"), { strings: false });
      assert(/createErrorTracker\s*\(/.test(src), "appearance.js does not build its aggregate with createErrorTracker");
      assert(!/allErrors\.push\s*\(/.test(src), "appearance.js still copies a page's errors into an array at track time");
      assert(/tracker\.all|allErrors\s*\(\s*\)/.test(src), "check 18 does not read the live aggregate");
      return "createErrorTracker in use; no snapshot push";
    });
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }

  process.exit(run.report() ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});

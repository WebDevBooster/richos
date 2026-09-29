// A TEST NEVER WRITES INTO THE TREE IT IS VERIFYING — and when one does, the suite that did it
// is the one that goes red, by name, instead of the merge that happened to be running it.
//
// THE FAILURE THIS IS FOR, 2026-09-29. The merge gate verifies a candidate in the main
// checkout. `splash.js` photographed two screens that the candidate had legitimately changed,
// and `publishShot` wrote the new pictures over the committed references
// (`shots-splash/splash-03-the-off-switch.png` and `splash-04-a-launch-with-it-off.png`, both
// 30.5% of pixels different). The gate saw its own source change under it, refused the merge
// as "execution domain contaminated / source changed during verification", and canceled all
// of its checks — so every change that moved a committed picture was refused by its own tests.
// The nightly had been logging the same thing for `home.js` ("the UI suite modified its own
// checkout; restoring it") and quietly `git checkout`-ing it away.
//
// TWO LAYERS, because one is the fix and the other is what keeps the NEXT writer from doing it:
//
//   1. `publishShot` (lib/harness.js), the one place a PNG reaches a committed path, no longer
//      writes there unless the file is being regenerated on purpose (RICHOS_SHOTS_REGENERATE).
//      A changed picture goes to `.shots/changed/`, gitignored, and is announced.
//   2. THIS FILE. The harness snapshots the UI tree (`richos/app/ui`, see WHAT IT WATCHES
//      below) when a suite starts and compares it when the suite reports. Any tracked file
//      there whose content changed, any tracked file there that appeared in or left `git
//      status`, and any new untracked (not ignored) file under the tests directory is a FAILED
//      CHECK in that suite's own report, naming the files. So a future suite that calls
//      `fs.writeFileSync` on a tracked path of the UI tree — not through
//      `publishShot` at all — fails on its own branch, with its own name on it, long before a
//      merge gate is asked to verify it in the main checkout.
//
// WHAT IT DELIBERATELY DOES NOT DO: it does not restore anything. Restoring hides the writer,
// which is exactly how the nightly's restore let this class survive for weeks.
//
// THE ONE THING IT CANNOT TELL APART: another process editing the same files during the suite
// (a person saving a file, a second writer running beside it). The message says so. With no
// writer in the harness, the only way this fires is a real writer somewhere.
//
// WHAT IT WATCHES: THE UI TREE, `richos/app/ui`, NEVER THE WHOLE CHECKOUT (2026-09-29, part-2
// hunt section 07). It used to watch every tracked file in the repository, so saving an
// unrelated file anywhere (a Rust source, an engine script, a doc) during a land failed every
// UI suite that was running, by name, for a write none of them made. The UI tree is where
// everything a UI suite writes on purpose lives: its committed references
// (`tests/shots-*`, through `publishShot`), its weights file (`run.js`), its own sources. So
// a suite that writes a tracked file there is still red in its own report, which is the
// property this guard exists for; an edit outside it is not a UI suite's write and is not
// blamed on one. A suite that wrote a tracked file OUTSIDE the UI tree would not be named
// here any more; under `proof-run.py` it is still caught, because every check whose declared
// inputs hold that file (the writer's own whole-checkout identity included) is invalidated.
// `ui/tests` greps show no such writer today. An edit INSIDE the UI tree by another process
// still fails the suite: that file is one of the things the UI suites test.
//
// Cost, measured 2026-09-29 in a richos worktree of 9,127 tracked files: `git status
// --untracked-files=no` 0.026 s, `--untracked-files=all` 0.065 s. Two of them per suite.

"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const TESTS_DIR = path.resolve(__dirname, "..");
/// The tree a UI suite verifies and the only tree it writes on purpose (see the header).
const UI_DIR = path.resolve(TESTS_DIR, "..");

/// Where the checkout is. `RICHOS_UI_TRACKED_TREE_ROOT` is the seam `tracked-tree.js` uses to
/// point a child suite at a throwaway repository, so the guard can be proven red without
/// touching a real tracked file. Nothing else sets it.
function resolveRoot() {
  const forced = process.env.RICHOS_UI_TRACKED_TREE_ROOT;
  const cwd = forced ? path.resolve(forced) : TESTS_DIR;
  try {
    return execFileSync("git", ["rev-parse", "--path-format=absolute", "--show-toplevel"], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch (_e) {
    return null;
  }
}

/// `git status -z` entries as repo-relative paths. A rename carries its origin as the next
/// NUL-separated field; both halves are recorded.
function statusPaths(root, args) {
  // --no-optional-locks: never take index.lock to refresh the index. Several suites run this
  // at once in one checkout, beside git commands of their own.
  const out = execFileSync("git", ["--no-optional-locks", "status", "--porcelain=v1", "-z", ...args], {
    cwd: root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 64 * 1024 * 1024,
  });
  const fields = out.split("\0");
  const entries = [];
  for (let i = 0; i < fields.length; i++) {
    const f = fields[i];
    if (f.length < 4) continue;
    const code = f.slice(0, 2);
    entries.push({ code, file: f.slice(3) });
    if (code[0] === "R" || code[0] === "C") {
      const from = fields[++i];
      if (from) entries.push({ code, file: from });
    }
  }
  return entries;
}

function contentId(abs) {
  try {
    const st = fs.lstatSync(abs);
    if (st.isSymbolicLink()) return "link:" + fs.readlinkSync(abs);
    if (!st.isFile()) return "kind:" + (st.isDirectory() ? "dir" : "other");
    return "sha1:" + crypto.createHash("sha1").update(fs.readFileSync(abs)).digest("hex");
  } catch (_e) {
    return "absent";
  }
}

/// `dir` as a path relative to `root`, or "." when `dir` is not inside `root`.
function within(root, dir) {
  const rel = path.relative(root, dir);
  return rel && !rel.startsWith("..") && !path.isAbsolute(rel) ? rel : ".";
}

/// What is watched, repository-relative: `tracked` for changed tracked files, `untracked` for
/// new files git does not ignore. In a real checkout that is the UI tree and its tests
/// directory. Under the `RICHOS_UI_TRACKED_TREE_ROOT` seam (a throwaway repository) it is the
/// whole repository, or `RICHOS_UI_TRACKED_TREE_SCOPE` inside it, so the fixture can put an
/// edit on either side of the line. Nothing else sets either variable.
function scopeOf(root) {
  const forced = process.env.RICHOS_UI_TRACKED_TREE_ROOT ? process.env.RICHOS_UI_TRACKED_TREE_SCOPE : "";
  if (forced) {
    const rel = within(root, path.resolve(root, forced));
    return { tracked: rel, untracked: rel };
  }
  return { tracked: within(root, UI_DIR), untracked: within(root, TESTS_DIR) };
}

/// A picture of what `git status` says is not clean in the watched scope, with the CONTENT of
/// each such file, so a file that was already modified when the suite started is blamed only
/// if it changed again.
function snapshot(root) {
  const scope = scopeOf(root);
  const entries = [
    ...statusPaths(root, ["--untracked-files=no", "--", scope.tracked]),
    ...statusPaths(root, ["--untracked-files=all", "--", scope.untracked]).filter((e) => e.code === "??"),
  ];
  const map = new Map();
  for (const e of entries) map.set(e.file, e.code + " " + contentId(path.join(root, e.file)));
  return map;
}

/// Every path whose state differs between two snapshots.
function compare(before, after) {
  const changed = [];
  for (const [file, now] of after) {
    const was = before.get(file);
    if (was !== now) changed.push({ file, before: was || "clean", after: now });
  }
  for (const [file, was] of before) {
    if (!after.has(file)) changed.push({ file, before: was, after: "clean" });
  }
  return changed.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : 0));
}

/// Start watching. Returns `verify()`, which answers `{ checked, root, changed, why }`.
/// `exempt(absPath)` names files the caller is ALLOWED to change (a deliberate regeneration).
function watch(exempt) {
  const root = resolveRoot();
  if (!root) {
    return { verify: () => ({ checked: false, why: "not inside a git checkout, so there is no tracked tree to compare" }) };
  }
  let before;
  try {
    before = snapshot(root);
  } catch (e) {
    const why = "git status failed at suite start: " + ((e && e.message) || String(e)).split("\n")[0];
    return { verify: () => ({ checked: false, why }) };
  }
  return {
    verify() {
      let after;
      try {
        after = snapshot(root);
      } catch (e) {
        return { checked: false, why: "git status failed at report: " + ((e && e.message) || String(e)).split("\n")[0] };
      }
      const changed = compare(before, after).filter((c) => !(exempt && exempt(path.join(root, c.file))));
      return { checked: true, root, scope: scopeOf(root).tracked, changed };
    },
  };
}

module.exports = { watch, snapshot, compare, resolveRoot, scopeOf };

// Run every browser suite in this directory, in order, and fail loudly.
//
// Each suite is a plain node script that exits non-zero on any failure, so it is runnable on
// its own (`node workers.js`) when you are working on one thing.
//
// THE INVENTORY IS DISCOVERED FROM DISK, NEVER TYPED. This file used to carry a hand-written
// SUITES array, and slice 6 landed `steering.js` that the array did not name — so a passing
// `run.js` would have reported "all 4 suites passed" while silently running none of its 24
// checks. That is the same defect, in its fifth costume, that produced "13/13 guards" over a
// typed list, "18/18 suites" over one directory's glob, and an install.sh whose HOOK_FILES had
// drifted from the registration. Add a suite and it runs; there is no second place to update.
//
// Zero suites found is exit 2, not "all 0 suites passed" — an empty inventory reporting green
// is exactly how an unreachable CI workflow looked green for months.
//
// AND AN EXIT CODE IS NOT EVIDENCE. Discovery fixed which suites are STARTED. It says nothing
// about what they DID, and every failure this repository has had in this family exited 0
// honestly: a scanner that reported CLEAN over an empty corpus did run, and a suite that
// checks nothing passes perfectly. A CI runner reporting green over that is worse than no CI,
// because it converts "nobody checked" into "somebody checked and it was fine".
//
// So each suite now reports how many checks it ran, through the ledger in `lib/harness.js`,
// and this file gates on the numbers:
//
//   * a suite that produced NO ledger record at all did not check anything — FAIL, whatever
//     it exited;
//   * a suite that ran FEWER checks than its own source declares stopped early — FAIL. The
//     declared count is `run.check(` counted in the suite's own source, so BOTH sides are
//     read off disk and there is no number typed anywhere for someone to forget to update;
//   * a suite that SKIPPED is named and fails the run, unless it was explicitly allowed with
//     `--allow-skip=<file>` — which is a visible argument at the call site, not a silent
//     branch inside the suite;
//   * a suite that RECORDED FAILED CHECKS fails the run whatever it exited;
//   * zero total checks is a failure even if every suite exited 0.
//
// THAT THIRD CLAUSE IS NEW, AND A REAL RUN EARNED IT. On 2026-09-04 the first public
// `ui-suite-ci` run printed, in its own evidence table:
//
//     FAIL            home.js — 29 check(s) run, 28 declared, 2 failed (exit 0)
//
// ...and then reported "2 suite(s) FAILED: scale.js, splash.js". home.js is the one suite in
// this directory that calls `run.report()` and throws the number away, so its process exited
// 0 with two checks red — and this file gated on exit codes alone, so two failures on the
// CEO's own home screen were printed as FAIL and counted as fine. That is this file's entire
// thesis ("AND AN EXIT CODE IS NOT EVIDENCE") failing on the one path where the evidence and
// the exit code disagreed, and the ledger already held the number needed to catch it.
//
// The suite is fixed too — `home.js` exits on its own failures now, as the other twenty do —
// but a gate that depends on twenty-one authors each remembering one line is not a gate.
//
// The relation is `observed >= declared`, not `==`: several suites drive their checks from a
// loop (affordances.js declares 16 and runs 46). A scanner mistake can therefore only make
// this gate STRICTER — it cannot manufacture a green run.

"use strict";

const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

// ---------------------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------------------

const ALLOWED_SKIPS = new Set();
for (const arg of process.argv.slice(2)) {
  if (arg.startsWith("--allow-skip=")) {
    ALLOWED_SKIPS.add(arg.slice("--allow-skip=".length));
    continue;
  }
  // A mistyped flag must not be ignored. `--allow-skips=x` quietly doing nothing is the same
  // class of bug as everything else in this file's header.
  console.error("unknown argument: " + arg + "\nusage: node run.js [--allow-skip=<suite.js> ...]");
  process.exit(2);
}

// ---------------------------------------------------------------------------------------
// The inventory
// ---------------------------------------------------------------------------------------

// `lib/` holds shared harness code, not suites. Everything else ending in .js is a suite.
const SUITES = fs
  .readdirSync(__dirname)
  .filter((f) => f.endsWith(".js") && f !== "run.js")
  .filter((f) => fs.statSync(path.join(__dirname, f)).isFile())
  .sort();

if (SUITES.length === 0) {
  console.error("no browser suites discovered in " + __dirname + " — refusing to report green over an empty inventory");
  process.exit(2);
}

// ---------------------------------------------------------------------------------------
// How many checks a suite CLAIMS, read off its own source
// ---------------------------------------------------------------------------------------

/// Count `run.check(` outside comments, string literals and regex literals.
///
/// NOT reusing `lib/state-strings.js`'s scanner, deliberately: that one returns string
/// LITERALS with `+`-concatenation folded, which is a different job, and bending it to also
/// emit code positions would put two callers on a parser written for one. It IS the source of
/// the regex rule below — the prev-significant-token heuristic is documented there and this
/// applies it rather than inventing a second one.
///
/// THE REGEX CASE IS NOT OPTIONAL, which the first version of this function assumed it was.
/// Skipping only comments and strings, it read `docs-claims.js` as declaring 2 checks where
/// the file declares 6: `/^\|\s*`([a-z0-9-]+\.js)`\s*\|/gm` contains a backtick, which opened
/// a template literal that swallowed the next four calls. An under-count does not manufacture
/// a green run — `observed >= declared` still holds — but it lowers the floor to a height
/// nothing trips over, which is the same as not having one. A suite that quietly stopped
/// after its third check would have passed.
function declaredChecks(src) {
  let out = "";
  let i = 0;
  const n = src.length;
  // The last significant character, used only to decide whether a slash opens a regex (after
  // an operator, keyword, `(` or `,`) or is a division (after a value).
  let prevSig = "";
  while (i < n) {
    const c = src[i];

    if (c === "/" && src[i + 1] === "/") {
      while (i < n && src[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && src[i + 1] === "*") {
      i += 2;
      while (i < n && !(src[i] === "*" && src[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    if (c === "/" && !/[A-Za-z0-9_$)\]]/.test(prevSig)) {
      i++;
      let inClass = false;
      while (i < n) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === "[") inClass = true;
        else if (src[i] === "]") inClass = false;
        else if (src[i] === "/" && !inClass) { i++; break; }
        else if (src[i] === "\n") break;
        i++;
      }
      while (i < n && /[a-z]/.test(src[i])) i++;
      prevSig = "/";
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const quote = c;
      i++;
      while (i < n) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === quote) { i++; break; }
        i++;
      }
      prevSig = quote;
      continue;
    }

    out += c;
    if (!/\s/.test(c)) prevSig = c;
    i++;
  }
  return (out.match(/\brun\.check\s*\(/g) || []).length;
}

// The self-test. Four things a naive `grep -c` gets wrong, asserted on every run rather than
// trusted: a live call counts, a commented-out one does not, a block comment does not close
// the file, and the string forms are not calls.
(function selfTestTheScanner() {
  const fixture = [
    'await run.check("one", async () => {});',
    '// await run.check("a commented-out check", async () => {});',
    '/* run.check( inside a block comment */ await run.check("two", async () => {});',
    'const s = "run.check(";',
    "const t = `run.check(`;",
    // The regression that made this self-test worth having: a regex carrying a quote or a
    // backtick used to open a string literal here and swallow every call after it.
    "const r = /[\"'`]/g;",
    'await run.check("three", async () => {});',
    // ...and its other half, a division that must not be read as a regex opening.
    "const d = (a) / 2; const e = b / c;",
    'await run.check("four", async () => {});',
  ].join("\n");
  const got = declaredChecks(fixture);
  if (got !== 4) {
    console.error(`the declared-check scanner is broken: expected 4 on its own fixture, got ${got}`);
    process.exit(2);
  }
})();

const DECLARED = new Map();
for (const suite of SUITES) {
  DECLARED.set(suite, declaredChecks(fs.readFileSync(path.join(__dirname, suite), "utf8")));
}

// ---------------------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------------------

const ledgerDir = fs.mkdtempSync(path.join(os.tmpdir(), "richos-ui-evidence-"));
const ledgerFile = path.join(ledgerDir, "evidence.jsonl");
fs.writeFileSync(ledgerFile, "");

console.log(`${SUITES.length} suite(s) discovered: ${SUITES.join(", ")}\n`);

const exited = new Map();
for (const suite of SUITES) {
  const r = spawnSync(process.execPath, [path.join(__dirname, suite)], {
    stdio: "inherit",
    env: Object.assign({}, process.env, { RICHOS_UI_TESTS_LEDGER: ledgerFile }),
  });
  exited.set(suite, r.status === null ? 1 : r.status);
}

// ---------------------------------------------------------------------------------------
// The evidence gate
// ---------------------------------------------------------------------------------------

const records = fs
  .readFileSync(ledgerFile, "utf8")
  .split("\n")
  .filter((l) => l.trim())
  .map((l) => JSON.parse(l));
fs.rmSync(ledgerDir, { recursive: true, force: true });

const bySuite = new Map(SUITES.map((s) => [s, []]));
for (const rec of records) {
  if (!bySuite.has(rec.suite)) bySuite.set(rec.suite, []);
  bySuite.get(rec.suite).push(rec);
}

const problems = [];
const notes = [];
let ran = 0;
let skipped = 0;
let observedTotal = 0;
let declaredTotal = 0;

console.log("\n== evidence ==");
for (const suite of SUITES) {
  const recs = bySuite.get(suite) || [];
  const skips = recs.filter((r) => typeof r.skipped === "string");
  const runs = recs.filter((r) => typeof r.checks === "number");
  const declared = DECLARED.get(suite);
  const observed = runs.reduce((a, r) => a + r.checks, 0);
  const failedChecks = runs.reduce((a, r) => a + r.failed, 0);
  const status = exited.get(suite);

  if (declared === 0) {
    problems.push(`${suite}: its source declares no \`run.check(\` at all — a suite that cannot fail`);
  }

  if (skips.length && !runs.length) {
    skipped++;
    if (ALLOWED_SKIPS.has(suite)) {
      console.log(`  SKIP (allowed)  ${suite} — ${skips[0].skipped.split("\n")[0]}`);
    } else {
      console.log(`  SKIP            ${suite} — ${skips[0].skipped.split("\n")[0]}`);
      problems.push(
        `${suite}: did not run and was not allowed to skip. Pass --allow-skip=${suite} at the ` +
          `call site if that is deliberate, so the gap is visible where the run is started.`
      );
    }
    continue;
  }

  if (!runs.length) {
    problems.push(
      `${suite}: produced NO evidence — it exited ${status} without reporting a single check. ` +
        `Its source declares ${declared}.`
    );
    console.log(`  NO EVIDENCE     ${suite} (exit ${status}, ${declared} declared)`);
    continue;
  }

  ran++;
  observedTotal += observed;
  declaredTotal += declared;
  if (observed < declared) {
    problems.push(
      `${suite}: ran ${observed} check(s) but its source declares ${declared} — it stopped early ` +
        `or a check was never reached.`
    );
  }
  if (ALLOWED_SKIPS.has(suite)) {
    // Not a failure. An allowance is permission to skip, not an instruction to — and whether
    // realbytes.js can run depends on whether the machine has cargo, which is a fact about
    // the machine. Turning a coverage GAIN red would be its own kind of wrong answer.
    notes.push(`--allow-skip=${suite} was passed and was not needed: ${suite} ran here.`);
  }
  // SHORT, not ok: the suite's own checks all passed and it exited 0, and it still did less
  // than it says it does. That is the case worth a word of its own — it is the one that reads
  // as green everywhere else.
  const verdict = failedChecks || status !== 0 ? "FAIL " : observed < declared ? "SHORT" : "ok   ";
  console.log(`  ${verdict}           ${suite} — ${observed} check(s) run, ${declared} declared, ${failedChecks} failed (exit ${status})`);
}

// FAILED BY EITHER WITNESS. The exit code is one; the ledger is the other, and where they
// disagree the ledger is the one that saw a check go red.
const failedSuites = SUITES.filter((s) => {
  const recs = (bySuite.get(s) || []).filter((r) => typeof r.checks === "number");
  return exited.get(s) !== 0 || recs.reduce((a, r) => a + r.failed, 0) > 0;
});
for (const s of failedSuites) {
  if (exited.get(s) === 0) {
    problems.push(
      `${s}: reported failed check(s) and still exited 0 — its own failures did not reach its ` +
        `exit code. The run is failed on the LEDGER; fix the suite to exit on \`run.report()\`.`
    );
  }
}

if (observedTotal === 0) {
  problems.push("zero checks were run across the whole tree — refusing to report green over nothing");
}

console.log(
  `\n  ${SUITES.length} discovered, ${ran} ran, ${skipped} skipped, ` +
    `${observedTotal} checks observed against ${declaredTotal} declared`
);

for (const n of notes) console.log("  NOTE  " + n);

if (problems.length) {
  console.log("\n== the evidence gate REFUSES this run ==");
  for (const p of problems) console.log("  ✗ " + p);
}

if (failedSuites.length) {
  console.log(`\n${failedSuites.length} suite(s) FAILED: ${failedSuites.join(", ")}`);
}

if (failedSuites.length || problems.length) {
  process.exit(1);
}

const skipTail = skipped ? `, ${skipped} skipped with leave (${[...ALLOWED_SKIPS].join(", ")})` : ", none skipped";
console.log(`\nall ${ran} suites passed — ${observedTotal} checks over ${ran} suites${skipTail}`);
process.exit(0);

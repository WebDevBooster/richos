#!/usr/bin/env node
/**
 * Mutation audit for the model-integrity layer.
 *
 *   node test/mutation-audit.mjs            # run every mutation, report coverage
 *   node test/mutation-audit.mjs --list     # just print what would be tried
 *
 * WHY THIS EXISTS. A green suite proves the tests ran, not that they can fail. This project has
 * already been bitten by that: eight silent mutations across three branches meant a check was not
 * running at all, and nobody could tell from the output. So each check here has been WATCHED to go
 * red against deliberately broken shipped source, and this script is how that claim stays true
 * instead of becoming a sentence in an old commit message.
 *
 * HOW IT WORKS. For each mutation: apply one exact string replacement to a source file, run
 * `test/run.js`, record which test names printed FAIL, then `git checkout` the tree back. It
 * refuses to run against a dirty tree, because restoring by checkout would throw away real work.
 *
 * WHAT IT REPORTS, and every one of these is a finding rather than noise:
 *   NEVER SEEN RED   a check that no mutation could break. Either the mutation set is too weak or
 *                    the check cannot fail — the second is the dangerous one and it has happened
 *                    here twice (a false claim about the search path, and an assertion racing the
 *                    thing it was watching).
 *   SURVIVED         a mutation nothing caught: a real behaviour with no test behind it.
 *   DID NOT APPLY    the source moved and the mutation's `from` string no longer exists. Reported
 *                    LOUDLY and never skipped quietly, because a mutation that silently stops
 *                    applying turns this whole script into theatre.
 *
 * MAINTENANCE, SAID PLAINLY. `mutations.json` is pinned to exact source text, so refactoring the
 * modules it names WILL break entries here. That is the intended cost: an entry that stops
 * applying is a prompt to re-aim it at the new code, not a reason to delete it.
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';

const HERE = import.meta.dirname;
const ROOT = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: HERE, encoding: 'utf8' }).trim();
const SVC = path.join(ROOT, 'tools', 'richos-service');
const MUTATIONS = JSON.parse(fs.readFileSync(path.join(HERE, 'mutations.json'), 'utf8'));

/** The checks this audit is accountable for: everything in the two model-integrity groups. */
const GROUP_MARKERS = [
  "group('model integrity",
  "group('model fetch",
  "group('model resolution",
];

/** Test names declared inside the groups above, read from the suite so the two cannot drift. */
function checksUnderAudit() {
  const src = fs.readFileSync(path.join(HERE, 'run.js'), 'utf8').split('\n');
  const names = [];
  let inside = false;
  for (const line of src) {
    if (line.startsWith('group(')) inside = GROUP_MARKERS.some((m) => line.startsWith(m));
    const m = /^test(?:Async)?\('((?:[^'\\]|\\.)*)'/.exec(line);
    if (inside && m) names.push(m[1].replace(/\\'/g, "'"));
  }
  return names;
}

function runSuite() {
  const r = spawnSync(process.execPath, ['test/run.js'], { cwd: SVC, encoding: 'utf8' });
  const fails = (r.stdout || '')
    .split('\n')
    .filter((l) => l.startsWith('FAIL  '))
    .map((l) => l.slice(6));
  return { fails, crashed: r.status !== 0 && fails.length === 0, stderr: (r.stderr || '').slice(-400) };
}

function restore() {
  execFileSync('git', ['checkout', '--', 'tools/'], { cwd: ROOT });
}

const checks = checksUnderAudit();
if (process.argv.includes('--list')) {
  console.log(`${MUTATIONS.length} mutations over ${checks.length} checks`);
  for (const m of MUTATIONS) console.log(`  ${m.label}`);
  process.exit(0);
}

const dirty = execFileSync('git', ['status', '--porcelain', '--', 'tools/'], { cwd: ROOT, encoding: 'utf8' }).trim();
if (dirty) {
  console.error('REFUSING TO RUN: tools/ has uncommitted changes, and this script restores by\n' +
    'git checkout. Commit first, mutate second — that ordering is the whole safety of it.\n' + dirty);
  process.exit(2);
}

const killedBy = new Map();
const survived = [];
const notApplied = [];
const crashed = [];

for (const m of MUTATIONS) {
  const file = path.join(ROOT, m.file);
  const before = fs.readFileSync(file, 'utf8');
  if (!before.includes(m.from)) {
    notApplied.push(m.label);
    continue;
  }
  fs.writeFileSync(file, before.replace(m.from, m.to));
  const { fails, crashed: blew, stderr } = runSuite();
  restore();
  if (blew) {
    crashed.push(`${m.label} :: ${stderr.trim().split('\n').pop()}`);
    continue;
  }
  if (fails.length === 0) {
    survived.push(m.label);
    continue;
  }
  for (const f of fails) {
    if (!killedBy.has(f)) killedBy.set(f, m.label);
  }
  console.log(`${String(fails.length).padStart(2)} red  ${m.label}`);
}

console.log(`\n=== ${checks.length} checks under audit ===`);
const unseen = [];
for (const c of checks) {
  if (killedBy.has(c)) console.log(`  RED  ${c}\n         first broken by: ${killedBy.get(c)}`);
  else {
    unseen.push(c);
    console.log(`  !!!! ${c}`);
  }
}
console.log(`\n${checks.length - unseen.length}/${checks.length} observed RED`);

const problems = [
  ...unseen.map((c) => `NEVER SEEN RED — no mutation could break it: ${c}`),
  ...survived.map((l) => `SURVIVED — nothing caught it: ${l}`),
  ...notApplied.map((l) => `DID NOT APPLY — the source moved, re-aim it: ${l}`),
  ...crashed.map((l) => `CRASHED THE SUITE — no per-test verdict: ${l}`),
];
if (problems.length) {
  console.log('');
  for (const p of problems) console.log(`  - ${p}`);
}
process.exit(problems.length ? 1 : 0);

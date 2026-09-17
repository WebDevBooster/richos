#!/usr/bin/env node
/**
 * The one-time evidence-zone migration — proven on a COPY of a corpus shaped like the real one.
 *
 *   node test/migrate-evidence-zone.js
 *
 * Test names document the invariant. Every negative assertion carries a positive control, because a
 * "nothing leaked / nothing was touched" check over an empty corpus passes for the wrong reason.
 *
 * The migration is never run against the CEO's real `~/RichOS` from here: every case builds its own
 * corpus in a temp directory and points the migration at it explicitly.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { migrateEvidenceZone, formatMigrationReport, OLD_REL, NEW_REL } from '../lib/workspace/migrate-evidence-zone.js';
import { loadCorpus } from '../../../engine/loro/lib/store.js';

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ok  ${name}`);
  } catch (err) {
    failed += 1;
    console.log(`  FAIL  ${name}`);
    console.log(`        ${String((err && err.message) || err).split('\n').join('\n        ')}`);
  }
}

/** A corpus laid out the way one written before 2026-09-17 is. */
function legacyCorpus() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'migrate-evidence-'));
  const w = (rel, body) => {
    const p = path.join(dir, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, body);
  };
  const itemDir = `${OLD_REL}/workspace/google/calendar/evt_pricing--abc/rev-def`;

  // The evidence zone, inside the compiled `ceo/unfiled` record directory.
  w(`${itemDir}/item.json`, JSON.stringify({
    id: 'evt_pricing',
    content: { title: 'Coach pricing ladder review', textFile: 'content.txt' },
  }, null, 2));
  // A body that MENTIONS the old path — immutable evidence, must survive byte-identical.
  w(`${itemDir}/content.txt`, `Notes pasted from ${OLD_REL}/workspace/google/calendar/old-note.txt\nPick a floor.\n`);
  w(`${itemDir}/governance.json`, JSON.stringify({
    scope: 'org-shared',
    evidenceLink: `${itemDir}/item.json`,
    trust: { quarantine: false },
  }, null, 2));
  w(`${OLD_REL}/workspace/_workspace_ingest.jsonl`,
    `${JSON.stringify({ evidenceLink: `${itemDir}/item.json`, at: '2026-09-16T00:00:00.000Z' })}\n`);
  // A transcript at the artifact name pipeline.js writes — this is the file that would compile.
  w(`${OLD_REL}/meetings/sess-1/transcript.md`, '# Raw call note\n\n## Transcript\n\nEvidence, not memory.\n');

  // A promoted record, in the record partition, carrying the embedded link.
  w('ceo/unfiled/ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c.md',
    ['---', 'kind: event', 'scope: org-shared', '---', '',
      '# Coach pricing ladder review', '',
      'Calendar entry for Tuesday, September 15, 2026.',
      `Evidence: ${itemDir}/item.json`,
      `Notes: the operator filed this under ${OLD_REL}/ by hand last year.`, ''].join('\n'));
  // A page that merely TALKS about the old path in prose — must not be rewritten.
  w('ceo/pages/worldview.md',
    ['# How I work', '', '## Where evidence went', '',
      `Before the move, evidence lived at ${OLD_REL}/ and that turned out to be inside compiled memory.`, ''].join('\n'));

  return dir;
}

function listing(dir) {
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else out.push(path.relative(dir, p));
    }
  };
  walk(dir);
  return out.sort();
}

function withCorpus(fn) {
  const dir = legacyCorpus();
  try {
    return fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// -------------------------------------------------------------------------------------------------

test('POSITIVE CONTROL: ceo/unfiled really is walked recursively — a nested .md there compiles', () => {
  withCorpus((dir) => {
    // `neverWalk()` is what stops the evidence subtree now, so this control puts the same file at a
    // sibling path that is NOT named `evidence` — the same structural position with that one barrier
    // removed — to show the directory really is inside a recursively-walked record directory.
    const probe = path.join(dir, 'ceo', 'unfiled', 'probe', 'sess-1');
    fs.mkdirSync(probe, { recursive: true });
    fs.copyFileSync(path.join(dir, OLD_REL, 'meetings', 'sess-1', 'transcript.md'), path.join(probe, 'transcript.md'));
    const corpus = loadCorpus({ root: dir, layout: 'corpus', now: '2026-09-17T09:00:00.000Z' });
    const found = corpus.records.filter((r) => (r.provenance.path || '').startsWith('ceo/unfiled/probe/'));
    assert.ok(found.length > 0, 'ceo/unfiled is walked recursively — this control must find the probe file');
  });
});

test('dry run reports the move and every embedded link, and changes NOTHING on disk', () => {
  withCorpus((dir) => {
    const before = listing(dir);
    const result = migrateEvidenceZone({ corpus: dir, dryRun: true });
    assert.equal(result.refusal, null);
    assert.equal(result.moved, false);
    assert.equal(result.filesMoved, 5, 'item.json, content.txt, governance.json, the ledger, the transcript');
    const files = result.linksRewritten.map((r) => r.file).sort();
    assert.deepEqual(files, [
      'ceo/unfiled/evidence/workspace/_workspace_ingest.jsonl',
      'ceo/unfiled/evidence/workspace/google/calendar/evt_pricing--abc/rev-def/governance.json',
      'ceo/unfiled/ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c.md',
    ]);
    assert.deepEqual(listing(dir), before, 'a dry run must not move or write a single file');
    assert.match(formatMigrationReport(result), /dry run — nothing was changed/);
  });
});

test('apply moves the zone to ceo/evidence/unfiled and leaves the record partition in place', () => {
  withCorpus((dir) => {
    const result = migrateEvidenceZone({ corpus: dir, dryRun: false });
    assert.equal(result.moved, true);
    assert.equal(fs.existsSync(path.join(dir, OLD_REL)), false, 'the old zone is gone');
    assert.ok(fs.existsSync(path.join(dir, NEW_REL, 'meetings', 'sess-1', 'transcript.md')));
    assert.ok(fs.existsSync(path.join(dir, NEW_REL, 'workspace', 'google', 'calendar', 'evt_pricing--abc', 'rev-def', 'item.json')));
    // POSITIVE CONTROL: the record partition itself is NOT collateral — its promoted record survives.
    assert.ok(fs.existsSync(path.join(dir, 'ceo', 'unfiled', 'ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c.md')));
  });
});

test('apply rewrites the Evidence: line in a promoted record — and nothing else in that file', () => {
  withCorpus((dir) => {
    const rel = 'ceo/unfiled/ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c.md';
    const before = fs.readFileSync(path.join(dir, rel), 'utf8');
    migrateEvidenceZone({ corpus: dir, dryRun: false });
    const after = fs.readFileSync(path.join(dir, rel), 'utf8');
    assert.match(after, new RegExp(`^Evidence: ${NEW_REL}/workspace/google/calendar/`, 'm'));
    assert.doesNotMatch(after, new RegExp(`^Evidence: ${OLD_REL}/`, 'm'));
    // The `Notes:` line names the old path in prose and is NOT an evidence link. Untouched.
    assert.match(after, new RegExp(`^Notes: the operator filed this under ${OLD_REL}/ by hand last year\\.$`, 'm'));
    // POSITIVE CONTROL: the file really did change, so "untouched" is a claim about one line only.
    assert.notEqual(after, before);
  });
});

test('apply rewrites governance.json and the ledger, and NEVER item.json or content.txt', () => {
  withCorpus((dir) => {
    const itemRel = 'workspace/google/calendar/evt_pricing--abc/rev-def';
    const contentBefore = fs.readFileSync(path.join(dir, OLD_REL, itemRel, 'content.txt'), 'utf8');
    const itemBefore = fs.readFileSync(path.join(dir, OLD_REL, itemRel, 'item.json'), 'utf8');
    migrateEvidenceZone({ corpus: dir, dryRun: false });

    const gov = JSON.parse(fs.readFileSync(path.join(dir, NEW_REL, itemRel, 'governance.json'), 'utf8'));
    assert.ok(gov.evidenceLink.startsWith(`${NEW_REL}/`), `evidenceLink is ${gov.evidenceLink}`);
    const ledger = fs.readFileSync(path.join(dir, NEW_REL, 'workspace', '_workspace_ingest.jsonl'), 'utf8');
    assert.ok(JSON.parse(ledger.trim()).evidenceLink.startsWith(`${NEW_REL}/`));

    // Evidence is IMMUTABLE. content.txt mentions the old path in its body and must survive byte
    // for byte — a migration that "helpfully" fixed it would be editing the CEO's raw material.
    assert.equal(fs.readFileSync(path.join(dir, NEW_REL, itemRel, 'content.txt'), 'utf8'), contentBefore);
    assert.equal(fs.readFileSync(path.join(dir, NEW_REL, itemRel, 'item.json'), 'utf8'), itemBefore);
    // POSITIVE CONTROL: that content.txt really does contain the string being left alone.
    assert.ok(contentBefore.includes(`${OLD_REL}/`));
  });
});

test('after migrating, NOTHING under the evidence zone compiles — and the page beside it still does', () => {
  withCorpus((dir) => {
    migrateEvidenceZone({ corpus: dir, dryRun: false });
    const corpus = loadCorpus({ root: dir, layout: 'corpus', now: '2026-09-17T09:00:00.000Z' });
    const paths = corpus.records.map((r) => r.provenance.path || '');
    assert.deepEqual(paths.filter((p) => p.includes('/evidence/') || p.startsWith('ceo/evidence/')), []);
    // POSITIVE CONTROL: the corpus is not empty, and the promoted record DID compile — the absence
    // above is the boundary working, not the loader failing.
    assert.ok(paths.some((p) => p.startsWith('ceo/unfiled/ws-google-calendar-')), `compiled: ${paths.join(', ')}`);
    assert.ok(paths.some((p) => p === 'ceo/pages/worldview.md'), `compiled: ${paths.join(', ')}`);
  });
});

test('a corpus with BOTH zones is REFUSED, not merged — and nothing is changed', () => {
  withCorpus((dir) => {
    fs.mkdirSync(path.join(dir, NEW_REL, 'workspace'), { recursive: true });
    fs.writeFileSync(path.join(dir, NEW_REL, 'workspace', 'stray.json'), '{}');
    const before = listing(dir);
    const result = migrateEvidenceZone({ corpus: dir, dryRun: false });
    assert.match(result.refusal || '', /Merging two evidence zones is a decision/);
    assert.deepEqual(listing(dir), before);
  });
});

test('a corpus already migrated reports nothing to do and is idempotent', () => {
  withCorpus((dir) => {
    migrateEvidenceZone({ corpus: dir, dryRun: false });
    const after1 = listing(dir);
    const second = migrateEvidenceZone({ corpus: dir, dryRun: false });
    assert.equal(second.refusal, null);
    assert.equal(second.nothingToDo, true);
    assert.deepEqual(second.linksRewritten, []);
    assert.deepEqual(listing(dir), after1, 'a second run must be a no-op');
  });
});

test('a corpus that never had an unfiled evidence zone is a clean no-op', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'migrate-empty-'));
  try {
    fs.mkdirSync(path.join(dir, 'ceo', 'records'), { recursive: true });
    const result = migrateEvidenceZone({ corpus: dir, dryRun: false });
    assert.equal(result.refusal, null);
    assert.equal(result.nothingToDo, true);
    assert.equal(result.moved, false);
    assert.match(formatMigrationReport(result), /already migrated, or never written/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

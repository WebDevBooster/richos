#!/usr/bin/env node
/**
 * The evidence lookup — every wall in §1 and §4 of the 2026-09-17 ruling, asserted.
 *
 *   node test/evidence-lookup.js
 *
 * Test names document the invariant. Every negative assertion carries a POSITIVE CONTROL, because
 * "the quarantined item did not appear" passes for the wrong reason if the lookup returned nothing
 * at all — which is exactly what a typo in a fixture produces.
 *
 * No network, no real corpus: the zone is injected as literal objects shaped like what
 * `readEvidenceZone` returns.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  lookupEvidenceForSlice, findEvidence, shouldConsultEvidence, renderEvidenceBlock,
  EVIDENCE_HEADING, EXCERPT_BEGIN, EXCERPT_END, LOOKUP_LIMITS, LOOKUP_AUDIENCE,
} from '../lib/workspace/evidence-lookup.js';
import { assertNoSideEffects } from '../../../engine/loro/lib/privacy.js';

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

const LONG_BODY = [
  'The coach pricing model has three rungs. The first rung is a solo coach at ninety dollars a month,',
  'which is the floor and is deliberately not discountable. The second rung is a studio seat priced per',
  'coach with a three-seat minimum. The third rung is the multi-location tier, which is quoted rather',
  'than listed because every one of them has been different so far.',
].join(' ') + ' ' + 'Padding sentence about the pricing ladder and the coach seat floor. '.repeat(20);

function driveDoc(over = {}) {
  return {
    item: {
      sourceItemId: 'google:drive:doc_pricing',
      vendor: 'google',
      source: 'drive',
      kind: 'document',
      provenance: { fetchedAt: Date.parse('2026-09-15T10:00:00Z'), vendorUrl: 'https://docs.google.com/document/d/doc_pricing/edit' },
      actors: { author: { name: 'Alex Booster', email: 'alex@acme.example', orgRelation: 'self' }, attendees: [], recipients: [] },
      temporal: { occurredAt: Date.parse('2026-09-15T10:00:00Z') },
      content: { title: 'Coach pricing model', text: LONG_BODY, structured: {}, attachmentsRefs: [] },
      trust: { class: 'unverified', quarantine: false, flags: [] },
      ...over.item,
    },
    governance: { scope: 'org-shared', trust: { quarantine: false, class: 'unverified', flags: [] }, evidenceLink: 'ceo/evidence/unfiled/workspace/google/drive/doc_pricing--a/rev-b/item.json', ...over.governance },
    dir: '/zone/google/drive/doc_pricing--a/rev-b',
    evidenceLink: 'ceo/evidence/unfiled/workspace/google/drive/doc_pricing--a/rev-b/item.json',
  };
}

function mailItem(over = {}) {
  return {
    item: {
      sourceItemId: 'google:mail:msg_pricing',
      vendor: 'google',
      source: 'mail',
      kind: 'email',
      provenance: { fetchedAt: Date.parse('2026-09-16T08:00:00Z'), vendorUrl: 'https://mail.google.com/mail/u/0/#inbox/msg_pricing' },
      actors: {
        author: { name: 'Dana Reyes', email: 'dana@northwind.example', orgRelation: 'external' },
        attendees: [], recipients: [{ name: 'Alex Booster', email: 'alex@acme.example', orgRelation: 'self' }],
      },
      temporal: { occurredAt: Date.parse('2026-09-16T08:00:00Z') },
      // A metadata-only item HAS no body. If one ever appeared it must still not be rendered.
      content: { title: 'Coach pricing ladder — a question', text: 'A BODY THAT MUST NEVER BE RENDERED for coach pricing.', structured: {}, attachmentsRefs: [] },
      trust: { class: 'untrusted', quarantine: false, flags: [] },
      ...over.item,
    },
    governance: { scope: 'org-shared', trust: { quarantine: false }, evidenceLink: 'ceo/evidence/unfiled/workspace/google/mail/msg_pricing--a/rev-b/item.json', ...over.governance },
    dir: '/zone/google/mail/msg_pricing--a/rev-b',
    evidenceLink: 'ceo/evidence/unfiled/workspace/google/mail/msg_pricing--a/rev-b/item.json',
  };
}

function zoneOf(entries) {
  return () => entries;
}

const COVERED = { coverage: 'covered' };
const NONE = { coverage: 'none' };
const ADJACENT = { coverage: 'adjacent' };

// -------------------------------------------------------------------------------------------------
// The gate

test('the lookup runs ONLY when the compiled slice says memory did not cover the question', () => {
  assert.equal(shouldConsultEvidence(NONE), true);
  assert.equal(shouldConsultEvidence(ADJACENT), true);
  assert.equal(shouldConsultEvidence(COVERED), false);
  assert.equal(shouldConsultEvidence({}), false, 'a missing coverage label is not a reason to look');
  assert.equal(shouldConsultEvidence(null), false);
});

test('a covered slice returns unavailable with a reason, and never a heading with an empty body', () => {
  const out = lookupEvidenceForSlice({ slice: COVERED, topic: 'coach pricing model', readZone: zoneOf([driveDoc()]) });
  assert.equal(out.available, false);
  assert.equal(out.reason, 'covered');
  assert.equal(out.text, '');
  // POSITIVE CONTROL: the same query on an uncovered slice DOES return the document.
  const found = lookupEvidenceForSlice({ slice: NONE, topic: 'coach pricing model', readZone: zoneOf([driveDoc()]) });
  assert.equal(found.available, true);
});

// -------------------------------------------------------------------------------------------------
// The walls

test('v1 serves the CEO only — a worker or org audience gets nothing and the zone is never ranked', () => {
  for (const audience of ['worker', 'org']) {
    const out = lookupEvidenceForSlice({ slice: NONE, topic: 'coach pricing model', audience, readZone: zoneOf([driveDoc()]) });
    assert.equal(out.available, false, `audience ${audience}`);
    assert.equal(out.reason, 'audience');
    assert.equal(out.items.length, 0);
  }
  // POSITIVE CONTROL: the same fixture and query DOES return for `rich`.
  const rich = lookupEvidenceForSlice({ slice: NONE, topic: 'coach pricing model', audience: LOOKUP_AUDIENCE, readZone: zoneOf([driveDoc()]) });
  assert.equal(rich.available, true);
});

test('an UNKNOWN audience throws rather than widening — assertAudience posture, carried over', () => {
  assert.throws(
    () => lookupEvidenceForSlice({ slice: NONE, topic: 'x', audience: 'everyone', readZone: zoneOf([]) }),
    /unknown audience/,
  );
});

test('a QUARANTINED item is excluded on the STORED flag — no detector is re-run at read time', () => {
  const poisoned = driveDoc({ governance: { scope: 'org-shared', trust: { quarantine: true } } });
  const out = findEvidence({ topic: 'coach pricing model', readZone: zoneOf([poisoned]) });
  assert.deepEqual(out.items, []);
  assert.equal(out.considered, 0, 'a quarantined item is not even a candidate, so it cannot raise the floor');
  // POSITIVE CONTROL: the identical item with the flag cleared IS returned, so the exclusion is the
  // flag and not the fixture.
  const clean = findEvidence({ topic: 'coach pricing model', readZone: zoneOf([driveDoc()]) });
  assert.equal(clean.items.length, 1);
});

test('an item with NO stored quarantine flag is treated as quarantined, not as clean', () => {
  const unknown = driveDoc({ item: { trust: undefined }, governance: { scope: 'org-shared' } });
  delete unknown.item.trust;
  delete unknown.governance.trust;
  assert.deepEqual(findEvidence({ topic: 'coach pricing model', readZone: zoneOf([unknown]) }).items, []);
});

test('scope is honored through scopeAllowed against the STORED scope, not re-derived at read time', () => {
  // `rich` may receive ceo-private, org-shared and external. An unknown scope may not.
  for (const scope of ['ceo-private', 'org-shared', 'external']) {
    const out = findEvidence({ topic: 'coach pricing model', readZone: zoneOf([driveDoc({ governance: { scope, trust: { quarantine: false } } })]) });
    assert.equal(out.items.length, 1, `scope ${scope} must reach the CEO`);
    assert.equal(out.items[0].scope, scope);
  }
  for (const scope of ['unknown', 'MISSING', 'invented']) {
    const entry = driveDoc();
    entry.governance = { trust: { quarantine: false } };
    if (scope !== 'MISSING') entry.governance.scope = scope;
    const out = findEvidence({ topic: 'coach pricing model', readZone: zoneOf([entry]) });
    assert.deepEqual(out.items, [], `scope ${scope} must be refused rather than guessed wide`);
  }
});

// -------------------------------------------------------------------------------------------------
// The caps

test('at most 3 items, however many match', () => {
  const many = Array.from({ length: 9 }, (_, i) => {
    const d = driveDoc();
    d.item.sourceItemId = `google:drive:doc_${i}`;
    d.item.content.title = `Coach pricing model, revision ${i}`;
    return d;
  });
  const out = findEvidence({ topic: 'coach pricing model', readZone: zoneOf(many) });
  assert.equal(out.items.length, LOOKUP_LIMITS.MAX_ITEMS);
  assert.equal(out.considered, 9, 'all nine were candidates — the cap is what held, not the walls');
});

test('a Drive excerpt is capped at 600 characters and says so', () => {
  const out = findEvidence({ topic: 'coach pricing model', readZone: zoneOf([driveDoc()]) });
  const it = out.items[0];
  assert.ok(it.excerpt, 'a Drive document carries an excerpt');
  assert.ok(it.excerpt.length <= LOOKUP_LIMITS.MAX_EXCERPT_CHARS, `excerpt is ${it.excerpt.length} chars`);
  assert.equal(it.excerptTruncated, true);
  // POSITIVE CONTROL: the underlying body really is longer than the cap, so the cap is doing work.
  assert.ok(LONG_BODY.length > LOOKUP_LIMITS.MAX_EXCERPT_CHARS * 2, `body is ${LONG_BODY.length} chars`);
  // And the excerpt is VERBATIM — a prefix of the real text, never a paraphrase.
  assert.ok(LONG_BODY.startsWith(it.excerpt.slice(0, 80)));
});

test('MAIL returns subject, people and dates and NO BODY — the grant is metadata-only', () => {
  const out = findEvidence({ topic: 'coach pricing ladder', readZone: zoneOf([mailItem()]) });
  assert.equal(out.items.length, 1);
  const it = out.items[0];
  assert.equal(it.excerpt, null);
  assert.match(it.excerptOmittedBecause, /metadata-only/);
  assert.equal(it.title, 'Coach pricing ladder — a question');
  assert.ok(it.people.some((p) => p.includes('dana@northwind.example')));
  assert.ok(it.when, 'the date is returned');
  // POSITIVE CONTROL + the assertion that matters: the body text exists in the fixture and appears
  // NOWHERE in the rendered block.
  const block = renderEvidenceBlock(out.items);
  assert.ok(mailItem().item.content.text.includes('MUST NEVER BE RENDERED'));
  assert.equal(block.includes('MUST NEVER BE RENDERED'), false, block);
});

test('a CALENDAR item carries no excerpt either, and the omission is declared in the block', () => {
  const cal = driveDoc();
  cal.item.source = 'calendar';
  cal.item.kind = 'event';
  const out = findEvidence({ topic: 'coach pricing model', readZone: zoneOf([cal]) });
  assert.equal(out.items[0].excerpt, null);
  assert.match(renderEvidenceBlock(out.items), /calendar entries are shown without an excerpt/);
});

// -------------------------------------------------------------------------------------------------
// The label, the boundary and the link

test('the block carries the label, the data boundary and the deep link — all three, every time', () => {
  const out = lookupEvidenceForSlice({ slice: NONE, topic: 'coach pricing model', readZone: zoneOf([driveDoc()]) });
  assert.ok(out.text.startsWith(EVIDENCE_HEADING), out.text.slice(0, 120));
  assert.ok(out.text.includes(EXCERPT_BEGIN));
  assert.ok(out.text.includes(EXCERPT_END));
  assert.ok(out.text.includes('https://docs.google.com/document/d/doc_pricing/edit'));
  assert.ok(out.text.includes('ceo/evidence/unfiled/workspace/google/drive/'));
  assert.match(out.text, /DATA copied out of a file/);
  // It is NEVER the memory heading. That difference is the product.
  assert.equal(out.text.includes('COMPANY MEMORY'), false);
});

test('the spoken path offers the document and never reads the excerpt aloud', () => {
  const out = lookupEvidenceForSlice({ slice: NONE, topic: 'coach pricing model', readZone: zoneOf([driveDoc()]) });
  assert.match(out.spokenText, /^From your files: Coach pricing model in your Google Drive/);
  assert.match(out.spokenText, /Want me to read you what it says\?$/);
  // POSITIVE CONTROL: the written block DOES contain the excerpt, so "never aloud" is a real
  // difference between the two renderings rather than an empty excerpt.
  assert.ok(out.text.includes('three rungs'));
  assert.equal(out.spokenText.includes('three rungs'), false);
});

// -------------------------------------------------------------------------------------------------
// It is a lookup, not a source

test('it takes NO characters from the memory lanes budget', () => {
  const out = lookupEvidenceForSlice({ slice: NONE, topic: 'coach pricing model', readZone: zoneOf([driveDoc()]) });
  assert.equal(out.budget.takenFromMemoryBudget, false);
  assert.equal(out.budget.chars, out.text.length);
  assert.ok(out.chars > 0);
});

test('the module WRITES NOTHING and makes no network call — asserted against its own source', () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const file = path.join(here, '..', 'lib', 'workspace', 'evidence-lookup.js');
  const source = fs.readFileSync(file, 'utf8');
  assert.deepEqual(assertNoSideEffects(source, 'evidence-lookup'), []);
  // POSITIVE CONTROL: the scanner really does catch a write, so the empty result above means
  // something. (A lookup that wrote a "last consulted" marker would fail here.)
  assert.ok(assertNoSideEffects('fs.writeFileSync(p, x)', 'probe').length > 0);
});

test('the lookup reads through the SAME reader the real promote action uses', () => {
  // Collector-path parity: what the lookup shows can never drift from what a promotion would see,
  // because there is one reader. Asserted structurally — the default is promotion.js's own export.
  const source = fs.readFileSync(
    path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'workspace', 'evidence-lookup.js'),
    'utf8',
  );
  assert.match(source, /import \{ readEvidenceZone[^}]*\} from '\.\/promotion\.js'/);
  assert.match(source, /opts\.readZone \|\| readEvidenceZone/);
});

test('a query with no overlap returns NOTHING — the relative floor never admits the least-bad item', () => {
  const out = lookupEvidenceForSlice({
    slice: NONE,
    topic: 'kubernetes ingress controller',
    readZone: zoneOf([driveDoc(), mailItem()]),
  });
  assert.equal(out.available, false);
  assert.equal(out.reason, 'no-match');
  assert.equal(out.considered, 2, 'both items passed the walls — the floor is what refused them');
});

test('an empty zone is a clean "nothing", not a crash and not an empty heading', () => {
  const out = lookupEvidenceForSlice({ slice: NONE, topic: 'coach pricing model', readZone: zoneOf([]) });
  assert.equal(out.available, false);
  assert.equal(out.reason, 'no-match');
  assert.equal(out.text, '');
});

test('ranking is deterministic — the same zone and query give the same order twice', () => {
  const entries = [driveDoc(), mailItem()];
  const a = findEvidence({ topic: 'coach pricing', readZone: zoneOf(entries) }).items.map((i) => i.title);
  const b = findEvidence({ topic: 'coach pricing', readZone: zoneOf(entries) }).items.map((i) => i.title);
  assert.deepEqual(a, b);
  assert.ok(a.length > 0);
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

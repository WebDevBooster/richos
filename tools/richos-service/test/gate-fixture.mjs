#!/usr/bin/env node
/**
 * Generate `fixtures/correction-gate.json` FROM THE SHIPPED JS — the source of truth for
 * ceo-decisions.md §7's gate.
 *
 * WHY THIS EXISTS. The gate now has TWO implementations: this one, which corrects call
 * transcripts and dictation, and the Rust port in `app/crates/richos-core/src/spoken.rs`,
 * which decides whether a SPOKEN utterance is worth asking about. Both write into the same
 * `loro/entities.json`, so a divergence does not produce two answers — it produces one
 * vocabulary poisoned by whichever half was wrong.
 *
 * Two implementations that "agree by inspection" drift, and the drift is invisible because
 * each one's own tests keep passing. So neither side owns the answer: this file writes the
 * answers down once, from the JS, and BOTH sides assert against the same bytes.
 *   - `test/run.js` fails if the JS moves away from the fixture.
 *   - `cargo test -p richos-core --test spoken_gate_agreement` fails if the Rust does.
 *
 * Regenerate deliberately, never to make a red test green:
 *   node test/gate-fixture.mjs                 # rewrite the committed fixture
 *   node test/gate-fixture.mjs <out.json>      # write elsewhere, changing nothing
 * A regeneration that changes a value is a change to §7's gate and belongs in a commit
 * message that says so.
 *
 * THE OUTPUT ARGUMENT IS NOT A CONVENIENCE. `test/run.js` proves this generator still runs
 * and still reproduces the committed bytes, and the first version of that test invoked the
 * generator with no argument — so a MOVED gate rewrote the committed fixture, failed the
 * byte comparison once, and then passed for ever afterwards against its own new answers.
 * A test that repairs the evidence it is checking launders a regression into a pass. The
 * test now writes to a temp path and compares; nothing but a deliberate human run touches
 * the committed file.
 *
 * The fixture is ASCII on purpose. `normalizeTerm` here folds via `normalize('NFKD')` and
 * the Rust port folds via a small explicit table; that gap is real, named in `spoken.rs`,
 * and must not be hidden by a fixture that never exercises it either way.
 */

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { normalizeTerm, similarity } from '../lib/correct.js';
import { looksLikeTerm } from '../lib/capture.js';
import {
  phoneticKey,
  phoneticSimilarity,
  askKey,
  ASK_MIN_ORTHOGRAPHIC,
  ASK_MIN_PHONETIC,
  ASK_LONE_TOKEN_MIN,
} from '../lib/dictation.js';

/** Pairs chosen to span the DECISIONS, not to be pretty: each one is a verdict §7 argues from. */
const PAIRS = [
  ['deep graham', 'Deepgram'],
  ['Deke Graham', 'Deepgram'],
  ['Kestral', 'Kestrel'],
  ['Briella', 'Priya'],
  ['Thursday', 'Friday'],
  ['Tuesday', 'Wednesday'],
  ['MySQL', 'Postgres'],
  ['Ever Lock', 'Everlock'],
  ['whisper C P P', 'whisper.cpp'],
  ['Ilse', 'Elsa'],
  ['Jarrow', 'Yaro'],
  ['Series A', 'Series B'],
  ['Raven Crest', 'Ravencrest'],
  ["O'Connell", 'Okonkwo'],
  ['Ada Z', 'Adaeze'],
  ['great', 'Grant'],
];

/** Spans chosen to span `looksLikeTerm`'s three yes-routes and its one no-route. */
const SPANS = [
  'Deepgram',
  'whisper.cpp',
  'EverLock',
  'iPhone',
  'Quill Harbor',
  'the Bank of Kestrel',
  'a bug',
  'a feature',
  'ship Friday',
  "It's",
  'sixty',
  '1.4 million',
  'Series B',
  '',
];

const fixture = {
  note:
    'Generated from tools/richos-service/lib by test/gate-fixture.mjs. The SHARED contract of '
    + "ceo-decisions.md §7's gate, asserted by both implementations against these exact bytes. "
    + 'Every string here was invented for the fixture; none is a real spoken sentence.',
  generatedBy: 'tools/richos-service/test/gate-fixture.mjs',
  floors: {
    askMinOrthographic: ASK_MIN_ORTHOGRAPHIC,
    askMinPhonetic: ASK_MIN_PHONETIC,
    askLoneTokenMin: ASK_LONE_TOKEN_MIN,
  },
  pairs: PAIRS.map(([from, to]) => ({
    from,
    to,
    normalizedFrom: normalizeTerm(from),
    normalizedTo: normalizeTerm(to),
    phoneticKeyFrom: phoneticKey(from),
    phoneticKeyTo: phoneticKey(to),
    // Orthographic similarity is scored on the NORMALIZED forms; phonetic on the raw ones.
    // That asymmetry is the shipped behaviour and is part of what the port has to match.
    orthographic: similarity(normalizeTerm(from), normalizeTerm(to)),
    phonetic: phoneticSimilarity(from, to),
    key: askKey(from, to),
  })),
  spans: SPANS.map((text) => ({ text, looksLikeTerm: looksLikeTerm(text) })),
};

const here = dirname(fileURLToPath(import.meta.url));
const out = process.argv[2] ? process.argv[2] : join(here, 'fixtures', 'correction-gate.json');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, `${JSON.stringify(fixture, null, 2)}\n`);
console.log(`wrote ${out} — ${fixture.pairs.length} pairs, ${fixture.spans.length} spans`);

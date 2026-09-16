// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
import fs from 'node:fs';
import path from 'node:path';

import { analyzeCoverage, relinkCandidates } from '../lib/coverage.js';
import { RefusedError, bareMemId, memoryStoreFileFor, setJsonlField } from './writer.js';
import { assertWritePath, writePrivateFile } from './storage.js';

export const BASELINE_SCHEMA_VERSION = 1;

export const COVERAGE_TOOL = 'loro-coverage/1.0.0';

export function baselinePath(corpusRoot) {
  return corpusRoot.layout === 'corpus'
    ? path.join(corpusRoot.root, 'state', 'coverage-baseline.json')
    : path.join(corpusRoot.root, 'loro', 'coverage-baseline.json');
}

export function renderBaseline(analysis, prev = {}) {
  const carried = prev.knownUnreachable && typeof prev.knownUnreachable === 'object' ? prev.knownUnreachable : {};
  const files = [...new Set(analysis.unreachableFiles.map((u) => u.path))].sort();
  const knownUnreachable = {};
  for (const f of files) knownUnreachable[f] = carried[f] || '';
  return `${JSON.stringify(
    {
      schemaVersion: BASELINE_SCHEMA_VERSION,
      generatedBy: COVERAGE_TOOL,
      note:
        'DERIVED — regenerate with `loro-coverage baseline --write`, never edit the lists by hand. ' +
        'Each `knownUnreachable` entry needs a REASON; an empty one fails `loro-coverage check`, ' +
        'because an undeclared exemption is the silent default this tool exists to remove.',
      totals: analysis.totals,
      knownUnreachable,
      knownUncovered: analysis.uncovered.slice().sort(),
    },
    null,
    2,
  )}\n`;
}

export function readBaseline(corpusRoot) {
  const file = baselinePath(corpusRoot);
  if (!fs.existsSync(file)) {
    return {
      baseline: null,
      file,
      problem:
        `no coverage baseline at ${file}. Refusing to check against nothing — an absent ratchet ` +
        'passes every corpus, including one that has fallen a month behind. Create it with ' +
        '`loro-coverage baseline --write`, read the diff, and commit it.',
    };
  }
  try {
    return { baseline: JSON.parse(fs.readFileSync(file, 'utf8')), file, problem: null };
  } catch (err) {
    return { baseline: null, file, problem: `coverage baseline at ${file} is not valid JSON (${err.message}).` };
  }
}

export function writeBaseline(corpusRoot, analysis, opts = {}) {
  assertWritePath(corpusRoot, baselinePath(corpusRoot));
  const { baseline, file } = readBaseline(corpusRoot);
  const text = renderBaseline(analysis, baseline || {});
  const changed = !fs.existsSync(file) || fs.readFileSync(file, 'utf8') !== text;
  if (!opts.dryRun && changed) {
    writePrivateFile(corpusRoot, file, text);
  }
  return { file, text, written: !opts.dryRun && changed, changed };
}

export function checkAgainstBaseline(analysis, baseline) {
  const knownUncovered = new Set(Array.isArray(baseline.knownUncovered) ? baseline.knownUncovered : []);
  const declared = baseline.knownUnreachable && typeof baseline.knownUnreachable === 'object' ? baseline.knownUnreachable : {};

  const undeclaredUnreachable = analysis.unreachableFiles.filter(
    (u) => !(typeof declared[u.path] === 'string' && declared[u.path].trim()),
  );
  const newlyUncovered = analysis.uncovered.filter((k) => !knownUncovered.has(k));
  const nowCovered = new Set(analysis.uncovered);
  const ratchetable = [...knownUncovered].filter((k) => !nowCovered.has(k)).sort();
  const stillUnreachable = new Set(analysis.unreachableFiles.map((u) => u.path));
  const staleExemptions = Object.keys(declared).filter((f) => !stillUnreachable.has(f)).sort();

  return {
    ok: analysis.driftedAnchors.length === 0 && undeclaredUnreachable.length === 0 && newlyUncovered.length === 0,
    driftedAnchors: analysis.driftedAnchors,
    undeclaredUnreachable,
    newlyUncovered,
    ratchetable,
    staleExemptions,
  };
}

export function applyRelinks(corpusRoot, corpus, repairs, opts = {}) {
  const applied = [];
  const skipped = [];
  const edits = new Map();

  for (const repair of repairs) {
    for (const id of repair.records) {
      const rec = corpus.byId.get(id);
      if (!rec) {
        skipped.push({ id, why: 'no such record in this corpus' });
        continue;
      }
      if (rec.provenance.source !== 'memory') {
        skipped.push({
          id,
          why:
            `${rec.provenance.source} records carry their citation in front matter — use ` +
            '`loro-write correct --ref-source`, which requires a --why',
        });
        continue;
      }
      const store = memoryStoreFileFor(corpusRoot, rec);
      if (!store) {
        skipped.push({ id, why: 'could not resolve the JSONL store this record lives in' });
        continue;
      }
      assertWritePath(corpusRoot, store);
      if (!edits.has(store)) edits.set(store, fs.readFileSync(store, 'utf8'));
      try {
        edits.set(store, setJsonlField(edits.get(store), bareMemId(id), { anchor: repair.to }));
      } catch (err) {
        skipped.push({ id, why: err.message });
        continue;
      }
      applied.push({ id, file: store, from: repair.from, to: repair.to });
    }
  }

  if (!opts.dryRun) {
    for (const f of edits.keys()) assertWritePath(corpusRoot, f);
    for (const [f, text] of edits) writePrivateFile(corpusRoot, f, text);
  }
  return { applied, skipped };
}

export { memoryStoreFileFor as storeFileFor };

export function refuseAutoPromotion(args) {
  if (args.apply === true) {
    throw new RefusedError(
      'loro-coverage propose --apply does not exist, and will not. A candidate is not a record: ' +
        '`kind`, `authority`, `confidence` and `scope` are judgments a heading cannot supply, and ' +
        'the prose layer already carries the mechanical guess honestly labelled `kindInferred: true`. ' +
        'Promoting that guess unlabelled would make the corpus WORSE, not merely no better. ' +
        'Read the section and write it with `loro-write append`.',
      5,
    );
  }
}

export { analyzeCoverage, relinkCandidates };

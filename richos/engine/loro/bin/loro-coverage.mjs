#!/usr/bin/env node
// Loro public component. SPDX-License-Identifier: AGPL-3.0-only

import fs from 'node:fs';

import { analyzeCoverage, candidateFor, coverageByPage, relinkCandidates } from '../lib/coverage.js';
import { resolveCorpusRoot } from '../lib/layout.js';
import { loadCorpus } from '../lib/store.js';
import {
  applyRelinks,
  checkAgainstBaseline,
  readBaseline,
  refuseAutoPromotion,
  writeBaseline,
} from '../writer/coverage-write.js';

const USAGE = `loro-coverage — does the promoted layer still describe the pages it cites?

  loro-coverage report    [--format json|text] [--limit <n>]
  loro-coverage check                                   # exit 6 on a regression
  loro-coverage baseline  [--write] [--dry-run]         # regenerate the ratchet
  loro-coverage relink    [--apply]                     # repair re-slugified citations only
  loro-coverage propose   [--page <path>] [--limit <n>] [--out <file>]

Corpus (required, no default):
  --corpus <dir>    a provisioned corpus (ceo/ + companies/). Or LORO_CORPUS.
  --root <dir>      an in-repo dogfood root. Or LORO_ROOT.

  --format json|text   default text for report/check, json for propose
  --now <iso8601>      fixed clock, for deterministic output
`;

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) args[key] = true;
      else {
        args[key] = next;
        i += 1;
      }
    } else args._.push(a);
  }
  return args;
}

const val = (args, key) => (args[key] !== undefined && args[key] !== true ? String(args[key]) : undefined);
const out = (s) => process.stdout.write(s);

function fail(code, message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = code;
  return null;
}

function summary(analysis) {
  const t = analysis.totals;
  const pct = t.sections ? Math.round((t.covered / t.sections) * 100) : 0;
  return (
    `${t.covered}/${t.sections} prose sections have a promoted record (${pct}%). ` +
    `${t.promoted} promoted record(s); ${t.danglingCitations} citation(s) resolve to nothing ` +
    `(${t.driftedAnchors} drifted anchor(s), ${t.unreachableFiles} outside the prose layer); ` +
    `${t.uncited} promoted record(s) cite no page at all.`
  );
}

function main() {
  const argv = process.argv.slice(2);
  const command = argv[0];
  const args = parseArgs(argv.slice(1));

  if (!command || command === 'help' || args.help) {
    out(USAGE);
    return;
  }

  let corpusRoot;
  let corpus;
  let analysis;
  try {
    corpusRoot = resolveCorpusRoot({ corpus: val(args, 'corpus'), root: val(args, 'root'), env: process.env });
    const now = args.now && args.now !== true ? Date.parse(String(args.now)) : Date.now();
    if (Number.isNaN(now)) throw new Error(`--now is not a valid ISO-8601 timestamp: ${args.now}`);
    corpus = loadCorpus({ ...corpusRoot, now });
    analysis = analyzeCoverage(corpus.records);
  } catch (err) {
    return fail(2, `usage: ${err.message}`);
  }

  const json = val(args, 'format') === 'json';
  const limit = args.limit && args.limit !== true ? Number(args.limit) : 25;

  try {
    if (command === 'report') return report(analysis, { json, limit });
    if (command === 'check') return check(corpusRoot, analysis, { json });
    if (command === 'baseline') return baseline(corpusRoot, analysis, args);
    if (command === 'relink') return relink(corpusRoot, corpus, analysis, args);
    if (command === 'propose') return propose(corpus, analysis, args, { limit });
  } catch (err) {
    return fail(typeof err.code === 'number' ? err.code : 1, err.message);
  }

  return fail(2, `unknown command "${command}"\n\n${USAGE}`);
}

function report(analysis, { json, limit }) {
  if (json) {
    out(
      `${JSON.stringify(
        {
          totals: analysis.totals,
          byPage: coverageByPage(analysis),
          driftedAnchors: analysis.driftedAnchors,
          unreachableFiles: analysis.unreachableFiles,
          uncited: analysis.uncited,
        },
        null,
        2,
      )}\n`,
    );
    return;
  }
  out(`${summary(analysis)}\n\n`);
  out('WORST-COVERED PAGES (uncovered/total)\n');
  for (const p of coverageByPage(analysis).slice(0, limit)) {
    out(`  ${String(`${p.uncovered}/${p.total}`).padStart(8)}  ${p.path}\n`);
  }
  const rel = relinkCandidates(analysis);
  if (rel.repairable.length) {
    out('\nCITATIONS A MACHINE MAY REPAIR (same heading, re-slugified)\n');
    for (const r of rel.repairable) out(`  ${r.path}\n    ${r.from}\n -> ${r.to}   (${r.records.length} record(s))\n`);
  }
  if (rel.unrepairable.length) {
    out('\nCITATIONS THAT NEED A PERSON\n');
    for (const r of rel.unrepairable) out(`  ${r.key}  (${r.records.length} record(s))\n      ${r.why}\n`);
  }
}

function check(corpusRoot, analysis, { json }) {
  const { baseline: base, file, problem } = readBaseline(corpusRoot);
  if (problem) return fail(2, problem);
  const result = checkAgainstBaseline(analysis, base);
  if (json) {
    out(`${JSON.stringify({ ok: result.ok, baseline: file, totals: analysis.totals, ...result }, null, 2)}\n`);
  } else {
    out(`${summary(analysis)}\n`);
    out(`baseline: ${file}\n\n`);
    if (result.driftedAnchors.length) {
      out(`FAIL — ${result.driftedAnchors.length} citation(s) point at a section their page no longer has:\n`);
      for (const d of result.driftedAnchors) out(`  ${d.key}\n      cited by ${d.records.join(', ')}\n`);
      out('  Run `loro-coverage relink` — it repairs the ones whose heading only re-slugified.\n\n');
    }
    if (result.undeclaredUnreachable.length) {
      out(`FAIL — ${result.undeclaredUnreachable.length} citation(s) name a file outside the prose layer, with no declared reason:\n`);
      for (const u of result.undeclaredUnreachable) out(`  ${u.key}\n      cited by ${u.records.join(', ')}\n`);
      out('  Decide whether that file is company memory, then write the reason into the baseline.\n\n');
    }
    if (result.newlyUncovered.length) {
      out(`FAIL — ${result.newlyUncovered.length} prose section(s) are newly uncovered since the baseline:\n`);
      for (const k of result.newlyUncovered.slice(0, 40)) out(`  ${k}\n`);
      if (result.newlyUncovered.length > 40) out(`  … and ${result.newlyUncovered.length - 40} more\n`);
      out('  Promote a record with `loro-write append`, or ratchet deliberately: `loro-coverage baseline --write`.\n\n');
    }
    if (result.ratchetable.length) {
      out(`${result.ratchetable.length} baseline entr(ies) are now covered or gone — the ratchet can tighten: \`loro-coverage baseline --write\`.\n`);
    }
    if (result.staleExemptions.length) {
      out(`${result.staleExemptions.length} declared exemption(s) no longer apply: ${result.staleExemptions.join(', ')}.\n`);
    }
    if (result.ok) out('OK — the corpus has not fallen behind its baseline.\n');
  }
  if (!result.ok) process.exitCode = 6;
}

function baseline(corpusRoot, analysis, args) {
  const dryRun = args['dry-run'] === true || args.write !== true;
  const r = writeBaseline(corpusRoot, analysis, { dryRun });
  if (dryRun) {
    out(`${r.changed ? 'WOULD WRITE' : 'unchanged'} ${r.file}\n\n${r.text}`);
    return;
  }
  out(`${r.written ? 'wrote' : 'unchanged'} ${r.file}\n${summary(analysis)}\n`);
}

function relink(corpusRoot, corpus, analysis, args) {
  const rel = relinkCandidates(analysis);
  const apply = args.apply === true;
  if (!rel.repairable.length) {
    out('no citation is mechanically repairable.\n');
    if (rel.unrepairable.length) {
      out(`${rel.unrepairable.length} broken citation(s) need a person:\n`);
      for (const u of rel.unrepairable) out(`  ${u.key}\n      ${u.why}\n`);
    }
    return;
  }
  const r = applyRelinks(corpusRoot, corpus, rel.repairable, { dryRun: !apply });
  out(`${apply ? 'RELINKED' : 'WOULD RELINK'} ${r.applied.length} record(s) — a pointer changed, no claim did:\n`);
  for (const a of r.applied) out(`  ${a.id}\n    ${a.from}\n -> ${a.to}\n`);
  for (const s of r.skipped) out(`  SKIPPED ${s.id}: ${s.why}\n`);
  if (!apply) out('\nPropose-only. Re-run with --apply to write.\n');
  if (rel.unrepairable.length) {
    out(`\n${rel.unrepairable.length} broken citation(s) are NOT repairable and stay for a person:\n`);
    for (const u of rel.unrepairable) out(`  ${u.key}\n      ${u.why}\n`);
  }
}

function propose(corpus, analysis, args, { limit }) {
  refuseAutoPromotion(args);
  const page = val(args, 'page');
  const bodies = new Map(corpus.records.filter((r) => r.provenance.source === 'wiki').map((r) => [`${r.provenance.path}#${r.provenance.anchor}`, r.text]));
  const wanted = analysis.sections
    .filter((s) => !analysis.citedBy.has(s.key))
    .filter((s) => !page || s.path === page)
    .slice(0, limit);
  const candidates = wanted.map((s) => candidateFor(s, bodies.get(s.key) || ''));
  const text = `${candidates.map((c) => JSON.stringify(c)).join('\n')}\n`;
  const file = val(args, 'out');
  if (file) {
    fs.writeFileSync(file, text, 'utf8');
    process.stderr.write(
      `${candidates.length} candidate(s) -> ${file}. These are NOT records: every adjudicated field is ` +
        'null. Read each section and promote with `loro-write append`, or leave it as prose — which is ' +
        'a real answer, not a gap.\n',
    );
    return;
  }
  out(text);
}

main();

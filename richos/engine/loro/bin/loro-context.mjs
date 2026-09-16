#!/usr/bin/env node
// Loro public component. SPDX-License-Identifier: AGPL-3.0-only

import fs from 'node:fs';
import { analyzeCoverage } from '../lib/coverage.js';
import { COMPILER_VERSION, CONTEXT_SLICE_SCHEMA_VERSION, compileContext, fetchRecord } from '../lib/compile.js';
import { CORPUS_ENV, ROOT_ENV, resolveCorpusRoot } from '../lib/layout.js';
import { AUDIENCES } from '../lib/privacy.js';
import { loadCorpus } from '../lib/store.js';

const USAGE = `loro-context ${COMPILER_VERSION} (slice schema v${CONTEXT_SLICE_SCHEMA_VERSION})

  loro-context compile --topic "<active thread>" [options]
  loro-context fetch   --ref "<ref>" [options]
  loro-context corpus  [options]

Options:
  --topic <text>        the active thread / task to compile memory for (compile)
  --topic-stdin         read the topic from stdin instead (avoids shell escaping)
  --ref <ref>           record ref to deep-fetch (fetch)
  --budget-chars <n>    HARD cap on the rendered slice text (default 1200)
  --max-items <n>       cap on items selected (default 8)
  --audience <a>        ${AUDIENCES.join(' | ')}  (default rich)
  --sources <list>      comma list of memory,wiki,entities (default all)
  --company <ids>       company lanes to compile: comma list, or "all" (default: every ACTIVE
                        company). NARROWS attention and cost; it is NOT a privacy control — use
                        --audience/scope for that. An unknown id is an error, never an empty lane.
  --corpus <dir>        the CEO's corpus root (ceo/ + companies/). Or ${CORPUS_ENV}.
  --root <dir>          an in-repo dogfood root (wiki/ + loro/). Or ${ROOT_ENV}.
  --now <iso8601>       fixed clock, for deterministic/testable output
  --format json|text    default json
`;

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        args[key] = true;
      } else {
        args[key] = next;
        i += 1;
      }
    } else {
      args._.push(a);
    }
  }
  return args;
}

function fail(code, message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = code;
  return null;
}

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

function commonOpts(args) {
  const resolved = resolveCorpusRoot({
    corpus: args.corpus && args.corpus !== true ? String(args.corpus) : undefined,
    root: args.root && args.root !== true ? String(args.root) : undefined,
    env: process.env,
  });
  const now = args.now && args.now !== true ? Date.parse(String(args.now)) : Date.now();
  if (Number.isNaN(now)) throw new Error(`--now is not a valid ISO-8601 timestamp: ${args.now}`);
  const sources = args.sources && args.sources !== true ? String(args.sources).split(',').map((s) => s.trim()).filter(Boolean) : undefined;
  return {
    root: resolved.root,
    layout: resolved.layout,
    rootSource: resolved.rootSource,
    dogfood: resolved.dogfood,
    now,
    sources,
    audience: args.audience && args.audience !== true ? String(args.audience) : 'rich',
  };
}

function main() {
  const argv = process.argv.slice(2);
  const command = argv[0];
  const args = parseArgs(argv.slice(1));
  const format = args.format === 'text' ? 'text' : 'json';

  if (!command || command === 'help' || args.help) {
    process.stdout.write(USAGE);
    return;
  }

  let base;
  try {
    base = commonOpts(args);
  } catch (err) {
    return fail(2, `usage: ${err.message}`);
  }

  if (command === 'compile') {
    let topic = args.topic && args.topic !== true ? String(args.topic) : '';
    if (args['topic-stdin']) topic = readStdin();
    if (!topic.trim()) return fail(2, 'usage: compile needs --topic "<text>" (or --topic-stdin)');

    if (args.company === true) return fail(2, 'usage: --company needs a value — a comma list of company ids, or "all"');
    let slice;
    try {

      slice = compileContext({
        ...base,
        corpus: loadCorpus(base),
        topic,
        budgetChars: args['budget-chars'] && args['budget-chars'] !== true ? Number(args['budget-chars']) : undefined,
        maxItems: args['max-items'] && args['max-items'] !== true ? Number(args['max-items']) : undefined,

        company: args.company,
      });
    } catch (err) {
      return fail(/privacy invariant/.test(err.message) ? 4 : 2, err.message);
    }
    process.stdout.write(format === 'text' ? `${slice.text}\n` : `${JSON.stringify(slice, null, 2)}\n`);
    return;
  }

  if (command === 'fetch') {
    const ref = args.ref && args.ref !== true ? String(args.ref) : '';
    if (!ref) return fail(2, 'usage: fetch needs --ref "<ref>"');
    let result;
    try {
      result = fetchRecord({ ...base, corpus: loadCorpus(base), ref });
    } catch (err) {
      return fail(/privacy invariant/.test(err.message) ? 4 : 2, err.message);
    }
    if (!result.found) {
      return fail(result.denied ? 4 : 3, result.reason);
    }
    if (format === 'text') {
      const r = result.record;
      process.stdout.write(`[${r.kind}${r.kindInferred ? '?' : ''}] ${r.title}\n(${r.provenance.path || r.id})\n\n${r.text}\n`);
    } else {
      process.stdout.write(`${JSON.stringify(result.record, null, 2)}\n`);
    }
    return;
  }

  if (command === 'corpus') {
    const corpus = loadCorpus(base);

    const cov = analyzeCoverage(corpus.records).totals;
    const summary = {
      coverage: cov,
      root: corpus.root,
      layout: corpus.layout,
      rootSource: corpus.rootSource,
      companies: corpus.companies,
      retiredCompanies: corpus.retiredCompanies,
      sources: corpus.sources,
      fingerprint: corpus.fingerprint,
      entitiesVersion: corpus.entitiesVersion,
      counts: corpus.counts,
      notes: corpus.notes,
      problems: corpus.problems.slice(0, 20),
    };
    if (format === 'text') {
      const kinds = Object.keys(summary.counts)
        .filter((k) => k !== 'total')
        .sort()
        .map((k) => `${k}=${summary.counts[k]}`)
        .join(' ');
      process.stdout.write(
        `loro corpus @ ${summary.root}\n  layout: ${summary.layout} (from ${summary.rootSource})\n` +
          `  companies: ${summary.companies.length ? summary.companies.join(', ') : '(none)'}` +
          `${summary.retiredCompanies.length ? ` (retired: ${summary.retiredCompanies.join(', ')})` : ''}\n` +
          `  sources: ${summary.sources.join(', ')}\n  records: ${summary.counts.total} (${kinds})\n` +
          `  entitiesVersion: ${summary.entitiesVersion}\n  fingerprint: ${summary.fingerprint}\n` +
          `  coverage: ${cov.covered}/${cov.sections} prose sections have a promoted record` +
          `${cov.danglingCitations ? `; ${cov.danglingCitations} citation(s) resolve to NOTHING` : ''}` +
          `${cov.uncited ? `; ${cov.uncited} promoted record(s) cite no page` : ''}\n` +
          `${summary.notes.length ? `  notes: ${summary.notes.join('; ')}\n` : ''}`,
      );
    } else {
      process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
    }
    return;
  }

  fail(2, `unknown command "${command}"\n\n${USAGE}`);
}

main();

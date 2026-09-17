#!/usr/bin/env node
/**
 * THE EVIDENCE LOOKUP, AS A PROCESS — the one door the Rust app knocks on.
 *
 *   richos-evidence lookup --coverage none --topic-stdin --zone <dir> --format json
 *
 * Executes §1 and §4 of `docs/plans/loro-evidence-retrieval-ruling-2026-09-17.md` (richos-hq).
 * `lib/workspace/evidence-lookup.js` is the whole of the behavior; this file is argv, a zone, and
 * one JSON object on stdout. It holds no ranking, no rendering and no policy of its own, so the
 * block the app injects and the block `test/evidence-lookup-e2e.mjs` prints cannot drift.
 *
 * =================================================================================================
 * WHY A SECOND ENTRY POINT RATHER THAN A `loro-context` SUBCOMMAND
 *
 * The ruling's §1 table names the verb `loro-context evidence --find <query>`, and that spelling is
 * not available without inverting a dependency. `engine/loro/**` is the Loro public component
 * (`SPDX-License-Identifier: AGPL-3.0-only`, stamped on every file there) and it imports nothing
 * from `tools/richos-service`; the lookup module imports `engine/loro/lib/{privacy,relevance}.js`
 * AND `./promotion.js`, so teaching `bin/loro-context.mjs` the verb would make the compiler depend
 * on the Workspace source. §4's own instruction is the binding one — *"a new module BESIDE the
 * compiler rather than inside `engine/loro/lib`"* — and a module beside the compiler gets a door
 * beside the compiler's. The verb is `richos-evidence lookup`; the ruling's table is one spelling
 * out of date and that is recorded rather than quietly reconciled.
 *
 * =================================================================================================
 * THE ZONE IS NEVER DEFAULTED, AND THIS IS THE ONE THING THIS FILE ADDS
 *
 * `config.js corpusRoot()` falls back to `~/RichOS/corpus` when `LORO_CORPUS` is unset
 * (`config.js:51-56`), so `workspaceZone()` resolves to a real path on a machine that configured
 * nothing. For a lookup driven by a child process that is exactly `CONTEXT-CONTRACT.md` §1's
 * refused default — *"a customer's Rich silently answering out of the VENDOR's company memory, and
 * exiting 0 either way"* — one layer down, over the CEO's own documents. So:
 *
 *   `--zone <dir>` or `--corpus <dir>` is REQUIRED. Neither given, and `LORO_CORPUS` /
 *   `RICHOS_WORKSPACE_ZONE` unset, is exit 2 with the reason on stderr. There is no fallback.
 *
 * =================================================================================================
 * WHAT IT WRITES: nothing. It opens `item.json` / `content.txt` for reading and returns one JSON
 * object on stdout. Human lines go to stderr so stdout stays parseable.
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

/** The output schema the Rust consumer asserts before it trusts a byte of this. */
export const EVIDENCE_LOOKUP_SCHEMA_VERSION = 1;
export const EVIDENCE_LOOKUP_VERSION = '1.0.0';

const USAGE = `richos-evidence ${EVIDENCE_LOOKUP_VERSION} (lookup schema v${EVIDENCE_LOOKUP_SCHEMA_VERSION})

  richos-evidence lookup --coverage <label> [--topic <text> | --topic-stdin] (--zone <dir> | --corpus <dir>)

The evidence lookup: the CEO's own files, labeled as files, when company memory did not answer.
It writes nothing and it is never company memory.

Options:
  --coverage <label>    the compiled slice's own coverage label: none | adjacent | direct.
                        The lookup runs on "none" and "adjacent" ONLY. Anything else — including
                        a missing label — reports consulted:false and looks at nothing, because
                        absence of the signal is not the signal.
  --topic <text>        what the CEO asked
  --topic-stdin         read the topic from stdin instead (avoids shell quoting)
  --zone <dir>          the Workspace evidence zone. REQUIRED unless --corpus is given.
  --corpus <dir>        the corpus root; the zone is derived from it. No default — see the header.
  --audience <a>        rich only in v1 (default rich). Anything else is a reported refusal.
  --max-items <n>       cap on items returned (the module's hard ceiling applies regardless)
  --now <iso8601>       fixed clock, for deterministic output
  --format json         default and only format

Exit: 0 a completed lookup (found or not) | 2 usage / no zone | 3 the lookup itself failed
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

function str(v) {
  return v && v !== true ? String(v) : '';
}

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

/**
 * The zone, or a refusal naming what would have fixed it. NEVER `~/RichOS/corpus`.
 *
 * Precedence, and every step of it is something somebody SAID rather than something inferred:
 * `--zone`, then `--corpus` + the active company, then `RICHOS_WORKSPACE_ZONE`, then `LORO_CORPUS`.
 *
 * @returns {{zone:string}|{error:string}}
 */
export function resolveZone(args, env = process.env) {
  const explicitZone = str(args.zone);
  if (explicitZone) return { zone: path.resolve(explicitZone) };

  const explicitCorpus = str(args.corpus);
  if (explicitCorpus) return { zone: zoneUnder(path.resolve(explicitCorpus), env) };

  const envZone = (env.RICHOS_WORKSPACE_ZONE || '').trim();
  if (envZone) return { zone: path.resolve(envZone) };

  const envCorpus = (env.LORO_CORPUS || '').trim();
  if (envCorpus) return { zone: zoneUnder(path.resolve(envCorpus), env) };

  return {
    error:
      'no evidence zone: pass --zone <dir> or --corpus <dir>, or set RICHOS_WORKSPACE_ZONE or ' +
      'LORO_CORPUS. There is NO default — defaulting here would read whichever corpus happens to ' +
      'sit at ~/RichOS/corpus and exit 0 either way.',
  };
}

/** `companies/<active>/evidence/workspace` or `ceo/evidence/unfiled/workspace` — config.js's own layout. */
function zoneUnder(corpus, env) {
  const company = (env.RICHOS_ACTIVE_COMPANY || '').trim();
  const root = company
    ? path.join(corpus, 'companies', company, 'evidence')
    : path.join(corpus, 'ceo', 'evidence', 'unfiled');
  return path.join(root, 'workspace');
}

/** One item, reduced again for the wire: what a UI may render beside the block. Never the excerpt. */
function wireItem(it) {
  return {
    title: it.title,
    sourceLabel: it.sourceLabel,
    vendor: it.vendor,
    source: it.source,
    when: it.when,
    deepLink: it.deepLink,
    evidencePath: it.evidencePath,
    hasExcerpt: Boolean(it.excerpt),
  };
}

export async function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const verb = args._[0];
  if (!verb || args.help || verb === 'help') {
    process.stderr.write(USAGE);
    return verb ? 0 : 2;
  }
  if (verb !== 'lookup') {
    process.stderr.write(`unknown verb "${verb}"\n\n${USAGE}`);
    return 2;
  }
  const format = str(args.format) || 'json';
  if (format !== 'json') {
    process.stderr.write(`--format ${format} is not supported; this entry point emits json only\n`);
    return 2;
  }

  const zoned = resolveZone(args);
  if (zoned.error) {
    process.stderr.write(`${zoned.error}\n`);
    return 2;
  }

  const topic = (args['topic-stdin'] ? readStdin() : str(args.topic)).trim();
  const coverage = str(args.coverage).trim();
  const audience = str(args.audience).trim() || undefined;
  const maxItems = args['max-items'] && args['max-items'] !== true ? Number(args['max-items']) : undefined;
  const now = args.now && args.now !== true ? Date.parse(str(args.now)) : Date.now();
  if (Number.isNaN(now)) {
    process.stderr.write(`--now is not a valid ISO-8601 timestamp: ${str(args.now)}\n`);
    return 2;
  }

  const {
    lookupEvidenceForSlice, shouldConsultEvidence, EVIDENCE_HEADING, EXCERPT_BEGIN, EXCERPT_END,
    LOOKUP_LIMITS, LOOKUP_AUDIENCE,
  } = await import('../lib/workspace/evidence-lookup.js');

  // THE GATE, ASKED OF THE MODULE — never re-implemented here. A second copy of the consult rule
  // would be a second thing to keep in step with the compiler's labels, and it would be the copy
  // that drifted. `slice` is the label and nothing else: this process never sees a compiled slice.
  const slice = { coverage };
  const consulted = shouldConsultEvidence(slice);

  const base = {
    schemaVersion: EVIDENCE_LOOKUP_SCHEMA_VERSION,
    lookup: `richos-evidence/${EVIDENCE_LOOKUP_VERSION}`,
    coverage: coverage || null,
    consulted,
    zone: zoned.zone,
    heading: EVIDENCE_HEADING,
    excerptBegin: EXCERPT_BEGIN,
    excerptEnd: EXCERPT_END,
    limits: { ...LOOKUP_LIMITS },
    audience: audience || LOOKUP_AUDIENCE,
  };

  if (!consulted) {
    const detail = `coverage ${JSON.stringify(coverage)} is not a consult signal — `
      + 'memory covered this, or never said it did not';
    process.stdout.write(`${JSON.stringify({
      ...base,
      available: false,
      reason: 'covered',
      detail,
      text: '',
      spokenText: '',
      chars: 0,
      items: [],
      considered: 0,
      budget: { chars: 0, takenFromMemoryBudget: false },
    }, null, 2)}\n`);
    return 0;
  }

  let found;
  try {
    found = lookupEvidenceForSlice({ slice, topic, audience, zone: zoned.zone, now, maxItems });
  } catch (e) {
    // A THROW IS EXIT 3, NOT AN EMPTY BLOCK. `assertAudience` throws on an unknown audience, and a
    // caller that read "nothing in your files" out of a crash would be told a falsehood by a bug.
    process.stderr.write(`the evidence lookup failed: ${e && e.message ? e.message : e}\n`);
    return 3;
  }

  process.stdout.write(`${JSON.stringify({
    ...base,
    available: found.available,
    reason: found.reason,
    detail: found.detail || null,
    text: found.text,
    spokenText: found.spokenText,
    chars: found.chars,
    items: (found.items || []).map(wireItem),
    considered: found.considered,
    budget: found.budget,
  }, null, 2)}\n`);
  return 0;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return fs.realpathSync(entry) === fs.realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  main()
    .then((code) => {
      process.exitCode = code;
    })
    .catch((e) => {
      process.stderr.write(`${e && e.stack ? e.stack : e}\n`);
      process.exitCode = 3;
    });
}

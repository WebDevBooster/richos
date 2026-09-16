#!/usr/bin/env node
// Loro public component. SPDX-License-Identifier: AGPL-3.0-only

import fs from 'node:fs';

import { resolveCorpusRoot } from '../lib/layout.js';
import { loadCorpus } from '../lib/store.js';
import { COMPANY_ROLES, COMPANY_STATUSES, appendRecord, correctRecord, createCompany, resolveRef, supersedeRecord } from '../writer/writer.js';

const USAGE = `loro-write — record a belief, or correct one loro already holds.

  loro-write append    --id <id> --kind <kind> --body-stdin [options]
  loro-write supersede --ref <old-ref> --id <new-id> --kind <kind> --body-stdin --why "<reason>"
  loro-write correct   --ref <ref> --why "<reason>" [--scope|--kind|--title|--confidence|--tags|--body-stdin]
  loro-write show      --ref <ref>
  loro-write create-company --id <company-id> [--name "<display name>"] [--role <role>]

Corpus (required, no default):
  --corpus <dir>        a provisioned corpus (ceo/ + companies/). Or LORO_CORPUS.
  --root <dir>          an in-repo dogfood root. Or LORO_ROOT.

Record:
  --id <id>             lowercase-hyphen id; becomes the filename and a permanent ref
  --kind <kind>         principle|decision|constraint|preference|strategy|lesson|commitment|
                        risk|goal|metric|fact|event|entity|passage
  --scope <scope>       ceo-private|org-shared|external   (OMITTED => ceo-private)
  --authority <who>     self|internal|external|unknown — WHO made the claim. OMITTED stays absent
                        and reads as unknown; it is never defaulted to self, because the writer
                        must not assert authorship of a claim nobody attributed
  --title <text>        display title (defaults to the body's first line)
  --body <text>         the record body, or use --body-stdin
  --body-stdin          read the body from stdin (no shell quoting)
  --partition <p>       ceo (default) | unfiled | <company-id>
  --confidence <0..1>   default 0.9
  --observed-at <iso>   when this became true (default: now)
  --tags a,b            comma list
  --method <m>          how this was learned (default explicit_ceo_instruction)
  --source <s>          where it came from (default conversation)
  --ref-source <r>      a pointer back to the evidence

Company partition (create-company):
  --id <company-id>     stable forever; becomes the directory name and every record's company field
  --name "<text>"       display name; a FIELD, so a later rename is free and needs no migration
  --role <role>         ${COMPANY_ROLES.join(' | ')}   (default owner)
  --status <status>     ${COMPANY_STATUSES.join(' | ')}   (default active)
  --started-at <when>   coarse on purpose — "2025-01" or "2025" are real answers

Correction:
  --why "<reason>"      REQUIRED for correct/supersede — what was wrong
  --widen-scope         acknowledge widening ceo-private -> org-shared/external

  --now <iso8601>       fixed clock, for deterministic tests
  --dry-run             print what would be written; touch nothing
  --json                emit ONE JSON object on stdout instead of prose. For machine callers
                        (the RichOS correction desk). Exit codes and stderr are unchanged.
`;

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) args[key] = true;
      else { args[key] = next; i += 1; }
    } else args._.push(a);
  }
  return args;
}

const val = (args, key) => (args[key] !== undefined && args[key] !== true ? String(args[key]) : undefined);

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

function bodyFrom(args) {
  if (args['body-stdin']) return readStdin();
  return val(args, 'body');
}

function main() {
  const argv = process.argv.slice(2);
  const command = argv[0];
  const args = parseArgs(argv.slice(1));

  if (!command || command === 'help' || args.help) {
    process.stdout.write(USAGE);
    return;
  }

  let corpusRoot;
  let corpus;
  let now;
  try {
    corpusRoot = resolveCorpusRoot({ corpus: val(args, 'corpus'), root: val(args, 'root'), env: process.env });
    now = args.now && args.now !== true ? Date.parse(String(args.now)) : Date.now();
    if (Number.isNaN(now)) throw new Error(`--now is not a valid ISO-8601 timestamp: ${args.now}`);
    corpus = loadCorpus({ ...corpusRoot, now });
  } catch (err) {
    return fail(2, `usage: ${err.message}`);
  }

  const dryRun = args['dry-run'] === true;
  const asJson = args.json === true;
  const emit = (obj) => process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`);
  const common = {
    corpus,
    corpusRoot,
    now,
    dryRun,
    id: val(args, 'id'),
    kind: val(args, 'kind'),
    scope: val(args, 'scope'),
    authority: val(args, 'authority'),
    title: val(args, 'title'),
    partition: val(args, 'partition'),
    confidence: args.confidence !== undefined && args.confidence !== true ? Number(args.confidence) : undefined,
    observedAt: val(args, 'observed-at'),
    tags: val(args, 'tags') ? String(val(args, 'tags')).split(',').map((t) => t.trim()).filter(Boolean) : undefined,
    method: val(args, 'method'),
    sourceLabel: val(args, 'source'),
    ref: val(args, 'ref'),
    why: val(args, 'why'),
    widenScope: args['widen-scope'] === true,
  };

  try {
    if (command === 'append') {
      const out = appendRecord({ ...common, ref: val(args, 'ref-source'), body: bodyFrom(args) });
      if (asJson) {
        emit({ op: 'append', dryRun, ref: out.ref, file: out.file, text: out.text });
        return;
      }
      report(dryRun ? 'WOULD WRITE' : 'wrote', out.ref, out.file, out.text, dryRun);
      return;
    }

    if (command === 'supersede') {
      if (!common.ref) return fail(2, 'usage: supersede needs --ref "<the record that is out of date>"');
      if (!String(common.why || '').trim()) {
        return fail(2, 'usage: supersede needs --why "<why the old record no longer holds>"');
      }

      const out = supersedeRecord({ ...common, refSource: val(args, 'ref-source'), body: bodyFrom(args) });
      if (asJson) {
        emit({
          op: 'supersede',
          dryRun,
          ref: out.ref,
          supersededRef: out.supersededRef,
          file: out.file,
          oldFile: out.oldFile,
          text: out.text,
        });
        return;
      }
      process.stdout.write(
        `${dryRun ? 'WOULD SUPERSEDE' : 'superseded'} ${out.supersededRef}\n  with ${out.ref}\n  ${out.file}\n`,
      );
      if (dryRun) process.stdout.write(`\n${out.text}\n`);
      return;
    }

    if (command === 'correct') {
      if (!common.ref) return fail(2, 'usage: correct needs --ref "<the record that is wrong>"');
      const body = bodyFrom(args);
      const out = correctRecord({ ...common, body });
      if (asJson) {
        emit({ op: 'correct', dryRun, ref: out.ref, file: out.file, changed: out.changed, text: out.text });
        return;
      }
      process.stdout.write(
        `${dryRun ? 'WOULD CORRECT' : 'corrected'} ${out.ref} (${out.changed.join(', ')})\n  ${out.file}\n`,
      );
      if (dryRun) process.stdout.write(`\n${out.text}\n`);
      return;
    }

    if (command === 'create-company') {
      if (!common.id) return fail(2, 'usage: create-company needs --id "<company-id>"');
      const out = createCompany({
        corpusRoot,
        dryRun,
        id: common.id,
        name: val(args, 'name'),
        role: val(args, 'role'),
        status: val(args, 'status'),
        startedAt: val(args, 'started-at'),
      });
      if (asJson) {
        emit({
          op: 'create-company',
          dryRun,
          id: out.id,
          file: out.manifestPath,
          dir: out.dir,
          dirs: out.dirs,
          text: out.manifest,
        });
        return;
      }
      process.stdout.write(
        `${dryRun ? 'WOULD CREATE' : 'created'} company partition "${out.id}"\n  ${out.dir}\n` +
          `${out.dirs.map((d) => `  + ${d}`).join('\n')}\n  + ${out.manifestPath}\n\n${out.manifest}`,
      );
      return;
    }

    if (command === 'show') {
      if (!common.ref) return fail(2, 'usage: show needs --ref "<ref>"');

      const found = resolveRef({ corpus, corpusRoot, ref: common.ref });
      const rec = found.record;
      const contents = fs.readFileSync(found.file, 'utf8');
      if (asJson) {
        emit({
          op: 'show',
          dryRun: false,
          ref: common.ref,

          file: found.file,
          text: contents,
          source: found.source,
          what: found.what,
          record: { kind: rec.kind, title: rec.title, text: rec.text, scope: rec.scope, status: rec.status },
          cites: rec.provenance.source === 'memory' ? rec.provenance.path || null : null,
          writable: found.writable,
          refusals: found.refusals,
        });
        return;
      }

      const relFile = found.file.startsWith(corpusRoot.root)
        ? found.file.slice(corpusRoot.root.length + 1)
        : found.file;
      const out = [
        found.file,
        '',
        `RECORD    ${common.ref}`,
        `          ${found.what} — [${rec.kind}${rec.kindInferred ? '?' : ''}] ${rec.title}`,
        `HELD IN   ${relFile}`,
      ];
      if (rec.provenance.source === 'memory' && rec.provenance.path) {
        out.push(`CITES     ${rec.provenance.path}${rec.provenance.anchor ? `#${rec.provenance.anchor}` : ''}`);
      }
      out.push(
        `WRITABLE  supersede: ${found.writable.supersede ? 'yes' : `no — ${found.refusals.supersede}`}`,
        `          correct:   ${found.writable.correct ? 'yes' : `no — ${found.refusals.correct}`}`,
        '',
        found.source === 'records' ? contents : `${rec.text}\n`,
      );
      process.stdout.write(`${out.join('\n')}`);
      return;
    }
  } catch (err) {
    return fail(typeof err.code === 'number' ? err.code : 1, err.message);
  }

  fail(2, `unknown command "${command}"\n\n${USAGE}`);
}

function report(verb, ref, file, text, dryRun) {
  process.stdout.write(`${verb} ${ref}\n  ${file}\n`);
  if (dryRun) process.stdout.write(`\n${text}\n`);
}

main();

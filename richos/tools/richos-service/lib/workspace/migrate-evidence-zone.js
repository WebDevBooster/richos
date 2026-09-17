/**
 * ONE-TIME MIGRATION — relocate the unfiled evidence zone out of the compiled record tree.
 *
 *   ceo/unfiled/evidence/**  ->  ceo/evidence/unfiled/**
 *
 * Why this exists: `evidenceRoot()` used to resolve its unfiled branch — the default, since no
 * company is bound unless `RICHOS_ACTIVE_COMPANY` says so — to `ceo/unfiled/evidence`. `ceo/unfiled`
 * is an enumerated RECORD directory in both of loro's path builders, walked recursively with a `.md`
 * filter, so meeting transcripts and Workspace evidence sat INSIDE compiled memory. `config.js`
 * moved the zone; a corpus written before that move still has the old tree on disk, and the promoted
 * records in it still carry `Evidence:` lines pointing at the old path. This puts both right.
 *
 * ---------------------------------------------------------------------------------------------
 * WHAT IT REWRITES, AND — MORE IMPORTANTLY — WHAT IT REFUSES TO
 *
 * Evidence is IMMUTABLE (loro-architecture departure #2). A migration that rewrote a stored item
 * body would be editing the CEO's raw material to fix our own layout mistake, and if a transcript
 * happens to contain the words `ceo/unfiled/evidence/` it would be silently corrupted. So the
 * rewrite is scoped by file, never by "every file containing the string":
 *
 *   - INSIDE the moved zone: `governance.json` (its `evidenceLink` field) and the `*.jsonl` ledgers.
 *     `item.json` and `content.txt` are NEVER touched — they are the immutable evidence itself.
 *   - OUTSIDE the zone: `*.md` record bodies, and only on a line that begins `Evidence: `. That is
 *     the exact line `promotion.js` writes (`renderEventBody`, `Evidence: ${evidenceLink}`), so
 *     prose that merely mentions the old path is left alone.
 *
 * It also REFUSES rather than guesses:
 *
 *   - if the destination already exists and is non-empty, it stops. Merging two evidence zones is a
 *     decision, not a default, and a half-merged zone is unrecoverable.
 *   - it never deletes. The move is a rename; on failure nothing has been removed.
 *
 * `--dry-run` is the default from the CLI: it reports exactly what it would do and changes nothing.
 */

import fs from 'node:fs';
import path from 'node:path';

import { corpusRoot, evidenceRoot, legacyUnfiledEvidenceRoot, activeCompany } from '../config.js';

/** The corpus-relative form of the two zones — this is what is embedded in links. */
export const OLD_REL = 'ceo/unfiled/evidence';
export const NEW_REL = 'ceo/evidence/unfiled';

/** Evidence files that are immutable by contract and must never be rewritten. */
const IMMUTABLE_IN_ZONE = new Set(['item.json', 'content.txt']);

/** Directories that are never descended into while hunting for promoted records. */
const SKIP_DIRS = new Set(['node_modules', '.git', 'evidence']);

/**
 * Plan and (unless `dryRun`) perform the migration.
 *
 * @param {Object} [opts]
 * @param {string} [opts.corpus]   corpus root; defaults to `corpusRoot()`
 * @param {boolean} [opts.dryRun]  report only, change nothing (default true — this is destructive-ish)
 * @returns {{corpus:string, from:string, to:string, moved:boolean, filesMoved:number,
 *            linksRewritten:Array<{file:string, occurrences:number}>, skipped:Array<string>,
 *            refusal:string|null, dryRun:boolean, nothingToDo:boolean}}
 */
export function migrateEvidenceZone(opts = {}) {
  const corpus = opts.corpus ? path.resolve(opts.corpus) : corpusRoot();
  const dryRun = opts.dryRun !== false;
  const from = legacyUnfiledEvidenceRoot(corpus);
  const to = path.join(corpus, ...NEW_REL.split('/'));

  const out = {
    corpus,
    from,
    to,
    moved: false,
    filesMoved: 0,
    linksRewritten: [],
    skipped: [],
    refusal: null,
    dryRun,
    nothingToDo: false,
  };

  const hasOld = isDirectory(from);
  if (!hasOld) {
    // Still rewrite stale links: a corpus can have been moved by hand, or by an earlier run that
    // stopped short, and a record pointing at a path with nothing behind it is worse than no link.
    out.nothingToDo = true;
  } else {
    if (isDirectory(to) && fs.readdirSync(to).length > 0) {
      out.refusal =
        `both ${OLD_REL}/ and ${NEW_REL}/ exist and the destination is not empty. Merging two ` +
        'evidence zones is a decision, not a default — move or remove one of them by hand, then ' +
        're-run. Nothing has been changed.';
      return out;
    }
    out.filesMoved = countFiles(from);
    out.nothingToDo = false;
  }

  // Which files carry an embedded link, and how many occurrences each has.
  const rewrites = [];
  for (const file of filesCarryingLinks(corpus, hasOld ? from : to)) {
    const before = readTextOrNull(file.abs);
    if (before === null) continue;
    const after = rewriteText(before, file.kind);
    if (after !== before) {
      rewrites.push({ file: path.relative(corpus, file.abs), occurrences: countOccurrences(before), abs: file.abs, after });
    }
  }

  if (dryRun) {
    out.linksRewritten = rewrites.map(({ file, occurrences }) => ({ file, occurrences }));
    return out;
  }

  if (hasOld) {
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.renameSync(from, to);
    out.moved = true;
    // Paths under the old zone have moved; re-resolve each rewrite target against the new root.
    for (const r of rewrites) {
      if (r.abs.startsWith(from + path.sep)) r.abs = path.join(to, path.relative(from, r.abs));
    }
    // `ceo/unfiled` itself stays: it is a legitimate record partition and holds promoted records.
  }

  for (const r of rewrites) {
    fs.writeFileSync(r.abs, r.after);
    out.linksRewritten.push({ file: r.file, occurrences: r.occurrences });
  }
  return out;
}

/** Human-readable report of a plan or a completed run — one line per thing that happened. */
export function formatMigrationReport(result) {
  const lines = [];
  const tag = result.dryRun ? 'would ' : '';
  lines.push(`corpus:     ${result.corpus}`);
  lines.push(`from:       ${OLD_REL}/`);
  lines.push(`to:         ${NEW_REL}/`);
  if (result.refusal) {
    lines.push(`REFUSED:    ${result.refusal}`);
    return lines.join('\n');
  }
  if (result.nothingToDo && !result.filesMoved) {
    lines.push(`zone:       nothing at ${OLD_REL}/ — already migrated, or never written`);
  } else {
    lines.push(`zone:       ${tag}move ${result.filesMoved} file(s)`);
  }
  if (!result.linksRewritten.length) {
    lines.push('links:      no embedded evidence link names the old path');
  } else {
    const total = result.linksRewritten.reduce((n, r) => n + r.occurrences, 0);
    lines.push(`links:      ${tag}rewrite ${total} reference(s) in ${result.linksRewritten.length} file(s)`);
    for (const r of result.linksRewritten) lines.push(`              ${r.file}  (${r.occurrences})`);
  }
  if (result.dryRun) lines.push('(dry run — nothing was changed. Re-run with --apply.)');
  return lines.join('\n');
}

/**
 * Where the CURRENT process would write evidence, and whether that is inside a compiled directory.
 * Used by the CLI so the operator sees the destination rather than trusting this file's constants.
 */
export function currentEvidenceDestination() {
  return { company: activeCompany(), root: evidenceRoot() };
}

// -------------------------------------------------------------------------------------------------

function isDirectory(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function readTextOrNull(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch {
    return null;
  }
}

function countFiles(dir) {
  let n = 0;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) n += countFiles(p);
    else n += 1;
  }
  return n;
}

function countOccurrences(text) {
  return text.split(`${OLD_REL}/`).length - 1;
}

/**
 * Rewrite by KIND, never globally.
 *  - 'zone-metadata' — a governance.json or a ledger line: the whole file is ours, rewrite every
 *    occurrence of the zone prefix.
 *  - 'record' — a promoted record body: only the `Evidence: ` line, which is the only place
 *    `promotion.js` writes a link.
 */
function rewriteText(text, kind) {
  if (kind === 'zone-metadata') return text.split(`${OLD_REL}/`).join(`${NEW_REL}/`);
  return text
    .split('\n')
    .map((line) => (/^Evidence: /.test(line) ? line.split(`${OLD_REL}/`).join(`${NEW_REL}/`) : line))
    .join('\n');
}

/** Every file that may legitimately carry an embedded evidence link, tagged with its kind. */
function filesCarryingLinks(corpus, zone) {
  const out = [];
  if (isDirectory(zone)) walkZone(zone, out);
  walkRecords(corpus, corpus, out, 0);
  return out;
}

function walkZone(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      walkZone(p, out);
    } else if (!IMMUTABLE_IN_ZONE.has(e.name) && (e.name.endsWith('.json') || e.name.endsWith('.jsonl'))) {
      out.push({ abs: p, kind: 'zone-metadata' });
    }
  }
}

/** Promoted records are `*.md` anywhere in the corpus OUTSIDE any evidence directory. */
function walkRecords(corpus, dir, out, depth) {
  if (depth > 8) return;
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name.startsWith('.') || SKIP_DIRS.has(e.name)) continue;
      walkRecords(corpus, p, out, depth + 1);
    } else if (e.name.endsWith('.md')) {
      out.push({ abs: p, kind: 'record' });
    }
  }
}

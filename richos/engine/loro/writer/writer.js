// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
import fs from 'node:fs';
import path from 'node:path';

import { parseFrontMatter, renderRecordFile, setFields } from '../lib/frontmatter.js';
import { AUTHORITY_WEIGHT, KINDS, SCOPES, normalizeRecord, validateRecord } from '../lib/record.js';
import { SOURCES, loadCorpus } from '../lib/store.js';
import { assertWritePath, makeWriteDirectory, writePrivateFile, withWriteLock } from './storage.js';

export class RefusedError extends Error {
  constructor(message, code = 5) {
    super(message);
    this.name = 'RefusedError';
    this.code = code;
  }
}

export class NoSuchRefError extends Error {
  constructor(message) {
    super(message);
    this.name = 'NoSuchRefError';
    this.code = 3;
  }
}

export const ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,79}$/;

export const AUTHORITIES = Object.keys(AUTHORITY_WEIGHT);

export function assertId(id) {
  const s = String(id || '').trim();
  if (!ID_PATTERN.test(s)) {
    throw new RefusedError(
      `loro write: "${s}" is not a usable record id. Use lowercase letters, digits and hyphens ` +
        '(e.g. pricing-seat-based) — the id becomes a filename and a permanent ref.',
      2,
    );
  }
  return s;
}

export function resolvePartition(corpusRoot, partition) {
  const p = String(partition || 'ceo').trim();

  if (corpusRoot.layout === 'repo' && !fs.existsSync(path.join(corpusRoot.root, 'ceo'))) {
    if (p !== 'ceo') {
      throw new RefusedError(
        `loro write: this in-repo dogfood checkout is not provisioned — it has one records directory ` +
          `and no ceo/ or companies/ tree, so --partition "${p}" has nowhere to go. Provision it ` +
          '(`loro-write create-company`, plus ceo/records) or use a provisioned corpus (--corpus).',
        2,
      );
    }
    return { dir: path.join(corpusRoot.root, 'loro', 'records'), company: null, partition: 'ceo' };
  }
  if (p === 'ceo') return { dir: path.join(corpusRoot.root, 'ceo', 'records'), company: null, partition: 'ceo' };
  if (p === 'unfiled') return { dir: path.join(corpusRoot.root, 'ceo', 'unfiled'), company: null, partition: 'unfiled' };
  const id = p.replace(/^companies\//, '');
  const dir = path.join(corpusRoot.root, 'companies', id);
  if (!fs.existsSync(dir)) {
    const known = (corpusRoot.companies || []).join(', ') || '(none yet)';
    throw new RefusedError(
      `loro write: no company "${id}" in this corpus. Known companies: ${known}. ` +
        'Create the partition deliberately, or use --partition unfiled — unfiled is a legitimate ' +
        'resting place, and filing must never block a write.',
    );
  }
  return { dir: path.join(dir, 'records'), company: id, partition: `companies/${id}` };
}

export function refFor(root, file) {
  return `rec:${path.relative(root, file).split(path.sep).join('/').replace(/\.md$/, '')}`;
}

function assertUsable(fields, body, id, now) {
  const rec = normalizeRecord(
    { ...fields, id, text: body, title: fields.title || '', promotionMethod: fields.provenance?.method },
    { now, source: 'records' },
  );
  const problems = validateRecord(rec);
  if (problems.length) throw new RefusedError(`loro write: refusing to write an unusable record — ${problems.join('; ')}`, 2);
  return rec;
}

function assertKind(kind) {
  const k = String(kind || '').toLowerCase().trim();
  if (!k) {
    throw new RefusedError(
      `loro write: --kind is required. A record DECLARES its type; a guessed one would come back ` +
        `marked inferred. One of: ${KINDS.join(' | ')}`,
      2,
    );
  }
  if (!KINDS.includes(k)) throw new RefusedError(`loro write: unknown kind "${k}". One of: ${KINDS.join(' | ')}`, 2);
  return k;
}

function assertScope(scope) {
  if (scope === undefined || scope === null || scope === '') return 'ceo-private';
  const s = String(scope).toLowerCase().trim();
  if (!SCOPES.includes(s)) throw new RefusedError(`loro write: unknown scope "${s}". One of: ${SCOPES.join(' | ')}`, 2);
  return s;
}

function assertAuthority(authority) {
  if (authority === undefined || authority === null || authority === '') return undefined;
  const a = String(authority).toLowerCase().trim();
  if (!AUTHORITIES.includes(a)) {
    throw new RefusedError(
      `loro write: unknown authority "${a}". One of: ${AUTHORITIES.join(' | ')} — ` +
        'self is the CEO\'s own words, internal a team or design-authority ruling, external a ' +
        'vendor- or research-sourced fact.',
      2,
    );
  }
  return a;
}

export function isWidening(from, to) {
  return SCOPES.indexOf(to) > SCOPES.indexOf(from);
}

export function appendRecord(opts) {
  return withWriteLock(opts.corpusRoot, () => appendRecordUnlocked(opts), opts);
}

function appendRecordUnlocked(opts) {
  const id = assertId(opts.id);
  const kind = assertKind(opts.kind);
  const scope = assertScope(opts.scope);
  const body = String(opts.body || '').trim();
  if (!body) throw new RefusedError('loro write: a record with no body records nothing. Pass --body or --body-stdin.', 2);

  const target = resolvePartition(opts.corpusRoot, opts.partition);
  const file = assertWritePath(opts.corpusRoot, path.join(target.dir, `${id}.md`));
  if (fs.existsSync(file)) {
    throw new RefusedError(
      `loro write: "${refFor(opts.corpusRoot.root, file)}" already exists. Refusing to overwrite it — ` +
        'a belief is superseded, never silently replaced. Use `correct` to fix it, or `supersede` to ' +
        'record that it is out of date and what replaced it.',
    );
  }

  const fields = {
    id,
    kind,
    scope,
    title: opts.title || undefined,
    company: target.company || undefined,
    authority: assertAuthority(opts.authority),
    confidence: typeof opts.confidence === 'number' ? opts.confidence : 0.9,
    observedAt: opts.observedAt || new Date(opts.now).toISOString(),
    supersededBy: null,
    supersedes: opts.supersedes || undefined,
    tags: opts.tags && opts.tags.length ? opts.tags : undefined,
    related: opts.related && opts.related.length ? opts.related : undefined,
    provenance: {
      method: opts.method || 'explicit_ceo_instruction',
      source: opts.sourceLabel || 'conversation',
      ref: opts.ref || null,
    },
  };
  assertUsable(fields, body, `rec:${id}`, opts.now);
  const text = renderRecordFile(fields, body);

  if (!opts.dryRun) {
    writePrivateFile(opts.corpusRoot, file, text, { createOnly: true });
  }
  return { ref: refFor(opts.corpusRoot.root, file), file, text, written: !opts.dryRun };
}

export function memoryStoreFileFor(corpusRoot, rec) {
  const m = /^mem:([^:]+):/.exec(rec.id);
  if (!m) return null;

  if (corpusRoot.layout === 'corpus') return null;
  const dir = path.join(corpusRoot.root, 'loro', 'memory');
  for (const ext of ['.jsonl', '.json']) {
    const f = path.join(dir, `${m[1]}${ext}`);
    if (fs.existsSync(f)) return f;
  }
  return null;
}

function ownFile(corpusRoot, rec) {
  return rec.provenance.path ? path.join(corpusRoot.root, rec.provenance.path) : null;
}

export const REF_RESOLVERS = {
  records: {
    prefix: 'rec:',
    what: 'a typed record in the writable store',
    container: ownFile,
    supersede: true,
    correct: true,
  },
  memory: {
    prefix: 'mem:',
    what: 'a promoted row in the typed JSONL memory store',
    container: memoryStoreFileFor,
    supersede: true,
    correct: (ref) =>
      `loro write: "${ref}" lives in the JSONL store, which this writer only SUPERSEDES. ` +
      'Correcting it in place would rewrite a machine-promoted row; record the correction as a new ' +
      `record instead: \`loro-write supersede --ref ${ref} --id <new-id> …\``,
  },
  wiki: {
    prefix: 'wiki:',
    what: 'a section of a prose page',
    container: ownFile,
    supersede: (ref, rec) =>
      `loro write: "${ref}" is a PROSE section, not a typed record — loro indexes this text, it does ` +
      'not own it, so there is no record here to supersede. Prose is corrected by editing the page ' +
      `— that escape hatch must always work, and git records the change: ${rec.provenance.path || '(unknown path)'}`,
    correct: (ref, rec) =>
      `loro write: "${ref}" is a PROSE section, not a typed record. Prose is corrected by editing the ` +
      `page — that escape hatch must always work, and git records the change: ${rec.provenance.path || '(unknown path)'}`,
  },
  entities: {
    prefix: 'entity:',
    what: 'a generated vocabulary entry',
    container: ownFile,

    supersede: (ref, rec) =>
      `loro write: "${ref}" is a generated vocabulary entry, not a belief — it is synthesized from a ` +
      `row in ${rec.provenance.path || 'entities.json'} and has no claim to supersede. Vocabulary is ` +
      'maintained by the entity learning loop and by editing that file; loro-write records beliefs.',
    correct: (ref, rec) =>
      `loro write: "${ref}" is a generated vocabulary entry, not a belief — it is synthesized from a ` +
      `row in ${rec.provenance.path || 'entities.json'} and carries no metadata of its own to correct. ` +
      'Vocabulary is maintained by the entity learning loop and by editing that file.',
  },
};

export function assertResolverCoverage() {
  const missing = SOURCES.filter((s) => !REF_RESOLVERS[s]);
  if (missing.length) {
    throw new RefusedError(
      `loro write: the compiler can emit refs from source(s) the writer has no resolver for: ` +
        `${missing.join(', ')}. Add an entry to REF_RESOLVERS — a ref the compiler hands out and the ` +
        'writer cannot address is a belief nobody can correct.',
      1,
    );
  }
}

export function resolveRef(opts) {
  assertResolverCoverage();
  const ref = String(opts.ref || '');
  const record = opts.corpus.byId.get(ref);
  if (!record) throw new NoSuchRefError(`loro write: no record with ref "${ref}". Nothing was changed.`);

  const source = record.provenance.source;
  const spec = REF_RESOLVERS[source];
  if (!spec) {
    throw new RefusedError(
      `loro write: "${ref}" comes from the "${source}" source, which this writer has no resolver for. ` +
        'Refusing to guess which file holds it — a guessed container is how a correction lands in the ' +
        'wrong file.',
      1,
    );
  }

  const file = spec.container(opts.corpusRoot, record);
  if (!file || !fs.existsSync(file)) {
    throw new RefusedError(
      `loro write: "${ref}" is ${spec.what}, but the file that holds it is not in this corpus ` +
        `(looked for: ${file || 'nothing resolvable'}). Nothing was changed.`,
    );
  }

  const reason = (rule) => (rule === true ? null : rule(ref, record));
  return {
    record,
    source,

    kind: spec.prefix.replace(/:$/, ''),
    what: spec.what,
    file,
    writable: { supersede: spec.supersede === true, correct: spec.correct === true },
    refusals: { supersede: reason(spec.supersede), correct: reason(spec.correct) },
  };
}

export function locate(opts) {
  const resolved = resolveRef(opts);
  const op = opts.op === 'correct' ? 'correct' : 'supersede';
  if (!resolved.writable[op]) throw new RefusedError(resolved.refusals[op]);
  return resolved;
}

export function supersedeRecord(opts) {
  return withWriteLock(opts.corpusRoot, () => supersedeRecordUnlocked({ ...opts,
    corpus: loadCorpus({ ...opts.corpusRoot, now: opts.now }),
  }), opts);
}

function supersedeRecordUnlocked(opts) {
  const found = locate({ ...opts, op: 'supersede' });
  assertWritePath(opts.corpusRoot, found.file);
  if (found.record.supersededBy) {
    throw new RefusedError(
      `loro write: "${opts.ref}" is already superseded by "${found.record.supersededBy}". ` +
        'Supersede the CURRENT record instead — a chain that points at dead records answers nothing.',
    );
  }

  const scope = assertScope(opts.scope);
  if (isWidening(found.record.scope, scope) && !opts.widenScope) {
    throw new RefusedError(
      `loro write: refusing to widen "${opts.ref}" from ${found.record.scope} to ${scope} without --widen-scope.`,
    );
  }

  // A correction changes the belief, not the company that can retrieve it.
  // Desktop Supersede requests intentionally have no partition argument. Keep
  // unfiled records there too; promoted legacy records retain their company lane.
  const relative = path.relative(opts.corpusRoot.root, found.file).split(path.sep).join('/');
  const partition = found.record.company || (relative.startsWith('ceo/unfiled/') ? 'unfiled' : 'ceo');
  const original = resolvePartition(opts.corpusRoot, partition);
  if (opts.partition !== undefined && resolvePartition(opts.corpusRoot, opts.partition).partition !== original.partition) {
    throw new RefusedError('loro write: supersede preserves the original partition. Moving a record requires a separate filing operation.');
  }
  const created = appendRecord({
    ...opts,
    scope,
    partition,
    ref: opts.refSource || opts.ref,
    supersedes: opts.ref,
    dryRun: true,
  });

  const stamp = new Date(opts.now).toISOString();
  let oldText;
  if (found.kind === 'rec') {
    oldText = setFields(fs.readFileSync(found.file, 'utf8'), {
      supersededBy: created.ref,
      supersededAt: stamp,
      supersessionReason: opts.why || null,
    });
  } else {
    oldText = setJsonlField(fs.readFileSync(found.file, 'utf8'), bareMemId(opts.ref), {
      supersededBy: created.ref,
      supersededAt: stamp,
      supersessionReason: opts.why || null,
    });
  }

  if (!opts.dryRun) {
    // Check both destinations before publishing either side of the correction.
    assertWritePath(opts.corpusRoot, found.file);
    assertWritePath(opts.corpusRoot, created.file);
    writePrivateFile(opts.corpusRoot, created.file, created.text, { createOnly: true });
    writePrivateFile(opts.corpusRoot, found.file, oldText);
  }
  return { ref: created.ref, supersededRef: opts.ref, file: created.file, oldFile: found.file, text: created.text };
}

export function bareMemId(ref) {
  const parts = String(ref).split(':');
  return parts.slice(2).join(':');
}

export function setJsonlField(text, id, changes) {
  const lines = String(text).split(/\r?\n/);
  let hit = false;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line || line.startsWith('//')) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (obj.id !== id) continue;
    lines[i] = JSON.stringify({ ...obj, ...changes });
    hit = true;
    break;
  }
  if (!hit) throw new NoSuchRefError(`loro write: no JSONL record with id "${id}" in that file.`);
  return lines.join('\n');
}

export function correctRecord(opts) {
  return withWriteLock(opts.corpusRoot, () => correctRecordUnlocked({ ...opts,
    corpus: loadCorpus({ ...opts.corpusRoot, now: opts.now }),
  }), opts);
}

function correctRecordUnlocked(opts) {

  const found = resolveRef(opts);
  if (!String(opts.why || '').trim()) {
    throw new RefusedError(
      'loro write: correct needs --why "<what was wrong>". A correction with no reason is an ' +
        'unexplained edit, and the next reader cannot tell it from a mistake.',
      2,
    );
  }
  if (!found.writable.correct) throw new RefusedError(found.refusals.correct);
  assertWritePath(opts.corpusRoot, found.file);

  const changes = {};
  const changed = [];
  if (opts.kind !== undefined) { changes.kind = assertKind(opts.kind); changed.push('kind'); }
  if (opts.title !== undefined) { changes.title = String(opts.title); changed.push('title'); }
  if (opts.authority !== undefined) { changes.authority = assertAuthority(opts.authority); changed.push('authority'); }
  if (opts.confidence !== undefined) { changes.confidence = Number(opts.confidence); changed.push('confidence'); }
  if (opts.observedAt !== undefined) { changes.observedAt = String(opts.observedAt); changed.push('observedAt'); }
  if (opts.tags !== undefined) { changes.tags = opts.tags; changed.push('tags'); }
  if (opts.scope !== undefined) {
    const next = assertScope(opts.scope);
    if (isWidening(found.record.scope, next) && !opts.widenScope) {
      throw new RefusedError(
        `loro write: refusing to widen "${opts.ref}" from ${found.record.scope} to ${next} without ` +
          '--widen-scope. Widening is what turns the CEO\'s private view into something every worker ' +
          'sees, and it must be a decision, never a side effect of another edit.',
      );
    }
    changes.scope = next;
    changed.push('scope');
  }
  if (opts.body !== undefined) changed.push('body');
  if (!changed.length) {
    throw new RefusedError('loro write: correct was given nothing to change.', 2);
  }

  changes.correctedAt = new Date(opts.now).toISOString();
  changes.correctionReason = String(opts.why);

  const before = fs.readFileSync(found.file, 'utf8');

  const text = setFields(before, changes, opts.body === undefined ? {} : { body: String(opts.body) });

  const parsed = parseFrontMatter(text);
  assertUsable(parsed.data, parsed.body, opts.ref, opts.now);

  if (!opts.dryRun) writePrivateFile(opts.corpusRoot, found.file, text);
  return { ref: opts.ref, file: found.file, text, changed };
}

export const COMPANY_ROLES = ['owner', 'co-founder', 'advisor', 'investor', 'observer'];

export const COMPANY_STATUSES = ['active', 'retired', 'merged'];

export function createCompany(opts) {
  return withWriteLock(opts.corpusRoot, () => createCompanyUnlocked(opts), opts);
}

function createCompanyUnlocked(opts) {
  const corpusRoot = opts.corpusRoot;
  const id = assertId(opts.id);
  const role = String(opts.role || 'owner').trim();
  if (!COMPANY_ROLES.includes(role)) {
    throw new RefusedError(
      `loro write: "${role}" is not a company role. One of: ${COMPANY_ROLES.join(' | ')}. ` +
        'The field is inert in v1 and is validated anyway, because an unvalidated inert field is a ' +
        'field that will be wrong on the day something starts reading it.',
      2,
    );
  }
  const status = String(opts.status || 'active').trim();
  if (!COMPANY_STATUSES.includes(status)) {
    throw new RefusedError(`loro write: "${status}" is not a company status. One of: ${COMPANY_STATUSES.join(' | ')}.`, 2);
  }

  const dir = path.join(corpusRoot.root, 'companies', id);
  assertWritePath(corpusRoot, dir, 'directory');
  if (fs.existsSync(dir)) {
    throw new RefusedError(
      `loro write: company partition "${id}" already exists at ${dir}. Creating it again would either ` +
        'clobber its manifest or open a second home for records that already have one. To rename it, ' +
        'edit `name` in its manifest — `name` is a field and `id` never changes, so a rename is free ' +
        'and costs no migration.',
    );
  }

  const dirs = ['pages', 'records', 'evidence', 'inbox', 'mirrors'].map((d) => path.join(dir, d));
  const manifestPath = path.join(dir, 'company.yaml');
  const lines = [`id: ${id}`, `name: ${opts.name ? String(opts.name).trim() : id}`, `role: ${role}`, `status: ${status}`];

  if (opts.startedAt) lines.push(`startedAt: ${String(opts.startedAt).trim()}`);
  const manifest = `${lines.join('\n')}\n`;

  if (opts.dryRun) return { created: false, id, dir, manifestPath, manifest, dirs };
  for (const d of dirs) assertWritePath(corpusRoot, d, 'directory');
  assertWritePath(corpusRoot, manifestPath);
  for (const d of dirs) makeWriteDirectory(corpusRoot, d);
  writePrivateFile(corpusRoot, manifestPath, manifest, { createOnly: true });
  return { created: true, id, dir, manifestPath, manifest, dirs };
}

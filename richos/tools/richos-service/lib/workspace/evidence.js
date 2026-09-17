/**
 * RichOS Workspace source — the EVIDENCE ZONE writer (the system architecture §4.2).
 *
 * Raw items land here as IMMUTABLE evidence, NOT as truth (loro-architecture departure #2). This is a
 * document *evidence* store, deliberately NOT a document *dumping ground* (loro-concept "storage is not
 * memory"): the large normalized body is kept in `content.txt` (cheap to scan) out of the JSON, and
 * attachments are refs — never bulk-downloaded (§4.1 design notes).
 *
 * Layout (§4.2), mirroring the call-transcript drop zone — same discipline, different family. Both
 * now live in the CEO's CORPUS, never in the product repo (`config.js:evidenceRoot`):
 *   <corpus>/{companies/<id>/evidence|ceo/evidence/unfiled}/workspace/<vendor>/<source>/<safeId>/
 *     item.json      the SourceItem (immutable once written; a new version = a new rev dir)
 *     content.txt    normalized text (out of the JSON for cheap governance scanning)
 *     governance.json the §5.1 metadata record + evidence link
 *
 * A CHANGED item (same id, new etag) is written as a NEW rev directory so prior versions are never
 * overwritten (temporal memory, loro-architecture #3). The evidence link is always answerable:
 * "why does loro think X?" resolves to a concrete file.
 */

import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { workspaceZone } from '../config.js';
import { privateDirectory, privateFile, writePrivateFile } from '../private-files.js';

/** Keep a readable prefix, with the full identity digest preventing sanitizer collisions. */
export function safeId(sourceItemId) {
  const id = String(sourceItemId ?? '');
  const prefix = id.replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 48) || 'item';
  return `${prefix}--${digest(id)}`;
}

function digest(value) {
  return createHash('sha256').update(String(value)).digest('hex');
}

/** ETags are opaque: punctuation and every character contribute to revision identity. */
export function revToken(vendorEtag) {
  return digest(vendorEtag ?? '');
}

function sameIdentity(stored, item) {
  return stored.sourceItemId === item.sourceItemId && stored.vendor === item.vendor
    && stored.source === item.source && stored.provenance?.vendorEtag === item.provenance.vendorEtag;
}

/** Existing citations retain their legacy location only when its full identity matches. */
export function evidenceDir(item, zone = workspaceZone()) {
  const legacyId = String(item.sourceItemId || 'unknown').replace(/[^A-Za-z0-9._-]/g, '_');
  const legacyEtag = String(item.provenance.vendorEtag || 'noetag').replace(/[^A-Za-z0-9]/g, '').slice(0, 24) || 'noetag';
  const legacy = path.join(zone, item.vendor, item.source, legacyId, `rev-${legacyEtag}`);
  if (fs.existsSync(path.join(legacy, 'item.json'))) {
    const verified = privateDirectory(legacy, zone);
    const file = privateFile(path.join(verified, 'item.json'), verified);
    let stored;
    try { stored = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* preserve damaged legacy evidence */ }
    if (stored && sameIdentity(stored, item)) return legacy;
  }
  return path.join(zone, item.vendor, item.source, safeId(item.sourceItemId), `rev-${revToken(item.provenance.vendorEtag)}`);
}

/**
 * The repo-relative evidence link (§5.1) recorded in governance metadata — stable across machines.
 * @param {import('./source-item.js').SourceItem} item
 * @param {string} zone
 * @param {string} repoRoot
 */
export function evidenceLinkFor(item, zone, repoRoot) {
  const dir = evidenceDir(item, zone);
  const rel = path.relative(repoRoot, dir);
  return path.join(rel, 'item.json');
}

/** Publish a complete revision once. Repeat observations never rewrite its evidence. */
export function writeEvidence(item, governance, zone = workspaceZone()) {
  const requested = evidenceDir(item, zone);
  const parent = privateDirectory(path.dirname(requested), zone);
  const dir = path.join(parent, path.basename(requested));
  function validateDestination() {
    const entry = fs.lstatSync(dir, { throwIfNoEntry: false });
    if (entry && (!entry.isDirectory() || entry.isSymbolicLink())) {
      throw new Error('storage boundary: revision directory must not be a link');
    }
    if (entry) {
      privateDirectory(dir, zone);
      for (const name of ['item.json', 'content.txt', 'governance.json']) {
        privateFile(path.join(dir, name), dir);
      }
    }
  }
  validateDestination();
  const itemPath = path.join(dir, 'item.json');
  const body = item.content.text || '';
  const stored = { ...item, content: { ...item.content, text: undefined, textFile: 'content.txt' } };

  function existing() {
    // Fetched time changes on a repeat observation. The source evidence may not.
    const material = (value) => {
      const copy = JSON.parse(JSON.stringify(value));
      if (copy.provenance) delete copy.provenance.fetchedAt;
      return copy;
    };
    try {
      const previous = JSON.parse(fs.readFileSync(privateFile(itemPath, dir), 'utf8'));
      const text = fs.readFileSync(privateFile(path.join(dir, 'content.txt'), dir), 'utf8');
      JSON.parse(fs.readFileSync(privateFile(path.join(dir, 'governance.json'), dir), 'utf8'));
      if (!sameIdentity(previous, item) || text !== body
        || !isDeepStrictEqual(material(previous), material(stored))) {
        throw new Error('different contents for an existing source revision');
      }
    } catch (error) {
      throw new Error(`evidence conflict at ${dir}: ${error.message}`);
    }
    return { dir, itemPath, written: false };
  }

  if (fs.existsSync(itemPath)) return existing();
  if (fs.existsSync(dir) && fs.readdirSync(dir).length) throw new Error(`evidence conflict at ${dir}: incomplete revision`);
  const staging = fs.mkdtempSync(path.join(path.dirname(dir), '.evidence-'));
  try {
    writePrivateFile(path.join(staging, 'item.json'), `${JSON.stringify(stored, null, 2)}\n`);
    writePrivateFile(path.join(staging, 'content.txt'), body);
    writePrivateFile(path.join(staging, 'governance.json'), `${JSON.stringify(governance, null, 2)}\n`);
    try {
      validateDestination();
      // Remove only an empty pre-existing revision directory; rmdir cannot erase evidence.
      if (fs.existsSync(dir)) fs.rmdirSync(dir);
      fs.renameSync(staging, dir);
    } catch (error) {
      // A concurrent writer may have published this exact revision first.
      if (error.code === 'EEXIST' || error.code === 'ENOTEMPTY') return existing();
      throw error;
    }
    return { dir, itemPath, written: true };
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

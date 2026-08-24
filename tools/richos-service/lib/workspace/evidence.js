/**
 * RichOS Workspace source — the EVIDENCE ZONE writer (the system architecture §4.2).
 *
 * Raw items land here as IMMUTABLE evidence, NOT as truth (loro-architecture departure #2). This is a
 * document *evidence* store, deliberately NOT a document *dumping ground* (loro-concept "storage is not
 * memory"): the large normalized body is kept in `content.txt` (cheap to scan) out of the JSON, and
 * attachments are refs — never bulk-downloaded (§4.1 design notes).
 *
 * Layout (§4.2), mirroring `wiki/raw/meetings/` for transcripts — same discipline, different family:
 *   loro/raw/workspace/<vendor>/<source>/<safeId>/
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
import { workspaceZone } from '../config.js';

/** Make a vendor-prefixed sourceItemId safe as a single path segment (no slashes/colons/dots leading). */
export function safeId(sourceItemId) {
  return String(sourceItemId || 'unknown').replace(/[^A-Za-z0-9._-]/g, '_');
}

/** A short, filesystem-safe token for a vendor etag — the rev discriminator within an item's dir. */
export function revToken(vendorEtag) {
  const s = String(vendorEtag || 'noetag').replace(/[^A-Za-z0-9]/g, '');
  return s ? s.slice(0, 24) : 'noetag';
}

/**
 * The directory for a specific (sourceItemId, vendorEtag) evidence version.
 * @param {import('./source-item.js').SourceItem} item
 * @param {string} [zone]
 * @returns {string}
 */
export function evidenceDir(item, zone = workspaceZone()) {
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

/**
 * Write a SourceItem + its governance record into the evidence zone. IMMUTABLE by convention: if the
 * rev dir already exists (same id + etag re-observed) it is a no-op write of identical bytes — never a
 * mutation of a prior version. Large body text goes to content.txt.
 *
 * @param {import('./source-item.js').SourceItem} item
 * @param {Object} governance the §5.1 metadata record
 * @param {string} [zone]
 * @returns {{dir:string, itemPath:string, written:boolean}}
 */
export function writeEvidence(item, governance, zone = workspaceZone()) {
  const dir = evidenceDir(item, zone);
  const itemPath = path.join(dir, 'item.json');
  const alreadyThere = fs.existsSync(itemPath);
  fs.mkdirSync(dir, { recursive: true });
  // Keep the heavy body out of item.json for cheap scanning; item.json references content.txt.
  const body = item.content.text || '';
  const stored = { ...item, content: { ...item.content, text: undefined, textFile: 'content.txt' } };
  fs.writeFileSync(itemPath, `${JSON.stringify(stored, null, 2)}\n`);
  fs.writeFileSync(path.join(dir, 'content.txt'), body);
  fs.writeFileSync(path.join(dir, 'governance.json'), `${JSON.stringify(governance, null, 2)}\n`);
  return { dir, itemPath, written: !alreadyThere };
}

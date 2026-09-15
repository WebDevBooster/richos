/**
 * RichOS local service — loro entity-memory loader (the correction stage's input source).
 *
 * P4 wires the real loro-correction stage (lib/correct.js) to loro's known entities. The concrete
 * source loro provides TODAY is a curated flat file, `loro/entities.json` (Rich maintains it; see
 * loro/README.md). This module is the ONLY place that knows the file exists: it loads, validates and
 * normalizes it into the `{ entities, entitiesVersion }` shape `correct()` consumes.
 *
 * THE SEAM: when a structured, queryable loro entity memory replaces the file, only this module
 * changes — point it at the new source, keep returning `{ entities, entitiesVersion }`, and neither
 * `correct()` nor the pipeline is touched. That is why the corrector takes entity memory as a
 * parameter rather than reading a file itself.
 */

import fs from 'node:fs';
import path from 'node:path';
import { REPO_ROOT, corpusRoot, corpusRootConfigured, expand } from './config.js';

/**
 * @typedef {{
 *   canonical: string, type: string, aliases: string[], mangled: string[],
 *   fuzzy: boolean, caseSensitive: boolean, minScore: (number|null)
 * }} Entity
 */

/**
 * Resolve the entities file. Precedence: an explicit override, then the CEO's CORPUS, then the repo.
 *
 * The vocabulary is the CEO's network — his people, his customers, his aliases — and this file is
 * WRITTEN by the capture path (`lib/capture.js:110`, `:415`). On a customer install the old default
 * wrote his network's names into a clone of a publicly-shipping product repo. With a corpus
 * configured it now lives in the corpus, where `ceo/entities.json` is the one vocabulary spanning
 * every company (the loro structure notes: "the entity lexicon belongs to the CEO layer").
 *
 * The repo path survives ONLY as the in-repo dogfood case: this repository's `loro/entities.json` is
 * genuinely our own vocabulary. It is a residual, recorded in
 * the loro-corpus defects brief, 2026-08-26 — closing it fully needs first-run
 * corpus provisioning, which is a product step, not a library one.
 */
export function entitiesFilePath() {
  if (process.env.RICHOS_ENTITIES_FILE) return expand(process.env.RICHOS_ENTITIES_FILE);
  if (corpusRootConfigured()) return path.join(corpusRoot(), 'ceo', 'entities.json');
  return path.join(REPO_ROOT, 'loro', 'entities.json');
}

/**
 * Normalize a raw entities.json object into the internal `{ entities, entitiesVersion }` shape.
 * PURE (no fs) so it is node-testable with a literal object — and so an alternate loro source can
 * reuse it. Drops malformed rows rather than throwing: a bad entity must never break the pipeline.
 * @param {any} raw
 * @returns {{entities: Entity[], entitiesVersion: string|null}}
 */
export function normalizeEntities(raw) {
  const version = raw && typeof raw.version === 'string' ? raw.version : null;
  const list = Array.isArray(raw?.entities) ? raw.entities : [];
  const entities = [];
  for (const e of list) {
    const canonical = typeof e?.canonical === 'string' ? e.canonical.trim() : '';
    if (!canonical) continue; // canonical is the only required field
    entities.push({
      canonical,
      type: typeof e.type === 'string' ? e.type : 'unknown',
      aliases: Array.isArray(e.aliases) ? e.aliases.filter((a) => typeof a === 'string' && a.trim()) : [],
      mangled: Array.isArray(e.mangled) ? e.mangled.filter((m) => typeof m === 'string' && m.trim()) : [],
      fuzzy: e.fuzzy !== false, // default true
      caseSensitive: e.caseSensitive === true, // default false
      minScore: typeof e.minScore === 'number' ? e.minScore : null,
    });
  }
  return { entities, entitiesVersion: version };
}

/**
 * Load loro entity memory from disk. Missing/unreadable file is NOT an error — it yields an empty
 * memory so the pipeline runs a clean identity correction (no entities => no corrections), never a
 * crash. That keeps correction an accuracy ENHANCEMENT, never a capture/transcription dependency.
 * @param {string} [file]
 * @returns {{entities: Entity[], entitiesVersion: string|null, source: string|null}}
 */
export function loadEntityMemory(file = entitiesFilePath()) {
  try {
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    const norm = normalizeEntities(raw);
    return { ...norm, source: file };
  } catch {
    return { entities: [], entitiesVersion: null, source: null };
  }
}

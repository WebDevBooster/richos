// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
import { citationOf, sectionKey } from './coverage.js';
import { resolveCorpusRoot } from './layout.js';
import { allocateChars, allocateItems, partitionRecords, resolveCompanies } from './partition.js';
import { filterByAudience, assertAudience, assertNoScopeLeak, scopeAllowed } from './privacy.js';
import { TUNING, applyFloor, buildIndex, expandQuery, scoreRecords, selectDiverse } from './relevance.js';
import { loadCorpus } from './store.js';

const PATH_OVERRIDES = ['memoryDir', 'entitiesPath', 'wikiDir', 'pageDirs', 'recordDirs'];

function corpusFor(opts) {
  if (opts.corpus) return opts.corpus;
  const resolved = resolveCorpusRoot({
    corpus: opts.corpusRoot,
    root: opts.root,
    env: opts.env || process.env,
  });
  const load = {
    root: resolved.root,
    layout: resolved.layout,
    rootSource: resolved.rootSource,
    dogfood: resolved.dogfood,
    now: opts.now,
    sources: opts.sources,
  };
  for (const key of PATH_OVERRIDES) if (opts[key] !== undefined) load[key] = opts[key];
  return loadCorpus(load);
}

export const CONTEXT_SLICE_SCHEMA_VERSION = 1;

export const COMPILER_VERSION = '1.4.0';

export const DEFAULTS = {
  audience: 'rich',
  budgetChars: 1200,
  maxItems: 8,
  maxAvailable: 12,
  minItemChars: 200,
  maxItemCharsCap: 900,
};

export function flatten(text) {
  return String(text || '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function truncate(text, max) {
  if (max <= 0) return '';
  if (text.length <= max) return text;
  if (max <= 1) return '…';
  const cut = text.slice(0, max - 1);
  const space = cut.lastIndexOf(' ');
  return `${(space > max * 0.5 ? cut.slice(0, space) : cut).trimEnd()}…`;
}

function headingFor(topic) {
  return `COMPANY MEMORY (loro) — bearing on: ${JSON.stringify(String(topic))}`;
}

function adjacentHeadingFor(topic) {
  return (
    `COMPANY MEMORY (loro) — nothing squarely covers ${JSON.stringify(String(topic))}; ` +
    'the nearest recorded material is below. Treat it as adjacent context, NOT as an answer.'
  );
}

function emptyText(topic) {
  return (
    `COMPANY MEMORY (loro): nothing recorded bears on ${JSON.stringify(String(topic))}. ` +
    'Do not assume company facts — ask the CEO or check a live system.'
  );
}

export function renderItem(candidate, maxItemChars) {
  const rec = candidate.record;
  const label = rec.kindInferred ? `${rec.kind}?` : rec.kind;
  const head = `• [${label}] ${flatten(rec.title)}`;
  const tail = ` (ref: ${rec.id})`;
  const body = flatten(rec.text);
  const room = Math.max(0, maxItemChars - head.length - tail.length - 3);
  const shown = truncate(body, room);
  return { line: shown ? `${head} — ${shown}${tail}` : `${head}${tail}`, truncated: shown.length < body.length };
}

export function compileContext(opts) {
  const topic = String(opts.topic || '').trim();
  const audience = assertAudience(opts.audience || DEFAULTS.audience);
  const budgetChars = Math.max(0, Math.floor(opts.budgetChars ?? DEFAULTS.budgetChars));
  const maxItems = Math.max(0, Math.floor(opts.maxItems ?? DEFAULTS.maxItems));
  const maxAvailable = Math.max(0, Math.floor(opts.maxAvailable ?? DEFAULTS.maxAvailable));
  const now = typeof opts.now === 'number' ? opts.now : Date.now();
  const corpus = corpusFor({ ...opts, now });

  const notes = [];
  if (corpus.problems.length) notes.push(...corpus.problems.slice(0, 5));

  const { allowed, withheld } = filterByAudience(corpus.records, audience);
  if (withheld.length) {
    notes.push(
      `${withheld.length} record(s) withheld from this "${audience}" slice by the memory-scope wall ` +
        '(CEO-private memory never reaches a worker).',
    );
  }

  const companyIds = resolveCompanies({
    requested: opts.company,
    companies: corpus.companies || [],
    retired: corpus.retiredCompanies || [],
  });
  const laneSpecs = partitionRecords(allowed, companyIds);
  const matchedEntities = new Set();
  let ranked = laneSpecs.map((lane) => {
    const index = buildIndex(lane.records);
    const query = expandQuery(topic, corpus.entities, index);
    for (const e of query.matchedEntities) matchedEntities.add(e);
    const scored = topic ? scoreRecords({ records: lane.records, index, query, now }) : [];
    return { ...lane, index, candidates: applyFloor(scored) };
  });

  const laneCount = { requested: ranked.length };
  ranked = ranked.filter((lane) => lane.candidates.length > 0);
  laneCount.withCandidates = ranked.length;
  const itemShares = allocateItems(maxItems, ranked);
  ranked = ranked.map((lane, i) => ({ ...lane, itemSlots: itemShares[i] }));
  const starvedLanes = ranked.filter((lane) => lane.itemSlots === 0).map((lane) => lane.id);
  ranked = ranked.filter((lane) => lane.itemSlots > 0);

  for (const lane of ranked) {
    lane.selected = selectDiverse({ candidates: lane.candidates, index: lane.index, maxItems: lane.itemSlots });
  }

  const itemCharsFor = (share) =>
    Math.min(DEFAULTS.maxItemCharsCap, Math.max(DEFAULTS.minItemChars, Math.round(share / 3)));
  const globalItemChars = Math.min(
    DEFAULTS.maxItemCharsCap,
    Math.max(DEFAULTS.minItemChars, Math.round(budgetChars / 3)),
  );

  const allSelected = ranked.flatMap((lane) => lane.selected);
  const topCoverage = allSelected.length ? Math.max(...allSelected.map((c) => c.breakdown.coverage)) : 0;
  const coverageLabel = topCoverage >= TUNING.DIRECT_QUERY_COVERAGE ? 'direct' : 'adjacent';
  const heading = coverageLabel === 'direct' ? headingFor(topic) : adjacentHeadingFor(topic);
  const available = Math.max(0, budgetChars - heading.length);
  const charShares = allocateChars(available, ranked);
  const lines = [];
  const items = [];
  const laneReport = [];
  let stoppedForBudget = false;

  for (let i = 0; i < ranked.length; i += 1) {
    const lane = ranked[i];
    const share = charShares[i];
    const maxItemChars = ranked.length === 1 ? globalItemChars : itemCharsFor(share);
    let laneUsed = 0;
    let laneItems = 0;
    for (const cand of lane.selected) {
      const rendered = renderItem(cand, maxItemChars);
      if (laneUsed + 1 + rendered.line.length > share) {
        stoppedForBudget = true;
        break;
      }
      laneUsed += 1 + rendered.line.length;
      laneItems += 1;
      lines.push(rendered.line);
      const rec = cand.record;
      items.push({
        ref: rec.id,
        kind: rec.kind,
        kindInferred: rec.kindInferred,
        title: rec.title,
        scope: rec.scope,
        company: rec.company || null,
        score: Number(cand.score.toFixed(4)),
        truncated: rendered.truncated,
        provenance: rec.provenance,
        confidence: rec.confidence,
      });
    }
    laneReport.push({
      id: lane.id,
      isCeo: lane.isCeo,
      chars: share,
      itemSlots: lane.itemSlots,
      usedChars: laneUsed,
      itemsIncluded: laneItems,
      itemsConsidered: lane.candidates.length,
    });
  }
  const used = heading.length + laneReport.reduce((sum, l) => sum + l.usedChars, 0);

  const thin = items.length === 0;
  let text;
  if (thin) {
    text = truncate(emptyText(topic), budgetChars);
  } else {
    text = truncate([heading, ...lines].join('\n'), budgetChars);
  }

  const selectedRefs = new Set(items.map((i) => i.ref));
  const deepAvailable = [];
  const leftovers = ranked.map((lane) => lane.candidates.filter((c) => !selectedRefs.has(c.ref)));
  const deepest = Math.max(0, ...leftovers.map((l) => l.length));
  for (let rank = 0; rank < deepest && deepAvailable.length < maxAvailable; rank += 1) {
    for (const lane of leftovers) {
      if (deepAvailable.length >= maxAvailable) break;
      const c = lane[rank];
      if (c) deepAvailable.push({ ref: c.ref, kind: c.record.kind, title: c.record.title, company: c.record.company || null });
    }
  }
  const itemsConsidered = ranked.reduce((sum, lane) => sum + lane.candidates.length, 0);

  if (!topic) notes.push('no topic given — a context slice is always topical, so nothing was compiled.');
  if (corpus.counts.total === 0) notes.push('loro is EMPTY — no memory records, no wiki pages, no entities.');
  else if (thin) notes.push(`loro has ${corpus.counts.total} record(s) but none clear the relevance floor for this topic.`);
  if (items.some((i) => i.kindInferred)) {
    notes.push(
      'kinds marked "?" were INFERRED from prose, not declared by a promoted memory record — ' +
        'treat them as a document section, not an adjudicated claim.',
    );
  }

  const proseSections = new Set(
    corpus.records
      .filter((r) => r.provenance.source === 'wiki')
      .map((r) => sectionKey(r.provenance.path, r.provenance.anchor)),
  );
  const staleProvenance = items.filter((i) => {
    const rec = corpus.byId.get(i.ref);
    const cite = rec && citationOf(rec);
    return cite && !proseSections.has(sectionKey(cite.path, cite.anchor));
  });
  if (staleProvenance.length) {
    notes.push(
      `${staleProvenance.length} item(s) cite a page section that no longer exists ` +
        `(${staleProvenance.map((i) => i.ref).join(', ')}) — the record may describe a page that has ` +
        'since been rewritten, and its provenance link cannot be followed. Run `loro-coverage check`.',
    );
  }
  if (!thin && coverageLabel === 'adjacent') {
    notes.push(
      'ADJACENT ONLY — no record squarely covers this topic; the items are the nearest company memory ' +
        'loro holds. Do not present them as an answer to it.',
    );
  }
  if (stoppedForBudget) notes.push('slice truncated by the character budget; more relevant memory is listed in deepFetch.');

  if (laneReport.length > 1) {
    notes.push(
      `partitioned compile: ${laneReport.length} lane(s) — ` +
        `${laneReport.map((l) => `${l.id}:${l.itemsIncluded}/${l.itemSlots} items, ${l.usedChars}/${l.chars} chars`).join('; ')}. ` +
        'Each lane is ranked in its own index against its own floor, so scores are NOT comparable across lanes.',
    );
  }
  if (starvedLanes.length) {
    notes.push(
      `${starvedLanes.length} lane(s) had memory clearing their own floor but no item slot at ` +
        `--max-items ${maxItems}: ${starvedLanes.join(', ')}. Raise --max-items or narrow --company.`,
    );
  }
  const unspentChars = Math.max(0, budgetChars - used);
  if (!thin && laneReport.length > 1 && unspentChars > 0) {
    notes.push(
      `${unspentChars} char(s) of the budget are unspent: a lane's unused share is NEVER reclaimed by ` +
        'another lane, because reclaiming it would break the "a larger budget is a superset" guarantee ' +
        '(CONTEXT-CONTRACT §7.2).',
    );
  }

  const slice = {
    schemaVersion: CONTEXT_SLICE_SCHEMA_VERSION,
    compiler: `loro-context-compiler/${COMPILER_VERSION}`,
    generatedAt: new Date(now).toISOString(),
    request: { topic, audience, budgetChars, maxItems, companies: companyIds },
    corpus: {
      recordCount: corpus.counts.total,
      sources: corpus.sources,
      entitiesVersion: corpus.entitiesVersion,
      fingerprint: corpus.fingerprint,

      layout: corpus.layout || null,
      rootSource: corpus.rootSource || null,
    },
    thin,
    coverage: thin ? 'none' : coverageLabel,
    text,
    items,
    deepFetch: { verb: 'loro-context fetch --ref <ref>', available: deepAvailable },
    budget: {
      chars: budgetChars,
      usedChars: text.length,
      itemsIncluded: items.length,

      itemsConsidered,
      withheldByScope: withheld.length,

      lanes: laneReport,
      unspentChars,
    },
    matchedEntities: [...matchedEntities].sort(),
    notes,
  };

  assertNoScopeLeak(slice, audience);
  return slice;
}

export function fetchRecord(opts) {
  const audience = assertAudience(opts.audience || DEFAULTS.audience);
  const now = typeof opts.now === 'number' ? opts.now : Date.now();
  const corpus = corpusFor({ ...opts, now });
  const rec = corpus.byId.get(String(opts.ref));
  if (!rec) return { found: false, reason: `no record with ref "${opts.ref}"` };
  if (!scopeAllowed(rec.scope, audience)) {

    return { found: false, denied: true, reason: `ref "${opts.ref}" is not available to audience "${audience}"` };
  }
  return { found: true, record: rec };
}

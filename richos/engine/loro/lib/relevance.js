// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
import { authorityWeight, kindPrior } from './record.js';

export const TUNING = {
  BM25_K1: 1.2,
  BM25_B: 0.75,

  MIN_DOC_LEN: 20,
  TITLE_BONUS: 0.35,
  TITLE_BONUS_CAP: 2.4,
  PHRASE_BONUS: 1.2,
  ENTITY_BONUS: 0.5,
  ENTITY_BONUS_CAP: 1.5,
  TAG_BONUS: 0.3,
  LINK_BONUS_FRACTION: 0.12,
  LINK_TOP_K: 3,
  RECENCY_HALF_LIFE_DAYS: 540,
  RECENCY_FLOOR: 0.7,
  CONFIDENCE_FLOOR: 0.6,
  AMBIENT_DF_RATIO: 0.25,

  MIN_QUERY_COVERAGE: 0.12,
  DIRECT_QUERY_COVERAGE: 0.5,
  UNKNOWN_TERM_WEIGHT: 0.5,

  FLOOR_FRACTION: 0.15,
  MMR_LAMBDA: 0.72,
  MAX_PER_PATH: 2,
  MAX_PER_PATH_RELAXED: 3,
};

export const STOPWORDS = new Set(
  ('a an and are as at be been but by can could did do does for from had has have how i if in into is it its ' +
    'may might must no nor not of on or our ours out over should so some such than that the their them then there ' +
    'these they this those to too us was we were what when where which while who why will with would you your ' +
    'about after all also any because before between both during each few more most other own same through under up')
    .split(/\s+/),
);

export function tokenize(text) {
  return String(text || '')
    .toLowerCase()
    .split(/[^a-z0-9.+#]+/)
    .map((t) => t.replace(/^[.+#]+|[.+#]+$/g, ''))
    .filter((t) => t.length > 1 && !STOPWORDS.has(t));
}

export function normalizePhrase(text) {
  return ` ${String(text || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()} `;
}

export function buildIndex(records) {
  const docs = new Map();
  const df = new Map();
  let totalLen = 0;
  for (const rec of records) {
    const bodyTokens = tokenize(`${rec.title}\n${rec.text}`);
    const titleTokens = new Set(tokenize(rec.title));
    const tf = new Map();
    for (const t of bodyTokens) tf.set(t, (tf.get(t) || 0) + 1);
    for (const t of tf.keys()) df.set(t, (df.get(t) || 0) + 1);
    totalLen += bodyTokens.length;
    docs.set(rec.id, {
      tf,
      len: bodyTokens.length,
      titleTokens,
      phrase: normalizePhrase(`${rec.title} ${rec.text}`),
      tags: new Set(rec.tags),
    });
  }
  return { n: records.length, avgLen: records.length ? totalLen / records.length : 0, df, docs };
}

export function idf(term, index) {
  const dfv = index.df.get(term) || 0;
  return Math.log(1 + (index.n - dfv + 0.5) / (dfv + 0.5));
}

export function expandQuery(topic, entities = [], index = null) {
  const phrase = normalizePhrase(topic);
  const discriminating = (text) => {
    if (!index || !index.n) return true;
    const toks = tokenize(text);
    if (!toks.length) return false;
    return toks.some((t) => (index.df.get(t) || 0) / index.n <= TUNING.AMBIENT_DF_RATIO);
  };
  const weights = new Map();
  const add = (term, weight) => {
    if (!term || STOPWORDS.has(term)) return;
    weights.set(term, Math.max(weights.get(term) || 0, weight));
  };
  for (const t of tokenize(topic)) add(t, 1);

  const matched = [];
  for (const e of entities) {
    if (!e || typeof e.canonical !== 'string') continue;
    const forms = [e.canonical, ...(Array.isArray(e.aliases) ? e.aliases : []), ...(Array.isArray(e.mangled) ? e.mangled : [])];
    let hit = false;
    let hitForm = '';
    for (const form of forms) {
      if (typeof form !== 'string' || !form.trim()) continue;
      const needle = normalizePhrase(form).trim();
      if (needle && phrase.includes(` ${needle} `) && discriminating(form)) {
        hit = true;
        hitForm = form;
        break;
      }
    }
    if (!hit) continue;
    matched.push(e.canonical);

    for (const t of tokenize(hitForm)) {
      if (!tokenize(e.canonical).includes(t)) weights.delete(t);
    }
    for (const t of tokenize(e.canonical)) add(t, 0.9);
    for (const alias of Array.isArray(e.aliases) ? e.aliases : []) {
      for (const t of tokenize(alias)) add(t, 0.85);
    }
  }

  const terms = [...weights.entries()]
    .map(([term, weight]) => ({ term, weight }))
    .sort((a, b) => (a.term < b.term ? -1 : a.term > b.term ? 1 : 0));
  matched.sort();
  return { terms, matchedEntities: matched, phrase: phrase.trim() };
}

export function queryStats(query, index) {
  let knownMass = 0;
  let unknownMass = 0;
  const unknownTerms = [];
  for (const { term, weight } of query.terms) {
    const contribution = weight * idf(term, index);
    if ((index.df.get(term) || 0) > 0) knownMass += contribution;
    else {
      unknownMass += contribution;
      unknownTerms.push(term);
    }
  }
  const total = query.terms.length || 1;
  return {
    mass: knownMass + TUNING.UNKNOWN_TERM_WEIGHT * unknownMass,
    knownMass,
    unknownRatio: unknownTerms.length / total,
    unknownTerms,
  };
}

export function recencyFactor(rec, now) {
  if (!rec.observedAt) return 1;
  const t = Date.parse(rec.observedAt);
  if (Number.isNaN(t)) return 1;
  const ageDays = Math.max(0, (now - t) / 86400000);
  const decayed = Math.pow(0.5, ageDays / TUNING.RECENCY_HALF_LIFE_DAYS);
  return Math.max(TUNING.RECENCY_FLOOR, Math.min(1, decayed));
}

export function scoreRecords(opts) {
  const { records, index, query, now } = opts;
  const { BM25_K1: k1, BM25_B: b } = TUNING;
  const scored = [];
  const { mass: queryMass } = queryStats(query, index);

  for (const rec of records) {

    if (rec.status !== 'current') continue;
    const doc = index.docs.get(rec.id);
    if (!doc) continue;

    let bm25 = 0;
    let titleBonus = 0;
    let tagBonus = 0;
    let matchedMass = 0;
    for (const { term, weight } of query.terms) {
      const tf = doc.tf.get(term) || 0;
      const termIdf = idf(term, index);
      if (tf > 0) {
        matchedMass += weight * termIdf;
        const effectiveLen = Math.max(doc.len, TUNING.MIN_DOC_LEN);
        const denom = tf + k1 * (1 - b + (b * effectiveLen) / (index.avgLen || 1));
        bm25 += weight * termIdf * ((tf * (k1 + 1)) / denom);
        if (doc.titleTokens.has(term)) titleBonus += TUNING.TITLE_BONUS * termIdf * weight;
      }
      if (doc.tags.has(term)) tagBonus += TUNING.TAG_BONUS * weight;
    }
    if (bm25 <= 0) continue;

    const coverage = queryMass > 0 ? matchedMass / queryMass : 0;
    if (coverage < TUNING.MIN_QUERY_COVERAGE) continue;

    titleBonus = Math.min(titleBonus, TUNING.TITLE_BONUS_CAP);

    const phraseBonus =
      query.phrase && query.phrase.split(' ').length >= 2 && doc.phrase.includes(` ${query.phrase} `)
        ? TUNING.PHRASE_BONUS
        : 0;
    let entityBonus = 0;
    for (const canonical of query.matchedEntities) {
      const needle = normalizePhrase(canonical).trim();
      if (needle && doc.phrase.includes(` ${needle} `)) entityBonus += TUNING.ENTITY_BONUS;
    }
    entityBonus = Math.min(entityBonus, TUNING.ENTITY_BONUS_CAP);

    const prior = kindPrior(rec.kind);
    const authority = authorityWeight(rec.authority);
    const confidence = TUNING.CONFIDENCE_FLOOR + (1 - TUNING.CONFIDENCE_FLOOR) * rec.confidence;
    const recency = recencyFactor(rec, now);
    const base = bm25 + titleBonus + phraseBonus + entityBonus + tagBonus;

    const coverageWeight = 0.5 + 0.5 * Math.min(1, coverage);
    const score = base * prior * authority * confidence * recency * coverageWeight;

    scored.push({
      ref: rec.id,
      record: rec,
      score,
      breakdown: { bm25, coverage, coverageWeight, titleBonus, phraseBonus, entityBonus, tagBonus, prior, authority, confidence, recency, link: 0 },
    });
  }

  scored.sort((x, y) => y.score - x.score || (x.ref < y.ref ? -1 : x.ref > y.ref ? 1 : 0));

  if (scored.length) {
    const topScore = scored[0].score;
    const bonus = TUNING.LINK_BONUS_FRACTION * topScore;
    const linkTargets = new Set();
    for (const cand of scored.slice(0, TUNING.LINK_TOP_K)) {
      for (const rel of cand.record.related) linkTargets.add(rel);
    }
    if (linkTargets.size) {
      for (const cand of scored) {
        if (cand.score === topScore && cand.ref === scored[0].ref) continue;
        const linked = [...linkTargets].some((target) => cand.ref === target || cand.ref.startsWith(`${target}#`));
        if (linked) {
          cand.score += bonus;
          cand.breakdown.link = bonus;
        }
      }
      scored.sort((x, y) => y.score - x.score || (x.ref < y.ref ? -1 : x.ref > y.ref ? 1 : 0));
    }
  }

  return scored;
}

export function groupKey(rec) {
  return rec.provenance.source === 'wiki' ? rec.provenance.path || rec.id : rec.id;
}

export function similarity(docA, docB) {
  if (!docA || !docB) return 0;
  const [small, large] = docA.tf.size <= docB.tf.size ? [docA, docB] : [docB, docA];
  let dot = 0;
  for (const [term, tf] of small.tf) {
    const other = large.tf.get(term);
    if (other) dot += Math.sqrt(tf) * Math.sqrt(other);
  }
  if (dot === 0) return 0;
  let na = 0;
  let nb = 0;
  for (const tf of docA.tf.values()) na += tf;
  for (const tf of docB.tf.values()) nb += tf;
  const denom = Math.sqrt(na) * Math.sqrt(nb);
  return denom > 0 ? dot / denom : 0;
}

export function applyFloor(scored) {
  if (!scored.length) return [];
  const top = scored[0].score;
  return scored.filter((c) => c.score >= TUNING.FLOOR_FRACTION * top);
}

export function selectDiverse(opts) {
  const { candidates, index, maxItems } = opts;
  if (!candidates.length || maxItems <= 0) return [];
  const topScore = candidates[0].score || 1;
  const lambda = TUNING.MMR_LAMBDA;
  const maxPerKind = Math.max(2, Math.ceil(maxItems / 2));

  const selected = [];
  const perPath = new Map();
  const perKind = new Map();
  const taken = new Set();

  const countOf = (map, key) => map.get(key) || 0;

  for (const relaxed of [false, true]) {
    while (selected.length < maxItems) {
      let best = null;
      let bestValue = -Infinity;
      for (const cand of candidates) {
        if (taken.has(cand.ref)) continue;
        const pathCap = relaxed ? TUNING.MAX_PER_PATH_RELAXED : TUNING.MAX_PER_PATH;
        if (countOf(perPath, groupKey(cand.record)) >= pathCap) continue;
        if (!relaxed && countOf(perKind, cand.record.kind) >= maxPerKind) continue;
        const docA = index.docs.get(cand.ref);
        let maxSim = 0;
        for (const s of selected) {
          const sim = similarity(docA, index.docs.get(s.ref));
          if (sim > maxSim) maxSim = sim;
        }
        const value = lambda * (cand.score / topScore) - (1 - lambda) * maxSim;

        if (value > bestValue) {
          bestValue = value;
          best = cand;
        }
      }
      if (!best) break;
      taken.add(best.ref);
      perPath.set(groupKey(best.record), countOf(perPath, groupKey(best.record)) + 1);
      perKind.set(best.record.kind, countOf(perKind, best.record.kind) + 1);
      selected.push(best);
    }
    if (selected.length >= maxItems) break;
  }

  return selected;
}

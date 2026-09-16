// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
export const PROMOTED_SOURCES = ['memory', 'records'];

export const PROSE_SOURCE = 'wiki';

export function sectionKey(path, anchor) {
  return `${path}#${anchor || 'overview'}`;
}

export function citationOf(rec) {
  const source = rec?.provenance?.source;
  if (source === 'memory') {
    const p = rec.provenance.path || '';
    if (!p.endsWith('.md')) return null;
    return { path: p, anchor: rec.provenance.anchor || 'overview' };
  }
  if (source === 'records') {
    const ref = rec.provenance.ref || '';
    const m = /^(?:wiki:)?([^#\s]+\.md)(?:#([A-Za-z0-9_-]*))?$/.exec(ref);
    if (!m) return null;
    return { path: m[1], anchor: m[2] || 'overview' };
  }
  return null;
}

export function anchorShape(anchor) {
  return String(anchor || '').replace(/-/g, '');
}

export function sameHeadingText(a, b) {
  const x = anchorShape(a);
  const y = anchorShape(b);
  if (!x || !y) return false;
  return x.startsWith(y) || y.startsWith(x);
}

export function analyzeCoverage(records) {
  const prose = records.filter((r) => r.provenance.source === PROSE_SOURCE);
  const promoted = records.filter((r) => PROMOTED_SOURCES.includes(r.provenance.source));

  const sections = prose
    .map((r) => ({
      key: sectionKey(r.provenance.path, r.provenance.anchor),
      path: r.provenance.path || '',
      anchor: r.provenance.anchor || 'overview',
      title: r.title,
      inferredKind: r.kind,
      chars: r.text.length,
    }))
    .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

  const sectionKeys = sections.map((s) => s.key);
  const keySet = new Set(sectionKeys);
  const proseFiles = [...new Set(sections.map((s) => s.path))].sort();
  const proseFileSet = new Set(proseFiles);
  const anchorsByFile = new Map();
  for (const s of sections) {
    if (!anchorsByFile.has(s.path)) anchorsByFile.set(s.path, []);
    anchorsByFile.get(s.path).push(s.anchor);
  }

  const citedBy = new Map();
  const uncited = [];
  const driftedMap = new Map();
  const unreachableMap = new Map();

  for (const rec of promoted) {
    const cite = citationOf(rec);
    if (!cite) {
      uncited.push(rec.id);
      continue;
    }
    const key = sectionKey(cite.path, cite.anchor);
    if (keySet.has(key)) {
      if (!citedBy.has(key)) citedBy.set(key, []);
      citedBy.get(key).push(rec.id);
      continue;
    }

    const bucket = proseFileSet.has(cite.path) ? driftedMap : unreachableMap;
    if (!bucket.has(key)) bucket.set(key, { key, path: cite.path, anchor: cite.anchor, records: [] });
    bucket.get(key).records.push(rec.id);
  }

  const finish = (m) =>
    [...m.values()]
      .map((e) => ({ ...e, records: e.records.slice().sort() }))
      .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

  const covered = sectionKeys.filter((k) => citedBy.has(k));
  const uncovered = sectionKeys.filter((k) => !citedBy.has(k));
  const driftedAnchors = finish(driftedMap);
  const unreachableFiles = finish(unreachableMap);

  return {
    sections,
    sectionKeys,
    covered,
    uncovered,
    citedBy,
    driftedAnchors,
    unreachableFiles,
    uncited: uncited.sort(),
    proseFiles,
    anchorsByFile,
    totals: {
      sections: sections.length,
      promoted: promoted.length,
      covered: covered.length,
      uncovered: uncovered.length,
      driftedAnchors: driftedAnchors.length,
      unreachableFiles: unreachableFiles.length,
      uncited: uncited.length,
      danglingCitations: driftedAnchors.length + unreachableFiles.length,
    },
  };
}

export function coverageByPage(analysis) {
  const rows = new Map();
  for (const s of analysis.sections) {
    if (!rows.has(s.path)) rows.set(s.path, { path: s.path, total: 0, covered: 0, uncovered: 0 });
    const row = rows.get(s.path);
    row.total += 1;
    if (analysis.citedBy.has(s.key)) row.covered += 1;
    else row.uncovered += 1;
  }
  return [...rows.values()].sort(
    (a, b) => b.uncovered - a.uncovered || (a.path < b.path ? -1 : a.path > b.path ? 1 : 0),
  );
}

export function relinkCandidates(analysis) {
  const repairable = [];
  const unrepairable = [];
  for (const d of analysis.driftedAnchors) {
    const anchors = analysis.anchorsByFile.get(d.path) || [];
    const matches = anchors.filter((a) => sameHeadingText(d.anchor, a));
    if (matches.length === 1) {
      repairable.push({ key: d.key, path: d.path, from: d.anchor, to: matches[0], records: d.records });
    } else {
      unrepairable.push({
        ...d,
        why:
          matches.length === 0
            ? `no section on ${d.path} carries this heading text any more — the heading was rewritten or ` +
              'removed, and choosing its successor is a judgment'
            : `${matches.length} sections on ${d.path} match this anchor (${matches.join(', ')}) — an ` +
              'ambiguous pointer is never re-aimed silently',
      });
    }
  }
  for (const u of analysis.unreachableFiles) {
    unrepairable.push({
      ...u,
      why:
        `"${u.path}" is not in the compiled prose layer at all, so no anchor on it can resolve. ` +
        'Either the page belongs in the prose layer (a corpus-shape decision) or the citation ' +
        'points at the wrong file. Both are judgments.',
    });
  }
  return {
    repairable: repairable.sort((a, b) => (a.key < b.key ? -1 : 1)),
    unrepairable: unrepairable.sort((a, b) => (a.key < b.key ? -1 : 1)),
  };
}

export function candidateFor(section, text = '') {
  return {
    candidate: true,
    section: section.key,
    path: section.path,
    anchor: section.anchor,
    sourceTitle: section.title,

    kindGuess: section.inferredKind,
    kind: null,
    scope: null,
    authority: null,
    confidence: null,
    title: null,
    text: null,
    needs: ['kind', 'scope', 'authority', 'confidence', 'title', 'text'],
    why:
      'A heading cannot supply what a promotion asserts. Read the section, decide whether it holds a ' +
      'claim worth promoting, and write it with loro-write — or leave it as prose, which is a real answer.',
    excerpt: String(text).slice(0, 400),
  };
}

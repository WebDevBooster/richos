// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
import fs from 'node:fs';
import path from 'node:path';

import { parseFrontMatter } from './frontmatter.js';
import { neverWalk } from './layout.js';
import { dateFieldProblems, normalizeRecord } from './record.js';
import { assertReadPath, readSource } from './read-storage.js';

export function slugify(heading) {
  return String(heading)
    .toLowerCase()
    .replace(/[`*_[\]()]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
}

export function inferKind(heading, body) {
  const h = heading.toLowerCase();
  const t = `${h}\n${body.toLowerCase()}`;

  if (/\b(decision|decisions|decided|rejected|locked by the ceo|we chose|ruling)\b/.test(h)) return 'decision';
  if (/\((recorded|ceo,? \d{4}-\d{2}-\d{2})\)/.test(t)) return 'decision';

  if (/\b(hard rule|hard rules|never|must not|non-negotiable|invariant|constraint|forbidden|banned)\b/.test(h))
    return 'constraint';

  if (/\b(principle|principles|doctrine|thesis|mental model|philosophy|departures)\b/.test(h)) return 'principle';

  if (/\b(preference|preferences|prefers|ceo wants|house style|taste)\b/.test(h)) return 'preference';

  if (/\b(strategy|positioning|roadmap|priority|priorities|market fit|gtm|go-to-market|plan|milestone)\b/.test(h))
    return 'strategy';

  if (/\b(lesson|lessons|failure mode|failure modes|what went wrong|post-?mortem|incident|pitfall)\b/.test(h))
    return 'lesson';
  if (/\b(risk|risks|threat|exposure)\b/.test(h)) return 'risk';
  if (/\b(commitment|commitments|promised|owes|deadline)\b/.test(h)) return 'commitment';
  if (/\b(goal|goals|objective|objectives|target)\b/.test(h)) return 'goal';
  if (/\b(metric|metrics|kpi|arr|mrr|revenue)\b/.test(h)) return 'metric';
  return 'passage';
}

export function splitMarkdownSections(md) {
  const lines = String(md).split(/\r?\n/);
  let docTitle = '';
  const sections = [];
  let current = { heading: 'overview', body: [] };
  let inFence = false;

  for (const line of lines) {
    if (/^\s*```/.test(line)) inFence = !inFence;
    if (!inFence) {
      const h1 = line.match(/^#\s+(.*\S)\s*$/);
      if (h1 && !docTitle) {
        docTitle = h1[1].trim();
        continue;
      }
      const h = line.match(/^(#{2,4})\s+(.*\S)\s*$/);
      if (h) {
        sections.push(current);
        current = { heading: h[2].trim(), body: [] };
        continue;
      }
    }
    current.body.push(line);
  }
  sections.push(current);

  return sections
    .map((s) => ({ heading: s.heading, body: s.body.join('\n').trim(), docTitle }))
    .filter((s) => s.body.length > 0);
}

function listFilesRecursive(root, dir, filterFn, excludeDirs, excludeFiles = []) {
  const out = [];
  const walk = (d) => {
    if (!assertReadPath(root, d, 'directory')) return;
    let entries;
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        if (e.name.startsWith('.') || excludeDirs.includes(e.name)) continue;
        walk(p);
      } else if (filterFn(e.name) && !excludeFiles.includes(e.name)) {
        assertReadPath(root, p);
        out.push(p);
      }
    }
  };
  walk(dir);
  return out;
}

export function isCommentOnly(body) {
  return String(body).replace(/<!--[\s\S]*?-->/g, '').trim().length === 0;
}

export function pageRecords(opts) {
  const { root, now } = opts;
  const pageDirs = Array.isArray(opts.pageDirs) ? opts.pageDirs : [];
  const minChars = typeof opts.minChars === 'number' ? opts.minChars : 60;
  const notes = [];
  const records = [];
  let anyDir = false;

  for (const spec of pageDirs) {
    const dir = spec.dir;
    if (!dir || !assertReadPath(root, dir, 'directory')) continue;
    anyDir = true;
    const idBase = spec.idBase || dir;
    const privateSubdirs = Array.isArray(spec.privateSubdirs) ? spec.privateSubdirs : [];

    const files = listFilesRecursive(root, dir, (n) => n.endsWith('.md'), neverWalk(), spec.excludeFiles || []);
    for (const file of files) {
      const rel = path.relative(root, file).split(path.sep).join('/');
      const refPath = path.relative(idBase, file).split(path.sep).join('/');
      const inDir = path.relative(dir, file).split(path.sep).join('/');
      const isPrivate = privateSubdirs.some((sub) => inDir === sub || inDir.startsWith(`${sub}/`));
      let md;
      try {
        md = readSource(root, file);
      } catch (err) {
        notes.push(`unreadable page file ${rel}: ${err.message}`);
        continue;
      }
      for (const section of splitMarkdownSections(md)) {
        if (section.body.length < minChars) continue;
        if (isCommentOnly(section.body)) continue;
        const anchor = slugify(section.heading);
        const title = section.docTitle && section.heading !== 'overview'
          ? `${section.docTitle} — ${section.heading}`
          : section.docTitle || section.heading;
        records.push(
          normalizeRecord(
            {
              id: `wiki:${refPath}#${anchor}`,
              kind: inferKind(section.heading, section.body),
              kindInferred: true,
              title,
              text: section.body,

              scope: isPrivate ? 'ceo-private' : spec.defaultScope || 'org-shared',
              authority: 'self',
              confidence: 0.75,
              company: spec.company || null,
              path: rel,
              anchor,
              related: outboundLinks(section.body),
            },
            { now, source: 'wiki' },
          ),
        );
      }
    }
  }

  if (!anyDir) {
    notes.push(`no prose directory found (looked in: ${pageDirs.map((s) => s.dir).filter(Boolean).join(', ') || 'nothing'})`);
  }
  return { records, notes };
}

export function wikiRecords(opts) {
  const { wikiDir } = opts;
  if (!assertReadPath(opts.root, wikiDir, 'directory')) return { records: [], notes: [`no wiki directory at ${wikiDir}`] };
  return pageRecords({
    ...opts,
    pageDirs: [{ dir: wikiDir, idBase: wikiDir, defaultScope: 'org-shared' }],
  });
}

export function outboundLinks(body) {
  const out = [];
  for (const m of String(body).matchAll(/\]\(([A-Za-z0-9_./-]+\.md)(#[A-Za-z0-9_-]*)?\)/g)) {
    const target = m[1].replace(/^\.\//, '');
    const ref = `wiki:${target}`;
    if (!out.includes(ref)) out.push(ref);
  }
  return out;
}

export function entityRecords(opts) {
  const { entitiesPath, root, now } = opts;
  const notes = [];
  if (!assertReadPath(root, entitiesPath)) {
    return { records: [], notes: [`no entities file at ${entitiesPath}`], entitiesVersion: null, entities: [] };
  }
  let doc;
  try {
    doc = JSON.parse(readSource(root, entitiesPath));
  } catch (err) {
    return {
      records: [],
      notes: [`entities file is not valid JSON (${err.message}) — treated as empty`],
      entitiesVersion: null,
      entities: [],
    };
  }
  const entities = Array.isArray(doc.entities) ? doc.entities : [];
  const rel = path.relative(root, entitiesPath).split(path.sep).join('/');
  const records = entities
    .filter((e) => e && typeof e.canonical === 'string' && e.canonical.trim())
    .map((e) => {
      const aliases = Array.isArray(e.aliases) ? e.aliases.filter(Boolean) : [];
      const parts = [`${e.canonical} — a ${e.type || 'unknown'} this company knows.`];
      if (aliases.length) parts.push(`Also written: ${aliases.join(', ')}.`);
      return normalizeRecord(
        {
          id: `entity:${slugify(e.canonical) || e.canonical.toLowerCase()}`,
          kind: 'entity',
          title: e.canonical,
          text: parts.join(' '),
          scope: 'org-shared',
          authority: 'self',
          confidence: 0.9,
          tags: [String(e.type || 'unknown')],
          path: rel,
        },
        { now, source: 'entities' },
      );
    });
  return {
    records,
    notes,
    entitiesVersion: typeof doc.version === 'string' ? doc.version : null,
    entities,
  };
}

export function recordFileRecords(opts) {
  const { root, now } = opts;
  const recordDirs = Array.isArray(opts.recordDirs) ? opts.recordDirs : [];
  const notes = [];
  const problems = [];
  const records = [];

  for (const spec of recordDirs) {
    if (!spec || !spec.dir || !assertReadPath(root, spec.dir, 'directory')) continue;
    const idBase = spec.idBase || spec.dir;
    const files = listFilesRecursive(root, spec.dir, (n) => n.endsWith('.md'), neverWalk());
    for (const file of files) {
      const rel = path.relative(root, file).split(path.sep).join('/');
      const refPath = path.relative(idBase, file).split(path.sep).join('/').replace(/\.md$/, '');
      let text;
      try {
        text = readSource(root, file);
      } catch (err) {
        notes.push(`unreadable record file ${rel}: ${err.message}`);
        continue;
      }
      const parsed = parseFrontMatter(text);
      for (const p of parsed.fenceProblems) problems.push(`${rel}: ${p}`);
      for (const p of parsed.problems) {
        if (!parsed.fenceProblems.includes(p)) notes.push(`${rel}: ${p}`);
      }
      const fm = parsed.data;

      for (const p of dateFieldProblems(fm)) problems.push(`${rel}: ${p}`);
      const stem = path.basename(file, '.md');
      if (typeof fm.id === 'string' && fm.id && fm.id !== stem) {
        notes.push(`${rel}: front-matter id "${fm.id}" disagrees with the filename — the PATH wins (ref: rec:${refPath})`);
      }
      const body = parsed.body.trim();
      const prov = fm.provenance && typeof fm.provenance === 'object' ? fm.provenance : {};
      records.push(
        normalizeRecord(
          {
            id: `rec:${refPath}`,
            kind: fm.kind,
            title: typeof fm.title === 'string' && fm.title.trim() ? fm.title : firstLineTitle(body) || stem,
            text: body,
            scope: fm.scope,
            authority: fm.authority,
            confidence: fm.confidence,
            observedAt: fm.observedAt,
            validFrom: fm.validFrom,
            validUntil: fm.validUntil,
            supersededBy: fm.supersededBy,
            supersedes: fm.supersedes,
            tags: Array.isArray(fm.tags) ? fm.tags.map(String) : [],
            related: Array.isArray(fm.related) ? fm.related.map(String) : [],
            company: fm.company || spec.company || null,
            promotionMethod: prov.method,
            promotionRef: prov.ref,
            // The writer's own `--source-label`, carried through rather than dropped: it is what
            // lets a consumer say "from your Google Calendar" instead of only "a record".
            promotionSource: prov.source,
            path: rel,
          },
          { now, source: 'records' },
        ),
      );
    }
  }
  return { records, notes, problems };
}

export function firstLineTitle(body) {
  for (const line of String(body).split(/\r?\n/)) {
    const t = line.replace(/^#+\s*/, '').trim();
    if (t) return t.slice(0, 120);
  }
  return '';
}

export function memoryRecords(opts) {
  const { memoryDir, root, now } = opts;
  const notes = [];
  if (!assertReadPath(root, memoryDir, 'directory')) return { records: [], notes: [] };

  const records = [];
  const files = listFilesRecursive(root, memoryDir, (n) => n.endsWith('.jsonl') || n.endsWith('.json'), ['node_modules']);
  for (const file of files) {
    const rel = path.relative(root, file).split(path.sep).join('/');
    const base = path.basename(file).replace(/\.(jsonl|json)$/, '');
    let raws = [];
    let text;
    try {
      text = readSource(root, file);
    } catch (err) {
      notes.push(`unreadable memory file ${rel}: ${err.message}`);
      continue;
    }
    if (file.endsWith('.jsonl')) {
      const lines = text.split(/\r?\n/);
      for (let i = 0; i < lines.length; i += 1) {
        const line = lines[i].trim();
        if (!line || line.startsWith('//')) continue;
        try {
          raws.push(JSON.parse(line));
        } catch (err) {
          notes.push(`skipped malformed record ${rel}:${i + 1} (${err.message})`);
        }
      }
    } else {
      try {
        const doc = JSON.parse(text);
        raws = Array.isArray(doc) ? doc : Array.isArray(doc.records) ? doc.records : [];
      } catch (err) {
        notes.push(`skipped malformed memory file ${rel} (${err.message})`);
      }
    }
    for (const raw of raws) {
      if (!raw || typeof raw !== 'object') continue;
      records.push(
        normalizeRecord({ ...raw, id: raw.id ? `mem:${base}:${raw.id}` : '', path: raw.path || rel }, {
          now,
          source: 'memory',

        }),
      );
    }
  }
  return { records, notes };
}

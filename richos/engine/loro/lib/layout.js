// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
import fs from 'node:fs';
import path from 'node:path';

import { parseFrontMatterLines } from './frontmatter.js';

export const CORPUS_ENV = 'LORO_CORPUS';

export const ROOT_ENV = 'LORO_ROOT';

const NEVER_WALK = ['raw', 'node_modules'];

const CEO_WIKI_NON_MEMORY = ['000_index.md', 'zzz_log.md'];

export function repoPaths(root) {
  const manifest = companyManifests(root);
  const owners = proseOwners(manifest.manifests);
  const problems = manifest.problems.concat(owners.problems);
  const ownerOf = (rel) => owners.byPath.get(rel) || null;

  const pageDirs = [

    {
      dir: path.join(root, 'ceo', 'pages'),
      idBase: root,
      defaultScope: 'org-shared',
      privateSubdirs: ['private'],
    },

    {
      dir: path.join(root, 'wiki'),
      idBase: path.join(root, 'wiki'),
      defaultScope: 'org-shared',
      company: ownerOf('wiki'),
    },

    {
      dir: path.join(root, 'engine', 'ceo-wiki', 'wiki'),
      idBase: root,
      defaultScope: 'org-shared',
      excludeFiles: CEO_WIKI_NON_MEMORY,
      company: ownerOf('engine/ceo-wiki/wiki'),
    },
    {
      dir: path.join(root, 'richos', 'engine', 'ceo-wiki', 'wiki'),
      idBase: root,
      defaultScope: 'org-shared',
      excludeFiles: CEO_WIKI_NON_MEMORY,
      company: ownerOf('richos/engine/ceo-wiki/wiki'),
    },
  ];
  const recordDirs = [
    { dir: path.join(root, 'ceo', 'records'), idBase: root },

    { dir: path.join(root, 'ceo', 'unfiled'), idBase: root },

    { dir: path.join(root, 'loro', 'records'), idBase: root },
  ];
  for (const id of manifest.manifests.map((m) => m.id)) {
    pageDirs.push({
      dir: path.join(root, 'companies', id, 'pages'),
      idBase: root,
      defaultScope: 'org-shared',
      company: id,
    });
    recordDirs.push({ dir: path.join(root, 'companies', id, 'records'), idBase: root, company: id });
  }

  return {
    root,
    layout: 'repo',
    memoryDir: path.join(root, 'loro', 'memory'),

    entitiesPath: fs.existsSync(path.join(root, 'ceo', 'entities.json'))
      ? path.join(root, 'ceo', 'entities.json')
      : path.join(root, 'loro', 'entities.json'),

    wikiDir: path.join(root, 'wiki'),
    pageDirs,
    recordDirs,
    companies: manifest.manifests.map((m) => m.id),
    companyManifests: manifest.manifests,
    retiredCompanies: manifest.retired,
    manifestProblems: problems,
  };
}

export function proseOwners(manifests) {
  const byPath = new Map();
  const problems = [];
  for (const m of manifests) {
    for (const raw of m.pages || []) {
      const rel = String(raw).replace(/^\.\//, '').replace(/\/+$/, '');
      if (!rel || path.isAbsolute(rel) || rel.split('/').includes('..')) {
        problems.push(
          `${COMPANY_MANIFEST} for "${m.id}": pages entry "${raw}" is not a relative path inside the ` +
            'corpus — ignored. A partition may not claim prose outside the corpus root.',
        );
        continue;
      }
      if (byPath.has(rel)) {
        problems.push(
          `${COMPANY_MANIFEST} for "${m.id}": prose directory "${rel}" is already claimed by ` +
            `"${byPath.get(rel)}" — ignored. A record has ONE home company.`,
        );
        continue;
      }
      byPath.set(rel, m.id);
    }
  }
  return { byPath, problems };
}

export function listCompanies(root) {
  const dir = path.join(root, 'companies');
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries
    .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
    .map((e) => e.name)
    .sort();
}

export const COMPANY_MANIFEST = 'company.yaml';

export const DORMANT_STATUSES = ['retired', 'merged'];

export function readCompanyManifest(root, id) {
  const file = path.join(root, 'companies', id, COMPANY_MANIFEST);
  const out = { id, name: null, role: null, status: 'active', startedAt: null, mergedInto: null, pages: [], dormant: false, problems: [] };
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return out;
  }
  const { data, problems } = parseFrontMatterLines(text.split(/\r?\n/));
  for (const p of problems) out.problems.push(`${COMPANY_MANIFEST} for "${id}": ${p}`);
  const str = (v) => (typeof v === 'string' && v.trim() ? v.trim() : null);
  out.name = str(data.name);
  out.role = str(data.role);
  out.startedAt = str(data.startedAt);
  out.mergedInto = str(data.mergedInto);
  if (data.pages !== undefined && data.pages !== null) {
    const list = Array.isArray(data.pages) ? data.pages : [data.pages];
    for (const entry of list) {
      const rel = str(entry);
      if (rel) out.pages.push(rel);
      else out.problems.push(`${COMPANY_MANIFEST} for "${id}": a pages entry is not a path — ignored.`);
    }
  }
  const status = (str(data.status) || 'active').toLowerCase();
  if (status !== 'active' && !DORMANT_STATUSES.includes(status)) {
    out.problems.push(
      `${COMPANY_MANIFEST} for "${id}": unknown status "${status}" — treated as active. ` +
        `Known: active, ${DORMANT_STATUSES.join(', ')}.`,
    );
  } else {
    out.status = status;
    out.dormant = DORMANT_STATUSES.includes(status);
  }

  const declared = str(data.id);
  if (declared && declared !== id) {
    out.problems.push(
      `${COMPANY_MANIFEST} for "${id}" declares id "${declared}". The DIRECTORY is the id — a manifest ` +
        'cannot rename the partition its own records live in. Ignored.',
    );
  }
  return out;
}

export function companyManifests(root) {
  const manifests = listCompanies(root).map((id) => readCompanyManifest(root, id));
  return {
    manifests,
    retired: manifests.filter((m) => m.dormant).map((m) => m.id),
    problems: manifests.flatMap((m) => m.problems),
  };
}

export function corpusPaths(root) {
  const companies = listCompanies(root);
  const pageDirs = [
    {
      dir: path.join(root, 'ceo', 'pages'),
      idBase: root,
      defaultScope: 'org-shared',

      privateSubdirs: ['private'],
    },
  ];
  const recordDirs = [
    { dir: path.join(root, 'ceo', 'records'), idBase: root },

    { dir: path.join(root, 'ceo', 'unfiled'), idBase: root },
  ];
  for (const id of companies) {
    pageDirs.push({
      dir: path.join(root, 'companies', id, 'pages'),
      idBase: root,
      defaultScope: 'org-shared',
      company: id,
    });
    recordDirs.push({ dir: path.join(root, 'companies', id, 'records'), idBase: root, company: id });
  }
  const manifest = companyManifests(root);
  return {
    root,
    layout: 'corpus',

    memoryDir: null,
    entitiesPath: path.join(root, 'ceo', 'entities.json'),
    wikiDir: null,
    pageDirs,
    recordDirs,
    companies,
    companyManifests: manifest.manifests,
    retiredCompanies: manifest.retired,
    manifestProblems: manifest.problems,
  };
}

export function neverWalk() {
  return NEVER_WALK.slice();
}

export function isProductCheckout(dir) {
  // Recognize standalone, packaged, legacy and nested public source layouts.
  // Directory names alone are not evidence that a location contains code.
  return ['', 'loro'].some((rel) =>
    fs.existsSync(path.join(dir, rel, 'lib/store.js')) &&
    fs.existsSync(path.join(dir, rel, 'bin/loro-context.mjs'))
  ) || ['app/crates/richos-core/Cargo.toml', 'richos/app/crates/richos-core/Cargo.toml']
    .some((rel) => fs.existsSync(path.join(dir, rel)));
}

export function productCheckoutContaining(dir) {
  let d = fs.realpathSync(dir);
  for (;;) {
    if (isProductCheckout(d)) return d;
    const up = path.dirname(d);
    if (up === d) break;
    d = up;
  }
  return null;
}

export function looksLikeCorpus(dir) {
  return fs.existsSync(path.join(dir, 'ceo')) || fs.existsSync(path.join(dir, 'companies'));
}

const UNSET_MESSAGE =
  "loro corpus root: no corpus configured. The corpus is the CEO's own record and it is NEVER " +
  "inferred from the checkout this binary sits in — inferring it would compile RichOS's memory as " +
  'yours, or nothing at all, and exit 0 either way.\n' +
  `  Set one of: --corpus <dir> | ${CORPUS_ENV}=<dir>   (a provisioned corpus: ceo/ + companies/)\n` +
  `              --root <dir>   | ${ROOT_ENV}=<dir>     (in-repo dogfood: a checkout with wiki/ + loro/)`;

export function resolveCorpusRoot(opts = {}) {
  const env = opts.env || {};
  const candidates = [
    ['corpus', opts.corpus, '--corpus'],
    ['repo', opts.root, '--root'],
    ['corpus', env[CORPUS_ENV], CORPUS_ENV],
    ['repo', env[ROOT_ENV], ROOT_ENV],
  ];
  const picked = candidates.find(([, value]) => typeof value === 'string' && value.trim());
  if (!picked) throw new Error(UNSET_MESSAGE);

  const [layout, rawValue, rootSource] = picked;
  const given = path.resolve(expandHome(String(rawValue).trim()));

  const resolved = layout === 'repo' && fs.existsSync(given) ? resolveRoot(given) : given;

  if (!fs.existsSync(resolved)) {
    throw new Error(
      `loro corpus root: ${rootSource} points at "${resolved}", which does not exist. ` +
        'Refusing to compile an empty corpus that would read as an honest "loro knows nothing".',
    );
  }
  if (!fs.statSync(resolved).isDirectory()) {
    throw new Error(`loro corpus root: ${rootSource} points at "${resolved}", which is not a directory.`);
  }

  if (layout === 'corpus') {

    const product = productCheckoutContaining(resolved);
    if (product) {
      throw new Error(
        `loro corpus root: refusing a corpus inside the RichOS product repo (${product}). ` +
          "The corpus is the CEO's private record and RichOS ships publicly — a corpus in the " +
          'product repo is one commit away from being published. Put it outside the checkout ' +
          `(e.g. ~/RichOS/corpus). For the in-repo dogfood case use --root / ${ROOT_ENV}, which ` +
          'says so out loud.',
      );
    }
    if (!looksLikeCorpus(resolved)) {
      throw new Error(
        `loro corpus root: "${resolved}" is not a loro corpus — it has neither a ceo/ nor a ` +
          'companies/ directory. A corpus is provisioned, not guessed: create ceo/{pages,records} ' +
          'and companies/<id>/{pages,records} first. Refusing to compile nothing and call it success.',
      );
    }
  }

  const dogfood = layout === 'repo' && isProductCheckout(resolved);

  return { root: resolved, layout, rootSource, dogfood, companies: listCompanies(resolved) };
}

export function resolveRoot(start) {
  let dir = path.resolve(start);
  for (let i = 0; i < 12; i += 1) {
    if (fs.existsSync(path.join(dir, 'loro'))) return dir;
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  return path.resolve(start);
}

export function expandHome(p) {
  if (p === '~') return process.env.HOME || p;
  if (p.startsWith('~/') && process.env.HOME) return path.join(process.env.HOME, p.slice(2));
  return p;
}

export function pathsFor(root, layout) {
  return layout === 'corpus' ? corpusPaths(root) : repoPaths(root);
}

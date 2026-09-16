import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { compileContext } from '../lib/compile.js';
import { loadCorpus } from '../lib/store.js';

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'loro read boundaries '));
let checks = 0;
function fixture(name) {
  const root = path.join(temporary, name);
  fs.mkdirSync(path.join(root, 'ceo/pages/private'), { recursive: true });
  fs.mkdirSync(path.join(root, 'companies'));
  const privateFile = path.join(root, 'ceo/pages/private/acquisition.md');
  fs.writeFileSync(privateFile, '# Acquisition\n\nSynthetic confidential acquisition budget is forty million. These financial plans must remain private to the CEO.\n');
  return { root, privateFile };
}
function worker(root) {
  return compileContext({ corpusRoot: root, topic: 'confidential acquisition budget', audience: 'worker', budgetChars: 4000 });
}
function refused(root) {
  assert.throws(() => worker(root), /linked|single-link/);
  const result = spawnSync(process.execPath, [path.resolve(import.meta.dirname, '../bin/loro-context.mjs'),
    'compile', '--corpus', root, '--audience', 'worker', '--topic', 'confidential acquisition budget'], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.stdout.includes('forty million'));
  checks++;
}
try {
  for (const kind of ['symlink', 'hardlink']) {
    const { root, privateFile } = fixture(kind);
    assert.deepEqual(worker(root).items, []);
    const alias = path.join(root, 'ceo/pages/budget.md');
    if (kind === 'symlink') fs.symlinkSync(privateFile, alias);
    else fs.linkSync(privateFile, alias);
    refused(root);
  }
  for (const destination of ['private-directory', 'foreign-company', 'outside-corpus', 'dangling']) {
    const { root, privateFile } = fixture(destination);
    const shared = path.join(root, 'companies/beta/pages');
    fs.mkdirSync(path.dirname(shared), { recursive: true });
    let target = path.dirname(privateFile);
    if (destination === 'foreign-company') {
      target = path.join(root, 'companies/alpha/pages');
      fs.mkdirSync(target, { recursive: true });
      fs.copyFileSync(privateFile, path.join(target, 'budget.md'));
    } else if (destination === 'outside-corpus') {
      target = path.join(temporary, 'external'); fs.mkdirSync(target);
      fs.copyFileSync(privateFile, path.join(target, 'budget.md'));
    } else if (destination === 'dangling') target = path.join(temporary, 'missing');
    fs.symlinkSync(target, shared);
    refused(root);
  }
  for (const rel of ['ceo/entities.json', 'ceo/records/budget.md', 'companies/alpha/company.yaml']) {
    const { root, privateFile } = fixture(rel.replaceAll('/', '-'));
    const alias = path.join(root, rel); fs.mkdirSync(path.dirname(alias), { recursive: true });
    fs.symlinkSync(privateFile, alias);
    assert.throws(() => loadCorpus({ root, layout: 'corpus' }), /linked/);
    checks++;
  }
  const { root } = fixture('safe-root-alias');
  const alias = path.join(temporary, 'root-alias'); fs.symlinkSync(root, alias);
  assert.deepEqual(worker(alias).items, []);
  assert.ok(compileContext({ corpusRoot: alias, topic: 'confidential acquisition budget', audience: 'rich', budgetChars: 4000 }).text.includes('forty million'));
  checks++;
  console.log(`Loro reader boundaries: ${checks} checks passed`);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

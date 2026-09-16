import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { loadCorpus } from '../lib/store.js';
import { writeBaseline, applyRelinks } from '../writer/coverage-write.js';

const cli = fileURLToPath(new URL('../bin/loro-write.mjs', import.meta.url));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'loro write boundary '));
const record = '---\nid: original\nkind: fact\nscope: ceo-private\n---\n\nSYNTHETIC PRIVATE MEMORY\n';
let checks = 0;
function fixture(name) {
  const base = path.join(temporary, name);
  const root = path.join(base, 'corpus');
  const outside = path.join(base, 'outside');
  fs.mkdirSync(path.join(root, 'ceo/records'), { recursive: true });
  fs.mkdirSync(outside, { recursive: true });
  const sentinel = path.join(outside, 'sentinel.md');
  fs.writeFileSync(sentinel, record);
  return { root, outside, sentinel, output: path.join(root, 'ceo/records/original.md'),
    corpusRoot: { root, layout: 'corpus', companies: [] } };
}
function invoke(root, args) {
  return spawnSync(process.execPath, [cli, ...args, '--corpus', root, '--json'], { encoding: 'utf8' });
}
function refused(f, args) {
  const result = invoke(f.root, args);
  assert.notEqual(result.status, 0, JSON.stringify(result));
  assert.match(result.stderr, /linked|single-link|product repo/);
  assert.equal(fs.readFileSync(f.sentinel, 'utf8'), record);
  checks++;
}
const append = ['append', '--id', 'new', '--kind', 'fact', '--body', 'PRIVATE CORRECTION'];
const supersede = ['supersede', '--ref', 'rec:ceo/records/original', '--id', 'new', '--kind', 'fact',
  '--body', 'PRIVATE CORRECTION', '--why', 'Synthetic correction'];
try {
  const f = fixture('linked-records-directory');
  fs.rmdirSync(path.join(f.root, 'ceo/records'));
  fs.symlinkSync(f.outside, path.join(f.root, 'ceo/records'));
  refused(f, append);
  assert.deepEqual(fs.readdirSync(f.outside), ['sentinel.md']);

  for (const link of ['symlink', 'hardlink']) {
    for (const operation of ['correct', 'supersede']) {
      const f = fixture(`${operation}-${link}`);
      if (link === 'symlink') fs.symlinkSync(f.sentinel, f.output);
      else fs.linkSync(f.sentinel, f.output);
      refused(f, operation === 'correct'
        ? ['correct', '--ref', 'rec:ceo/records/original', '--body', 'PRIVATE CORRECTION', '--why', 'Synthetic correction']
        : supersede);
      assert.equal(fs.existsSync(path.join(f.root, 'ceo/records/new.md')), false, 'preflight must precede either supersession write');
    }
  }
  for (const operation of ['append', 'supersede']) {
    const f = fixture(`${operation}-dangling-leaf`);
    fs.writeFileSync(f.output, record);
    fs.symlinkSync(path.join(f.outside, 'new.md'), path.join(f.root, 'ceo/records/new.md'));
    refused(f, operation === 'append' ? append : supersede);
    assert.equal(fs.existsSync(path.join(f.outside, 'new.md')), false);
    assert.equal(fs.readFileSync(f.output, 'utf8'), record);
  }
  {
    const f = fixture('company-linked-parent');
    fs.symlinkSync(f.outside, path.join(f.root, 'companies'));
    refused(f, ['create-company', '--id', 'alpha']);
    assert.equal(fs.existsSync(path.join(f.outside, 'alpha')), false);
  }
  for (const link of ['directory', 'hardlink']) {
    const f = fixture(`baseline-${link}`);
    if (link === 'directory') fs.symlinkSync(f.outside, path.join(f.root, 'state'));
    else {
      fs.mkdirSync(path.join(f.root, 'state'));
      fs.linkSync(f.sentinel, path.join(f.root, 'state/coverage-baseline.json'));
    }
    assert.throws(() => writeBaseline(f.corpusRoot, { unreachableFiles: [], uncovered: [], totals: {} }), /linked|single-link/);
    assert.equal(fs.readFileSync(f.sentinel, 'utf8'), record);
    checks++;
  }
  {
    const f = fixture('relink-hardlink');
    fs.mkdirSync(path.join(f.root, 'loro/memory'), { recursive: true });
    const memory = path.join(f.outside, 'company.jsonl');
    const original = JSON.stringify({ id: 'x', kind: 'fact', text: 'Fictional citation.', path: 'wiki/source.md', anchor: 'old' }) + '\n';
    fs.writeFileSync(memory, original);
    fs.linkSync(memory, path.join(f.root, 'loro/memory/company.jsonl'));
    const corpusRoot = { root: f.root, layout: 'repo' };
    assert.throws(() => applyRelinks(corpusRoot, loadCorpus(corpusRoot), [{ records: ['mem:company:x'], to: 'new' }]), /single-link/);
    assert.equal(fs.readFileSync(memory, 'utf8'), original);
    checks++;
  }
  {
    const f = fixture('nested-product');
    fs.mkdirSync(path.join(f.root, 'ceo/records/richos/app/crates/richos-core'), { recursive: true });
    fs.writeFileSync(path.join(f.root, 'ceo/records/richos/app/crates/richos-core/Cargo.toml'), '[package]\n');
    refused(f, append);
  }
  {
    const f = fixture('safe-root-alias');
    const alias = path.join(path.dirname(f.root), 'alias');
    fs.symlinkSync(f.root, alias);
    const preview = invoke(alias, [...append, '--dry-run']);
    assert.equal(preview.status, 0, preview.stderr);
    assert.equal(fs.existsSync(path.join(f.root, 'ceo/records/new.md')), false);
    const result = invoke(alias, append);
    assert.equal(result.status, 0, result.stderr);
    const output = path.join(f.root, 'ceo/records/new.md');
    assert.match(fs.readFileSync(output, 'utf8'), /PRIVATE CORRECTION/);
    assert.equal(fs.statSync(output).mode & 0o777, 0o600);
    assert.equal(fs.statSync(output).nlink, 1);
    assert.deepEqual(fs.readdirSync(path.dirname(output)), ['new.md']);
    const before = fs.readFileSync(output, 'utf8');
    assert.notEqual(invoke(alias, append).status, 0);
    assert.equal(fs.readFileSync(output, 'utf8'), before);
    checks++;
  }
  console.log(`Loro writer boundaries: ${checks} checks passed`);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

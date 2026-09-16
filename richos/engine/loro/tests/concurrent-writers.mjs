import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { withWriteLock } from '../writer/storage.js';
import { appendRecord, correctRecord } from '../writer/writer.js';
import { loadCorpus } from '../lib/store.js';

const cli = path.resolve(import.meta.dirname, '../bin/loro-write.mjs');
if (process.argv[2] === 'writer') {
  // Observe the real CLI after it loaded its corpus and before it receives the
  // body. The filesystem read itself is unchanged.
  const original = fs.readFileSync;
  fs.readFileSync = function (file, ...args) {
    if (file === 0) process.stderr.write('BODY_READY\n');
    return original.call(this, file, ...args);
  };
  process.argv = [process.argv[0], cli, ...process.argv.slice(3)];
  await import(cli);
} else if (process.argv[2] === 'hold') {
  process.stdout.write('STARTING\n');
  withWriteLock({ root: process.argv[3], layout: 'corpus' }, () => {
    process.stdout.write('LOCKED\n');
    fs.readFileSync(0);
  });
} else {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'loro concurrent writers '));
  const root = path.join(directory, 'corpus');
  fs.mkdirSync(path.join(root, 'ceo/records'), { recursive: true });
  fs.mkdirSync(path.join(root, 'companies'));
  const corpusRoot = { root, layout: 'corpus' };
  const children = [];
  function launch(args) {
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), ...args]);
    const item = { child, stdout: '', stderr: '', finished: false };
    child.stdout.on('data', (b) => { item.stdout += b; });
    child.stderr.on('data', (b) => { item.stderr += b; });
    item.done = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', (code) => { item.finished = true; resolve(code); });
    });
    children.push(item);
    return item;
  }
  async function marker(item, text) {
    const deadline = Date.now() + 10000;
    while (!item.stdout.includes(text) && !item.stderr.includes(text)) {
      if (item.finished || Date.now() > deadline) throw new Error(`missing ${text}: ${item.stderr}`);
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
  function writer(id, verb = 'supersede') {
    const args = ['writer', verb, '--corpus', root, '--id', id, '--kind', 'fact', '--body-stdin', '--json'];
    if (verb === 'supersede') args.push('--ref', 'rec:ceo/records/original', '--why', 'Synthetic correction');
    return launch(args);
  }
  try {
    const options = { corpusRoot, kind: 'fact', now: Date.now() };
    appendRecord({ ...options, id: 'original', body: 'Synthetic acquisition budget is forty million.' });
    const first = writer('replacement-one'); const second = writer('replacement-two');
    await Promise.all([marker(first, 'BODY_READY'), marker(second, 'BODY_READY')]);
    first.child.stdin.end('Synthetic acquisition budget is fifty million.');
    assert.equal(await first.done, 0, first.stderr);
    second.child.stdin.end('Synthetic acquisition budget is sixty million.');
    assert.equal(await second.done, 5, second.stderr);
    assert.match(second.stderr, /already superseded/);
    const corpus = loadCorpus(corpusRoot);
    assert.equal(corpus.records.filter((r) => !r.supersededBy).length, 1);
    assert.ok(!fs.existsSync(path.join(root, 'ceo/records/replacement-two.md')));

    // Correct must also reload its scope before making a widening decision.
    appendRecord({ ...options, id: 'scope', scope: 'org-shared', body: 'Synthetic budget.' });
    const stale = loadCorpus(corpusRoot);
    const correction = { ...options, corpus: stale, ref: 'rec:ceo/records/scope', why: 'Synthetic scope correction' };
    correctRecord({ ...correction, scope: 'ceo-private' });
    assert.throws(() => correctRecord({ ...correction, scope: 'org-shared' }), /refusing to widen/);

    // Two different root spellings still share the same process lock.
    const alias = path.join(directory, 'alias'); fs.symlinkSync(root, alias);
    const holder = launch(['hold', root]); await marker(holder, 'LOCKED');
    const waiting = launch(['hold', alias]); await marker(waiting, 'STARTING');
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.ok(!waiting.stdout.includes('LOCKED'));
    holder.child.stdin.end(); assert.equal(await holder.done, 0, holder.stderr);
    await marker(waiting, 'LOCKED');
    waiting.child.stdin.end(); assert.equal(await waiting.done, 0, waiting.stderr);

    // Contention is bounded, and an abruptly killed owner leaves no stale lock.
    const killed = launch(['hold', root]); await marker(killed, 'LOCKED');
    const blocked = writer('after-crash', 'append'); await marker(blocked, 'BODY_READY');
    blocked.child.stdin.end('Synthetic durable result.');
    assert.equal(await blocked.done, 5, blocked.stderr);
    assert.match(blocked.stderr, /another corpus writer/);
    assert.ok(!fs.existsSync(path.join(root, 'ceo/records/after-crash.md')));
    killed.child.kill('SIGKILL'); await killed.done;
    appendRecord({ ...options, id: 'after-crash', body: 'Synthetic durable result.' });
    assert.ok(fs.existsSync(path.join(root, 'ceo/records/after-crash.md')));

    const previewRoot = path.join(directory, 'preview'); fs.mkdirSync(previewRoot);
    appendRecord({ ...options, corpusRoot: { root: previewRoot, layout: 'corpus' }, id: 'preview', body: 'Preview only.', dryRun: true });
    assert.deepEqual(fs.readdirSync(previewRoot), []);

    const protectedFile = path.join(directory, 'protected'); fs.writeFileSync(protectedFile, 'sentinel');
    for (const suffix of ['-journal', '-wal', '-shm']) {
      const linked = path.join(root, 'state', 'writer-lock.sqlite' + suffix);
      fs.symlinkSync(protectedFile, linked);
      assert.throws(() => appendRecord({ ...options, id: 'linked', body: 'Refused.' }), /linked/);
      assert.equal(fs.readFileSync(protectedFile, 'utf8'), 'sentinel');
      fs.unlinkSync(linked);
    }
    console.log('Loro concurrent writers: overlapping replacements, stale scope, shared aliases, bounded contention, crash release, dry runs and linked sidecars passed');
  } finally {
    for (const item of children) if (!item.finished) item.child.kill('SIGKILL');
    await Promise.allSettled(children.map((item) => item.done));
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

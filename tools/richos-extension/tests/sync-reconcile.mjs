#!/usr/bin/env node
/**
 * RichOS extension — sync reconciliation test (real CLI, real files on disk, no browser).
 *
 *   node tests/sync-reconcile.mjs
 *
 * Proves the never-silent doctrine end to end through the actual `richos-sync.mjs` process:
 *   · a captions-only session (captions present, NO audio) is FLAGGED, left in place, exit 2;
 *   · a clean audio session (with captions) is moved and reported complete, exit 0.
 *
 * This is the "a call happened and we may not have it" tripwire, exercised against the shipping
 * script rather than a mock.
 */

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SYNC = path.join(HERE, '..', 'sync', 'richos-sync.mjs');

let failures = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? '  ok  ' : 'FAIL  '}${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures += 1;
}

function makeSession(dir, { name, record, audioBytes = 0, captionLines = 0 }) {
  const sessionDir = path.join(dir, name);
  fs.mkdirSync(sessionDir, { recursive: true });
  fs.writeFileSync(path.join(sessionDir, 'session.json'), JSON.stringify(record, null, 2));
  if (audioBytes > 0) fs.writeFileSync(path.join(sessionDir, 'audio-part-00.webm'), Buffer.alloc(audioBytes, 1));
  if (captionLines > 0) {
    const lines = Array.from({ length: captionLines }, (_, i) => JSON.stringify({ speaker: 'Ada', text: `line ${i}`, t: 1700000000000 + i, revision: 1 }));
    fs.writeFileSync(path.join(sessionDir, 'captions.ndjson'), lines.join('\n'));
  }
  return sessionDir;
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-sync-'));
const fromDir = path.join(work, 'drop');
const toDir = path.join(work, 'loro');
fs.mkdirSync(fromDir, { recursive: true });

// 1) Captions-only session: captions present, no audio at all.
makeSession(fromDir, {
  name: '2026-08-23T10-00-00Z--meet--captions-only',
  audioBytes: 0,
  captionLines: 12,
  record: {
    status: 'closed',
    mode: 'captions-only',
    audio: { parts: [], bytesTotal: 0, chunkCount: 0 },
    captions: { available: true, count: 12, degraded: false },
    verification: { ok: false, problems: ['captions were captured (12) but NO audio'] },
    health: { redSeconds: 30 },
  },
});

// 2) Clean audio session WITH captions.
makeSession(fromDir, {
  name: '2026-08-23T11-00-00Z--meet--full',
  audioBytes: 2_000_000,
  captionLines: 40,
  record: {
    status: 'closed',
    mode: 'full',
    audio: { parts: [{ part: 0, bytes: 2_000_000, chunks: 100 }], bytesTotal: 2_000_000, chunkCount: 100 },
    captions: { available: true, count: 40, degraded: false },
    verification: { ok: true, problems: [] },
    health: { redSeconds: 0 },
  },
});

const run = spawnSync('node', [SYNC, '--to', toDir, '--from', fromDir], { encoding: 'utf8' });
const out = `${run.stdout || ''}${run.stderr || ''}`;
console.log(out.trim());

check('the sync process exits non-zero when an anomaly is present', run.status === 2, `exit ${run.status}`);
check('the captions-only session is reported as an anomaly', /captions-only/.test(out) && /NO audio/.test(out), 'anomaly section present');
check(
  'the captions-only session is LEFT IN PLACE (never silently moved)',
  fs.existsSync(path.join(fromDir, '2026-08-23T10-00-00Z--meet--captions-only', 'session.json')),
  'still in the drop folder',
);
check(
  'the clean audio session (with captions) was moved to the destination',
  fs.existsSync(path.join(toDir, '2026-08-23T11-00-00Z--meet--full', 'audio-part-00.webm')) &&
    fs.existsSync(path.join(toDir, '2026-08-23T11-00-00Z--meet--full', 'captions.ndjson')),
  'audio + captions landed in loro',
);

fs.rmSync(work, { recursive: true, force: true });
console.log(`\n${failures === 0 ? 'all sync-reconcile checks passed' : `${failures} FAILED`}`);
process.exit(failures ? 1 : 0);

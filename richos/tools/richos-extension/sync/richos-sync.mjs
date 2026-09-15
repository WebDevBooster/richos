#!/usr/bin/env node
/**
 * RichOS — drop-zone sync helper (cross-platform: macOS, Windows, Linux).
 *
 *   node sync/richos-sync.mjs --to <loro-raw-meetings-dir> [--from <drop-folder>] [--dry-run]
 *   node sync/richos-sync.mjs --to ~/richos/wiki/raw/meetings --purge-after 30
 *
 * The extension can only write inside Chrome's downloads folder (a browser security
 * boundary). This moves finished sessions from there into loro's meetings folder, and —
 * more importantly — REPORTS ANOMALIES rather than silently tidying up:
 *
 *   · a session still marked `open`               → the call ended without closing cleanly
 *   · a session with no audio, or implausibly little for its length
 *   · a session whose own verification says `ok: false`
 *
 * Those are the "a call happened and we may not have it" cases. They are printed loudly,
 * exit code 2, and are never moved without `--force`.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { analyzeSession } from './reconcile.js';

function arg(name, fallback = null) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) return fallback;
  const value = process.argv[index + 1];
  return value && !value.startsWith('--') ? value : true;
}

const DRY_RUN = Boolean(arg('dry-run', false));
const FORCE = Boolean(arg('force', false));
const PURGE_AFTER_DAYS = Number(arg('purge-after', 0)) || 0;

function expand(p) {
  if (!p) return p;
  return p.startsWith('~') ? path.join(os.homedir(), p.slice(1)) : path.resolve(p);
}

/** Chrome's default downloads folder on every platform it runs on. */
function defaultDownloads() {
  return path.join(os.homedir(), 'Downloads');
}

const fromRoot = expand(arg('from') || path.join(defaultDownloads(), 'richos-capture'));
const toRoot = expand(arg('to'));

if (!toRoot || toRoot === true) {
  console.error('usage: node sync/richos-sync.mjs --to <destination> [--from <drop folder>] [--dry-run] [--force] [--purge-after <days>]');
  process.exit(1);
}
if (!fs.existsSync(fromRoot)) {
  console.error(`nothing to sync: ${fromRoot} does not exist`);
  process.exit(0);
}

const sessions = fs
  .readdirSync(fromRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

let moved = 0;
const anomalies = [];

for (const dir of sessions) {
  const sourceDir = path.join(fromRoot, dir);
  const sessionFile = path.join(sourceDir, 'session.json');
  /** @type {any} */
  let record = null;
  try {
    record = JSON.parse(fs.readFileSync(sessionFile, 'utf8'));
  } catch {
    anomalies.push({ dir, problems: ['no readable session.json — the session never even started cleanly'] });
    continue;
  }

  const audioOnDisk = fs
    .readdirSync(sourceDir)
    .filter((f) => f.endsWith('.webm'))
    .reduce((sum, f) => sum + fs.statSync(path.join(sourceDir, f)).size, 0);

  const { problems } = analyzeSession({ record, audioBytesOnDisk: audioOnDisk });

  if (problems.length) anomalies.push({ dir, problems });
  if (problems.length && !FORCE) continue;

  const targetDir = path.join(toRoot, dir);
  if (fs.existsSync(targetDir)) {
    console.log(`skip   ${dir} (already in the destination)`);
    continue;
  }
  console.log(`${DRY_RUN ? 'would move' : 'move  '} ${dir} → ${targetDir}  (${(audioOnDisk / 1048576).toFixed(1)} MB)`);
  if (!DRY_RUN) {
    fs.mkdirSync(path.dirname(targetDir), { recursive: true });
    try {
      fs.renameSync(sourceDir, targetDir);
    } catch {
      // Cross-device move (downloads on another volume): copy then remove.
      fs.cpSync(sourceDir, targetDir, { recursive: true });
      fs.rmSync(sourceDir, { recursive: true, force: true });
    }
    moved += 1;
  }
}

// Retention: only ever purge audio, never the transcript/session record, and only once a
// transcript exists next to it.
if (PURGE_AFTER_DAYS > 0 && fs.existsSync(toRoot)) {
  const cutoff = Date.now() - PURGE_AFTER_DAYS * 86400000;
  for (const dir of fs.readdirSync(toRoot)) {
    const sessionDir = path.join(toRoot, dir);
    if (!fs.statSync(sessionDir).isDirectory()) continue;
    const files = fs.readdirSync(sessionDir);
    const hasTranscript = files.some((f) => f === 'transcript.md');
    if (!hasTranscript) continue;
    for (const file of files.filter((f) => f.endsWith('.webm'))) {
      const full = path.join(sessionDir, file);
      if (fs.statSync(full).mtimeMs < cutoff) {
        console.log(`${DRY_RUN ? 'would purge' : 'purge '} ${path.join(dir, file)} (transcript exists, older than ${PURGE_AFTER_DAYS} days)`);
        if (!DRY_RUN) fs.rmSync(full);
      }
    }
  }
}

console.log(`\n${moved} session(s) moved.`);
if (anomalies.length) {
  console.log('\nANOMALIES — these sessions may not hold the call:');
  for (const a of anomalies) console.log(`  ${a.dir}\n    - ${a.problems.join('\n    - ')}`);
  console.log('\nLeft in place. Investigate, then re-run with --force to move them anyway.');
  process.exit(2);
}

#!/usr/bin/env node
/**
 * RichOS local service — coordination END-TO-END (real CLI + real drop zone on disk).
 *
 *   node test/coordination-e2e.mjs
 *
 * Proves the two P4 coordination guarantees on THIS machine, deterministically, with no browser and
 * no TCC/audio grant — by driving the SAME shared code paths the real surfaces use:
 *
 *   A. NO DOUBLE-CAPTURE — the extension (via the real SessionSink) owns a live browser call; a
 *      companion asks the shared authority (`richos-service claim`, disk-backed) and is told to
 *      STAND DOWN. Exactly ONE session directory exists for the call.
 *   B. BROWSER-CRASH FAILOVER — the host finalizes the extension session `interrupted` + promotable
 *      on pipe EOF; the companion polls (`richos-service failover-scan`), sees the candidate,
 *      promotes with `ownership.supersedes`, and marks the dead one superseded (`mark-superseded`).
 *
 * Surface-agnostic by construction: the companion side is exercised purely through the shared CLI +
 * the frozen contract fields, so the Windows companion plugs in with no change here.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { SessionSink } from '../lib/host-handlers.js';
import { CAPTURE_SOURCE } from '../lib/contract.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(HERE, '..', 'bin', 'richos-service.js');
const T0 = 2_100_000_000_000;

let failures = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? '  ok  ' : 'FAIL  '}${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures += 1;
}

/** Run the CLI; return { code, out } (never throws on a non-zero exit — the code is a signal here). */
function cli(args, zone) {
  try {
    const out = execFileSync(process.execPath, [CLI, ...args, '--zone', zone], { encoding: 'utf8', env: { ...process.env, RICHOS_LOG_LEVEL: 'error' } });
    return { code: 0, out };
  } catch (err) {
    return { code: err.status ?? 1, out: `${err.stdout || ''}${err.stderr || ''}` };
  }
}

const zone = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-coord-'));
console.log(`drop zone: ${zone}\n`);

// ============================================================================================
// A. NO DOUBLE-CAPTURE — extension owns the live browser call; companion must stand down.
// ============================================================================================
console.log('--- A. ownership handshake: exactly one session per call ---');

const sink = new SessionSink(zone);
const extId = '2026-08-24T13-00-00Z--meet--coord';
// The extension arms a browser-tab call and declares ownership (browser process = "Google Chrome").
sink.handle(
  {
    type: 'session-start',
    record: {
      schemaVersion: 1, sessionId: extId, dir: extId, status: 'open', startedAt: T0,
      platform: { id: 'meet', label: 'Google Meet', slug: 'coord' },
      capture: { source: CAPTURE_SOURCE.extension, captureTarget: 'tab' },
      ownership: { ownerSurface: CAPTURE_SOURCE.extension, supersedes: null, processHint: 'Google Chrome' },
      audio: { parts: [], bytesTotal: 0 }, captions: { count: 3 },
    },
  },
  T0,
);
// A fresh heartbeat lands on disk (health.ndjson) so the call reads as LIVE to the claim authority.
sink.handle({ type: 'health', sessionId: extId, line: { t: T0 + 500, level: 'green' } }, T0 + 500);

check('extension session directory exists (the browser call is being captured)', fs.existsSync(path.join(zone, extId, 'session.json')));

// The companion (all-system capture) asks the SHARED authority whether it may also capture.
const claim = cli(['claim', '--surface', 'desktop-companion-macos', '--kind', 'system', '--session-id', 'mac-coord-1'], zone);
const claimJson = JSON.parse(claim.out);
check('companion is told to STAND DOWN (extension already owns the browser call)', claimJson.decision === 'stand-down', claimJson.decision);
check('claim exit code signals stand-down (3)', claim.code === 3, `code=${claim.code}`);
check('stand-down names the conflicting session + the browser process to exclude', claimJson.conflictSessionId === extId && claimJson.excludeProcessHint === 'Google Chrome');

// Because the companion stood down, it created NO session — exactly one directory exists for the call.
const dirsAfter = fs.readdirSync(zone, { withFileTypes: true }).filter((e) => e.isDirectory());
check('exactly ONE session directory exists — no double-capture', dirsAfter.length === 1, `dirs=${dirsAfter.map((d) => d.name).join(', ')}`);

// Sanity: a companion capturing a DIFFERENT app (a desktop Zoom call) is NOT blocked.
const claimZoom = cli(['claim', '--surface', 'desktop-companion-macos', '--kind', 'process', '--process-hint', 'zoom.us', '--session-id', 'mac-zoom'], zone);
check('companion may OWN a desktop-app call the extension is not capturing', JSON.parse(claimZoom.out).decision === 'own' && claimZoom.code === 0);

// ============================================================================================
// B. BROWSER-CRASH FAILOVER — companion promotes to become the authoritative record.
// ============================================================================================
console.log('\n--- B. browser-crash failover promotion ---');

// The browser dies mid-call: the native host finalizes every open session on pipe EOF.
const finalized = sink.finalizeOnEof(T0 + 8000);
check('host finalized the extension session INTERRUPTED on pipe EOF (a lost call is present on disk)', finalized.includes(extId));
const deadRec = JSON.parse(fs.readFileSync(path.join(zone, extId, 'session.json'), 'utf8'));
check('the interrupted session is marked PROMOTABLE on disk', deadRec.status === 'interrupted' && deadRec.ownership.promotable === true);

// The companion polls the shared authority and sees the failover candidate.
const scan = JSON.parse(cli(['failover-scan'], zone).out);
check('failover-scan surfaces the dead browser call as a promotion candidate', scan.candidates.some((c) => c.sessionId === extId), JSON.stringify(scan.candidates.map((c) => c.sessionId)));

// The companion PROMOTES: it starts a system-capture session that supersedes the dead one (this is
// exactly the ownership block coordination.buildPromotionOwnership produces + SessionContract.swift
// writes; here we write the same shape to prove the loop closes on disk).
const promoId = '2026-08-24T13-00-08Z--system--coord-failover';
fs.mkdirSync(path.join(zone, promoId), { recursive: true });
fs.writeFileSync(
  path.join(zone, promoId, 'session.json'),
  `${JSON.stringify({
    schemaVersion: 2, sessionId: promoId, dir: promoId, status: 'open', startedAt: T0 + 8000,
    capture: { source: CAPTURE_SOURCE.macos, captureTarget: 'system' },
    ownership: { ownerSurface: CAPTURE_SOURCE.macos, supersedes: extId, processHint: null },
    audio: { parts: [], bytesTotal: 0 }, captions: { count: 0 },
  }, null, 2)}\n`,
);
const superseded = cli(['mark-superseded', '--dead', extId, '--by', promoId], zone);
check('mark-superseded records the takeover on the dead session', JSON.parse(superseded.out).marked === true && superseded.code === 0);

// The call keeps a live authoritative record (the companion), and the dead one no longer promotes.
const scan2 = JSON.parse(cli(['failover-scan'], zone).out);
check('the superseded session is no longer a promotion candidate (failover is complete)', !scan2.candidates.some((c) => c.sessionId === extId));
const promoRec = JSON.parse(fs.readFileSync(path.join(zone, promoId, 'session.json'), 'utf8'));
check('the companion session is the authoritative record and supersedes the dead browser call', promoRec.ownership.supersedes === extId);

console.log(`\n(drop zone kept at ${zone})`);
console.log(`\n${failures === 0 ? 'ALL COORDINATION-E2E CHECKS PASSED' : `${failures} COORDINATION-E2E CHECK(S) FAILED`}`);
process.exit(failures ? 1 : 0);

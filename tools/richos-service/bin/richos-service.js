#!/usr/bin/env node
/**
 * RichOS local service — CLI.
 *
 *   richos-service watch                 # run the drop-zone watcher (pipeline trigger + reconcile net)
 *   richos-service run <sessionId|dir>   # run the pipeline over one session
 *   richos-service retranscribe <id> [--model large-v3]   # re-run stages 2-6 on retained audio
 *   richos-service reconcile             # report-only sweep (never transcribes) — the anomaly audit
 *   richos-service claim ...             # coordination (§5.4): own this call or stand down (no double)
 *   richos-service failover-scan         # browser-owned calls that went dark -> promotion candidates
 *   richos-service mark-superseded ...   # record a companion's takeover of a dead browser call
 *   richos-service doctor                # verify ffmpeg / whisper-cli / model are resolvable
 *
 * Common flags: --zone <dir> (override the drop zone), --model <id>.
 */

import fs from 'node:fs';
import path from 'node:path';
import { runPipeline } from '../lib/pipeline.js';
import { scanZone, watch } from '../lib/watcher.js';
import { decideClaimOnDisk, findPromotableOnDisk, markSuperseded } from '../lib/coordination.js';
import { dropZone, ffmpegBin, whisperBin, resolveModel, DEFAULT_MODEL } from '../lib/config.js';
import { ffmpegVersion } from '../lib/normalize.js';
import { log } from '../lib/log.js';

function flag(name, fallback = null) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const v = process.argv[i + 1];
  return v && !v.startsWith('--') ? v : true;
}

function resolveSessionDir(arg, zone) {
  if (!arg) return null;
  if (arg.includes('/') || arg.includes(path.sep)) return path.resolve(arg);
  return path.join(zone, arg);
}

function main() {
  const cmd = process.argv[2];
  const zone = flag('zone') ? path.resolve(String(flag('zone'))) : dropZone();
  const model = flag('model') ? String(flag('model')) : undefined;

  switch (cmd) {
    case 'watch': {
      const handle = watch({ zone, model });
      process.on('SIGINT', () => {
        handle.stop();
        process.exit(0);
      });
      process.on('SIGTERM', () => {
        handle.stop();
        process.exit(0);
      });
      break;
    }

    case 'run': {
      const dir = resolveSessionDir(process.argv[3], zone);
      if (!dir || !fs.existsSync(dir)) fail(`run: session directory not found: ${dir}`);
      const result = runPipeline(dir, { model, zone });
      report(result);
      process.exit(result.status === 'ready' ? 0 : 2);
      break;
    }

    case 'retranscribe': {
      const dir = resolveSessionDir(process.argv[3], zone);
      if (!dir || !fs.existsSync(dir)) fail(`retranscribe: session directory not found: ${dir}`);
      const result = runPipeline(dir, { model: model || DEFAULT_MODEL, retranscribe: true, zone });
      report(result);
      process.exit(result.status === 'ready' ? 0 : 2);
      break;
    }

    case 'reconcile': {
      const r = scanZone({ zone, process: false });
      console.log(`reconcile over ${zone}`);
      console.log(`  ok/skipped: ${r.skipped.length}`);
      if (r.anomalies.length) {
        console.log('\nANOMALIES — a call may not have a transcript:');
        for (const a of r.anomalies) console.log(`  ${a.sessionId}\n    - ${a.problems.join('\n    - ')}`);
        process.exit(2);
      }
      console.log('  no anomalies');
      break;
    }

    case 'claim': {
      // Surface-agnostic ownership handshake (§5.4). A companion (macOS now, Windows later) or the
      // extension asks the SHARED authority whether to own a call or stand down (avoid double-capture).
      const req = {
        surface: flag('surface') ? String(flag('surface')) : 'desktop-companion-macos',
        captureKind: flag('kind') ? String(flag('kind')) : 'system',
        processHint: flag('process-hint') ? String(flag('process-hint')) : null,
        sessionId: flag('session-id') ? String(flag('session-id')) : null,
      };
      const decision = decideClaimOnDisk(zone, req);
      console.log(JSON.stringify({ request: req, ...decision }, null, 2));
      process.exit(decision.decision === 'own' ? 0 : 3);
      break;
    }

    case 'failover-scan': {
      // What a companion polls to learn a browser-owned call went dark (crash/hang) and can be taken
      // over. Prints the promotion candidates; a companion then captures with ownership.supersedes.
      const candidates = findPromotableOnDisk(zone);
      console.log(JSON.stringify({ zone, candidates }, null, 2));
      process.exit(0);
      break;
    }

    case 'mark-superseded': {
      // Close the failover loop: record on the dead session that a companion has taken it over.
      const dead = flag('dead') ? String(flag('dead')) : null;
      const by = flag('by') ? String(flag('by')) : null;
      if (!dead || !by) fail('mark-superseded requires --dead <sessionId> --by <sessionId>');
      const ok = markSuperseded(zone, dead, by);
      console.log(JSON.stringify({ dead, by, marked: ok }, null, 2));
      process.exit(ok ? 0 : 1);
      break;
    }

    case 'doctor': {
      let ok = true;
      try {
        console.log(`ffmpeg:     ${ffmpegBin()}  (${ffmpegVersion()})`);
      } catch (err) {
        ok = false;
        console.log(`ffmpeg:     MISSING — ${String(err.message || err)}`);
      }
      try {
        console.log(`whisper:    ${whisperBin()}`);
      } catch (err) {
        ok = false;
        console.log(`whisper:    MISSING — ${String(err.message || err)}`);
      }
      try {
        console.log(`model:      ${resolveModel(model || DEFAULT_MODEL)}`);
      } catch (err) {
        ok = false;
        console.log(`model:      MISSING — ${String(err.message || err)}`);
      }
      console.log(`drop zone:  ${zone}`);
      process.exit(ok ? 0 : 1);
      break;
    }

    default:
      console.log(
        [
          'usage:',
          '  richos-service watch [--zone dir] [--model id]',
          '  richos-service run <sessionId|dir> [--zone dir] [--model id]',
          '  richos-service retranscribe <sessionId|dir> [--model id]',
          '  richos-service reconcile [--zone dir]',
          '  richos-service claim --surface <s> --kind <browser-tab|system|process> [--process-hint h] [--session-id id]',
          '  richos-service failover-scan [--zone dir]',
          '  richos-service mark-superseded --dead <sessionId> --by <sessionId>',
          '  richos-service doctor',
        ].join('\n'),
      );
      process.exit(cmd ? 1 : 0);
  }
}

function report(result) {
  if (result.status === 'ready') {
    log.info(`READY ${result.sessionId} — ${result.words} words -> ${result.transcript}`);
  } else {
    log.alarm(`${result.status.toUpperCase()} ${result.sessionId}`, { problems: result.problems });
  }
}

function fail(msg) {
  log.error(msg);
  process.exit(1);
}

main();

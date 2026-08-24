#!/usr/bin/env node
/**
 * RichOS local service — Chrome native-messaging HOST (stdio entry point).
 *
 * Chrome spawns this process and speaks length-prefixed JSON over stdin/stdout (the system architecture §5.1).
 * It is the transport shell around two testable cores: `SessionSink` (writes the contract dir +
 * holds watchdog state) and `runPipeline` (transcribes on close). stdout is the binary framed
 * channel to Chrome — ALL diagnostics go to stderr (see lib/log.js).
 *
 * Responsibilities:
 *   - receive session lifecycle + audio/health/caption/heartbeat messages -> write the drop zone;
 *   - hold the outside-the-browser watchdog timer (heartbeat stall -> loud alarm);
 *   - on session-close, run the pipeline in a detached child so the host stays responsive;
 *   - on pipe EOF (browser died), finalize open sessions `interrupted` -> loud anomaly on disk.
 */

import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { NativeChannel } from '../lib/stdio.js';
import { SessionSink } from '../lib/host-handlers.js';
import { dropZone } from '../lib/config.js';
import { log } from '../lib/log.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(HERE, '..', 'bin', 'richos-service.js');

function main() {
  const zone = dropZone();
  const sink = new SessionSink(zone);
  const channel = new NativeChannel(process.stdin, process.stdout);
  log.info(`native host up; drop zone ${zone}`);

  channel.on('message', (msg) => {
    let response;
    try {
      response = sink.handle(msg);
    } catch (err) {
      log.error(`handler error: ${String(err.message || err)}`);
      channel.send({ type: 'error', error: String(err.message || err) });
      return;
    }
    if (response && response._trigger) {
      triggerPipeline(response._trigger, zone);
      delete response._trigger;
    }
    if (response) channel.send(response);
  });

  const watchdog = setInterval(() => sink.checkWatchdog(), 1000);

  channel.on('end', () => {
    clearInterval(watchdog);
    const finalized = sink.finalizeOnEof();
    if (finalized.length) log.alarm(`pipe closed with ${finalized.length} open session(s): ${finalized.join(', ')}`);
    process.exit(0);
  });

  channel.on('error', (err) => log.error(`channel error: ${String(err.message || err)}`));
}

/** Run the pipeline for a just-closed session in a detached child; the watcher is the backstop. */
function triggerPipeline(sessionId, zone) {
  try {
    const child = spawn(process.execPath, [CLI, 'run', sessionId], {
      detached: true,
      stdio: 'ignore',
      env: { ...process.env, RICHOS_DROP_ZONE: zone },
    });
    child.unref();
    log.info(`pipeline spawned for ${sessionId} (pid ${child.pid})`);
  } catch (err) {
    log.error(`failed to spawn pipeline for ${sessionId}: ${String(err.message || err)}`);
  }
}

main();

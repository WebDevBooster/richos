#!/usr/bin/env node
/**
 * RichOS local service — native-messaging HOST integration test (real stdio, real child process).
 *
 *   node test/host-e2e.mjs
 *
 * Spawns the actual native host and speaks Chrome's length-prefixed JSON protocol to it, exactly as
 * the extension would over `chrome.runtime.connectNative`. Proves the transport end-to-end: a
 * hello handshake, a streamed audio chunk landing byte-exact in the contract dir, health + caption
 * appends, heartbeat acks, and session-close finalizing the session + triggering the pipeline
 * (which then produces transcript.md in the same drop zone). No browser required.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { encodeMessage, FrameDecoder } from '../lib/stdio.js';
import { ffmpegBin, whisperBin, resolveModel } from '../lib/config.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HOST = path.join(HERE, '..', 'host', 'native-host.js');
const T0 = 1_700_000_000_000;

let failures = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? '  ok  ' : 'FAIL  '}${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures += 1;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Preconditions: the host needs ffmpeg/whisper/model to run the pipeline it spawns on close.
let ok = true;
try {
  ffmpegBin();
  whisperBin();
  resolveModel();
} catch (err) {
  ok = false;
  console.error(`host-e2e requires ffmpeg + whisper + model: ${err.message}`);
}
if (!ok) process.exit(1);
const canSay = (() => {
  try {
    execFileSync('say', ['-v', '?'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
})();

const zone = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-host-'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-host-work-'));

// Build a small 2-channel sample the extension would have chunked over the wire.
const samplePath = path.join(work, 'sample.webm');
if (canSay) {
  const a = path.join(work, 'a.aiff');
  const b = path.join(work, 'b.aiff');
  execFileSync('say', ['-v', 'Samantha', '-o', a, 'Hello from the microphone side of the call.']);
  execFileSync('say', ['-v', 'Fred', '-o', b, 'And hello from the other participant on the tab side.']);
  execFileSync(ffmpegBin(), [
    '-y', '-i', a, '-i', b,
    '-filter_complex',
    '[0:a]aformat=channel_layouts=mono,apad=whole_dur=8[me];' +
      '[1:a]aformat=channel_layouts=mono,adelay=3500,apad=whole_dur=8[others];' +
      '[me][others]join=inputs=2:channel_layout=stereo[a]',
    '-map', '[a]', '-c:a', 'libopus', '-b:a', '64k', '-ac', '2', samplePath,
  ]);
} else {
  execFileSync(ffmpegBin(), [
    '-y', '-f', 'lavfi', '-i', 'sine=frequency=280:duration=8',
    '-f', 'lavfi', '-i', 'sine=frequency=540:duration=8',
    '-filter_complex', '[0:a][1:a]join=inputs=2:channel_layout=stereo[a]',
    '-map', '[a]', '-c:a', 'libopus', '-b:a', '64k', '-ac', '2', samplePath,
  ]);
}
const audio = fs.readFileSync(samplePath);

async function main() {
  const child = spawn(process.execPath, [HOST], {
    env: { ...process.env, RICHOS_DROP_ZONE: zone, RICHOS_LOG_LEVEL: 'error' },
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const decoder = new FrameDecoder();
  const inbox = [];
  child.stdout.on('data', (chunk) => {
    for (const msg of decoder.push(chunk)) inbox.push(msg);
  });
  const send = (m) => child.stdin.write(encodeMessage(m));
  const waitFor = async (type, ms = 3000) => {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      const hit = inbox.find((m) => m.type === type);
      if (hit) return hit;
      await sleep(25);
    }
    return null;
  };

  const sessionId = '2026-08-24T12-00-00Z--meet--host-e2e';

  send({ type: 'hello', extensionVersion: '0.2.1' });
  check('host answers hello with ready', (await waitFor('ready')) != null);

  send({
    type: 'session-start',
    record: {
      schemaVersion: 1, sessionId, dir: sessionId, status: 'open', startedAt: T0,
      platform: { id: 'meet', label: 'Google Meet', slug: 'host-e2e' },
      audio: { parts: [], bytesTotal: 0, chunkCount: 0 }, captions: { count: 1 },
    },
  });
  check('host acks session-start', (await waitFor('started')) != null);

  // Stream the audio as one part (the extension streams ~3 s Opus chunks; one part here).
  send({ type: 'audio-chunk', sessionId, part: 0, ext: 'webm', dataB64: audio.toString('base64') });
  check('host acks the audio chunk', (await waitFor('chunk-ack')) != null);

  send({ type: 'health', sessionId, line: { t: T0 + 1000, level: 'green', bytes: audio.length } });
  send({ type: 'caption', sessionId, line: { speaker: 'Fred', text: 'and hello from the other participant', firstT: T0 + 3500, t: T0 + 7000 } });
  send({ type: 'heartbeat', sessionId, t: T0 + 2000 });
  check('host answers heartbeat with an ack (the outside-the-browser liveness signal)', (await waitFor('heartbeat-ack')) != null);

  send({ type: 'session-close', sessionId, record: { endedAt: T0 + 8000, audio: { parts: [{ part: 0, bytes: audio.length }], bytesTotal: audio.length, chunkCount: 1 } } });
  check('host acks session-close', (await waitFor('closed')) != null);

  const dir = path.join(zone, sessionId);
  check('audio landed byte-exact in the contract dir', fs.existsSync(path.join(dir, 'audio-part-00.webm')) &&
    fs.statSync(path.join(dir, 'audio-part-00.webm')).size === audio.length,
    `${fs.existsSync(path.join(dir, 'audio-part-00.webm')) ? fs.statSync(path.join(dir, 'audio-part-00.webm')).size : 'missing'} vs ${audio.length}`);
  check('health.ndjson + captions.ndjson were appended', fs.existsSync(path.join(dir, 'health.ndjson')) && fs.existsSync(path.join(dir, 'captions.ndjson')));
  const rec = JSON.parse(fs.readFileSync(path.join(dir, 'session.json'), 'utf8'));
  check('session.json is CLOSED and upgraded to schemaVersion 2', rec.status === 'closed' && rec.schemaVersion === 2);

  // Close the pipe: the host finalizes (none open now) and exits; the pipeline it spawned on close
  // continues detached.
  child.stdin.end();

  // Poll for the detached pipeline to reach a terminal state and (with speech) emit a transcript.
  let terminal = null;
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    try {
      const r = JSON.parse(fs.readFileSync(path.join(dir, 'session.json'), 'utf8'));
      if (r.pipeline && r.pipeline.status !== 'pending') {
        terminal = r.pipeline.status;
        break;
      }
    } catch {
      /* mid-write */
    }
    await sleep(300);
  }
  check('session-close TRIGGERED the pipeline (status left pending)', terminal != null, `status=${terminal}`);
  if (canSay) {
    check('the detached pipeline produced transcript.md from the streamed audio', fs.existsSync(path.join(dir, 'transcript.md')),
      `pipeline status=${terminal}`);
    if (fs.existsSync(path.join(dir, 'transcript.md'))) {
      console.log('\n----- host-e2e transcript.md -----\n' + fs.readFileSync(path.join(dir, 'transcript.md'), 'utf8') + '----------------------------------\n');
    }
  }

  try {
    child.kill();
  } catch {
    /* already gone */
  }
  fs.rmSync(work, { recursive: true, force: true });
  console.log(`(drop zone kept at ${zone})`);
  console.log(`\n${failures === 0 ? 'ALL HOST-E2E CHECKS PASSED' : `${failures} HOST-E2E CHECK(S) FAILED`}`);
  process.exit(failures ? 1 : 0);
}

main();

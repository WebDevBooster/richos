/**
 * RichOS — the recorder (runs inside the offscreen document).
 *
 * THE INVARIANT: NEVER LOSE THE AUDIO.
 *
 * Two sources, one 2-channel Opus stream:
 *   left  = microphone (you)
 *   right = tab audio (everyone else)
 * which gives free "me vs them" separation for transcription, with no diarisation model.
 *
 * Every `chunkMs` the MediaRecorder hands us a chunk and we WAIT for it to be committed to
 * IndexedDB before acknowledging. So a tab crash, a service-worker eviction, an extension
 * reload or a browser kill loses at most one chunk (default 3s) — never the call.
 *
 * Two traps that are handled here because forgetting either is catastrophic:
 *   1. `chrome.tabCapture` MUTES the captured tab. The tab source is re-routed to the
 *      AudioContext destination so the CEO keeps hearing the meeting.
 *   2. The microphone must NOT be routed to the destination, or the call echoes.
 */

import { DB } from '../../core/constants.js';
import { put, putAll, getAll, deleteBySession } from '../../core/idb.js';
import { THRESHOLDS } from './constants.js';

/** @type {null | {
 *   sessionId: string, settings: any, ctx: AudioContext, dest: MediaStreamAudioDestinationNode,
 *   merger: ChannelMergerNode, recorder: MediaRecorder|null,
 *   micStream: MediaStream|null, tabStream: MediaStream|null,
 *   micSource: MediaStreamAudioSourceNode|null, tabSource: MediaStreamAudioSourceNode|null,
 *   micAnalyser: AnalyserNode|null, tabAnalyser: AnalyserNode|null,
 *   part: number, seq: number, chunkCount: number, bytesTotal: number,
 *   lastChunkAt: number|null, micOnlyFailover: boolean, heartbeatTimer: any,
 *   healthBuffer: object[], stopping: boolean, startedAt: number, lastError: string|null
 * }} */
let session = null;

/** @type {Float32Array} */
let scratch = new Float32Array(2048);

/** Send a message to the service worker; never throws (the worker may be restarting). */
async function toWorker(message) {
  try {
    await chrome.runtime.sendMessage({ target: 'sw', module: 'callCapture', ...message });
  } catch {
    /* the worker will pick the state back up from IndexedDB */
  }
}

/**
 * @param {AnalyserNode|null} analyser
 * @returns {number} RMS in 0..1
 */
function rms(analyser) {
  if (!analyser) return 0;
  if (scratch.length !== analyser.fftSize) scratch = new Float32Array(analyser.fftSize);
  analyser.getFloatTimeDomainData(scratch);
  let sum = 0;
  for (let i = 0; i < scratch.length; i += 1) sum += scratch[i] * scratch[i];
  return Math.sqrt(sum / scratch.length);
}

/**
 * @param {MediaStream|null} stream
 * @returns {{readyState: string, muted: boolean, enabled: boolean, label: string}|null}
 */
function trackInfo(stream) {
  const track = stream && stream.getAudioTracks()[0];
  if (!track) return null;
  return { readyState: track.readyState, muted: track.muted, enabled: track.enabled, label: track.label };
}

/**
 * Acquire the tab audio stream from a stream id minted by the service worker.
 * @param {string} streamId
 * @returns {Promise<MediaStream>}
 */
async function getTabStream(streamId) {
  return navigator.mediaDevices.getUserMedia({
    audio: {
      // Legacy constraint form — the only one `chromeMediaSource: 'tab'` accepts.
      mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId },
    },
  });
}

/**
 * @param {any} settings
 * @returns {Promise<MediaStream>}
 */
async function getMicStream(settings) {
  const processing = settings.micProcessing !== false;
  return navigator.mediaDevices.getUserMedia({
    audio: {
      echoCancellation: processing,
      noiseSuppression: processing,
      autoGainControl: processing,
      channelCount: 1,
    },
  });
}

/** Wire a source into merger input `index` and give it an analyser. */
function connectSource(stream, index) {
  const source = session.ctx.createMediaStreamSource(stream);
  const analyser = session.ctx.createAnalyser();
  analyser.fftSize = 2048;
  source.connect(analyser);
  source.connect(session.merger, 0, index);
  return { source, analyser };
}

/** Persist one chunk. Awaited before we acknowledge — this is the durability boundary. */
async function persistChunk(blob) {
  const buffer = await blob.arrayBuffer();
  const record = {
    sessionId: session.sessionId,
    seq: session.seq,
    part: session.part,
    t: Date.now(),
    bytes: buffer.byteLength,
    data: buffer,
  };
  session.seq += 1;
  try {
    await put(DB.stores.chunks, record);
  } catch (err) {
    session.lastError = `chunk-write-failed: ${String((err && err.message) || err)}`;
    await toWorker({ type: 'cc:chunk-error', sessionId: session.sessionId, error: session.lastError });
    return;
  }
  session.chunkCount += 1;
  session.bytesTotal += record.bytes;
  session.lastChunkAt = record.t;
  await toWorker({
    type: 'cc:chunk',
    sessionId: session.sessionId,
    seq: record.seq,
    part: record.part,
    bytes: record.bytes,
    bytesTotal: session.bytesTotal,
    t: record.t,
  });
}

/** Build (or rebuild) the MediaRecorder for the current part. */
function buildRecorder() {
  const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
    ? 'audio/webm;codecs=opus'
    : 'audio/webm';
  const recorder = new MediaRecorder(session.dest.stream, {
    mimeType,
    audioBitsPerSecond: session.settings.audioBitsPerSecond || 96000,
  });
  recorder.ondataavailable = (event) => {
    if (!event.data || !event.data.size) return;
    void persistChunk(event.data);
  };
  recorder.onerror = (event) => {
    session.lastError = `recorder-error: ${event?.error?.name || 'unknown'}`;
    void toWorker({ type: 'cc:recorder-error', sessionId: session.sessionId, error: session.lastError });
  };
  session.recorder = recorder;
  recorder.start(session.settings.chunkMs || 3000);
  return mimeType;
}

/** One heartbeat: the only source of truth the health evaluator ever sees. */
async function heartbeat() {
  if (!session) return;
  const record = {
    sessionId: session.sessionId,
    t: Date.now(),
    micRms: Number(rms(session.micAnalyser).toFixed(6)),
    tabRms: Number(rms(session.tabAnalyser).toFixed(6)),
    recorderState: session.recorder ? session.recorder.state : 'inactive',
    part: session.part,
    chunkCount: session.chunkCount,
    bytesTotal: session.bytesTotal,
    lastChunkAt: session.lastChunkAt,
    micTrack: trackInfo(session.micStream),
    tabTrack: trackInfo(session.tabStream),
    micOnlyFailover: session.micOnlyFailover,
    lastError: session.lastError,
  };
  session.healthBuffer.push(record);
  if (session.healthBuffer.length >= 5) {
    const batch = session.healthBuffer.splice(0, session.healthBuffer.length);
    try {
      await putAll(DB.stores.health, batch);
    } catch {
      /* health records are diagnostics; never let them break the recording */
    }
  }
  await toWorker({ type: 'cc:heartbeat', ...record });
}

/**
 * Start a capture session.
 * @param {{sessionId: string, streamId: string|null, settings: any}} msg
 */
export async function start(msg) {
  if (session) await stop({ reason: 'superseded' });
  const settings = msg.settings || {};
  session = {
    sessionId: msg.sessionId,
    settings,
    ctx: new AudioContext({ sampleRate: 48000 }),
    dest: null,
    merger: null,
    recorder: null,
    micStream: null,
    tabStream: null,
    micSource: null,
    tabSource: null,
    micAnalyser: null,
    tabAnalyser: null,
    part: 0,
    seq: 0,
    chunkCount: 0,
    bytesTotal: 0,
    lastChunkAt: null,
    micOnlyFailover: false,
    heartbeatTimer: null,
    healthBuffer: [],
    stopping: false,
    startedAt: Date.now(),
    lastError: null,
  };
  session.merger = session.ctx.createChannelMerger(2);
  session.dest = session.ctx.createMediaStreamDestination();
  session.merger.connect(session.dest);

  const problems = [];

  if (msg.streamId) {
    try {
      session.tabStream = await getTabStream(msg.streamId);
      const wired = connectSource(session.tabStream, 1);
      session.tabSource = wired.source;
      session.tabAnalyser = wired.analyser;
      // TRAP 1: tabCapture mutes the tab. Give the audio back to the speakers.
      session.tabSource.connect(session.ctx.destination);
      session.tabStream.getAudioTracks()[0].addEventListener('ended', () => {
        void toWorker({ type: 'cc:track-ended', sessionId: session.sessionId, which: 'tab' });
      });
    } catch (err) {
      problems.push(`tab-audio: ${String((err && err.message) || err)}`);
      session.micOnlyFailover = true;
    }
  } else {
    problems.push('tab-audio: no stream id was provided');
    session.micOnlyFailover = true;
  }

  if (settings.captureMic !== false) {
    try {
      session.micStream = await getMicStream(settings);
      const wired = connectSource(session.micStream, 0);
      session.micSource = wired.source;
      session.micAnalyser = wired.analyser;
      // TRAP 2: never connect the mic to ctx.destination — that is an echo loop.
      session.micStream.getAudioTracks()[0].addEventListener('ended', () => {
        void toWorker({ type: 'cc:track-ended', sessionId: session.sessionId, which: 'mic' });
      });
    } catch (err) {
      problems.push(`microphone: ${String((err && err.message) || err)}`);
    }
  }

  if (!session.tabStream && !session.micStream) {
    const error = `no audio source could be acquired — ${problems.join('; ')}`;
    session.lastError = error;
    await stop({ reason: 'no-source' });
    return { ok: false, error, problems };
  }

  const mimeType = buildRecorder();
  session.heartbeatTimer = setInterval(() => void heartbeat(), THRESHOLDS.heartbeatMs);
  void heartbeat();

  return {
    ok: true,
    mimeType,
    micOnlyFailover: session.micOnlyFailover,
    hasTab: Boolean(session.tabStream),
    hasMic: Boolean(session.micStream),
    problems,
  };
}

/**
 * Roll to a new part with a fresh MediaRecorder. Used by recovery: a new part is a
 * self-contained WebM, so even a corrupt previous part cannot poison what follows.
 */
export async function restartRecorder() {
  if (!session) return { ok: false, error: 'no-session' };
  try {
    if (session.recorder && session.recorder.state !== 'inactive') {
      const flushed = new Promise((resolve) => {
        session.recorder.addEventListener('stop', resolve, { once: true });
      });
      session.recorder.stop();
      await flushed;
    }
  } catch {
    /* a wedged recorder is exactly why we are here */
  }
  session.part += 1;
  const mimeType = buildRecorder();
  return { ok: true, part: session.part, mimeType };
}

/**
 * Re-acquire the tab stream after it ended (tab moved windows, reloaded, device switched).
 * @param {{streamId: string|null}} msg
 */
export async function reattachTab(msg) {
  if (!session) return { ok: false, error: 'no-session' };
  try {
    if (session.tabSource) session.tabSource.disconnect();
    if (session.tabStream) session.tabStream.getTracks().forEach((t) => t.stop());
    if (!msg.streamId) throw new Error('no stream id available (needs an extension invocation on the tab)');
    session.tabStream = await getTabStream(msg.streamId);
    const wired = connectSource(session.tabStream, 1);
    session.tabSource = wired.source;
    session.tabAnalyser = wired.analyser;
    session.tabSource.connect(session.ctx.destination);
    session.micOnlyFailover = false;
    await restartRecorder();
    return { ok: true };
  } catch (err) {
    // Half a call beats none: keep recording the microphone and stay loud about it.
    session.micOnlyFailover = true;
    session.tabStream = null;
    session.tabSource = null;
    session.tabAnalyser = null;
    return { ok: false, error: String((err && err.message) || err), micOnlyFailover: true };
  }
}

/** Re-acquire the microphone (Bluetooth handoff / default device change). */
export async function reacquireMic() {
  if (!session) return { ok: false, error: 'no-session' };
  try {
    if (session.micSource) session.micSource.disconnect();
    if (session.micStream) session.micStream.getTracks().forEach((t) => t.stop());
    session.micStream = await getMicStream(session.settings);
    const wired = connectSource(session.micStream, 0);
    session.micSource = wired.source;
    session.micAnalyser = wired.analyser;
    await restartRecorder();
    return { ok: true, device: trackInfo(session.micStream) };
  } catch (err) {
    session.micStream = null;
    session.micSource = null;
    session.micAnalyser = null;
    return { ok: false, error: String((err && err.message) || err) };
  }
}

/**
 * Stop the session and flush everything.
 * @param {{reason?: string}} [msg]
 */
export async function stop(msg = {}) {
  if (!session) return { ok: true, alreadyStopped: true };
  session.stopping = true;
  clearInterval(session.heartbeatTimer);
  try {
    if (session.recorder && session.recorder.state !== 'inactive') {
      const flushed = new Promise((resolve) => {
        session.recorder.addEventListener('stop', resolve, { once: true });
      });
      session.recorder.stop();
      await flushed;
      // Give the final ondataavailable its microtask turn to commit.
      await new Promise((resolve) => setTimeout(resolve, 150));
    }
  } catch {
    /* ignore */
  }
  if (session.healthBuffer.length) {
    try {
      await putAll(DB.stores.health, session.healthBuffer.splice(0));
    } catch {
      /* diagnostics only */
    }
  }
  for (const stream of [session.micStream, session.tabStream]) {
    if (stream) stream.getTracks().forEach((t) => t.stop());
  }
  try {
    await session.ctx.close();
  } catch {
    /* ignore */
  }
  const summary = {
    ok: true,
    sessionId: session.sessionId,
    reason: msg.reason || 'stopped',
    parts: session.part + 1,
    chunkCount: session.chunkCount,
    bytesTotal: session.bytesTotal,
    micOnlyFailover: session.micOnlyFailover,
    lastError: session.lastError,
  };
  session = null;
  return summary;
}

/** @returns {object} live status for the popup / watchdog */
export function status() {
  if (!session) return { ok: true, active: false };
  return {
    ok: true,
    active: true,
    sessionId: session.sessionId,
    startedAt: session.startedAt,
    part: session.part,
    chunkCount: session.chunkCount,
    bytesTotal: session.bytesTotal,
    lastChunkAt: session.lastChunkAt,
    recorderState: session.recorder ? session.recorder.state : 'inactive',
    micOnlyFailover: session.micOnlyFailover,
    micTrack: trackInfo(session.micStream),
    tabTrack: trackInfo(session.tabStream),
    lastError: session.lastError,
  };
}

/**
 * Assemble persisted chunks into one blob URL per part.
 *
 * WebM note: within a part, chunk 0 carries the header and the rest are continuation
 * clusters, so concatenating a part's chunks in `seq` order yields a playable file. A file
 * whose session was killed mid-recording has no duration index — ffmpeg reads it fine and
 * `ffmpeg -i in.webm -c copy out.webm` restores seeking.
 *
 * @param {{sessionId: string}} msg
 * @returns {Promise<{ok: boolean, parts?: {part: number, url: string, bytes: number, chunks: number,
 *                    firstChunkAt: number|null, lastChunkAt: number|null}[], error?: string}>}
 */
export async function assemble(msg) {
  try {
    const chunks = await getAll(DB.stores.chunks, 'bySession', IDBKeyRange.only(msg.sessionId));
    if (!chunks.length) return { ok: true, parts: [] };
    chunks.sort((a, b) => a.seq - b.seq);
    /** @type {Map<number, any[]>} */
    const byPart = new Map();
    for (const chunk of chunks) {
      if (!byPart.has(chunk.part)) byPart.set(chunk.part, []);
      byPart.get(chunk.part).push(chunk);
    }
    const parts = [];
    for (const [part, list] of [...byPart.entries()].sort((a, b) => a[0] - b[0])) {
      const blob = new Blob(list.map((c) => c.data), { type: 'audio/webm' });
      parts.push({
        part,
        url: URL.createObjectURL(blob),
        bytes: blob.size,
        chunks: list.length,
        firstChunkAt: list[0]?.t ?? null,
        lastChunkAt: list[list.length - 1]?.t ?? null,
      });
    }
    return { ok: true, parts };
  } catch (err) {
    return { ok: false, error: String((err && err.message) || err) };
  }
}

/**
 * Export the per-second health records as JSONL (written next to the audio).
 * @param {{sessionId: string}} msg
 */
export async function healthJsonl(msg) {
  const records = await getAll(DB.stores.health, 'bySession', IDBKeyRange.only(msg.sessionId));
  records.sort((a, b) => a.t - b.t);
  return { ok: true, text: records.map((r) => JSON.stringify(r)).join('\n'), count: records.length };
}

/** Drop a session's chunks/health once it is safely exported. */
export async function purge(msg) {
  await deleteBySession(DB.stores.chunks, msg.sessionId);
  await deleteBySession(DB.stores.health, msg.sessionId);
  return { ok: true };
}

/** @returns {Promise<string[]>} session ids that still have chunks in IndexedDB */
export async function orphanSessions() {
  const chunks = await getAll(DB.stores.chunks);
  return [...new Set(chunks.map((c) => c.sessionId))];
}

/** Route a `cc:` message inside the offscreen document. */
export async function handleMessage(msg) {
  switch (msg.type) {
    case 'cc:start':
      return start(msg);
    case 'cc:stop':
      return stop(msg);
    case 'cc:restart-recorder':
      return restartRecorder();
    case 'cc:reattach-tab':
      return reattachTab(msg);
    case 'cc:reacquire-mic':
      return reacquireMic();
    case 'cc:status':
      return status();
    case 'cc:assemble':
      return assemble(msg);
    case 'cc:health-jsonl':
      return healthJsonl(msg);
    case 'cc:purge':
      return purge(msg);
    case 'cc:orphans':
      return { ok: true, sessionIds: await orphanSessions() };
    default:
      return undefined;
  }
}

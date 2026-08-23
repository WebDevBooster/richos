/**
 * RichOS — capture health evaluation (pure module, node-testable).
 *
 * This is the second-by-second in-call answer to "is the audio actually being recorded?".
 * It is deliberately pure: the controller feeds it heartbeats and a clock, it returns a
 * level, human-readable reasons and the recovery actions to perform. Everything the CEO is
 * ever alarmed about is decided here, and every threshold is unit-tested.
 *
 * Design rule borrowed from the LinkedIn extension work: the numbers shown to the user come
 * from the SAME record that the writer produced (bytes/chunks reported by the recorder that
 * wrote them) — never a second, drift-prone counter.
 */

import { THRESHOLDS, ACTIONS } from './constants.js';

const LEVEL_ORDER = { green: 0, amber: 1, red: 2 };

/**
 * @typedef {object} CaptureState
 * @property {string} sessionId
 * @property {number} startedAt
 * @property {boolean} micEnabled
 * @property {boolean} tabEnabled
 * @property {number|null} lastHeartbeatAt
 * @property {number|null} lastChunkAt
 * @property {number} chunkCount
 * @property {number} bytesTotal
 * @property {number|null} bytesGrewAt
 * @property {number} part
 * @property {string} recorderState
 * @property {{readyState: string, muted: boolean}|null} micTrack
 * @property {{readyState: string, muted: boolean}|null} tabTrack
 * @property {string|null} ctxState AudioContext state: only 'running' records anything
 * @property {number|null} micNonZeroAt
 * @property {number|null} tabNonZeroAt
 * @property {number|null} micSpeechAt
 * @property {number|null} tabSpeechAt
 * @property {boolean} micOnlyFailover
 */

/**
 * @param {{sessionId: string, startedAt: number, micEnabled?: boolean, tabEnabled?: boolean}} init
 * @returns {CaptureState}
 */
export function newCaptureState(init) {
  return {
    sessionId: init.sessionId,
    startedAt: init.startedAt,
    micEnabled: init.micEnabled !== false,
    tabEnabled: init.tabEnabled !== false,
    /** Hybrid mode: mic + captions are running but tab audio has not been armed yet. */
    awaitingTabAudio: Boolean(init.awaitingTabAudio),
    lastHeartbeatAt: null,
    lastChunkAt: null,
    chunkCount: 0,
    bytesTotal: 0,
    bytesGrewAt: null,
    part: 0,
    recorderState: 'starting',
    micTrack: null,
    tabTrack: null,
    ctxState: null,
    micNonZeroAt: null,
    tabNonZeroAt: null,
    micSpeechAt: null,
    tabSpeechAt: null,
    micOnlyFailover: false,
  };
}

/**
 * Fold one heartbeat from the offscreen recorder into the state.
 * @param {CaptureState} state
 * @param {object} hb
 * @param {typeof THRESHOLDS} [thresholds]
 * @returns {CaptureState}
 */
export function applyHeartbeat(state, hb, thresholds = THRESHOLDS) {
  const t = hb.t || Date.now();
  state.lastHeartbeatAt = t;
  state.recorderState = hb.recorderState || state.recorderState;
  state.part = hb.part != null ? hb.part : state.part;
  state.micTrack = hb.micTrack || null;
  state.tabTrack = hb.tabTrack || null;
  state.ctxState = hb.ctxState || state.ctxState;
  state.micOnlyFailover = Boolean(hb.micOnlyFailover);

  if (hb.lastChunkAt) state.lastChunkAt = hb.lastChunkAt;
  if (typeof hb.chunkCount === 'number') state.chunkCount = hb.chunkCount;
  if (typeof hb.bytesTotal === 'number') {
    if (hb.bytesTotal > state.bytesTotal) state.bytesGrewAt = t;
    state.bytesTotal = hb.bytesTotal;
  }
  if (typeof hb.micRms === 'number') {
    if (hb.micRms > thresholds.rmsZeroEpsilon) state.micNonZeroAt = t;
    if (hb.micRms > thresholds.rmsSpeechFloor) state.micSpeechAt = t;
  }
  if (typeof hb.tabRms === 'number') {
    if (hb.tabRms > thresholds.rmsZeroEpsilon) state.tabNonZeroAt = t;
    if (hb.tabRms > thresholds.rmsSpeechFloor) state.tabSpeechAt = t;
  }
  return state;
}

/**
 * @param {CaptureState} state
 * @param {number} now
 * @param {typeof THRESHOLDS} [thresholds]
 * @returns {{level: 'green'|'amber'|'red', reasons: {code: string, level: string, detail: string}[],
 *            actions: string[], signals: Record<string, string>}}
 */
export function evaluateHealth(state, now, thresholds = THRESHOLDS) {
  /** @type {{code: string, level: string, detail: string}[]} */
  const reasons = [];
  /** @type {string[]} */
  const actions = [];
  /** @type {Record<string, string>} */
  const signals = {};
  const age = now - state.startedAt;
  const warming = age < thresholds.warmupMs;

  const add = (code, level, detail, action) => {
    reasons.push({ code, level, detail });
    if (action && !actions.includes(action)) actions.push(action);
  };

  // --- 1. Is the recorder itself still talking to us? -----------------------------------
  const hbAge = now - (state.lastHeartbeatAt || state.startedAt);
  if (hbAge >= thresholds.heartbeatRedMs) {
    signals.heartbeat = 'red';
    add(
      'offscreen-silent',
      'red',
      `no heartbeat from the recorder for ${Math.round(hbAge / 1000)}s`,
      ACTIONS.recreateOffscreen,
    );
    // Every other signal is stale by definition — report and stop here.
    return { level: 'red', reasons, actions, signals };
  }
  signals.heartbeat = hbAge >= thresholds.heartbeatAmberMs ? 'amber' : 'green';
  if (signals.heartbeat === 'amber') {
    add('offscreen-lagging', 'amber', `recorder heartbeat is ${Math.round(hbAge / 1000)}s old`);
  }

  // --- 2. Are audio chunks reaching disk? ----------------------------------------------
  if (state.lastChunkAt == null) {
    if (warming) {
      signals.chunks = 'amber';
      add('warming-up', 'amber', 'waiting for the first audio chunk');
    } else {
      signals.chunks = 'red';
      add(
        'no-audio-ever',
        'red',
        `armed ${Math.round(age / 1000)}s ago and not one audio chunk has been written`,
        ACTIONS.restartRecorder,
      );
    }
  } else {
    const chunkAge = now - state.lastChunkAt;
    if (chunkAge >= thresholds.chunkRedMs) {
      signals.chunks = 'red';
      add('audio-stalled', 'red', `no audio written for ${Math.round(chunkAge / 1000)}s`, ACTIONS.restartRecorder);
    } else if (chunkAge >= thresholds.chunkAmberMs) {
      signals.chunks = 'amber';
      add('audio-lagging', 'amber', `last audio chunk was ${Math.round(chunkAge / 1000)}s ago`);
    } else {
      signals.chunks = 'green';
    }

    // Chunks arriving but empty is the nastiest silent failure: the pipeline looks alive.
    const growthAge = now - (state.bytesGrewAt || state.startedAt);
    if (growthAge >= thresholds.chunkRedMs) {
      signals.bytes = 'red';
      add(
        'audio-not-growing',
        'red',
        `the recording has not grown for ${Math.round(growthAge / 1000)}s`,
        ACTIONS.restartRecorder,
      );
    } else {
      signals.bytes = 'green';
    }
  }

  // --- 3. Is the recorder in the right state, with live tracks? -------------------------
  if (state.recorderState && !['recording', 'starting'].includes(state.recorderState)) {
    signals.recorder = 'red';
    add('recorder-inactive', 'red', `MediaRecorder state is "${state.recorderState}"`, ACTIONS.restartRecorder);
  } else {
    signals.recorder = 'green';
  }

  // A suspended/closed AudioContext records perfect silence while every other signal looks
  // healthy. The recorder tries to resume it; if it is still not running, that is red.
  if (state.ctxState && state.ctxState !== 'running') {
    signals.audioGraph = 'red';
    add(
      'audio-graph-not-running',
      'red',
      `the audio graph is "${state.ctxState}" — the recording would be silent`,
      ACTIONS.restartRecorder,
    );
  } else if (state.ctxState) {
    signals.audioGraph = 'green';
  }

  if (state.tabEnabled) {
    if (state.tabTrack && state.tabTrack.readyState === 'ended') {
      signals.tabTrack = 'red';
      add('tab-stream-ended', 'red', 'the tab audio stream ended', ACTIONS.reattachTab);
    } else {
      signals.tabTrack = 'green';
    }
  }
  if (state.micEnabled) {
    if (state.micTrack && state.micTrack.readyState === 'ended') {
      signals.micTrack = 'red';
      add('mic-stream-ended', 'red', 'the microphone stream ended', ACTIONS.reacquireMic);
    } else if (state.micTrack && state.micTrack.muted) {
      signals.micTrack = 'amber';
      add('mic-muted', 'amber', 'the microphone track reports muted');
    } else {
      signals.micTrack = 'green';
    }
  }

  // --- 4. Digital silence: the stream is technically alive but carries nothing ----------
  if (!warming) {
    if (state.tabEnabled && !state.micOnlyFailover) {
      const tabSilentFor = now - (state.tabNonZeroAt || state.startedAt);
      if (tabSilentFor >= thresholds.digitalSilenceRedMs) {
        signals.tabLevel = 'red';
        add(
          'tab-digital-silence',
          'red',
          `exact digital silence on the call channel for ${Math.round(tabSilentFor / 1000)}s`,
          ACTIONS.reattachTab,
        );
      } else {
        signals.tabLevel = 'green';
      }
    }
    if (state.micEnabled) {
      const micSilentFor = now - (state.micNonZeroAt || state.startedAt);
      if (micSilentFor >= thresholds.digitalSilenceRedMs) {
        signals.micLevel = 'red';
        add(
          'mic-digital-silence',
          'red',
          `exact digital silence on your microphone for ${Math.round(micSilentFor / 1000)}s (device switched or muted at the OS?)`,
          ACTIONS.reacquireMic,
        );
      } else {
        signals.micLevel = 'green';
      }
    }

    // Nobody talking is legitimate — amber, never red, and never a recovery action.
    const lastSpeech = Math.max(state.micSpeechAt || 0, state.tabSpeechAt || 0) || state.startedAt;
    if (now - lastSpeech >= thresholds.quietAmberMs) {
      signals.speech = 'amber';
      add('no-speech', 'amber', `no speech-level audio on either channel for ${Math.round((now - lastSpeech) / 1000)}s`);
    } else {
      signals.speech = 'green';
    }
  }

  // --- 5. Failover is a permanent amber: half a call is better than none, but it is not OK
  if (state.micOnlyFailover) {
    add('mic-only-failover', 'amber', 'tab audio could not be recovered — recording your microphone only');
  }

  // Hybrid: mic + captions are running by design, awaiting the one click that adds tab audio.
  // Amber (partial capture), never red here and never a recovery action — the controller drives
  // the ARM prompt for the missing ground-truth channel.
  if (state.awaitingTabAudio) {
    add('awaiting-tab-audio', 'amber', 'microphone + captions recording; click to add tab audio (ground truth)');
  }

  const level = reasons.reduce(
    (worst, r) => (LEVEL_ORDER[r.level] > LEVEL_ORDER[worst] ? r.level : worst),
    /** @type {'green'|'amber'|'red'} */ ('green'),
  );
  return { level, reasons, actions, signals };
}

/**
 * Short badge text for a health level — the glanceable indicator.
 * @param {'green'|'amber'|'red'|'idle'} level
 * @returns {string}
 */
export function badgeTextFor(level) {
  switch (level) {
    case 'green':
      return 'REC';
    case 'amber':
      return '...';
    case 'red':
      return '!';
    default:
      return '';
  }
}

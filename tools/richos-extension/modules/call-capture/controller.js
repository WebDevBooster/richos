/**
 * RichOS — call-capture controller (runs in the service worker).
 *
 * Owns: arming, the second-by-second watchdog, recovery, CEO-only alarms, session records
 * and the drop-zone export. The recorder (offscreen) owns bytes; this file owns *truth about*
 * those bytes and never counts anything itself — every number it reports comes from the
 * recorder that wrote it.
 */

import { KEYS, PRODUCT, DB } from '../../core/constants.js';
import { getModuleSettings } from '../../core/settings.js';
import { ensureOffscreen, closeOffscreen, callOffscreen, offscreenExists } from '../../core/offscreen-host.js';
import { writeText, writeUrl, dropPath, setDownloadUi } from '../../core/output.js';
import { raiseAlert, setHealth, resetAlertThrottle, notifyRoutine } from '../../core/alerts.js';
import { put, get, getAll, deleteBySession } from '../../core/idb.js';
import {
  NativeHostClient,
  withBrowserOwnership,
  buildHealthMessage,
  buildCaptionMessage,
  SURFACE,
} from '../../core/native-host-client.js';
import { MODULE_ID, CAPTURE_DEFAULTS, SETTINGS_SCHEMA, THRESHOLDS, ACTIONS, SESSION_STATUS, FILES } from './constants.js';
import { detectPlatform, shouldAutoArm, isCallTab } from './platforms.js';
import { newCaptureState, applyHeartbeat, evaluateHealth, evaluateCaptionsOnlyHealth, badgeTextFor } from './health.js';
import { newSessionRecord, accrueHealth, verifySession, audioFileName } from './session.js';

/** @type {{record: any, state: any, tabId: number, lastEval: any, attempts: Record<string, {n: number, at: number}>,
 *          lastDiskWrite: number, finalizing: boolean}|null} */
let active = null;

/** @type {Map<number, number>} tabId -> first time we saw it as a call tab */
const seenCallTabs = new Map();
/** @type {number|null} when we first noticed an unarmed call tab */
let unarmedSince = null;
/** @type {any} */
let watchdogTimer = null;

const SCAN_ALARM = 'richos-cc-scan';

// ---------------------------------------------------------------------------------------
// Module definition
// ---------------------------------------------------------------------------------------

export const callCaptureModule = {
  id: MODULE_ID,
  label: 'Call capture',
  defaults: CAPTURE_DEFAULTS,
  settingsSchema: SETTINGS_SCHEMA,
  init,
  onMessage,
  getStatus,
  onSettingsChanged: applyCoreSideEffects,
};

/** Boot: wire listeners, restore state, recover anything interrupted. */
async function init() {
  chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => void onTabChanged(tabId, changeInfo, tab));
  chrome.tabs.onCreated.addListener(() => void scanTabs());
  chrome.tabs.onRemoved.addListener((tabId) => void onTabRemoved(tabId));
  chrome.tabs.onReplaced.addListener(() => void scanTabs());
  chrome.alarms.create(SCAN_ALARM, { periodInMinutes: 1 });
  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name !== SCAN_ALARM) return;
    // Backstop for an evicted service worker: re-check everything on the alarm tick.
    void tick();
    void scanTabs();
  });
  if (chrome.commands?.onCommand) {
    chrome.commands.onCommand.addListener((command) => {
      if (command === 'arm-capture') void armActiveTab('shortcut');
    });
  }

  await applyCoreSideEffects();
  await recoverAfterRestart();
  await scanTabs();
}

/** Settings that touch browser-wide state. */
async function applyCoreSideEffects() {
  const core = await getModuleSettings('core');
  await setDownloadUi(!core.suppressDownloadUi);
}

// ---------------------------------------------------------------------------------------
// Arming
// ---------------------------------------------------------------------------------------

/**
 * Mint a tab-audio stream id.
 *
 * Chrome requires the extension to have been *invoked* for a tab (toolbar click, keyboard
 * shortcut, context menu) before it hands over that tab's audio. That is a browser security
 * boundary and we do not attempt to work around it — we make forgetting impossible instead:
 * a recognized call tab that is not being captured is alarmed within seconds.
 *
 * @param {number} tabId
 * @returns {Promise<{ok: boolean, streamId?: string, needsInvocation?: boolean, error?: string}>}
 */
async function mintStreamId(tabId) {
  try {
    const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
    return { ok: true, streamId };
  } catch (err) {
    const error = String((err && err.message) || err);
    return { ok: false, error, needsInvocation: /invoke|activeTab|gesture/i.test(error) };
  }
}

/**
 * Serialize all arm attempts. Captions can arrive faster than a session can be created, and each
 * one may trigger an auto-start; without this, two concurrent starts would race and double-build
 * the recorder. Every entry point (scan, popup, shortcut, caption) goes through this chain.
 * @type {Promise<any>}
 */
let armChain = Promise.resolve();

/**
 * Arm capture on a tab. Hybrid model:
 *   · toolbar/shortcut/popup trigger (a real invocation) → Chrome hands over tab audio → FULL
 *     capture (tab + mic), or UPGRADES a running mic+captions session to full.
 *   · auto trigger with no invocation yet → start MIC + CAPTIONS immediately (zero gesture), and
 *     raise the red ARM prompt for the one click that adds tab-audio ground truth.
 * @param {number} tabId
 * @param {string} trigger 'auto' | 'popup' | 'shortcut' | 'recovery'
 * @returns {Promise<{ok: boolean, error?: string, needsInvocation?: boolean, sessionId?: string, mode?: string}>}
 */
export function armTab(tabId, trigger = 'auto') {
  const next = armChain.then(() => armTabImpl(tabId, trigger));
  armChain = next.catch(() => {});
  return next;
}

/**
 * @param {number} tabId
 * @param {string} trigger
 */
async function armTabImpl(tabId, trigger = 'auto') {
  const settings = await getModuleSettings(MODULE_ID);
  if (!settings.enabled) return { ok: false, error: 'call capture is disabled in settings' };

  // Upgrade path: a mic+captions (or captions-only) session is already running for this tab and
  // the CEO has now invoked the extension — add the ground-truth tab audio to it.
  if (active && active.tabId === tabId && active.awaitingTabAudio) {
    return upgradeToFullAudio(tabId, trigger);
  }
  if (active) {
    if (active.tabId === tabId) return { ok: true, sessionId: active.record.sessionId };
    await raiseAlert({
      code: 'second-call-tab',
      level: 'amber',
      title: 'RichOS: a second call is not being captured',
      message: 'Another call tab is open while a session is already recording. Only one call is captured at a time.',
    });
    return { ok: false, error: 'a session is already active' };
  }

  let tab;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    return { ok: false, error: 'tab is gone' };
  }

  const platform = detectPlatform(tab.url || '') || {
    id: 'unknown',
    label: 'Unrecognised tab',
    slug: 'call',
    requiresAudible: true,
  };

  const minted = await mintStreamId(tabId);
  if (minted.ok) {
    return beginSession({ tabId, tab, platform, settings, trigger, streamId: minted.streamId, mode: 'full' });
  }

  // Chrome will not release tab audio without an invocation.
  if (minted.needsInvocation && settings.autoStartMicCaptions !== false && trigger === 'auto') {
    // The hybrid guarantee: never leave a detected call fully uncaptured. Start mic + captions
    // now with zero gesture; the click will upgrade to full tab audio.
    return beginSession({ tabId, tab, platform, settings, trigger, streamId: null, mode: 'mic+captions' });
  }
  if (minted.needsInvocation) {
    await raiseAlert({
      code: 'needs-invocation',
      level: 'red',
      title: 'RichOS: click to start capturing this call',
      message:
        'Chrome will not release this tab\'s audio until you invoke the extension for it. Click the RichOS icon (or press the shortcut) on the call tab now.',
    });
    await setHealth({ level: 'red', text: 'ARM', title: 'RichOS: call tab NOT being captured — click to arm' });
  }
  return { ok: false, error: minted.error, needsInvocation: minted.needsInvocation };
}

/**
 * Create and start a session in the given mode.
 * @param {{tabId: number, tab: any, platform: any, settings: any, trigger: string,
 *          streamId: string|null, mode: 'full'|'mic+captions'}} init
 */
async function beginSession({ tabId, tab, platform, settings, trigger, streamId, mode }) {
  const startedAt = Date.now();
  const record = newSessionRecord({
    startedAt,
    platform,
    tabId,
    url: tab.url,
    title: tab.title,
    extensionVersion: chrome.runtime.getManifest?.().version || PRODUCT.version,
    settings,
  });
  record.mode = mode;
  record.notes.push(`armed via ${trigger} (mode: ${mode})`);

  resetAlertThrottle();
  const micEnabled = settings.captureMic !== false;
  const tabEnabled = mode === 'full';
  active = {
    record,
    state: newCaptureState({ sessionId: record.sessionId, startedAt, micEnabled, tabEnabled, awaitingTabAudio: mode !== 'full' }),
    tabId,
    lastEval: null,
    attempts: {},
    lastDiskWrite: 0,
    finalizing: false,
    awaitingTabAudio: mode !== 'full',
    audioActive: false,
    captions: { available: false, adapter: null, adapterVersion: null, count: 0, seq: 0, lastCaptionAt: null, degraded: false },
    // Transport sink: native-messaging streaming is the DEFAULT; Downloads is the runtime fallback.
    sink: 'downloads',
    native: null,
    nativeChain: Promise.resolve(),
    streamedBytes: 0,
    streamedChunks: 0,
  };

  // 1) The record of the call's existence reaches disk BEFORE any audio does. Choose the transport
  //    first: if the local service answers, stream the whole contract dir straight to it (session
  //    START lands over the wire, host writes session.json immediately); otherwise fall back to the
  //    Downloads path unchanged. Either way the "session on disk before audio" anomaly guarantee holds.
  await setupSink(record);
  if (active.sink === 'downloads') await writeSessionFile(record);
  await persistActive();

  // 2) Start the recorder. `expectTab: false` in hybrid mode means "no tab yet, by design".
  await ensureOffscreen();
  const started = await callOffscreen({
    type: 'cc:start',
    sessionId: record.sessionId,
    streamId,
    settings,
    expectTab: tabEnabled,
  });

  if (!started?.ok) {
    // No audio source at all. In hybrid mode (mic permission absent, tab not armed) this is NOT
    // fatal — keep the session so captions are still collected, go red ARM, never silent.
    if (mode !== 'full' && settings.captureCaptions !== false) {
      active.audioActive = false;
      active.record.mode = 'captions-only';
      active.record.notes.push(`no audio source yet: ${started?.error || 'unknown'} — captions-only until armed`);
      unarmedSince = null;
      startWatchdog();
      // Genuinely no audio source exists. Announce via the same amber/red split tick() uses —
      // at t=0 with zero captions yet this lands amber (warming up), never red on arrival.
      await announceCaptionsOnlyHealth(startedAt);
      await persistActive();
      return { ok: true, sessionId: record.sessionId, mode: 'captions-only' };
    }
    record.notes.push(`recorder failed to start: ${started?.error || 'unknown'}`);
    await raiseAlert({
      code: 'recorder-start-failed',
      level: 'red',
      title: 'RichOS: capture did NOT start',
      message: `This call is not being recorded: ${started?.error || 'the recorder could not start'}`,
      sessionId: record.sessionId,
      force: true,
    });
    await finalize('start-failed');
    return { ok: false, error: started?.error || 'recorder-start-failed' };
  }

  active.audioActive = true;
  if (mode === 'full' && (started.micOnlyFailover || !started.hasMic)) {
    for (const problem of started.problems || []) record.notes.push(problem);
    await raiseAlert({
      code: 'partial-start',
      level: 'red',
      title: 'RichOS: only part of this call is being captured',
      message: (started.problems || []).join(' | ') || 'one audio channel could not be acquired',
      sessionId: record.sessionId,
      force: true,
    });
  }
  if (mode !== 'full' && !started.hasMic) {
    // Tab was never expected here; if the mic also failed we are effectively captions-only.
    active.record.mode = 'captions-only';
    for (const problem of started.problems || []) record.notes.push(problem);
  }

  unarmedSince = null;
  await maybeShowDisclosure(tabId, settings);
  startWatchdog();

  if (mode === 'full') {
    await setHealth({ level: 'green', text: badgeTextFor('green'), title: `RichOS: recording ${platform.label}` });
    await notifyRoutine({
      title: 'RichOS: capture started',
      message: `${platform.label} — saving to ${await dropRoot()}/${record.dir}`,
    });
  } else {
    // Mic + captions are live; the red ARM prompt drives the one click that adds tab audio.
    await raiseTabAudioArmAlert(platform);
  }
  return { ok: true, sessionId: record.sessionId, mode: active.record.mode };
}

/**
 * The CEO invoked the extension on a tab that already has a mic+captions (or captions-only)
 * session — add the ground-truth tab audio.
 * @param {number} tabId
 * @param {string} trigger
 */
async function upgradeToFullAudio(tabId, trigger) {
  const settings = await getModuleSettings(MODULE_ID);
  const minted = await mintStreamId(tabId);
  if (!minted.ok) {
    // Still refused: stay in the current mode and keep the ARM prompt up.
    return { ok: false, error: minted.error, needsInvocation: minted.needsInvocation, sessionId: active.record.sessionId };
  }
  active.record.notes.push(`tab audio armed via ${trigger} — upgrading to full capture`);

  if (!active.audioActive) {
    // captions-only → start the recorder fresh with tab (and retry the mic).
    await ensureOffscreen();
    const started = await callOffscreen({
      type: 'cc:start',
      sessionId: active.record.sessionId,
      streamId: minted.streamId,
      settings,
      expectTab: true,
    });
    if (!started?.ok) {
      await raiseAlert({
        code: 'recorder-start-failed',
        level: 'red',
        title: 'RichOS: audio capture did NOT start',
        message: `Captions are still being collected, but audio could not start: ${started?.error || 'unknown'}`,
        sessionId: active.record.sessionId,
        force: true,
      });
      return { ok: false, error: started?.error || 'recorder-start-failed', sessionId: active.record.sessionId };
    }
    active.audioActive = true;
  } else {
    // mic+captions running → attach the tab source to the live recorder (new part).
    const result = await callOffscreen({ type: 'cc:reattach-tab', streamId: minted.streamId });
    if (!result?.ok) {
      await raiseAlert({
        code: 'tab-arm-failed',
        level: 'red',
        title: 'RichOS: could not add tab audio',
        message: `Your microphone and captions are still being captured. Tab audio failed: ${result?.error || 'unknown'}`,
        sessionId: active.record.sessionId,
      });
      return { ok: false, error: result?.error || 'reattach-failed', sessionId: active.record.sessionId };
    }
  }

  active.awaitingTabAudio = false;
  active.state.awaitingTabAudio = false;
  active.state.tabEnabled = true;
  active.record.mode = 'full';
  active.attempts = {};
  await setHealth({ level: 'green', text: badgeTextFor('green'), title: `RichOS: recording ${active.record.platform.label} (full)` });
  await persistActive();
  return { ok: true, sessionId: active.record.sessionId, mode: 'full', upgraded: true };
}

/**
 * Red ARM prompt for the one click that adds tab-audio ground truth. This fires only while mic
 * audio (a real audio channel) is already running and merely awaiting the tab-audio upgrade —
 * "audio was expected [and is present via the mic]" stays red, unchanged by the 2026-08-23
 * captions-only-amber decision below, because this is not the degraded-but-working state; a
 * real audio channel already exists and the ground-truth channel is simply missing.
 * @param {any} platform
 */
async function raiseTabAudioArmAlert(platform) {
  await setHealth({
    level: 'red',
    text: 'ARM',
    title: `RichOS: ${platform.label} — recording mic + captions, click to add tab audio`,
  });
  await raiseAlert({
    code: 'needs-invocation',
    level: 'red',
    title: 'RichOS: click to capture the full call',
    message:
      'Your microphone and the live captions are being captured now. Click the RichOS icon on the call tab (or press Alt+Shift+L) to add the other side\'s tab audio — the ground-truth recording.',
  });
}

/**
 * Evaluate + announce health for a session with NO audio source at all (`mode: 'captions-only'`,
 * `active.audioActive === false`) — captions are the only channel running. Shared by the initial
 * arm (`beginSession`) and every watchdog tick (`tick()`), so the badge/alert decision for this
 * state lives in exactly one place and can never drift between "just armed" and "still running".
 *
 * CEO decision 2026-08-23: a genuine captions-only call that IS capturing captions is AMBER
 * ("degraded, but working — get ground truth"), never red. Red is reserved for true failure:
 * the caption adapter breaking, no caption ever landing, or captions themselves stalling out —
 * see `evaluateCaptionsOnlyHealth`, the single source of truth for this split.
 * @param {number} [now]
 */
async function announceCaptionsOnlyHealth(now = Date.now()) {
  if (!active) return;
  const captionsHealth = evaluateCaptionsOnlyHealth(
    {
      startedAt: active.record.startedAt,
      lastCaptionAt: active.captions.lastCaptionAt,
      degraded: active.captions.degraded,
    },
    now,
  );
  active.lastEval = { level: captionsHealth.level, reasons: captionsHealth.reasons, actions: [], signals: {}, at: now };
  accrueHealth(active.record, { level: captionsHealth.level });
  const detail = captionsHealth.reasons[0]?.detail || '';

  await setHealth({
    level: captionsHealth.level,
    text: 'ARM',
    title:
      captionsHealth.level === 'amber'
        ? `RichOS: ${active.record.platform.label} — captions-only (degraded), ${active.captions.count} captions so far, click to add audio`
        : `RichOS: ${active.record.platform.label} — captions only, NO audio, click to record audio`,
  });
  await raiseAlert({
    code: captionsHealth.level === 'red' ? 'needs-invocation' : 'captions-only-degraded',
    level: captionsHealth.level,
    title:
      captionsHealth.level === 'red'
        ? 'RichOS: click to capture the full call'
        : 'RichOS: captions-only — click to add audio (ground truth)',
    message: `${detail}. Click the RichOS icon on the call tab, or press Alt+Shift+L.`,
    sessionId: active.record.sessionId,
  });
}

/** Arm whatever tab is currently active (toolbar/keyboard path — a real invocation). */
export async function armActiveTab(trigger = 'popup') {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return { ok: false, error: 'no active tab' };
  return armTab(tab.id, trigger);
}

/**
 * Participant-facing disclosure. OFF by default; only injected when the CEO (or a RichOS
 * customer in an all-party-consent jurisdiction) turns it on.
 */
async function maybeShowDisclosure(tabId, settings) {
  if (!settings.disclosureBanner) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      args: [settings.disclosureText || CAPTURE_DEFAULTS.disclosureText],
      func: (text) => {
        const el = document.createElement('div');
        el.textContent = text;
        el.setAttribute('data-richos-disclosure', '1');
        el.style.cssText =
          'position:fixed;z-index:2147483647;left:50%;transform:translateX(-50%);bottom:16px;' +
          'background:#111;color:#fff;font:13px/1.4 system-ui,sans-serif;padding:8px 14px;' +
          'border-radius:999px;opacity:.92;pointer-events:none';
        document.documentElement.appendChild(el);
      },
    });
  } catch (err) {
    // Missing host permission is the usual cause; the CEO's default has this off anyway.
    active?.record.notes.push(`disclosure banner failed: ${String((err && err.message) || err)}`);
  }
}

// ---------------------------------------------------------------------------------------
// Transport sink — native-messaging streaming (default) with a Downloads runtime fallback
// ---------------------------------------------------------------------------------------

/**
 * Decide + open the transport for this session. Native-messaging streaming to the local RichOS
 * service is the DEFAULT: it removes the Downloads hop entirely (the host writes the contract dir
 * straight into loro and runs the pipeline). If the service is not installed/reachable, `active.sink`
 * stays `downloads` and everything works exactly as before — the service is NEVER a dependency for
 * capture to keep working (architecture §5.1). On success the session record is stamped with the browser
 * ownership block and streamed as `session-start` before any audio flows.
 * @param {Record<string, any>} record
 */
async function setupSink(record) {
  if (!active) return;
  active.sink = 'downloads';
  active.native = null;
  if (typeof chrome === 'undefined' || !chrome.runtime || !chrome.runtime.connectNative) return;
  const client = new NativeHostClient();
  let connected = false;
  try {
    connected = await client.connect();
  } catch {
    connected = false;
  }
  if (!connected) {
    record.notes.push('native host not reachable at start — using the Downloads capture path');
    return;
  }
  try {
    // Surface-agnostic ownership handshake (§5.4): a browser-tab call always wins, but the extension
    // announces it so any system-capturing companion stands down. The result is advisory here.
    await client.claim({ sessionId: record.sessionId, processHint: 'the browser' });
  } catch {
    /* claim is advisory for the extension; never let it block capture */
  }
  record.capture = record.capture || {};
  record.capture.source = SURFACE;
  Object.assign(record, withBrowserOwnership(record, { processHint: 'the browser' }));
  const started = await client.startSession(record);
  if (!started) {
    record.notes.push('native host did not ack session-start — using the Downloads capture path');
    try {
      client._port?.disconnect();
    } catch {
      /* ignore */
    }
    return;
  }
  active.native = client;
  active.sink = 'native';
  record.notes.push('native-messaging transport ACTIVE: audio streams to the local service (Downloads fallback armed)');
}

/** Base64-encode an ArrayBuffer in the service worker (no Buffer; chunked to bound the call stack). */
function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
  }
  return btoa(binary);
}

/**
 * Stream one just-committed chunk to the host, in `seq` order. The chunk read here is the EXACT
 * durable record the Downloads path would assemble, so the bytes that cross native messaging are
 * byte-identical to the fallback (collector-path parity). Any failure demotes to Downloads — the
 * chunk is still safe in IndexedDB, so nothing is ever lost.
 * @param {string} sessionId @param {number} seq @param {number} part
 */
function streamChunkToHost(sessionId, seq, part) {
  if (!active || !active.native) return;
  active.nativeChain = active.nativeChain
    .then(async () => {
      if (!active || active.sink !== 'native' || !active.native) return;
      let chunk;
      try {
        chunk = await get(DB.stores.chunks, [sessionId, seq]);
      } catch (err) {
        await demoteToDownloads(`chunk read failed: ${String((err && err.message) || err)}`);
        return;
      }
      if (!chunk || !chunk.data) return;
      const ok = active.native.sendChunk(sessionId, part, arrayBufferToBase64(chunk.data));
      if (!ok || active.native.available === false) {
        await demoteToDownloads('native port closed mid-stream');
        return;
      }
      active.streamedChunks += 1;
      active.streamedBytes += chunk.bytes || 0;
    })
    .catch(() => {});
}

/**
 * The local service became unreachable mid-call. Flip to the Downloads path so capture continues
 * with NO lost audio (every chunk is already durable in IndexedDB; the full session is exported to
 * Downloads at finalize). Write session.json to Downloads now, since native mode had not.
 * @param {string} reason
 */
async function demoteToDownloads(reason) {
  if (!active || active.sink !== 'native') return;
  active.sink = 'downloads';
  const client = active.native;
  active.native = null;
  active.record.notes.push(`native transport degraded (${reason}) — switched to Downloads fallback; audio is safe in the browser`);
  try {
    client?._port?.disconnect();
  } catch {
    /* ignore */
  }
  await writeSessionFile(active.record);
  await raiseAlert({
    code: 'native-transport-degraded',
    level: 'amber',
    title: 'RichOS: switched to the Downloads capture path',
    message: `The local service became unreachable (${reason}). Capture continues to Downloads — no audio is lost.`,
    sessionId: active.record.sessionId,
  });
}

/**
 * Build the pipeline's audio accounting (parts/bytes/chunks) from the durable chunks in IndexedDB.
 * Used for the native `session-close` so `hasUsableAudio` is true and the host runs the pipeline.
 * @param {string} sessionId
 * @returns {Promise<{parts: any[], bytesTotal: number, chunkCount: number}>}
 */
async function buildStreamedParts(sessionId) {
  let chunks = [];
  try {
    chunks = await getAll(DB.stores.chunks, 'bySession', IDBKeyRange.only(sessionId));
  } catch {
    return { parts: [], bytesTotal: 0, chunkCount: 0 };
  }
  /** @type {Map<number, any>} */
  const byPart = new Map();
  let bytesTotal = 0;
  for (const c of chunks) {
    const p = byPart.get(c.part) || { part: c.part, file: FILES.audioPart(c.part), bytes: 0, chunks: 0, written: true };
    p.bytes += c.bytes;
    p.chunks += 1;
    bytesTotal += c.bytes;
    byPart.set(c.part, p);
  }
  return {
    parts: [...byPart.values()].sort((a, b) => a.part - b.part),
    bytesTotal,
    chunkCount: chunks.length,
  };
}

// ---------------------------------------------------------------------------------------
// The watchdog
// ---------------------------------------------------------------------------------------

function startWatchdog() {
  stopWatchdog();
  watchdogTimer = setInterval(() => void tick(), THRESHOLDS.heartbeatMs);
}

function stopWatchdog() {
  if (watchdogTimer) clearInterval(watchdogTimer);
  watchdogTimer = null;
}

/**
 * One evaluation pass. Runs on every recorder heartbeat, on a 1s timer while the worker is
 * alive, and on the 1-minute alarm if the worker was evicted — so the longest we can be
 * blind is one alarm tick, and any heartbeat wakes us instantly.
 */
async function tick() {
  if (!active || active.finalizing) {
    await watchUnarmedCallTabs();
    return;
  }
  const now = Date.now();
  const settings = await getModuleSettings(MODULE_ID);

  const maxMs = (settings.maxSessionMinutes || CAPTURE_DEFAULTS.maxSessionMinutes) * 60000;
  if (now - active.record.startedAt > maxMs) {
    active.record.notes.push('stopped: maximum session length reached');
    await finalize('max-duration');
    return;
  }

  // Captions-only: no recorder to evaluate. Stay loud (never silent) about the missing audio,
  // but distinguish "degraded, still working" (captions flowing → amber) from "true failure,
  // nothing captured at all" (red) — see announceCaptionsOnlyHealth / evaluateCaptionsOnlyHealth,
  // the single source of truth for this split (CEO decision 2026-08-23).
  if (!active.audioActive) {
    await announceCaptionsOnlyHealth(now);
    if (now - active.record.startedAt > 60000 && now - active.lastDiskWrite > 60000) {
      active.lastDiskWrite = now;
      await writeSessionFile(active.record);
    }
    if (now % 10000 < THRESHOLDS.heartbeatMs) await persistActive();
    return;
  }

  const evaluation = evaluateHealth(active.state, now);
  active.lastEval = { ...evaluation, at: now };
  accrueHealth(active.record, evaluation);

  if (active.awaitingTabAudio) {
    // Mic + captions are live, but tab-audio ground truth is not armed: keep the red ARM prompt.
    await setHealth({
      level: 'red',
      text: 'ARM',
      title: `RichOS: recording mic + captions (${active.captions.count} captions) — click to add tab audio`,
    });
    await raiseAlert({
      code: 'needs-invocation',
      level: 'red',
      title: 'RichOS: click to add tab audio (ground truth)',
      message: 'Your microphone and the live captions are being captured. Click the RichOS icon on the call tab (or press Alt+Shift+L) to add the other side\'s tab audio.',
      sessionId: active.record.sessionId,
    });
  } else {
    await setHealth({
      level: evaluation.level,
      text: badgeTextFor(evaluation.level),
      title: healthTitle(evaluation),
    });
  }

  if (evaluation.level === 'red') {
    for (const reason of evaluation.reasons.filter((r) => r.level === 'red')) {
      const fired = await raiseAlert({
        code: reason.code,
        level: 'red',
        title: 'RichOS: call capture problem',
        message: `${reason.detail}. Recovery is running; check the RichOS icon.`,
        sessionId: active.record.sessionId,
      });
      if (fired) active.record.alerts.push({ t: now, code: reason.code, detail: reason.detail });
    }
    // A red state is written to disk immediately (throttled), so a browser death right
    // after the failure still leaves the evidence in the drop zone.
    if (now - active.lastDiskWrite > 60000) {
      active.lastDiskWrite = now;
      await writeSessionFile(active.record);
    }
  }

  for (const action of evaluation.actions) await runRecovery(action, now);

  if (now % 10000 < THRESHOLDS.heartbeatMs) await persistActive();
}

/**
 * @param {{level: string, reasons: {code: string, level: string, detail: string}[]}} evaluation
 * @returns {string}
 */
function healthTitle(evaluation) {
  if (!active) return 'RichOS';
  const mb = (active.state.bytesTotal / 1048576).toFixed(1);
  const mins = Math.round((Date.now() - active.record.startedAt) / 60000);
  const head = `RichOS: recording ${mins}m · ${mb} MB · ${active.state.chunkCount} chunks`;
  if (evaluation.level === 'green') return `${head} · healthy`;
  return `${head}\n${evaluation.reasons.map((r) => `${r.level.toUpperCase()}: ${r.detail}`).join('\n')}`;
}

/**
 * Execute one recovery action, with per-action attempt limits and backoff.
 * @param {string} action
 * @param {number} now
 */
async function runRecovery(action, now) {
  if (!active) return;
  const attempt = active.attempts[action] || { n: 0, at: 0 };
  if (now - attempt.at < THRESHOLDS.recoverBackoffMs) return;
  if (attempt.n >= THRESHOLDS.recoverMaxAttempts) return;
  attempt.n += 1;
  attempt.at = now;
  active.attempts[action] = attempt;
  active.record.recovery.push({ t: now, action, attempt: attempt.n });

  switch (action) {
    case ACTIONS.restartRecorder: {
      const result = await callOffscreen({ type: 'cc:restart-recorder' });
      if (!result?.ok) await recreateOffscreenAndRestart();
      break;
    }
    case ACTIONS.reattachTab: {
      const minted = await mintStreamId(active.tabId);
      const result = await callOffscreen({ type: 'cc:reattach-tab', streamId: minted.ok ? minted.streamId : null });
      if (!result?.ok) {
        active.state.micOnlyFailover = true;
        await raiseAlert({
          code: 'tab-failover',
          level: 'red',
          title: 'RichOS: recording your microphone only',
          message: minted.needsInvocation
            ? 'Chrome needs you to click the RichOS icon on the call tab to give the tab audio back.'
            : `Tab audio could not be recovered (${result?.error || 'unknown'}). Your side is still being recorded.`,
          sessionId: active.record.sessionId,
        });
      }
      break;
    }
    case ACTIONS.reacquireMic: {
      const result = await callOffscreen({ type: 'cc:reacquire-mic' });
      if (!result?.ok) {
        await raiseAlert({
          code: 'mic-lost',
          level: 'red',
          title: 'RichOS: your microphone is not being recorded',
          message: `The microphone could not be re-acquired (${result?.error || 'unknown'}). The other side is still being captured.`,
          sessionId: active.record.sessionId,
        });
      }
      break;
    }
    case ACTIONS.recreateOffscreen:
      await recreateOffscreenAndRestart();
      break;
    default:
      break;
  }
}

/** The recorder document itself is wedged or gone: rebuild it and start a new part. */
async function recreateOffscreenAndRestart() {
  if (!active) return;
  const settings = await getModuleSettings(MODULE_ID);
  await closeOffscreen();
  await ensureOffscreen();
  const minted = await mintStreamId(active.tabId);
  const started = await callOffscreen({
    type: 'cc:start',
    sessionId: active.record.sessionId,
    streamId: minted.ok ? minted.streamId : null,
    settings,
  });
  active.record.recovery.push({ t: Date.now(), action: 'recreate-offscreen', ok: Boolean(started?.ok) });
  if (!started?.ok) {
    await raiseAlert({
      code: 'recorder-unrecoverable',
      level: 'red',
      title: 'RichOS: recording has STOPPED',
      message: `The recorder could not be restarted (${started?.error || 'unknown'}). Everything captured so far is safe on disk.`,
      sessionId: active.record.sessionId,
      force: true,
    });
  } else {
    // A brand new recorder means a brand new part; treat its state as fresh.
    active.state.lastChunkAt = null;
    active.state.startedAt = Date.now();
  }
}

/** Alarm when a recognized call tab is open and NOT being captured. */
async function watchUnarmedCallTabs() {
  const settings = await getModuleSettings(MODULE_ID);
  if (!settings.enabled) return;
  const tabs = await chrome.tabs.query({});
  const callTabs = tabs.filter((t) => isCallTab({ url: t.url, audible: t.audible }));
  if (!callTabs.length) {
    unarmedSince = null;
    if (!active) await setHealth({ level: 'idle', text: '', title: 'RichOS: idle' });
    return;
  }
  if (active) return;
  const now = Date.now();
  if (unarmedSince == null) unarmedSince = now;
  if (now - unarmedSince < THRESHOLDS.unarmedAlarmMs) return;

  await setHealth({ level: 'red', text: 'ARM', title: 'RichOS: a call is open and NOT being captured' });
  await raiseAlert({
    code: 'call-not-captured',
    level: 'red',
    title: 'RichOS: this call is NOT being recorded',
    message: 'A call tab is open with no capture running. Click the RichOS icon on that tab (or press the shortcut) to start.',
  });
}

// ---------------------------------------------------------------------------------------
// Tab lifecycle
// ---------------------------------------------------------------------------------------

async function onTabChanged(tabId, changeInfo, tab) {
  if (active && tabId === active.tabId) {
    // Navigating away from the meeting ends the call for our purposes.
    if (changeInfo.url && !detectPlatform(changeInfo.url) && detectPlatform(active.record.tab.url || '')) {
      active.record.notes.push('call tab navigated away');
      await finalize('tab-navigated');
      return;
    }
  }
  if (changeInfo.status === 'complete' || changeInfo.audible != null || changeInfo.url) await scanTabs();
}

async function onTabRemoved(tabId) {
  seenCallTabs.delete(tabId);
  if (active && tabId === active.tabId && !active.finalizing) {
    active.record.notes.push('call tab was closed');
    await finalize('tab-closed');
  }
}

/** Auto-arm pass. */
async function scanTabs() {
  const settings = await getModuleSettings(MODULE_ID);
  if (!settings.enabled) return;
  const now = Date.now();
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (!tab.id || !tab.url) continue;
    if (!seenCallTabs.has(tab.id) && (detectPlatform(tab.url) || tab.audible)) seenCallTabs.set(tab.id, now);
  }
  if (active) return;

  for (const tab of tabs) {
    if (!tab.id || !tab.url) continue;
    const decision = shouldAutoArm(
      { url: tab.url, audible: tab.audible, openedAt: seenCallTabs.get(tab.id) || now },
      settings,
      now,
    );
    if (!decision.arm) continue;
    const result = await armTab(tab.id, 'auto');
    if (result.ok) return;
    if (result.needsInvocation) break; // the CEO has been alarmed; stop retrying in a loop
  }
  await watchUnarmedCallTabs();
}

// ---------------------------------------------------------------------------------------
// Finalization + export
// ---------------------------------------------------------------------------------------

/**
 * Close a session: stop the recorder, write every artifact to the drop zone, verify, alarm
 * if the result is not trustworthy.
 * @param {string} reason
 */
export async function finalize(reason) {
  if (!active || active.finalizing) return { ok: false, error: 'nothing to finalize' };
  active.finalizing = true;
  stopWatchdog();
  const { record } = active;
  try {
    return await runFinalize(record, reason);
  } catch (err) {
    // Finalization must never wedge: a half-finished close would leave the badge stuck and
    // the next call unable to arm. Alarm loudly and clear the state either way — the audio
    // itself is still in IndexedDB and gets exported by orphan recovery on the next boot.
    const detail = String((err && err.stack) || err);
    record.notes.push(`finalization failed: ${detail}`);
    await raiseAlert({
      code: 'finalise-failed',
      level: 'red',
      title: 'RichOS: saving this call did not complete',
      message: `${record.sessionId}: ${detail.split('\n')[0]}. The audio is still in the browser and will be recovered on restart.`,
      sessionId: record.sessionId,
      force: true,
    });
    await chrome.storage.local.remove(KEYS.activeSession);
    active = null;
    await setHealth({ level: 'red', text: '!', title: 'RichOS: last session did not save cleanly' });
    return { ok: false, error: detail };
  }
}

/**
 * Dispatch finalization to the transport that captured this session. Native-messaging sessions are
 * closed over the wire (the host finalizes the contract dir + runs the pipeline); Downloads sessions
 * assemble from IndexedDB as before. A native session that degraded mid-call already flipped
 * `active.sink` to `downloads`, so it finalizes the Downloads way from the same durable chunks.
 * @param {any} record
 * @param {string} reason
 */
async function runFinalize(record, reason) {
  if (active && active.sink === 'native' && active.native) return runFinalizeNative(record, reason);
  return runFinalizeDownloads(record, reason);
}

/**
 * Close a native-messaging session: stop the recorder, flush the streamed chunks in order, send the
 * final accounting as `session-close` (which triggers the host pipeline), then drop the local IDB
 * copies. If the host vanishes during close, fall back to a full Downloads export from IndexedDB —
 * nothing is ever lost.
 * @param {any} record
 * @param {string} reason
 */
async function runFinalizeNative(record, reason) {
  const settings = await getModuleSettings(MODULE_ID);
  const native = active.native;
  const stopped = await callOffscreen({ type: 'cc:stop', reason });
  // Let every streamed chunk reach the host, in order, before we close.
  await active.nativeChain.catch(() => {});
  record.endedAt = Date.now();
  record.status = reason === 'recovered' ? SESSION_STATUS.recovered : SESSION_STATUS.closed;
  record.notes.push(`closed: ${reason} (native-messaging transport)`);
  if (stopped?.lastError) record.notes.push(`recorder last error: ${stopped.lastError}`);

  // The flush may have demoted us (host died) — if so, finish the Downloads way (audio all in IDB).
  if (active.sink !== 'native' || !active.native) return runFinalizeDownloads(record, reason);

  const audio = await buildStreamedParts(record.sessionId);
  record.audio = audio;

  const closed = await native.closeSession(record.sessionId, {
    endedAt: record.endedAt,
    status: record.status,
    audio,
    captions: record.captions,
    health: record.health,
    notes: record.notes,
  });
  if (!closed) {
    record.notes.push('native session-close was not acked — exporting to Downloads as a safety net');
    active.sink = 'downloads';
    active.native = null;
    try {
      native._port?.disconnect();
    } catch {
      /* ignore */
    }
    return runFinalizeDownloads(record, reason);
  }
  try {
    native._port?.disconnect();
  } catch {
    /* ignore */
  }

  // Chunks are now safe in the loro drop zone via the host; drop the local copies unless asked to keep.
  if (!settings.keepChunksAfterExport) {
    await callOffscreen({ type: 'cc:purge', sessionId: record.sessionId });
    try {
      await deleteBySession(DB.stores.captions, record.sessionId);
    } catch {
      /* harmless */
    }
  }

  await indexSession(record, { ok: true, problems: [] });
  await notifyRoutine({
    title: 'RichOS: capture streamed to the local service',
    message: `${(audio.bytesTotal / 1048576).toFixed(1)} MB · ${audio.chunkCount} chunks · native-messaging → loro`,
  });
  await chrome.storage.local.remove(KEYS.activeSession);
  active = null;
  await setHealth({ level: 'idle', text: '', title: 'RichOS: idle' });
  if (!(await anyActiveWork())) await closeOffscreen();
  return { ok: true, sessionId: record.sessionId, transport: 'native', verdict: { ok: true, problems: [] } };
}

/**
 * @param {any} record
 * @param {string} reason
 */
async function runFinalizeDownloads(record, reason) {
  const settings = await getModuleSettings(MODULE_ID);

  const stopped = await callOffscreen({ type: 'cc:stop', reason });
  record.endedAt = Date.now();
  record.status = reason === 'recovered' ? SESSION_STATUS.recovered : SESSION_STATUS.closed;
  record.notes.push(`closed: ${reason}`);
  if (stopped?.lastError) record.notes.push(`recorder last error: ${stopped.lastError}`);
  if (stopped?.micOnlyFailover) record.notes.push('finished in microphone-only failover');

  // exportSession returns the audio accounting itself — reading `.audio` off it threw
  // mid-finalize and left the session `open` on disk (caught by the live harness).
  record.audio = await exportSession(record);
  // The secondary caption channel is written on its own durable file, and its count comes from
  // the same records — captions never inflate or vanish relative to what is on disk.
  await exportCaptions(record);

  const verdict = verifySession(record);
  record.verification = verdict;
  await writeSessionFile(record, { overwrite: true });

  if (!verdict.ok) {
    await raiseAlert({
      code: 'session-suspect',
      level: 'red',
      title: 'RichOS: this call may not have been captured properly',
      message: `${record.sessionId}: ${verdict.problems.join('; ')}`,
      sessionId: record.sessionId,
      force: true,
    });
  }
  if (verdict.ok && !settings.keepChunksAfterExport) {
    await callOffscreen({ type: 'cc:purge', sessionId: record.sessionId });
    // Captions are persisted by the service worker (not the offscreen recorder), so purge them here.
    try {
      await deleteBySession(DB.stores.captions, record.sessionId);
    } catch {
      /* leaving caption rows behind is harmless; never let cleanup break finalization */
    }
  }

  await indexSession(record, verdict);
  await notifyRoutine({
    title: verdict.ok ? 'RichOS: capture saved' : 'RichOS: capture finished with problems',
    message: `${(record.audio.bytesTotal / 1048576).toFixed(1)} MB · ${verdict.durationSeconds}s · ${await dropRoot()}/${record.dir}`,
  });
  await chrome.storage.local.remove(KEYS.activeSession);
  active = null;
  await setHealth({
    level: verdict.ok ? 'idle' : 'red',
    text: verdict.ok ? '' : '!',
    title: verdict.ok ? 'RichOS: idle' : 'RichOS: last session needs attention',
  });
  if (!(await anyActiveWork())) await closeOffscreen();
  return { ok: true, sessionId: record.sessionId, verdict };
}

/** @returns {Promise<boolean>} */
async function anyActiveWork() {
  return Boolean(active);
}

/**
 * Move audio + health out of IndexedDB into the drop zone.
 * @param {any} record
 */
async function exportSession(record) {
  const audio = { parts: [], bytesTotal: 0, chunkCount: 0 };
  await ensureOffscreen();
  const assembled = await callOffscreen({ type: 'cc:assemble', sessionId: record.sessionId });
  if (assembled?.ok) {
    for (const part of assembled.parts || []) {
      const filename = dropPath(await dropRoot(), audioFileName(record, part.part));
      const written = await writeUrl(filename, part.url);
      audio.parts.push({
        part: part.part,
        file: FILES.audioPart(part.part),
        bytes: part.bytes,
        chunks: part.chunks,
        firstChunkAt: part.firstChunkAt,
        lastChunkAt: part.lastChunkAt,
        written: Boolean(written.ok),
        error: written.ok ? undefined : written.error,
      });
      audio.bytesTotal += part.bytes;
      audio.chunkCount += part.chunks;
    }
  } else {
    record.notes.push(`audio assembly failed: ${assembled?.error || 'unknown'}`);
  }

  const health = await callOffscreen({ type: 'cc:health-jsonl', sessionId: record.sessionId });
  if (health?.ok && health.text) {
    await writeText(dropPath(await dropRoot(), record.dir, FILES.health), health.text, {
      mime: 'application/x-ndjson',
      overwrite: true,
    });
    record.health.recordsWritten = health.count;
  }
  return audio;
}

/**
 * Write the captions channel to `captions.ndjson`. The record's caption count is set from the
 * SAME rows that are written — the one authoritative count (collector-path parity).
 * @param {any} record
 * @returns {Promise<number>} caption rows written
 */
async function exportCaptions(record) {
  let rows = [];
  try {
    rows = await getAll(DB.stores.captions, 'bySession', IDBKeyRange.only(record.sessionId));
  } catch (err) {
    record.notes.push(`caption read failed at finalize: ${String((err && err.message) || err)}`);
    return 0;
  }
  rows.sort((a, b) => a.seq - b.seq);
  if (rows.length) {
    const text = rows
      .map((r) =>
        JSON.stringify({
          speaker: r.speaker,
          text: r.text,
          t: r.t,
          firstT: r.firstT,
          revision: r.revision,
          id: r.id,
          language: r.language,
          adapter: r.adapter,
        }),
      )
      .join('\n');
    const written = await writeText(dropPath(await dropRoot(), record.dir, FILES.captions), text, {
      mime: 'application/x-ndjson',
      overwrite: true,
    });
    if (!written.ok) record.notes.push(`captions.ndjson write failed: ${written.error || 'unknown'}`);
  }
  // Authoritative: the count is the number of records actually written.
  record.captions.count = rows.length;
  record.captions.available = record.captions.available || rows.length > 0;
  if (!record.captions.speakers?.length) {
    record.captions.speakers = [...new Set(rows.map((r) => r.speaker).filter(Boolean))];
  }
  return rows.length;
}

/** @returns {Promise<string>} */
async function dropRoot() {
  const core = await getModuleSettings('core');
  return core.dropFolder || 'richos-capture';
}

/**
 * Write `session.json`. Called at START (status `open`) and again at finalization.
 * @param {any} record
 * @param {{overwrite?: boolean}} [opts]
 */
async function writeSessionFile(record, opts = {}) {
  const filename = dropPath(await dropRoot(), record.dir, FILES.session);
  const result = await writeText(filename, JSON.stringify(record, null, 2), {
    mime: 'application/json',
    overwrite: opts.overwrite !== false,
  });
  if (!result.ok) {
    await raiseAlert({
      code: 'drop-zone-write-failed',
      level: 'red',
      title: 'RichOS: cannot write to the drop zone',
      message: `${result.error || 'unknown error'} — capture continues in the browser, but nothing is reaching disk.`,
      sessionId: record.sessionId,
    });
  }
  return result;
}

/** Append to the local session index (used by the popup and by recovery). */
async function indexSession(record, verdict) {
  const stored = (await chrome.storage.local.get(KEYS.sessionIndex))[KEYS.sessionIndex] || [];
  stored.push({
    sessionId: record.sessionId,
    startedAt: record.startedAt,
    endedAt: record.endedAt,
    platform: record.platform.id,
    bytes: record.audio.bytesTotal,
    status: record.status,
    ok: verdict.ok,
    problems: verdict.problems,
  });
  await chrome.storage.local.set({ [KEYS.sessionIndex]: stored.slice(-100) });
}

async function persistActive() {
  if (!active) return;
  await chrome.storage.local.set({
    [KEYS.activeSession]: {
      record: active.record,
      tabId: active.tabId,
      state: active.state,
      awaitingTabAudio: active.awaitingTabAudio,
      audioActive: active.audioActive,
      captions: active.captions,
      // Informational only: a restarted worker cannot restore a native port, so recovery always
      // finalizes via the Downloads fallback from the durable IndexedDB chunks.
      sink: active.sink,
      savedAt: Date.now(),
    },
  });
}

// ---------------------------------------------------------------------------------------
// Crash recovery
// ---------------------------------------------------------------------------------------

/**
 * Called on every service-worker boot. Two cases:
 *   · the recorder is still alive (the worker was merely evicted) → re-attach and continue;
 *   · the recorder is gone (tab crash, extension reload, browser restart) → close the
 *     session out of IndexedDB, export what exists, and alarm.
 */
export async function recoverAfterRestart() {
  const saved = (await chrome.storage.local.get(KEYS.activeSession))[KEYS.activeSession];
  if (saved?.record) {
    const live = (await offscreenExists()) ? await callOffscreen({ type: 'cc:status' }) : null;
    if (live?.active && live.sessionId === saved.record.sessionId) {
      active = {
        record: saved.record,
        state: { ...saved.state },
        tabId: saved.tabId,
        lastEval: null,
        attempts: {},
        lastDiskWrite: 0,
        finalizing: false,
        awaitingTabAudio: Boolean(saved.awaitingTabAudio),
        audioActive: saved.audioActive !== false,
        captions: saved.captions || { available: false, adapter: null, adapterVersion: null, count: 0, seq: 0, lastCaptionAt: null, degraded: false },
      };
      active.record.notes.push('service worker restarted mid-session; recorder was still alive');
      startWatchdog();
      await setHealth({ level: 'amber', text: badgeTextFor('amber'), title: 'RichOS: reattached to a running session' });
    } else {
      active = {
        record: saved.record,
        state: saved.state || newCaptureState({ sessionId: saved.record.sessionId, startedAt: saved.record.startedAt }),
        tabId: saved.tabId,
        lastEval: null,
        attempts: {},
        lastDiskWrite: 0,
        finalizing: false,
        awaitingTabAudio: Boolean(saved.awaitingTabAudio),
        audioActive: saved.audioActive !== false,
        captions: saved.captions || { available: false, adapter: null, adapterVersion: null, count: 0, seq: 0, lastCaptionAt: null, degraded: false },
      };
      active.record.status = SESSION_STATUS.interrupted;
      active.record.notes.push('recovered after an interruption (tab crash, extension reload or browser restart)');
      await raiseAlert({
        code: 'session-interrupted',
        level: 'red',
        title: 'RichOS: a recording was interrupted',
        message: `Recovering ${saved.record.sessionId} from disk. Everything written before the interruption is safe.`,
        sessionId: saved.record.sessionId,
        force: true,
      });
      await finalize('recovered');
    }
  }
  await recoverOrphans();
}

/** Chunks in IndexedDB with no session record at all — export them rather than lose them. */
async function recoverOrphans() {
  if (!(await offscreenExists())) {
    const orphanCheck = await chrome.storage.local.get(KEYS.sessionIndex);
    // Opening an offscreen document just to check is cheap and only happens at boot.
    await ensureOffscreen();
    void orphanCheck;
  }
  const result = await callOffscreen({ type: 'cc:orphans' });
  // Never export a session the recorder is still writing to: a WebM part is only playable
  // when its header chunk travels with its continuation chunks, so exporting half a part
  // (and purging it) would leave an unreadable fragment behind. Caught by the live harness.
  const live = await callOffscreen({ type: 'cc:status' });
  const busySessionId = live?.active ? live.sessionId : null;
  const ids = (result?.sessionIds || []).filter(
    (id) => id !== busySessionId && (!active || id !== active.record.sessionId),
  );
  for (const sessionId of ids) {
    const record = {
      schemaVersion: 1,
      sessionId,
      dir: sessionId,
      status: SESSION_STATUS.recovered,
      producer: { product: 'RichOS extension', module: 'call-capture', extensionVersion: chrome.runtime.getManifest?.().version },
      platform: { id: 'unknown', label: 'recovered', slug: 'recovered' },
      tab: {},
      startedAt: Date.now(),
      endedAt: Date.now(),
      capture: {},
      audio: { parts: [], bytesTotal: 0, chunkCount: 0 },
      health: { heartbeats: 0, greenSeconds: 0, amberSeconds: 0, redSeconds: 0, worstLevel: 'green' },
      alerts: [],
      recovery: [{ t: Date.now(), action: 'orphan-recovery' }],
      captions: { available: false, adapter: null, adapterVersion: null, count: 0, speakers: [], degraded: false },
      notes: ['recovered from orphaned chunks with no live session record'],
    };
    record.audio = await exportSession(record);
    await exportCaptions(record);
    await writeSessionFile(record, { overwrite: true });
    await callOffscreen({ type: 'cc:purge', sessionId });
    try {
      await deleteBySession(DB.stores.captions, sessionId);
    } catch {
      /* harmless */
    }
    await raiseAlert({
      code: 'orphan-recovered',
      level: 'amber',
      title: 'RichOS: recovered orphaned audio',
      message: `${sessionId}: ${(record.audio.bytesTotal / 1048576).toFixed(1)} MB written to the drop zone.`,
      sessionId,
      force: true,
    });
  }

  // Captions-only orphans: caption rows with no chunks and no live session — a call that
  // produced captions but never any audio (never armed, or browser died before finalize). These
  // must NOT be silently lost; recover them as flagged captions-only sessions.
  await recoverCaptionOnlyOrphans(new Set([...ids, busySessionId, active?.record.sessionId].filter(Boolean)));

  if (!active && !ids.length) await closeOffscreen();
}

/**
 * @param {Set<string>} handled session ids already dealt with this boot
 */
async function recoverCaptionOnlyOrphans(handled) {
  let captionRows = [];
  try {
    captionRows = await getAll(DB.stores.captions);
  } catch {
    return;
  }
  const ids = [...new Set(captionRows.map((r) => r.sessionId))].filter((id) => id && !handled.has(id));
  for (const sessionId of ids) {
    const record = {
      schemaVersion: 1,
      sessionId,
      dir: sessionId,
      status: SESSION_STATUS.recovered,
      mode: 'captions-only',
      producer: { product: 'RichOS extension', module: 'call-capture', extensionVersion: chrome.runtime.getManifest?.().version },
      platform: { id: 'unknown', label: 'recovered', slug: 'recovered' },
      tab: {},
      startedAt: Date.now(),
      endedAt: Date.now(),
      capture: {},
      audio: { parts: [], bytesTotal: 0, chunkCount: 0 },
      health: { heartbeats: 0, greenSeconds: 0, amberSeconds: 0, redSeconds: 0, worstLevel: 'green' },
      alerts: [],
      recovery: [{ t: Date.now(), action: 'caption-only-orphan-recovery' }],
      captions: { available: true, adapter: null, adapterVersion: null, count: 0, speakers: [], degraded: false },
      notes: ['recovered captions with NO audio — the call was not fully captured'],
    };
    const count = await exportCaptions(record);
    record.verification = verifySession(record);
    await writeSessionFile(record, { overwrite: true });
    try {
      await deleteBySession(DB.stores.captions, sessionId);
    } catch {
      /* harmless */
    }
    await raiseAlert({
      code: 'captions-only-recovered',
      level: 'red',
      title: 'RichOS: a call was captured as captions only — NO audio',
      message: `${sessionId}: ${count} captions but no audio. The call was not fully captured; investigate.`,
      sessionId,
      force: true,
    });
  }
}

// ---------------------------------------------------------------------------------------
// Messages + status
// ---------------------------------------------------------------------------------------

/**
 * @param {any} msg
 * @param {chrome.runtime.MessageSender} [sender]
 */
async function onMessage(msg, sender) {
  switch (msg.type) {
    case 'cc:heartbeat': {
      if (!active || msg.sessionId !== active.record.sessionId) return { ok: true, ignored: true };
      applyHeartbeat(active.state, msg);
      if (active.sink === 'native' && active.native) {
        // Forward the health record as the outside-the-browser liveness signal + health.ndjson line.
        const { target, module, type, ...line } = msg;
        active.native.post(buildHealthMessage(active.record.sessionId, line));
      }
      await tick();
      return { ok: true };
    }
    case 'cc:chunk': {
      if (!active || msg.sessionId !== active.record.sessionId) return { ok: true, ignored: true };
      active.state.lastChunkAt = msg.t;
      active.state.chunkCount += 1;
      if (msg.bytesTotal > active.state.bytesTotal) active.state.bytesGrewAt = msg.t;
      active.state.bytesTotal = msg.bytesTotal;
      // Native transport: stream this exact durable chunk straight to the local service, in order.
      if (active.sink === 'native') streamChunkToHost(msg.sessionId, msg.seq, msg.part);
      return { ok: true };
    }
    case 'cc:chunk-error':
      await raiseAlert({
        code: 'chunk-write-failed',
        level: 'red',
        title: 'RichOS: audio is not reaching disk',
        message: msg.error || 'a chunk could not be written to browser storage',
        sessionId: msg.sessionId,
      });
      return { ok: true };
    case 'cc:recorder-error':
      await raiseAlert({
        code: 'recorder-error',
        level: 'red',
        title: 'RichOS: the recorder reported an error',
        message: msg.error || 'unknown recorder error',
        sessionId: msg.sessionId,
      });
      return { ok: true };
    case 'cc:track-ended':
      if (active) active.record.notes.push(`${msg.which} track ended`);
      await tick();
      return { ok: true };
    case 'cc:captions-attached':
      return handleCaptionsAttached(msg, sender);
    case 'cc:caption':
      return handleCaption(msg, sender);
    case 'cc:captions-degraded':
      return handleCaptionsDegraded(msg);
    case 'cc:captions-detached':
      return { ok: true };
    case 'cc:arm-active-tab':
      return armActiveTab(msg.trigger || 'popup');
    case 'cc:arm-tab':
      return armTab(msg.tabId, msg.trigger || 'popup');
    case 'cc:stop':
      return finalize(msg.reason || 'manual');
    case 'cc:status':
      return { ok: true, status: await getStatus() };
    case 'cc:scan':
      await scanTabs();
      return { ok: true };
    default:
      return undefined;
  }
}

// ---------------------------------------------------------------------------------------
// Captions — the secondary failsafe + enrichment channel
// ---------------------------------------------------------------------------------------

/**
 * A caption content script attached in a call tab. Mark the channel available and, if no
 * session is capturing that tab yet, kick an auto-start so captions are never dropped.
 * @param {any} msg
 * @param {chrome.runtime.MessageSender} [sender]
 */
async function handleCaptionsAttached(msg, sender) {
  const settings = await getModuleSettings(MODULE_ID);
  if (settings.captureCaptions === false) return { ok: true, ignored: 'captions-disabled' };
  const tabId = sender?.tab?.id;
  if (tabId != null && !active) await scanTabs();
  if (active && (tabId == null || active.tabId === tabId)) {
    active.captions.available = true;
    active.captions.adapter = msg.adapter || active.captions.adapter;
    active.captions.adapterVersion = msg.adapterVersion || active.captions.adapterVersion;
    active.record.captions.available = true;
    active.record.captions.adapter = msg.adapter || active.record.captions.adapter;
    active.record.captions.adapterVersion = msg.adapterVersion || active.record.captions.adapterVersion;
  }
  return { ok: true };
}

/**
 * Persist one deduped caption revision. The COUNT is incremented only on a successful write, so
 * the number shown anywhere is exactly the number of records that will be in `captions.ndjson`
 * (one collector path, never a second heuristic).
 * @param {any} msg
 * @param {chrome.runtime.MessageSender} [sender]
 */
async function handleCaption(msg, sender) {
  const settings = await getModuleSettings(MODULE_ID);
  if (settings.captureCaptions === false) return { ok: true, ignored: 'captions-disabled' };
  const tabId = sender?.tab?.id;
  const event = msg.event;
  if (!event || !event.text) return { ok: true };

  // Captions must be captured even before audio is armed. If nothing is capturing this call tab
  // yet, auto-start a session so the caption lands somewhere durable.
  if (!active && tabId != null) await armTab(tabId, 'auto');
  if (!active || (tabId != null && active.tabId !== tabId)) return { ok: true, ignored: 'no-matching-session' };

  active.captions.seq = (active.captions.seq || 0) + 1;
  const seq = active.captions.seq;
  try {
    await put(DB.stores.captions, {
      sessionId: active.record.sessionId,
      seq,
      speaker: event.speaker || 'unknown',
      text: event.text,
      t: event.t || Date.now(),
      firstT: event.firstT || event.t || Date.now(),
      revision: event.revision || 1,
      id: event.id != null ? String(event.id) : null,
      language: event.language || null,
      adapter: msg.adapter || active.captions.adapter,
    });
  } catch (err) {
    active.captions.degraded = true;
    active.record.captions.degraded = true;
    active.record.notes.push(`caption persist failed: ${String((err && err.message) || err)}`);
    return { ok: false, error: String((err && err.message) || err) };
  }

  // Success: count == rows persisted. Mirror onto the record for the popup and session.json.
  active.captions.count += 1;
  active.captions.available = true;
  // Native transport: forward the SAME persisted revision to the host's captions.ndjson.
  if (active.sink === 'native' && active.native) {
    active.native.post(
      buildCaptionMessage(active.record.sessionId, {
        speaker: event.speaker || 'unknown',
        text: event.text,
        t: event.t || Date.now(),
        firstT: event.firstT || event.t || Date.now(),
        revision: event.revision || 1,
        id: event.id != null ? String(event.id) : null,
        language: event.language || null,
        adapter: msg.adapter || active.captions.adapter,
      }),
    );
  }
  // Drives the captions-only amber/red split (evaluateCaptionsOnlyHealth): wall-clock receipt
  // time, not the caption's own (possibly backdated) `event.t` — this is a liveness signal for
  // the channel, not a content timestamp.
  active.captions.lastCaptionAt = Date.now();
  active.record.captions.available = true;
  active.record.captions.count = active.captions.count;
  active.record.captions.adapter = msg.adapter || active.record.captions.adapter;
  active.record.captions.adapterVersion = msg.adapterVersion || active.record.captions.adapterVersion;
  if (event.speaker && !active.record.captions.speakers.includes(event.speaker)) {
    active.record.captions.speakers.push(event.speaker);
  }
  return { ok: true, count: active.captions.count };
}

/**
 * The caption adapter broke (Meet DOM/protocol change). Fail SOFT: record a degraded-captions
 * state, never touch the audio path, never a hard alarm — audio is the guarantee.
 * @param {any} msg
 */
async function handleCaptionsDegraded(msg) {
  if (active) {
    active.captions.degraded = true;
    active.record.captions.degraded = true;
    active.record.notes.push(`captions degraded (${msg.adapter || 'unknown'}): ${msg.detail || 'adapter error'}`);
  }
  return { ok: true };
}

/** Popup card data. Numbers come from the recorder's own accounting, never a second count. */
async function getStatus() {
  const settings = await getModuleSettings(MODULE_ID);
  const index = (await chrome.storage.local.get(KEYS.sessionIndex))[KEYS.sessionIndex] || [];
  const tabs = await chrome.tabs.query({});
  const root = await dropRoot();
  const callTabs = tabs
    .filter((t) => isCallTab({ url: t.url, audible: t.audible }))
    .map((t) => ({ tabId: t.id, title: t.title, platform: detectPlatform(t.url || '')?.label || 'audible tab' }));

  if (!active) {
    return {
      active: false,
      enabled: settings.enabled,
      armMode: settings.armMode,
      dropFolder: root,
      saveLocation: `Downloads/${root}/`,
      lastSession: index.length ? index[index.length - 1] : null,
      callTabsOpen: callTabs,
      unarmedSeconds: unarmedSince ? Math.round((Date.now() - unarmedSince) / 1000) : 0,
      recent: index.slice(-5).reverse(),
    };
  }
  const evaluation = active.lastEval || evaluateHealth(active.state, Date.now());
  return {
    active: true,
    enabled: settings.enabled,
    armMode: settings.armMode,
    sessionId: active.record.sessionId,
    platform: active.record.platform.label,
    mode: active.record.mode,
    awaitingTabAudio: active.awaitingTabAudio,
    audioActive: active.audioActive,
    // Which transport this session is using: 'native' streams straight to the local service (loro),
    // 'downloads' is the fallback path. Streamed accounting is what actually crossed the wire.
    transport: active.sink || 'downloads',
    streamedChunks: active.streamedChunks || 0,
    streamedBytes: active.streamedBytes || 0,
    dropFolder: root,
    saveLocation:
      active.sink === 'native' ? `local service → loro (${active.record.dir})` : `Downloads/${root}/${active.record.dir}/`,
    lastSession: index.length ? index[index.length - 1] : null,
    startedAt: active.record.startedAt,
    bytesTotal: active.state.bytesTotal,
    chunkCount: active.state.chunkCount,
    part: active.state.part,
    micOnlyFailover: active.state.micOnlyFailover,
    // Caption channel: count comes from the same collector path that persists captions.ndjson.
    captions: {
      available: active.captions.available,
      count: active.captions.count,
      adapter: active.captions.adapter,
      speakers: active.record.captions.speakers || [],
      degraded: active.captions.degraded,
    },
    level: evaluation.level,
    signals: evaluation.signals,
    reasons: evaluation.reasons,
    callTabsOpen: callTabs,
    recent: index.slice(-5).reverse(),
  };
}

/** Test seam: the live-capture harness drives these through the devtools protocol. */
export const __testHooks = {
  armTab,
  armActiveTab,
  finalize,
  tick,
  scanTabs,
  getStatus,
  recoverAfterRestart,
  /** Simulate a service-worker eviction: drop in-memory state and re-run the boot path. */
  async simulateWorkerRestart() {
    stopWatchdog();
    active = null;
    unarmedSince = null;
    await recoverAfterRestart();
    return getStatus();
  },
  get active() {
    return active;
  },
};

/**
 * RichOS — call-capture controller (runs in the service worker).
 *
 * Owns: arming, the second-by-second watchdog, recovery, CEO-only alarms, session records
 * and the drop-zone export. The recorder (offscreen) owns bytes; this file owns *truth about*
 * those bytes and never counts anything itself — every number it reports comes from the
 * recorder that wrote it.
 */

import { KEYS, PRODUCT } from '../../core/constants.js';
import { getModuleSettings } from '../../core/settings.js';
import { ensureOffscreen, closeOffscreen, callOffscreen, offscreenExists } from '../../core/offscreen-host.js';
import { writeText, writeUrl, dropPath, setDownloadUi } from '../../core/output.js';
import { raiseAlert, setHealth, resetAlertThrottle, notifyRoutine } from '../../core/alerts.js';
import { MODULE_ID, CAPTURE_DEFAULTS, SETTINGS_SCHEMA, THRESHOLDS, ACTIONS, SESSION_STATUS, FILES } from './constants.js';
import { detectPlatform, shouldAutoArm, isCallTab } from './platforms.js';
import { newCaptureState, applyHeartbeat, evaluateHealth, badgeTextFor } from './health.js';
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
 * a recognised call tab that is not being captured is alarmed within seconds.
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
 * Arm capture on a tab.
 * @param {number} tabId
 * @param {string} trigger 'auto' | 'popup' | 'shortcut' | 'recovery'
 * @returns {Promise<{ok: boolean, error?: string, needsInvocation?: boolean, sessionId?: string}>}
 */
export async function armTab(tabId, trigger = 'auto') {
  const settings = await getModuleSettings(MODULE_ID);
  if (!settings.enabled) return { ok: false, error: 'call capture is disabled in settings' };
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
  if (!minted.ok) {
    if (minted.needsInvocation) {
      await raiseAlert({
        code: 'needs-invocation',
        level: 'red',
        title: 'RichOS: click to start capturing this call',
        message:
          'Chrome will not release this tab\'s audio until you invoke the extension for it. Click the RichOS icon (or press the shortcut) on the call tab now — nothing is being recorded.',
      });
      await setHealth({ level: 'red', text: 'ARM', title: 'RichOS: call tab NOT being captured — click to arm' });
    }
    return { ok: false, error: minted.error, needsInvocation: minted.needsInvocation };
  }

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
  record.notes.push(`armed via ${trigger}`);

  resetAlertThrottle();
  active = {
    record,
    state: newCaptureState({ sessionId: record.sessionId, startedAt, micEnabled: settings.captureMic !== false }),
    tabId,
    lastEval: null,
    attempts: {},
    lastDiskWrite: 0,
    finalizing: false,
  };

  // 1) The record of the call's existence goes to disk BEFORE any audio does.
  await writeSessionFile(record);
  await persistActive();

  // 2) Start the recorder.
  await ensureOffscreen();
  const started = await callOffscreen({
    type: 'cc:start',
    sessionId: record.sessionId,
    streamId: minted.streamId,
    settings,
  });

  if (!started?.ok) {
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
  if (started.micOnlyFailover || !started.hasMic) {
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

  unarmedSince = null;
  await maybeShowDisclosure(tabId, settings);
  startWatchdog();
  await setHealth({ level: 'green', text: badgeTextFor('green'), title: `RichOS: recording ${platform.label}` });
  await notifyRoutine({
    title: 'RichOS: capture started',
    message: `${platform.label} — saving to ${await dropRoot()}/${record.dir}`,
  });
  return { ok: true, sessionId: record.sessionId };
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

  const evaluation = evaluateHealth(active.state, now);
  active.lastEval = { ...evaluation, at: now };
  accrueHealth(active.record, evaluation);

  await setHealth({
    level: evaluation.level,
    text: badgeTextFor(evaluation.level),
    title: healthTitle(evaluation),
  });

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

  const maxMs = (settings.maxSessionMinutes || CAPTURE_DEFAULTS.maxSessionMinutes) * 60000;
  if (now - active.record.startedAt > maxMs) {
    active.record.notes.push('stopped: maximum session length reached');
    await finalize('max-duration');
    return;
  }
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

/** Alarm when a recognised call tab is open and NOT being captured. */
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
// Finalisation + export
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
  const settings = await getModuleSettings(MODULE_ID);

  const stopped = await callOffscreen({ type: 'cc:stop', reason });
  record.endedAt = Date.now();
  record.status = reason === 'recovered' ? SESSION_STATUS.recovered : SESSION_STATUS.closed;
  record.notes.push(`closed: ${reason}`);
  if (stopped?.lastError) record.notes.push(`recorder last error: ${stopped.lastError}`);
  if (stopped?.micOnlyFailover) record.notes.push('finished in microphone-only failover');

  const exported = await exportSession(record);
  record.audio = exported.audio;

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

/** @returns {Promise<string>} */
async function dropRoot() {
  const core = await getModuleSettings('core');
  return core.dropFolder || 'richos-capture';
}

/**
 * Write `session.json`. Called at START (status `open`) and again at finalisation.
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
  const ids = (result?.sessionIds || []).filter((id) => !active || id !== active.record.sessionId);
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
      captions: { available: false, adapter: null, count: 0 },
      notes: ['recovered from orphaned chunks with no live session record'],
    };
    record.audio = await exportSession(record);
    await writeSessionFile(record, { overwrite: true });
    await callOffscreen({ type: 'cc:purge', sessionId });
    await raiseAlert({
      code: 'orphan-recovered',
      level: 'amber',
      title: 'RichOS: recovered orphaned audio',
      message: `${sessionId}: ${(record.audio.bytesTotal / 1048576).toFixed(1)} MB written to the drop zone.`,
      sessionId,
      force: true,
    });
  }
  if (!active && !ids.length) await closeOffscreen();
}

// ---------------------------------------------------------------------------------------
// Messages + status
// ---------------------------------------------------------------------------------------

/**
 * @param {any} msg
 */
async function onMessage(msg) {
  switch (msg.type) {
    case 'cc:heartbeat': {
      if (!active || msg.sessionId !== active.record.sessionId) return { ok: true, ignored: true };
      applyHeartbeat(active.state, msg);
      await tick();
      return { ok: true };
    }
    case 'cc:chunk': {
      if (!active || msg.sessionId !== active.record.sessionId) return { ok: true, ignored: true };
      active.state.lastChunkAt = msg.t;
      active.state.chunkCount += 1;
      if (msg.bytesTotal > active.state.bytesTotal) active.state.bytesGrewAt = msg.t;
      active.state.bytesTotal = msg.bytesTotal;
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
    dropFolder: root,
    saveLocation: `Downloads/${root}/${active.record.dir}/`,
    lastSession: index.length ? index[index.length - 1] : null,
    startedAt: active.record.startedAt,
    bytesTotal: active.state.bytesTotal,
    chunkCount: active.state.chunkCount,
    part: active.state.part,
    micOnlyFailover: active.state.micOnlyFailover,
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

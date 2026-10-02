/**
 * RichOS extension — CEO-only alerting + the health indicator (shared core).
 *
 * Three distinct surfaces, deliberately separated:
 *
 *   1. AMBIENT STATUS — the toolbar badge (`setHealth`) and the popup. Always on, CEO-facing,
 *      lives in the browser's own toolbar. Nothing is ever injected into the meeting page,
 *      so nothing here can appear in a screenshare or be seen by the other party.
 *   2. ROUTINE NOTIFICATIONS — `notifyRoutine`, OFF by default (`core.notifyOnStartStop`).
 *   3. FAILURE ALERTS — `raiseAlert`, ON by default (`core.notifyOnFailure`), CEO-only,
 *      independent of (2) because it is the reliability guarantee, not routine noise.
 *      Loudness is tunable: red badge always, optional desktop notification, optional chime.
 *
 * The badge is the load-bearing surface: it survives every page-level failure because it
 * lives in the browser chrome, not in the meeting tab.
 */

import { BADGE, KEYS } from './constants.js';
import { callOffscreen } from './offscreen-host.js';
import { getModuleSettings } from './settings.js';

const ALERT_LOG_MAX = 200;
const INCIDENTS_KEY = 'richos.callCapture.alertIncidents';
const NOTIFICATION_ID = 'richos-capture-failure';
let alertChain = Promise.resolve();
function serializeAlert(operation) {
  const next = alertChain.then(operation);
  alertChain = next.catch(() => {});
  return next;
}

/**
 * Paint the health indicator.
 * @param {{level: 'green'|'amber'|'red'|'idle', text?: string, title?: string}} state
 */
export async function setHealth({ level, text, title }) {
  const color = BADGE[level] || BADGE.idle;
  try {
    await chrome.action.setBadgeBackgroundColor({ color });
    await chrome.action.setBadgeText({ text: text == null ? '' : String(text).slice(0, 4) });
    if (chrome.action.setTitle) {
      await chrome.action.setTitle({ title: title || 'RichOS' });
    }
  } catch {
    /* action APIs can be unavailable during teardown */
  }
}

/**
 * Raise a CEO-only alert once per unresolved condition, persisted across worker eviction.
 * @param {{code: string, level?: 'amber'|'red', title: string, message: string,
 *          sessionId?: string, force?: boolean}} alert
 * @returns {Promise<boolean>} whether a new incident actually fired
 */
export function raiseAlert(alert) {
  return serializeAlert(async () => {
    const incidents = (await chrome.storage.local.get(INCIDENTS_KEY))[INCIDENTS_KEY] || {};
    const identity = `${alert.sessionId || ''}:${alert.level || 'red'}`;
    if (incidents[alert.code]?.identity === identity) return false;
    const now = Date.now();
    const record = { t: now, code: alert.code, level: alert.level || 'red', title: alert.title,
      message: alert.message, sessionId: alert.sessionId || null };
    incidents[alert.code] = { identity, record };
    await chrome.storage.local.set({ [INCIDENTS_KEY]: incidents });
    await appendAlertLog(record);
    await showIncident(record);
    const core = await getModuleSettings('core');
    if (core.alertSound) await callOffscreen({ type: 'core:chime' });
    return true;
  });
}

async function showIncident(record) {
  const core = await getModuleSettings('core');
  if (!core.notifyOnFailure) return;
  try {
    // Stable ID replaces the previous surface. Red badge and durable log remain independent.
    await chrome.notifications.create(NOTIFICATION_ID, {
      type: 'basic', iconUrl: chrome.runtime.getURL('icons/icon128.png'),
      title: record.title, message: record.message, priority: 2,
      requireInteraction: record.level === 'red',
    });
  } catch { /* OS policy may disable notifications; badge and incident log remain. */ }
}

/** A recovered condition can alert again if it later fails, including after worker eviction. */
export function resolveAlerts(codes) {
  return serializeAlert(async () => {
    const incidents = (await chrome.storage.local.get(INCIDENTS_KEY))[INCIDENTS_KEY] || {};
    const before = Object.keys(incidents).length;
    for (const code of codes) delete incidents[code];
    if (before === Object.keys(incidents).length) return;
    await chrome.storage.local.set({ [INCIDENTS_KEY]: incidents });
    const remaining = Object.values(incidents).sort((a, b) => b.record.t - a.record.t);
    try { await chrome.notifications.clear(NOTIFICATION_ID); } catch { /* unavailable */ }
    if (remaining.length) await showIncident(remaining[0].record);
  });
}

/**
 * A ROUTINE notification (capture started / stopped). Off by default: the badge and popup
 * are the ambient status surface. Never participant-facing, and never used for failures —
 * failures go through `raiseAlert`, which has its own always-on setting.
 * @param {{title: string, message: string}} note
 * @returns {Promise<boolean>} whether it fired
 */
export async function notifyRoutine(note) {
  const core = await getModuleSettings('core');
  if (!core.notifyOnStartStop) return false;
  try {
    await chrome.notifications.create(`richos-routine-${Date.now()}`, {
      type: 'basic',
      iconUrl: chrome.runtime.getURL('icons/icon128.png'),
      title: note.title,
      message: note.message,
      priority: 0,
    });
    return true;
  } catch {
    return false;
  }
}

/**
 * Append to the durable alert log. The log is what makes "it failed and I was told"
 * auditable after the fact.
 * @param {object} record
 */
export async function appendAlertLog(record) {
  const stored = (await chrome.storage.local.get(KEYS.alertLog))[KEYS.alertLog] || [];
  stored.push(record);
  const trimmed = stored.slice(-ALERT_LOG_MAX);
  await chrome.storage.local.set({ [KEYS.alertLog]: trimmed });
}

/** @returns {Promise<object[]>} */
export async function getAlertLog() {
  return (await chrome.storage.local.get(KEYS.alertLog))[KEYS.alertLog] || [];
}

/** Start a new session without retaining old in-call incidents or legacy notification stacks. */
export function resetAlertThrottle() {
  return serializeAlert(async () => {
    await chrome.storage.local.set({ [INCIDENTS_KEY]: {} });
    try {
      const all = await chrome.notifications.getAll();
      for (const id of Object.keys(all)) if (id.startsWith('richos-')) await chrome.notifications.clear(id);
    } catch { /* unavailable */ }
  });
}

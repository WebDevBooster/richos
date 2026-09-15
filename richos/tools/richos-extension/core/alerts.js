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

const ALERT_REPEAT_MS = 30000;
const ALERT_LOG_MAX = 200;

/** @type {Map<string, number>} alert code -> last fired timestamp */
const lastFired = new Map();

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
 * Raise a CEO-only alert. Rate-limited per code so a stuck channel does not spam.
 * @param {{code: string, level?: 'amber'|'red', title: string, message: string,
 *          sessionId?: string, force?: boolean}} alert
 * @returns {Promise<boolean>} whether it actually fired (false = rate-limited)
 */
export async function raiseAlert(alert) {
  const now = Date.now();
  const last = lastFired.get(alert.code) || 0;
  if (!alert.force && now - last < ALERT_REPEAT_MS) return false;
  lastFired.set(alert.code, now);

  const core = await getModuleSettings('core');
  const record = {
    t: now,
    code: alert.code,
    level: alert.level || 'red',
    title: alert.title,
    message: alert.message,
    sessionId: alert.sessionId || null,
  };
  await appendAlertLog(record);

  if (core.notifyOnFailure) {
    try {
      await chrome.notifications.create(`richos-${alert.code}-${now}`, {
        type: 'basic',
        iconUrl: chrome.runtime.getURL('icons/icon128.png'),
        title: alert.title,
        message: alert.message,
        priority: 2,
        requireInteraction: (alert.level || 'red') === 'red',
      });
    } catch {
      /* notifications can be disabled at the OS level — the badge still tells the truth */
    }
  }
  if (core.alertSound) {
    await callOffscreen({ type: 'core:chime' });
  }
  return true;
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

/** Forget rate-limit state (used when a new session starts). */
export function resetAlertThrottle() {
  lastFired.clear();
}

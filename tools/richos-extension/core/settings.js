/**
 * RichOS extension — settings storage (shared core).
 *
 * Settings are namespaced per module: `{ core: {...}, callCapture: {...} }`.
 * A future module (chatgpt-export) adds its own namespace and reuses this plumbing
 * plus the generic options renderer — no duplicated storage code.
 */

import { KEYS, CORE_DEFAULTS } from './constants.js';

/** @type {Record<string, object>} moduleId -> defaults */
const defaultsByModule = { core: CORE_DEFAULTS };

/**
 * Register a module's defaults so `getSettings()` fills them in.
 * @param {string} moduleId
 * @param {object} defaults
 */
export function registerDefaults(moduleId, defaults) {
  defaultsByModule[moduleId] = defaults;
}

/** @returns {Record<string, object>} */
export function allDefaults() {
  return JSON.parse(JSON.stringify(defaultsByModule));
}

/**
 * Read the full settings tree, with defaults applied for anything unset.
 * @returns {Promise<Record<string, any>>}
 */
export async function getSettings() {
  const stored = (await chrome.storage.local.get(KEYS.settings))[KEYS.settings] || {};
  const merged = {};
  for (const [moduleId, defaults] of Object.entries(defaultsByModule)) {
    merged[moduleId] = { ...defaults, ...(stored[moduleId] || {}) };
  }
  // Preserve namespaces from modules that are not registered in this context.
  for (const [moduleId, value] of Object.entries(stored)) {
    if (!merged[moduleId]) merged[moduleId] = value;
  }
  return merged;
}

/**
 * Read one module's settings.
 * @param {string} moduleId
 * @returns {Promise<Record<string, any>>}
 */
export async function getModuleSettings(moduleId) {
  const all = await getSettings();
  return all[moduleId] || {};
}

/**
 * Patch one module's settings.
 * @param {string} moduleId
 * @param {Record<string, any>} patch
 * @returns {Promise<Record<string, any>>} the module's settings after the patch
 */
export async function updateModuleSettings(moduleId, patch) {
  const stored = (await chrome.storage.local.get(KEYS.settings))[KEYS.settings] || {};
  const next = { ...stored, [moduleId]: { ...(stored[moduleId] || {}), ...patch } };
  await chrome.storage.local.set({ [KEYS.settings]: next });
  return { ...(defaultsByModule[moduleId] || {}), ...next[moduleId] };
}

/**
 * Subscribe to settings changes.
 * @param {(settings: Record<string, any>) => void} cb
 */
export function onSettingsChanged(cb) {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !changes[KEYS.settings]) return;
    getSettings().then(cb);
  });
}

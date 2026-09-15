/**
 * RichOS extension — module registry (shared core).
 *
 * The unified extension is a shell plus modules. A module is a plain object:
 *
 *   {
 *     id: 'callCapture',                 // settings namespace + message routing key
 *     label: 'Call capture',
 *     defaults: {...},                   // registered with core settings storage
 *     settingsSchema: {title, fields},   // rendered generically by the options page
 *     async init(),                      // boot + crash recovery
 *     async onMessage(msg, sender),      // module-scoped messages
 *     async getStatus(),                 // popup card data
 *     async onSettingsChanged(settings)  // optional
 *   }
 *
 * `modules/chatgpt-export/` will register itself here and reuse settings, output and
 * alerting rather than duplicating them.
 */

import { registerDefaults, getSettings, updateModuleSettings } from './settings.js';

/** @type {Map<string, any>} */
const modules = new Map();

/** @param {any} mod */
export function registerModule(mod) {
  if (!mod || !mod.id) throw new Error('module needs an id');
  modules.set(mod.id, mod);
  registerDefaults(mod.id, mod.defaults || {});
}

/** @returns {any[]} */
export function listModules() {
  return [...modules.values()];
}

/** Boot every registered module. One module failing must not stop the others. */
export async function initModules() {
  for (const mod of modules.values()) {
    try {
      await mod.init?.();
    } catch (err) {
      console.error(`[richos] module ${mod.id} failed to init`, err);
    }
  }
}

/** @returns {Promise<Record<string, any>>} */
export async function statusSnapshot() {
  const status = {};
  for (const mod of modules.values()) {
    try {
      status[mod.id] = (await mod.getStatus?.()) || {};
    } catch (err) {
      status[mod.id] = { error: String((err && err.message) || err) };
    }
  }
  return status;
}

/**
 * Route one runtime message. Core message types are handled here; anything with a
 * `module` field is handed to that module.
 * @param {any} msg
 * @param {chrome.runtime.MessageSender} sender
 * @returns {Promise<any>}
 */
export async function routeMessage(msg, sender) {
  if (!msg || typeof msg !== 'object') return undefined;

  switch (msg.type) {
    case 'core:get-status':
      return { ok: true, modules: await statusSnapshot() };
    case 'core:get-settings':
      return { ok: true, settings: await getSettings(), schemas: schemaList() };
    case 'core:update-settings':
      await updateModuleSettings(msg.moduleId, msg.patch || {});
      for (const mod of modules.values()) {
        try {
          await mod.onSettingsChanged?.(await getSettings());
        } catch (err) {
          console.error(`[richos] ${mod.id} settings handler failed`, err);
        }
      }
      return { ok: true, settings: await getSettings() };
    default:
      break;
  }

  if (msg.module && modules.has(msg.module)) {
    return modules.get(msg.module).onMessage?.(msg, sender);
  }
  return undefined;
}

/** @returns {{moduleId: string, title: string, fields: any[]}[]} */
export function schemaList() {
  const out = [];
  for (const mod of modules.values()) {
    if (mod.settingsSchema) {
      out.push({ moduleId: mod.id, title: mod.settingsSchema.title, fields: mod.settingsSchema.fields });
    }
  }
  return out;
}

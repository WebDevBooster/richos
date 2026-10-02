/** GPT Exporter module. Its only shared dependency is the core resource host/settings. */
import { handleAction, getExportState, cancelExport, requestTab, pinExportTab } from './runtime.js';
import { getJob, newJob, updateJob, resumePacing } from './jobs.js';
import { getModuleSettings } from '../../core/settings.js';
import { acquireOffscreen } from '../../core/offscreen-host.js';
import { validateMigration } from './migration.js';
import { getSyncData } from './sync/tracker.js';
import { updateModuleSettings } from '../../core/settings.js';
import { isChatGPTPage } from './sites.js';

const ORIGINS = ['https://chatgpt.com/*'];
let running = null, cancellationRequested = false;
const actions = new Set(['exportAll', 'exportNewUpdated', 'exportCurrentConversation']);
async function permitted() { return chrome.permissions.contains({ origins: ORIGINS }); }
async function selectedTab(action) {
  const tabs = await chrome.tabs.query({ url: ORIGINS });
  const tab = tabs.find(t => t.active && t.lastAccessed === Math.max(...tabs.filter(x => x.active).map(x => x.lastAccessed || 0))) || tabs.find(t => t.active) || tabs[0];
  if (!tab || !isChatGPTPage(tab.url)) throw new Error('Open chatgpt.com to export conversations');
  if (action === 'exportCurrentConversation') {
    const target = await handleAction({ action: 'getCurrentConversationTarget' });
    if (target.error) throw new Error(target.error);
    // Runtime resolves the focused conversation with its established ambiguity handling.
    const focused = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (isChatGPTPage(focused[0]?.url)) return focused[0];
    if (tabs.filter(t => t.active).length !== 1) throw new Error('Focus the ChatGPT conversation to export');
    return tabs.find(t => t.active);
  }
  return tab;
}
async function start(message, resume = false) {
  if (running) return { error: 'An export is already running' };
  // Reserve before the first await to prevent overlapping starts or migrations.
  let resolveReservation;
  running = new Promise(resolve => { resolveReservation = resolve; });
  let release, resourceLost = false, ownsJob = false;
  cancellationRequested = false;
  try {
    if (!(await permitted())) throw new Error('Enable ChatGPT access before exporting');
    const previous = await getJob();
    if (resume && previous?.status !== 'interrupted') throw new Error('No interrupted export to resume');
    const options = resume ? previous?.options : {
      action: message.action, formats: message.formats, downloadFolder: message.downloadFolder || '', limit: message.limit || 0
    };
    if (!options || !actions.has(options.action)) throw new Error('No unfinished export to resume');
    if (!options.formats?.markdown && !options.formats?.json) throw new Error('Select at least one export format');
    const tab = resume ? await chrome.tabs.get(previous.tabId) : await selectedTab(options.action);
    if (!isChatGPTPage(tab.url)) throw new Error('The export tab left chatgpt.com');
    const ping = await requestTab(tab, { action: 'ping' });
    if (!ping?.hasToken || !ping.contextKey) throw new Error('Sign in to ChatGPT before exporting');
    if (resume && ping.contextKey !== previous.contextKey) throw new Error('ChatGPT account or workspace changed; start a new export');
    if (!resume) await newJob(options, ping.contextKey, tab.id);
    else await updateJob({ status: 'running', error: null });
    ownsJob = true;
    pinExportTab(tab);
    release = await acquireOffscreen('gptExporter', () => { resourceLost = true; cancelExport(); });
    await resumePacing(() => { if (cancellationRequested || resourceLost) throw new Error('Export cancelled or reset'); });
    if (cancellationRequested) throw new Error('Export cancelled by user');
    if (resourceLost) throw new Error('Recorder recovery reset the export document. Resume the export.');
    const result = await handleAction(options);
    if (result.error) {
      await updateJob({ status: 'interrupted', error: result.error });
    } else {
      await updateJob({ status: 'complete', phase: 'complete', result });
    }
    return result;
  } catch (error) {
    if (ownsJob) await updateJob({ status: 'interrupted', error: error.message });
    return { error: error.message };
  } finally {
    try { await release?.(); } finally { resolveReservation(); running = null; pinExportTab(null); }
  }
}
export const gptExporterModule = {
  id: 'gptExporter', label: 'ChatGPT export',
  defaults: { downloadFolder: '', exportLimit: 0, includeAboveBranchedFrom: false },
  settingsSchema: { title: 'ChatGPT export', fields: [
    { key: 'downloadFolder', type: 'text', label: 'Download folder', help: 'Subfolder in Downloads. Leave empty for the existing default.' },
    { key: 'exportLimit', type: 'number', min: 0, label: 'Export limit', help: '0 exports all eligible conversations.' },
    { key: 'includeAboveBranchedFrom', type: 'boolean', label: 'Include content above the Branched from divider' }
  ] },
  async init() {
    const job = await getJob();
    if (!running && job?.status === 'running') await updateJob({ status: 'interrupted', error: 'Export interrupted. Resume to reuse saved progress.' });
  },
  async getStatus() {
    const job = await getJob();
    return { enabled: await permitted(), isRunning: Boolean(running), state: getExportState(),
      job: job ? { status: job.status, phase: job.phase, current: job.current, total: job.total, error: job.error, result: job.result } : null };
  },
  async onMessage(message, sender) {
    // Only extension UI can start jobs, clear history or migrate data.
    const ui = sender?.id === chrome.runtime.id && !sender.tab?.url?.startsWith('https:') &&
      String(sender.url || '').startsWith(chrome.runtime.getURL(''));
    if (!ui) return { error: 'Exporter requests must come from RichOS Helper' };
    if (actions.has(message.action)) return start(message);
    if (message.action === 'resumeExport') return start(message, true);
    if (message.action === 'cancelExport') {
      if (!running) return { error: 'No export is running' };
      cancellationRequested = true; cancelExport(); return { success: true };
    }
    if (message.action === 'exportMigration') return { data: { format: 'richos-gpt-exporter-migration', version: 1, settings: await getModuleSettings('gptExporter'), history: await getSyncData() } };
    if (message.action === 'importMigration') {
      if (running) return { error: 'Finish or cancel the export first' };
      const data = validateMigration(message.data);
      await updateModuleSettings('gptExporter', data.settings);
      await chrome.storage.local.set({ 'richos.gptExporter.history': data.history });
      return { success: true };
    }
    if (message.action === 'getSettings') return getModuleSettings('gptExporter');
    if (message.action === 'getExportState') return gptExporterModule.getStatus();
    if (message.action === 'checkConnection') {
      if (!(await permitted())) return { connected: false };
      const tab = await selectedTab();
      const ping = await requestTab(tab, { action: 'ping' });
      return { connected: Boolean(ping?.hasToken) };
    }
    if (['getStats', 'getCurrentConversationTarget', 'clearHistory'].includes(message.action)) {
      if (running && message.action === 'clearHistory') return { error: 'Finish or cancel the export first' };
      return handleAction(message);
    }
    return { error: 'Unknown exporter action' };
  }
};

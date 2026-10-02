/** Explicit transfer only. Chrome cannot read another installed extension's storage. */
export function validateMigration(input) {
  if (!input || typeof input !== 'object') throw new Error('Invalid migration file');
  const settings = input.settings || input.gpt_exporter_settings || {};
  const history = input.history || input.gpt_exporter_sync_data;
  if (!history || typeof history.exportedConversations !== 'object' || Array.isArray(history.exportedConversations)) throw new Error('Missing export history');
  if (settings.downloadFolder != null && typeof settings.downloadFolder !== 'string') throw new Error('Invalid download folder');
  if (settings.exportLimit != null && (!Number.isInteger(settings.exportLimit) || settings.exportLimit < 0)) throw new Error('Invalid export limit');
  const exportedConversations = Object.create(null);
  for (const [id, entry] of Object.entries(history.exportedConversations)) {
    if (!/^[a-zA-Z0-9-]{1,128}$/.test(id) || !entry || typeof entry.exportedAt !== 'string' ||
        !Number.isFinite(Date.parse(entry.exportedAt)) || !['string', 'number'].includes(typeof entry.updateTime)) throw new Error('Invalid conversation history entry');
    exportedConversations[id] = { exportedAt: entry.exportedAt, updateTime: entry.updateTime };
  }
  if (history.lastSyncTime != null && !Number.isFinite(Date.parse(history.lastSyncTime))) throw new Error('Invalid sync timestamp');
  return { settings: { downloadFolder: settings.downloadFolder || '', exportLimit: settings.exportLimit || 0,
    includeAboveBranchedFrom: Boolean(settings.includeAboveBranchedFrom) },
    history: { exportedConversations, lastSyncTime: history.lastSyncTime || null } };
}
export function validateDownloadPath(path) {
  if (typeof path !== 'string' || !path || path.startsWith('/') || path.includes('\\') ||
      /^[a-z]:/i.test(path) || path.split('/').some(part => !part || part === '.' || part === '..') || /[\x00-\x1f]/.test(path)) throw new Error('Invalid export path');
  // Validation never transliterates Unicode, punctuation or project-folder names.
  return path;
}

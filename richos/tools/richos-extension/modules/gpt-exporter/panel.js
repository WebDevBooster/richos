/**
 * Popup Script
 * Handles UI interactions and communicates with background worker
 */

// DOM Elements
const connectionStatus = document.getElementById('connectionStatus');
const exportedCount = document.getElementById('exportedCount');
const lastSync = document.getElementById('lastSync');
const downloadFolder = document.getElementById('downloadFolder');
const exportLimit = document.getElementById('exportLimit');
const formatMarkdown = document.getElementById('formatMarkdown');
const includeAboveBranchedFrom = document.getElementById('includeAboveBranchedFrom');
const formatJson = document.getElementById('formatJson');
const btnExportNew = document.getElementById('btnExportNew');
const btnExportCurrent = document.getElementById('btnExportCurrent');
const btnExportAll = document.getElementById('btnExportAll');
const btnCancelProcess = document.getElementById('btnCancelProcess');
const btnClearHistory = document.getElementById('btnClearHistory');
const btnClearLog = document.getElementById('btnClearLog');
const btnPopout = document.getElementById('btnPopout');
const progressSection = document.getElementById('progressSection');
const progressFill = document.getElementById('progressFill');
const progressText = document.getElementById('progressText');
const logOutput = document.getElementById('logOutput');

/**
 * Check if running in a popup or a window
 */
function isPopup() {
    return window.innerWidth < 400;
}

/**
 * Open this popup as a detached window
 */
function handlePopout() {
    chrome.windows.create({
        url: chrome.runtime.getURL('modules/gpt-exporter/panel.html'),
        type: 'popup',
        width: 420,
        height: 650,
        focused: true
    });
    // Close the popup
    if (window === window.top) window.close();
}

let locallyRunning = false;

/**
 * Add entry to visible log
 */
function log(message, type = 'info') {
    const entry = document.createElement('div');
    entry.className = `log-entry ${type}`;
    const time = new Date().toLocaleTimeString();
    entry.textContent = `[${time}] ${message}`;
    logOutput.appendChild(entry);
    while (logOutput.children.length > 500) logOutput.firstChild.remove();
    logOutput.scrollTop = logOutput.scrollHeight;
    console.log(`[GPT Exporter] ${message}`);
}

/**
 * Clear log
 */
function clearLog() {
    logOutput.innerHTML = '';
}

/**
 * Send message to background script with logging
 */
async function sendMessage(message) {
    const quiet = ['getExportState', 'getCurrentConversationTarget'].includes(message.action);
    if (!quiet) log(`Sending: ${message.action}`, 'info');
    try {
        const response = await new Promise((resolve, reject) => {
            chrome.runtime.sendMessage({ target: 'sw', module: 'gptExporter', ...message }, (response) => {
                if (chrome.runtime.lastError) {
                    reject(new Error(chrome.runtime.lastError.message));
                } else {
                    resolve(response);
                }
            });
        });

        if (response === undefined) {
            log(`Response undefined - service worker may not be running`, 'error');
            return { error: 'No response from background script' };
        }

        if (response.error) {
            log(`Error: ${response.error}`, 'error');
        } else {
            if (!quiet) log(`Response received for ${message.action}`, 'success');
        }

        return response;
    } catch (error) {
        log(`Send failed: ${error.message}`, 'error');
        return { error: error.message };
    }
}

/**
 * Load settings from storage
 */
async function loadSettings() {
    const result = await chrome.runtime.sendMessage({ target: 'sw', type: 'core:get-settings' });
    const settings = result.settings?.gptExporter || {};

    downloadFolder.value = settings.downloadFolder || '';
    exportLimit.value = settings.exportLimit || '';
    // Default unchecked: exports omit content above the "Branched from"
    // divider unless the user opts back in.
    includeAboveBranchedFrom.checked = settings.includeAboveBranchedFrom || false;
    log('Settings loaded');
}

/**
 * Save settings to storage
 */
async function saveSettings() {
    const settings = {
        downloadFolder: downloadFolder.value.trim(),
        exportLimit: parseInt(exportLimit.value) || 0,
        includeAboveBranchedFrom: includeAboveBranchedFrom.checked
    };
    await chrome.runtime.sendMessage({ target: 'sw', type: 'core:update-settings', moduleId: 'gptExporter', patch: settings });
    log('Settings saved');
    return settings;
}

/**
 * Format relative time
 */
function formatRelativeTime(dateString) {
    if (!dateString) return 'Never';

    const date = new Date(dateString);
    const now = new Date();
    const diffMs = now - date;
    const diffMins = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMs / 3600000);
    const diffDays = Math.floor(diffMs / 86400000);

    if (diffMins < 1) return 'Just now';
    if (diffMins < 60) return `${diffMins}m ago`;
    if (diffHours < 24) return `${diffHours}h ago`;
    if (diffDays < 7) return `${diffDays}d ago`;

    return date.toLocaleDateString();
}

/**
 * Update connection status display
 */
async function updateConnectionStatus() {
    log('Checking connection...');
    const result = await sendMessage({ action: 'checkConnection' });

    connectionStatus.classList.remove('connected', 'disconnected');

    if (result && result.connected) {
        connectionStatus.classList.add('connected');
        connectionStatus.querySelector('.status-text').textContent = 'Connected';
        btnExportNew.disabled = false;
        btnExportAll.disabled = false;
        btnExportCurrent.disabled = false;
        log('Connected to ChatGPT', 'success');
    } else {
        connectionStatus.classList.add('disconnected');
        connectionStatus.querySelector('.status-text').textContent = 'Not logged in';
        btnExportNew.disabled = true;
        btnExportAll.disabled = true;
        btnExportCurrent.disabled = true;
        log('Not connected - please log in to chatgpt.com', 'error');
    }
}

/**
 * Enable current-chat export only when the active tab is a concrete conversation
 */
async function updateCurrentConversationAvailability() {
    if (!connectionStatus.classList.contains('connected')) {
        btnExportCurrent.disabled = true;
        btnExportCurrent.title = 'Log in to ChatGPT first';
        return;
    }

    const result = await sendMessage({ action: 'getCurrentConversationTarget' });
    const isAvailable = !!(result && result.available && result.conversationId);

    btnExportCurrent.disabled = !isAvailable;
    btnExportCurrent.title = isAvailable
        ? 'Export only the active ChatGPT conversation tab'
        : (result?.error || 'Open the ChatGPT conversation you want to export');
}

/**
 * Update stats display
 */
async function updateStats() {
    const stats = await sendMessage({ action: 'getStats' });

    if (stats && !stats.error) {
        exportedCount.textContent = stats.totalExported || 0;
        lastSync.textContent = formatRelativeTime(stats.lastSyncTime);
    }
}

/**
 * Get selected formats and settings
 */
function getExportOptions() {
    return {
        formats: {
            markdown: formatMarkdown.checked,
            json: formatJson.checked,
            includeAboveBranchedFrom: includeAboveBranchedFrom.checked
        },
        downloadFolder: downloadFolder.value.trim(),
        limit: parseInt(exportLimit.value) || 0
    };
}

/**
 * Show progress UI
 */
function showProgress(phase, current, total) {
    progressSection.classList.remove('hidden');

    let phaseText = '';
    let percent = 0;

    switch (phase) {
        case 'fetching_list':
            phaseText = `Fetching conversation list... ${current}/${total || '?'}`;
            percent = total ? (current / total) * 25 : 10;
            break;
        case 'fetching_conversations':
            phaseText = `Downloading conversations... ${current}/${total}`;
            percent = 25 + (current / total) * 45;
            break;
        case 'exporting':
            phaseText = `Preparing files... ${current}/${total}`;
            percent = 70 + (current / total) * 15;
            break;
        case 'zipping':
            phaseText = `Creating ZIP archive... ${total} files`;
            percent = 90;
            break;
        case 'complete':
            phaseText = `Export complete! ${total} files`;
            percent = 100;
            break;
        case 'saving':
            phaseText = 'Saving export... waiting for Chrome to finish';
            percent = 95;
            break;
        default:
            phaseText = 'Processing...';
            percent = 50;
    }

    progressFill.style.width = `${Math.min(percent, 100)}%`;
    progressText.textContent = phaseText;
}

/**
 * Hide progress UI
 */
function hideProgress() {
    progressSection.classList.add('hidden');
    progressFill.style.width = '0%';
}

/**
 * Show completion message
 */
function showComplete(message) {
    progressSection.classList.remove('hidden');
    progressFill.style.width = '100%';
    progressText.textContent = message;
    log(message, 'success');

    setTimeout(() => {
        hideProgress();
        updateStats();
    }, 3000);
}

/**
 * Handle export button click
 */
async function handleExport(exportType) {
    const options = getExportOptions();
    log(`Starting export: ${exportType}, limit: ${options.limit}, folder: ${options.downloadFolder || '(default)'}`);

    if (!options.formats.markdown && !options.formats.json) {
        alert('Please select at least one export format.');
        return;
    }

    // Save settings before export
    await saveSettings();

    locallyRunning = true;
    btnExportNew.disabled = true;
    btnExportCurrent.disabled = true;
    btnExportAll.disabled = true;

    try {
        const actionMap = {
            all: 'exportAll',
            new: 'exportNewUpdated',
            current: 'exportCurrentConversation'
        };
        const action = actionMap[exportType];
        log(`Calling action: ${action}`);

        const result = await sendMessage({
            action,
            formats: options.formats,
            downloadFolder: options.downloadFolder,
            limit: options.limit
        });

        log(`Result: ${JSON.stringify(result)}`, result?.error ? 'error' : 'info');

        if (result?.error) {
            throw new Error(result.error);
        }

        if (result?.totalExported === 0) {
            showComplete(result.message || 'Nothing to export!');
        } else if (result?.totalExported > 0) {
            showComplete(`✓ Exported ${result.totalExported} conversation(s)`);
        } else {
            log('Unexpected result format', 'error');
        }
    } catch (error) {
        console.error('Export error:', error);
        log(`Export failed: ${error.message}`, 'error');
        hideProgress();
        alert(`Export failed: ${error.message}`);
    } finally {
        locallyRunning = false;
        btnExportNew.disabled = false;
        btnExportAll.disabled = false;
        await updateCurrentConversationAvailability();
    }
}

/**
 * Handle cancel current process
 */
async function handleCancelProcess() {
    if (!confirm('Cancel the current export process? Progress will be lost.')) {
        return;
    }

    const result = await sendMessage({ action: 'cancelExport' });
    if (result && !result.error) {
        log('Export cancelled', 'info');
        hideProgress();
        btnExportNew.disabled = false;
        btnExportAll.disabled = false;
        await updateCurrentConversationAvailability();
    } else {
        log(result?.error || 'No export running to cancel', 'info');
    }
}

/**
 * Handle clear history
 */
async function handleClearHistory() {
    if (!confirm('Clear all export history? This will not delete any downloaded files.')) {
        return;
    }

    await sendMessage({ action: 'clearHistory' });
    log('Export history cleared');
    await updateStats();
}

// Listen for progress updates from background
chrome.runtime.onMessage.addListener((message) => {
    if (message.module === 'gptExporter' && message.type === 'gpt:progress') {
        showProgress(message.phase, message.current, message.total);
        log(`Progress: ${message.phase} ${message.current}/${message.total}`);
    }
});

// Auto-save settings on change
downloadFolder.addEventListener('change', saveSettings);
exportLimit.addEventListener('change', saveSettings);
includeAboveBranchedFrom.addEventListener('change', saveSettings);

// Event listeners
btnExportNew.addEventListener('click', () => handleExport('new'));
btnExportCurrent.addEventListener('click', () => handleExport('current'));
btnExportAll.addEventListener('click', () => handleExport('all'));
btnCancelProcess.addEventListener('click', handleCancelProcess);
btnClearHistory.addEventListener('click', handleClearHistory);
btnClearLog.addEventListener('click', clearLog);
if (btnPopout) {
    btnPopout.addEventListener('click', handlePopout);
}

/**
 * Check if an export is currently running and show progress
 */
async function checkExportState() {
    const state = await sendMessage({ action: 'getExportState' });

    const job = state?.job;
    document.getElementById('btnResume').hidden = !job || job.status !== 'interrupted';
    if (job?.error && !state.isRunning) { progressSection.classList.remove('hidden'); progressText.textContent = job.error; }
    const current = state?.state || {};
    if (!state?.isRunning && !locallyRunning && connectionStatus.classList.contains('connected')) {
        btnExportNew.disabled = false;
        btnExportAll.disabled = false;
        await updateCurrentConversationAvailability();
    }
    if (state?.isRunning && current.phase) {
        showProgress(current.phase, current.current, current.total);

        // Disable buttons while export is running
        btnExportNew.disabled = true;
        btnExportCurrent.disabled = true;
        btnExportAll.disabled = true;
    }
}

// Initialize
document.addEventListener('DOMContentLoaded', async () => {
    log('GPT Exporter popup initialized');
    await loadSettings();
    const enabled = await chrome.permissions.contains({ origins: ['https://chatgpt.com/*'] });
    document.getElementById('btnEnableAccess').hidden = enabled;
    document.getElementById('accessHint').hidden = enabled;
    if (enabled) await updateConnectionStatus();
    await updateCurrentConversationAvailability();
    await updateStats();
    await checkExportState(); // Check if export is already running
});

// Permission request remains directly attached to the user gesture.
document.getElementById('btnEnableAccess').addEventListener('click', async () => {
    if (await chrome.permissions.request({ origins: ['https://chatgpt.com/*'] })) {
        document.getElementById('btnEnableAccess').hidden = true;
        document.getElementById('accessHint').hidden = true;
        await updateConnectionStatus();
        await updateCurrentConversationAvailability();
    } else log('ChatGPT access was not granted. You can enable it when ready.', 'info');
});
document.getElementById('btnResume').addEventListener('click', async () => {
    const result = await sendMessage({ action: 'resumeExport' });
    if (result.error) log(result.error, 'error');
    await updateStats(); await checkExportState();
});
document.getElementById('btnExportHistory').addEventListener('click', async () => {
    const result = await sendMessage({ action: 'exportMigration' });
    if (result.error) { log(result.error, 'error'); return; }
    const url = URL.createObjectURL(new Blob([JSON.stringify(result.data, null, 2)], { type: 'application/json' }));
    const link = document.createElement('a');
    link.href = url; link.download = 'gpt-exporter-settings-history.json'; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
});
document.getElementById('historyFile').addEventListener('change', async event => {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
        const result = await sendMessage({ action: 'importMigration', data: JSON.parse(await file.text()) });
        if (result.error) throw new Error(result.error);
        await loadSettings(); await updateStats();
        log('Settings and history imported', 'success');
    } catch (error) { log(error.message, 'error'); }
    event.target.value = '';
});
// Reopened panels recover status even if the original response channel disappeared.
setInterval(() => { if (!locallyRunning) checkExportState(); }, 1000);

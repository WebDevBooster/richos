/**
 * Background Service Worker
 * Handles extension messaging, API calls via content script, and downloads
 */

import { conversationToMarkdown } from './export/markdown.js';
import { createBackupJson } from './export/json.js';
import { filterNeedingExport, markMultipleExported, getStats, clearHistory } from './sync/tracker.js';
import { parseChatGPTConversationUrl } from './lib/chatgpt-url.js';
import { createDownloadManager } from './lib/downloads.js';
import { ensureOffscreen, callOffscreen } from '../../core/offscreen-host.js';
import { getJob, cacheRequest, cachedRequest, waitPacing, saveOutput, savedOutput, updateJob } from './jobs.js';
import { validateDownloadPath } from './migration.js';
import { isChatGPTPage } from './sites.js';

const RATE_LIMIT_DELAY = 4000; // 4 seconds between requests (avoid rate limiting)
const ZIP_THRESHOLD = 3; // Bundle into ZIP if more than this many files
const MAX_RETRIES = 3; // Retry failed requests
const RETRY_BACKOFF = 10000; // 10 seconds base backoff on retry

// Export state tracking - allows popup to query current progress
let exportState = {
    isRunning: false,
    phase: null,
    current: 0,
    total: 0,
    startTime: null,
    cancelRequested: false
};

/**
 * Service worker keepalive.
 *
 * MV3 suspends idle service workers after ~30s. Long exports spend most of
 * their time sleeping between API requests, which counts as idle. Calling
 * any extension API resets the idle timer, so while an export is running
 * we ping a cheap API every 20s to keep the worker alive.
 */
let keepAliveIntervalId = null;

function startKeepAlive() {
    if (keepAliveIntervalId) {
        return;
    }
    keepAliveIntervalId = setInterval(() => {
        chrome.runtime.getPlatformInfo().catch(() => {});
    }, 20000);
}

function stopKeepAlive() {
    if (keepAliveIntervalId) {
        clearInterval(keepAliveIntervalId);
        keepAliveIntervalId = null;
    }
}

/**
 * Update export state and broadcast to any open popups
 */
function updateExportState(phase, current, total) {
    exportState.phase = phase;
    exportState.current = current;
    exportState.total = total;
    updateJob({ phase, current, total }).catch(() => { exportState.cancelRequested = true; });

    // Broadcast to popup
    chrome.runtime.sendMessage({ target: 'ui', module: 'gptExporter', type: 'gpt:progress', phase, current, total }).catch(() => {
        // Popup not open, ignore
    });
}

/**
 * Get current export state
 */
function getExportState() {
    return { ...exportState };
}

/**
 * Request cancellation of the current export
 */
function cancelExport() {
    if (!exportState.isRunning) {
        return { success: false, error: 'No export is currently running' };
    }
    exportState.cancelRequested = true;
    downloadManager.cancelPending();
    return { success: true };
}

/**
 * Check if cancellation was requested and throw if so
 */
function checkCancellation() {
    if (exportState.cancelRequested) {
        throw new Error('Export cancelled by user');
    }
}

/**
 * Sleep utility
 */
function sleep(ms) {
    return waitPacing(ms, checkCancellation);
}

/**
 * Get a random delay between min and max milliseconds
 */
function randomDelay(minMs, maxMs) {
    return Math.floor(Math.random() * (maxMs - minMs + 1)) + minMs;
}

/**
 * Find a ChatGPT tab to communicate with
 * Prefers: 1) Active tab in current window, 2) Regular chat tabs over Custom GPT tabs
 */
async function findChatGPTTab() {
    // First try to find tabs in the current/focused window
    const currentWindowTabs = await chrome.tabs.query({
        url: ['https://chatgpt.com/*'],
        currentWindow: true
    });


    if (currentWindowTabs.length > 0) {
        // Prefer regular chat tabs (not Custom GPTs which have /g/ in URL)
        const regularTabs = currentWindowTabs.filter(t => !t.url.includes('/g/'));
        const activeTab = currentWindowTabs.find(t => t.active);

        if (activeTab) {
            return activeTab;
        }
        if (regularTabs.length > 0) {
            return regularTabs[0];
        }
        return currentWindowTabs[0];
    }

    // Fallback: check all windows, prefer regular chat tabs
    const allTabs = await chrome.tabs.query({ url: ['https://chatgpt.com/*'] });
    if (allTabs.length === 0) {
        throw new Error('No ChatGPT tab found. Please open chatgpt.com first.');
    }

    const regularTabs = allTabs.filter(t => !t.url.includes('/g/'));
    const selected = regularTabs.length > 0 ? regularTabs[0] : allTabs[0];
    return selected;
}
/**
 * Cached tab for current export session
 * This prevents tab switching from breaking an ongoing export
 */
let cachedExportTab = null;
let pinnedTab = null;
export function pinExportTab(tab) { pinnedTab = tab; cachedExportTab = tab; }

/**
 * Clear the cached tab (call at start of new export)
 */
function clearCachedTab() {
    cachedExportTab = pinnedTab;
}

/**
 * Get or find a ChatGPT tab for the export session
 * Uses cached tab if available and valid, otherwise finds a new one
 */
async function getExportTab() {
    // If we have a cached tab, verify it still exists
    if (cachedExportTab) {
        try {
            const tab = await chrome.tabs.get(cachedExportTab.id);
            if (tab && isChatGPTPage(tab.url)) return tab;
            throw new Error('The export tab left chatgpt.com');
        } catch (e) {
            if (pinnedTab) throw new Error('The original export tab is gone or left chatgpt.com');
        }
        cachedExportTab = null;
    }

    // Find a new tab
    const tab = await findChatGPTTab();
    cachedExportTab = tab;
    return tab;
}

/**
 * Send message to a specific ChatGPT tab
 */
async function sendToTab(tab, message) {
    if (!isChatGPTPage(tab?.url)) throw new Error('Exporter is restricted to chatgpt.com');
    const prior = message.action !== 'ping' ? await cachedRequest(message) : null;
    if (prior) return prior;
    const response = await requestTab(tab, message);
    if (message.action !== 'ping' && !response?.error) await cacheRequest(message, response);
    return response;
}

export async function requestTab(tab, message) {
    if (!tab?.id || !isChatGPTPage(tab.url)) {
        throw new Error('No valid ChatGPT tab available.');
    }

    // First try to send message directly
    try {
        const response = await chrome.tabs.sendMessage(tab.id, { module: 'gptExporter', ...message, contextKey: (await getJob())?.contextKey });
        return response;
    } catch (error) {
        // Content script not loaded, try to inject it

        try {
            await chrome.scripting.executeScript({
                target: { tabId: tab.id },
                files: ['modules/gpt-exporter/content.js']
            });

            // Wait for script to initialize
            await new Promise(r => setTimeout(r, 500));

            // Try again
            const response = await chrome.tabs.sendMessage(tab.id, { module: 'gptExporter', ...message, contextKey: (await getJob())?.contextKey });
            return response;
        } catch (injectError) {
            throw new Error('Failed to connect to ChatGPT tab. Please ensure you have a ChatGPT page open and try again.');
        }
    }
}

/**
 * Send message to content script using cached tab
 */
async function sendToContentScript(message) {
    const tab = await getExportTab();
    try {
        return await sendToTab(tab, message);
    } catch (error) {
        // Clear the cached tab so we try a different one next time
        cachedExportTab = null;
        throw error;
    }
}

/**
 * Wrapper to call content script with retry logic
 * Handles rate limiting and temporary failures during list fetching
 */
async function sendWithRetry(message, description = 'API call') {
    let lastError = null;

    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
        try {
            const response = await sendToContentScript(message);

            if (response.error) {
                lastError = response.error;
                const backoffTime = RETRY_BACKOFF * (attempt + 1);
                await sleep(backoffTime);
                continue;
            }

            return response;
        } catch (error) {
            lastError = error.message || String(error);
            const backoffTime = RETRY_BACKOFF * (attempt + 1);
            await sleep(backoffTime);
        }
    }

    return { error: lastError };
}

/**
 * Get conversation list via content script (with retry)
 */
async function getConversationsList(offset = 0, limit = 28) {
    return sendWithRetry(
        { action: 'getConversationsList', offset, limit },
        `getConversationsList(offset=${offset})`
    );
}

/**
 * Get list of projects (with retry)
 */
async function getProjectsList() {
    return sendWithRetry(
        { action: 'getProjectsList' },
        'getProjectsList'
    );
}

/**
 * Get conversations within a project (with retry)
 */
async function getProjectConversations(projectId, cursor = '0') {
    return sendWithRetry(
        { action: 'getProjectConversations', projectId, cursor },
        `getProjectConversations(${projectId})`
    );
}

/**
 * Get all conversations from a specific project
 * Uses cursor-based pagination
 * @param {number} maxItems - Optional limit on number of items to fetch (0 = unlimited)
 */
async function getAllProjectConversationsMeta(projectId, projectName, onProgress = null, maxItems = 0) {
    const conversations = [];
    let cursor = '0';
    let totalFetched = 0;

    while (true) {
        // Check for cancellation
        checkCancellation();

        const response = await getProjectConversations(projectId, cursor);

        if (response.error) {
            break;
        }

        if (!response.items || response.items.length === 0) {
            break;
        }

        // Mark conversations with their project info
        const itemsWithProject = response.items.map(item => ({
            ...item,
            _projectId: projectId,
            _projectName: projectName
        }));

        conversations.push(...itemsWithProject);
        totalFetched += response.items.length;


        if (onProgress) {
            onProgress(conversations.length, response.total || conversations.length);
        }

        // Check if we've reached the limit
        if (maxItems > 0 && conversations.length >= maxItems) {
            break;
        }

        // Check if there's a next page
        if (!response.cursor) {
            break;
        }

        cursor = response.cursor;
        await sleep(randomDelay(2000, 4000));
    }

    return conversations;
}


/**
 * Get all conversation metadata (including from projects)
 * Projects are fetched FIRST because they tend to be more important
 * @param {function} onProgress - Progress callback
 * @param {number} fetchLimit - Optional limit on total items to fetch (0 = unlimited)
 */
async function getAllConversationsMeta(onProgress = null, fetchLimit = 0) {
    const allConversations = [];

    // FIRST: Fetch projects and their conversations (higher priority)
    const projectsResponse = await getProjectsList();

    if (projectsResponse.items && projectsResponse.items.length > 0) {

        for (const project of projectsResponse.items) {
            // Check for cancellation
            checkCancellation();

            // Check if we've reached the limit
            if (fetchLimit > 0 && allConversations.length >= fetchLimit) {
                break;
            }

            const projectId = project.gizmo?.id || project.id;
            const projectName = project.gizmo?.display?.name || project.display?.name || projectId;

            if (!projectId) continue;

            // Random delay 2-4 seconds between project fetches
            await sleep(randomDelay(2000, 4000));

            // Calculate remaining items we can fetch
            const remainingLimit = fetchLimit > 0 ? fetchLimit - allConversations.length : 0;

            const projectConversations = await getAllProjectConversationsMeta(
                projectId,
                projectName,
                (current, projectTotal) => {
                    if (onProgress) {
                        // Report progress as we fetch project conversations
                        onProgress(allConversations.length + current, allConversations.length + current);
                    }
                },
                remainingLimit
            );

            if (projectConversations.length > 0) {
                allConversations.push(...projectConversations);
            }
        }
    } else {
    }

    // Check if we've already reached the limit from projects
    if (fetchLimit > 0 && allConversations.length >= fetchLimit) {
        return allConversations;
    }

    // SECOND: Get main/regular conversations
    let offset = 0;
    const pageSize = 28;

    while (true) {
        // Check for cancellation
        checkCancellation();

        const response = await getConversationsList(offset, pageSize);

        if (response.error) {
            throw new Error(response.error);
        }

        // Continue until API returns no more items (don't trust 'total' - it may be capped)
        if (!response.items || response.items.length === 0) {
            break;
        }

        allConversations.push(...response.items);

        if (onProgress) {
            onProgress(allConversations.length, allConversations.length);
        }

        // Check if we've reached the limit
        if (fetchLimit > 0 && allConversations.length >= fetchLimit) {
            break;
        }

        offset += pageSize;
        // Random delay 2-4 seconds between list pages
        await sleep(randomDelay(2000, 4000));
    }

    return allConversations;
}

/**
 * Get single conversation via content script
 */
async function getConversation(id) {
    return sendToContentScript({ action: 'getConversation', id });
}

function extractProjectUUID(projectId) {
    if (!projectId || typeof projectId !== 'string') {
        return null;
    }

    const match = projectId.match(/^(g-p-[a-f0-9]{32})/);
    return match ? match[1] : projectId;
}

function getConversationTargetFromTab(tab) {
    if (!tab?.id || !isChatGPTPage(tab.url)) {
        return null;
    }

    const parsed = parseChatGPTConversationUrl(tab.url);
    if (!parsed) {
        return null;
    }

    return {
        tab,
        conversationId: parsed.conversationId,
        projectId: parsed.projectId
    };
}

async function getCurrentConversationTarget() {
    if (pinnedTab) {
        const tab = await chrome.tabs.get(pinnedTab.id);
        const target = getConversationTargetFromTab(tab);
        if (!target) throw new Error('The original ChatGPT conversation is no longer open');
        return target;
    }
    const focusedTabs = await chrome.tabs.query({
        active: true,
        lastFocusedWindow: true
    });
    const focusedTarget = getConversationTargetFromTab(focusedTabs[0]);
    if (focusedTarget) {
        return focusedTarget;
    }

    const activeTabs = await chrome.tabs.query({ active: true });
    const matchingTargets = activeTabs
        .map(getConversationTargetFromTab)
        .filter(Boolean);

    if (matchingTargets.length === 1) {
        return matchingTargets[0];
    }

    if (matchingTargets.length > 1) {
        throw new Error('Multiple active ChatGPT conversations found in different windows. Focus the one you want, then try again.');
    }

    throw new Error('No active ChatGPT conversation found. Open the chat you want to export, then try again.');
}

async function getProjectNameForCurrentConversation(tab, projectId) {
    if (!projectId) {
        return null;
    }

    try {
        const response = await sendToTab(tab, { action: 'getProjectsList' });
        if (response?.error) {
            return null;
        }

        const apiProjectId = extractProjectUUID(projectId);

        for (const project of response.items || []) {
            const candidateId = project.gizmo?.id || project.id;
            if (!candidateId) {
                continue;
            }

            if (candidateId === projectId || extractProjectUUID(candidateId) === apiProjectId) {
                return project.gizmo?.display?.name || project.display?.name || null;
            }
        }
    } catch (error) {
    }

    return null;
}

async function buildExportFiles(fullConversations, formats, reportProgress) {
    const filesToBundle = [];

    if (formats.markdown) {
        const markdownOptions = { includeAboveBranchedFrom: !!formats.includeAboveBranchedFrom };
        for (let i = 0; i < fullConversations.length; i++) {
            const md = conversationToMarkdown(fullConversations[i], markdownOptions);
            filesToBundle.push({ filename: md.filename, content: md.content, mimeType: 'text/markdown' });
            reportProgress('exporting', i + 1, fullConversations.length);
        }
    }

    if (formats.json) {
        const json = createBackupJson(fullConversations);
        filesToBundle.push({ filename: json.filename, content: json.content, mimeType: 'application/json' });
    }

    return filesToBundle;
}

async function downloadExportFiles(filesToBundle, folder = '') {
    const job = await getJob();
    if (job?.files) filesToBundle = job.files;
    else if (job) { job.files = filesToBundle; await saveOutput(null, job); }
    const results = [];

    if (filesToBundle.length > ZIP_THRESHOLD) {
        updateExportState('zipping', 0, filesToBundle.length);
        const today = new Date((await getJob())?.startedAt || Date.now()).toISOString().split('T')[0];
        const zipFilename = `ChatGPT_Export_${today}.zip`;
        await createZipBundle(filesToBundle, zipFilename, folder);
        results.push({ type: 'zip', filename: zipFilename, fileCount: filesToBundle.length });
        updateExportState('complete', filesToBundle.length, filesToBundle.length);
        return results;
    }

    for (const file of filesToBundle) {
        await downloadFile(file.filename, file.content, file.mimeType, folder);
        results.push({ type: file.mimeType.includes('markdown') ? 'markdown' : 'json', filename: file.filename });
    }

    updateExportState('complete', filesToBundle.length, filesToBundle.length);
    return results;
}

async function markConversationsAsExported(fullConversations) {
    const exportedData = fullConversations.map(c => ({
        id: c.conversation_id || c.id,
        updateTime: c.update_time
            ? (typeof c.update_time === 'number'
                ? new Date(c.update_time * 1000).toISOString()
                : c.update_time)
            : new Date().toISOString()
    }));

    await markMultipleExported(exportedData);
}

/**
 * Get multiple conversations with rate limiting, retry logic, and batch pauses
 */
async function getConversations(conversationIds, onProgress = null) {
    const conversations = [];
    let consecutiveErrors = 0;
    const totalCount = conversationIds.length;
    const startTime = Date.now();


    for (let i = 0; i < conversationIds.length; i++) {
        // Check for cancellation
        checkCancellation();

        const conversationNum = i + 1;
        let conversation = null;
        let lastError = null;

        // Every 100 conversations, take a longer break (2-4 minutes)
        if (i > 0 && i % 100 === 0) {
            const pauseMinutes = randomDelay(2 * 60 * 1000, 4 * 60 * 1000);
            const pauseMinutesDisplay = (pauseMinutes / 60000).toFixed(1);
            await sleep(pauseMinutes);
        }

        // Retry logic with exponential backoff
        for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
            try {
                conversation = await getConversation(conversationIds[i]);

                if (conversation.error) {
                    lastError = conversation.error;
                    conversation = null;

                    // Wait with backoff before retry
                    const backoffTime = RETRY_BACKOFF * (attempt + 1);
                    await sleep(backoffTime);
                    continue;
                }

                // Success - reset consecutive error counter
                consecutiveErrors = 0;
                break;
            } catch (error) {
                lastError = error.message || String(error);
                const backoffTime = RETRY_BACKOFF * (attempt + 1);
                await sleep(backoffTime);
            }
        }

        if (!conversation) {
            consecutiveErrors++;

            // If we get 5 consecutive errors, something is seriously wrong - abort
            if (consecutiveErrors >= 5) {
                const elapsed = ((Date.now() - startTime) / 60000).toFixed(1);
                throw new Error(`Export aborted after ${consecutiveErrors} consecutive failures. Fetched ${conversations.length} conversations. Try again later.`);
            }
            continue;
        }

        conversations.push(conversation);

        if (onProgress) {
            onProgress(conversationNum, totalCount);
        }

        // Random delay between 2-4 seconds before next request
        if (i < conversationIds.length - 1) {
            const delay = randomDelay(2000, 4000);
            await sleep(delay);
        }

        // Log progress every 25 conversations
        if (conversationNum % 25 === 0) {
            const elapsed = ((Date.now() - startTime) / 60000).toFixed(1);
            const rate = (conversationNum / (Date.now() - startTime) * 60000).toFixed(1);
        }
    }

    const totalElapsed = ((Date.now() - startTime) / 60000).toFixed(1);

    return conversations;
}

/**
 * Offscreen document helpers.
 *
 * Chrome's download system rejects data: URLs larger than ~2MB - the download
 * fails with NETWORK_FAILED ("Check internet connection" in the UI). MV3
 * service workers can't call URL.createObjectURL, so we delegate Blob URL
 * creation to an offscreen document. This makes downloads work regardless
 * of file size (fixes long conversations failing in "Export Current Chat").
 */
async function ensureOffscreenDocument() { await ensureOffscreen(); }

/**
 * Create a Blob URL in the offscreen document.
 * @param {string} content - File content (text, or base64 if isBase64 is true)
 * @param {string} mimeType
 * @param {boolean} isBase64
 * @returns {Promise<string>} blob: URL
 */
async function createBlobUrl(content, mimeType, isBase64 = false) {
    await ensureOffscreenDocument();
    const response = await chrome.runtime.sendMessage({
        target: 'offscreen', module: 'gptExporter',
        action: 'create-blob-url',
        content,
        mimeType,
        isBase64
    });
    if (!response || !response.success) {
        throw new Error(`Failed to create blob URL: ${response ? response.error : 'no response from offscreen document'}`);
    }
    return response.url;
}

const downloadManager = createDownloadManager({
    downloads: chrome.downloads,
    isCancelled: () => exportState.cancelRequested,
    onStarted: (id, url, path) => saveOutput({ path, id }),
    revokeBlobUrl: url => chrome.runtime.sendMessage({
        target: 'offscreen', module: 'gptExporter',
        action: 'revoke-blob-url',
        url
    })
});

/**
 * Download a blob and wait for successful terminal completion, including cleanup.
 */
async function downloadBlobUrl(blobUrl, fullPath) {
    validateDownloadPath(fullPath);
    checkCancellation();
    updateExportState('saving', 0, 1);
    const prior = await savedOutput(fullPath);
    if (prior) {
        const item = (await chrome.downloads.search({ id: prior.id }))[0];
        if (item?.state === 'in_progress' || (item?.state === 'complete' && item.exists !== false)) {
            await callOffscreen({ module: 'gptExporter', action: 'revoke-blob-url', url: blobUrl });
            return downloadManager.waitForDownload(prior.id, null);
        }
    }
    const id = await downloadManager.download(blobUrl, fullPath);
    await saveOutput({ path: fullPath, id });
    return id;
}

/**
 * Download a file using Chrome downloads API
 */
async function downloadFile(filename, content, mimeType = 'text/plain', folder = '') {

    let fullPath = filename;
    if (folder) {
        folder = folder.replace(/^[/\\]+|[/\\]+$/g, '');
        fullPath = `${folder}/${filename}`;
    }


    try {
        // Use a Blob URL created in the offscreen document. Unlike data:
        // URLs, blob: URLs have no size limit in the downloads system.
        const blobUrl = await createBlobUrl(content, mimeType, false);
        const downloadId = await downloadBlobUrl(blobUrl, fullPath);


        return downloadId;
    } catch (error) {
        throw error;
    }
}

/**
 * Create a ZIP bundle from multiple files
 * @param {Array} files - Array of {filename, content, mimeType} objects
 * @param {string} zipFilename - Name of the output ZIP file
 * @param {string} folder - Optional folder path
 */
async function createZipBundle(files, zipFilename, folder = '') {

    let fullPath = zipFilename;
    if (folder) {
        folder = folder.replace(/^[/\\]+|[/\\]+$/g, '');
        fullPath = `${folder}/${zipFilename}`;
    }

    try {
        // ZIP is built with real JSZip (DEFLATE compression) in the offscreen
        // document, which returns a Blob URL (no data: URL size limit).
        await ensureOffscreenDocument();
        const response = await chrome.runtime.sendMessage({
            target: 'offscreen', module: 'gptExporter',
            action: 'create-zip-blob-url',
            files: files.map(f => ({ filename: f.filename, content: f.content }))
        });
        if (!response || !response.success) {
            throw new Error(`ZIP creation failed: ${response ? response.error : 'no response from offscreen document'}`);
        }
        const downloadId = await downloadBlobUrl(response.url, fullPath);


        return downloadId;
    } catch (error) {
        throw error;
    }
}

/**
 * Check connection by pinging content script
 */
async function checkConnection() {
    try {
        const response = await sendToContentScript({ action: 'ping' });
        const connected = response && response.success;
        return connected;
    } catch (e) {
        return false;
    }
}

/**
 * Export all conversations
 */
async function exportAll(formats, onProgress, folder = '', limit = 0) {
    // Clear cached tab at start of new export to get a fresh, valid tab
    clearCachedTab();

    // Track export state
    exportState.isRunning = true;
    exportState.cancelRequested = false;
    exportState.startTime = Date.now();
    startKeepAlive();

    const reportProgress = (phase, current, total) => {
        updateExportState(phase, current, total);
        onProgress({ phase, current, total });
    };

    try {
        reportProgress('fetching_list', 0, 0);

        // Pass limit to avoid fetching more metadata than needed
        const allMeta = await getAllConversationsMeta((current, total) => {
            reportProgress('fetching_list', current, total);
        }, limit);

        let toExport = allMeta;
        if (limit > 0 && limit < allMeta.length) {
            toExport = allMeta.slice(0, limit);
        }

        reportProgress('fetching_conversations', 0, toExport.length);

        // Build lookup map for project metadata before fetching full conversations
        const projectLookup = new Map();
        for (const meta of toExport) {
            if (meta._projectId) {
                projectLookup.set(meta.id, {
                    _projectId: meta._projectId,
                    _projectName: meta._projectName
                });
            }
        }

        const conversationIds = toExport.map(c => c.id);
        const fullConversations = await getConversations(conversationIds, (current, total) => {
            reportProgress('fetching_conversations', current, total);
        });

        // Merge project metadata into full conversations
        for (const conv of fullConversations) {
            const projectInfo = projectLookup.get(conv.conversation_id || conv.id);
            if (projectInfo) {
                conv._projectId = projectInfo._projectId;
                conv._projectName = projectInfo._projectName;
            }
        }

        reportProgress('exporting', 0, fullConversations.length);

        const filesToBundle = await buildExportFiles(fullConversations, formats, reportProgress);
        const results = await downloadExportFiles(filesToBundle, folder);

        await markConversationsAsExported(fullConversations);

        return {
            totalExported: fullConversations.length,
            results
        };
    } finally {
        exportState.isRunning = false;
        exportState.phase = null;
        stopKeepAlive();
    }
}

/**
 * Export only new or updated conversations
 */
async function exportNewUpdated(formats, onProgress, folder = '', limit = 0) {
    // Clear cached tab at start of new export to get a fresh, valid tab
    clearCachedTab();

    // Track export state
    exportState.isRunning = true;
    exportState.cancelRequested = false;
    exportState.startTime = Date.now();
    startKeepAlive();

    const reportProgress = (phase, current, total) => {
        updateExportState(phase, current, total);
        onProgress({ phase, current, total });
    };

    try {
        reportProgress('fetching_list', 0, 0);

        // Determine fetch limit based on export history
        // If user has never exported, all conversations need export - no buffer needed
        // If user has history, some will be filtered out - use buffer
        let fetchLimit = 0;
        if (limit > 0) {
            const stats = await getStats();
            if (stats.totalExported === 0) {
                // First time export - no filtering will occur, use limit directly
                fetchLimit = limit;
            } else {
                // Has history - some will be filtered, use 3x buffer
                fetchLimit = Math.max(limit * 3, limit + 100);
            }
        }

        const allMeta = await getAllConversationsMeta((current, total) => {
            reportProgress('fetching_list', current, total);
        }, fetchLimit);

        let needExport = await filterNeedingExport(allMeta);

        if (needExport.length === 0) {
            return {
                totalExported: 0,
                message: 'All conversations are already up to date!',
                results: []
            };
        }

        if (limit > 0 && limit < needExport.length) {
            needExport = needExport.slice(0, limit);
        }

        reportProgress('fetching_conversations', 0, needExport.length);

        // Build lookup map for project metadata before fetching full conversations
        const projectLookup = new Map();
        for (const meta of needExport) {
            if (meta._projectId) {
                projectLookup.set(meta.id, {
                    _projectId: meta._projectId,
                    _projectName: meta._projectName
                });
            }
        }

        const conversationIds = needExport.map(c => c.id);
        const fullConversations = await getConversations(conversationIds, (current, total) => {
            reportProgress('fetching_conversations', current, total);
        });

        // Merge project metadata into full conversations
        for (const conv of fullConversations) {
            const projectInfo = projectLookup.get(conv.conversation_id || conv.id);
            if (projectInfo) {
                conv._projectId = projectInfo._projectId;
                conv._projectName = projectInfo._projectName;
            }
        }

        reportProgress('exporting', 0, fullConversations.length);

        const filesToBundle = await buildExportFiles(fullConversations, formats, reportProgress);
        const results = await downloadExportFiles(filesToBundle, folder);

        await markConversationsAsExported(fullConversations);

        return {
            totalExported: fullConversations.length,
            results
        };
    } finally {
        exportState.isRunning = false;
        exportState.phase = null;
        stopKeepAlive();
    }
}

/**
 * Export only the currently active conversation tab
 */
async function exportCurrentConversation(formats, onProgress, folder = '') {
    clearCachedTab();

    exportState.isRunning = true;
    exportState.cancelRequested = false;
    exportState.startTime = Date.now();
    startKeepAlive();

    const reportProgress = (phase, current, total) => {
        updateExportState(phase, current, total);
        onProgress({ phase, current, total });
    };

    try {
        reportProgress('fetching_conversations', 0, 1);

        const target = await getCurrentConversationTarget();
        const conversation = await sendToTab(target.tab, {
            action: 'getConversation',
            id: target.conversationId
        });

        if (conversation.error) {
            throw new Error(conversation.error);
        }

        if (target.projectId) {
            conversation._projectId = target.projectId;
            conversation._projectName = await getProjectNameForCurrentConversation(target.tab, target.projectId);
        }

        reportProgress('fetching_conversations', 1, 1);
        reportProgress('exporting', 0, 1);

        const fullConversations = [conversation];
        const filesToBundle = await buildExportFiles(fullConversations, formats, reportProgress);
        const results = await downloadExportFiles(filesToBundle, folder);

        await markConversationsAsExported(fullConversations);

        return {
            totalExported: 1,
            results
        };
    } finally {
        exportState.isRunning = false;
        exportState.phase = null;
        stopKeepAlive();
    }
}

/**
 * Handle messages from popup
 */
export async function handleAction(message) {
    const handleAsync = async () => {
        try {
            switch (message.action) {
                case 'checkConnection':
                    return { connected: await checkConnection() };

                case 'getStats':
                    return await getStats();

                case 'getExportState':
                    return getExportState();

                case 'getCurrentConversationTarget': {
                    const target = await getCurrentConversationTarget();
                    return {
                        available: true,
                        conversationId: target.conversationId,
                        projectId: target.projectId
                    };
                }

                case 'exportAll':
                    return await exportAll(
                        message.formats,
                        () => {},
                        message.downloadFolder || '',
                        message.limit || 0
                    );

                case 'exportNewUpdated':
                    return await exportNewUpdated(
                        message.formats,
                        () => {},
                        message.downloadFolder || '',
                        message.limit || 0
                    );

                case 'exportCurrentConversation':
                    return await exportCurrentConversation(
                        message.formats,
                        () => {},
                        message.downloadFolder || ''
                    );

                case 'clearHistory':
                    await clearHistory();
                    return { success: true };

                case 'cancelExport':
                    return cancelExport();

                default:
                    throw new Error(`Unknown action: ${message.action}`);
            }
        } catch (error) {
            return { error: error.message };
        }
    };

    return handleAsync();
}

export { getExportState, cancelExport, downloadManager };

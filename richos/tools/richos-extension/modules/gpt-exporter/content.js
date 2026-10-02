(() => {
if (location.origin !== 'https://chatgpt.com' || globalThis.__richosGptExporterBridge) return;
globalThis.__richosGptExporterBridge = true;
/**
 * Content Script - runs in the context of chatgpt.com
 * This script can access the page's cookies for authenticated API calls
 * 
 * Based on authentication pattern from: https://github.com/pionxzh/chatgpt-exporter
 */

const API_BASE = 'https://chatgpt.com/backend-api';
const SESSION_API = 'https://chatgpt.com/api/auth/session';

// Cached access token
let cachedAccessToken = null;
let accountContext = null;
let exportContext = null;

/**
 * Fetch session to get access token
 */
async function fetchSession() {
    const response = await fetch(SESSION_API, {
        credentials: 'include'
    });

    if (!response.ok) {
        throw new Error(`Session fetch failed: ${response.status}`);
    }

    const session = await response.json();
    return session;
}

/**
 * Get access token (cached)
 * @param {boolean} forceRefresh - Bypass the cache (e.g. after a 401)
 */
async function getAccessToken(forceRefresh = false) {
    if (cachedAccessToken && !forceRefresh) {
        return cachedAccessToken;
    }

    const session = await fetchSession();
    cachedAccessToken = session.accessToken;
    accountContext = String(session.user?.id || session.user?.email || 'unknown') + ':' + (getWorkspaceAccountId() || 'personal');
    return cachedAccessToken;
}

/**
 * Get team account ID if user is on a team workspace
 */
function getWorkspaceAccountId() {
    const match = document.cookie.match(/(^|;)\s*_account\s*=\s*([^;]+)/);
    return match ? match.pop() : null;
}

/**
 * Make an authenticated request to ChatGPT API
 */
const FETCH_TIMEOUT_MS = 30000;

async function apiRequest(endpoint, isRetryAfter401 = false, expectedContext = exportContext) {
    const url = `${API_BASE}${endpoint}`;

    // Abort hung requests so exports don't stall indefinitely
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

    try {
        const accessToken = await getAccessToken(true);
        if (expectedContext && accountContext !== expectedContext) throw new Error('ChatGPT account or workspace changed; start a new export');
        const accountId = getWorkspaceAccountId();

        const headers = {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${accessToken}`,
            'X-Authorization': `Bearer ${accessToken}`,
        };

        // Add team account ID if present
        if (accountId) {
            headers['Chatgpt-Account-Id'] = accountId;
        }

        const response = await fetch(url, {
            method: 'GET',
            credentials: 'include',
            headers: headers,
            signal: controller.signal
        });


        // Stale cached token: refresh it once and retry
        if (response.status === 401 && !isRetryAfter401) {
            cachedAccessToken = null;
            clearTimeout(timeoutId);
            return apiRequest(endpoint, true, expectedContext);
        }

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(`API Error: ${response.status} ${response.statusText}`);
        }

        const data = await response.json();
        return data;
    } catch (error) {
        if (error.name === 'AbortError') {
            const timeoutError = new Error(`Request timed out after ${FETCH_TIMEOUT_MS / 1000}s: ${endpoint}`);
            throw timeoutError;
        }
        throw error;
    } finally {
        clearTimeout(timeoutId);
    }
}

/**
 * Get conversation list (main/non-project conversations)
 */
async function getConversationsList(offset = 0, limit = 28) {
    return apiRequest(`/conversations?offset=${offset}&limit=${limit}`);
}

/**
 * Get single conversation
 */
async function getConversation(id) {
    return apiRequest(`/conversation/${id}`);
}

/**
 * Fetch all projects from the snorlax/sidebar API with cursor pagination
 * This endpoint returns all projects, not just the visible 5
 */
async function fetchAllProjectsFromSidebar() {
    const projects = [];
    let cursor = null;
    const seenIds = new Set();

    while (true) {
        let url = '/gizmos/snorlax/sidebar?conversations_per_gizmo=5&owned_only=true';
        if (cursor) {
            url += `&cursor=${encodeURIComponent(cursor)}`;
        }

        const response = await apiRequest(url);


        // Response has 'items' array with gizmo objects
        // Structure is: item.gizmo.gizmo.id (double-nested!)
        if (response.items && Array.isArray(response.items)) {
            for (const item of response.items) {
                // Handle double-nested structure: item.gizmo.gizmo
                const innerGizmo = item.gizmo?.gizmo || item.gizmo || item;
                const id = innerGizmo.id || item.gizmo?.id || item.id;

                // Only include projects (IDs starting with g-p-)
                if (id && id.startsWith('g-p-') && !seenIds.has(id)) {
                    seenIds.add(id);
                    const displayName = innerGizmo.display?.name || innerGizmo.name || id;
                    projects.push({
                        id: id,
                        gizmo: {
                            id: id,
                            display: { name: displayName }
                        }
                    });
                }
            }
        }

        // Check for next page
        if (response.cursor) {
            cursor = response.cursor;
        } else {
            break;
        }
    }

    return projects;
}

/**
 * Get list of projects (GPT Projects use gizmo infrastructure)
 * Projects have IDs starting with "g-p-"
 * Uses the snorlax/sidebar endpoint which returns all projects with pagination
 */
async function getProjectsList() {
    // First try the snorlax/sidebar endpoint which returns all projects
    try {
        const allProjects = await fetchAllProjectsFromSidebar();
        if (allProjects.length > 0) {
            return { items: allProjects };
        }
    } catch (error) {
    }

    // Fallback to other endpoints
    const endpoints = [
        { url: '/gizmos/discovery', parse: 'cuts' },
    ];

    for (const endpoint of endpoints) {
        try {
            const response = await apiRequest(endpoint.url);


            let items = [];

            // Parse based on response structure
            if (endpoint.parse === 'cuts' && response.cuts) {
                for (const cut of response.cuts) {
                    if (cut.list?.items) {
                        for (const item of cut.list.items) {
                            if (item.resource?.gizmo) {
                                items.push({ gizmo: item.resource.gizmo });
                            } else if (item.gizmo) {
                                items.push(item);
                            } else {
                                items.push(item);
                            }
                        }
                    }
                }
            } else {
                items = response.items || response.projects || response.list || [];
            }

            if (!Array.isArray(items)) continue;

            // Filter to only include projects (IDs starting with g-p-)
            const projects = items.filter(item => {
                const id = item.id || item.gizmo?.id || item.project_id || '';
                return id.startsWith('g-p-');
            });


            if (projects.length > 0) {
                return { items: projects };
            }
        } catch (error) {
        }
    }

    // FALLBACK: Extract project IDs from sidebar DOM
    try {
        const projectsFromDOM = extractProjectsFromDOM();
        if (projectsFromDOM.length > 0) {
            return { items: projectsFromDOM };
        }
    } catch (error) {
    }

    return { items: [] };
}

/**
 * Extract project IDs from the page DOM (sidebar links)
 * Projects have URLs like: /g/g-p-{id}-{name}/project
 */
function extractProjectsFromDOM() {
    const projects = [];
    const seenIds = new Set();

    // Find all links that look like project links
    const links = document.querySelectorAll('a[href*="/g/g-p-"]');

    for (const link of links) {
        const href = link.getAttribute('href');
        // Match pattern: /g/g-p-{uuid}-{name}
        const match = href.match(/\/g\/(g-p-[a-f0-9]+-[^/]+)/);
        if (match && !seenIds.has(match[1])) {
            const projectId = match[1];
            seenIds.add(projectId);

            // Try to get the display name from the link text
            const displayName = link.textContent?.trim() || projectId;

            projects.push({
                id: projectId,
                gizmo: {
                    id: projectId,
                    display: { name: displayName }
                }
            });
        }
    }

    return projects;
}


/**
 * Extract the API-compatible project ID (just the UUID, without the slug name)
 * DOM gives us: g-p-67c804d08cac8191af6ee36ed6219624-software-hardware
 * API needs:    g-p-67c804d08cac8191af6ee36ed6219624
 */
function extractProjectUUID(fullProjectId) {
    // Pattern: g-p-{32-char-hex}-{slug-name}
    // Extract: g-p-{32-char-hex}
    const match = fullProjectId.match(/^(g-p-[a-f0-9]{32})/);
    if (match) {
        return match[1];
    }
    // Fallback: return as-is
    return fullProjectId;
}

/**
 * Get conversations within a specific project
 * Uses the /gizmos/{id}/conversations endpoint with cursor-based pagination
 */
async function getProjectConversations(projectId, cursor = '0') {
    // Extract just the UUID part for the API call
    const apiProjectId = extractProjectUUID(projectId);
    const endpoint = `/gizmos/${apiProjectId}/conversations?cursor=${cursor}`;

    try {
        const response = await apiRequest(endpoint);


        // Response has 'items' array and 'cursor' for next page
        if (response.items) {
            return {
                items: response.items,
                cursor: response.cursor || null,
                total: response.total || response.items.length
            };
        }

        return { items: [], cursor: null, total: 0 };
    } catch (error) {
        return { items: [], cursor: null, total: 0 };
    }
}


/**
 * Listen for messages from the extension
 */
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message?.module !== 'gptExporter') return false;

    const handleAsync = async () => {
        try {
            if (message.action !== 'ping' && message.contextKey && (accountContext !== message.contextKey || message.contextKey.split(':').slice(1).join(':') !== (getWorkspaceAccountId() || 'personal'))) throw new Error('ChatGPT account or workspace changed; start a new export');
            if (message.action !== 'ping') exportContext = message.contextKey || null;
            switch (message.action) {
                case 'getConversationsList':
                    return await getConversationsList(message.offset || 0, message.limit || 28);

                case 'getConversation':
                    return await getConversation(message.id);

                case 'getProjectsList':
                    return await getProjectsList();

                case 'getProjectConversations':
                    return await getProjectConversations(message.projectId, message.cursor || '0');

                case 'ping':
                    // Also verify we can get a token
                    try {
                        await getAccessToken(true);
                        return { success: true, url: window.location.href, hasToken: Boolean(cachedAccessToken), contextKey: accountContext };
                    } catch (e) {
                        return { success: true, url: window.location.href, hasToken: false, tokenError: e.message };
                    }

                default:
                    throw new Error(`Unknown action: ${message.action}`);
            }
        } catch (error) {
            return { error: error.message };
        }
    };

    handleAsync().then(sendResponse);
    return true;
});

})();

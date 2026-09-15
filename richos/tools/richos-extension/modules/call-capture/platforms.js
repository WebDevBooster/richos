/**
 * RichOS — call platform detection (pure module, node-testable).
 *
 * v0 is deliberately audio-first and therefore platform-AGNOSTIC: anything that plays call
 * audio in a Chrome tab can be captured. This file only decides *when to arm automatically*
 * and how to name the session directory — it is never load-bearing for capture itself.
 *
 * `requiresAudible: true` marks apps whose URL does not change when a call starts
 * (Slack huddles), so we wait for the tab to actually make sound.
 */

/**
 * @typedef {{id: string, label: string, requiresAudible?: boolean,
 *            match: (u: URL) => boolean, slug?: (u: URL) => string}} Platform
 */

/** @type {Platform[]} */
export const PLATFORMS = [
  {
    id: 'meet',
    label: 'Google Meet',
    match: (u) => u.hostname === 'meet.google.com' && /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}\b/.test(u.pathname),
    slug: (u) => u.pathname.split('/').filter(Boolean)[0] || 'meet',
  },
  {
    id: 'zoom-web',
    label: 'Zoom (web client)',
    match: (u) => /(^|\.)zoom\.us$/.test(u.hostname) && /^\/wc\//.test(u.pathname),
    slug: (u) => {
      const m = u.pathname.match(/\/wc\/(?:join\/)?(\d{6,})/);
      return m ? m[1] : 'zoom';
    },
  },
  {
    id: 'teams-web',
    label: 'Microsoft Teams (web)',
    match: (u) =>
      /(^|\.)teams\.(microsoft|live)\.com$/.test(u.hostname) &&
      /(meetup-join|pre-join-calling|modern-calling|\/v2\/|meetingjoin)/i.test(u.href),
    slug: () => 'teams',
  },
  {
    id: 'whereby',
    label: 'Whereby',
    match: (u) => /(^|\.)whereby\.com$/.test(u.hostname) && u.pathname.length > 1,
    slug: (u) => u.pathname.split('/').filter(Boolean)[0] || 'whereby',
  },
  {
    id: 'slack-huddle',
    label: 'Slack huddle',
    requiresAudible: true,
    match: (u) => /(^|\.)slack\.com$/.test(u.hostname) && /^\/(client|huddle)/.test(u.pathname),
    slug: () => 'slack',
  },
  {
    id: 'discord',
    label: 'Discord (web)',
    requiresAudible: true,
    match: (u) => /(^|\.)discord\.com$/.test(u.hostname) && /^\/channels\//.test(u.pathname),
    slug: () => 'discord',
  },
  {
    id: 'webex',
    label: 'Webex',
    requiresAudible: true,
    match: (u) => /(^|\.)webex\.com$/.test(u.hostname),
    slug: () => 'webex',
  },
];

/**
 * @param {string} url
 * @returns {{id: string, label: string, slug: string, requiresAudible: boolean}|null}
 */
export function detectPlatform(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null;
  for (const p of PLATFORMS) {
    if (p.match(parsed)) {
      return {
        id: p.id,
        label: p.label,
        slug: (p.slug ? p.slug(parsed) : p.id) || p.id,
        requiresAudible: Boolean(p.requiresAudible),
      };
    }
  }
  return null;
}

/**
 * Should this tab be armed automatically right now?
 *
 * Bias: arming a lobby or a few seconds of silence costs nothing; NOT arming a call is the
 * cardinal sin. So a recognized call URL arms on sight (after `armDelayMs`), audible or not.
 *
 * @param {{url?: string, audible?: boolean, openedAt?: number}} tab
 * @param {{armMode: string, armUnknownAudible: boolean, armDelayMs: number}} settings
 * @param {number} now
 * @returns {{arm: boolean, reason: string, platform: object|null}}
 */
export function shouldAutoArm(tab, settings, now) {
  const platform = detectPlatform(tab.url || '');
  if (settings.armMode !== 'auto') return { arm: false, reason: 'manual-mode', platform };

  const openMs = now - (tab.openedAt || now);
  if (platform) {
    if (platform.requiresAudible && !tab.audible) {
      return { arm: false, reason: 'awaiting-audio', platform };
    }
    if (openMs < settings.armDelayMs) return { arm: false, reason: 'arm-delay', platform };
    return { arm: true, reason: 'known-platform', platform };
  }
  if (settings.armUnknownAudible && tab.audible && openMs >= settings.armDelayMs) {
    return {
      arm: true,
      reason: 'unknown-audible',
      platform: { id: 'unknown', label: 'Unrecognised audible tab', slug: 'audio', requiresAudible: true },
    };
  }
  return { arm: false, reason: 'no-match', platform };
}

/**
 * A recognized call tab that is NOT being captured is itself a failure — this is the
 * check that turns "I forgot to arm" from a post-call discovery into an in-call alarm.
 * @param {{url?: string, audible?: boolean}} tab
 * @returns {boolean}
 */
export function isCallTab(tab) {
  const platform = detectPlatform(tab.url || '');
  if (!platform) return false;
  return platform.requiresAudible ? Boolean(tab.audible) : true;
}

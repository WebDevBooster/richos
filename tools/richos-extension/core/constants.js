/**
 * RichOS extension — shared core constants.
 *
 * Pure module: no `chrome.*` access, so the service worker, the offscreen document,
 * extension pages AND the node test harness can all import it.
 *
 * Nothing in this file (or anywhere in the extension) is OS-specific. The same
 * unpacked directory runs on Chrome for macOS, Windows and Linux.
 */

/** Product identity. The brand the CEO installs; `loro` is the destination, not the tool. */
export const PRODUCT = {
  name: 'RichOS',
  shortName: 'RichOS',
  /** Bump on every user-visible change (semver habit, same as the other extensions). */
  version: '0.2.1',
};

/** Keys in `chrome.storage.local`. Namespaced so future modules never collide. */
export const KEYS = {
  settings: 'richos.settings',
  activeSession: 'richos.callCapture.activeSession',
  sessionIndex: 'richos.callCapture.sessionIndex',
  alertLog: 'richos.callCapture.alertLog',
};

/** IndexedDB. One database for the whole extension; modules own object stores. */
export const DB = {
  name: 'richos-extension',
  // v2 adds the `captions` store (the secondary caption/enrichment channel).
  version: 2,
  stores: {
    /** key: [sessionId, seq] — one persisted audio chunk. */
    chunks: 'chunks',
    /** key: sessionId — the session record (mirror of the one written to the drop zone). */
    sessions: 'sessions',
    /** key: [sessionId, t] — one health heartbeat. */
    health: 'health',
    /**
     * key: [sessionId, seq] — one persisted caption revision. The SAME records that get
     * written to `captions.ndjson`, so the caption count never comes from a second heuristic.
     */
    captions: 'captions',
  },
};

/** Health-indicator colours (extension action badge). CEO-only: never participant-facing. */
export const BADGE = {
  green: '#1a7f37',
  amber: '#bf8700',
  red: '#c1121f',
  idle: '#5c5c5c',
};

/** Core settings shared by every module. */
export const CORE_DEFAULTS = {
  /** Sub-folder of Chrome's downloads folder (any OS) that acts as the loro drop zone. */
  dropFolder: 'richos-capture',
  /** Hide Chrome's own download bubble so drop-zone writes are not visible on screen. */
  suppressDownloadUi: true,
  /**
   * ROUTINE notifications (capture started / stopped). OFF by default — the toolbar badge
   * and popup are the ambient status surface; routine desktop pop-ups are noise.
   */
  notifyOnStartStop: false,
  /**
   * FAILURE alerts. ON by default and deliberately independent of `notifyOnStartStop`:
   * this is the reliability guarantee, not routine chatter. Always CEO-only.
   */
  notifyOnFailure: true,
  /** CEO-only audible chime on failure. OFF by default: an open mic would pick it up. */
  alertSound: false,
  /** Days the sync helper keeps exported audio before it may purge it. */
  retentionDays: 30,
};

/**
 * Declarative schema for the shared options page. Each module exports the same shape,
 * so the options page renders every module's settings without knowing what they are.
 * @typedef {{key: string, type: 'boolean'|'number'|'text'|'select', label: string,
 *            help?: string, min?: number, max?: number, options?: {value: string, label: string}[],
 *            danger?: boolean}} SettingField
 */

/** @type {{title: string, fields: SettingField[]}} */
export const CORE_SETTINGS_SCHEMA = {
  title: 'General',
  fields: [
    {
      key: 'dropFolder',
      type: 'text',
      label: 'Drop-zone folder',
      help: 'Sub-folder of your Chrome downloads folder. The sync helper moves finished sessions from here into loro.',
    },
    {
      key: 'suppressDownloadUi',
      type: 'boolean',
      label: 'Hide Chrome download bubble',
      help: 'Keeps session writes off-screen. Side effect: while RichOS holds this, ALL Chrome downloads are silent.',
    },
    {
      key: 'notifyOnStartStop',
      type: 'boolean',
      label: 'Desktop notification when capture starts and stops',
      help: 'Off by default. The toolbar icon already shows status at a glance: grey = idle, green = capturing, red = problem.',
    },
    {
      key: 'notifyOnFailure',
      type: 'boolean',
      label: 'Desktop alert when capture fails',
      help: 'On by default, and independent of the setting above — this is how you learn about a stall during the call. Only ever fired for failures, only to you. Note: an OS notification is visible if you are screen-sharing your whole desktop; the red badge alone is not.',
    },
    {
      key: 'alertSound',
      type: 'boolean',
      label: 'Audible alarm when capture fails',
      help: 'Off by default — your microphone would pick the chime up mid-call.',
    },
    {
      key: 'retentionDays',
      type: 'number',
      label: 'Audio retention (days)',
      min: 1,
      max: 3650,
      help: 'Advisory: consumed by the sync helper, not by the browser.',
    },
  ],
};

/** Message envelope targets, so core and modules never fight over `chrome.runtime` messages. */
export const TARGET = {
  serviceWorker: 'sw',
  offscreen: 'offscreen',
  ui: 'ui',
};

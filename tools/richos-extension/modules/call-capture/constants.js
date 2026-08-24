/**
 * RichOS — call-capture module constants.
 *
 * Pure module (no `chrome.*`): imported by the service worker, the offscreen recorder,
 * the popup, the options page and the node test harness.
 */

export const MODULE_ID = 'callCapture';

/** Module defaults. Biased to "capture too much, announce nothing". */
export const CAPTURE_DEFAULTS = {
  /** Master switch for this module. */
  enabled: true,
  /**
   * 'auto'   — try to arm the moment a call tab is recognised, and escalate loudly if
   *            Chrome refuses without an extension invocation (see README §Arming).
   * 'manual' — only ever arm on the toolbar click or the keyboard shortcut.
   */
  armMode: 'auto',
  /**
   * Hybrid auto-start: the moment a call tab is recognised, start MICROPHONE + CAPTION capture
   * with ZERO user gesture, so a detected call is never fully uncaptured. Only tab-audio (the
   * ground-truth channel) still needs the one invocation/click. On = the click merely UPGRADES
   * an already-running mic+captions session to full tab audio.
   */
  autoStartMicCaptions: true,
  /** Collect the platform's own live captions as a secondary failsafe + enrichment channel. */
  captureCaptions: true,
  /** Also treat ANY audible tab as a call (noisy: video sites count as audible). */
  armUnknownAudible: false,
  /** How long a recognised call URL must stay open before auto-arming. */
  armDelayMs: 3000,
  /** Record the microphone (you) on its own channel — left = you, right = everyone else. */
  captureMic: true,
  /** Browser mic DSP (echo cancellation / noise suppression / AGC). On = cleaner separation. */
  micProcessing: true,
  /** MediaRecorder timeslice: the upper bound on audio a hard crash can destroy. */
  chunkMs: 3000,
  /** Opus bitrate for the 2-channel stream (~43 MB per hour at 96 kbps). */
  audioBitsPerSecond: 96000,
  /**
   * Participant-facing disclosure banner. OFF by default (the CEO's own use).
   * Kept because RichOS customers operate in two-party-consent jurisdictions.
   */
  disclosureBanner: false,
  disclosureText: 'This call is being recorded locally for transcription.',
  /** Hard cap on one session. */
  maxSessionMinutes: 240,
  /** Keep IndexedDB chunks after a successful export (extra safety, extra disk). */
  keepChunksAfterExport: false,
};

/** @type {{title: string, fields: import('../../core/constants.js').SettingField[]}} */
export const SETTINGS_SCHEMA = {
  title: 'Call capture',
  fields: [
    { key: 'enabled', type: 'boolean', label: 'Call capture enabled', help: 'Master switch. Off = nothing is ever recorded.' },
    {
      key: 'armMode',
      type: 'select',
      label: 'Arming',
      options: [
        { value: 'auto', label: 'Automatic — arm as soon as a call tab is detected' },
        { value: 'manual', label: 'Manual — only on click / keyboard shortcut' },
      ],
      help: 'Chrome requires one extension invocation per tab before it will hand over tab audio. Automatic mode tries first and alarms loudly if it needs your click.',
    },
    {
      key: 'autoStartMicCaptions',
      type: 'boolean',
      label: 'Auto-start microphone + captions with no click',
      help: 'The moment a call tab is detected, start recording your microphone and collecting captions with zero gesture. Only tab audio (the ground-truth channel) still needs one click; that click then upgrades the running session to full tab audio. A detected call is never fully uncaptured.',
    },
    {
      key: 'captureCaptions',
      type: 'boolean',
      label: 'Collect platform captions (secondary channel)',
      help: 'Read the meeting platform\'s own live captions as a failsafe + enrichment layer (per-speaker names, accuracy cross-check). Secondary to audio: if it breaks you lose enrichment, never the call.',
    },
    { key: 'armUnknownAudible', type: 'boolean', label: 'Also arm on unrecognised audible tabs', help: 'Catches call platforms we do not know yet. Will also catch video sites.' },
    { key: 'captureMic', type: 'boolean', label: 'Record microphone on its own channel', help: 'Left channel = you, right channel = everyone else. Free speaker separation.' },
    { key: 'micProcessing', type: 'boolean', label: 'Microphone echo cancellation / noise suppression' },
    { key: 'chunkMs', type: 'number', label: 'Chunk size (ms)', min: 1000, max: 15000, help: 'Maximum audio a hard crash can destroy. Smaller = safer, slightly more disk churn.' },
    { key: 'audioBitsPerSecond', type: 'number', label: 'Audio bitrate (bps)', min: 32000, max: 256000 },
    { key: 'maxSessionMinutes', type: 'number', label: 'Maximum session length (minutes)', min: 5, max: 1440 },
    { key: 'disclosureBanner', type: 'boolean', label: 'Show a recording disclosure to participants', help: 'OFF by default. Turn on where all-party consent is required; it injects a small banner into the call tab and needs page access.' },
    { key: 'disclosureText', type: 'text', label: 'Disclosure text' },
    { key: 'keepChunksAfterExport', type: 'boolean', label: 'Keep raw chunks in the browser after export', help: 'Belt and braces. Costs disk inside Chrome.' },
  ],
};

/**
 * Health thresholds. Every number is a latency budget the CEO can hold the tool to.
 */
export const THRESHOLDS = {
  /** Grace period after arming before "no audio at all" becomes fatal. */
  warmupMs: 20000,
  /** Audio chunks arriving from MediaRecorder. */
  chunkAmberMs: 7000,
  chunkRedMs: 15000,
  /** Heartbeat from the offscreen recorder to the service worker. */
  heartbeatAmberMs: 7000,
  heartbeatRedMs: 15000,
  /** Exact-zero RMS on a channel while the session is live = the device/stream is gone. */
  digitalSilenceRedMs: 20000,
  /** Nothing above the speech floor on BOTH channels. Legitimate (nobody talking) => amber. */
  quietAmberMs: 120000,
  /**
   * RMS at or below this is treated as digital silence (a dead stream), not a quiet room.
   * Measured on Chrome's fake capture device with the browser's DSP enabled: ~3e-5, so the
   * threshold sits an order of magnitude below that to avoid crying wolf on a heavily
   * noise-suppressed but perfectly live microphone.
   */
  rmsZeroEpsilon: 0.000001,
  /** RMS above this counts as "someone spoke". */
  rmsSpeechFloor: 0.005,
  /** Heartbeat period emitted by the offscreen recorder. */
  heartbeatMs: 1000,
  /** Recovery attempts per failing signal before we stop retrying and just stay loud. */
  recoverMaxAttempts: 5,
  /** Minimum spacing between two recovery attempts for the same signal. */
  recoverBackoffMs: 5000,
  /** An unarmed, recognised call tab is an alarm this fast. */
  unarmedAlarmMs: 10000,
  /**
   * Captions-only mode (`mode: 'captions-only'`, no audio source exists at all): grace period
   * after arming before "not one caption has landed either" becomes a hard (red) failure.
   * Reuses the same shape as `warmupMs` but is named separately so the two can diverge later.
   */
  captionsWarmupMs: 20000,
  /**
   * Captions-only mode: age of the last landed caption before the channel is treated as having
   * ALSO gone silent (red — the CEO-decision 2026-08-23 boundary between "degraded but working"
   * and "true failure: nothing is being captured"). Generous enough to survive a natural pause
   * in conversation, short enough to catch an adapter that quietly died.
   */
  captionsStallRedMs: 45000,
};

/** Recovery actions the (pure) health evaluator asks the controller to perform. */
export const ACTIONS = {
  restartRecorder: 'restart-recorder',
  reattachTab: 'reattach-tab',
  reacquireMic: 'reacquire-mic',
  recreateOffscreen: 'recreate-offscreen',
};

/**
 * Session lifecycle. `open` on disk with no audio is the loud anomaly that makes a
 * lost call *present* instead of absent.
 */
export const SESSION_STATUS = {
  open: 'open',
  closed: 'closed',
  interrupted: 'interrupted',
  recovered: 'recovered',
};

/**
 * Filenames inside one session directory in the drop zone.
 * NB: the health file is JSONL, but it is named `.ndjson` because Chrome's downloads API
 * rewrites the extension to match the MIME type — verified on a live run, where a
 * `health.jsonl` write landed as `health.ndjson`.
 */
export const FILES = {
  session: 'session.json',
  health: 'health.ndjson',
  /** The secondary caption channel: one JSON record per caption revision. */
  captions: 'captions.ndjson',
  audioPart: (part) => `audio-part-${String(part).padStart(2, '0')}.webm`,
};

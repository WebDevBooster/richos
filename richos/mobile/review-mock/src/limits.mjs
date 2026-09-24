// THE MAC'S NUMBERS, restated for the review host. Every value here is read from the Mac's own
// Rust source and names the constant it came from, so a reviewer's phone meets exactly the limits
// a real Mac would put in front of it. `test/conformance.test.mjs` holds these against the
// conformance corpus (`mobile/conformance/vectors/*.json`), which the Mac's verifier in turn
// holds against the production code. A drift on the Mac fails there, not in review.

/** `phone/mod.rs` MAX_BODY_BYTES: the largest JSON body the Mac reads. */
export const MAX_BODY_BYTES = 65536;
/** `phone/voice.rs` MAX_UPLOAD: the largest voice note body. */
export const MAX_VOICE_BYTES = 60_000_000;
/** `phone/voice.rs` MAX_SECONDS: thirty minutes of 16 kHz audio. */
export const MAX_VOICE_SECONDS = 30 * 60;
/** `phone/voice.rs` MAX_REPLY: the largest spoken reply the Mac serves. */
export const MAX_REPLY_AUDIO_BYTES = 6_000_000;
/** `phone/device.rs` CHALLENGE_LIFETIME_MS. */
export const CHALLENGE_LIFETIME_MS = 600_000;
/** `phone/device.rs` LIVE_CHALLENGES. */
export const LIVE_CHALLENGES = 256;
/** `phone/device.rs` issue_challenge: a newer challenge is minted at most every 30 seconds. */
export const CHALLENGE_REUSE_MS = 30_000;
/** `phone/device.rs` RATE_WINDOW_MS and RATE_LIMIT: 60 requests a rolling minute per bucket. */
export const RATE_WINDOW_MS = 60_000;
export const RATE_LIMIT = 60;
/** `phone/device.rs` MAX_STREAMS: concurrent event streams. */
export const MAX_STREAMS = 4;
/** `phone/device.rs` revoked ids kept for a final answer. */
export const REVOKED_MEMORY = 8;
/** `phone/mod.rs` PAIRING_WINDOW_MS: how long a pairing code can be redeemed. */
export const PAIRING_WINDOW_MS = 300_000;
/** `phone/device.rs` CODE_ALPHABET and CODE_LENGTH. */
export const CODE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTVWXYZ';
export const CODE_LENGTH = 8;
/** `phone/mod.rs` KEEPALIVE_MS: the stream's keep-alive comment interval. */
export const KEEPALIVE_MS = 15_000;
/** `phone/delivery.rs` MAX_RECEIPTS and RETENTION_MS. */
export const MAX_RECEIPTS = 4096;
export const RECEIPT_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
/** `phone/routes.rs` PROTOCOL_VERSION. */
export const PROTOCOL_VERSION = 1;
/** `phone/stream.rs` REPLAY_MEMORY: frames kept for a reconnecting stream. */
export const REPLAY_MEMORY = 512;

/** `phone/attachments.rs`. */
export const MAX_FILE_BYTES = 25 * 1024 * 1024;
export const MAX_FILES_PER_MESSAGE = 10;
export const MAX_MESSAGE_BYTES = 100 * 1024 * 1024;
export const MAX_STAGED_BYTES = 200 * 1024 * 1024;
export const STAGING_TTL_MS = 7 * 24 * 60 * 60 * 1000;
export const EVICTION_GRACE_MS = 15 * 60 * 1000;
export const UPLOAD_SECONDS = 300;
export const MAX_RAW_NAME_BYTES = 1024;

/** `phone/notifications.rs`: the apps whose push tokens a Mac forwards. */
export const APNS_TOPICS = ['dev.richos.mobile.loop', 'dev.richos.mobile.integration', 'dev.richos.native.ios', 'dev.richos.connect'];
export const FCM_APPS = ['dev.richos.native.android', 'dev.richos.connect'];
/** `phone/notifications.rs` Desk: pending jobs expire after an hour; at most 100 are held. */
export const PUSH_JOB_LIFETIME_MS = 3_600_000;
export const PUSH_JOB_LIMIT = 100;
export const PUSH_DELIVERED_MEMORY = 1000;

// ---- review-host bounds (not Mac constants; the Mac's disk is not a shared cloud object) -----

/** Rows kept per conversation. The oldest reviewer rows go first; the sample rows are rebuilt on reset. */
export const MAX_ROWS_PER_THREAD = 400;
/** The version string a review host reports in `build`. Not a RichOS release. */
export const BUILD = 'review-demo';

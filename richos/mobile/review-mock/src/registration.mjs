// THE NATIVE PUSH REGISTRATION the phone sends inside `{"native_push": …}` — `phone/notifications.rs`
// Registration, parsed with `deny_unknown_fields` and checked with `validate()`. The whole
// `vectors/push-registration-fcm.json` registration table is replayed against `parseRegistration`.

import { unb64url } from './codec.mjs';
import { APNS_TOPICS, FCM_APPS } from './limits.mjs';

const KEYS = ['platform', 'token', 'environment', 'topic', 'preview_key', 'previews'];
const FCM_TOKEN = /^[A-Za-z0-9_:-]{32,4096}$/;

/**
 * Parse `value` (the `native_push` field). Returns `{ ok: true, registration }` where
 * `registration` is null for an unregistration, or `{ ok: false }` for anything the Mac refuses
 * (the route answers those with a flat 404).
 */
export function parseRegistration(value) {
	if (value === null) return { ok: true, registration: null };
	if (!value || typeof value !== 'object' || Array.isArray(value)) return { ok: false };
	if (Object.keys(value).some((k) => !KEYS.includes(k))) return { ok: false };
	const { platform, token, topic } = value;
	const environment = value.environment === undefined ? '' : value.environment;
	const previewKey = value.preview_key === undefined ? null : value.preview_key;
	const previews = value.previews === undefined ? true : value.previews;
	if (platform !== undefined && platform !== null && typeof platform !== 'string') return { ok: false };
	if (typeof token !== 'string' || typeof topic !== 'string' || typeof environment !== 'string') return { ok: false };
	if (previewKey !== null && typeof previewKey !== 'string') return { ok: false };
	if (typeof previews !== 'boolean') return { ok: false };
	let previewOk = true;
	if (previewKey !== null) {
		try { previewOk = unb64url(previewKey).length === 32; } catch { previewOk = false; }
	}
	let valid;
	if (platform === undefined || platform === null || platform === 'apns') {
		valid = previewOk && token.length >= 32 && token.length <= 512 && /^[0-9a-f]+$/.test(token)
			&& ['sandbox', 'production'].includes(environment) && APNS_TOPICS.includes(topic);
	} else if (platform === 'fcm') {
		valid = previewOk && FCM_TOKEN.test(token) && environment === '' && FCM_APPS.includes(topic);
	} else {
		valid = false;
	}
	if (!valid) return { ok: false };
	// `normalized`: an explicit "apns" and the preserved app's registration are one record.
	const transport = platform === 'fcm' ? 'fcm' : 'apns';
	return { ok: true, registration: { transport, token, environment, topic, preview_key: previewKey, previews } };
}

/**
 * `notifications.rs` device_body: the `PUT /v1/push/device` body the Connect Worker receives.
 * The review host is never reached through a Connect tunnel, so its route is always `tailnet`
 * (the Worker's name for "a host that is not the Connect tunnel"; it skips the tunnel checks).
 */
export function deviceBody(revision, generation, target) {
	if (!target) return { revision, generation, deviceHash: null, token: null, route: 'tailnet' };
	const r = target.registration;
	if (r.transport === 'fcm') {
		return { revision, generation, deviceHash: target.hash, token: r.token, platform: 'fcm', topic: r.topic, route: 'tailnet' };
	}
	return { revision, generation, deviceHash: target.hash, token: r.token, environment: r.environment, topic: r.topic, route: 'tailnet' };
}

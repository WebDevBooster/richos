// REAL PUSH, THROUGH THE REAL SERVICE.
//
// A Mac never talks to Apple or Google. It signs control requests to the RichOS Connect Worker
// (`mobile/service/connect-worker.mjs`), which holds the APNs keys and the FCM service account and
// delivers. The review host does exactly the same, as a push-only host (`POST /v1/push/hosts`): each
// virtual host has its own P-256 host identity, and a reply becomes a `POST /v1/push/events` with
// opaque SHA-256 references and, when the phone asked for previews, an AES-GCM envelope only the
// phone can open. So the notification a reviewer receives travels the production path end to end.
//
// Ports of `phone/connect/client.rs` (the signed control request) and `phone/notifications.rs`
// (Desk: registration intent, job queue, reconcile; `seal_preview`).

import { b64url, bytesOf, hex, randomBytes, sha256, sha256hex, unb64url } from './codec.mjs';
import { deviceBody } from './registration.mjs';
import { PUSH_DELIVERED_MEMORY, PUSH_JOB_LIFETIME_MS, PUSH_JOB_LIMIT } from './limits.mjs';

/** The sentence the phone shows when the service cannot be reached (`notifications.rs` unavailable). */
export const UNAVAILABLE = 'Reply notifications could not reach the service. Your conversation still works. Retry notifications in settings.';

const ROUTES = new Set(['POST /v1/push/hosts', 'PUT /v1/push/device', 'POST /v1/push/events']);

/**
 * A host identity from a PKCS#8 private key (base64url), as `bin/review-secrets.mjs` writes it.
 * @returns {Promise<{id: string, publicKey: string, sign: (text: string) => Promise<Uint8Array>}>}
 */
export async function hostIdentity(pkcs8B64url) {
	const privateKey = await crypto.subtle.importKey('pkcs8', unb64url(pkcs8B64url), { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign']);
	const jwk = await crypto.subtle.exportKey('jwk', privateKey);
	const point = new Uint8Array(65);
	point[0] = 4; point.set(unb64url(jwk.x), 1); point.set(unb64url(jwk.y), 33);
	return {
		id: hex(await sha256(point)).slice(0, 32),
		publicKey: b64url(point),
		async sign(text) {
			return new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, bytesOf(text)));
		}
	};
}

/**
 * `connect/client.rs` Client::call: a signed control request to the Connect Worker.
 * `fetchImpl` is injected so the tests can put the real Worker handler behind it.
 */
export function connectClient({ origin, identity, fetchImpl = fetch, now = Date.now }) {
	return {
		async call(method, path, body) {
			if (!ROUTES.has(`${method} ${path}`)) throw new Error('Unknown Connect action');
			const time = String(now());
			const nonce = hex(randomBytes(16));
			const canonical = `RICHOS-CONNECT-V1\n${time}\n${nonce}\n${method}\n${path}\n${await sha256hex(body)}`;
			const signature = b64url(await identity.sign(canonical));
			let response;
			try {
				response = await fetchImpl(new Request(origin + path, {
					method,
					headers: { 'content-type': 'application/json', 'x-richos-key': identity.publicKey, 'x-richos-time': time, 'x-richos-nonce': nonce, 'x-richos-signature': signature },
					body
				}));
			} catch {
				throw new Error(UNAVAILABLE);
			}
			let value = null;
			try { value = await response.json(); } catch { value = null; }
			return { status: response.status, value };
		}
	};
}

/**
 * `notifications.rs` seal_preview: whitespace-normalized, at most 240 characters, AES-256-GCM
 * under the phone's preview key, bound to the version and the two opaque references.
 */
export async function sealPreview(keyB64url, threadRef, eventRef, text) {
	const key = await crypto.subtle.importKey('raw', unb64url(keyB64url), { name: 'AES-GCM' }, false, ['encrypt']);
	const nonce = randomBytes(12);
	const body = Array.from(String(text).split(/\s+/).filter(Boolean).join(' ')).slice(0, 240).join('');
	const sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: bytesOf(`richos-preview-v1\n${threadRef}\n${eventRef}`) }, key, bytesOf(body));
	return { v: 1, nonce: b64url(nonce), body: b64url(new Uint8Array(sealed)) };
}

/** An empty desk (`notifications.rs` State::default). */
export function emptyDesk() {
	return { revision: 0, target: null, dirty: false, host: null, generation: 0, jobs: [], delivered: [] };
}

const bump = (desk, now) => { desk.revision = Math.max(desk.revision + 1, now); };

/**
 * `notifications.rs` Desk, over a plain object the caller persists. Every method mutates `desk`
 * and the caller writes it back; nothing here touches storage.
 */
export const Desk = {
	/** `Desk::set`: record a registration (or its removal) for the paired device. */
	async set(desk, device, registration, now) {
		bump(desk, now);
		desk.target = registration ? { device: device.id, hash: await sha256hex(unb64url(device.public_key)), registration, route: 'tailnet' } : null;
		desk.dirty = true;
		desk.jobs = [];
		desk.delivered = [];
	},

	/** `Desk::clear`: the phone is gone; unregister at the next reconcile. */
	clear(desk, now) {
		if (!desk.target && !desk.jobs.length) return false;
		bump(desk, now);
		desk.target = null;
		desk.jobs = [];
		desk.dirty = true;
		return true;
	},

	enabledFor(desk, device) {
		return Boolean(desk.target && device && desk.target.device === device.id);
	},

	/** `Desk::enqueue` plus `queue_reply`'s preview sealing: one job per reply event. */
	async enqueue(desk, device, threadId, eventId, text, now) {
		if (!Desk.enabledFor(desk, device)) return false;
		const event = await sha256hex(eventId);
		if (desk.delivered.includes(event) || desk.jobs.some((j) => j.event === event)) return false;
		desk.jobs = desk.jobs.filter((j) => j.expires > now);
		if (desk.jobs.length >= PUSH_JOB_LIMIT) throw new Error(UNAVAILABLE);
		const thread = await sha256hex(threadId);
		const r = desk.target.registration;
		const preview = r.previews && r.preview_key ? await sealPreview(r.preview_key, thread, event, text) : null;
		desk.jobs.push({ event, thread, expires: now + PUSH_JOB_LIFETIME_MS, preview });
		return true;
	},

	needsReconcile(desk, device) {
		return desk.dirty || desk.jobs.length > 0 || Boolean(desk.target && !(device && device.id === desk.target.device && device.fingerprint_confirmed));
	},

	/**
	 * `Desk::reconcile`: enroll (idempotent), register when dirty, then deliver queued jobs in
	 * order. Throws UNAVAILABLE on any failure; everything done so far is kept in `desk`.
	 */
	async reconcile(desk, control, device, now) {
		if (desk.target && !(device && device.id === desk.target.device && device.fingerprint_confirmed)) Desk.clear(desk, now);
		desk.jobs = desk.jobs.filter((j) => j.expires > now);
		if (!desk.dirty && !desk.jobs.length) return;
		const enrollment = await control.call('POST', '/v1/push/hosts', '{}');
		const host = enrollment.value && enrollment.value.hostId;
		const generation = enrollment.value && enrollment.value.generation;
		if (enrollment.status !== 200 || typeof host !== 'string' || !/^[0-9a-f]{32}$/.test(host) || !Number.isSafeInteger(generation) || generation < 1) {
			throw new Error(UNAVAILABLE);
		}
		if (desk.generation !== generation) { desk.dirty = true; bump(desk, now); }
		desk.host = host;
		desk.generation = generation;
		if (desk.dirty) {
			const result = await control.call('PUT', '/v1/push/device', JSON.stringify(deviceBody(desk.revision, generation, desk.target)));
			if (result.status !== 200) throw new Error(UNAVAILABLE);
			desk.dirty = false;
		}
		while (desk.target && desk.jobs.length) {
			const job = desk.jobs[0];
			const result = await control.call('POST', '/v1/push/events', JSON.stringify({ deviceHash: desk.target.hash, revision: desk.revision, eventRef: job.event, threadRef: job.thread, preview: job.preview }));
			if (result.status === 409) { desk.dirty = true; bump(desk, now); throw new Error(UNAVAILABLE); }
			if (result.status !== 202) throw new Error(UNAVAILABLE);
			desk.delivered.push(job.event);
			if (desk.delivered.length > PUSH_DELIVERED_MEMORY) desk.delivered.shift();
			desk.jobs.shift();
		}
	},

	/** `Desk::response`: what the phone is told after a registration. */
	response(desk) {
		return { host_id: desk.host, registered: Boolean(desk.target) && !desk.dirty };
	}
};

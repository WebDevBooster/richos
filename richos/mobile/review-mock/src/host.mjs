// ONE REVIEW HOST: everything a Mac holds for one paired phone, and nothing else.
//
// In production this object lives inside one Cloudflare Durable Object per virtual host
// (`worker.mjs` ReviewHost), keyed by the host's own HTTPS name. That is the isolation: a second
// reviewer on another virtual host talks to a different object with different storage, so an Apple
// review and a Google review can never replace each other's pairing, conversation or push
// registration. Within one host, the Mac's single-phone semantics hold exactly (one paired phone;
// a new pairing needs the old one forgotten first, which the access page does only when asked).
//
// Every rule below restates a Mac rule and names it. The ports (`storage`, `now`, `schedule`,
// `sleep`, `push`) are injected so the unit tests drive the same code the Worker runs.
//
// Storage keys, all in this host's own Durable Object:
//   meta                 { cursor, currentThread, initializedAt, receiptCount }
//   device               the paired phone, or absent
//   revoked              device ids forgotten here (at most 8), for the final 403
//   pairing              { code, openedAt } while a pairing link is open
//   spent                { codeHash, until } after a code is redeemed, for the spent-code alarm
//   notice               the last thing the access page must tell the reviewer
//   challenges           [[challenge, issuedAt], …] (at most 256)
//   rows:<thread>        that conversation's rows, oldest first
//   receipt:<hash>       { hash, answer, at } per (device, client_id)
//   staging:<device>     { [client_id]: { at, files: { [id]: meta } } }  metadata only, never bytes
//   desk                 the native push desk (`push.mjs` Desk)
//   pending              simulated replies waiting to be written

import { b64url, hex, iso8601, randomBytes, sameString, sha256, sha256hex } from './codec.mjs';
import {
	ATTACHMENT_LIMITS_WIRE, CAPABILITIES_BASE
} from './wire.mjs';
import {
	CHALLENGE_LIFETIME_MS, CHALLENGE_REUSE_MS, CODE_ALPHABET, CODE_LENGTH, EVICTION_GRACE_MS, KEEPALIVE_MS,
	LIVE_CHALLENGES, MAX_FILE_BYTES, MAX_FILES_PER_MESSAGE, MAX_MESSAGE_BYTES, MAX_RECEIPTS, MAX_ROWS_PER_THREAD,
	MAX_STAGED_BYTES, MAX_STREAMS, PAIRING_WINDOW_MS, PROTOCOL_VERSION, RATE_LIMIT, RATE_WINDOW_MS,
	RECEIPT_RETENTION_MS, REPLAY_MEMORY, REVOKED_MEMORY, STAGING_TTL_MS, BUILD
} from './limits.mjs';
import { signingString, verifySignature, deviceIdOf, importPoint, publicPointOf } from './signing.mjs';
import { contentMatches, describe, kindOf, sanitizeName, uniqueNames, validId } from './attachments.mjs';
import { parseRegistration } from './registration.mjs';
import { THREADS, sampleRows, replyFor, chunks, voiceRowText } from './script.mjs';
import { Desk, emptyDesk, UNAVAILABLE } from './push.mjs';
import { chime } from './wav.mjs';
import { sixWords } from './qr.mjs';

/** A cap on staged messages per phone. The Mac's cap is its disk; the review host's is this. */
export const MAX_STAGED_MESSAGES = 200;
/**
 * How long after an accepted message its demo reply starts streaming. Long enough for a reviewer
 * to close the app and receive the reply as a notification, short enough to feel like a reply.
 */
export const REPLY_DELAY_MS = 4000;
/** The pause between streamed pieces of a demo reply. */
export const DELTA_PAUSE_MS = 250;
/** When a push delivery failed, the next attempt. Jobs still expire after an hour. */
export const PUSH_RETRY_MS = 5 * 60_000;

const encoder = new TextEncoder();

/** The six-word fingerprint source for a host: a stable, public, per-host value. */
export async function fingerprintOf(hostname) {
	return hex(await sha256(`RichConnect review host\n${hostname}`)).toUpperCase().match(/../g).join(':');
}

function platformOfName(name) {
	const lower = String(name).toLowerCase();
	if (lower.includes('iphone') || lower.includes('ipad') || lower.includes('ipod')) return 'ios';
	if (lower.includes('android')) return 'android';
	return 'other';
}

/** `device.rs` sanitize_name: at most 40 characters, no control characters, "Phone" if empty. */
function deviceName(raw) {
	const cleaned = Array.from(String(raw)).filter((c) => !/\p{Cc}/u.test(c)).slice(0, 40).join('').trim();
	return cleaned || 'Phone';
}

function admit(bucket, now) {
	while (bucket.length && now - bucket[0] > RATE_WINDOW_MS) bucket.shift();
	if (bucket.length >= RATE_LIMIT) return false;
	bucket.push(now);
	return true;
}

const json = (status, body) => ({ type: 'json', status, body: JSON.stringify(body) });
const NOT_FOUND = { type: 'notFound' };
const REVOKED = { type: 'revoked' };
const RATE_LIMITED = { type: 'rateLimited' };
/**
 * Sage's v2 pairing contract, F1 (richos-hq `docs/research/2026-09-24-richconnect-pairing-protocol-review.md`
 * section 3): an authenticated device the person has not confirmed ON THE MAC gets this distinct,
 * retryable answer and nothing else. No `retry:false`, so every existing classifier reads it as a
 * temporary fault and waits rather than giving up. On a review host, the access page is the Mac.
 */
export const AWAITING = { type: 'json', status: 409, body: JSON.stringify({ awaiting_mac_confirmation: true, reason: 'Press They match on your Mac.' }) };

/**
 * Sage's F2 derivation (section 1, F2 "Fix"): the words bind the origin the phone dialed, the
 * Mac's value and the phone's key. `pairingVersion` 1 keeps today's rule (the words of the
 * fingerprint alone), which is what the conformance corpus and the shipped apps use until the v2
 * vectors exist.
 */
export async function pairingWords(version, origin, macValue, devicePointB64url) {
	if (version === 2) return sixWords(await sha256hex(`RICHCONNECT-PAIR-V2\n${origin}\n${macValue}\n${devicePointB64url}`));
	return sixWords(macValue);
}

export class Host {
	/**
	 * @param {object} ports
	 * @param {{get:Function,put:Function,delete:Function,list:Function}} ports.storage Durable Object storage or the test double
	 * @param {string} ports.hostname this host's HTTPS name; its origin is the paired origin
	 * @param {() => number} [ports.now]
	 * @param {(at: number) => Promise<void>|void} [ports.schedule] wake `alarm()` at this time
	 * @param {(ms: number) => Promise<void>} [ports.sleep]
	 * @param {null|{control: {call: Function}}} [ports.push] the Connect client, or null when push is not configured
	 * @param {1|2} [ports.pairingVersion] which six-word rule the phone uses (see `pairingWords`)
	 */
	constructor({ storage, hostname, now = Date.now, schedule = () => {}, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), push = null, pairingVersion = 1 }) {
		this.storage = storage;
		this.hostname = hostname;
		this.origin = `https://${hostname}`;
		this.now = now;
		this.schedule = schedule;
		this.sleep = sleep;
		this.push = push;
		this.pairingVersion = pairingVersion === 2 ? 2 : 1;
		this.loaded = null;
		// In memory only, as on the Mac: a restart empties them (`device.rs` RATE_LIMIT).
		this.deviceRequests = [];
		this.strangerRequests = [];
		this.pairingRequests = [];
		this.streams = new Set();
		this.recent = [];
	}

	// ---- state ---------------------------------------------------------------------------------

	async load() {
		if (!this.loaded) this.loaded = this.initialize();
		return this.loaded;
	}

	async initialize() {
		let meta = await this.storage.get('meta');
		if (!meta) meta = await this.seed();
		this.meta = meta;
		this.device = (await this.storage.get('device')) || null;
		this.revoked = (await this.storage.get('revoked')) || [];
		this.pairing = (await this.storage.get('pairing')) || null;
		this.spent = (await this.storage.get('spent')) || null;
		this.notice = (await this.storage.get('notice')) || null;
		this.challenges = (await this.storage.get('challenges')) || [];
		this.desk = (await this.storage.get('desk')) || emptyDesk();
		this.pending = (await this.storage.get('pending')) || [];
		this.fingerprint = await fingerprintOf(this.hostname);
	}

	/** The sample conversations. Also what an explicit reset returns to. */
	async seed(baseCursor = 0) {
		const now = this.now();
		const rows = sampleRows(now, { push: Boolean(this.push) });
		// Cursors only ever rise, across a reset too: a phone that cached rows before the reset
		// can never mistake a new row for one it already holds.
		let cursor = baseCursor;
		for (const row of rows) row.cursor = ++cursor;
		for (const thread of THREADS) await this.storage.put(`rows:${thread.id}`, rows.filter((r) => r.thread_id === thread.id));
		const meta = { cursor, currentThread: THREADS[0].id, initializedAt: now, receiptCount: 0 };
		await this.storage.put('meta', meta);
		return meta;
	}

	async saveMeta() { await this.storage.put('meta', this.meta); }

	async rows(threadId) { return (await this.storage.get(`rows:${threadId}`)) || []; }

	threadExists(threadId) { return THREADS.some((t) => t.id === threadId); }

	capabilities() {
		const push = Boolean(this.push);
		// `routes.rs` capabilities(voice=true, native_push): the Mac's order, additions appended.
		return [...CAPABILITIES_BASE, 'voice', 'audio', ...(push ? ['native-push'] : []), 'attachments', ...(push ? ['native-push-fcm'] : []),
			// Sage section 3.5: v2 is announced by capability, never by protocol_version.
			...(this.pairingVersion === 2 ? ['pair-v2'] : [])];
	}

	// ---- challenges (`device.rs` issue_challenge) ----------------------------------------------

	/** Mint or reuse a challenge. Called for every response, as the Mac's `render` does. */
	async issueChallenge() {
		await this.load();
		const now = this.now();
		const before = this.challenges.length;
		while (this.challenges.length && now - this.challenges[0][1] > CHALLENGE_LIFETIME_MS) this.challenges.shift();
		const last = this.challenges[this.challenges.length - 1];
		if (last && now - last[1] < CHALLENGE_REUSE_MS) {
			if (this.challenges.length !== before) await this.storage.put('challenges', this.challenges);
			return last[0];
		}
		const challenge = b64url(randomBytes(24));
		this.challenges.push([challenge, now]);
		while (this.challenges.length > LIVE_CHALLENGES) this.challenges.shift();
		// Persisted, unlike on the Mac: a Durable Object is evicted after a short idle, and a phone
		// holding a ten-minute challenge should not pay a re-sign after every quiet minute.
		await this.storage.put('challenges', this.challenges);
		return challenge;
	}

	/** Test hook: make a challenge live, as `verifier/tests/corpus.rs` issues the corpus's own. */
	async acceptChallengeForTest(challenge) {
		await this.load();
		this.challenges.push([challenge, this.now()]);
		await this.storage.put('challenges', this.challenges);
	}

	// ---- the credential (`device.rs` verify) ---------------------------------------------------

	/**
	 * @returns {Promise<{device: object}|{refusal: object}>} the paired device, or the outcome to answer
	 */
	async verify({ method, pathWithQuery, deviceId, challenge, signature, bodyHashHex }) {
		await this.load();
		const now = this.now();
		await this.expireUnconfirmed(now);
		if (this.revoked.includes(deviceId)) return { refusal: REVOKED };
		const device = this.device;
		if (!device || !sameString(device.id, deviceId)) {
			if (!admit(this.strangerRequests, now)) return { refusal: RATE_LIMITED };
			return { refusal: NOT_FOUND };
		}
		if (!admit(this.deviceRequests, now)) return { refusal: RATE_LIMITED };
		const issued = this.challenges.find(([c]) => sameString(c, challenge));
		if (!issued || now - issued[1] > CHALLENGE_LIFETIME_MS) return { refusal: NOT_FOUND };
		const ok = await verifySignature(device.public_key, signingString(challenge, method, pathWithQuery, bodyHashHex), signature);
		if (!ok) return { refusal: NOT_FOUND };
		return { device, active: device.active === true };
	}

	/**
	 * The no-crypto half of `verify`, run before a body larger than any JSON request is read
	 * (Sage F3): the paired, ACTIVE device's id and a live challenge. Anything else is answered
	 * without reading the body. Spends no bucket; the full check still runs after the body.
	 */
	async largeBodyAllowed(deviceId, challenge) {
		await this.load();
		const now = this.now();
		await this.expireUnconfirmed(now);
		if (!this.device || this.device.active !== true || !sameString(this.device.id, deviceId)) return false;
		const issued = this.challenges.find(([c]) => sameString(c, challenge));
		return Boolean(issued) && now - issued[1] <= CHALLENGE_LIFETIME_MS;
	}

	/** Sage section 3.1 step 6: a device nobody confirmed on the Mac is forgotten when its window closes. */
	async expireUnconfirmed(now) {
		if (this.device && this.device.active !== true && now > this.device.window_ends) {
			await this.forget();
			await this.say('expired');
		}
	}

	/** Remember what the access page must tell the reviewer next time it is loaded. */
	async say(kind) {
		this.notice = { kind, at: this.now() };
		await this.storage.put('notice', this.notice);
	}

	// ---- pairing -------------------------------------------------------------------------------

	/**
	 * Open a pairing window (the access page's "Get a fresh pairing link"). Refused while a phone is
	 * paired, as `device.rs` open_pairing refuses: replacing a phone is a separate, explicit action.
	 */
	async openPairing() {
		await this.load();
		if (this.device) return { ok: false, reason: 'paired' };
		let code = '';
		for (const b of randomBytes(CODE_LENGTH)) code += CODE_ALPHABET[b % CODE_ALPHABET.length];
		this.pairing = { code, openedAt: this.now() };
		await this.storage.put('pairing', this.pairing);
		this.notice = null;
		await this.storage.delete('notice');
		return { ok: true, code, link: `${this.origin}/#pair=${code}`, expiresAt: this.pairing.openedAt + PAIRING_WINDOW_MS };
	}

	pairingOpen(now) {
		return Boolean(this.pairing) && now >= this.pairing.openedAt && now - this.pairing.openedAt <= PAIRING_WINDOW_MS;
	}

	/** `routes.rs` complete_pairing plus `device.rs` complete_pairing. */
	async completePairing(body) {
		await this.load();
		let point;
		try {
			point = publicPointOf(body);
			await importPoint(point);
		} catch {
			return NOT_FOUND;
		}
		const now = this.now();
		if (!admit(this.pairingRequests, now)) return RATE_LIMITED;
		await this.expireUnconfirmed(now);
		// Sage F1 fix 4, the spent-code alarm: the correct code a second time means two phones had it.
		if (typeof body.code === 'string' && this.spent && now <= this.spent.until && sameString(this.spent.codeHash, await sha256hex(body.code))) {
			if (this.device && this.device.active !== true) {
				await this.forget();
				await this.say('two-phones-removed');
			} else if (this.device) {
				await this.say('two-phones-kept');
			}
			return NOT_FOUND;
		}
		if (!this.pairingOpen(now)) return NOT_FOUND;
		if (typeof body.code !== 'string' || !sameString(this.pairing.code, body.code)) return NOT_FOUND;
		if (this.device) return NOT_FOUND;
		const name = typeof body.device_name === 'string' ? body.device_name : 'Phone';
		const platform = body.platform === 'ios' || body.platform === 'android' ? body.platform : platformOfName(name);
		const device = {
			id: await deviceIdOf(point),
			name: deviceName(name),
			public_key: b64url(point),
			paired_at: now,
			platform,
			fingerprint_confirmed: false,
			// Sage F1: nothing but a confirmation is answered until the person presses on the Mac.
			active: false,
			window_ends: this.pairing.openedAt + PAIRING_WINDOW_MS,
			push_transport: 'web-push',
			delivered_cursor: null
		};
		// Pairing is explicit authorization to use this key again (`device.rs`).
		if (this.revoked.includes(device.id)) {
			this.revoked = this.revoked.filter((id) => id !== device.id);
			await this.storage.put('revoked', this.revoked);
		}
		this.device = device;
		await this.storage.put('device', device);
		this.spent = { codeHash: await sha256hex(this.pairing.code), until: device.window_ends };
		await this.storage.put('spent', this.spent);
		this.pairing = null;
		await this.storage.delete('pairing');
		await this.wake(device.window_ends + 1);
		this.deviceRequests = [];
		const challenge = await this.issueChallenge();
		const current = THREADS.find((t) => t.id === this.meta.currentThread) || THREADS[0];
		return json(200, {
			device_id: device.id,
			ca_fingerprint_sha256: this.fingerprint,
			vapid_public_key: '',
			challenge,
			api_base: this.origin,
			thread_id: current.id,
			thread_title: current.title,
			threads: THREADS.map(({ id, title }) => ({ id, title })),
			protocol_version: PROTOCOL_VERSION,
			capabilities: this.capabilities(),
			attachment_limits: ATTACHMENT_LIMITS_WIRE,
			build: BUILD,
			...(this.pairingVersion === 2 ? { pairing_version: 2 } : {})
		});
	}

	/**
	 * The Mac-side press (Sage section 3.1 step 6), on the access page: "They match" activates
	 * the phone; "They do not match" is the same teardown as the phone's own rejection.
	 */
	async confirmOnMac(match) {
		await this.load();
		await this.expireUnconfirmed(this.now());
		if (!this.device || this.device.active === true) return { ok: false, reason: this.device ? 'already-active' : 'no-phone' };
		if (!match) {
			await this.forget();
			await this.say('rejected-on-mac');
			return { ok: true };
		}
		this.device = { ...this.device, active: true };
		await this.storage.put('device', this.device);
		await this.say('confirmed');
		return { ok: true };
	}

	/**
	 * Forget the paired phone: `device.rs` forget, the listener's streams closed, and the push
	 * registration removed at the Connect service. Idempotent.
	 */
	async forget() {
		await this.load();
		if (this.device) {
			this.revoked = [...this.revoked, this.device.id].slice(-REVOKED_MEMORY);
			await this.storage.put('revoked', this.revoked);
			await this.storage.delete(`staging:${this.device.id}`);
		}
		this.device = null;
		await this.storage.delete('device');
		this.pairing = null;
		await this.storage.delete('pairing');
		this.challenges = [];
		await this.storage.put('challenges', this.challenges);
		this.recent = [];
		for (const stream of [...this.streams]) stream.close();
		if (Desk.clear(this.desk, this.now())) await this.reconcilePush(null);
	}

	/** The access page's "Pair a different phone": forget, then open a fresh window. */
	async replacePhone() {
		await this.forget();
		return this.openPairing();
	}

	/**
	 * The access page's explicit reset: forget the phone and return this host, and only this host,
	 * to its sample conversations. Nothing on any other virtual host is touched.
	 */
	async reset() {
		await this.forget();
		for (const key of (await this.storage.list({ prefix: 'receipt:' })).keys()) await this.storage.delete(key);
		for (const key of (await this.storage.list({ prefix: 'staging:' })).keys()) await this.storage.delete(key);
		this.pending = [];
		await this.storage.put('pending', this.pending);
		this.spent = null;
		await this.storage.delete('spent');
		this.meta = await this.seed(this.meta.cursor);
	}

	/** What the access page shows for this host. No secrets, no conversation text. */
	async status() {
		await this.load();
		const now = this.now();
		await this.expireUnconfirmed(now);
		const open = this.pairingOpen(now);
		const d = this.device;
		return {
			hostname: this.hostname,
			pairing_version: this.pairingVersion,
			// Words only once a phone has reached the host (Sage section 3.1 steps 1 and 4).
			words: d ? await pairingWords(this.pairingVersion, this.origin, this.fingerprint, d.public_key) : null,
			paired: d ? { name: d.name, platform: d.platform, paired_at: d.paired_at, phone_confirmed: d.fingerprint_confirmed, active: d.active === true, window_ends: d.window_ends } : null,
			notice: this.notice,
			pairing: open ? { code: this.pairing.code, link: `${this.origin}/#pair=${this.pairing.code}`, expires_at: this.pairing.openedAt + PAIRING_WINDOW_MS } : null,
			push: { configured: Boolean(this.push), registered: Boolean(this.desk.target) && !this.desk.dirty, transport: this.desk.target ? this.desk.target.registration.transport : null }
		};
	}

	// ---- the device record (`routes.rs` pair_or_device_record, authenticated half) -------------

	async deviceRecord(device, body, deviceId, active = true) {
		if (!active) {
			// Sage F1: an inactive device may only answer the six words. Its own "They match" is
			// recorded (it protects the phone) and activates nothing.
			if (typeof body.fingerprint_confirmed !== 'boolean') return AWAITING;
			return this.recordConfirmation(body);
		}
		if (Object.prototype.hasOwnProperty.call(body, 'native_push')) {
			if (!this.push) return json(422, { reason: 'unsupported', retryable: false });
			const parsed = parseRegistration(body.native_push);
			if (!parsed.ok) return NOT_FOUND;
			return this.registerNativePush(deviceId, parsed.registration);
		}
		if (Object.prototype.hasOwnProperty.call(body, 'push')) {
			// The review host has no Web Push service; the native apps do not use it. A
			// subscription it could never dial is refused the way the Mac refuses one it cannot store.
			if (body.push !== null) return NOT_FOUND;
		}
		if (body.reply_receipts === true || body.seen_reply !== undefined) {
			if (body.seen_reply !== undefined) {
				const seen = body.seen_reply;
				const ok = (v) => typeof v === 'string' && v.length > 0 && v.length <= 256;
				if (!seen || !ok(seen.thread) || !ok(seen.id)) return NOT_FOUND;
			}
		}
		if (Number.isSafeInteger(body.delivered_cursor) && body.delivered_cursor >= 0) {
			this.device = { ...this.device, delivered_cursor: body.delivered_cursor };
			await this.storage.put('device', this.device);
		}
		if (typeof body.fingerprint_confirmed === 'boolean') return this.recordConfirmation(body);
		return json(200, { ok: true });
	}

	/** The phone's answer to the six words (`routes.rs` fingerprint_confirmed). */
	async recordConfirmation(body) {
		if (body.fingerprint_confirmed) {
			const transport = ['apns', 'fcm'].includes(body.push_transport) ? body.push_transport : null;
			this.device = { ...this.device, fingerprint_confirmed: true, ...(transport ? { push_transport: transport } : {}) };
			await this.storage.put('device', this.device);
		} else {
			// "They do not match": the phone is forgotten, on this host only.
			await this.forget();
			await this.say('rejected-on-phone');
		}
		return json(200, { ok: true });
	}

	/** `mod.rs` register_native_notifications. */
	async registerNativePush(deviceId, registration) {
		const device = this.device;
		if (!device || device.id !== deviceId || !device.fingerprint_confirmed || device.active !== true) {
			return json(503, { reason: 'unreachable', retryable: true, message: UNAVAILABLE });
		}
		await Desk.set(this.desk, device, registration, this.now());
		const transport = registration ? registration.transport : device.push_transport === 'fcm' ? 'fcm' : 'apns';
		this.device = { ...device, push_transport: transport };
		await this.storage.put('device', this.device);
		try {
			await this.reconcilePush(this.device, { throwOnFailure: true });
		} catch {
			return json(503, { reason: 'unreachable', retryable: true, message: UNAVAILABLE });
		}
		return json(200, Desk.response(this.desk));
	}

	/** `notifications.rs` Desk::reconcile against the Connect Worker. Saves the desk either way. */
	async reconcilePush(device, { throwOnFailure = false } = {}) {
		if (!this.push) return;
		try {
			await Desk.reconcile(this.desk, this.push.control, device, this.now());
		} catch (error) {
			await this.storage.put('desk', this.desk);
			if (this.desk.jobs.length || this.desk.dirty) await this.wake(this.now() + PUSH_RETRY_MS);
			if (throwOnFailure) throw error;
			return;
		}
		await this.storage.put('desk', this.desk);
	}

	// ---- receipts (`delivery.rs` execute_prepared) ---------------------------------------------

	async receiptKey(deviceId, clientId) {
		return 'receipt:' + (await sha256hex(`${deviceId}\n${clientId}`));
	}

	/**
	 * The durable receipt: the same client_id and bytes answer the original result; different bytes
	 * are a conflict; `prepare` failing reserves nothing. The review host writes the receipt with
	 * the answer in one step, so there is no "uncertain" gap to report.
	 */
	async execute(deviceId, clientId, bodyHashHex, prepare, submit) {
		const key = await this.receiptKey(deviceId, clientId);
		const previous = await this.storage.get(key);
		if (previous) {
			if (previous.hash !== bodyHashHex) return { kind: 'conflict' };
			return { kind: 'duplicate', answer: previous.answer };
		}
		if (this.meta.receiptCount >= MAX_RECEIPTS) {
			const now = this.now();
			for (const [k, r] of await this.storage.list({ prefix: 'receipt:' })) {
				if (now - r.at >= RECEIPT_RETENTION_MS) { await this.storage.delete(k); this.meta.receiptCount -= 1; }
			}
			if (this.meta.receiptCount >= MAX_RECEIPTS) { await this.saveMeta(); return { kind: 'full' }; }
		}
		let prepared;
		try { prepared = await prepare(); } catch (error) { return { kind: 'rejected', reason: error.message }; }
		const answer = await submit(prepared);
		await this.storage.put(key, { hash: bodyHashHex, answer, at: this.now() });
		this.meta.receiptCount += 1;
		await this.saveMeta();
		return { kind: 'accepted', answer };
	}

	// ---- the conversation ----------------------------------------------------------------------

	nextCursor() { this.meta.cursor += 1; return this.meta.cursor; }

	async appendRow(row) {
		const rows = await this.rows(row.thread_id);
		rows.push(row);
		while (rows.length > MAX_ROWS_PER_THREAD) rows.shift();
		await this.storage.put(`rows:${row.thread_id}`, rows);
	}

	async replaceRow(row) {
		const rows = await this.rows(row.thread_id);
		const at = rows.findIndex((r) => r.id === row.id);
		if (at === -1) rows.push(row); else rows[at] = row;
		while (rows.length > MAX_ROWS_PER_THREAD) rows.shift();
		await this.storage.put(`rows:${row.thread_id}`, rows);
	}

	/** Accept one CEO message: the row, the live frame, the queued demo reply. */
	async submit(threadId, clientId, fields, what) {
		const now = this.now();
		const cursor = this.nextCursor();
		this.meta.currentThread = threadId;
		const row = {
			id: `turn_${cursor}:user`, thread_id: threadId, cursor, role: 'ceo', kind: 'text', text: '',
			created_at: iso8601(now), client_id: clientId, has_audio: false, from_microphone: false,
			state: 'sent', complete: true, ...fields
		};
		await this.appendRow(row);
		await this.saveMeta();
		this.publish('message', cursor, row);
		this.pending.push({ thread: threadId, what, due: now + REPLY_DELAY_MS });
		await this.storage.put('pending', this.pending);
		await this.wake(now + REPLY_DELAY_MS);
		return { row, answer: { message_id: row.id, cursor, thread_id: threadId, accepted_at: iso8601(now) } };
	}

	async sendText(device, body, bodyHashHex) {
		const clientId = body.client_id;
		// `routes.rs`: a kind that is not a string reads as "text", as `unwrap_or("text")` does.
		if (typeof body.kind === 'string' && body.kind !== 'text') return NOT_FOUND;
		const text = typeof body.text === 'string' ? body.text.trim() : '';
		if (!text) return NOT_FOUND;
		const threadId = typeof body.thread_id === 'string' ? body.thread_id : this.meta.currentThread;
		if (!this.threadExists(threadId)) return NOT_FOUND;
		const result = await this.execute(device.id, clientId, bodyHashHex, async () => null, async () => {
			const { answer } = await this.submit(threadId, clientId, { text }, { kind: 'text', text });
			return JSON.stringify({ ...answer, duplicate: false });
		});
		return this.deliveryOutcome(result, {
			conflict: 'That message ID was already used for different text. Your draft is still on your phone.',
			full: "Your Mac's message recovery history is full. Your text is still on your phone."
		});
	}

	async sendVoice(device, { clientId, threadId, durationMs, receiptHashHex }) {
		if (!this.threadExists(threadId)) return NOT_FOUND;
		const text = voiceRowText(durationMs);
		const result = await this.execute(device.id, clientId, receiptHashHex, async () => null, async () => {
			const { answer } = await this.submit(threadId, clientId, { kind: 'voice', text, from_microphone: true, duration_ms: durationMs }, { kind: 'voice', durationMs });
			return JSON.stringify({ ...answer, text_sha256: await sha256hex(text), duration_ms: durationMs, duplicate: false });
		});
		const refuse = (status, reason) => json(status, { accepted: false, retry: false, reason });
		if (result.kind === 'accepted') return { type: 'json', status: 200, body: result.answer };
		if (result.kind === 'duplicate') return { type: 'json', status: 200, body: JSON.stringify({ ...JSON.parse(result.answer), duplicate: true }) };
		if (result.kind === 'conflict') return refuse(409, 'That recording ID already belongs to a different message. The recording remains on your phone.');
		if (result.kind === 'rejected') return refuse(422, result.reason);
		return refuse(503, "Your Mac could not save this recording's receipt. The recording remains on your phone.");
	}

	deliveryOutcome(result, sentences) {
		if (result.kind === 'accepted') return { type: 'json', status: 200, body: result.answer };
		if (result.kind === 'duplicate') return { type: 'json', status: 200, body: JSON.stringify({ ...JSON.parse(result.answer), duplicate: true }) };
		if (result.kind === 'conflict') return json(409, { retry: false, reason: sentences.conflict });
		if (result.kind === 'rejected') return json(422, { retry: false, reason: result.reason });
		return json(503, { retry: false, reason: sentences.full });
	}

	// ---- attachments (`attachments.rs` AttachmentDesk, metadata only) ---------------------------

	async stage(device, { clientId, id, name, contentType, bytes }) {
		const kind = kindOf(contentType);
		const refused = (reason) => json(422, { accepted: false, retry: false, reason });
		if (!kind) return refused("RichOS can't take this kind of file yet. Photos, PDFs, text and Office documents work. The file is still on your phone.");
		if (!bytes.length) return refused('This file is empty. Nothing was sent.');
		if (bytes.length > MAX_FILE_BYTES) return refused('This file is larger than 25 MB, the most RichOS takes from a phone. It is still on your phone.');
		if (!contentMatches(kind, bytes)) return refused(`This file does not look like a ${kind.label}. Nothing was sent; it is still on your phone.`);
		const sha = await sha256hex(bytes);
		const key = `staging:${device.id}`;
		const staging = (await this.storage.get(key)) || {};
		const now = this.now();
		const group = staging[clientId] || { at: now, files: {} };
		const answer = (meta, duplicate) => json(200, { attachment_id: meta.id, name: meta.name, media_type: meta.media_type, size: meta.size, sha256: meta.sha256, duplicate });
		const existing = group.files[id];
		if (existing) {
			return existing.sha256 === sha ? answer(existing, true) : json(409, { accepted: false, retry: false, reason: 'That file ID already belongs to a different file. The file is still on your phone.' });
		}
		const already = Object.values(group.files);
		if (already.length >= MAX_FILES_PER_MESSAGE) return refused(`A message can carry at most ${MAX_FILES_PER_MESSAGE} files.`);
		if (already.reduce((n, f) => n + f.size, 0) + bytes.length > MAX_MESSAGE_BYTES) return refused('The files in this message add up to more than 100 MB, the most RichOS takes in one message.');
		if (!this.makeRoom(staging, clientId, bytes.length, now)) return refused('Your Mac is holding too many unsent files from this phone. Send or remove some, then try again.');
		const meta = { id, name: sanitizeName(name || '', kind), media_type: kind.media_type, size: bytes.length, sha256: sha, at: now };
		group.files[id] = meta;
		group.at = now;
		staging[clientId] = group;
		await this.storage.put(key, staging);
		return answer(meta, false);
	}

	/** `AttachmentDesk::make_room`: expire old groups, then evict the oldest outside the grace period. */
	makeRoom(staging, keep, incoming, now) {
		for (const [client, group] of Object.entries(staging)) {
			if (client !== keep && now - group.at > STAGING_TTL_MS) delete staging[client];
		}
		const size = (g) => Object.values(g.files).reduce((n, f) => n + f.size, 0);
		let total = Object.values(staging).reduce((n, g) => n + size(g), 0) + incoming;
		let count = Object.keys(staging).length + (staging[keep] ? 0 : 1);
		const oldest = Object.entries(staging).sort((a, b) => a[1].at - b[1].at);
		for (const [client, group] of oldest) {
			if (total <= MAX_STAGED_BYTES && count <= MAX_STAGED_MESSAGES) break;
			if (client === keep || now - group.at < EVICTION_GRACE_MS) continue;
			total -= size(group);
			count -= 1;
			delete staging[client];
		}
		return total <= MAX_STAGED_BYTES && count <= MAX_STAGED_MESSAGES;
	}

	/** `routes.rs` attachments_message. `body` is already parsed; `bodyHashHex` is of the exact bytes. */
	async commitAttachments(device, body, bodyHashHex) {
		const threadId = body.thread_id;
		if (typeof threadId !== 'string' || !this.threadExists(threadId)) return NOT_FOUND;
		let text = '';
		if (body.text !== undefined && body.text !== null) {
			if (typeof body.text !== 'string') return NOT_FOUND;
			text = body.text.trim();
		}
		const list = body.attachments;
		if (!Array.isArray(list) || !list.length || list.length > MAX_FILES_PER_MESSAGE) return NOT_FOUND;
		const wanted = [];
		for (const item of list) {
			const id = item && item.id, sha = item && item.sha256;
			if (!validId(id) || typeof sha !== 'string' || !/^[0-9a-f]{64}$/.test(sha)) return NOT_FOUND;
			if (wanted.some((w) => w.id === id)) return NOT_FOUND;
			wanted.push({ id, sha });
		}
		const clientId = body.client_id;
		const key = `staging:${device.id}`;
		const staged = async () => {
			const group = ((await this.storage.get(key)) || {})[clientId];
			const found = [], missing = [];
			for (const w of wanted) {
				const meta = group && group.files[w.id];
				if (meta && meta.sha256 === w.sha) found.push(meta); else missing.push(w.id);
			}
			return { found, missing };
		};
		const result = await this.execute(device.id, clientId, bodyHashHex, async () => {
			const { found, missing } = await staged();
			if (missing.length) throw new Error('missing');
			return found;
		}, async (files) => {
			const stored = uniqueNames(files);
			const staging = (await this.storage.get(key)) || {};
			delete staging[clientId];
			await this.storage.put(key, staging);
			const { answer } = await this.submit(threadId, clientId, { text: describe(text, stored) }, { kind: 'attachments', text, files: stored });
			return JSON.stringify({ ...answer, attachments: stored.map(({ id, name, media_type, size }) => ({ id, name, media_type, size })), duplicate: false });
		});
		const refusal = (status, retry, reason) => json(status, { accepted: false, retry, reason });
		if (result.kind === 'accepted') return { type: 'json', status: 200, body: result.answer };
		if (result.kind === 'duplicate') return { type: 'json', status: 200, body: JSON.stringify({ ...JSON.parse(result.answer), duplicate: true }) };
		if (result.kind === 'rejected') {
			const { missing } = await staged();
			return json(422, { accepted: false, retry: true, missing, reason: 'Some files have not reached your Mac yet. They are still on your phone and will be sent again.' });
		}
		if (result.kind === 'conflict') return refusal(409, false, 'That message ID was already used for a different message. Your files are still on your phone.');
		return refusal(503, false, "Your Mac's message recovery history is full. Your files are still on your phone.");
	}

	// ---- the event stream and the backfill (`routes.rs` events, `stream.rs` PhoneHub) -----------

	publish(kind, cursor, data) {
		if (cursor > this.meta.cursor) this.meta.cursor = cursor;
		const frame = { cursor, kind, data: JSON.stringify(data) };
		this.recent.push(frame);
		while (this.recent.length > REPLAY_MEMORY) this.recent.shift();
		const wire = `id: ${frame.cursor}\nevent: ${frame.kind}\ndata: ${frame.data}\n\n`;
		for (const stream of this.streams) stream.write(wire);
		return frame;
	}

	/** `stream.rs` replay_after. */
	replayAfter(since) {
		if (since === null) return null;
		if (since > this.meta.cursor) return null;
		const oldest = this.recent.length ? this.recent[0].cursor : null;
		if (oldest !== null && oldest <= since + 1) return this.recent.filter((f) => f.cursor > since);
		if (oldest === null && since === this.meta.cursor) return [];
		return null;
	}

	async backfill(threadId, before, limit) {
		const all = await this.rows(threadId);
		const earlier = all.filter((r) => r.cursor < before);
		const start = Math.max(0, earlier.length - limit);
		return json(200, { messages: earlier.slice(start), more: start > 0 });
	}

	async hello(threadId) {
		const rows = await this.rows(threadId);
		return {
			challenge: await this.issueChallenge(),
			api_base: this.origin,
			thread_id: threadId,
			latest_cursor: this.meta.cursor,
			threads: THREADS.map(({ id, title }) => ({ id, title })),
			vapid_public_key: '',
			capabilities: this.capabilities(),
			protocol_version: PROTOCOL_VERSION,
			attachment_limits: ATTACHMENT_LIMITS_WIRE,
			build: BUILD,
			messages: rows
		};
	}

	/** Open a live stream: the opening frames, then every published frame, with keep-alives. */
	async openStream(threadId, since) {
		if (this.streams.size >= MAX_STREAMS) return RATE_LIMITED;
		let opening;
		const tail = this.replayAfter(since);
		if (tail) {
			opening = tail.map((f) => `id: ${f.cursor}\nevent: ${f.kind}\ndata: ${f.data}\n\n`);
		} else {
			const data = await this.hello(threadId);
			opening = [`id: ${this.meta.cursor}\nevent: hello\ndata: ${JSON.stringify(data)}\n\n`];
		}
		const { readable, writable } = new TransformStream();
		const writer = writable.getWriter();
		const streams = this.streams;
		let timer = null;
		const entry = {
			write(text) { writer.write(encoder.encode(text)).catch(() => entry.close()); },
			close() {
				if (!streams.has(entry)) return;
				streams.delete(entry);
				if (timer) clearInterval(timer);
				writer.close().catch(() => {});
			}
		};
		streams.add(entry);
		for (const text of opening) entry.write(text);
		timer = setInterval(() => entry.write(`: keep-alive ${this.now()}\n\n`), KEEPALIVE_MS);
		// Node only: a keep-alive timer must not hold a test process open. workerd has no `unref`.
		if (timer && typeof timer.unref === 'function') timer.unref();
		return { type: 'stream', body: readable, entry };
	}

	// ---- reply audio (`routes.rs` audio) --------------------------------------------------------

	async audio(messageId, threadId) {
		const threads = threadId && this.threadExists(threadId) ? [threadId] : THREADS.map((t) => t.id);
		for (const t of threads) {
			const row = (await this.rows(t)).find((r) => r.id === messageId && r.role === 'rich' && r.complete);
			if (row) return { type: 'bytes', status: 200, contentType: 'audio/wav', body: chime() };
		}
		return json(503, { retry: false, reason: 'Audio playback is unavailable. The reply remains in the conversation.' });
	}

	// ---- the demo replies ----------------------------------------------------------------------

	/** Ask for `alarm()` at `at`, keeping the earliest outstanding wake-up. */
	async wake(at) { await this.schedule(at); }

	/**
	 * The Durable Object alarm: write every demo reply that is due, streamed in pieces, then send
	 * its notification. Also retries push work that failed earlier.
	 */
	async alarm() {
		await this.load();
		const now = this.now();
		await this.expireUnconfirmed(now);
		const due = this.pending.filter((p) => p.due <= now);
		this.pending = this.pending.filter((p) => p.due > now);
		await this.storage.put('pending', this.pending);
		for (const item of due) await this.writeReply(item);
		if (this.push && (this.desk.jobs.length || this.desk.dirty)) await this.reconcilePush(this.device);
		const next = [...this.pending.map((p) => p.due)];
		if (this.push && this.desk.jobs.length) next.push(this.now() + PUSH_RETRY_MS);
		if (this.device && this.device.active !== true) next.push(this.device.window_ends + 1);
		if (next.length) await this.wake(Math.min(...next));
	}

	async writeReply({ thread, what }) {
		const text = replyFor(what);
		const cursor = this.nextCursor();
		const id = `turn_${cursor}:text:0`;
		const base = { id, thread_id: thread, cursor, role: 'rich', kind: 'text', created_at: iso8601(this.now()), client_id: null, has_audio: false, from_microphone: false };
		await this.saveMeta();
		this.publish('message', cursor, { ...base, text: '', state: 'streaming', complete: false });
		for (const piece of chunks(text)) {
			this.publish('delta', cursor, { message_id: id, thread_id: thread, cursor, text: piece });
			await this.sleep(DELTA_PAUSE_MS);
		}
		const row = { ...base, text, state: 'complete', complete: true };
		await this.replaceRow(row);
		this.publish('message', cursor, row);
		// `notifications.rs` queue_reply: not for a phone that already reported this cursor.
		const device = this.device;
		if (this.push && device && device.fingerprint_confirmed && device.active === true && Desk.enabledFor(this.desk, device)
			&& !(Number.isSafeInteger(device.delivered_cursor) && device.delivered_cursor >= cursor)) {
			try {
				await Desk.enqueue(this.desk, device, thread, id, text, this.now());
			} catch { /* the queue is full; the reply is still in the conversation */ }
			await this.reconcilePush(device);
		}
	}
}

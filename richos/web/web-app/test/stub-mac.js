'use strict';

// A STAND-IN FOR HIS MAC, for the browser harness. Not shipped, not the contract, not a second
// implementation of anything — it exists so `test/desktop-verify.js` can drive the REAL app, over
// the REAL origin shape, against something that answers the four routes the way CONTRACT-STUB.md
// says the Mac will.
//
// WHAT IT IS HONEST ABOUT, and this is the part that makes the harness worth running:
//
//   * It serves over TLS from a certificate it mints for itself, so the browser is on an `https`
//     origin and `isSecureContext` is true — which is what service workers, push and getUserMedia
//     are actually gated on. A harness on `http://127.0.0.1` tests a different thing.
//   * It VERIFIES the phone's signature with `node:crypto`, against the public key the phone
//     registered at pairing. So "the phone signs requests" is proved by a real ECDSA P-256
//     verification of a signature made by the browser's own WebCrypto with a non-extractable key,
//     rather than by the phone claiming it signed something.
//   * It can be made UNREACHABLE — destroying the socket, the way a Mac that is asleep or on another
//     network behaves — so the queue's "waiting to send" state is produced by a real failed `fetch`
//     and not by a stub returning a convenient error.
//   * It issues the cursors. Nothing the phone sends carries an order.
//
// The certificate helpers come from `richos/tools/phone-probe/lib/x509.js`. That is a TEST-ONLY
// cross-tree require and it is deliberate: those two hundred lines mint an Apple-compliant CA and
// leaf with no dependency, they are already proven on his phone, and a second copy of certificate
// code in this repository would be a second thing to get wrong. Nothing in the shipped app imports
// anything from `tools/`.

const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const crypto = require('node:crypto');

const { createCertificateAuthority, createServerCertificate } = require('../../../tools/phone-probe/lib/x509.js');
const pcm = require('../lib/pcm.js');

const APP_DIR = path.join(__dirname, '..');

const TYPES = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.png': 'image/png',
	'.webmanifest': 'application/manifest+json'
};

function spkiPin(certPem) {
	const spki = crypto.createPublicKey(certPem).export({ type: 'spki', format: 'der' });
	return crypto.createHash('sha256').update(spki).digest('base64');
}

function sha256Hex(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}

/// What a WAV says about itself, read off the bytes on the wire. The Mac's recognizer takes 16 kHz
/// mono 16-bit PCM and nothing else, so this is the shape of the only thing it can be handed.
function readWavHeader(bytes) {
	if (!bytes || bytes.length < 44) return { error: `only ${bytes ? bytes.length : 0} bytes` };
	return {
		riff: bytes.slice(0, 4).toString('ascii'),
		wave: bytes.slice(8, 12).toString('ascii'),
		fmt: bytes.slice(12, 16).toString('ascii'),
		format: bytes.readUInt16LE(20),
		channels: bytes.readUInt16LE(22),
		rate: bytes.readUInt32LE(24),
		byteRate: bytes.readUInt32LE(28),
		bits: bytes.readUInt16LE(34),
		dataBytes: bytes.readUInt32LE(40),
		totalBytes: bytes.length
	};
}

/// One seeded conversation, so the thread has a past to scroll into and a present to add to.
function seedLedger(threadId, count) {
	const rows = [];
	const start = Date.UTC(2026, 8, 18, 9, 0, 0);
	for (let i = 0; i < count; i++) {
		const mine = i % 2 === 0;
		rows.push({
			id: `seed-${i}`,
			thread_id: threadId,
			cursor: i + 1,
			role: mine ? 'ceo' : 'rich',
			kind: 'text',
			text: mine ? `Earlier question number ${i + 1}.` : `Earlier answer number ${i + 1}.`,
			created_at: new Date(start + i * 60000).toISOString(),
			complete: true,
			has_audio: !mine
		});
	}
	return rows;
}

function createStubMac(options) {
	const opts = options || {};
	const host = opts.host || 'localhost';
	const threadId = opts.threadId || 'thread-main';

	const ca = createCertificateAuthority({ commonName: 'RichOS phone harness root' });
	const leaf = createServerCertificate({
		names: [host, '127.0.0.1'],
		caCertPem: ca.certPem,
		caKeyPem: ca.keyPem,
		commonName: host
	});

	const caFingerprintHex = crypto.createHash('sha256')
		.update(new crypto.X509Certificate(ca.certPem).raw).digest('hex');

	const state = {
		// `unreachable` makes every /api/ request fail at the socket, which is what a sleeping Mac
		// looks like to `fetch`. `revoked` answers 403 with the body that means "forgotten".
		mode: 'normal',
		devices: new Map(),
		challenges: new Map(),
		ledger: seedLedger(threadId, opts.history === undefined ? 60 : opts.history),
		nextCursor: (opts.history === undefined ? 60 : opts.history) + 1,
		clientIds: new Map(),
		streams: new Set(),
		received: [],
		dropped: new Set(),
		pairCode: opts.pairCode || 'harness-pair-code',
		threads: opts.threads || [{ id: threadId, title: 'Rich' }],
		vapidPublicKey: opts.vapidPublicKey || 'BJ-harness-vapid-public-key',
		// Both are what the stub IS, and both are overridable so a check can drive a Mac that
		// cannot take a voice note without a second server.
		capabilities: opts.capabilities || ['text', 'voice'],
		build: opts.build || '0.0.0-harness',
		autoReply: opts.autoReply !== false
	};

	/// A RING OF LIVE CHALLENGES, NOT ONE, because that is what the Mac has and the difference is
	/// load-bearing now. `device.rs` keeps the last LIVE_CHALLENGES = 16 and accepts any of them
	/// (`device.rs:413-417`), so a phone with a request in flight is not refused because something
	/// else asked for a challenge a millisecond earlier. A stub holding exactly one would refuse
	/// that phone, and the reconnect this harness now exercises asks for a challenge and signs a
	/// stream with it as two separate requests.
	const LIVE_CHALLENGES = 16;
	function newChallenge(deviceId) {
		const value = crypto.randomBytes(12).toString('base64url');
		const live = state.challenges.get(deviceId) || [];
		live.push(value);
		while (live.length > LIVE_CHALLENGES) live.shift();
		state.challenges.set(deviceId, live);
		return value;
	}

	/// The newest one this device was given, for the `hello` frame.
	function liveChallenge(deviceId) {
		const live = state.challenges.get(deviceId) || [];
		return live[live.length - 1] || null;
	}

	/// The whole of authentication, and it is a real verification rather than a shape check.
	///
	/// **`where` IS REQUIRED, AND IT IS THE FIX FOR A DEFECT THIS FUNCTION WAS HIDING.** It used to
	/// read `req.headers.authorization || url.searchParams.get('auth')` — the header OR the query,
	/// on every route. The shipped Mac does no such thing. It reads ONE of the two per route, and
	/// which one is not a detail:
	///
	///   * `GET /api/events` — the QUERY and only the query. `routes.rs:403-411` is
	///     `let Some(auth) = query_value(&request.query, "auth") else { return Outcome::NotFound }`
	///     and the word `request.authorization` does not appear anywhere in that function.
	///   * `POST /api/messages` (`routes.rs:304`), `GET /api/audio/…` (`:504`) and
	///     `POST /api/pair` when it is the device record (`:210`) — the HEADER and only the header.
	///
	/// So a stub that accepts either is MORE PERMISSIVE THAN THE MAC, and a phone that signs the
	/// wrong way passes every check in this repository and gets a flat 404 on his actual Mac. That
	/// is not a hypothetical: `lib/api.js` `backfill()` went through `request()`, which sets the
	/// header, against a route that reads only the query — so every "load older messages" scroll on
	/// a real Mac was a 404, and `api.test.js` and `desktop-verify` were green the whole time.
	///
	/// It is required rather than defaulted because a default is how the next route forgets.
	function authenticate(req, url, bodyBytes, where) {
		if (where !== 'header' && where !== 'query') {
			throw new Error("authenticate() needs to be told where this route reads the credential: 'header' or 'query'");
		}
		const header = where === 'query'
			? url.searchParams.get('auth')
			: (req.headers.authorization || null);
		if (!header || !header.startsWith('RichOS-Device ')) return null;

		const [deviceId, challenge, signature] = header.slice('RichOS-Device '.length).split('.');
		const device = state.devices.get(deviceId);
		if (!device) return null;
		if (!(state.challenges.get(deviceId) || []).includes(challenge)) return null;

		// The path the phone signed is the path WITHOUT the credential it appended.
		const signedSearch = new URLSearchParams(url.search);
		signedSearch.delete('auth');
		const query = signedSearch.toString();
		const signedPath = url.pathname + (query ? `?${query}` : '');
		const input = `${challenge}\n${req.method.toUpperCase()}\n${signedPath}\n${bodyBytes && bodyBytes.length ? sha256Hex(bodyBytes) : ''}`;

		const ok = crypto.verify('sha256', Buffer.from(input, 'utf8'),
			{ key: device.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url'));
		return ok ? { deviceId, device } : null;
	}

	function send(res, status, body, headers) {
		const payload = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
		res.writeHead(status, Object.assign({
			'Content-Type': 'application/json',
			// The app origin is the only one allowed, and the credential is a header rather than a
			// cookie — so no credentials mode is enabled here.
			'Access-Control-Allow-Origin': '*',
			'Access-Control-Allow-Headers': 'authorization, content-type'
		}, headers || {}));
		res.end(payload);
	}

	// §2.5 item 4: an unauthorized caller learns nothing, not even that it guessed a real path.
	function flat404(res) {
		res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
		res.end('Not Found');
	}

	function broadcast(event, data) {
		for (const res of state.streams) {
			try {
				res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
			} catch { /* the client went away; the next write will clean it up */ }
		}
	}

	function appendRow(row) {
		state.ledger.push(row);
		broadcast('message', row);
		return row;
	}

	/// Rich answering. Deliberately in three pieces with a first token that is immediate: §4.2 (v)
	/// is that a phone showing nothing for thirty-five seconds reads as broken, and the harness
	/// asserts that a reply STREAMS rather than appearing whole.
	function replyTo(text) {
		if (!state.autoReply) return;
		const id = `rich-${state.nextCursor}`;
		const cursor = state.nextCursor++;
		const row = {
			id, thread_id: threadId, cursor, role: 'rich', kind: 'text', text: 'On it!',
			created_at: new Date().toISOString(), complete: false, has_audio: true
		};
		appendRow(row);
		const pieces = [' Looking at it now.', ` You asked: ${text.slice(0, 40)}`, ' That is the whole answer.'];
		let at = 0;
		const tick = setInterval(() => {
            if(state.pauseReplyChunks)return;
			if (at >= pieces.length) {
				clearInterval(tick);
				broadcast('state', { message_id: id, complete: true, state: 'done' });
				const stored = state.ledger.find((r) => r.id === id);
				if (stored) stored.complete = true;
				return;
			}
			const piece = pieces[at++];
			const stored = state.ledger.find((r) => r.id === id);
			if (stored) stored.text += piece;
			broadcast('delta', { message_id: id, cursor, text: piece });
		}, 60);
	}

	const server = https.createServer({ cert: leaf.certPem, key: leaf.keyPem }, (req, res) => {
		const url = new URL(req.url, `https://${req.headers.host || host}`);

		if (req.method === 'OPTIONS') {
			send(res, 204, '');
			return;
		}

		// --- static: the app itself ---------------------------------------------------------
		if (!url.pathname.startsWith('/api/')) {
			const rel = url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\//, '');
			const file = path.join(APP_DIR, rel);
			// No path can escape the app directory. The Mac serves four routes and a static app,
			// and nothing else (§2.5 item 5).
			if (!file.startsWith(APP_DIR) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
				flat404(res);
				return;
			}
			const type = TYPES[path.extname(file)] || 'application/octet-stream';
			res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store' });
			res.end(fs.readFileSync(file));
			return;
		}

		if (state.mode === 'unreachable') {
			// Not a 503: a Mac that is asleep does not answer at all, and the difference decides
			// whether the phone says "waiting to send" or "your Mac refused this".
			// Every request this outage drops is recorded, exactly as the phone sent it, so a harness
			// can tell the browser reporting THIS failure from any other one.
			state.dropped.add(req.url);
			req.socket.destroy();
			return;
		}

		// --- the way back to a challenge this phone can sign ---------------------------------
		//
		// `lib/api.js` `refreshChallenge()` knocks here, UNAUTHENTICATED and on purpose: an
		// `EventSource` cannot read a response header, so a phone whose challenge aged out during
		// an outage has no other way to learn a live one, and signing the dead challenge to ask
		// for a live one is the circle. The real Mac has no such route and answers the flat 404 —
		// WITH the challenge attached, because EVERY answer on that port carries one
		// (`app/src-tauri/src/phone/listen.rs:334-342`, pinned by its test at `listen.rs:557`).
		// This answers exactly the same way, status included, so the harness exercises the path
		// the phone will really take.
		if (url.pathname === '/api/challenge') {
			const only = [...state.devices.keys()][0] || 'unpaired';
			res.writeHead(404, {
				'Content-Type': 'text/plain; charset=utf-8',
				'Cache-Control': 'no-store',
				'Access-Control-Allow-Origin': '*',
				'X-RichOS-Challenge': newChallenge(only)
			});
			res.end('Not Found');
			return;
		}

		// --- the stream ---------------------------------------------------------------------
		if (url.pathname === '/api/events' && url.searchParams.get('before') === null && req.headers.accept && req.headers.accept.includes('text/event-stream')) {
			// THE QUERY, because an `EventSource` cannot set a header (`routes.rs:405`).
			const who = authenticate(req, url, null, 'query');
			if (!who) { flat404(res); return; }
			if (state.mode === 'revoked') { send(res, 403, { revoked: true }); return; }

			res.writeHead(200, {
				'Content-Type': 'text/event-stream',
				'Cache-Control': 'no-store',
				Connection: 'keep-alive',
				'Access-Control-Allow-Origin': '*'
			});
			state.streams.add(res);
			req.on('close', () => state.streams.delete(res));

			res.write(`event: hello\ndata: ${JSON.stringify({
				challenge: liveChallenge(who.deviceId),
				api_base: opts.apiBase || null,
				thread_id: threadId,
				latest_cursor: state.nextCursor - 1,
				threads: state.threads,
				vapid_public_key: state.vapidPublicKey,
				// WHAT THIS STUB CAN ACTUALLY DO, and it advertises it because it can: the
				// `/api/messages` handler below takes an `audio/wav` body and files it as a voice
				// row. The shipped Mac answers a voice note 503 and advertises `["text"]` only
				// (`routes.rs`), which is the same rule — a capability is named when the thing
				// behind it works — and it is what makes the harness's hold-to-record walk a test
				// of the recorder rather than a test of a control that should not be there.
				capabilities: state.capabilities,
				build: state.build
			})}\n\n`);

			const since = Number(url.searchParams.get('since'));
			const from = Number.isFinite(since) && since > 0 ? since : state.nextCursor - 12;
			state.ledger.filter((row) => row.cursor > from).forEach((row) => {
				res.write(`event: message\ndata: ${JSON.stringify(row)}\n\n`);
			});
			return;
		}

		// --- the backfill behind infinite scroll --------------------------------------------
		if (url.pathname === '/api/events') {
			// THE QUERY HERE TOO, AND THAT IS THE WHOLE POINT. `routes.rs` `events()` reads the
			// credential ONCE, at `:405`, BEFORE it looks at `before=` and decides whether this is
			// the stream or the backfill. One route, one contract — the Mac does not grow a second
			// way to be asked just because the answer is JSON.
			const who = authenticate(req, url, null, 'query');
			if (!who) { flat404(res); return; }
			const before = Number(url.searchParams.get('before'));
			const limit = Number(url.searchParams.get('limit')) || 40;
			const older = state.ledger.filter((row) => row.cursor < before).sort((a, b) => a.cursor - b.cursor);
			const page = older.slice(-limit);
			send(res, 200, { messages: page, more: page.length < older.length },
				{ 'X-RichOS-Challenge': newChallenge(who.deviceId) });
			return;
		}

		// --- post a message ------------------------------------------------------------------
		if (url.pathname === '/api/messages' && req.method === 'POST') {
			const parts = [];
			req.on('data', (c) => parts.push(c));
			req.on('end', () => {
				const bodyBytes = Buffer.concat(parts);
				// THE HEADER — `routes.rs:304`.
				const who = authenticate(req, url, bodyBytes, 'header');
				if (!who) { flat404(res); return; }
				if (state.mode === 'revoked') { send(res, 403, { revoked: true }); return; }

				let clientId;
				let row;
				if ((req.headers['content-type'] || '').startsWith('audio/wav')) {
					clientId = url.searchParams.get('client_id');
					// The header is read HERE, off the bytes that actually arrived, so the harness
					// asserts what the Mac received rather than what the page believed it sent.
					state.wavHeader = readWavHeader(bodyBytes);
					row = {
						id: `m-${state.nextCursor}`,
						thread_id: url.searchParams.get('thread_id') || threadId,
						cursor: state.nextCursor,
						role: 'ceo',
						kind: 'voice',
						// A note the Mac has transcribed. The marker the bridge established is a
						// field, never a character the phone has to know about.
						text: '(spoken) this is what the Mac heard',
						from_microphone: true,
						created_at: new Date().toISOString(),
						client_id: clientId,
						complete: true,
						audio: { bytes: bodyBytes.length, codec: url.searchParams.get('codec'), seconds: Number(url.searchParams.get('seconds')) }
					};
				} else {
					let body = {};
					try { body = JSON.parse(bodyBytes.toString('utf8')); } catch { send(res, 400, { error: 'bad json' }); return; }
					clientId = body.client_id;
					row = {
						id: `m-${state.nextCursor}`,
						thread_id: body.thread_id || threadId,
						cursor: state.nextCursor,
						role: 'ceo',
						kind: 'text',
						text: body.text,
						created_at: new Date().toISOString(),
						client_id: clientId,
						complete: true
					};
				}

				// IDEMPOTENT ON THE CLIENT ID. This is what makes the phone's retry safe, so the
				// harness proves the Mac side of that bargain rather than assuming it.
				if (clientId && state.clientIds.has(clientId)) {
					const first = state.clientIds.get(clientId);
					send(res, 200, { message_id: first.id, cursor: first.cursor, thread_id: first.thread_id, accepted_at: first.created_at, duplicate: true },
						{ 'X-RichOS-Challenge': newChallenge(who.deviceId) });
					return;
				}

				state.nextCursor++;
				if (clientId) state.clientIds.set(clientId, row);
				state.received.push(row);
				appendRow(row);
				send(res, 200, { message_id: row.id, cursor: row.cursor, thread_id: row.thread_id, accepted_at: row.created_at, duplicate: false },
					{ 'X-RichOS-Challenge': newChallenge(who.deviceId) });
				replyTo(row.text || 'a voice note');
			});
			return;
		}

		// --- one audio blob, by an id the Mac minted -----------------------------------------
		if (url.pathname.startsWith('/api/audio/')) {
			// THE HEADER — `routes.rs:504`.
			const who = authenticate(req, url, null, 'header');
			if (!who) { flat404(res); return; }
			const id = decodeURIComponent(url.pathname.slice('/api/audio/'.length));
			if (!state.ledger.some((row) => row.id === id)) { flat404(res); return; }
			// Half a second of a quiet tone, made with the app's own encoder. Nothing is played out
			// of this Mac's speakers by the harness — the page fetches it and the harness asserts
			// the bytes and the element's state, never a sound in the room.
			const samples = new Float32Array(8000);
			for (let i = 0; i < samples.length; i++) samples[i] = 0.05 * Math.sin((2 * Math.PI * 220 * i) / 16000);
			const wav = Buffer.from(pcm.encodeWav(samples, 16000));
			res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': wav.length, 'Access-Control-Allow-Origin': '*' });
			res.end(wav);
			return;
		}

		// --- pairing, and the device record --------------------------------------------------
		if (url.pathname === '/api/pair' && req.method === 'POST') {
			const parts = [];
			req.on('data', (c) => parts.push(c));
			req.on('end', () => {
				const bodyBytes = Buffer.concat(parts);
				let body = {};
				try { body = JSON.parse(bodyBytes.toString('utf8')); } catch { flat404(res); return; }

				if (body.code) {
					if (body.code !== state.pairCode) { send(res, 403, { error: 'no' }); return; }
					const deviceId = `device-${state.devices.size + 1}`;
					let publicKey;
					try {
						publicKey = crypto.createPublicKey({ key: body.public_key_jwk, format: 'jwk' });
					} catch (err) { send(res, 400, { error: 'bad key' }); return; }
					state.devices.set(deviceId, { publicKey, name: body.device_name, push: null });
					// One shot: the code is spent whether or not he finishes.
					state.pairCode = null;
					send(res, 200, {
						device_id: deviceId,
						ca_fingerprint_sha256: caFingerprintHex,
						challenge: newChallenge(deviceId),
						api_base: opts.apiBase || null,
						vapid_public_key: state.vapidPublicKey,
						thread_id: threadId,
						threads: state.threads
					});
					return;
				}

				// THE HEADER — `routes.rs:210`, the device-record half of this route.
				const who = authenticate(req, url, bodyBytes, 'header');
				if (!who) { flat404(res); return; }
				who.device.push = body.push || null;
				who.device.pushTransport = body.push_transport || null;
				send(res, 200, { ok: true, challenge: newChallenge(who.deviceId) });
			});
			return;
		}

		flat404(res);
	});

	return {
		server,
		state,
		caPem: ca.certPem,
		leafPem: leaf.certPem,
		spkiPin: spkiPin(leaf.certPem),
		caFingerprintHex,
		threadId,
		listen(port) {
			return new Promise((resolve, reject) => {
				server.once('error', reject);
				server.listen(port, opts.bindHost, () => resolve(server.address().port));
			});
		},
		close() {
			for (const res of state.streams) { try { res.end(); } catch { /* already gone */ } }
			state.streams.clear();
			return new Promise((resolve) => server.close(resolve));
		},
		setMode(mode) { state.mode = mode; },
		received() { return state.received; },
		pushTo(client, payload) { return payload; }
	};
}

module.exports = { createStubMac };

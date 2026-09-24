// THE PHONE'S FOUR ROUTES, AND THE FLAT 404 EVERYTHING ELSE GETS — on a review host.
//
// A port of `phone/routes.rs` dispatch (the route table) and `phone/listen.rs` render (the
// headers every answer carries, including `X-RichOS-Challenge`). `dispatch` is a pure function
// from a described request to a described outcome, exactly as on the Mac, so the tests drive the
// whole path space without a network; `handlePhoneRequest` is the thin HTTP edge around it.

import { sha256hex, bytesOf, concat } from './codec.mjs';
import { MAX_BODY_BYTES, MAX_FILE_BYTES, MAX_RAW_NAME_BYTES, MAX_VOICE_BYTES } from './limits.mjs';
import { bodyHash, decodeComponent, parseAuthorization, queryValue, signedPath } from './signing.mjs';
import { validId } from './attachments.mjs';
import { validateVoice } from './wav.mjs';
import { pageHeaders, hostPage } from './pages.mjs';
import { AWAITING } from './host.mjs';

const utf8Length = (s) => bytesOf(s).length;
const NOT_FOUND = { type: 'notFound' };

/** `routes.rs` body_limit: decided from the request line and headers before the body is read. */
export function bodyLimit(method, path, query, contentType) {
	if (method !== 'POST' || path !== '/api/messages') return MAX_BODY_BYTES;
	if (queryValue(query, 'kind') === 'attachment') return MAX_FILE_BYTES;
	return contentType === 'audio/wav' ? MAX_VOICE_BYTES : MAX_BODY_BYTES;
}

function parseJson(bytes) {
	try {
		const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
		return { ok: true, value };
	} catch {
		return { ok: false };
	}
}

const asObject = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});
const u64 = (text) => (typeof text === 'string' && /^\d{1,15}$/.test(text) ? Number(text) : null);

/** `routes.rs` verified: check the credential over the path the signature covers. */
async function verified(host, incoming, header, pathWithQuery) {
	const parsed = parseAuthorization(header);
	if (!parsed) return { refusal: NOT_FOUND };
	return host.verify({
		method: incoming.method,
		pathWithQuery,
		deviceId: parsed.deviceId,
		challenge: parsed.challenge,
		signature: parsed.signature,
		bodyHashHex: await bodyHash(incoming.body)
	});
}

/**
 * The route table. `incoming` is `{ method, path, query, authorization, lastEventId, contentType, body }`
 * with `path` as sent on the wire and `query` without the `?`.
 */
export async function dispatch(host, incoming) {
	await host.load();
	if (incoming.body.length > bodyLimit(incoming.method, incoming.path, incoming.query, incoming.contentType)) return { type: 'tooLarge' };
	const { method, path } = incoming;
	if (method === 'POST' && path === '/api/pair') return pair(host, incoming);
	if (method === 'POST' && path === '/api/messages') return messages(host, incoming);
	if (method === 'GET' && path === '/api/events') return events(host, incoming);
	if (method === 'GET' && path.startsWith('/api/audio/')) return audio(host, incoming, path.slice('/api/audio/'.length));
	if (method === 'GET' && path === '/') return { type: 'page' };
	return NOT_FOUND;
}

async function pair(host, incoming) {
	const parsed = parseJson(incoming.body);
	if (!parsed.ok) return NOT_FOUND;
	const body = asObject(parsed.value);
	// Two requests on one route, told apart by the presence of a code (`routes.rs`).
	if (typeof body.code === 'string') return host.completePairing(body);
	if (!incoming.authorization) return NOT_FOUND;
	const check = await verified(host, incoming, incoming.authorization, signedPath(incoming.path, incoming.query));
	if (check.refusal) return check.refusal;
	return host.deviceRecord(check.device, body, check.device.id, check.active);
}

async function messages(host, incoming) {
	if (!incoming.authorization) return NOT_FOUND;
	const check = await verified(host, incoming, incoming.authorization, signedPath(incoming.path, incoming.query));
	if (check.refusal) return check.refusal;
	if (!check.active) return AWAITING;
	const device = check.device;
	const kind = queryValue(incoming.query, 'kind');
	if (kind === 'attachment') return upload(host, device, incoming);
	if (kind === 'voice' || (incoming.contentType || '').startsWith('audio/')) return voice(host, device, incoming);
	const parsed = parseJson(incoming.body);
	if (!parsed.ok) return NOT_FOUND;
	const body = asObject(parsed.value);
	const clientId = body.client_id;
	if (typeof clientId !== 'string' || !clientId || utf8Length(clientId) > 128) return NOT_FOUND;
	const bodyHashHex = await sha256hex(incoming.body);
	if (body.kind === 'attachments') return host.commitAttachments(device, body, bodyHashHex);
	return host.sendText(device, body, bodyHashHex);
}

async function upload(host, device, incoming) {
	const decoded = (name) => { const v = queryValue(incoming.query, name); return v === null ? null : decodeComponent(v); };
	const clientId = decoded('client_id');
	if (!clientId || utf8Length(clientId) > 128) return NOT_FOUND;
	const id = decoded('attachment_id');
	if (!validId(id)) return NOT_FOUND;
	const name = decoded('name');
	if (name !== null && utf8Length(name) > MAX_RAW_NAME_BYTES) return NOT_FOUND;
	if (!incoming.contentType) return NOT_FOUND;
	return host.stage(device, { clientId, id, name, contentType: incoming.contentType, bytes: incoming.body });
}

async function voice(host, device, incoming) {
	const refuse = (status, reason) => ({ type: 'json', status, body: JSON.stringify({ accepted: false, retry: false, reason }) });
	if (incoming.contentType !== 'audio/wav' || queryValue(incoming.query, 'kind') !== 'voice') return NOT_FOUND;
	const client = queryValue(incoming.query, 'client_id'), thread = queryValue(incoming.query, 'thread_id');
	if (client === null || thread === null) return NOT_FOUND;
	const clientId = decodeComponent(client), threadId = decodeComponent(thread);
	if (!clientId || utf8Length(clientId) > 128 || !host.threadExists(threadId)) return NOT_FOUND;
	let durationMs;
	try { durationMs = validateVoice(incoming.body); } catch (error) { return refuse(422, error.message); }
	// Bind the receipt to both the destination and the audio (`routes.rs` voice_message).
	const receiptHashHex = await sha256hex(concat(bytesOf(threadId), Uint8Array.of(0), incoming.body));
	return host.sendVoice(device, { clientId, threadId, durationMs, receiptHashHex });
}

async function events(host, incoming) {
	const auth = queryValue(incoming.query, 'auth');
	if (auth === null) return NOT_FOUND;
	const check = await verified(host, incoming, decodeComponent(auth), signedPath(incoming.path, incoming.query));
	if (check.refusal) return check.refusal;
	if (!check.active) return AWAITING;
	const threadId = queryValue(incoming.query, 'thread_id') || host.meta.currentThread;
	if (!host.threadExists(threadId)) return NOT_FOUND;
	const before = u64(queryValue(incoming.query, 'before'));
	if (before !== null) {
		const limit = Math.min(200, Math.max(1, u64(queryValue(incoming.query, 'limit')) ?? 40));
		return host.backfill(threadId, before, limit);
	}
	const since = u64(queryValue(incoming.query, 'since')) ?? u64(incoming.lastEventId);
	return host.openStream(threadId, since);
}

async function audio(host, incoming, rawId) {
	if (!incoming.authorization) return NOT_FOUND;
	const check = await verified(host, incoming, incoming.authorization, signedPath(incoming.path, incoming.query));
	if (check.refusal) return check.refusal;
	if (!check.active) return AWAITING;
	const id = decodeComponent(rawId);
	if (!id || id.length > 256 || !/^[A-Za-z0-9_:-]+$/.test(id)) return NOT_FOUND;
	const thread = queryValue(incoming.query, 'thread_id');
	return host.audio(id, thread === null ? null : decodeComponent(thread));
}

// ---- the HTTP edge (`listen.rs`) -----------------------------------------------------------

/**
 * `listen.rs` render_with: every answer is `no-store`, `nosniff`, CORS `null`, and carries a
 * challenge. A flat refusal has no body; a forgotten phone gets `{"revoked":true}`.
 */
export async function render(host, outcome) {
	if (outcome.type === 'stream') {
		return new Response(outcome.body, { status: 200, headers: {
			'content-type': 'text/event-stream', 'cache-control': 'no-store', 'access-control-allow-origin': 'null', 'x-accel-buffering': 'no'
		} });
	}
	const headers = new Headers({ 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'access-control-allow-origin': 'null' });
	headers.set('x-richos-challenge', await host.issueChallenge());
	let status = 404, body = null;
	switch (outcome.type) {
	case 'json':
		status = outcome.status; body = outcome.body;
		headers.set('content-type', 'application/json; charset=utf-8');
		break;
	case 'bytes':
		status = outcome.status; body = outcome.body;
		headers.set('content-type', outcome.contentType);
		break;
	case 'revoked':
		status = 403; body = '{"revoked":true}';
		headers.set('content-type', 'application/json; charset=utf-8');
		break;
	case 'rateLimited':
		status = 429; headers.set('retry-after', '60');
		break;
	case 'tooLarge':
		status = 413;
		break;
	case 'page':
		status = 200; body = hostPage(host.hostname);
		for (const [k, v] of Object.entries(await pageHeaders())) headers.set(k, v);
		break;
	default:
		status = 404;
	}
	return new Response(body, { status, headers });
}

/** Read at most `limit` bytes; `null` when the body is larger. */
export async function readBody(request, limit) {
	const declared = Number(request.headers.get('content-length') || 0);
	if (declared > limit) return null;
	if (!request.body) return new Uint8Array(0);
	const reader = request.body.getReader();
	const parts = [];
	let size = 0;
	try {
		for (;;) {
			const { value, done } = await reader.read();
			if (done) break;
			size += value.byteLength;
			if (size > limit) { await reader.cancel(); return null; }
			parts.push(value);
		}
	} finally {
		reader.releaseLock();
	}
	return concat(...parts);
}

/** One HTTPS request for a review host, from the Worker (or the Durable Object) to a Response. */
export async function handlePhoneRequest(host, request) {
	await host.load();
	const url = new URL(request.url);
	const method = request.method.toUpperCase();
	const path = url.pathname;
	const query = url.search.startsWith('?') ? url.search.slice(1) : url.search;
	const contentType = request.headers.get('content-type');
	const limit = bodyLimit(method, path, query, contentType);
	// Sage F3: before granting a body larger than any JSON request, run the no-crypto half of the
	// credential check. Only the paired, active phone presenting a live challenge may send 60 MB;
	// anyone else is answered without the body being read.
	if (limit > MAX_BODY_BYTES) {
		const parsed = parseAuthorization(request.headers.get('authorization'));
		if (parsed && host.revoked.includes(parsed.deviceId)) return render(host, { type: 'revoked' });
		if (!parsed || !(await host.largeBodyAllowed(parsed.deviceId, parsed.challenge))) return render(host, NOT_FOUND);
	}
	const body = await readBody(request, limit);
	if (body === null) return render(host, { type: 'tooLarge' });
	const outcome = await dispatch(host, {
		method, path, query, contentType, body,
		authorization: request.headers.get('authorization'),
		lastEventId: request.headers.get('last-event-id')
	});
	return render(host, outcome);
}

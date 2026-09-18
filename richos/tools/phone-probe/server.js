'use strict';

// The phone probe's whole back end: serve five static files, hold one push subscription in
// memory, and send one encrypted push on a delay.
//
// It is deliberately not a relay. The relay described in the plan (§2) is the NEXT brief; this
// process exists to answer §3.2's five questions and then be deleted. Nothing here is a
// foundation for anything, and reading it as one would be a mistake.
//
// WHAT IT STORES, exhaustively, because the page makes a promise about this:
//   - one push subscription per device that presses "turn on notifications": the push-service
//     endpoint URL, its public key and its auth secret. All three are required to send a push
//     at all, on every platform including native, and they identify a MAILBOX, not a person.
//   - nothing else. No audio (it never leaves the phone), no check results (localStorage on the
//     phone), no identity, no analytics, no request log of his traffic.
// In memory only — a restart forgets everything, and there is no database and no disk write.

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { generateVapidKeys, sendNotification } = require('./lib/webpush.js');

const PORT = Number(process.env.PORT || 8788);
const PUBLIC_DIR = path.join(__dirname, 'public');
const VAPID_SUBJECT = process.env.VAPID_SUBJECT || 'mailto:probe@richos.invalid';

// An unguessable code, if one is set. The plan's own doctrine (§2, "one device set, everything
// else 404") says an unpaired caller gets a flat 404 rather than an error that tells it what
// exists — so that is what this does. Unset means open, which is fine for a local test and is
// warned about at boot.
const ACCESS_CODE = process.env.PROBE_ACCESS_CODE || '';

// ---------------------------------------------------------------------------
// VAPID keys
// ---------------------------------------------------------------------------

let vapid = {
	publicKey: process.env.VAPID_PUBLIC_KEY || '',
	privateKey: process.env.VAPID_PRIVATE_KEY || ''
};
let vapidEphemeral = false;
if (!vapid.publicKey || !vapid.privateKey) {
	// Generating a pair at boot keeps `npm start` working with no setup, but the pair dies with
	// the process, which invalidates every subscription taken against it. That is tolerable for a
	// local test and wrong for his phone, so it is said loudly rather than logged quietly.
	vapid = generateVapidKeys();
	vapidEphemeral = true;
}

// ---------------------------------------------------------------------------
// State — one Map, no disk
// ---------------------------------------------------------------------------

/** @type {Map<string, {id: string, subscription: object, createdAt: string, lastSend: object|null}>} */
const devices = new Map();
const MAX_DEVICES = 8; // one CEO, one phone, plus room for a desktop test browser or two
/** @type {Map<string, NodeJS.Timeout>} */
const pending = new Map();

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

function sendJson(res, status, body) {
	const text = JSON.stringify(body);
	res.writeHead(status, {
		'Content-Type': 'application/json; charset=utf-8',
		'Content-Length': Buffer.byteLength(text),
		'Cache-Control': 'no-store'
	});
	res.end(text);
}

function notFound(res) {
	// Flat and uninformative, on purpose.
	res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
	res.end('Not found\n');
}

function readBody(req, limitBytes = 64 * 1024) {
	return new Promise((resolve, reject) => {
		const chunks = [];
		let total = 0;
		req.on('data', (c) => {
			total += c.length;
			if (total > limitBytes) {
				reject(new Error('body too large'));
				req.destroy();
				return;
			}
			chunks.push(c);
		});
		req.on('end', () => resolve(Buffer.concat(chunks)));
		req.on('error', reject);
	});
}

function codeOk(req, url) {
	if (!ACCESS_CODE) return true;
	const supplied = req.headers['x-probe-code'] || url.searchParams.get('k') || '';
	// Timing-safe, because it costs one line.
	const a = Buffer.from(String(supplied));
	const b = Buffer.from(ACCESS_CODE);
	return a.length === b.length && crypto.timingSafeEqual(a, b);
}

const MIME = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.webmanifest': 'application/manifest+json; charset=utf-8',
	'.png': 'image/png',
	'.svg': 'image/svg+xml',
	'.ico': 'image/x-icon'
};

function serveStatic(res, urlPath) {
	const rel = urlPath === '/' ? 'index.html' : urlPath.replace(/^\/+/, '');
	const full = path.join(PUBLIC_DIR, rel);
	// Never serve outside public/.
	if (!full.startsWith(PUBLIC_DIR + path.sep)) return notFound(res);

	fs.readFile(full, (err, data) => {
		if (err) return notFound(res);
		const headers = {
			'Content-Type': MIME[path.extname(full)] || 'application/octet-stream',
			'Content-Length': data.length,
			// A probe must never show a stale build; every answer it gives would be about the
			// wrong page. The service worker is the file where this matters most.
			'Cache-Control': 'no-store'
		};
		res.writeHead(200, headers);
		res.end(data);
	});
}

// The manifest is generated rather than static for one reason: `start_url` must carry the access
// code, or Add to Home Screen produces an installed app that 404s on its own first launch. An
// installed iOS web app may also be storage-partitioned away from Safari, so localStorage cannot
// be relied on to carry the code across the install.
function serveManifest(res, code) {
	const q = code ? `?k=${encodeURIComponent(code)}` : '';
	const manifest = {
		name: 'RichOS phone probe',
		short_name: 'Probe',
		description: 'Five checks that say whether a RichOS phone app can be a web app.',
		// `standalone` is not cosmetic: WebKit gives an installed web app no push at all unless
		// display is standalone or fullscreen.
		display: 'standalone',
		start_url: `/${q}`,
		scope: '/',
		orientation: 'portrait',
		// Matches --ground in both themes (richos/app/ui/style.css), so the status bar and the
		// splash agree with the page instead of flashing white.
		background_color: '#0c1322',
		theme_color: '#0c1322',
		icons: [
			{ src: `/icons/icon-192.png${q}`, sizes: '192x192', type: 'image/png', purpose: 'any' },
			{ src: `/icons/icon-512.png${q}`, sizes: '512x512', type: 'image/png', purpose: 'any' },
			{ src: `/icons/icon-maskable-512.png${q}`, sizes: '512x512', type: 'image/png', purpose: 'maskable' }
		]
	};
	const text = JSON.stringify(manifest, null, 2);
	res.writeHead(200, {
		'Content-Type': 'application/manifest+json; charset=utf-8',
		'Content-Length': Buffer.byteLength(text),
		'Cache-Control': 'no-store'
	});
	res.end(text);
}

// ---------------------------------------------------------------------------
// The push the probe sends
// ---------------------------------------------------------------------------

// The payload is BOTH a plain object our service worker understands AND a valid Declarative Web
// Push document (`web_push: 8030`, WebKit's "Meet Declarative Web Push"). On iOS 18.4+ Safari may
// render the declared notification itself without running our JavaScript; on iOS 16.4–18.3 the
// service worker's `push` handler reads the same fields. Either way a notification appears, which
// is the only thing check 4 is asking. Costs one extra key and removes a whole failure mode.
function pushPayload(code) {
	const q = code ? `?k=${encodeURIComponent(code)}&from=push` : '?from=push';
	return {
		web_push: 8030,
		notification: {
			title: 'Rich',
			body: 'Check 4 passed — this push arrived with the app closed. Tap to finish check 5.',
			navigate: `/${q}`,
			// An app-icon badge is documented as working in the foreground and while handling a
			// push in the background, so it is a second, independent signal that the push landed.
			app_badge: 1
		},
		// Read by the service worker on the iOS 16.4–18.3 path.
		url: `/${q}`,
		sentAt: new Date().toISOString()
	};
}

async function deliver(id, code) {
	const device = devices.get(id);
	if (!device) return;
	try {
		const result = await sendNotification(device.subscription, pushPayload(code), {
			vapidPublicKey: vapid.publicKey,
			vapidPrivateKey: vapid.privateKey,
			vapidSubject: VAPID_SUBJECT,
			ttl: 300,
			urgency: 'high'
		});
		device.lastSend = {
			at: new Date().toISOString(),
			statusCode: result.statusCode,
			ok: result.statusCode >= 200 && result.statusCode < 300,
			gone: result.gone,
			// A push service's error body is the most useful diagnostic there is when this fails,
			// and it says nothing about him, so it is kept.
			detail: result.statusCode >= 300 ? String(result.body).slice(0, 400) : ''
		};
		// Plan risk 2: a lapsed subscription is a real event, not something to swallow. A silent
		// dead channel is the failure that matters.
		if (result.gone) devices.delete(id);
		log(`push ${id.slice(0, 8)} -> ${result.statusCode}${result.gone ? ' (subscription gone, forgotten)' : ''}`);
	} catch (err) {
		device.lastSend = { at: new Date().toISOString(), statusCode: 0, ok: false, gone: false, detail: String(err.message).slice(0, 400) };
		log(`push ${id.slice(0, 8)} -> failed: ${err.message}`);
	} finally {
		pending.delete(id);
	}
}

function log(msg) {
	process.stdout.write(`[phone-probe] ${msg}\n`);
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

const server = http.createServer(async (req, res) => {
	const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
	const route = url.pathname;

	if (route === '/healthz') {
		return sendJson(res, 200, { ok: true, devices: devices.size, vapidEphemeral });
	}

	// The manifest and the icons are fetched by the OS, which does not send our header, so they
	// authenticate by query string only.
	if (route === '/manifest.webmanifest') {
		if (ACCESS_CODE && url.searchParams.get('k') !== ACCESS_CODE) return notFound(res);
		return serveManifest(res, ACCESS_CODE);
	}

	if (route.startsWith('/api/')) {
		if (!codeOk(req, url)) return notFound(res);

		if (route === '/api/config' && req.method === 'GET') {
			return sendJson(res, 200, {
				vapidPublicKey: vapid.publicKey,
				vapidEphemeral,
				// So the page can prove which build answered it, rather than assuming.
				buildSha: process.env.PROBE_BUILD_SHA || 'unset',
				serverTime: new Date().toISOString()
			});
		}

		if (route === '/api/subscribe' && req.method === 'POST') {
			let body;
			try {
				body = JSON.parse((await readBody(req)).toString('utf8'));
			} catch {
				return sendJson(res, 400, { error: 'expected JSON' });
			}
			const sub = body && body.subscription;
			if (!sub || !sub.endpoint || !sub.keys || !sub.keys.p256dh || !sub.keys.auth) {
				return sendJson(res, 400, { error: 'subscription must have endpoint and keys.p256dh and keys.auth' });
			}
			// Re-subscribing on every launch is plan risk 2's mitigation, so the same endpoint
			// arriving twice must update in place rather than pile up.
			let id = null;
			for (const [key, d] of devices) {
				if (d.subscription.endpoint === sub.endpoint) { id = key; break; }
			}
			if (!id) {
				if (devices.size >= MAX_DEVICES) {
					// Drop the oldest rather than refuse: a probe that stops working because a
					// test browser filled a slot is a probe that answers the wrong question.
					const oldest = [...devices.entries()].sort((a, b) => a[1].createdAt.localeCompare(b[1].createdAt))[0];
					if (oldest) devices.delete(oldest[0]);
				}
				id = crypto.randomUUID();
			}
			devices.set(id, {
				id,
				subscription: sub,
				createdAt: devices.get(id) ? devices.get(id).createdAt : new Date().toISOString(),
				lastSend: devices.get(id) ? devices.get(id).lastSend : null
			});
			log(`subscribed ${id.slice(0, 8)} via ${new URL(sub.endpoint).host}`);
			return sendJson(res, 200, { id, pushService: new URL(sub.endpoint).host });
		}

		if (route === '/api/test-push' && req.method === 'POST') {
			let body;
			try {
				body = JSON.parse((await readBody(req)).toString('utf8'));
			} catch {
				return sendJson(res, 400, { error: 'expected JSON' });
			}
			const id = body && body.id;
			if (!id || !devices.has(id)) return notFound(res);
			const delay = Math.min(Math.max(Number(body.delaySeconds) || 60, 0), 600);
			if (pending.has(id)) clearTimeout(pending.get(id));
			const timer = setTimeout(() => { deliver(id, ACCESS_CODE); }, delay * 1000);
			// A stray timer must never hold the process open past a shutdown.
			if (timer.unref) timer.unref();
			pending.set(id, timer);
			devices.get(id).lastSend = null;
			log(`scheduled push for ${id.slice(0, 8)} in ${delay}s`);
			return sendJson(res, 200, { scheduled: true, delaySeconds: delay, dueAt: new Date(Date.now() + delay * 1000).toISOString() });
		}

		if (route === '/api/status' && req.method === 'GET') {
			const id = url.searchParams.get('id');
			if (!id || !devices.has(id)) return notFound(res);
			return sendJson(res, 200, { id, pending: pending.has(id), lastSend: devices.get(id).lastSend });
		}

		if (route === '/api/forget' && req.method === 'POST') {
			let body = {};
			try { body = JSON.parse((await readBody(req)).toString('utf8')); } catch { /* an empty body is fine */ }
			const id = body && body.id;
			if (id && pending.has(id)) { clearTimeout(pending.get(id)); pending.delete(id); }
			const had = id ? devices.delete(id) : false;
			log(`forget ${String(id).slice(0, 8)} -> ${had ? 'deleted' : 'nothing to delete'}`);
			return sendJson(res, 200, { forgotten: had });
		}

		return notFound(res);
	}

	if (req.method !== 'GET' && req.method !== 'HEAD') return notFound(res);

	// The access code gates the PAGE, the manifest and the API — the three things that either
	// identify the probe or act on his behalf. It deliberately does NOT gate the stylesheet, the
	// scripts or the icons.
	//
	// Not laziness: a `<script src="/pcm.js">` in the markup is fetched by the browser without our
	// query string, and an `audioWorklet.addModule` inside a service-worker-controlled page is worse
	// again. Gating those would mean threading the code through every asset reference and having the
	// page die on whichever one was missed — a failure that would present as "the microphone does not
	// work", which is the one wrong answer this probe must not give. The assets are a stylesheet and
	// some arithmetic; they reveal nothing and do nothing.
	const gated = route === '/' || route === '/index.html';
	if (ACCESS_CODE && gated && !codeOk(req, url)) return notFound(res);
	return serveStatic(res, route);
});

server.listen(PORT, () => {
	log(`listening on http://localhost:${PORT}`);
	log(`VAPID public key: ${vapid.publicKey}`);
	if (vapidEphemeral) {
		log('');
		log('  WARNING: no VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY in the environment, so a pair was');
		log('  generated for this process only. Every subscription taken against it dies when this');
		log('  process restarts, and check 4 would then fail for a reason that has nothing to do');
		log('  with the phone. Fine for a local test; wrong for his phone.');
		log('  Run: npm run keys');
		log('');
	}
	if (!ACCESS_CODE) {
		log('  NOTE: PROBE_ACCESS_CODE is unset, so this origin is open to anyone who finds it.');
		log('  Set one before this is on a public URL.');
	}
});

// Railway stops a service with SIGTERM. Anything still pending is dropped on purpose — a probe
// that fires a scheduled push after a redeploy is a probe that lies about which build sent it.
for (const signal of ['SIGTERM', 'SIGINT']) {
	process.on(signal, () => {
		log(`${signal} — closing`);
		for (const timer of pending.values()) clearTimeout(timer);
		pending.clear();
		devices.clear();
		server.close(() => process.exit(0));
		setTimeout(() => process.exit(0), 3000).unref();
	});
}

module.exports = { server };

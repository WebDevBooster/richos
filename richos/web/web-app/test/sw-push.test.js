'use strict';

// THE SERVICE WORKER'S PUSH HANDLER, DRIVEN AS A WORKER.
//
// `node --test "test/*.test.js"`.
//
// The completion criterion for this slice says the push payload's `navigate` is validated *before
// it reaches `openWindow` or the page*. `test/inbound.test.js` proves the RULE; this file proves
// the WIRING — that the rule is actually on the path between the network and
// `clients.openWindow()`, which is a different claim and the one that would be quietly lost by an
// edit to `sw.js` alone.
//
// HOW, WITHOUT A BROWSER. `sw.js` is evaluated in a `node:vm` context that provides exactly what a
// service worker global provides and nothing else: `self` is the global, `importScripts` loads the
// real `lib/` modules into the same context, and every capability the handler reaches for —
// `registration.showNotification`, `clients.matchAll`, `clients.openWindow` — is a recorder. So the
// file under test is the shipped file, byte for byte, read off disk.
//
// A FRESH V8 CONTEXT HAS NO WEB GLOBALS. `URL` and `URLSearchParams` are Node/web globals rather
// than ECMAScript builtins, so they are injected deliberately — a worker has them, and
// `lib/inbound.js` parses with them.

const test = require('node:test');
const assert = require('node:assert');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

const APP_DIR = path.join(__dirname, '..');

/// A settings/messages store in memory, in the shape `lib/storage.js` exposes. Substituted AFTER
/// the worker loads, because the real one needs an IndexedDB and what is being tested here is the
/// decision, not the database.
function memoryStorage() {
	const settings = new Map();
	const rows = [];
	return {
		settings,
		rows,
		module: {
			async open() { return { fake: true, close() {} }; },
			settings: () => ({
				async get(key, fallback) { return settings.has(key) ? settings.get(key) : fallback; },
				async set(key, value) { settings.set(key, value); }
			}),
			messages: () => ({
				async put(row) { rows.push(row); },
				async trim() {}
			})
		}
	};
}

function loadWorker(options) {
	const opts = options || {};
	const origin = opts.origin || 'https://mm1.tail9a3b2.ts.net:8443';
	const listeners = {};
	const shown = [];
	const opened = [];
	const posted = [];
	const focused = [];
	const store = memoryStorage();

	const windows = (opts.windows || []).map((name) => ({
		name,
		focus: async () => { focused.push(name); },
		postMessage: (m) => posted.push({ to: name, message: m })
	}));

	const context = vm.createContext({
		// The web globals a worker has and a bare V8 context does not.
		URL,
		URLSearchParams,
		TextEncoder,
		console,
		setTimeout,
		clearTimeout
	});
	const self = vm.runInContext('globalThis', context);
	self.self = self;
	self.location = { origin, href: `${origin}/sw.js` };
	self.addEventListener = (name, fn) => { listeners[name] = fn; };
	self.caches = {
		open: async () => ({ put: async () => {}, match: async () => null }),
		keys: async () => [],
		delete: async () => true
	};
	self.fetch = async () => { throw new Error('the worker must not reach the network in this test'); };
	self.skipWaiting = async () => {};
	self.registration = {
		showNotification: async (title, o) => { shown.push({ title, options: o }); }
	};
	self.clients = {
		claim: async () => {},
		matchAll: async () => windows,
		openWindow: async (url) => { opened.push(url); }
	};
	self.navigator = {};
	self.importScripts = (...paths) => {
		for (const p of paths) {
			const file = path.join(APP_DIR, p.replace(/^\//, ''));
			vm.runInContext(fs.readFileSync(file, 'utf8'), context, { filename: file });
		}
	};

	const swFile = path.join(APP_DIR, 'sw.js');
	vm.runInContext(fs.readFileSync(swFile, 'utf8'), context, { filename: swFile });

	// The real rules stay; only the database is replaced.
	self.RichOSStorage = store.module;

	return { self, listeners, shown, opened, posted, focused, store, origin };
}

/// A `PushEvent` in the shape the handler reads it: `event.data.json()` and `waitUntil`.
async function push(worker, payload) {
	let held = null;
	worker.listeners.push({
		data: { json: () => payload },
		waitUntil: (p) => { held = p; }
	});
	await held;
}

/// A `NotificationEvent`, the same way.
async function clickNotification(worker, data) {
	let held = null;
	worker.listeners.notificationclick({
		notification: { close: () => {}, data },
		waitUntil: (p) => { held = p; }
	});
	await held;
}

// --------------------------------------------------------------------------------------------

test('the worker loads and wires its four handlers, with `lib/inbound.js` in scope', () => {
	const w = loadWorker();
	for (const name of ['install', 'activate', 'fetch', 'push', 'notificationclick']) {
		assert.strictEqual(typeof w.listeners[name], 'function', `no ${name} handler`);
	}
	// The import this slice added. If `sw.js` ever stops importing it, every check below would
	// still pass by throwing inside a `catch`, so it is asserted directly.
	assert.strictEqual(typeof w.self.RichOSInbound.validateNavigate, 'function');
});

test('an ordinary push opens the thread it names, and the link survives untouched', async () => {
	const w = loadWorker({ windows: [] });
	await push(w, {
		notification: { title: 'Rich', body: 'On it!', navigate: '/#thread=thr_5c1e&at=i4' },
		message: { id: 'm1', thread_id: 'thr_5c1e', cursor: 9, text: 'On it!' }
	});

	assert.strictEqual(w.shown.length, 1, 'WebKit revokes a subscription for a push that shows nothing');
	assert.strictEqual(w.shown[0].options.data.url, '/#thread=thr_5c1e&at=i4');
	assert.deepStrictEqual(w.store.rows.map((r) => r.id), ['m1'], 'the reply was not written for the train');

	await clickNotification(w, w.shown[0].options.data);
	assert.deepStrictEqual(w.opened, ['/#thread=thr_5c1e&at=i4']);
});

test('a hostile `navigate` never reaches `openWindow` or the page — it lands him on the app instead', async () => {
	for (const hostile of ['https://evil.example/', '//evil.example', '/#pair=K7QF2M9X', 'javascript:alert(1)', '/\t\t//evil.example']) {
		const w = loadWorker({ windows: ['the app'] });
		await push(w, { notification: { title: 'Rich', body: 'x', navigate: hostile } });

		assert.strictEqual(w.shown.length, 1, `${hostile}: no notification was shown`);
		assert.strictEqual(w.shown[0].options.data.url, '/', `${hostile} reached the notification`);
		// The page is told too, and it is told the safe value.
		assert.deepStrictEqual(w.posted.map((p) => p.message.type), ['push-message']);

		await clickNotification(w, w.shown[0].options.data);
		assert.deepStrictEqual(w.opened, [], `${hostile}: a window was opened rather than a focus`);
		assert.deepStrictEqual(w.posted.filter((p) => p.message.type === 'notification-clicked').map((p) => p.message.url),
			['/'], `${hostile} reached the page`);

		// AND THE REASON IS WRITTEN DOWN rather than dropped (plan §2 C).
		const refusal = w.store.settings.get('navigateRefusal');
		assert.ok(refusal, `${hostile}: refused with no reason recorded`);
		assert.strictEqual(refusal.value, hostile);
		assert.ok(refusal.reason, `${hostile}: a refusal with an empty reason`);
	}
});

test('a notification held by the system is re-validated when it is tapped, not trusted', async () => {
	// The handler above cannot have written this, but a notification outlives the worker that
	// showed it and is read back out of the system's own store — possibly by a later build.
	const w = loadWorker({ windows: [] });
	await clickNotification(w, { url: 'https://evil.example/' });
	assert.deepStrictEqual(w.opened, ['/'], 'a stored notification took the app to another origin');
});

test('an `api_base` on another origin is refused with a reason; the same-origin one is stored', async () => {
	const w = loadWorker();
	await push(w, {
		message: { id: 'm2', thread_id: 't', cursor: 1 },
		api_base: 'https://198.51.100.7:8443'
	});
	assert.strictEqual(w.store.settings.get('apiBase'), undefined, 'a cross-origin base was stored');
	assert.strictEqual(w.store.settings.get('apiBaseRefusal').reason, 'a different origin from the app');
	assert.strictEqual(w.store.settings.get('apiBaseRefusal').value, 'https://198.51.100.7:8443');

	// THE POSITIVE CONTROL. Without it this test passes against a worker that stores nothing at all.
	await push(w, { message: { id: 'm3', thread_id: 't', cursor: 2 }, api_base: w.origin });
	assert.strictEqual(w.store.settings.get('apiBase'), w.origin);
});

test('a push that carries no link and no address is the ordinary case, not a refusal', async () => {
	const w = loadWorker();
	await push(w, { message: { id: 'm4', thread_id: 't', cursor: 3, text: 'hello' } });
	assert.strictEqual(w.shown[0].options.data.url, '/');
	assert.strictEqual(w.store.settings.get('navigateRefusal'), undefined, 'silence was recorded as a refusal');
	assert.strictEqual(w.store.settings.get('apiBaseRefusal'), undefined, 'silence was recorded as a refusal');
});

test('an undecryptable payload still shows a notification, because WebKit revokes a subscription that does not', async () => {
	const w = loadWorker();
	let held = null;
	w.listeners.push({
		data: { json: () => { throw new SyntaxError('not JSON'); } },
		waitUntil: (p) => { held = p; }
	});
	await held;
	assert.strictEqual(w.shown.length, 1);
	assert.strictEqual(w.shown[0].title, 'Rich');
	assert.strictEqual(w.shown[0].options.data.url, '/');
});


test('reply previews default on, can be hidden and follow the current preference with the app closed',async()=>{
 const w=loadWorker();const payload={notification:{title:'Rich',body:'The supplier accepted £42,000.'}};
 await push(w,payload);assert.strictEqual(w.shown.at(-1).options.body,payload.notification.body);
 w.store.settings.set('notificationPreviews',false);
 await push(w,payload);assert.strictEqual(w.shown.at(-1).options.body,'Rich has replied.');
 w.store.settings.set('notificationPreviews',true);
 await push(w,{notification:{body:'x'.repeat(500)}});assert.strictEqual(w.shown.at(-1).options.body.length,240);
 w.self.RichOSStorage.open=async()=>{throw Error('storage unavailable');};
 await push(w,payload);assert.strictEqual(w.shown.at(-1).options.body,'Rich has replied.');
});

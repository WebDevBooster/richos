// WHAT THIS PHONE KEEPS, AND WHERE — one IndexedDB database, four stores, and no local storage.
//
// Four things have to survive the app being closed, and each one is here for a stated reason:
//
//   settings  the API base, the device id, the latest challenge, the thread he was last in. The API
//             base is DATA (plan §10.7) and the whole reachability seam rests on it being readable
//             at the next send rather than re-derived from the origin.
//   queue     messages he sent that his Mac has not accepted. This is the one store whose loss he
//             would actually notice, because losing it loses something he wrote.
//   messages  a VIEW of the last stretch of conversation, so opening the app away from the Mac
//             shows him Rich's reply instead of an empty screen (§2.4). It is never the record —
//             the ledger on his Mac is (§6) — and it is replaced by the Mac's rows on every
//             connection rather than merged with them.
//   keys      the device key pair. NON-EXTRACTABLE (§2.7), which is exactly why it lives here: a
//             `CryptoKey` can be stored in IndexedDB and used later without its private half ever
//             being readable by any script, including this one.
//
// WHY INDEXEDDB AND NOT LOCAL STORAGE. Three reasons and all of them are load-bearing: a voice note
// is ~32 KB per second of audio and local storage's practical ceiling is about five megabytes of
// TEXT, which a base64 note would eat in twenty seconds; local storage cannot hold a non-extractable
// key at all; and it is synchronous, so writing a note would block the frame he is watching.
//
// THE SERVICE WORKER USES THIS FILE TOO. A push arriving with the app closed writes Rich's reply
// into `messages` so it is there when he opens it — which means this module must not touch
// `window` or the DOM anywhere. It does not.
//
// Loads as a plain script (defines `globalThis.RichOSStorage`) and as a CommonJS module.

(function (root, factory) {
	const api = factory();
	if (typeof module === 'object' && module.exports) module.exports = api;
	root.RichOSStorage = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
	'use strict';

	const DB_NAME = 'richos-phone';
	const DB_VERSION = 1;
	const SETTINGS = 'settings';
	const QUEUE = 'queue';
	const MESSAGES = 'messages';
	const KEYS = 'keys';

	// How much conversation is kept for the train. Enough to open the app away from the Mac and read
	// the last exchange; not so much that the phone starts to feel like a second record of a
	// conversation it does not own.
	const MESSAGE_CACHE_LIMIT = 200;

	function request(req) {
		return new Promise((resolve, reject) => {
			req.onsuccess = () => resolve(req.result);
			req.onerror = () => reject(req.error);
		});
	}

	function done(tx) {
		return new Promise((resolve, reject) => {
			tx.oncomplete = () => resolve();
			tx.onerror = () => reject(tx.error);
			tx.onabort = () => reject(tx.error || new Error('the write was abandoned'));
		});
	}

	function open(indexedDBImpl) {
		const idb = indexedDBImpl || (typeof indexedDB !== 'undefined' ? indexedDB : null);
		if (!idb) return Promise.reject(new Error('this browser has no IndexedDB'));
		return new Promise((resolve, reject) => {
			const req = idb.open(DB_NAME, DB_VERSION);
			req.onupgradeneeded = () => {
				const db = req.result;
				if (!db.objectStoreNames.contains(SETTINGS)) db.createObjectStore(SETTINGS);
				if (!db.objectStoreNames.contains(QUEUE)) db.createObjectStore(QUEUE, { keyPath: 'clientId' });
				if (!db.objectStoreNames.contains(MESSAGES)) db.createObjectStore(MESSAGES, { keyPath: 'id' });
				if (!db.objectStoreNames.contains(KEYS)) db.createObjectStore(KEYS);
			};
			req.onsuccess = () => resolve(req.result);
			req.onerror = () => reject(req.error);
		});
	}

	function settings(db) {
		return {
			async get(key, fallback) {
				const tx = db.transaction(SETTINGS, 'readonly');
				const value = await request(tx.objectStore(SETTINGS).get(key));
				return value === undefined ? fallback : value;
			},
			async set(key, value) {
				const tx = db.transaction(SETTINGS, 'readwrite');
				tx.objectStore(SETTINGS).put(value, key);
				return done(tx);
			},
			async all() {
				const tx = db.transaction(SETTINGS, 'readonly');
				const store = tx.objectStore(SETTINGS);
				const keys = await request(store.getAllKeys());
				const values = await request(store.getAll());
				const out = {};
				keys.forEach((k, i) => { out[k] = values[i]; });
				return out;
			}
		};
	}

	/// The port `lib/queue.js` expects. Same three methods in the browser and in the tests, which is
	/// what lets the whole queue state machine be driven in Node.
	function queueStorage(db) {
		return {
			async all() {
				const tx = db.transaction(QUEUE, 'readonly');
				return request(tx.objectStore(QUEUE).getAll());
			},
			async put(item) {
				const tx = db.transaction(QUEUE, 'readwrite');
				// Structured-clone safe: a `Uint8Array` survives, but it is stored as a plain array
				// so the record is the same shape whether it was written by the page or read back
				// from a version of this app that did not exist yet.
				const record = Object.assign({}, item);
				if (record.bytes && record.bytes instanceof Uint8Array) record.bytes = Array.from(record.bytes);
				tx.objectStore(QUEUE).put(record);
				return done(tx);
			},
			async remove(clientId) {
				const tx = db.transaction(QUEUE, 'readwrite');
				tx.objectStore(QUEUE).delete(clientId);
				return done(tx);
			}
		};
	}

	function messages(db) {
		return {
			/// Called by the page on every merge AND by the service worker when a push arrives with
			/// the app closed. Both write the same shape.
			async put(rows) {
				const list = Array.isArray(rows) ? rows : [rows];
				if (!list.length) return;
				const tx = db.transaction(MESSAGES, 'readwrite');
				const store = tx.objectStore(MESSAGES);
				list.forEach((row) => { if (row && row.id) store.put(row); });
				return done(tx);
			},
			async recent(threadId, limit) {
				const tx = db.transaction(MESSAGES, 'readonly');
				const all = await request(tx.objectStore(MESSAGES).getAll());
				return all
					.filter((row) => !threadId || row.thread_id === threadId)
					.sort((a, b) => a.cursor - b.cursor)
					.slice(-(limit || MESSAGE_CACHE_LIMIT));
			},
			/// Keeps the cache from growing without end. Oldest first, by the Mac's cursor — never
			/// by anything this phone decided.
			async trim(limit) {
				const keep = limit || MESSAGE_CACHE_LIMIT;
				const tx = db.transaction(MESSAGES, 'readwrite');
				const store = tx.objectStore(MESSAGES);
				const all = await request(store.getAll());
				if (all.length <= keep) return done(tx);
				all.sort((a, b) => a.cursor - b.cursor).slice(0, all.length - keep)
					.forEach((row) => store.delete(row.id));
				return done(tx);
			},
			async clear() {
				const tx = db.transaction(MESSAGES, 'readwrite');
				tx.objectStore(MESSAGES).clear();
				return done(tx);
			}
		};
	}

	function keys(db) {
		return {
			/// The pair goes in as `CryptoKey` objects, not as exported bytes. The private half is
			/// non-extractable, so there is nothing to export even if a later edit tried.
			async save(pair) {
				const tx = db.transaction(KEYS, 'readwrite');
				tx.objectStore(KEYS).put(pair.privateKey, 'device-private');
				tx.objectStore(KEYS).put(pair.publicKey, 'device-public');
				return done(tx);
			},
			async load() {
				const tx = db.transaction(KEYS, 'readonly');
				const store = tx.objectStore(KEYS);
				const privateKey = await request(store.get('device-private'));
				const publicKey = await request(store.get('device-public'));
				if (!privateKey || !publicKey) return null;
				return { privateKey, publicKey };
			},
			async clear() {
				const tx = db.transaction(KEYS, 'readwrite');
				tx.objectStore(KEYS).clear();
				return done(tx);
			}
		};
	}

	/// Everything this phone holds, gone. Used when the Mac says it has forgotten this device: a
	/// credential that cannot be used again is a credential worth deleting, and a queue that can
	/// never drain is worth deleting with it.
	async function forgetEverything(db) {
		for (const name of [SETTINGS, QUEUE, MESSAGES, KEYS]) {
			const tx = db.transaction(name, 'readwrite');
			tx.objectStore(name).clear();
			await done(tx);
		}
	}

	// -------------------------------------------------------------------------------------------
	// The device key, and the signer the API module asks for
	// -------------------------------------------------------------------------------------------

	function base64url(bytes) {
		let binary = '';
		const view = new Uint8Array(bytes);
		for (let i = 0; i < view.length; i++) binary += String.fromCharCode(view[i]);
		return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
	}

	function hex(buffer) {
		return Array.from(new Uint8Array(buffer)).map((b) => b.toString(16).padStart(2, '0')).join('');
	}

	/// P-256, and NON-EXTRACTABLE — the `false` below is the whole point of the choice (§2.7, and
	/// the rule that no extractable credential sits anywhere). The public half is exportable
	/// regardless, which is what gets registered with the Mac.
	async function generateDeviceKey(subtle) {
		return subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']);
	}

	function createSigner(subtle, pair, state) {
		return {
			get deviceId() { return state.deviceId; },
			async sign(input) {
				const bytes = new TextEncoder().encode(input);
				const signature = await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, bytes);
				return base64url(signature);
			},
			async sha256Hex(payload) {
				const bytes = typeof payload === 'string' ? new TextEncoder().encode(payload)
					: payload instanceof Uint8Array ? payload
						: new Uint8Array(payload);
				return hex(await subtle.digest('SHA-256', bytes));
			}
		};
	}

	return {
		DB_NAME, DB_VERSION, MESSAGE_CACHE_LIMIT,
		open, settings, queueStorage, messages, keys, forgetEverything,
		generateDeviceKey, createSigner, base64url, hex
	};
});

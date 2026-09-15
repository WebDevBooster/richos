/**
 * RichOS extension — IndexedDB helpers (shared core).
 *
 * IndexedDB is available in BOTH the service worker and the offscreen document, which is
 * what makes crash recovery possible: the offscreen document writes chunks, and after a
 * service-worker restart the worker can still see exactly what was written.
 *
 * Durability note (honest): a chunk is safe once its transaction completes. A hard OS/power
 * loss between `put` and `oncomplete` can still lose that one chunk — bounded by `chunkMs`.
 */

import { DB } from './constants.js';

/** @type {Promise<IDBDatabase>|null} */
let dbPromise = null;

/** @returns {Promise<IDBDatabase>} */
export function openDb() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB.name, DB.version);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(DB.stores.chunks)) {
        const store = db.createObjectStore(DB.stores.chunks, { keyPath: ['sessionId', 'seq'] });
        store.createIndex('bySession', 'sessionId', { unique: false });
      }
      if (!db.objectStoreNames.contains(DB.stores.sessions)) {
        db.createObjectStore(DB.stores.sessions, { keyPath: 'sessionId' });
      }
      if (!db.objectStoreNames.contains(DB.stores.health)) {
        const store = db.createObjectStore(DB.stores.health, { keyPath: ['sessionId', 't'] });
        store.createIndex('bySession', 'sessionId', { unique: false });
      }
      if (!db.objectStoreNames.contains(DB.stores.captions)) {
        const store = db.createObjectStore(DB.stores.captions, { keyPath: ['sessionId', 'seq'] });
        store.createIndex('bySession', 'sessionId', { unique: false });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

/**
 * @param {IDBTransaction} tx
 * @returns {Promise<void>}
 */
function done(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

/**
 * Write one record and WAIT for the transaction to commit. Callers must await this —
 * "fire and forget" would silently widen the crash window.
 * @param {string} storeName
 * @param {any} value
 */
export async function put(storeName, value) {
  const db = await openDb();
  const tx = db.transaction(storeName, 'readwrite');
  tx.objectStore(storeName).put(value);
  await done(tx);
}

/**
 * @param {string} storeName
 * @param {any[]} values
 */
export async function putAll(storeName, values) {
  if (!values.length) return;
  const db = await openDb();
  const tx = db.transaction(storeName, 'readwrite');
  const store = tx.objectStore(storeName);
  for (const v of values) store.put(v);
  await done(tx);
}

/**
 * @param {string} storeName
 * @param {IDBValidKey} key
 * @returns {Promise<any>}
 */
export async function get(storeName, key) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const req = db.transaction(storeName, 'readonly').objectStore(storeName).get(key);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

/**
 * @param {string} storeName
 * @param {string} [indexName]
 * @param {IDBKeyRange|IDBValidKey} [query]
 * @returns {Promise<any[]>}
 */
export async function getAll(storeName, indexName, query) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const store = db.transaction(storeName, 'readonly').objectStore(storeName);
    const source = indexName ? store.index(indexName) : store;
    const req = source.getAll(query);
    req.onsuccess = () => resolve(req.result || []);
    req.onerror = () => reject(req.error);
  });
}

/**
 * Delete every record of a session from a store that has a `bySession` index.
 * @param {string} storeName
 * @param {string} sessionId
 */
export async function deleteBySession(storeName, sessionId) {
  const db = await openDb();
  const tx = db.transaction(storeName, 'readwrite');
  const index = tx.objectStore(storeName).index('bySession');
  const req = index.openKeyCursor(IDBKeyRange.only(sessionId));
  req.onsuccess = () => {
    const cursor = req.result;
    if (!cursor) return;
    tx.objectStore(storeName).delete(cursor.primaryKey);
    cursor.continue();
  };
  await done(tx);
}

/**
 * @param {string} storeName
 * @param {IDBValidKey} key
 */
export async function del(storeName, key) {
  const db = await openDb();
  const tx = db.transaction(storeName, 'readwrite');
  tx.objectStore(storeName).delete(key);
  await done(tx);
}

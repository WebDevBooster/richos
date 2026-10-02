import assert from 'node:assert/strict';
const store = { 'richos.settings': { core: { notifyOnFailure: true, alertSound: false } } };
const notifications = new Map();
let creations = 0;
globalThis.chrome = {
  storage: { local: { async get(key) { return structuredClone({ [key]: store[key] }); }, async set(values) { Object.assign(store, structuredClone(values)); } } },
  runtime: { getURL: x => x },
  notifications: { async create(id, options) { creations++; notifications.set(id, options); }, async clear(id) { notifications.delete(id); }, async getAll() { return Object.fromEntries(notifications); } },
};
let alerts = await import('../core/alerts.js');
const incident = { code: 'needs-invocation', title: 'Arm capture', message: 'No audio', sessionId: 'session-A' };
await Promise.all(Array.from({ length: 21 }, () => alerts.raiseAlert(incident)));
assert.equal(creations, 1, 'unchanged failure must notify once, even under concurrent watchdog evaluations');
alerts = await import('../core/alerts.js?worker-restart');
await alerts.raiseAlert(incident);
assert.equal(creations, 1, 'worker eviction must not repeat unchanged failure');
await alerts.raiseAlert({ ...incident, code: 'mic-lost', message: 'Microphone gone' });
assert.equal(notifications.size, 1, 'different failures must share one desktop surface');
await alerts.resolveAlerts(['needs-invocation', 'mic-lost']);
assert.equal(notifications.size, 0, 'resolved failures must clear the notification');
await alerts.raiseAlert(incident);
assert.equal(creations, 3, 'a failure that recurs after recovery must notify again');
assert.equal((await alerts.getAlertLog()).length, 3, 'durable log must keep distinct incident onsets');
await alerts.resetAlertThrottle();
assert.equal(notifications.size, 0);
console.log('PASS persistent incident deduplication, single notification and resolution');

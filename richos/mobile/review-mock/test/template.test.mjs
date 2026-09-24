// The deploy template is held to the same rules as the code: every routed name is the access page
// or a configured review host, none is a wildcard, none is in richos.ceo, logs and public
// addresses are off, and its variables pass the Worker's own configuration check.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readConfig, inForbiddenZone } from '../src/config.mjs';

const toml = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wrangler.example.toml'), 'utf8');
const topLevel = toml.split(/^\[/m)[0];
const value = (name) => (toml.match(new RegExp(`^${name} = (?:"([^"]*)"|'([^']*)')`, 'm')) || []).slice(1).find((v) => v !== undefined);

test('the template routes exactly the access page and the review hosts, by custom domain only', () => {
	const patterns = [...topLevel.matchAll(/\{ pattern = "([^"]+)", custom_domain = true \}/g)].map((m) => m[1]);
	assert.ok(patterns.length >= 2, 'routes are top-level keys, above the first table');
	const hosts = JSON.parse(value('REVIEW_HOSTS')).map((h) => h.hostname);
	assert.deepEqual([...patterns].sort(), [value('ACCESS_HOSTNAME'), ...hosts].sort());
	for (const p of patterns) {
		assert.ok(!p.includes('*') && !p.includes('/'), `${p} is one name, not a pattern`);
		assert.equal(inForbiddenZone(p), false, `${p} is outside richos.ceo`);
	}
	assert.match(topLevel, /^workers_dev = false$/m);
	assert.match(topLevel, /^preview_urls = false$/m);
	assert.match(toml, /^\[observability\]\nenabled = false$/m);
	assert.match(toml, /^new_sqlite_classes = \["ReviewHost"\]$/m);
});

test('the template variables pass the Worker configuration check once the secrets are added', () => {
	const env = {
		ACCESS_HOSTNAME: value('ACCESS_HOSTNAME'), REVIEW_HOSTS: value('REVIEW_HOSTS'), PAIRING_WORDS: value('PAIRING_WORDS'), CONNECT_ORIGIN: value('CONNECT_ORIGIN'),
		REVIEW_PASSWORD_HASHES: JSON.stringify(Object.fromEntries(JSON.parse(value('REVIEW_HOSTS')).map((h) => [h.username, 'pbkdf2-sha256$100000$AAAAAAAAAAAAAAAAAAAAAA$AAAA']))),
		SESSION_KEY: Buffer.alloc(32, 1).toString('base64url'), HOSTS: { idFromName() {} }, LOGIN_LIMIT: { limit() {} }
	};
	const read = readConfig(env);
	assert.equal(read.ok, true, JSON.stringify(read.problems));
});

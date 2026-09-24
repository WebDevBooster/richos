// The operator CLI: secrets land outside Git in a protected folder, nothing secret is printed,
// and what it writes is exactly what the Worker's configuration accepts.

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, statSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readConfig } from '../src/config.mjs';
import { hostIdentity } from '../src/push.mjs';
import { verifyPassword } from '../src/session.mjs';
import { newPassword, enclosingRepository } from '../bin/review-secrets.mjs';

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'review-secrets.mjs');
const HOSTS = [
	{ hostname: 'review-a.example.com', label: 'Apple App Review', username: 'apple-review' },
	{ hostname: 'review-b.example.com', label: 'Google Play review', username: 'google-review' }
];

function scratch(t) {
	const dir = mkdtempSync(join(tmpdir(), 'richconnect-review-secrets-'));
	t.after(() => rmSync(dir, { recursive: true, force: true }));
	assert.equal(enclosingRepository(dir), null, 'the scratch folder must itself be outside Git for this test');
	const hostsFile = join(dir, 'hosts.json');
	writeFileSync(hostsFile, JSON.stringify(HOSTS));
	return { dir, hostsFile };
}

const run = (...argv) => execFileSync(process.execPath, [CLI, ...argv], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

test('create: protected files outside Git, public ids printed, secrets never printed, and the Worker accepts them', async (t) => {
	const { dir, hostsFile } = scratch(t);
	const out = join(dir, 'review-secrets');
	const printed = run('create', '--hosts', hostsFile, '--out', out, '--access', 'review.example.com');
	assert.equal(statSync(out).mode & 0o777, 0o700);
	for (const name of ['worker-secrets.json', 'review-credentials.json']) assert.equal(statSync(join(out, name)).mode & 0o777, 0o600, name);
	const secrets = JSON.parse(readFileSync(join(out, 'worker-secrets.json'), 'utf8'));
	const creds = JSON.parse(readFileSync(join(out, 'review-credentials.json'), 'utf8'));
	for (const c of creds.credentials) {
		assert.ok(!printed.includes(c.password), 'no password is printed');
		assert.equal(await verifyPassword(c.password, JSON.parse(secrets.REVIEW_PASSWORD_HASHES)[c.username]), true);
	}
	assert.ok(!printed.includes(secrets.SESSION_KEY), 'the session key is not printed');
	const keys = JSON.parse(secrets.REVIEW_HOST_KEYS);
	for (const h of HOSTS) {
		assert.ok(!printed.includes(keys[h.hostname]), 'no host key is printed');
		const { id } = await hostIdentity(keys[h.hostname]);
		assert.ok(printed.includes(`INSERT OR IGNORE INTO allowed_hosts(id) VALUES ('${id}');`), 'the admission SQL names each public id');
	}
	const env = { ACCESS_HOSTNAME: 'review.example.com', REVIEW_HOSTS: JSON.stringify(HOSTS), ...secrets, HOSTS: { idFromName() {} }, LOGIN_LIMIT: { limit() {} } };
	const read = readConfig(env);
	assert.equal(read.ok, true, JSON.stringify(read.problems));
	assert.ok(read.config.hostKeys);
	assert.equal(run('ids', '--secrets', join(out, 'worker-secrets.json')).trim().split('\n').length, HOSTS.length);
});

test('create: refuses a folder inside a Git repository, a folder that is not empty, and the richos.ceo zone', (t) => {
	const { dir, hostsFile } = scratch(t);
	const inside = join(dirname(fileURLToPath(import.meta.url)), 'never-created');
	assert.throws(() => run('create', '--hosts', hostsFile, '--out', inside), /inside the Git repository/s);
	const full = join(dir, 'full');
	mkdirSync(full);
	writeFileSync(join(full, 'x'), 'x');
	assert.throws(() => run('create', '--hosts', hostsFile, '--out', full), /not empty/s);
	const zone = join(dir, 'zone.json');
	writeFileSync(zone, JSON.stringify([{ ...HOSTS[0], hostname: 'review.richos.ceo' }]));
	assert.throws(() => run('create', '--hosts', zone, '--out', join(dir, 'z')), /richos\.ceo zone/s);
});

test('create --push off writes no host keys, and the Worker then offers no push', (t) => {
	const { dir, hostsFile } = scratch(t);
	const out = join(dir, 'no-push');
	const printed = run('create', '--hosts', hostsFile, '--out', out, '--push', 'off');
	assert.match(printed, /push is off/);
	const secrets = JSON.parse(readFileSync(join(out, 'worker-secrets.json'), 'utf8'));
	assert.equal(secrets.REVIEW_HOST_KEYS, undefined);
});

test('passwords are four groups of four from an unambiguous alphabet', () => {
	for (let i = 0; i < 50; i++) assert.match(newPassword(), /^[2-9a-hjkmnp-z]{4}(-[2-9a-hjkmnp-z]{4}){3}$/);
});

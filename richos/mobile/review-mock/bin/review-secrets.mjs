#!/usr/bin/env node
// Create everything secret the review Worker needs, in a protected folder OUTSIDE every Git
// repository, and print only what is public.
//
//   node richos/mobile/review-mock/bin/review-secrets.mjs create --hosts <review-hosts.json> --out <new folder>
//   node richos/mobile/review-mock/bin/review-secrets.mjs ids --secrets <folder>/worker-secrets.json
//
// `<review-hosts.json>` is the REVIEW_HOSTS value: [{ "hostname", "label", "username" }, …].
//
// `create` writes, in a new mode-0700 folder:
//   worker-secrets.json       (0600) the three Worker secrets, for `wrangler secret bulk`
//   review-credentials.json   (0600) each reviewer's username and password, for the store notes
// and prints each review host's Connect host id (public: the SHA-256 of its public key) with the
// SQL that admits it to the Connect Worker. It never prints a password or a key.

import { mkdirSync, readdirSync, existsSync, writeFileSync, readFileSync, statSync, chmodSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { hashPassword } from '../src/session.mjs';
import { hostIdentity } from '../src/push.mjs';
import { inForbiddenZone } from '../src/config.mjs';

const ALPHABET = '23456789abcdefghjkmnpqrstuvwxyz';

/** A password a reviewer can type from the notes: 4 groups of 4, about 79 bits. */
export function newPassword(bytes = randomBytes(16)) {
	const chars = Array.from(bytes, (b) => ALPHABET[b % ALPHABET.length]);
	return [0, 4, 8, 12].map((i) => chars.slice(i, i + 4).join('')).join('-');
}

/** The Git work tree that contains `path`, or null. Walks up from the nearest existing folder. */
export function enclosingRepository(path) {
	let dir = resolve(path);
	while (!existsSync(dir)) dir = dirname(dir);
	for (;;) {
		if (existsSync(join(dir, '.git'))) return dir;
		const parent = dirname(dir);
		if (parent === dir) return null;
		dir = parent;
	}
}

function args(argv) {
	const out = { _: [] };
	for (let i = 0; i < argv.length; i++) {
		if (argv[i].startsWith('--')) out[argv[i].slice(2)] = argv[i + 1], i++;
		else out._.push(argv[i]);
	}
	return out;
}

function readHosts(file) {
	const hosts = JSON.parse(readFileSync(file, 'utf8'));
	if (!Array.isArray(hosts) || !hosts.length) throw new Error('the hosts file must be a non-empty JSON array');
	for (const h of hosts) {
		if (!h || typeof h.hostname !== 'string' || typeof h.username !== 'string' || typeof h.label !== 'string') throw new Error('every host needs hostname, label and username');
		if (inForbiddenZone(h.hostname.toLowerCase())) throw new Error(`${h.hostname} is in the richos.ceo zone, which the review service never uses (rule M2)`);
		if (!/^[a-z0-9-]{1,40}$/.test(h.username)) throw new Error(`username ${JSON.stringify(h.username)} must be 1 to 40 of a-z, 0-9 and hyphen`);
	}
	return hosts;
}

/** Create the secrets folder. Returns what was printed, for the tests. */
export async function create({ hostsFile, out, accessHostname = null, withPush = true }) {
	const hosts = readHosts(hostsFile);
	const folder = resolve(out);
	const repository = enclosingRepository(folder);
	if (repository) throw new Error(`refusing to write secrets inside the Git repository at ${repository}; choose a folder outside every repository`);
	if (existsSync(folder) && readdirSync(folder).length) throw new Error(`${folder} is not empty; choose a new folder so nothing is overwritten`);
	mkdirSync(folder, { recursive: true, mode: 0o700 });
	chmodSync(folder, 0o700);
	const credentials = [], hashes = {}, keys = {}, admitted = [];
	for (const h of hosts) {
		const password = newPassword();
		credentials.push({ label: h.label, hostname: h.hostname, username: h.username, password });
		hashes[h.username] = await hashPassword(password);
		if (withPush) {
			const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
			keys[h.hostname] = privateKey.export({ format: 'der', type: 'pkcs8' }).toString('base64url');
			admitted.push({ hostname: h.hostname, id: (await hostIdentity(keys[h.hostname])).id });
		}
	}
	const secrets = { REVIEW_PASSWORD_HASHES: JSON.stringify(hashes), SESSION_KEY: randomBytes(32).toString('base64url') };
	if (withPush) secrets.REVIEW_HOST_KEYS = JSON.stringify(keys);
	writeFileSync(join(folder, 'worker-secrets.json'), JSON.stringify(secrets, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
	writeFileSync(join(folder, 'review-credentials.json'), JSON.stringify({ access_page: accessHostname ? `https://${accessHostname}/` : null, credentials }, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
	const lines = [`Wrote ${join(folder, 'worker-secrets.json')} and ${join(folder, 'review-credentials.json')} (mode 0600, folder 0700).`];
	if (withPush) {
		lines.push('', 'Connect host ids to admit (public values):');
		for (const a of admitted) lines.push(`  ${a.hostname}  ${a.id}`);
		lines.push('', 'SQL for the Connect D1 database (richos-connect):');
		for (const a of admitted) lines.push(`  INSERT OR IGNORE INTO allowed_hosts(id) VALUES ('${a.id}');`);
	} else {
		lines.push('', 'No host keys were created: push is off for this deployment.');
	}
	return lines.join('\n');
}

/** Print the public host ids of an existing secrets file. */
export async function ids(secretsFile) {
	const secrets = JSON.parse(readFileSync(secretsFile, 'utf8'));
	if (!secrets.REVIEW_HOST_KEYS) return 'This deployment has no host keys (push is off).';
	const keys = JSON.parse(secrets.REVIEW_HOST_KEYS);
	const lines = [];
	for (const [hostname, key] of Object.entries(keys)) lines.push(`${hostname}  ${(await hostIdentity(key)).id}`);
	return lines.join('\n');
}

async function main() {
	const a = args(process.argv.slice(2));
	const command = a._[0];
	try {
		if (command === 'create' && a.hosts && a.out) {
			console.log(await create({ hostsFile: a.hosts, out: a.out, accessHostname: a.access || null, withPush: a.push !== 'off' }));
		} else if (command === 'ids' && a.secrets) {
			if ((statSync(a.secrets).mode & 0o077) !== 0) console.error('Warning: the secrets file is readable by other users; run chmod 600 on it.');
			console.log(await ids(a.secrets));
		} else {
			console.error('usage: review-secrets.mjs create --hosts <review-hosts.json> --out <new folder> [--access <access hostname>] [--push off]\n       review-secrets.mjs ids --secrets <worker-secrets.json>');
			process.exitCode = 2;
		}
	} catch (error) {
		console.error(`review-secrets: ${error.message}`);
		process.exitCode = 1;
	}
}

if (import.meta.url === `file://${process.argv[1]}`) await main();

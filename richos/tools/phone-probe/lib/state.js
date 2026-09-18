'use strict';

// Where the probe's private state lives — and it is never the repository.
//
// The certificate authority's private key is a live credential. This repository is published, and
// this project's own write-time secret scanner would refuse a commit containing one, correctly. So
// every key, certificate and profile this tool generates goes under one directory outside every
// checkout, mode 0700, and the tool prints that path so nothing it leaves behind is a mystery.
//
// It is DURABLE state, not scratch: the whole point is that the CEO trusts the root on his phone
// once and it keeps working tomorrow. It is still state a person must be able to delete in one
// move, which `bin/make-local-ca.js --forget` does, and which the README names.

const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');

// `PROBE_STATE_DIR` exists so the tests can point at a temp directory and delete it afterwards
// rather than writing into the real one.
function stateDir() {
	if (process.env.PROBE_STATE_DIR) return path.resolve(process.env.PROBE_STATE_DIR);
	if (process.platform === 'darwin') {
		return path.join(os.homedir(), 'Library', 'Application Support', 'RichOS', 'phone-probe');
	}
	// Not the target platform — the CEO's Mac is — but a sane answer beats a crash for anyone
	// reading this repository on Linux.
	const base = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');
	return path.join(base, 'richos', 'phone-probe');
}

function tlsDir() { return path.join(stateDir(), 'tls'); }

function ensureDir(dir) {
	fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	// mkdir's mode is masked by umask, so it is set explicitly afterwards rather than hoped for.
	fs.chmodSync(dir, 0o700);
	return dir;
}

// A private key must not be group- or world-readable. Node has no atomic "create private", so the
// mode is passed at open time — writing then chmod'ing leaves a window where it is readable.
function writePrivate(file, contents) {
	ensureDir(path.dirname(file));
	fs.writeFileSync(file, contents, { mode: 0o600 });
	fs.chmodSync(file, 0o600);
	return file;
}

function writePublic(file, contents) {
	ensureDir(path.dirname(file));
	fs.writeFileSync(file, contents, { mode: 0o644 });
	return file;
}

const paths = () => ({
	stateDir: stateDir(),
	tlsDir: tlsDir(),
	caCert: path.join(tlsDir(), 'richos-local-ca.crt'),
	caKey: path.join(tlsDir(), 'richos-local-ca.key'),
	caProfile: path.join(tlsDir(), 'richos-local-ca.mobileconfig'),
	leafCert: path.join(tlsDir(), 'server.crt'),
	leafKey: path.join(tlsDir(), 'server.key'),
	meta: path.join(tlsDir(), 'meta.json'),
	// The VAPID pair. It lives here for the same reason the certificate does: on a Mac-hosted probe
	// there IS a durable place to put it, and a pair that dies with the process takes every push
	// subscription with it — which would fail check 4 for a reason that has nothing to do with the
	// phone. This was unavoidable when the probe was a stateless hosted service; it is not now.
	vapid: path.join(stateDir(), 'vapid.json')
});

module.exports = { stateDir, tlsDir, ensureDir, writePrivate, writePublic, paths };

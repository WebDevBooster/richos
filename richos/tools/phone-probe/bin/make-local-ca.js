#!/usr/bin/env node
'use strict';

// Mint the local certificate authority, or report the one that already exists.
//
//   node bin/make-local-ca.js              what exists, or create it if it does not
//   node bin/make-local-ca.js --reissue    keep the root, issue a fresh server certificate
//   node bin/make-local-ca.js --forget     delete everything this tool has written
//   node bin/make-local-ca.js --qr         also write the two QR images and print one
//
// `npm start` does all of this itself, so this command exists for three narrower jobs: seeing what
// is on disk without starting a server, reissuing after the Mac's address changes, and undoing the
// whole thing in one move.
//
// THE ROOT IS NEVER SILENTLY REGENERATED. Trusting it on the iPhone is a fifteen-tap operation by
// hand; throwing that away without being asked would present as "HTTPS stopped working for no
// reason". `--forget` is the only thing here that can destroy it, and it says what that costs.

const fs = require('node:fs');
const { ensureCertificates } = require('../lib/tls-setup.js');
const localnames = require('../lib/localnames.js');
const state = require('../lib/state.js');
const qr = require('../lib/qr.js');

const args = process.argv.slice(2);
const has = (flag) => args.includes(flag);
const out = (line = '') => process.stdout.write(`${line}\n`);

const HTTPS_PORT = Number(process.env.PROBE_HTTPS_PORT || 8788);
const TRUST_PORT = Number(process.env.PROBE_TRUST_PORT || 8787);

if (has('--help') || has('-h')) {
	out(fs.readFileSync(__filename, 'utf8').split('\n').slice(2, 18).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
	process.exit(0);
}

const paths = state.paths();

if (has('--forget')) {
	// Deleting the directory is the easy half. Saying what is left behind on the phone is the half
	// that matters: a trusted root nobody can find is worse than one that is documented.
	fs.rmSync(paths.tlsDir, { recursive: true, force: true });
	out(`Deleted ${paths.tlsDir}`);
	out('');
	out('STILL ON THE PHONE, and this command cannot reach it: the configuration profile you');
	out('installed. Remove it under Settings, General, VPN & Device Management, tap the RichOS');
	out('profile, Remove Profile. Until you do, the iPhone trusts a certificate authority whose');
	out('private key no longer exists — harmless, because nothing can sign with it any more, and');
	out('still worth deleting.');
	process.exit(0);
}

const result = ensureCertificates({ log: (line) => out(`  ${line}`), forceLeaf: has('--reissue') });

out('');
out('THE LOCAL CERTIFICATE AUTHORITY');
out(`  state directory   ${paths.tlsDir}`);
out(`  root certificate  ${paths.caCert}`);
out(`  profile for iOS   ${paths.caProfile}`);
out(`  SHA-256           ${result.meta.caFingerprintSha256}`);
out(`  root valid to     ${result.meta.caNotAfter}`);
out('');
out('THE SERVER CERTIFICATE');
out(`  names             ${result.meta.leafSubjectAltName}`);
out(`  valid to          ${result.meta.leafNotAfter}`);
out(`  public-key pin    ${result.meta.leafSpkiPinSha256}`);
out('');

const host = localnames.primaryName();
const addresses = localnames.lanAddresses();
const trustUrl = `http://${host}:${TRUST_PORT}/`;
const httpsUrl = `https://${host}:${HTTPS_PORT}/`;

out('THE TWO URLS');
out(`  trust step (plain HTTP, because the phone cannot trust HTTPS yet)   ${trustUrl}`);
out(`  the probe itself (HTTPS, once the root is trusted)                  ${httpsUrl}`);
if (addresses.length) {
	out(`  if the .local name does not resolve, by address                     http://${addresses[0].address}:${TRUST_PORT}/`);
}
out('');

if (result.actions.length) {
	out(`Changed: ${result.actions.join('; ')}.`);
} else {
	out('Nothing to do — the root and the server certificate on disk already cover every name.');
}

if (has('--qr')) {
	const trustQr = qr.toPng(trustUrl, { scale: 10 });
	const httpsQr = qr.toPng(httpsUrl, { scale: 10 });
	const trustFile = `${paths.tlsDir}/qr-trust-step.png`;
	const httpsFile = `${paths.tlsDir}/qr-probe.png`;
	state.writePublic(trustFile, trustQr.png);
	state.writePublic(httpsFile, httpsQr.png);
	out('');
	out(`Wrote ${trustFile}`);
	out(`Wrote ${httpsFile}`);
	out('');
	out(`Point the iPhone camera at this to start the trust step (${trustUrl}):`);
	out('');
	out(qr.toAnsi(trustUrl).text);
	out('');
}

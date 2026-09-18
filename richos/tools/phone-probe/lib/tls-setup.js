'use strict';

// Bootstrap the local certificate authority, and keep it usable as the Mac moves around a network.
//
// THE ONE RULE THIS FILE EXISTS TO ENFORCE: the ROOT is generated once and never again unless it is
// deleted on purpose. The CEO trusts it on his iPhone by hand — a fifteen-tap operation — and
// regenerating it would silently invalidate that work and present as "HTTPS stopped working". The
// LEAF is cheap and is reissued freely: a new DHCP lease, a different Wi-Fi, a renamed Mac all
// change the names it has to cover, and reissuing it from the SAME root means the phone needs no
// second trust step.
//
// So there are exactly two reasons to write anything here:
//   - no root exists yet (first run)
//   - a root exists, and the leaf does not cover the names this Mac now answers on

const fs = require('node:fs');
const crypto = require('node:crypto');
const { createCertificateAuthority, createServerCertificate } = require('./x509.js');
const { caProfile } = require('./mobileconfig.js');
const state = require('./state.js');
const localnames = require('./localnames.js');

function readIfPresent(file) {
	try { return fs.readFileSync(file, 'utf8'); } catch { return null; }
}

function fingerprint(pem) {
	const cert = new crypto.X509Certificate(pem);
	return crypto.createHash('sha256').update(cert.raw).digest('hex').toUpperCase().replace(/(..)(?=.)/g, '$1:');
}

// A certificate is usable if it parses, is inside its validity window with a month of room, and
// covers every name we need. "A month of room" so a probe started today does not expire mid-walk.
function leafCovers(leafPem, names) {
	if (!leafPem) return { ok: false, why: 'no leaf certificate yet' };
	let cert;
	try { cert = new crypto.X509Certificate(leafPem); } catch (err) { return { ok: false, why: `unreadable: ${err.message}` }; }
	const soon = Date.now() + 30 * 24 * 60 * 60 * 1000;
	if (new Date(cert.validTo).getTime() < soon) return { ok: false, why: `expires ${cert.validTo}` };
	const missing = names.filter((n) => {
		// checkHost for a name, checkIP for an address — asking the wrong one of a certificate
		// always answers no, which would reissue the leaf on every boot.
		const isIp = /^\d+\.\d+\.\d+\.\d+$/.test(n);
		return isIp ? !cert.checkIP(n) : !cert.checkHost(n);
	});
	if (missing.length) return { ok: false, why: `does not cover ${missing.join(', ')}` };
	return { ok: true, why: 'covers every name and is in date' };
}

/**
 * Make sure a root and a matching leaf exist on disk, and return everything the server needs.
 *
 * @param {{ names?: string[], log?: (line: string) => void, forceLeaf?: boolean }} [options]
 */
function ensureCertificates(options = {}) {
	const log = options.log || (() => {});
	const p = state.paths();
	state.ensureDir(p.tlsDir);

	const names = options.names || localnames.certificateNames();
	const actions = [];

	let caCertPem = readIfPresent(p.caCert);
	let caKeyPem = readIfPresent(p.caKey);

	// "RichOS on MM1", not "RichOS Local CA". This string is what iOS puts on TWO screens he has to
	// find his way through — the profile list, and the switch under Certificate Trust Settings — and
	// the trust page's instructions quote it. Naming the Mac also tells two Macs apart, which a
	// generic name cannot.
	const caCommonName = `RichOS on ${localnames.displayHostName()}`;

	if (!caCertPem || !caKeyPem) {
		const ca = createCertificateAuthority({ commonName: caCommonName });
		state.writePublic(p.caCert, ca.certPem);
		state.writePrivate(p.caKey, ca.keyPem);
		caCertPem = ca.certPem;
		caKeyPem = ca.keyPem;
		actions.push('created the root certificate authority');
		log(`created a new certificate authority, valid to ${new Date(ca.notAfter).toUTCString()}`);
	}

	// The profile is regenerated whenever it is missing or stale — it is derived from the root, so it
	// carries no state of its own and rewriting it can never invalidate the phone's trust.
	const caCert = new crypto.X509Certificate(caCertPem);
	// The name is read back out of the certificate rather than re-derived: an existing root keeps
	// whatever name it was born with, and the profile must agree with the label iOS will show.
	const certCommonName = (/CN=([^\n]+)/.exec(caCert.subject) || [null, caCommonName])[1].trim();
	const profile = caProfile({ certDer: caCert.raw, commonName: certCommonName, hostNames: names });
	const existingProfile = readIfPresent(p.caProfile);
	if (existingProfile !== profile) {
		state.writePublic(p.caProfile, profile);
		actions.push(existingProfile ? 'refreshed the configuration profile' : 'wrote the configuration profile');
	}

	let leafCertPem = readIfPresent(p.leafCert);
	let leafKeyPem = readIfPresent(p.leafKey);
	const verdict = leafCovers(leafCertPem, names);
	// A leaf whose issuer is no longer the root on disk is unusable however valid it looks — that is
	// what a deleted-and-regenerated CA leaves behind.
	const chainOk = leafCertPem && (() => {
		try { return new crypto.X509Certificate(leafCertPem).verify(crypto.createPublicKey(caCertPem)); } catch { return false; }
	})();

	if (options.forceLeaf || !verdict.ok || !chainOk || !leafKeyPem) {
		const why = options.forceLeaf ? 'asked to' : (!chainOk && leafCertPem ? 'it was not issued by the root on disk' : verdict.why);
		const leaf = createServerCertificate({
			names,
			caCertPem,
			caKeyPem,
			commonName: names[0]
		});
		state.writePublic(p.leafCert, leaf.certPem);
		state.writePrivate(p.leafKey, leaf.keyPem);
		leafCertPem = leaf.certPem;
		leafKeyPem = leaf.keyPem;
		actions.push(`issued a server certificate for ${names.join(', ')}`);
		log(`issued a server certificate (${why})`);
	}

	const leafCert = new crypto.X509Certificate(leafCertPem);
	const meta = {
		names,
		caCommonName: certCommonName,
		caFingerprintSha256: fingerprint(caCertPem),
		caNotAfter: caCert.validTo,
		leafNotAfter: leafCert.validTo,
		leafSubjectAltName: leafCert.subjectAltName,
		// The base64 SHA-256 of the leaf's SubjectPublicKeyInfo — the pin form Chromium's
		// --ignore-certificate-errors-spki-list wants, which is how the desktop verification drives
		// this exact certificate without touching any keychain.
		leafSpkiPinSha256: spkiPin(leafCertPem),
		writtenAt: new Date().toISOString()
	};
	state.writePublic(p.meta, `${JSON.stringify(meta, null, 2)}\n`);

	return { paths: p, caCertPem, caKeyPem, leafCertPem, leafKeyPem, profile, meta, actions, names };
}

function spkiPin(certPem) {
	const spki = crypto.createPublicKey(certPem).export({ type: 'spki', format: 'der' });
	return crypto.createHash('sha256').update(spki).digest('base64');
}

module.exports = { ensureCertificates, leafCovers, fingerprint, spkiPin };

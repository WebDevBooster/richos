'use strict';

// A local certificate authority, in Node and nothing else.
//
// Two certificates come out of here: a root the CEO installs on his iPhone once, and a leaf for
// this Mac's own names that the probe's HTTPS server presents. The root's private key signs the
// leaf and is then only needed again when the leaf expires or the Mac's LAN address changes.
//
// WHAT APPLE ACTUALLY REQUIRES of a TLS server certificate, because every one of these is a way to
// produce a certificate that works in `curl` and fails on the phone (support.apple.com/HT210176):
//   - the name must be in subjectAltName. A common name is IGNORED — iOS has not matched on CN for
//     years, so a cert with only a CN is a cert for no host at all.
//   - extendedKeyUsage must include id-kp-serverAuth (1.3.6.1.5.5.7.3.1).
//   - the signature must be SHA-256 or better, and an EC key must be 256 bits or more. P-256 with
//     SHA-256 satisfies both, and is what the whole repository already uses for VAPID.
//   - a server certificate's validity must be 825 days or fewer. The leaf here is 397 days, which
//     also clears the tighter 398-day rule (HT211025) whether or not that rule is read as applying
//     to a user-installed root. The ROOT is not a server certificate and gets ten years.
// And separately, the part no certificate can satisfy on its own: on iOS a root installed by
// profile is inert until full trust is switched on by hand in Settings. That is check 0's whole
// subject, and it is the page's job, not this file's.
//
// KEYS NEVER TOUCH THE REPOSITORY. Everything written here lands in the probe's state directory
// (see lib/state.js), mode 0600. A committed private key would be a live credential in a published
// repository, and the secret scanner in this project's hooks would — correctly — refuse the write.

const crypto = require('node:crypto');
const der = require('./der.js');

const OID = {
	commonName: '2.5.4.3',
	organizationName: '2.5.4.10',
	organizationalUnit: '2.5.4.11',
	ecPublicKey: '1.2.840.10045.2.1',
	prime256v1: '1.2.840.10045.3.1.7',
	ecdsaWithSha256: '1.2.840.10045.4.3.2',
	basicConstraints: '2.5.29.19',
	keyUsage: '2.5.29.15',
	extKeyUsage: '2.5.29.37',
	subjectAltName: '2.5.29.17',
	subjectKeyIdentifier: '2.5.29.14',
	authorityKeyIdentifier: '2.5.29.35',
	serverAuth: '1.3.6.1.5.5.7.3.1',
	clientAuth: '1.3.6.1.5.5.7.3.2'
};

const DAY = 24 * 60 * 60 * 1000;

// KeyUsage bit positions, RFC 5280 §4.2.1.3.
const KU = { digitalSignature: 0, keyEncipherment: 2, keyAgreement: 4, keyCertSign: 5, cRLSign: 6 };

function keyPair() {
	return crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
}

// 16 random bytes, positive. RFC 5280 wants a positive integer of at most 20 octets, and a serial
// with real entropy is what stops two regenerations of this CA colliding in a trust store.
function randomSerial() {
	const bytes = crypto.randomBytes(16);
	bytes[0] &= 0x7f;
	if (bytes[0] === 0x00) bytes[0] = 0x01; // keep it comfortably non-zero
	return bytes;
}

function name(parts) {
	// One RDN per attribute, in the order given. Values go out as UTF8String — PrintableString
	// cannot carry an apostrophe or an em dash, and a machine name is not ours to sanitize.
	return der.seq(parts.map(([attrOid, value]) => der.set(der.seq(der.oid(attrOid), der.utf8String(value)))));
}

function spkiDer(publicKey) {
	return publicKey.export({ type: 'spki', format: 'der' });
}

// RFC 5280 §4.2.1.2 method 1: SHA-1 over the subjectPublicKey BIT STRING contents. SHA-1 is not
// doing security work here — a key identifier is a lookup hint, and every trust store computes it
// this way, so using something stronger would simply fail to match.
function keyIdentifier(publicKey) {
	return crypto.createHash('sha1').update(der.subjectPublicKeyBits(spkiDer(publicKey))).digest();
}

function extension(extOid, critical, valueDer) {
	const parts = [der.oid(extOid)];
	if (critical) parts.push(der.bool(true)); // DEFAULT FALSE, so FALSE is never encoded
	parts.push(der.octetString(valueDer));
	return der.seq(parts);
}

// An IPv4 literal as the four bytes an iPAddress GeneralName wants. IPv6 is deliberately not
// handled: the phone reaches this Mac over the home Wi-Fi's IPv4 address or by Bonjour name, and a
// half-supported IPv6 SAN would be a claim this probe has not tested.
function ipv4Bytes(text) {
	const parts = text.split('.');
	if (parts.length !== 4) return null;
	const bytes = parts.map((p) => Number(p));
	if (bytes.some((b) => !Number.isInteger(b) || b < 0 || b > 255)) return null;
	return Buffer.from(bytes);
}

// GeneralNames: dNSName is [2] IA5String, iPAddress is [7] OCTET STRING, both IMPLICIT/primitive.
function subjectAltNameValue(names) {
	const entries = [];
	for (const n of names) {
		const ip = ipv4Bytes(n);
		if (ip) entries.push(der.implicitPrimitive(7, ip));
		else entries.push(der.implicitPrimitive(2, Buffer.from(n, 'ascii')));
	}
	if (entries.length === 0) throw new Error('x509: a server certificate with no subjectAltName matches no host');
	return der.seq(entries);
}

function signTbs(tbs, issuerPrivateKey) {
	// For an EC key Node's default `dsaEncoding` is 'der', which is exactly the SEQUENCE { r, s }
	// that X.509 expects. Asking for 'ieee-p1363' here — the form VAPID's JWT wants — would produce
	// a certificate whose signature no verifier can parse.
	const signature = crypto.sign('sha256', tbs, issuerPrivateKey);
	return der.seq(tbs, der.seq(der.oid(OID.ecdsaWithSha256)), der.bitString(signature, 0));
}

function pem(label, body) {
	const base64 = body.toString('base64').replace(/(.{64})/g, '$1\n').replace(/\n$/, '');
	return `-----BEGIN ${label}-----\n${base64}\n-----END ${label}-----\n`;
}

/**
 * The root. Self-signed, a CA, allowed to sign certificates and nothing else.
 *
 * @param {{ commonName?: string, organization?: string, days?: number, notBefore?: Date }} [options]
 */
function createCertificateAuthority(options = {}) {
	const commonName = options.commonName || 'RichOS Local CA';
	const organization = options.organization || 'RichOS';
	const days = options.days || 3650;
	// Backdated an hour. A phone whose clock is a few minutes behind this Mac would otherwise see a
	// certificate that is not valid yet, which presents as an unexplained connection failure.
	const notBefore = options.notBefore || new Date(Date.now() - 60 * 60 * 1000);
	const notAfter = new Date(notBefore.getTime() + days * DAY);

	const { publicKey, privateKey } = keyPair();
	const subject = name([[OID.commonName, commonName], [OID.organizationName, organization]]);

	const tbs = der.seq(
		der.explicit(0, der.integer(2)), // v3
		der.integer(randomSerial()),
		der.seq(der.oid(OID.ecdsaWithSha256)),
		subject, // self-signed: issuer === subject
		der.seq(der.time(notBefore), der.time(notAfter)),
		subject,
		spkiDer(publicKey),
		der.explicit(3, der.seq([
			// CA:TRUE with pathLenConstraint 0 — this root may issue end-entity certificates and may
			// not issue another CA. Critical, because a relying party that cannot understand
			// basicConstraints must not treat this as a CA by accident.
			extension(OID.basicConstraints, true, der.seq(der.bool(true), der.integer(0))),
			extension(OID.keyUsage, true, der.namedBits([KU.keyCertSign, KU.cRLSign])),
			extension(OID.subjectKeyIdentifier, false, der.octetString(keyIdentifier(publicKey)))
		]))
	);

	const certDer = signTbs(tbs, privateKey);
	return {
		certPem: pem('CERTIFICATE', certDer),
		certDer,
		keyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
		commonName,
		notBefore,
		notAfter
	};
}

/**
 * The leaf this Mac serves. Signed by the root above, valid only for the names passed in.
 *
 * @param {{ names: string[], caCertPem: string, caKeyPem: string, commonName?: string,
 *           organization?: string, days?: number, notBefore?: Date }} options
 */
function createServerCertificate(options) {
	const names = options.names || [];
	const commonName = options.commonName || names[0] || 'localhost';
	const organization = options.organization || 'RichOS';
	// 397 days: inside Apple's 825-day ceiling for server certificates and inside the tighter
	// 398-day rule too, so neither reading of the rules can reject it.
	const days = options.days || 397;
	const notBefore = options.notBefore || new Date(Date.now() - 60 * 60 * 1000);
	const notAfter = new Date(notBefore.getTime() + days * DAY);

	const caCert = new crypto.X509Certificate(options.caCertPem);
	const caKey = crypto.createPrivateKey(options.caKeyPem);
	const caPublicKey = crypto.createPublicKey(options.caCertPem);

	const { publicKey, privateKey } = keyPair();

	const tbs = der.seq(
		der.explicit(0, der.integer(2)),
		der.integer(randomSerial()),
		der.seq(der.oid(OID.ecdsaWithSha256)),
		// The issuer field must be the CA's subject BYTE FOR BYTE. Re-encoding it from strings is
		// how a chain stops building for no visible reason, so it is copied out of the CA itself.
		issuerNameDerOf(caCert),
		der.seq(der.time(notBefore), der.time(notAfter)),
		name([[OID.commonName, commonName], [OID.organizationName, organization]]),
		spkiDer(publicKey),
		der.explicit(3, der.seq([
			// Not a CA. Critical and explicit, rather than absent: an omitted basicConstraints is
			// legal and leaves the question to the verifier's defaults.
			extension(OID.basicConstraints, true, der.seq()),
			// digitalSignature ONLY.
			//
			// The plan's openssl block (§2.2) also asserts keyEncipherment. That is correct for an RSA
			// key and wrong for this one: RFC 5480 §3 says keyEncipherment is not an appropriate usage
			// for an id-ecPublicKey key, because nothing encrypts to an EC key directly. Every modern
			// ECDSA cipher suite needs digitalSignature and nothing else. Named here because it is the
			// one place this file deliberately differs from the plan's extension list.
			extension(OID.keyUsage, true, der.namedBits([KU.digitalSignature])),
			// serverAuth, and CRITICAL — a critical extendedKeyUsage says this certificate is for TLS
			// servers and for nothing else, which is exactly the claim a local CA should make. Apple
			// requires the extension to contain serverAuth; adding clientAuth would widen a
			// certificate that has one job.
			extension(OID.extKeyUsage, true, der.seq(der.oid(OID.serverAuth))),
			extension(OID.subjectAltName, false, subjectAltNameValue(names)),
			extension(OID.subjectKeyIdentifier, false, der.octetString(keyIdentifier(publicKey))),
			extension(OID.authorityKeyIdentifier, false, der.seq(der.implicitPrimitive(0, keyIdentifier(caPublicKey))))
		]))
	);

	const certDer = signTbs(tbs, caKey);
	return {
		certPem: pem('CERTIFICATE', certDer),
		certDer,
		keyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
		names: [...names],
		commonName,
		notBefore,
		notAfter
	};
}

// The issuer's subject, as the exact DER bytes in the CA certificate.
//
// This is copied rather than re-encoded on purpose. RFC 5280 requires the leaf's issuer field to
// match the CA's subject field, and while a verifier may compare them by canonical string, several
// compare the raw bytes. Re-encoding "RichOS Local CA" from a JavaScript string would be identical
// today and would silently stop matching the first time an attribute's string type, order or
// spacing changed — a chain that fails to build with no error naming the reason.
//
// `crypto.X509Certificate` exposes the subject only as text, so the field is located by walking the
// TBSCertificate in DER order: version, serialNumber, signature, ISSUER.
function issuerNameDerOf(caCert) {
	const raw = caCert.raw;
	const outer = der.readTlv(raw, 0);          // Certificate
	const tbs = der.readTlv(raw, outer.start);  // TBSCertificate
	let at = tbs.start;
	at = der.readTlv(raw, at).end;              // [0] version
	at = der.readTlv(raw, at).end;              // serialNumber
	at = der.readTlv(raw, at).end;              // signature AlgorithmIdentifier
	const issuer = der.readTlv(raw, at);        // issuer Name
	if (issuer.tag !== der.TAG.SEQUENCE) throw new Error('x509: the CA certificate has no issuer SEQUENCE where one must be');
	return Buffer.from(raw.subarray(at, issuer.end));
}

module.exports = { createCertificateAuthority, createServerCertificate, keyIdentifier, pem, OID, KU, ipv4Bytes };

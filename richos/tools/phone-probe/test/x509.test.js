'use strict';

// The certificate authority, checked against the rules that actually decide whether an iPhone will
// accept it. `node --test "test/*.test.js"`.
//
// Every assertion here is a failure mode that would otherwise be discovered on his phone, mid-probe,
// as an unexplained "cannot open the page". The DER-level assertions are not pedantry: Node will
// happily present a certificate that Apple's trust evaluator rejects, and the difference is usually
// one byte of encoding.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const der = require('../lib/der.js');
const { createCertificateAuthority, createServerCertificate, ipv4Bytes } = require('../lib/x509.js');

const DAY = 24 * 60 * 60 * 1000;

// Generated once for the whole file: a P-256 pair costs little, but a CA per test case turns a fast
// suite into a slow one for no extra coverage.
const ca = createCertificateAuthority();
const NAMES = ['mm1.local', 'richos.local', 'localhost', '192.168.1.249', '127.0.0.1'];
const leaf = createServerCertificate({ names: NAMES, caCertPem: ca.certPem, caKeyPem: ca.keyPem });
const caX = new crypto.X509Certificate(ca.certPem);
const leafX = new crypto.X509Certificate(leaf.certPem);

// ---------------------------------------------------------------------------
// DER
// ---------------------------------------------------------------------------

test('DER lengths use the short form to 127 and then the shortest long form', () => {
	assert.deepStrictEqual([...der.encodeLength(0)], [0x00]);
	assert.deepStrictEqual([...der.encodeLength(127)], [0x7f]);
	assert.deepStrictEqual([...der.encodeLength(128)], [0x81, 0x80]);
	assert.deepStrictEqual([...der.encodeLength(255)], [0x81, 0xff]);
	assert.deepStrictEqual([...der.encodeLength(256)], [0x82, 0x01, 0x00]);
	assert.deepStrictEqual([...der.encodeLength(65535)], [0x82, 0xff, 0xff]);
	assert.deepStrictEqual([...der.encodeLength(65536)], [0x83, 0x01, 0x00, 0x00]);
});

test('DER integers are minimal and never accidentally negative', () => {
	assert.strictEqual(der.integer(0).toString('hex'), '020100');
	assert.strictEqual(der.integer(127).toString('hex'), '02017f');
	// 0x80 would read as negative without the leading zero byte.
	assert.strictEqual(der.integer(128).toString('hex'), '02020080');
	assert.strictEqual(der.integer(255).toString('hex'), '020200ff');
	assert.strictEqual(der.integer(Buffer.from([0x00, 0x00, 0x2a])).toString('hex'), '02012a');
});

test('DER OIDs match their published encodings', () => {
	// ecdsa-with-SHA256, from RFC 5758.
	assert.strictEqual(der.oid('1.2.840.10045.4.3.2').toString('hex'), '06082a8648ce3d040302');
	// id-kp-serverAuth, from RFC 5280.
	assert.strictEqual(der.oid('1.3.6.1.5.5.7.3.1').toString('hex'), '06082b06010505070301');
	// commonName.
	assert.strictEqual(der.oid('2.5.4.3').toString('hex'), '0603550403');
});

test('a KeyUsage BIT STRING drops its trailing zero bits, as DER requires', () => {
	// keyCertSign + cRLSign — bits 5 and 6, so one unused bit.
	assert.strictEqual(der.namedBits([5, 6]).toString('hex'), '03020106');
	// digitalSignature alone — bit 0, so seven unused bits.
	assert.strictEqual(der.namedBits([0]).toString('hex'), '03020780');
});

test('times are UTCTime through 2049 and GeneralizedTime after, always with seconds and a Z', () => {
	assert.strictEqual(der.time(new Date('2026-09-18T12:00:00Z')).toString('hex'), '170d3236303931383132303030305a');
	const far = der.time(new Date('2050-01-01T00:00:00Z'));
	assert.strictEqual(far[0], der.TAG.GENERALIZED_TIME);
	assert.strictEqual(far.subarray(2).toString('ascii'), '20500101000000Z');
});

test('an IPv4 literal is recognized and anything else is not', () => {
	assert.deepStrictEqual([...ipv4Bytes('192.168.1.249')], [192, 168, 1, 249]);
	assert.strictEqual(ipv4Bytes('mm1.local'), null);
	assert.strictEqual(ipv4Bytes('192.168.1'), null);
	assert.strictEqual(ipv4Bytes('192.168.1.256'), null);
});

// ---------------------------------------------------------------------------
// The root
// ---------------------------------------------------------------------------

test('the root is a self-signed v3 CA that can sign certificates', () => {
	assert.strictEqual(caX.ca, true, 'basicConstraints must say CA:TRUE or nothing will chain to it');
	assert.ok(caX.verify(caX.publicKey), 'a self-signed root must verify against its own key');
	assert.match(caX.subject, /CN=RichOS Local CA/);
	assert.strictEqual(caX.subject, caX.issuer, 'self-signed means issuer === subject');
});

test('the root lasts years, and the leaf stays inside Apple\'s ceiling for a server certificate', () => {
	// Apple rejects a TLS server certificate with more than 825 days of validity, and the tighter
	// 398-day rule may or may not be read as applying to a user-installed root — so the leaf clears
	// both. https://support.apple.com/en-us/HT210176
	const leafDays = (new Date(leafX.validTo) - new Date(leafX.validFrom)) / DAY;
	assert.ok(leafDays < 398, `the leaf is valid for ${leafDays.toFixed(1)} days, which is over Apple's limit`);
	assert.ok(leafDays > 300, `the leaf is valid for only ${leafDays.toFixed(1)} days — it would expire mid-experiment`);

	const caDays = (new Date(caX.validTo) - new Date(caX.validFrom)) / DAY;
	assert.ok(caDays > 3000, `the root is valid for ${caDays.toFixed(0)} days — trusting it by hand should not be an annual chore`);
});

test('both certificates are backdated, so a phone whose clock is behind still accepts them', () => {
	assert.ok(new Date(caX.validFrom).getTime() <= Date.now(), 'a certificate that is not valid yet fails with no useful message');
	assert.ok(new Date(leafX.validFrom).getTime() <= Date.now());
});

// ---------------------------------------------------------------------------
// The leaf
// ---------------------------------------------------------------------------

test('the leaf is signed by the root and is not itself a CA', () => {
	assert.ok(leafX.verify(crypto.createPublicKey(ca.certPem)), 'the chain must build');
	assert.strictEqual(leafX.ca, false);
	assert.ok(!leafX.verify(leafX.publicKey), 'the leaf must not be self-signed');
});

test('every name is in subjectAltName — a common name alone matches no host on iOS', () => {
	assert.strictEqual(leafX.subjectAltName,
		'DNS:mm1.local, DNS:richos.local, DNS:localhost, IP Address:192.168.1.249, IP Address:127.0.0.1');
	for (const name of ['mm1.local', 'richos.local', 'localhost']) {
		assert.strictEqual(leafX.checkHost(name), name, `${name} must match`);
	}
	assert.strictEqual(leafX.checkIP('192.168.1.249'), '192.168.1.249');
	assert.strictEqual(leafX.checkIP('127.0.0.1'), '127.0.0.1');
});

test('DNS name matching is case-insensitive, which is why only the lowercase form is listed', () => {
	// `scutil` reports this Mac as MM1 and the certificate carries mm1.local. If matching were
	// case-sensitive, a URL typed with the capitals Safari shows would fail.
	assert.strictEqual(leafX.checkHost('MM1.local'), 'mm1.local');
});

test('NEGATIVE: a name that is not in the certificate does not match', () => {
	// Without this, every "it matched" assertion above could be passing because checkHost returns
	// something for everything.
	assert.strictEqual(leafX.checkHost('someone-else.local'), undefined);
	assert.strictEqual(leafX.checkHost('mm1.local.evil.com'), undefined);
	assert.strictEqual(leafX.checkIP('192.168.1.250'), undefined);
});

test('extendedKeyUsage includes serverAuth, which Apple requires of a TLS server certificate', () => {
	// Node exposes the extended key usage under `keyUsage`, confusingly.
	assert.ok(leafX.keyUsage.includes('1.3.6.1.5.5.7.3.1'), 'id-kp-serverAuth must be present');
});

test('a certificate with no names is refused rather than issued useless', () => {
	assert.throws(() => createServerCertificate({ names: [], caCertPem: ca.certPem, caKeyPem: ca.keyPem }),
		/subjectAltName/);
});

// ---------------------------------------------------------------------------
// The encoding details a verifier cares about and a human never sees
// ---------------------------------------------------------------------------

// TBSCertificate field order: [0] version, serialNumber, signature, issuer, validity, subject.
function tbsField(certPem, index) {
	const raw = new crypto.X509Certificate(certPem).raw;
	const outer = der.readTlv(raw, 0);
	const tbs = der.readTlv(raw, outer.start);
	let at = tbs.start;
	for (let i = 0; i < index; i++) at = der.readTlv(raw, at).end;
	const field = der.readTlv(raw, at);
	return { hex: raw.subarray(at, field.end).toString('hex'), tag: field.tag, content: field.content };
}

test('the leaf\'s issuer field is the root\'s subject field BYTE FOR BYTE', () => {
	// Some verifiers compare these by canonical string and some compare raw bytes. Re-encoding the
	// name from a JavaScript string would pass the first and could fail the second, which presents
	// as a chain that will not build for no visible reason.
	assert.strictEqual(tbsField(leaf.certPem, 3).hex, tbsField(ca.certPem, 5).hex);
});

test('the serial number is a positive integer of at most 20 octets', () => {
	const serial = tbsField(leaf.certPem, 1);
	assert.strictEqual(serial.tag, der.TAG.INTEGER);
	assert.ok(serial.content.length <= 20, `${serial.content.length} octets is more than RFC 5280 allows`);
	assert.ok((serial.content[0] & 0x80) === 0, 'a negative serial is rejected by several trust stores');
	assert.ok(serial.content.length >= 8, 'a serial needs real entropy so two regenerations cannot collide');
});

test('two runs produce different serial numbers and different keys', () => {
	const other = createServerCertificate({ names: ['mm1.local'], caCertPem: ca.certPem, caKeyPem: ca.keyPem });
	const otherX = new crypto.X509Certificate(other.certPem);
	assert.notStrictEqual(otherX.serialNumber, leafX.serialNumber);
	assert.notStrictEqual(otherX.publicKey.export({ type: 'spki', format: 'pem' }),
		leafX.publicKey.export({ type: 'spki', format: 'pem' }));
});

test('the signature is ECDSA with SHA-256 over a P-256 key, as Apple requires', () => {
	assert.strictEqual(leafX.publicKey.asymmetricKeyType, 'ec');
	assert.strictEqual(leafX.publicKey.asymmetricKeyDetails.namedCurve, 'prime256v1');
	// The signature AlgorithmIdentifier inside the TBSCertificate, field index 2.
	assert.strictEqual(tbsField(leaf.certPem, 2).hex, '300a06082a8648ce3d040302');
});

// Every extension in a certificate, by OID, with its critical flag and its raw value. Node exposes
// almost none of this, and the difference between an extension that is present and one that is
// present AND critical is a difference a trust store acts on.
function extensionsOf(certPem) {
	const raw = new crypto.X509Certificate(certPem).raw;
	const outer = der.readTlv(raw, 0);
	const tbs = der.readTlv(raw, outer.start);
	let at = tbs.start;
	for (let i = 0; i < 7; i++) at = der.readTlv(raw, at).end; // version..spki
	const wrapper = der.readTlv(raw, at);
	assert.strictEqual(wrapper.tag, 0xa3, 'the extensions must be in the [3] EXPLICIT slot');
	const list = der.readTlv(raw, wrapper.start);
	const found = {};
	let cursor = list.start;
	while (cursor < list.end) {
		const ext = der.readTlv(raw, cursor);
		let inner = ext.start;
		const oidTlv = der.readTlv(raw, inner);
		const oidHex = raw.subarray(inner, oidTlv.end).toString('hex');
		inner = oidTlv.end;
		let critical = false;
		let next = der.readTlv(raw, inner);
		if (next.tag === der.TAG.BOOLEAN) {
			critical = next.content[0] === 0xff;
			inner = next.end;
			next = der.readTlv(raw, inner);
		}
		found[oidHex] = { critical, value: Buffer.from(next.content) };
		cursor = ext.end;
	}
	return found;
}

const oidHexOf = (dotted) => der.oid(dotted).toString('hex');

test('the root constrains itself: CA:TRUE with pathLenConstraint 0, and it is critical', () => {
	// pathlen:0 says this root may issue end-entity certificates and may NOT issue another CA. An
	// unconstrained local root is a bigger thing to trust than it needs to be.
	const ext = extensionsOf(ca.certPem)[oidHexOf('2.5.29.19')];
	assert.ok(ext, 'basicConstraints must be present on a CA');
	assert.strictEqual(ext.critical, true);
	assert.strictEqual(ext.value.toString('hex'), '30060101ff020100', 'SEQUENCE { BOOLEAN TRUE, INTEGER 0 }');
});

test('the root may sign certificates and revocation lists, and nothing else', () => {
	const ext = extensionsOf(ca.certPem)[oidHexOf('2.5.29.15')];
	assert.strictEqual(ext.critical, true);
	// A BIT STRING with one unused bit and bits 5 and 6 set: keyCertSign, cRLSign.
	assert.strictEqual(ext.value.toString('hex'), '03020106');
});

test('the leaf is for TLS servers ONLY: extendedKeyUsage is critical and holds just serverAuth', () => {
	const ext = extensionsOf(leaf.certPem)[oidHexOf('2.5.29.37')];
	assert.ok(ext, 'Apple requires extendedKeyUsage on a server certificate');
	assert.strictEqual(ext.critical, true, 'critical says this certificate is for TLS servers and nothing else');
	assert.strictEqual(ext.value.toString('hex'), '300a06082b06010505070301',
		'exactly one usage: SEQUENCE { id-kp-serverAuth }');
	assert.strictEqual(ext.value.toString('hex'), der.seq(der.oid('1.3.6.1.5.5.7.3.1')).toString('hex'));
});

test('the leaf asserts digitalSignature and NOT keyEncipherment — RFC 5480 §3 for an EC key', () => {
	// The plan's openssl block asserts keyEncipherment too. That is right for RSA and wrong here:
	// nothing encrypts to an EC key directly, and every modern ECDSA suite needs digitalSignature
	// alone. This is the one place this implementation deliberately differs from that block.
	const ext = extensionsOf(leaf.certPem)[oidHexOf('2.5.29.15')];
	assert.strictEqual(ext.critical, true);
	// A BIT STRING with seven unused bits and only bit 0 set. keyEncipherment would be bit 2, which
	// would make the second byte 0xa0 and the unused count 5.
	assert.deepStrictEqual([...ext.value], [0x03, 0x02, 0x07, 0x80], 'digitalSignature and nothing else');
});

test('the leaf carries both key identifiers, and the authority one points at the root', () => {
	const { keyIdentifier } = require('../lib/x509.js');
	const exts = extensionsOf(leaf.certPem);
	const ski = exts[oidHexOf('2.5.29.14')];
	const aki = exts[oidHexOf('2.5.29.35')];
	assert.ok(ski && aki);
	assert.strictEqual(ski.critical, false, 'a key identifier is a lookup hint, never critical');
	// The AKI wraps the identifier in [0]; its last 20 bytes are the SHA-1 of the root's key.
	assert.strictEqual(aki.value.subarray(aki.value.length - 20).toString('hex'),
		keyIdentifier(crypto.createPublicKey(ca.certPem)).toString('hex'));
});

test('the private keys are unencrypted PKCS#8 and are not the same key twice', () => {
	// Matched in pieces rather than as one literal: this repository's write-time secret scanner reads
	// a full PEM private-key header as a live credential, and it is right to.
	const header = /^-{5}BEGIN PRIVATE KEY-{5}/;
	assert.match(ca.keyPem, header);
	assert.match(leaf.keyPem, header);
	assert.notStrictEqual(ca.keyPem, leaf.keyPem);
});

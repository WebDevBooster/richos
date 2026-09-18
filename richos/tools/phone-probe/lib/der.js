'use strict';

// DER — just enough ASN.1 to write an X.509 certificate, and to read the one field of one that the
// key identifiers need.
//
// WHY THIS FILE EXISTS AT ALL. The probe now serves itself over HTTPS from the CEO's own Mac
// (`wiki/ceo-decisions.md` §57: the user is not expected to have something like Railway), which
// means the probe has to MINT a certificate. Node's `crypto` has every primitive for that except
// the one thing it does not do at all: it can PARSE an X.509 certificate (`crypto.X509Certificate`)
// and it can sign arbitrary bytes, but it cannot CREATE a certificate. So the certificate body has
// to be assembled as DER by hand and handed to `crypto.sign`.
//
// The alternative was shelling out to `openssl req -x509`. Rejected for two reasons, in this order:
// the product is a free, open-source app installed by a person on their own machine, and `openssl`
// on a stock macOS is LibreSSL with different flags from the OpenSSL that happens to be in this
// developer's PATH — which is exactly the "third-party default" trap the standing rule names. Node
// is the one dependency the probe already has, on every machine it will ever run on.
//
// DER, not BER: every length is minimal, every INTEGER is minimal two's-complement, every BIT
// STRING declares its unused bits. A CA that is sloppy here produces a certificate that Node
// accepts and Apple's trust evaluator rejects — which would be the worst failure mode available,
// because it is discovered on his phone, mid-probe.

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

const TAG = {
	BOOLEAN: 0x01,
	INTEGER: 0x02,
	BIT_STRING: 0x03,
	OCTET_STRING: 0x04,
	NULL: 0x05,
	OID: 0x06,
	UTF8_STRING: 0x0c,
	PRINTABLE_STRING: 0x13,
	IA5_STRING: 0x16,
	UTC_TIME: 0x17,
	GENERALIZED_TIME: 0x18,
	SEQUENCE: 0x30,
	SET: 0x31
};

// The short form up to 127, then the long form with the fewest possible length bytes. A length
// written in more bytes than it needs is legal BER and illegal DER.
function encodeLength(n) {
	if (n < 0x80) return Buffer.from([n]);
	const bytes = [];
	let v = n;
	while (v > 0) { bytes.unshift(v & 0xff); v = Math.floor(v / 256); }
	return Buffer.from([0x80 | bytes.length, ...bytes]);
}

function tlv(tag, content) {
	const body = Buffer.isBuffer(content) ? content : Buffer.from(content);
	return Buffer.concat([Buffer.from([tag]), encodeLength(body.length), body]);
}

function seq(...parts) { return tlv(TAG.SEQUENCE, Buffer.concat(parts.flat())); }
function set(...parts) { return tlv(TAG.SET, Buffer.concat(parts.flat())); }

function bool(value) { return tlv(TAG.BOOLEAN, Buffer.from([value ? 0xff : 0x00])); }

// A non-negative integer, minimally encoded, with the leading 0x00 that stops a high top bit being
// read as a negative number. A certificate serial that comes out negative is a validity failure in
// several trust stores.
function integer(value) {
	let bytes;
	if (typeof value === 'number' || typeof value === 'bigint') {
		let v = BigInt(value);
		if (v < 0n) throw new Error('der: negative integers are not needed here and are not supported');
		if (v === 0n) bytes = [0];
		else {
			bytes = [];
			while (v > 0n) { bytes.unshift(Number(v & 0xffn)); v >>= 8n; }
		}
	} else {
		bytes = [...value];
		while (bytes.length > 1 && bytes[0] === 0x00 && (bytes[1] & 0x80) === 0) bytes.shift();
	}
	if (bytes[0] & 0x80) bytes.unshift(0x00);
	return tlv(TAG.INTEGER, Buffer.from(bytes));
}

// `unused` is the number of trailing bits in the last byte that carry no meaning. For a signature
// or a public key it is always 0; for KeyUsage it is whatever makes the encoding minimal.
function bitString(bytes, unused = 0) {
	return tlv(TAG.BIT_STRING, Buffer.concat([Buffer.from([unused]), Buffer.from(bytes)]));
}

function octetString(bytes) { return tlv(TAG.OCTET_STRING, Buffer.from(bytes)); }

// A KeyUsage BIT STRING from a list of bit positions (0 = digitalSignature). DER requires trailing
// zero bits to be dropped, so the encoding is derived from the highest bit set rather than written
// as a fixed two bytes.
function namedBits(positions) {
	const highest = Math.max(...positions);
	const byteCount = Math.floor(highest / 8) + 1;
	const bytes = Buffer.alloc(byteCount);
	for (const p of positions) bytes[Math.floor(p / 8)] |= 0x80 >> (p % 8);
	const unused = (byteCount * 8) - (highest + 1);
	return bitString(bytes, unused);
}

// "1.2.840.10045.4.3.2" -> a complete OID TLV. The first two arcs share one byte; every later arc
// is base-128 with the continuation bit set on all but the last septet.
function oid(dotted) {
	const arcs = dotted.split('.').map((a) => {
		const n = Number(a);
		if (!Number.isInteger(n) || n < 0) throw new Error(`der: bad OID arc ${JSON.stringify(a)} in ${dotted}`);
		return n;
	});
	if (arcs.length < 2) throw new Error(`der: an OID needs at least two arcs: ${dotted}`);
	if (arcs[0] > 2 || (arcs[0] < 2 && arcs[1] > 39)) throw new Error(`der: OID out of range: ${dotted}`);
	const out = [arcs[0] * 40 + arcs[1]];
	for (const arc of arcs.slice(2)) {
		const septets = [];
		let v = arc;
		do { septets.unshift(v & 0x7f); v = Math.floor(v / 128); } while (v > 0);
		for (let i = 0; i < septets.length - 1; i++) septets[i] |= 0x80;
		out.push(...septets);
	}
	return tlv(TAG.OID, Buffer.from(out));
}

function utf8String(text) { return tlv(TAG.UTF8_STRING, Buffer.from(text, 'utf8')); }
function ia5String(text) { return tlv(TAG.IA5_STRING, Buffer.from(text, 'ascii')); }
function printableString(text) { return tlv(TAG.PRINTABLE_STRING, Buffer.from(text, 'ascii')); }

// RFC 5280: UTCTime through 2049, GeneralizedTime from 2050. Both must be UTC, seconds included, no
// fractional part. Getting this wrong is a certificate that is not yet valid or already expired.
function time(date) {
	const pad = (n, w = 2) => String(n).padStart(w, '0');
	const y = date.getUTCFullYear();
	const body = `${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}Z`;
	if (y >= 1950 && y <= 2049) return tlv(TAG.UTC_TIME, Buffer.from(`${pad(y % 100)}${body}`, 'ascii'));
	return tlv(TAG.GENERALIZED_TIME, Buffer.from(`${pad(y, 4)}${body}`, 'ascii'));
}

// [n] with the constructed bit — an EXPLICIT tag wrapping a complete encoding.
function explicit(n, ...parts) { return tlv(0xa0 | n, Buffer.concat(parts.flat())); }

// [n] primitive — an IMPLICIT tag REPLACING the tag of what it wraps, which is what a GeneralName
// (dNSName, iPAddress) and an AuthorityKeyIdentifier's keyIdentifier use. Writing these as
// explicit/constructed instead is the classic subjectAltName bug: `openssl` prints it, and iOS
// rejects the name match.
function implicitPrimitive(n, content) { return tlv(0x80 | n, Buffer.from(content)); }

// ---------------------------------------------------------------------------
// Reading — only the one thing the writer needs back
// ---------------------------------------------------------------------------

// One TLV at `offset`. Returns the tag, the content, and — as ABSOLUTE offsets into `buf` — where
// the content starts and where the next TLV begins. The absolute offsets are what let a caller cut
// a field back out of the original buffer with its tag and length intact, which is the only safe
// way to copy a DER field verbatim.
function readTlv(buf, offset = 0) {
	const tag = buf[offset];
	let i = offset + 1;
	let len = buf[i++];
	if (len & 0x80) {
		const count = len & 0x7f;
		if (count === 0) throw new Error('der: indefinite length is BER, not DER');
		len = 0;
		for (let k = 0; k < count; k++) len = (len * 256) + buf[i++];
	}
	return { tag, start: i, content: buf.subarray(i, i + len), end: i + len };
}

// The raw public-key bits out of a SubjectPublicKeyInfo — SEQUENCE { AlgorithmIdentifier, BIT
// STRING }. RFC 5280 §4.2.1.2 computes a key identifier over exactly these bytes, not over the
// whole SPKI, and a trust store that recomputes it is entitled to disagree with us if we take the
// easier hash.
function subjectPublicKeyBits(spkiDer) {
	const outer = readTlv(spkiDer, 0);
	if (outer.tag !== TAG.SEQUENCE) throw new Error('der: an SPKI must be a SEQUENCE');
	const algorithm = readTlv(outer.content, 0);
	const keyBits = readTlv(outer.content, algorithm.end);
	if (keyBits.tag !== TAG.BIT_STRING) throw new Error('der: an SPKI must end in a BIT STRING');
	if (keyBits.content[0] !== 0x00) throw new Error('der: a public-key BIT STRING must have no unused bits');
	return Buffer.from(keyBits.content.subarray(1));
}

module.exports = {
	TAG, encodeLength, tlv, seq, set, bool, integer, bitString, octetString, namedBits,
	oid, utf8String, ia5String, printableString, time, explicit, implicitPrimitive,
	readTlv, subjectPublicKeyBits
};

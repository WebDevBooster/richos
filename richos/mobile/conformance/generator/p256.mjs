// DETERMINISTIC ECDSA P-256 / SHA-256 (RFC 6979), for the conformance corpus only.
//
// Why this file exists: ECDSA is randomized, and the corpus must regenerate BYTE-IDENTICALLY
// (`generate.mjs --check`). `node:crypto` offers no deterministic nonce, so the corpus signs
// with RFC 6979 here and then verifies every signature with `node:crypto` (an independent
// implementation) and, in `verifier/`, with the Mac's own Rust verifier. A signature from this
// file is an ordinary P-256 signature: nothing that verifies can tell how k was chosen.
//
// Not constant time and never meant to be: the only key it ever holds is the published
// TEST-ONLY key in `vectors/keys.json`.

import { createHash, createHmac } from 'node:crypto';

const P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn;
const N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;
const A = P - 3n;
const G = [
	0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296n,
	0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5n
];

export const ORDER = N;

const mod = (a, m) => ((a % m) + m) % m;

function inverse(a, m) {
	let [r0, r1] = [mod(a, m), m];
	let [s0, s1] = [1n, 0n];
	while (r1 !== 0n) {
		const q = r0 / r1;
		[r0, r1] = [r1, r0 - q * r1];
		[s0, s1] = [s1, s0 - q * s1];
	}
	if (r0 !== 1n) throw new Error('not invertible');
	return mod(s0, m);
}

// Jacobian coordinates; `null` is the point at infinity.
function double(pt) {
	if (!pt) return null;
	const [x, y, z] = pt;
	if (y === 0n) return null;
	const yy = mod(y * y, P);
	const s = mod(4n * x * yy, P);
	const zz = mod(z * z, P);
	const m = mod(3n * x * x + A * zz * zz, P);
	const x3 = mod(m * m - 2n * s, P);
	const y3 = mod(m * (s - x3) - 8n * yy * yy, P);
	const z3 = mod(2n * y * z, P);
	return [x3, y3, z3];
}

function add(p1, p2) {
	if (!p1) return p2;
	if (!p2) return p1;
	const [x1, y1, z1] = p1;
	const [x2, y2, z2] = p2;
	const z1z1 = mod(z1 * z1, P), z2z2 = mod(z2 * z2, P);
	const u1 = mod(x1 * z2z2, P), u2 = mod(x2 * z1z1, P);
	const s1 = mod(y1 * z2 * z2z2, P), s2 = mod(y2 * z1 * z1z1, P);
	if (u1 === u2) return s1 === s2 ? double(p1) : null;
	const h = mod(u2 - u1, P), r = mod(s2 - s1, P);
	const hh = mod(h * h, P), hhh = mod(h * hh, P);
	const x3 = mod(r * r - hhh - 2n * u1 * hh, P);
	const y3 = mod(r * (u1 * hh - x3) - s1 * hhh, P);
	const z3 = mod(h * z1 * z2, P);
	return [x3, y3, z3];
}

function affine(pt) {
	if (!pt) throw new Error('point at infinity');
	const [x, y, z] = pt;
	const zi = inverse(z, P);
	const zi2 = mod(zi * zi, P);
	return [mod(x * zi2, P), mod(y * zi2 * zi, P)];
}

function multiply(k, point) {
	let result = null;
	let addend = [point[0], point[1], 1n];
	while (k > 0n) {
		if (k & 1n) result = add(result, addend);
		addend = double(addend);
		k >>= 1n;
	}
	return affine(result);
}

const toBig = (bytes) => BigInt('0x' + (Buffer.from(bytes).toString('hex') || '0'));
const to32 = (n) => Buffer.from(n.toString(16).padStart(64, '0'), 'hex');
const hmac = (key, ...parts) => {
	const h = createHmac('sha256', key);
	for (const part of parts) h.update(part);
	return h.digest();
};

/// The 65-byte uncompressed public point for a 32-byte private scalar.
export function publicPoint(privateKey) {
	const d = toBig(privateKey);
	if (d <= 0n || d >= N) throw new Error('private scalar out of range');
	const [x, y] = multiply(d, G);
	return Buffer.concat([Buffer.from([4]), to32(x), to32(y)]);
}

/// RFC 6979 section 3.2 with SHA-256; qlen = hlen = 256, so bits2int is a plain conversion.
/// Returns raw r||s, 64 bytes (IEEE P1363), which is what WebCrypto, CryptoKit and the Mac use.
export function signDeterministic(privateKey, message) {
	const d = toBig(privateKey);
	const h1 = createHash('sha256').update(message).digest();
	const e = toBig(h1);
	const x = to32(d);
	const h1o = to32(mod(e, N));
	let v = Buffer.alloc(32, 1);
	let k = Buffer.alloc(32, 0);
	k = hmac(k, v, Buffer.from([0]), x, h1o);
	v = hmac(k, v);
	k = hmac(k, v, Buffer.from([1]), x, h1o);
	v = hmac(k, v);
	for (;;) {
		v = hmac(k, v);
		const nonce = toBig(v);
		if (nonce >= 1n && nonce < N) {
			const r = mod(multiply(nonce, G)[0], N);
			if (r !== 0n) {
				const s = mod(inverse(nonce, N) * (e + r * d), N);
				if (s !== 0n) return Buffer.concat([to32(r), to32(s)]);
			}
		}
		k = hmac(k, v, Buffer.from([0]));
		v = hmac(k, v);
	}
}

/// raw r||s -> ASN.1 DER `SEQUENCE { INTEGER r, INTEGER s }`, which is what Android's
/// `Signature("SHA256withECDSA")` and iOS `SecKeyCreateSignature` return.
export function rawToDer(raw) {
	const integer = (bytes) => {
		let i = 0;
		while (i < bytes.length - 1 && bytes[i] === 0) i++;
		let body = bytes.subarray(i);
		if (body[0] & 0x80) body = Buffer.concat([Buffer.from([0]), body]);
		return Buffer.concat([Buffer.from([2, body.length]), body]);
	};
	const seq = Buffer.concat([integer(raw.subarray(0, 32)), integer(raw.subarray(32, 64))]);
	return Buffer.concat([Buffer.from([0x30, seq.length]), seq]);
}

/// The same signature with s replaced by n - s. Mathematically valid ECDSA; whether a verifier
/// accepts it is a property of the verifier, and the corpus records the Mac's answer.
export function highS(raw) {
	const s = toBig(raw.subarray(32, 64));
	return Buffer.concat([raw.subarray(0, 32), to32(N - s)]);
}

/// The generator refuses to run if this file does not reproduce RFC 6979 appendix A.2.5
/// (P-256, SHA-256, message "sample"). A deterministic signer that is subtly wrong would
/// otherwise produce a corpus that is byte-stable AND wrong.
export function selfTest() {
	const key = Buffer.from('C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721', 'hex');
	const expected = 'EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716' +
		'F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8';
	const got = signDeterministic(key, Buffer.from('sample', 'utf8')).toString('hex').toUpperCase();
	if (got !== expected) throw new Error(`RFC 6979 A.2.5 self-test failed: ${got}`);
	const point = publicPoint(key).toString('hex').toUpperCase();
	const expectedPoint = '04' + '60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6' +
		'7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299';
	if (point !== expectedPoint) throw new Error(`RFC 6979 A.2.5 public key self-test failed: ${point}`);
}

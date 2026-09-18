'use strict';

// The certificate authority ON DISK: what gets written, where, with what permissions, and — the one
// that matters most — what is NEVER rewritten.
//
// THE INVARIANT THIS FILE EXISTS FOR: trusting the root on the iPhone is fifteen taps of the CEO's
// time. Regenerating the root silently throws that away and presents as "HTTPS stopped working for
// no reason", with nothing on screen connecting the two. So: the leaf is reissued freely, and the
// root is only ever created when there is none.
//
// Every case works in its own temp directory and removes it however the case ends — garbage is
// always cleaned up (ceo-decisions.md §54), including the garbage a test makes.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const { ensureCertificates, spkiPin } = require('../lib/tls-setup.js');
const { caProfile, derivedUuid } = require('../lib/mobileconfig.js');
const localnames = require('../lib/localnames.js');

// `lib/state.js` reads PROBE_STATE_DIR at call time, so each case can point it somewhere private.
// It is restored afterwards so one case cannot leak a directory into the next.
function inScratch(fn) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-probe-ca-test-'));
	const previous = process.env.PROBE_STATE_DIR;
	process.env.PROBE_STATE_DIR = dir;
	try {
		return fn(dir);
	} finally {
		if (previous === undefined) delete process.env.PROBE_STATE_DIR;
		else process.env.PROBE_STATE_DIR = previous;
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

const NAMES = ['mm1.local', 'richos.local', 'localhost', '192.168.1.249', '127.0.0.1'];

test('the first run writes a root, a profile and a server certificate, and nothing lands in the repository', () => {
	inScratch((dir) => {
		const result = ensureCertificates({ names: NAMES });
		for (const file of [result.paths.caCert, result.paths.caKey, result.paths.caProfile, result.paths.leafCert, result.paths.leafKey, result.paths.meta]) {
			assert.ok(fs.existsSync(file), `${file} should exist`);
			assert.ok(file.startsWith(dir), `${file} must be inside the state directory, not the repository`);
		}
		assert.strictEqual(result.actions.length, 3, result.actions.join('; '));
	});
});

test('a second run changes nothing at all', () => {
	inScratch(() => {
		const first = ensureCertificates({ names: NAMES });
		const caBefore = fs.readFileSync(first.paths.caCert, 'utf8');
		const leafBefore = fs.readFileSync(first.paths.leafCert, 'utf8');

		const second = ensureCertificates({ names: NAMES });
		assert.deepStrictEqual(second.actions, [], 'a no-op run must report no actions');
		assert.strictEqual(fs.readFileSync(second.paths.caCert, 'utf8'), caBefore);
		assert.strictEqual(fs.readFileSync(second.paths.leafCert, 'utf8'), leafBefore);
	});
});

test('THE INVARIANT: losing the server certificate reissues it and leaves the ROOT untouched', () => {
	inScratch(() => {
		const first = ensureCertificates({ names: NAMES });
		const caBefore = fs.readFileSync(first.paths.caCert, 'utf8');
		const caKeyBefore = fs.readFileSync(first.paths.caKey, 'utf8');
		const leafBefore = fs.readFileSync(first.paths.leafCert, 'utf8');

		fs.rmSync(first.paths.leafCert);
		const second = ensureCertificates({ names: NAMES });

		assert.strictEqual(fs.readFileSync(second.paths.caCert, 'utf8'), caBefore, 'the root must survive');
		assert.strictEqual(fs.readFileSync(second.paths.caKey, 'utf8'), caKeyBefore, 'the root key must survive');
		assert.notStrictEqual(fs.readFileSync(second.paths.leafCert, 'utf8'), leafBefore, 'the leaf must be new');
		// And the new leaf must chain to the SAME root, or the phone's trust is worthless.
		const leaf = new crypto.X509Certificate(fs.readFileSync(second.paths.leafCert, 'utf8'));
		assert.ok(leaf.verify(crypto.createPublicKey(caBefore)));
	});
});

test('a new address reissues the leaf, still from the same root', () => {
	inScratch(() => {
		const first = ensureCertificates({ names: NAMES });
		const caBefore = fs.readFileSync(first.paths.caCert, 'utf8');

		// What a new DHCP lease looks like to this code.
		const moved = [...NAMES.filter((n) => n !== '192.168.1.249'), '10.0.0.7'];
		const second = ensureCertificates({ names: moved });

		assert.ok(second.actions.some((a) => a.includes('issued a server certificate')), second.actions.join('; '));
		assert.strictEqual(fs.readFileSync(second.paths.caCert, 'utf8'), caBefore, 'a moving address must not cost a new root');
		const leaf = new crypto.X509Certificate(fs.readFileSync(second.paths.leafCert, 'utf8'));
		assert.strictEqual(leaf.checkIP('10.0.0.7'), '10.0.0.7');
		assert.strictEqual(leaf.checkIP('192.168.1.249'), undefined, 'the old address is gone from the new leaf');
	});
});

test('a leaf left behind by a DIFFERENT root is replaced rather than served', () => {
	inScratch(() => {
		const first = ensureCertificates({ names: NAMES });
		const orphanLeaf = fs.readFileSync(first.paths.leafCert, 'utf8');

		// Delete the root only. The leaf on disk still looks valid and is now unusable: nothing will
		// build a chain for it. Serving it would fail on the phone with a message about trust, which
		// is the hardest kind of failure to attribute.
		fs.rmSync(first.paths.caCert);
		fs.rmSync(first.paths.caKey);
		const second = ensureCertificates({ names: NAMES });

		assert.ok(second.actions.some((a) => a.includes('root')), 'a new root must be created');
		assert.notStrictEqual(fs.readFileSync(second.paths.leafCert, 'utf8'), orphanLeaf, 'the orphaned leaf must be replaced');
		const leaf = new crypto.X509Certificate(fs.readFileSync(second.paths.leafCert, 'utf8'));
		assert.ok(leaf.verify(crypto.createPublicKey(fs.readFileSync(second.paths.caCert, 'utf8'))));
	});
});

test('--reissue forces a new leaf and still keeps the root', () => {
	inScratch(() => {
		const first = ensureCertificates({ names: NAMES });
		const caBefore = fs.readFileSync(first.paths.caCert, 'utf8');
		const leafBefore = fs.readFileSync(first.paths.leafCert, 'utf8');
		const second = ensureCertificates({ names: NAMES, forceLeaf: true });
		assert.notStrictEqual(fs.readFileSync(second.paths.leafCert, 'utf8'), leafBefore);
		assert.strictEqual(fs.readFileSync(second.paths.caCert, 'utf8'), caBefore);
	});
});

test('private keys are readable only by their owner, and so is the directory holding them', () => {
	inScratch(() => {
		const result = ensureCertificates({ names: NAMES });
		for (const key of [result.paths.caKey, result.paths.leafKey]) {
			const mode = fs.statSync(key).mode & 0o777;
			assert.strictEqual(mode, 0o600, `${key} is mode ${mode.toString(8)} — a private key must not be group- or world-readable`);
		}
		const dirMode = fs.statSync(result.paths.tlsDir).mode & 0o777;
		assert.strictEqual(dirMode, 0o700, `the state directory is mode ${dirMode.toString(8)}`);
	});
});

test('the public-key pin is the base64 SHA-256 of the SubjectPublicKeyInfo, recomputed independently', () => {
	inScratch(() => {
		const result = ensureCertificates({ names: NAMES });
		const spki = crypto.createPublicKey(result.leafCertPem).export({ type: 'spki', format: 'der' });
		const expected = crypto.createHash('sha256').update(spki).digest('base64');
		assert.strictEqual(result.meta.leafSpkiPinSha256, expected);
		assert.strictEqual(spkiPin(result.leafCertPem), expected);
		// That is the exact form Chromium's --ignore-certificate-errors-spki-list takes, which is how
		// the desktop verification pins this certificate without touching any keychain.
		assert.match(result.meta.leafSpkiPinSha256, /^[A-Za-z0-9+/]{43}=$/);
	});
});

// ---------------------------------------------------------------------------
// The configuration profile
// ---------------------------------------------------------------------------

test('the profile carries the certificate as a root payload iOS understands', () => {
	inScratch((dir) => {
		const result = ensureCertificates({ names: NAMES });
		const profile = fs.readFileSync(result.paths.caProfile, 'utf8');
		assert.match(profile, /<key>PayloadType<\/key>\s*<string>com\.apple\.security\.root<\/string>/);
		assert.match(profile, /<string>Configuration<\/string>/);
		assert.match(profile, /<key>PayloadRemovalDisallowed<\/key>\s*<false\/>/, 'he must be able to remove it');

		// The embedded data must be the DER of the root, not of something else.
		const base64 = /<data>([\s\S]*?)<\/data>/.exec(profile)[1].replace(/\s+/g, '');
		const embedded = Buffer.from(base64, 'base64');
		const caDer = new crypto.X509Certificate(result.caCertPem).raw;
		assert.deepStrictEqual(embedded, Buffer.from(caDer));
		assert.ok(dir);
	});
});

test('the profile names the trust step, because a certificate installed and not trusted does nothing', () => {
	inScratch(() => {
		const result = ensureCertificates({ names: NAMES });
		const profile = fs.readFileSync(result.paths.caProfile, 'utf8');
		assert.match(profile, /Certificate Trust Settings/, 'the second half of the trust step must be stated in the profile itself');
		assert.match(profile, /Not signed/, 'iOS shows unsigned profiles in red; hiding that would be worse than naming it');
		// The fingerprint is in the description so what he installs can be compared to what the
		// console printed.
		assert.match(profile, /SHA-256: [0-9A-F]{2}(:[0-9A-F]{2}){31}/);
	});
});

test('the profile UUIDs are derived from the certificate, so reinstalling replaces instead of stacking up', () => {
	const der = crypto.randomBytes(200);
	const first = caProfile({ certDer: der, commonName: 'RichOS Local CA', hostNames: ['mm1.local'] });
	const again = caProfile({ certDer: der, commonName: 'RichOS Local CA', hostNames: ['mm1.local'] });
	assert.strictEqual(first, again, 'the same certificate must produce the same profile, byte for byte');

	const other = caProfile({ certDer: crypto.randomBytes(200), commonName: 'RichOS Local CA', hostNames: ['mm1.local'] });
	const uuidOf = (text) => /<key>PayloadUUID<\/key>\s*<string>([^<]+)</.exec(text)[1];
	assert.notStrictEqual(uuidOf(first), uuidOf(other), 'a different certificate must be a different profile');
	assert.match(uuidOf(first), /^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/,
		'a well-formed name-based UUID, not something that merely looks like one');
});

test('XML metacharacters in a host name cannot break the profile', () => {
	const profile = caProfile({ certDer: Buffer.from([1, 2, 3]), commonName: 'A & B <test>', hostNames: ['a<b>.local'] });
	assert.ok(!/<string>A & B/.test(profile), 'a bare ampersand would make the profile unparseable');
	assert.match(profile, /A &amp; B &lt;test&gt;/);
});

test('a derived UUID is stable and namespaced', () => {
	const a = derivedUuid('ns1', Buffer.from('x'));
	assert.strictEqual(a, derivedUuid('ns1', Buffer.from('x')));
	assert.notStrictEqual(a, derivedUuid('ns2', Buffer.from('x')));
});

// ---------------------------------------------------------------------------
// The names this Mac answers on
// ---------------------------------------------------------------------------

test('the certificate names include a .local name, localhost and the loopback address', () => {
	const names = localnames.certificateNames();
	assert.ok(names[0].endsWith('.local'), `${names[0]} should be the Bonjour name`);
	assert.ok(names.includes('richos.local'), 'the name the real product will want, so this step needs no second certificate');
	assert.ok(names.includes('localhost'), 'the desktop verification drives the same origin the phone uses');
	assert.ok(names.includes('127.0.0.1'));
	assert.deepStrictEqual(names, [...new Set(names)], 'no duplicates');
});

test('a self-assigned 169.254 address is never claimed in a certificate', () => {
	// That range is what an interface gives itself when DHCP failed. The phone cannot reach it, so
	// putting it in a certificate would be a false claim about where this Mac can be found.
	for (const name of localnames.certificateNames()) {
		assert.ok(!name.startsWith('169.254.'), `${name} is a link-local address`);
	}
});

test('the Bonjour name is lowercase and has no trailing .local', () => {
	const host = localnames.localHostName();
	assert.strictEqual(host, host.toLowerCase());
	assert.ok(!host.endsWith('.local'), `${host} must not already carry the suffix`);
	assert.strictEqual(localnames.primaryName(), `${host}.local`);
});

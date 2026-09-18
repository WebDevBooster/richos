'use strict';

// What this Mac is called on the home Wi-Fi, and at which address.
//
// The phone has to reach the Mac by a name the certificate covers. There are exactly two, and they
// fail in different ways, so both go in:
//
//   1. `<LocalHostName>.local` — the Bonjour name mDNSResponder already publishes. NOTHING has to
//      be installed or started for this to resolve from an iPhone on the same subnet, and it
//      survives the DHCP lease changing, which the IP address does not.
//   2. the LAN IPv4 address — the fallback for when multicast DNS is blocked, which is exactly what
//      a guest network or a router with "client isolation" / "AP isolation" does.
//
// `richos.local` is deliberately NOT here. It is the nicer name and it is deferred with its price
// stated, per `richos-hq/docs/plans/richos-phone-client-2026-09-18.md` §2.1: publishing an extra
// `.local` address record needs either FFI to `DNSServiceRegisterRecord` or a new mDNS dependency,
// PLUS `NSLocalNetworkUsageDescription` and a local-network permission prompt on macOS 15 and later.
// The Mac's own name needs none of that, because we are not the ones publishing it. It buys exactly
// one thing — the origin surviving him renaming his Mac — and the trade only flips if this probe
// finds the Mac's own name unreliable from the iPhone, which is a finding this probe can produce.
//
// The LocalHostName is read from `scutil`, which is the authoritative source on macOS — the same
// value System Settings shows as "Local hostname" and the one Bonjour actually publishes.
// `os.hostname()` can differ from it (it reports whatever DHCP or a network account handed over) and
// is used only as the fallback.

const os = require('node:os');
const { execFileSync } = require('node:child_process');

function run(file, args) {
	try {
		return execFileSync(file, args, { encoding: 'utf8', timeout: 4000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
	} catch {
		return '';
	}
}

/** The Bonjour host name, lowercase, without the trailing `.local`. */
function localHostName() {
	const fromScutil = process.platform === 'darwin' ? run('/usr/sbin/scutil', ['--get', 'LocalHostName']) : '';
	const raw = fromScutil || os.hostname();
	return raw.replace(/\.local\.?$/i, '').toLowerCase();
}

/**
 * The host name as macOS SHOWS it — `MM1`, not `mm1`.
 *
 * Used only where a person reads it: the certificate authority's own name, and therefore the label
 * on the switch he has to find in Settings. The page's instructions quote that label, so it has to
 * be the same string iOS will put on the screen.
 */
function displayHostName() {
	const fromScutil = process.platform === 'darwin' ? run('/usr/sbin/scutil', ['--get', 'LocalHostName']) : '';
	return (fromScutil || os.hostname()).replace(/\.local\.?$/i, '');
}

/** The interface carrying the default route — the one the phone will reach us on. */
function primaryInterface() {
	if (process.platform !== 'darwin') return '';
	const out = run('/sbin/route', ['-n', 'get', 'default']);
	const m = /interface:\s*(\S+)/.exec(out);
	return m ? m[1] : '';
}

/**
 * Every non-internal IPv4 address, the default-route interface's first.
 * @returns {{address: string, iface: string, primary: boolean}[]}
 */
function lanAddresses() {
	const primary = primaryInterface();
	const found = [];
	for (const [iface, entries] of Object.entries(os.networkInterfaces())) {
		for (const entry of entries || []) {
			if (entry.family !== 'IPv4' || entry.internal) continue;
			// 169.254/16 is what an interface gives itself when DHCP failed. It is not an address the
			// phone can reach and putting it in a certificate would be a false claim.
			if (entry.address.startsWith('169.254.')) continue;
			found.push({ address: entry.address, iface, primary: iface === primary });
		}
	}
	found.sort((a, b) => (b.primary ? 1 : 0) - (a.primary ? 1 : 0));
	return found;
}

/**
 * The names the leaf certificate covers, in the order they appear in the SAN.
 *
 * Nothing extra is added for the desktop verification's convenience. `localhost` would be a second
 * origin with its own service worker and its own push subscription, so a harness that used it would
 * be testing something the phone never touches. The desktop verification drives `mm1.local` — the
 * name the phone uses — which is the stronger test and needs no extra name in the certificate.
 */
function certificateNames(options = {}) {
	const host = options.hostName || localHostName();
	const names = [`${host}.local`];
	for (const { address } of lanAddresses()) names.push(address);
	// Preserve order, drop duplicates.
	return names.filter((n, i) => names.indexOf(n) === i);
}

/** The name to put in a URL the phone will open: the Bonjour name, which outlives a DHCP lease. */
function primaryName(options = {}) {
	return `${options.hostName || localHostName()}.local`;
}

module.exports = { localHostName, displayHostName, primaryInterface, lanAddresses, certificateNames, primaryName };

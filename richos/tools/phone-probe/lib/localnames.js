'use strict';

// What this Mac is called on the home Wi-Fi, and at which address.
//
// The phone has to reach the Mac by a name the certificate covers. There are two such names and
// they fail in different ways, so both go in:
//
//   1. `<LocalHostName>.local` — the Bonjour name mDNSResponder already publishes. NOTHING has to
//      be installed or started for this to resolve from an iPhone on the same subnet, and it
//      survives the DHCP lease changing, which the IP address does not.
//   2. the LAN IPv4 address — the fallback for when multicast DNS is blocked, which is exactly what
//      a guest network or a router with "client isolation" / "AP isolation" does.
//
// `richos.local` is included as a third name because it is the name the real product will want, and
// a certificate that already covers it means that step needs no new certificate. It resolves only
// while something publishes it (see bin/register-bonjour-alias.sh) — the certificate covering a name
// and the network resolving it are two independent things, and conflating them is how "I typed the
// URL and nothing happened" becomes a mystery.
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
 * `localhost` and `127.0.0.1` are in there for one reason: the desktop verification drives the real
 * page over HTTPS on this Mac, and a certificate that cannot serve `localhost` would force that
 * harness to test a different origin from the one the phone uses.
 */
function certificateNames(options = {}) {
	const host = options.hostName || localHostName();
	const names = [`${host}.local`, 'richos.local', 'localhost'];
	for (const { address } of lanAddresses()) names.push(address);
	names.push('127.0.0.1');
	// Preserve order, drop duplicates.
	return names.filter((n, i) => names.indexOf(n) === i);
}

/** The name to put in a URL the phone will open: the Bonjour name, which outlives a DHCP lease. */
function primaryName(options = {}) {
	return `${options.hostName || localHostName()}.local`;
}

module.exports = { localHostName, primaryInterface, lanAddresses, certificateNames, primaryName };

// THE REVIEW WORKER: the RichConnect review environment on Cloudflare, with no Mac behind it.
//
//   https://<ACCESS_HOSTNAME>/        the review access page (the reviewer's Mac), `portal.mjs`
//   https://<review host>/api/…       the phone protocol, one Durable Object per review host
//
// A request for a review host is handed, unchanged, to that host's own Durable Object, which runs
// the phone routes (`phone.mjs`) over its own storage (`host.mjs`). Nothing is ever forwarded to a
// Mac (Sage M4): there is no upstream at all except the Connect Worker for push. Any other hostname
// is a flat 404.

import { Host } from './host.mjs';
import { handlePhoneRequest } from './phone.mjs';
import { handlePortal } from './portal.mjs';
import { readConfig } from './config.mjs';
import { connectClient, hostIdentity } from './push.mjs';

/** The internal address the Worker uses to call a host's Durable Object for the access page. */
const INTERNAL = 'internal.invalid';
const OPS = new Set(['status', 'openPairing', 'confirmOnMac', 'replacePhone', 'reset']);

function unavailable(problems) {
	return new Response(JSON.stringify({ service: 'richconnect-review', ready: false, problems }), {
		status: 503, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
	});
}

/**
 * One review host. Keyed by its hostname (`idFromName`), so each review host is a separate
 * object with separate storage: that is the isolation between reviewers.
 */
export class ReviewHost {
	constructor(state, env) {
		this.state = state;
		this.env = env;
		this.host = null;
		this.building = null;
	}

	/**
	 * The one Host for this object. Memoized as a promise, not a value: two first requests that
	 * arrive together must share one Host, or each would hold its own copy of the phone, the
	 * challenges and the rate buckets over the same storage.
	 */
	ensure(hostname) {
		if (!this.building) this.building = this.build(hostname).catch((error) => { this.building = null; throw error; });
		return this.building;
	}

	async build(hostname) {
		const known = await this.state.storage.get('hostname');
		if (!known && !hostname) throw new Error('review host has no name yet');
		if (!known) await this.state.storage.put('hostname', hostname);
		const name = known || hostname;
		const read = readConfig(this.env);
		if (!read.ok) throw new Error('review Worker is misconfigured');
		const { config } = read;
		let push = null;
		if (config.hostKeys && config.hostKeys[name]) {
			const identity = await hostIdentity(config.hostKeys[name]);
			push = { control: connectClient({ origin: config.connectOrigin, identity }) };
		}
		const storage = this.state.storage;
		this.host = new Host({
			storage,
			hostname: name,
			push,
			pairingVersion: config.pairingVersion,
			schedule: async (at) => {
				const current = await storage.getAlarm();
				if (current === null || at < current) await storage.setAlarm(at);
			}
		});
		return this.host;
	}

	async fetch(request) {
		const url = new URL(request.url);
		if (url.hostname === INTERNAL) {
			const op = url.pathname.slice(1);
			if (!OPS.has(op)) return new Response(null, { status: 404 });
			const { hostname, args = [] } = await request.json();
			const host = await this.ensure(hostname);
			return Response.json(await host[op](...args) ?? null);
		}
		const host = await this.ensure(url.hostname);
		if (url.hostname !== host.hostname) return new Response(null, { status: 404 });
		return handlePhoneRequest(host, request);
	}

	async alarm() {
		const host = await this.ensure(null);
		await host.alarm();
	}
}

/** The access page's handle on one host's Durable Object. */
export function hostApiFor(env) {
	return (hostname) => {
		const stub = env.HOSTS.get(env.HOSTS.idFromName(hostname));
		const call = async (op, ...args) => {
			const response = await stub.fetch(new Request(`https://${INTERNAL}/${op}`, { method: 'POST', body: JSON.stringify({ hostname, args }) }));
			if (!response.ok) throw new Error(`review host ${op} failed`);
			return response.json();
		};
		return {
			status: () => call('status'),
			openPairing: () => call('openPairing'),
			confirmOnMac: (match) => call('confirmOnMac', match),
			replacePhone: () => call('replacePhone'),
			reset: () => call('reset')
		};
	};
}

export async function handle(request, env, ports = {}) {
	const url = new URL(request.url);
	if (url.protocol !== 'https:') return new Response(null, { status: 400 });
	const read = readConfig(env);
	if (!read.ok) return unavailable(read.problems);
	const { config } = read;
	const hostname = url.hostname.toLowerCase();
	if (hostname === config.accessHostname) {
		return handlePortal(request, config, { hostApi: ports.hostApi || hostApiFor(env), loginLimit: env.LOGIN_LIMIT, now: ports.now || Date.now });
	}
	if (config.hosts.some((h) => h.hostname === hostname)) {
		return env.HOSTS.get(env.HOSTS.idFromName(hostname)).fetch(request);
	}
	return new Response(null, { status: 404 });
}

export default { fetch: (request, env) => handle(request, env) };

// THE DEPLOYMENT, READ AND REFUSED EARLY. A review Worker that is misconfigured answers 503 on
// every route and says which setting is wrong on `/healthz`, never half-works.
//
// Bindings and variables (see README "Deploy"):
//   ACCESS_HOSTNAME        plain   the access page's HTTPS name
//   REVIEW_HOSTS           plain   JSON [{ "hostname", "label", "username" }, …], at most 8
//   PAIRING_WORDS          plain   "v1" (today's corpus, the default) or "v2" (Sage's derivation)
//   CONNECT_ORIGIN         plain   the Connect Worker, default https://connect.richos.ceo
//   REVIEW_PASSWORD_HASHES secret  JSON { username: "pbkdf2-sha256$…" }
//   SESSION_KEY            secret  base64url of 32 random bytes
//   REVIEW_HOST_KEYS       secret  JSON { hostname: PKCS#8 base64url }; absent = no push
//   HOSTS                  binding the ReviewHost Durable Object namespace
//   LOGIN_LIMIT            binding a Workers rate-limit binding for sign-in attempts

import { unb64url } from './codec.mjs';

const DNS_NAME = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const FORBIDDEN_ZONE = 'richos.ceo';
export const MAX_REVIEW_HOSTS = 8;

/**
 * Sage's rule M2: the review service never answers inside the Connect namespace. Every real
 * Mac's tunnel is `c-<id>-g<n>.richos.ceo`, and a route there would capture its traffic. So no
 * name in the `richos.ceo` zone is accepted, whatever its shape.
 */
export function inForbiddenZone(hostname) {
	return hostname === FORBIDDEN_ZONE || hostname.endsWith('.' + FORBIDDEN_ZONE);
}

function parseJson(text, what) {
	try { return JSON.parse(text); } catch { throw new Error(`${what} is not valid JSON`); }
}

/**
 * Validate `env`. Returns `{ ok: true, config }` or `{ ok: false, problems: [sentences] }`. The
 * sentences name settings, never values, so `/healthz` can show them.
 */
export function readConfig(env) {
	const problems = [];
	const need = (cond, sentence) => { if (!cond) problems.push(sentence); };
	const access = String(env.ACCESS_HOSTNAME || '').toLowerCase();
	need(DNS_NAME.test(access), 'ACCESS_HOSTNAME must be a DNS name.');
	need(!inForbiddenZone(access), 'ACCESS_HOSTNAME must not be in the richos.ceo zone (rule M2).');
	let hosts = [];
	try {
		hosts = parseJson(env.REVIEW_HOSTS || '', 'REVIEW_HOSTS');
		if (!Array.isArray(hosts) || !hosts.length || hosts.length > MAX_REVIEW_HOSTS) throw new Error(`REVIEW_HOSTS must list 1 to ${MAX_REVIEW_HOSTS} hosts.`);
	} catch (error) {
		problems.push(error.message);
		hosts = [];
	}
	const names = new Set(), users = new Set();
	hosts = hosts.map((h) => ({ hostname: String(h && h.hostname || '').toLowerCase(), label: String(h && h.label || ''), username: String(h && h.username || '') }));
	for (const h of hosts) {
		need(DNS_NAME.test(h.hostname), 'Every REVIEW_HOSTS hostname must be a DNS name.');
		need(!inForbiddenZone(h.hostname), 'No REVIEW_HOSTS hostname may be in the richos.ceo zone (rule M2).');
		need(h.hostname !== access, 'A review host cannot share the access page hostname.');
		need(!names.has(h.hostname), 'REVIEW_HOSTS hostnames must be unique.');
		need(/^[a-z0-9-]{1,40}$/.test(h.username), 'Every REVIEW_HOSTS username must be 1 to 40 of a-z, 0-9 and hyphen.');
		need(!users.has(h.username), 'REVIEW_HOSTS usernames must be unique.');
		need(h.label.length > 0 && h.label.length <= 60, 'Every REVIEW_HOSTS label must be 1 to 60 characters.');
		names.add(h.hostname);
		users.add(h.username);
	}
	let hashes = {};
	try { hashes = parseJson(env.REVIEW_PASSWORD_HASHES || '', 'REVIEW_PASSWORD_HASHES'); } catch (error) { problems.push(error.message); }
	for (const h of hosts) need(typeof hashes[h.username] === 'string' && hashes[h.username].startsWith('pbkdf2-sha256$'), 'REVIEW_PASSWORD_HASHES needs a hash for every username.');
	let sessionKeyOk = false;
	try { sessionKeyOk = unb64url(String(env.SESSION_KEY || '')).length === 32; } catch { sessionKeyOk = false; }
	need(sessionKeyOk, 'SESSION_KEY must be base64url of 32 bytes.');
	need(Boolean(env.HOSTS && typeof env.HOSTS.idFromName === 'function'), 'The HOSTS Durable Object binding is missing.');
	need(Boolean(env.LOGIN_LIMIT && typeof env.LOGIN_LIMIT.limit === 'function'), 'The LOGIN_LIMIT rate-limit binding is missing.');
	const words = String(env.PAIRING_WORDS || 'v1');
	need(words === 'v1' || words === 'v2', 'PAIRING_WORDS must be v1 or v2.');
	const connectOrigin = String(env.CONNECT_ORIGIN || 'https://connect.richos.ceo');
	need(/^https:\/\/[a-z0-9.-]+$/.test(connectOrigin), 'CONNECT_ORIGIN must be an https origin.');
	let hostKeys = null;
	if (env.REVIEW_HOST_KEYS) {
		try {
			hostKeys = parseJson(env.REVIEW_HOST_KEYS, 'REVIEW_HOST_KEYS');
			for (const h of hosts) need(typeof hostKeys[h.hostname] === 'string', 'REVIEW_HOST_KEYS needs a key for every review host, or must be absent.');
		} catch (error) {
			problems.push(error.message);
		}
	}
	if (problems.length) return { ok: false, problems: [...new Set(problems)] };
	return {
		ok: true,
		config: { accessHostname: access, hosts, hashes, sessionKey: env.SESSION_KEY, pairingVersion: words === 'v2' ? 2 : 1, connectOrigin, hostKeys }
	};
}

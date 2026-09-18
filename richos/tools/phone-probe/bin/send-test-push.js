#!/usr/bin/env node
'use strict';

// Send a push to a subscription by hand, from a terminal.
//
// Why this exists: on the phone, check 4 asks him to close the app and wait. If nothing arrives, the
// next question is always "was it never sent, or was it sent and not shown?" — and those have
// completely different fallbacks. This answers that half from here, without his phone, by printing
// exactly what the push service said.
//
//   node bin/send-test-push.js --url https://<origin> --code <access code> [--id <device id>]
//
// With no --id it sends to every device the server currently holds, which for this probe is his
// phone and whatever desktop browser was used to test.

const args = process.argv.slice(2);
function arg(name, fallback) {
	const i = args.indexOf(`--${name}`);
	return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}

const baseUrl = arg('url', process.env.PROBE_URL || 'http://localhost:8788').replace(/\/+$/, '');
const code = arg('code', process.env.PROBE_ACCESS_CODE || '');
const id = arg('id', '');
const delay = Number(arg('delay', '0'));

function withCode(path) {
	if (!code) return baseUrl + path;
	return baseUrl + path + (path.includes('?') ? '&' : '?') + 'k=' + encodeURIComponent(code);
}

async function api(path, options) {
	const init = Object.assign({ headers: {} }, options || {});
	init.headers = Object.assign({ 'Content-Type': 'application/json' }, init.headers);
	if (code) init.headers['x-probe-code'] = code;
	const res = await fetch(withCode(path), init);
	const text = await res.text();
	if (!res.ok) throw new Error(`${path} -> HTTP ${res.status}: ${text.slice(0, 200)}`);
	return text ? JSON.parse(text) : {};
}

(async () => {
	if (!id) {
		process.stdout.write(
			'No --id given.\n\n' +
			'The server does not list its devices: an endpoint that enumerates who is subscribed is a\n' +
			'thing an unauthorized caller would want, and the plan\'s doctrine (§2) is that such a caller\n' +
			'learns nothing at all. The id is printed by the page when it subscribes, and it is in the\n' +
			'browser\'s localStorage under "richos-phone-probe-v1".\n\n' +
			'Usage: node bin/send-test-push.js --url <origin> --code <code> --id <device id> [--delay 60]\n'
		);
		process.exit(2);
	}

	const scheduled = await api('/api/test-push', { method: 'POST', body: JSON.stringify({ id, delaySeconds: delay }) });
	process.stdout.write(`scheduled: due at ${scheduled.dueAt} (in ${scheduled.delaySeconds}s)\n`);

	// Poll until the server has a result, so this command ends with the push service's own answer
	// rather than with "a request was issued".
	const deadline = Date.now() + (delay + 30) * 1000;
	for (;;) {
		await new Promise((r) => setTimeout(r, 1000));
		const status = await api(`/api/status?id=${encodeURIComponent(id)}`);
		if (status.lastSend) {
			const s = status.lastSend;
			process.stdout.write(`push service: HTTP ${s.statusCode}${s.ok ? ' (accepted)' : ''}${s.gone ? ' — subscription GONE, the server has forgotten it' : ''}\n`);
			if (s.detail) process.stdout.write(`detail: ${s.detail}\n`);
			process.exit(s.ok ? 0 : 1);
		}
		if (Date.now() > deadline) {
			process.stdout.write('timed out waiting for the server to report a result\n');
			process.exit(1);
		}
	}
})().catch((err) => {
	process.stderr.write(`${err.message}\n`);
	process.exit(1);
});

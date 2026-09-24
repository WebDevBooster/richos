// THE REVIEW ACCESS PAGE: the reviewer's Mac.
//
// A real Mac shows a pairing code, and after a phone reaches it, the six words and the "They
// match" press (Sage's v2 pairing contract, section 3). A reviewer has no Mac, so this page plays
// that part for exactly one review host: it issues fresh pairing links and QR codes on demand,
// shows the words once a phone has arrived, and carries the Mac-side press. It holds no Mac, no
// AI and nothing of the CEO's.
//
// Credentials are per review host (Apple's reviewer signs in to Apple's host, Google's to
// Google's), so no reviewer can replace another's pairing. They are written into store review
// notes and are treated as public (Sage M6): they unlock this fictional host and nothing else.

import { sha256hex } from './codec.mjs';
import { escape, layout, pageHeaders } from './pages.mjs';
import { qrSvg } from './qr.mjs';
import { checkSession, clearedCookie, issueSession, sessionCookie, verifyPassword } from './session.mjs';

const MAX_FORM_BYTES = 4096;

const NOTICES = {
	confirmed: ['ok', 'Paired. RichConnect is now connected to this review host.'],
	expired: ['warn', 'Nobody pressed They match on this page within 5 minutes, so the waiting phone was removed. Get a fresh pairing link to try again.'],
	'rejected-on-mac': ['warn', 'You pressed They do not match, so that phone was removed. Get a fresh pairing link to try again.'],
	'rejected-on-phone': ['warn', 'The phone reported that the six words did not match, so it was removed. Get a fresh pairing link to try again.'],
	'two-phones-removed': ['warn', 'Two phones used the same pairing link. The phone that was waiting was removed to be safe. Get a fresh pairing link to try again.'],
	'two-phones-kept': ['warn', 'Another phone tried to use a pairing link that had already been used. Your paired phone was not affected.']
};

const clock = (ms) => new Date(ms).toISOString().slice(11, 16) + ' UTC';
const minutesLeft = (ms, now) => Math.max(0, Math.ceil((ms - now) / 60000));

async function html(status, body, extraHeaders = {}) {
	return new Response(body, { status, headers: { ...(await pageHeaders()), ...extraHeaders } });
}

function redirect(location, extraHeaders = {}) {
	return new Response(null, { status: 303, headers: { location, 'cache-control': 'no-store', ...extraHeaders } });
}

function form(action, button, { secondary = false, fields = '' } = {}) {
	return `<form class="inline" method="post" action="${action}">${fields}<button type="submit"${secondary ? ' class="secondary"' : ''}>${escape(button)}</button></form>`;
}

function confirmForm(action, button, sentence) {
	const id = action.replace(/\W/g, '');
	return `<form method="post" action="${action}"><label class="check" for="${id}"><input type="checkbox" id="${id}" name="confirm" value="yes" required> ${escape(sentence)}</label><button type="submit" class="secondary">${escape(button)}</button></form>`;
}

export function loginPage(error) {
	return layout('RichConnect review access', `<h1>RichConnect review access</h1>
<p>This page stands in for the Mac that RichConnect normally pairs with. Sign in with the review credentials from the review notes.</p>
${error ? `<p class="warn" role="alert">${escape(error)}</p>` : ''}
<form method="post" action="/login">
<label for="username">Username</label><input type="text" id="username" name="username" autocomplete="username" autocapitalize="none" spellcheck="false" required>
<label for="password">Password</label><input type="password" id="password" name="password" autocomplete="current-password" required>
<button type="submit">Sign in</button>
</form>`);
}

/** The one page a signed-in reviewer sees, for their review host, in its current state. */
export function hostView({ label, username, status, now }) {
	const parts = [`<h1>RichConnect review access</h1>
<p class="soft">${escape(label)} · review host ${escape(status.hostname)}</p>
<p>This page is the Mac for your review. It gives your phone a pairing link and confirms the pairing, as RichOS does on a Mac. Everything on this review host is fictional, and every reply is simulated and labeled “Demo reply”. No AI is involved.</p>`];
	if (status.notice && NOTICES[status.notice.kind]) {
		const [tone, sentence] = NOTICES[status.notice.kind];
		parts.push(`<p class="${tone === 'warn' ? 'warn' : ''}" role="status">${escape(sentence)}</p>`);
	}
	const p = status.paired;
	if (p && p.active) {
		parts.push(`<div class="card"><h2>Paired</h2>
<p>RichConnect on <strong>${escape(p.name)}</strong> is paired with this review host.</p>
<p>Things to try in the app:</p>
<ul><li>Send a text message. A demo reply arrives within a few seconds.</li>
<li>Hold the microphone button to record a voice message, then release it to send.</li>
<li>Attach a photo or a file. The review host checks it the way a Mac would, then discards it.</li>
<li>Play a reply. The review host plays a short chime where a Mac would speak.</li>
${status.push.configured ? '<li>Turn on notifications in the app. Send a message, then close the app or lock the phone right away. The demo reply arrives as a notification about 6 seconds later; tap it to open the conversation.</li>' : '<li>Notifications are not switched on for this review host.</li>'}</ul></div>
<div class="card"><h2>Pair a different phone</h2>
<p>Only one phone at a time can be paired with a review host, as with a Mac.</p>
${confirmForm('/replace', 'Remove this phone and get a new link', 'I understand this removes the paired phone from this review host.')}</div>
<div class="card"><h2>Start over</h2>
<p>Restores the sample conversations and removes the paired phone. Only this review host is affected.</p>
${confirmForm('/reset', 'Reset this review host', 'I understand this removes the paired phone and restores the sample conversations.')}</div>`);
	} else if (p) {
		parts.push(`<div class="card"><h2>A phone reached this review host</h2>
<p><strong>${escape(p.name)}</strong> is waiting to be confirmed. Check that RichConnect shows these six words:</p>
<p class="words">${status.words.map(escape).join(' ')}</p>
<p>If they match, press They match in the app and here. If they do not, press They do not match.</p>
${form('/confirm', 'They match', { fields: '<input type="hidden" name="match" value="yes">' })}
${form('/confirm', 'They do not match', { secondary: true, fields: '<input type="hidden" name="match" value="no">' })}
<p class="soft">If nobody presses They match by ${escape(clock(p.window_ends))} (about ${minutesLeft(p.window_ends, now)} min), the phone is removed and you can start again.</p></div>`);
	} else if (status.pairing) {
		const link = status.pairing.link;
		parts.push(`<div class="card"><h2>Pair your phone</h2>
<p>This link works until ${escape(clock(status.pairing.expires_at))} (about ${minutesLeft(status.pairing.expires_at, now)} min). It can pair one phone.</p>
<ol><li>Open RichConnect on the phone you are reviewing and scan this code with it.</li>
<li>Or, on that phone, copy the link below and paste it into RichConnect's pairing link field.</li>
<li>When the app shows six words, come back to this page and select Refresh.</li></ol>
<div class="qr">${qrSvg(link)}</div>
<label for="pairing-link">Pairing link</label>
<input type="text" id="pairing-link" value="${escape(link)}" readonly>
<button type="button" data-copy="pairing-link">Copy link</button>
<p><a href="/">Refresh</a></p></div>
${form('/link', 'Get a new link instead', { secondary: true })}`);
	} else {
		parts.push(`<div class="card"><h2>Pair your phone</h2>
<p>Get a pairing link. It works for 5 minutes and pairs one phone. You can get a new one at any time.</p>
${form('/link', 'Get a pairing link')}</div>`);
	}
	parts.push(`<p class="soft">Signed in as ${escape(username)}.</p>${form('/logout', 'Sign out', { secondary: true })}`);
	return layout('RichConnect review access', parts.join('\n'));
}

async function readForm(request) {
	const declared = Number(request.headers.get('content-length') || 0);
	if (declared > MAX_FORM_BYTES) return null;
	const text = await request.text();
	if (text.length > MAX_FORM_BYTES) return null;
	return new URLSearchParams(text);
}

/**
 * Handle one request for the access hostname.
 * @param {Request} request
 * @param {object} config from `readConfig`
 * @param {object} ports `{ hostApi(hostname) -> { status, openPairing, confirmOnMac, replacePhone, reset }, loginLimit, now }`
 */
export async function handlePortal(request, config, { hostApi, loginLimit, now = Date.now }) {
	const url = new URL(request.url);
	const origin = `https://${config.accessHostname}`;
	const method = request.method.toUpperCase();

	if (method === 'GET' && url.pathname === '/healthz') {
		return new Response(JSON.stringify({ service: 'richconnect-review', ready: true, hosts: config.hosts.length, push: Boolean(config.hostKeys), pairing_words: `v${config.pairingVersion}` }), {
			status: 200, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
		});
	}

	if (method === 'POST') {
		// Cross-site request forgery: a POST must come from this page itself.
		if (request.headers.get('origin') !== origin) return html(403, layout('Not allowed', '<h1>Not allowed</h1><p>This form must be sent from the review access page itself.</p>'));
	} else if (method !== 'GET' && method !== 'HEAD') {
		return new Response(null, { status: 405, headers: { allow: 'GET, POST' } });
	}

	if (method === 'POST' && url.pathname === '/login') {
		const ip = request.headers.get('cf-connecting-ip') || 'unknown';
		const allowed = await loginLimit.limit({ key: 'login:' + (await sha256hex(ip)) });
		if (!allowed.success) return html(429, loginPage('Too many sign-in attempts. Wait a minute, then try again.'), { 'retry-after': '60' });
		const fields = await readForm(request);
		const username = fields && fields.get('username') || '';
		const password = fields && fields.get('password') || '';
		const host = config.hosts.find((h) => h.username === username.trim().toLowerCase());
		// Always derive once, so a wrong username costs the same as a wrong password.
		const hash = host ? config.hashes[host.username] : 'pbkdf2-sha256$100000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
		const ok = await verifyPassword(password, hash);
		if (!host || !ok) return html(401, loginPage('That username and password did not match. Check the review notes and try again.'));
		return redirect('/', { 'set-cookie': sessionCookie(await issueSession(config.sessionKey, now(), host.username)) });
	}

	if (method === 'POST' && url.pathname === '/logout') return redirect('/', { 'set-cookie': clearedCookie() });

	const subject = await checkSession(request.headers.get('cookie'), config.sessionKey, now());
	const host = subject && config.hosts.find((h) => h.username === subject);
	if (!host) {
		if (method === 'GET' && url.pathname === '/') return html(200, loginPage());
		return redirect('/');
	}
	const api = hostApi(host.hostname);

	if (method === 'GET' && url.pathname === '/') {
		return html(200, hostView({ label: host.label, username: host.username, status: await api.status(), now: now() }));
	}
	if (method === 'POST') {
		const fields = (await readForm(request)) || new URLSearchParams();
		if (url.pathname === '/link') await api.openPairing();
		else if (url.pathname === '/confirm') await api.confirmOnMac(fields.get('match') === 'yes');
		else if (url.pathname === '/replace' && fields.get('confirm') === 'yes') await api.replacePhone();
		else if (url.pathname === '/reset' && fields.get('confirm') === 'yes') await api.reset();
		return redirect('/');
	}
	return html(404, layout('Not found', '<h1>Not found</h1><p><a href="/">Go to the review access page</a></p>'));
}

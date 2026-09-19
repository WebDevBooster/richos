'use strict';

// Rich, on a phone. One screen, four verbs: send text, send a voice note, receive Rich, hear Rich.
//
// This file is the wiring. The parts that can be wrong in a way a person notices live in `lib/`,
// where they are driven by tests without a browser: the recorder's arithmetic (`pcm.js`), the send
// queue's state machine (`queue.js`), the thread's ordering (`thread.js`), the routes (`api.js`),
// and what survives being closed (`storage.js`). What is left here is the part that only means
// anything with a screen attached, and the browser harness drives it in a real browser.
//
// THREE DECISIONS IN HERE ARE THE PRODUCT, not implementation detail:
//
//   1. THE MICROPHONE PROMPT IS PART OF THE GESTURE, NOT A MODAL BEFORE IT. iOS asks for the
//      microphone on every launch of an installed web app — measured on his own iPhone X on
//      2026-09-18, and the browser reported the permission as "granted" while still asking. So the
//      first hold of the session opens the microphone and the dialog appears under his finger. When
//      he lifts his finger to tap Allow, the release does NOT become a dead recording: the app says
//      the microphone is on and asks him to hold again. A dead recording there is the app telling
//      him the microphone is broken when it is working, which is the worst thing it could say.
//
//   2. THE THREE SEND STATES ARE HONEST, and the middle one is the real one. An optimistic bubble;
//      then "waiting to send — your Mac isn't reachable from here" with the reason; then delivered
//      when the Mac has it. The middle state is not a reassurance — it is the truth that his message
//      is still on this phone.
//
//   3. NOTHING HE READS IS AN IDENTIFIER. No message id, no device id, no cursor, no hash. His probe
//      walk ended with a horizontal scroll bar caused by a SHA-256 printed in one line; the rule
//      that came out of it is not "wrap the hash", it is "do not put one in front of him".

(function () {

const $ = (id) => document.getElementById(id);
const TIME = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' });

const pcm = globalThis.RichOSPcm;
const fingerprint = globalThis.RichOSFingerprint;
const Storage = globalThis.RichOSStorage;

// ---------------------------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------------------------

let db = null;
let settings = null;
let messageCache = null;
let keyStore = null;
let queue = null;
let thread = null;
let api = null;
let signer = null;

let apiState = { apiBase: location.origin, challenge: null, deviceId: null };
let threads = [];
let currentThreadId = null;
// The ONE owner of the event stream (`lib/link.js`). It used to be a bare `stream` handle plus a
// boolean, and both the closing and the reconnecting were spread across four places that could not
// see each other. There is no `stream` variable any more on purpose: nothing outside the link is
// allowed to hold a source, which is what makes "never more than one alive" a property rather than
// a hope.
let link = null;
/// The sentence currently under the header, by name. Read only to keep a retry from flickering it.
let linkStateNow = null;
let vapidPublicKey = null;
// See `refreshPushOffer` — his answer, not his permission state.
let notificationsDeclined = false;
let loadingOlder = false;
let renderQueued = false;
let pendingPairCode = null;

// The recorder, and the one flag the whole permission design hangs on.
let micStream = null;
let audioCtx = null;
let captureNode = null;
let chunks = [];
let recording = false;
let opening = false;
let heldDown = false;
let askedForMicrophoneThisLaunch = false;
let autoStopTimer = null;
const MAX_RECORD_SECONDS = 120;

// One audio element, unlocked on his first tap, reused for every "hear it". Safari will not start
// playback that is not inside a user gesture, and an `await` loses the gesture — so the element is
// started (on silence) inside the first tap he makes anywhere, and from then on it may be played.
let player = null;
let playerUnlocked = false;
let silentWavUrl = null;
let playingButton = null;

// ---------------------------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------------------------

async function boot() {
	try {
		db = await Storage.open();
	} catch (err) {
		// Private browsing, or a storage quota refusal. Without storage there is no queue and no
		// key, so this is said plainly rather than limped past.
		showTakeover('revoked');
		$('revoked-detail').textContent = 'This phone cannot store anything for Rich, so pairing and the send queue cannot work here. That is usually private browsing.';
		return;
	}

	settings = Storage.settings(db);
	messageCache = Storage.messages(db);
	keyStore = Storage.keys(db);

	const saved = await settings.all();
	apiState = {
		// The origin is the app's identity and never changes; the base is data, and it starts as
		// the origin (plan §10.7).
		apiBase: saved.apiBase || location.origin,
		challenge: saved.challenge || null,
		deviceId: saved.deviceId || null
	};
	vapidPublicKey = saved.vapidPublicKey || null;
	// He was asked about notifications and did not say yes. Remembered across a relaunch for one
	// reason: so the banner keeps telling him what that MEANT rather than reverting to the generic
	// offer, which is a reload asking him a question he has already answered.
	notificationsDeclined = Boolean(saved.notificationsDeclined);
	currentThreadId = saved.threadId || null;
	threads = saved.threads || [];

	const pair = /[#&]pair=([^&]+)/.exec(location.hash || '');
	pendingPairCode = pair ? decodeURIComponent(pair[1]) : null;

	const keys = await keyStore.load();

	if (!keys || !apiState.deviceId || pendingPairCode) {
		await startPairing(keys);
		return;
	}

	await startConversation(keys);
}

async function persistState() {
	await settings.set('apiBase', apiState.apiBase);
	await settings.set('challenge', apiState.challenge);
	await settings.set('deviceId', apiState.deviceId);
	// An address the Mac advertised that this app would not take, kept where it can be found.
	// Nothing renders it — said here so nobody goes looking for a message on the screen — but a
	// phone that declined to move to a new address now has the reason attached to it rather than
	// having silently ignored its Mac (plan §2 C).
	await settings.set('apiBaseRefusal', apiState.apiBaseRefusal || null);
}

function makeApi(keys) {
	signer = Storage.createSigner(crypto.subtle, keys, apiState);
	api = globalThis.RichOSApi.createApi({
		state: apiState,
		signer,
		onState: () => { persistState().catch(() => { /* a failed write must not kill a send */ }); }
	});
	return api;
}

// ---------------------------------------------------------------------------------------------
// Pairing — the phone half (plan §4.1)
// ---------------------------------------------------------------------------------------------

function showTakeover(which) {
	document.body.classList.toggle('pairing', which === 'pairing');
	document.body.classList.toggle('revoked', which === 'revoked');
	$('pairing').hidden = which !== 'pairing';
	$('revoked').hidden = which !== 'revoked';
}

function hideTakeovers() {
	document.body.classList.remove('pairing', 'revoked');
	$('pairing').hidden = true;
	$('revoked').hidden = true;
}

async function startPairing(existingKeys) {
	showTakeover('pairing');

	if (!pendingPairCode) {
		// There is no control on this phone that can pair it — the code comes from the Mac. So the
		// screen says exactly what to do THERE, rather than offering a button that cannot work.
		$('pairing-lede').textContent = 'This phone is not paired with your Mac yet.';
		$('pairing-detail').textContent = 'On your Mac, open RichOS and choose "Use Rich from your phone". Point this phone\'s camera at the second code it shows, and this screen will carry on from there.';
		return;
	}

	$('pairing-lede').textContent = 'Pairing with your Mac…';
	$('pairing-detail').textContent = '';

	let keys = existingKeys;
	if (!keys) {
		// Generated HERE, on the phone, and the private half is non-extractable: it cannot be read
		// out by this script or any other, now or later (plan §2.7, §20's rule).
		keys = await Storage.generateDeviceKey(crypto.subtle);
		await keyStore.save(keys);
	}
	makeApi(keys);

	let publicJwk;
	try {
		publicJwk = await crypto.subtle.exportKey('jwk', keys.publicKey);
	} catch (err) {
		$('pairing-lede').textContent = 'This phone could not make a key for itself.';
		$('pairing-detail').textContent = String(err && err.message ? err.message : err);
		return;
	}

	let answer;
	try {
		answer = await api.pair(pendingPairCode, publicJwk, deviceName());
	} catch (err) {
		$('pairing-lede').textContent = err && err.reason === 'unreachable'
			? 'Your Mac could not be reached from here.'
			: 'Your Mac did not accept that pairing code.';
		$('pairing-detail').textContent = err && err.reason === 'unreachable'
			? 'Make sure you are on the same Wi-Fi as your Mac, that RichOS is open on it, and try the code again.'
			: 'A pairing code is good for sixty seconds and for one phone. Show a fresh one on your Mac and open it again.';
		return;
	}

	vapidPublicKey = answer.vapid_public_key || null;
	threads = answer.threads || [];
	currentThreadId = (threads[0] && threads[0].id) || answer.thread_id || null;

	// SIX WORDS, computed here from the hash the Mac sent — never taken from the Mac as words, and
	// never shown to him as a hash.
	let words;
	try {
		words = fingerprint.phraseFromHex(answer.ca_fingerprint_sha256);
	} catch (err) {
		$('pairing-lede').textContent = 'Your Mac sent something this app could not read.';
		$('pairing-detail').textContent = 'Tell Rich. Pairing has not happened and nothing was stored.';
		return;
	}

	$('pairing-lede').textContent = 'Almost done. One thing to check, and it is the thing that matters.';
	$('fingerprint-note').textContent = whatTheSixWordsAre();
	$('fingerprint-words').textContent = words;
	$('fingerprint-box').hidden = false;
	$('pairing-row').hidden = false;
}

function deviceName() {
	// Named for him, not for a log. "iPhone" is what he calls it.
	if (/iPad/.test(navigator.userAgent)) return 'iPad';
	if (/iPhone/.test(navigator.userAgent)) return 'iPhone';
	if (/Android/.test(navigator.userAgent)) return 'Android phone';
	return 'Phone';
}

$('pair-confirm').addEventListener('click', async () => {
	$('pair-confirm').disabled = true;
	await settings.set('threads', threads);
	await settings.set('threadId', currentThreadId);
	await settings.set('vapidPublicKey', vapidPublicKey);
	await persistState();
	// The pairing code is single use; leaving it in the address would re-run pairing on the next
	// launch and fail with a stale code.
	history.replaceState(null, '', location.pathname);
	pendingPairCode = null;
	const keys = await keyStore.load();
	hideTakeovers();
	await startConversation(keys);
});

$('pair-reject').addEventListener('click', async () => {
	// He said the words do not match. That is the one outcome where continuing would be worse than
	// stopping: the credential is thrown away rather than kept "just in case".
	await keyStore.clear();
	await settings.set('deviceId', null);
	apiState.deviceId = null;
	$('fingerprint-box').hidden = true;
	$('pairing-row').hidden = true;
	$('pairing-lede').textContent = 'Stopped, and nothing was paired.';
	$('pairing-detail').textContent = 'If the six words on this phone are not the six words on your Mac, this phone was not talking to your Mac. Tell Rich, and do not pair again until he has looked at it.';
});

// ---------------------------------------------------------------------------------------------
// The conversation
// ---------------------------------------------------------------------------------------------

async function startConversation(keys) {
	hideTakeovers();
	if (!api) makeApi(keys);

	thread = globalThis.RichOSThread.createThread();
	queue = globalThis.RichOSQueue.createQueue({
		storage: Storage.queueStorage(db),
		onChange: () => { scheduleRender(); updateQueueBanner(); }
	});

	await queue.load();
	renderThreadPicker();

	// What he last saw, straight away, before any network. Opening the app on a train shows the
	// conversation rather than a spinner — the cache is a view, and the Mac replaces it the moment
	// it is reachable.
	const cached = await messageCache.recent(currentThreadId, 60);
	if (cached.length) thread.merge(cached);
	render(true);

	setLinkState('opening');
	connectStream();
	await refreshPushOffer();
	flushQueue();
}

function setLinkState(which, detail) {
	const el = $('link-state');
	linkStateNow = which;
	el.classList.toggle('away', which === 'away');
	if (which === 'connected') el.textContent = 'Connected to your Mac.';
	else if (which === 'opening') el.textContent = 'Looking for your Mac…';
	else if (which === 'away') el.textContent = detail || 'Your Mac isn’t reachable from here.';
	else el.textContent = detail || '';
}

// A CONTROL IS RENDERED ONLY WHERE THE MAC HAS NAMED THE CAPABILITY BEHIND IT (plan §2 A).
//
// The app shipped "Hold to record" as one of the two biggest controls on the screen against a Mac
// that answers every voice note `503`. The decision itself is in `lib/api.js` and is default-deny,
// so this function cannot show a control by omission: it is only ever reached with an answer the
// Mac gave, and both halves ship `hidden` in `index.html`. What is left here is the DOM.
function applyCapabilities() {
	if (!api) return;
	// Never while his finger is down. The release is handled by the button, so taking the button
	// out from under a live recording is how a recording never ends. `stopRecording` calls this
	// again the moment it is over, so a Mac that changed its mind is honored a second later.
	if (recording) return;
	const voice = api.offers('voice');
	hold.hidden = !voice;
	$('hold-note').hidden = !voice;
}

/// Is there a stream the Mac has accepted, right now? The link is the only thing that knows.
function streamIsOpen() { return Boolean(link && link.isOpen()); }

/// Build the one link, once. Everything it needs — the thread, the cursor, the credential — is
/// read at the moment of each attempt rather than captured here, because an attempt three minutes
/// into an outage must sign the challenge the phone has THEN, not the one it had when the app
/// booted. That is the whole point of the slice.
function makeLink() {
	return globalThis.RichOSLink.createLink({
		open: (handlers) => api.openEvents(currentThreadId, thread.latestCursor(), handlers),
		refresh: () => api.refreshChallenge(),

		// The sentence on screen, and nothing else decides it.
		onState: (which) => {
			// A RETRY DOES NOT FLICKER THE LINE. Once he is being told the Mac is not reachable,
			// that sentence is TRUE and it stays up. An attempt against a Mac that is off fails in
			// a fraction of a second, so mapping every attempt to "Looking for your Mac…" would
			// flash the line at him six times in the first minute and then twice a minute for as
			// long as the walk lasts — the app fidgeting rather than telling him anything new.
			// The first attempt still says it, because then it is news.
			if (which === 'opening' && linkStateNow === 'away') return;
			if (which === 'open') setLinkState('connected');
			else if (which === 'opening') setLinkState('opening');
			else setLinkState('away');
			updateQueueBanner();
		},

		handlers: {
			open() { flushQueue(); },
			hello(data) {
				// What this Mac can actually be asked for, before anything else in this handler:
				// the screen should never be one frame ahead of what the Mac has said it can do.
				applyCapabilities();
				// **BOTH SIDES OF THE CONVERSATION, AND THIS IS WHERE ONE OF THEM WENT.**
				//
				// The Mac puts the whole gated projection in every `hello` — *"The rows
				// themselves ride along, so the first paint needs no second request"*
				// (`app/src-tauri/src/phone/routes.rs:492-494`) — and it puts BOTH roles in it:
				// `rows_from_payload` keeps `user_message` and `rich_message` and drops only
				// machinery (`phone/rows.rs:49-109`, proved by its own
				// `only_the_conversation_reaches_the_phone_and_no_machinery_does`). This handler
				// read `vapid_public_key` and `threads` out of that frame and dropped
				// `data.messages` on the floor.
				//
				// What that looked like on his phone, on 2026-09-18: a list of answers with no
				// questions. The live stream can only ever open a `role: "rich"` row
				// (`phone/rows.rs:115-173`), so Rich's replies arrived and nothing he wrote ever
				// did — not from this phone, not from the Mac. It is the one frame that carries
				// his own words, and it is merged before anything else in this handler touches
				// the screen.
				if (Array.isArray(data.messages) && data.messages.length) {
					thread.merge(data.messages);
					messageCache.put(data.messages).catch(() => {});
					scheduleRender();
				}
				if (data.vapid_public_key) {
					vapidPublicKey = data.vapid_public_key;
					settings.set('vapidPublicKey', vapidPublicKey).catch(() => {});
				}
				if (Array.isArray(data.threads) && data.threads.length) {
					threads = data.threads;
					settings.set('threads', threads).catch(() => {});
					renderThreadPicker();
				}
				flushQueue();
			},
			message(row) {
				thread.merge(row);
				messageCache.put(row).catch(() => {});
				scheduleRender();
				if (row && row.role === 'rich' && row.complete) askForTheQuestion(row);
			},
			delta(data) { thread.applyDelta(data); scheduleRender(); },
			state(data) { thread.applyState(data); scheduleRender(); }
		}
	});
}

function connectStream() {
	if (!currentThreadId) return;
	if (!link) link = makeLink();
	link.connect();
}

// ---------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------

function scheduleRender() {
	if (renderQueued) return;
	renderQueued = true;
	requestAnimationFrame(() => { renderQueued = false; render(false); });
}

function atBottom() {
	const el = $('thread');
	return el.scrollHeight - el.scrollTop - el.clientHeight < 80;
}

function render(forceBottom) {
	const list = $('messages');
	const wasAtBottom = forceBottom || atBottom();
	const rows = thread.view(queue ? queue.all() : []);

	// "Delivered." belongs on the LAST thing he sent and nowhere else. Repeating it under every
	// message he has ever written turns the one state he might actually look for into wallpaper.
	let lastDelivered = -1;
	rows.forEach((row, i) => { if (!row.pending && row.role === 'ceo') lastDelivered = i; });

	list.textContent = '';
	rows.forEach((row, i) => list.appendChild(renderRow(row, i === lastDelivered)));

	const older = $('older');
	if (thread.atTheBeginning() && rows.length) {
		older.hidden = false;
		older.textContent = 'This is the beginning of the conversation.';
	} else if (loadingOlder) {
		older.hidden = false;
		older.textContent = 'Loading earlier messages…';
	} else {
		older.hidden = true;
	}

	if (!rows.length) {
		const empty = document.createElement('li');
		empty.className = 'msg msg-rich';
		const p = document.createElement('p');
		p.className = 'msg-text';
		// **THE SENTENCE NAMES WHAT IS ON SCREEN, AND IT READS THE SCREEN TO FIND OUT.**
		//
		// It used to say "or hold the button and speak" unconditionally, on a phone whose composer
		// is a text field and a Send button and nothing else (Ray, candidate .11, §4.4). The
		// control it names is hidden unless the Mac's `hello` lists `voice` in `capabilities`, and
		// this build's Mac answers every voice note 503 and advertises `["text"]`
		// (`app/src-tauri/src/phone/routes.rs` `CAPABILITIES`) — so the sentence pointed at
		// something that was never going to be there.
		//
		// It asks `hold.hidden` rather than `api.offers('voice')` on purpose. `applyCapabilities`
		// stays the ONE place that decides whether the control is on screen (`test/controls.test.js`
		// holds that property); this reads the answer rather than deciding it a second time, so the
		// sentence cannot disagree with the screen it is describing.
		const canSpeak = !$('hold').hidden;
		p.textContent = streamIsOpen()
			? (canSpeak
				? 'Nothing here yet. Write to Rich, or hold the button and speak.'
				: 'Nothing here yet. Write to Rich.')
			: 'Nothing here yet. When your Mac is reachable, this is where the conversation appears.';
		empty.appendChild(p);
		list.appendChild(empty);
	}

	if (wasAtBottom) $('thread').scrollTop = $('thread').scrollHeight;
}

function renderRow(row, isLastDelivered) {
	const li = document.createElement('li');
	const mine = row.role === 'ceo' || row.pending;
	li.className = `msg ${mine ? 'msg-mine' : 'msg-rich'}`;

	if (row.kind === 'voice' && !row.text) {
		const voice = document.createElement('p');
		voice.className = 'msg-voice msg-text';
		voice.textContent = row.seconds
			? `Voice note, ${Math.round(row.seconds)} seconds.`
			: 'Voice note.';
		li.appendChild(voice);
	} else {
		const text = document.createElement('p');
		text.className = 'msg-text';
		text.textContent = row.text || '';
		li.appendChild(text);
	}

	if (row.truncated) {
		const note = document.createElement('p');
		note.className = 'truncated';
		note.textContent = 'The rest of this is waiting on your Mac.';
		li.appendChild(note);
	}

	const meta = document.createElement('p');
	meta.className = 'msg-meta';

	if (row.from_microphone) {
		const mic = document.createElement('span');
		mic.textContent = 'Spoken';
		meta.appendChild(mic);
	}

	const when = document.createElement('span');
	when.textContent = timeOf(row);
	meta.appendChild(when);

	if (row.pending) {
		const state = document.createElement('span');
		if (row.sendState === 'blocked') {
			state.className = 'msg-state blocked';
			state.textContent = 'Not sent.';
		} else if (row.sendState === 'sending') {
			state.className = 'msg-state';
			state.textContent = 'Sending…';
		} else {
			state.className = 'msg-state waiting';
			state.textContent = 'Waiting to send — your Mac isn’t reachable from here.';
		}
		meta.appendChild(state);
	} else if (mine && isLastDelivered) {
		const state = document.createElement('span');
		state.className = 'msg-state';
		state.textContent = 'Delivered.';
		meta.appendChild(state);
	}

	li.appendChild(meta);

	// A message he sent that can never go needs the control that acts on it, beside it.
	if (row.pending && row.sendState === 'blocked') {
		const drop = document.createElement('button');
		drop.className = 'hear';
		drop.textContent = 'Remove this message';
		drop.addEventListener('click', () => queue.discard(row.clientId));
		li.appendChild(drop);
	}

	// "Hear it" — one tap, per reply, and only when the Mac says there is audio to fetch. Nothing
	// is synthesized for a reply he only reads.
	if (!mine && row.has_audio && row.id) {
		const hear = document.createElement('button');
		hear.className = 'hear';
		hear.type = 'button';
		hear.textContent = 'Hear it';
		hear.addEventListener('click', () => hearIt(row.id, hear));
		li.appendChild(hear);
	}

	return li;
}

function timeOf(row) {
	const raw = row.created_at || row.queuedAt;
	if (!raw) return '';
	const date = new Date(raw);
	return isNaN(date.getTime()) ? '' : TIME.format(date);
}

function renderThreadPicker() {
	const label = $('thread-picker-label');
	const picker = $('thread-picker');
	const title = $('thread-title');

	const current = threads.find((t) => t.id === currentThreadId);
	title.textContent = (current && current.title) || 'Rich';

	// A picker ONLY if there is more than one, and it lists what exists. It does not create threads
	// (plan §3.4) and there is no control here that pretends it can.
	if (threads.length <= 1) { label.hidden = true; return; }

	label.hidden = false;
	picker.textContent = '';
	threads.forEach((t) => {
		const option = document.createElement('option');
		option.value = t.id;
		option.textContent = t.title || 'Conversation';
		if (t.id === currentThreadId) option.selected = true;
		picker.appendChild(option);
	});
}

$('thread-picker').addEventListener('change', async (event) => {
	currentThreadId = event.target.value;
	await settings.set('threadId', currentThreadId);
	thread.reset();
	const cached = await messageCache.recent(currentThreadId, 60);
	if (cached.length) thread.merge(cached);
	renderThreadPicker();
	render(true);
	connectStream();
});

// ---------------------------------------------------------------------------------------------
// Older messages, behind a scroll. Chunked loading, never a page number.
// ---------------------------------------------------------------------------------------------

$('thread').addEventListener('scroll', () => {
	if ($('thread').scrollTop > 120 || loadingOlder || !thread || thread.atTheBeginning()) return;
	const oldest = thread.oldestCursor();
	if (oldest === null) return;
	loadOlder(oldest);
});

/// **A REPLY WITH NO QUESTION IN FRONT OF IT — the fallback, named as one.**
///
/// A message the CEO types ON HIS MAC never reaches this phone live. There is no live event in
/// this build that carries a CEO turn: `LiveEvent` is `TurnStatus`, `MessageStarted`,
/// `MessageDelta`, `MessageCompleted`, `ActivityUpserted`, `WorkerUpserted` and
/// `ThreadSummaryUpdated`, and not one of them carries his words
/// (`app/crates/richos-core/src/live.rs:306-381`); `event_from_live` therefore translates
/// `rich://message-*` and nothing else (`app/src-tauri/src/phone/rows.rs:115-173`). So while he
/// watches the phone and types on the Mac, Rich answers a question the phone never saw.
///
/// **The fix at the cause is a CEO-turn live event in `richos-core`, and it is NOT built here.**
/// This file cannot reach the spine, and the Mac-side emitter cannot read the projection mid-turn
/// either: `PhoneBridge::snapshot` `try_lock`s the spine and, while a turn holds it, serves a
/// cache from BEFORE that turn (`app/src-tauri/src/phone/bridge.rs:141-162`). What is built here
/// is the honest fallback — when a reply settles and the phone is holding nothing of his in front
/// of it, the phone asks the Mac for the rows before it, on the backfill route it already has and
/// already signs.
///
/// Bounded on purpose: at most one request per reply (`reconciled`), and five rows — the question,
/// its answer, and room for the turn before them.
const reconciled = new Set();

async function askForTheQuestion(row) {
	if (!api || !currentThreadId || !row || !row.id) return;
	if (reconciled.has(row.id)) return;
	const shown = thread.view([]);
	const at = shown.findIndex((seen) => seen.id === row.id);
	if (at > 0 && shown[at - 1].role === 'ceo') return;
	reconciled.add(row.id);
	// The Mac's own numbering is the only ordering, and the LIVE sequence can sit behind it: the
	// hub takes one cursor per streamed reply and the projection counts one per message, so a turn
	// he starts on the Mac moves the projection by two and the hub by one. Asking from one past the
	// highest cursor either side knows is what makes the answer include his row rather than stop
	// just short of it.
	const from = Math.max(row.cursor || 0, thread.latestCursor() || 0) + 1;
	try {
		const page = await api.backfill(currentThreadId, from, 5);
		thread.prependOlder(page);
		messageCache.put(page.messages || []).catch(() => {});
		scheduleRender();
	} catch (err) {
		// Never a screen of its own: the reply he is reading is real and already on screen, and the
		// row in front of it arrives with the next `hello` whatever happens here.
		reconciled.delete(row.id);
		handleApiError(err);
	}
}

async function loadOlder(beforeCursor) {
	loadingOlder = true;
	render(false);
	const el = $('thread');
	const heightBefore = el.scrollHeight;
	try {
		const page = await api.backfill(currentThreadId, beforeCursor, 40);
		thread.prependOlder(page);
		messageCache.put(page.messages || []).catch(() => {});
	} catch (err) {
		handleApiError(err);
	} finally {
		loadingOlder = false;
		render(false);
		// Keep his place: the new content went in above him, so the scroll position moves by
		// exactly as much as the document grew.
		el.scrollTop += el.scrollHeight - heightBefore;
	}
}

// ---------------------------------------------------------------------------------------------
// Verb 1 — send text
// ---------------------------------------------------------------------------------------------

const composer = $('composer');

composer.addEventListener('input', () => {
	$('send').disabled = composer.value.trim().length === 0;
	// Grow with what he writes, up to the cap the stylesheet sets.
	composer.style.height = 'auto';
	composer.style.height = `${Math.min(composer.scrollHeight, window.innerHeight * 0.4)}px`;
});

composer.addEventListener('keydown', (event) => {
	// Enter sends, Shift+Enter is a new line — the desktop habit. On the iPhone's own keyboard the
	// return key inserts a line, which is why the Send button is the primary control and not a
	// convenience.
	if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
		event.preventDefault();
		sendText();
	}
});

$('send').addEventListener('click', () => { unlockPlayer(); sendText(); });

async function sendText() {
	const text = composer.value.trim();
	if (!text) return;
	composer.value = '';
	composer.style.height = 'auto';
	$('send').disabled = true;

	await queue.enqueue({
		clientId: newClientId(),
		threadId: currentThreadId,
		kind: 'text',
		text,
		sentAt: new Date().toISOString()
	});
	render(true);
	flushQueue();
}

/// **WHICH WAY IN THIS PHONE CAME, read off the address bar and nothing else.**
///
/// The Mac serves this app on exactly two kinds of origin. At home it is
/// `https://<name>.local:8443` from a certificate authority the Mac made for itself
/// (`app/src-tauri/src/phone/api_base.rs:13`), and he is asked to install a profile for it. Over
/// Tailscale it is `https://<name>.ts.net:8443` — *"with a **publicly trusted** certificate, which
/// is what deletes the"* profile step entirely (`app/src-tauri/src/phone/listen.rs:213`,
/// `mod.rs:315`). Ray reached the second one on the CEO's Android on 2026-09-18 with no
/// interstitial at all, which is only possible with a certificate the phone already trusts.
///
/// Read from `location.hostname` rather than from the pairing payload because the payload does
/// not carry it today (`routes.rs:263-274` sends `device_id`, `ca_fingerprint_sha256`,
/// `vapid_public_key`, `challenge`, `api_base`, `thread_id`, `thread_title`, `threads`) and the
/// address bar does. Anything that is not a `ts.net` name is treated as the home path, so an
/// address nobody has thought of gets the sentence that names a certificate he may have
/// installed — the cautious way round.
function onTheTailscalePath() {
	const host = String(location.hostname || '').toLowerCase();
	return host === 'ts.net' || host.endsWith('.ts.net');
}

/// The sentence under the six words, for the way in this phone actually came.
///
/// **§4.2 of Ray's walk.** On the Tailscale path the phone said *"They are the name of the
/// certificate your Mac made for itself"* while the Mac had just said, in bold on the same flow:
/// *"There is no certificate to install on this path. If your phone asks you to install a
/// profile, something is wrong — tell me."* A careful person reading both concludes something IS
/// wrong, at the moment he is being asked whether the two screens match.
///
/// What is true on both paths is that the words come from a root the Mac made and keeps; what
/// differs is whether there is a certificate of his to compare them to.
function whatTheSixWordsAre() {
	if (onTheTailscalePath()) {
		return 'They are the name of a key your Mac keeps to itself. Nothing was installed on this phone to get here, and nothing needs to be. If they match what is on your Mac, this phone is talking to your Mac and to nothing else.';
	}
	return 'They are the name of the certificate your Mac made for itself. If they match what is on your Mac, this phone is talking to your Mac and to nothing else.';
}

/// **WHAT THIS PHONE CALLS THE CONTROL THAT PUTS THE APP ON ITS HOME SCREEN.**
///
/// The Mac's card says *"Add Rich to your phone's Home Screen"*. On the CEO's HONOR X6b, Chrome's
/// menu offers **"Install and create shortcut"** and there is no item by the other name at all
/// (Ray, candidate .11, §4.5, verified on the device). On his iPhone X, Safari's Share menu does
/// say "Add to Home Screen". One instruction cannot be right for both, and an instruction that
/// names a control the device does not have is one he cannot follow.
///
/// Returns `{ menu, item }` in the device's own words, or `null` when this app cannot say which
/// browser it is in. **`null` means SAY NOTHING**, not "guess": a wrong menu name sends him
/// looking for something that is not there, which is worse than the silence this replaced.
///
/// The user agent is the only thing that can answer this, and it is a string a browser is free to
/// lie in — which is survivable here because the cost of being wrong is a sentence, not a
/// decision. Nothing else in this app reads it.
function installControlName() {
	const ua = String(navigator.userAgent || '');
	// iPadOS reports itself as a Mac and gives itself away with touch points; iPhone and iPod say
	// what they are.
	const iOS = /iPad|iPhone|iPod/.test(ua)
		|| (/Macintosh/.test(ua) && typeof navigator.maxTouchPoints === 'number' && navigator.maxTouchPoints > 1);
	if (iOS) return { menu: 'the Share menu', item: 'Add to Home Screen' };
	// Chrome on Android. Every other Chromium browser on Android puts its own token in the same
	// string and has its own wording, so they are not claimed.
	if (/Android/.test(ua) && /Chrome\//.test(ua) && !/EdgA|OPR\/|SamsungBrowser|Firefox|DuckDuckGo/.test(ua)) {
		return { menu: "your browser's menu", item: 'Install and create shortcut' };
	}
	return null;
}

/// Is this app already on his home screen and running as one?
function alreadyInstalled() {
	if (navigator.standalone === true) return true;               // iOS, all versions
	return Boolean(window.matchMedia && window.matchMedia('(display-mode: standalone)').matches);
}

/// The sentence for a browser that cannot take a push at all until the app is installed — which
/// is iOS Safari in a tab, and is the case that used to be told NOTHING.
///
/// Android Chrome is deliberately not this case: it subscribes from a tab, which is why the page
/// needs no install instruction there and why §4.5 was only ever about the Mac's card.
function installSentence() {
	const control = installControlName();
	if (!control) return null;
	return `Rich can only reach you while this app is open. To let him reach you when it is closed, open ${control.menu} and choose \u201c${control.item}\u201d.`;
}

function newClientId() {
	if (crypto.randomUUID) return crypto.randomUUID();
	const bytes = crypto.getRandomValues(new Uint8Array(16));
	return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// ---------------------------------------------------------------------------------------------
// The queue, and the sentence that tells him the truth about it
// ---------------------------------------------------------------------------------------------

let flushing = false;

async function flushQueue() {
	if (flushing || !queue || !api) return;
	flushing = true;
	try {
		const result = await queue.flush(api);
		// His own message, where he put it, from the Mac's own answer. See `thread.confirm`.
		(result.accepted || []).forEach(({ item, answer }) => thread.confirm(item, answer));
		if (result.reason === 'revoked') { await goRevoked(); return; }
		if (result.sent > 0 && result.waiting === 0 && result.blocked === 0) setLinkState('connected');
		if (result.reason === 'unreachable') setLinkState('away');
	} catch (err) {
		handleApiError(err);
	} finally {
		flushing = false;
		updateQueueBanner();
		scheduleRender();
	}
}

function updateQueueBanner() {
	if (!queue) return;
	const waiting = queue.waitingCount();
	const blocked = queue.blocked().length;
	const banner = $('queue-banner');

	if (!waiting && !blocked) { banner.hidden = true; return; }
	banner.hidden = false;

	if (blocked) {
		$('queue-text').textContent = blocked === 1
			? 'One message could not be sent. Your Mac did not accept it.'
			: `${blocked} messages could not be sent. Your Mac did not accept them.`;
		$('queue-retry').textContent = 'Try again';
	} else {
		// The REASON lives on the message itself and in the line under the title; the banner is the
		// count and the control. Saying the whole sentence in all three places at once is how a
		// screen stops being read.
		$('queue-text').textContent = waiting === 1
			? 'One message is waiting to send.'
			: `${waiting} messages are waiting to send.`;
		$('queue-retry').textContent = 'Try now';
	}
}

$('queue-retry').addEventListener('click', () => {
	// He asked, so anything blocked gets one more chance rather than staying stuck forever.
	queue.blocked().forEach((item) => { item.state = 'waiting'; });
	flushQueue();
});

function handleApiError(err) {
	if (!err) return;
	if (err.reason === 'revoked') { goRevoked(); return; }
	if (err.reason === 'unreachable') { setLinkState('away'); return; }
	setLinkState('away', 'Your Mac answered, but not with something this app could use.');
}

async function goRevoked() {
	// FINAL, and it has to stop the retry loop as well as the socket. A revoked phone that went on
	// reconnecting every thirty seconds would be this app knocking on a door it has been told it is
	// not welcome at — which is the thing `lib/api.js` classifies REVOKED as never-retry to avoid.
	if (link) link.close();
	showTakeover('revoked');
	$('revoked-detail').textContent = 'Nothing you wrote has been lost from your Mac — this phone simply has no way in any more.';
	try {
		await queue.clear();
		await Storage.forgetEverything(db);
	} catch { /* the screen above is the important half */ }
}

// ---------------------------------------------------------------------------------------------
// Verb 2 — send a voice note
//
// The permission design is decision 1 at the top of this file. `opening` is the state between his
// finger going down and the microphone actually being open; `heldDown` is whether his finger is
// still there when it opens.
// ---------------------------------------------------------------------------------------------

const hold = $('hold');

hold.addEventListener('pointerdown', (event) => {
	event.preventDefault();
	unlockPlayer();
	heldDown = true;
	if (micStream) { startRecording(); return; }
	openMicrophoneThenRecord();
});

// The release is listened for on the WINDOW: if his finger slides off the button before he lifts
// it, the button itself never sees the release and the recording would run to the auto-stop.
window.addEventListener('pointerup', onRelease);
window.addEventListener('pointercancel', onRelease);

function onRelease() {
	if (!heldDown) return;
	heldDown = false;
	if (recording) { stopRecording(); return; }
	if (opening) {
		// He let go while iOS was asking. That is not a failed recording and must never be reported
		// as one — the dialog was literally under his finger.
		setHoldNote('The microphone is opening. Hold the button again when it is ready.', true);
	}
}

async function openMicrophoneThenRecord() {
	opening = true;
	hold.classList.add('opening');
	hold.textContent = 'Opening the microphone…';
	const firstTime = !askedForMicrophoneThisLaunch;
	askedForMicrophoneThisLaunch = true;

	try {
		micStream = await navigator.mediaDevices.getUserMedia({
			audio: {
				channelCount: 1,
				// All three processing stages OFF: this is a recording bound for a recognizer, not
				// for a phone call. Noise suppression in particular can gate a quiet room to digital
				// silence, and a third-party default is never trusted here.
				echoCancellation: false,
				noiseSuppression: false,
				autoGainControl: false
			}
		});
	} catch (err) {
		opening = false;
		hold.classList.remove('opening');
		hold.textContent = 'Hold to record';
		const denied = err && (err.name === 'NotAllowedError' || err.name === 'SecurityError');
		setHoldNote(denied
			? 'iOS did not give this app the microphone. You can still type, and you can allow the microphone the next time you hold the button.'
			: 'No microphone was available. You can still type.', true);
		return;
	}

	opening = false;
	hold.classList.remove('opening');

	if (heldDown) {
		// His finger never left: go straight into the recording he was already trying to make.
		startRecording();
		return;
	}

	hold.textContent = 'Hold to record';
	setHoldNote(firstTime
		? 'The microphone is on. Hold the button and speak.'
		: 'That was too quick — hold the button while you speak.', false);
}

async function startRecording() {
	if (recording || !micStream) return;
	chunks = [];
	recording = true;
	hold.classList.add('recording');
	hold.textContent = 'Recording — let go to send';
	$('meter').hidden = false;
	$('meter-read').hidden = false;
	setHoldNote('Speak now. Let go and it goes to your Mac.', false);

	if (!audioCtx) {
		const Ctx = window.AudioContext || window.webkitAudioContext;
		try {
			// Asking for 16 kHz directly saves the resampling when it is honored. Safari has
			// historically ignored or thrown on the option, so the REAL rate is read back from the
			// context and `pcm.js` converts from whatever we actually got.
			audioCtx = new Ctx({ sampleRate: pcm.TARGET_RATE });
		} catch {
			audioCtx = new Ctx();
		}
	}
	if (audioCtx.state === 'suspended') await audioCtx.resume();

	const source = audioCtx.createMediaStreamSource(micStream);

	if (audioCtx.audioWorklet) {
		try {
			await audioCtx.audioWorklet.addModule('/lib/recorder-worklet.js');
			const node = new AudioWorkletNode(audioCtx, 'richos-capture');
			node.port.onmessage = (event) => {
				if (!recording) return;
				chunks.push(event.data);
				setLevel(pcm.measure([event.data]).rms);
			};
			source.connect(node);
			// A muted gain node keeps the graph being pulled WITHOUT routing the microphone to the
			// speaker, which on a phone held to the face is an instant feedback loop.
			const mute = audioCtx.createGain();
			mute.gain.value = 0;
			node.connect(mute);
			mute.connect(audioCtx.destination);
			captureNode = { node, source, mute, kind: 'worklet' };
		} catch {
			captureNode = null;
		}
	}

	if (!captureNode) {
		const node = audioCtx.createScriptProcessor(4096, 1, 1);
		node.onaudioprocess = (event) => {
			if (!recording) return;
			const copy = new Float32Array(event.inputBuffer.getChannelData(0));
			chunks.push(copy);
			setLevel(pcm.measure([copy]).rms);
		};
		source.connect(node);
		const mute = audioCtx.createGain();
		mute.gain.value = 0;
		node.connect(mute);
		mute.connect(audioCtx.destination);
		captureNode = { node, source, mute, kind: 'script' };
	}

	autoStopTimer = setTimeout(() => { if (recording) stopRecording(); }, MAX_RECORD_SECONDS * 1000);
}

function setLevel(rms) {
	const db = pcm.toDbfs(rms);
	// -60 dBFS at the left, 0 at the right. A linear amplitude bar spends nearly all its travel in
	// the top few decibels and reads as dead for ordinary speech, which is the opposite of what a
	// level meter is for.
	const pct = Math.max(0, Math.min(100, ((db + 60) / 60) * 100));
	$('meter-fill').style.setProperty('--level', `${pct.toFixed(1)}%`);
	$('meter-read').textContent = `Level: ${pcm.formatDbfs(db)} dBFS`;
}

function teardownGraph() {
	if (!captureNode) return;
	try {
		if (captureNode.kind === 'worklet') captureNode.node.port.postMessage('stop');
		else captureNode.node.onaudioprocess = null;
		captureNode.source.disconnect();
		captureNode.node.disconnect();
		captureNode.mute.disconnect();
	} catch { /* teardown must not throw over a message */ }
	captureNode = null;
}

function releaseMicrophone() {
	// The tracks are stopped between notes so the phone's own recording indicator is not left on
	// after he has finished speaking. Within one launch iOS does not ask again, so the next hold
	// opens straight away; across launches it asks whatever we do, which is what the design above
	// is built around.
	if (!micStream) return;
	micStream.getTracks().forEach((track) => { try { track.stop(); } catch { /* already stopped */ } });
	micStream = null;
}

async function stopRecording() {
	if (!recording) return;
	recording = false;
	clearTimeout(autoStopTimer);
	hold.classList.remove('recording');
	hold.textContent = 'Hold to record';
	// His finger is off it, so a `hello` that arrived mid-hold and withdrew voice takes effect now.
	applyCapabilities();
	teardownGraph();
	setLevel(0);
	$('meter').hidden = true;
	$('meter-read').hidden = true;

	const captureRate = audioCtx ? audioCtx.sampleRate : 0;
	const result = pcm.analyze(chunks, captureRate);
	chunks = [];
	releaseMicrophone();

	if (result.outcome === 'too-short') {
		setHoldNote('That was too quick — hold the button while you speak.', true);
		return;
	}
	if (result.outcome === 'no-samples') {
		setHoldNote('The microphone opened but nothing came through. Try once more.', true);
		return;
	}
	if (result.outcome === 'silent') {
		// Sending it would cost him a transcription of nothing and a reply about nothing.
		setHoldNote(`That came through silent — peak ${pcm.formatDbfs(result.stats.peakDbfs)} dBFS, so your Mac would hear nothing. Try again, closer.`, true);
		return;
	}

	setHoldNote('Hold the button, speak, and let go to send.', false);

	await queue.enqueue({
		clientId: newClientId(),
		threadId: currentThreadId,
		kind: 'voice',
		bytes: Array.from(new Uint8Array(result.wav)),
		seconds: Number(result.seconds.toFixed(2)),
		codec: 'wav16k',
		sampleRate: pcm.TARGET_RATE,
		sentAt: new Date().toISOString()
	});
	render(true);
	flushQueue();
}

function setHoldNote(text, trouble) {
	const note = $('hold-note');
	note.textContent = text;
	note.classList.toggle('trouble', Boolean(trouble));
}

// Leaving the app mid-hold suspends the audio context; stop cleanly rather than keeping a dead
// graph and a recording that will never end.
document.addEventListener('visibilitychange', () => {
	if (document.hidden) {
		if (recording) stopRecording();
		return;
	}
	// Back on screen: this is one of the three moments a queued message can go, because a PWA
	// cannot flush anything in the background (§2.4).
	//
	// WAKE, NEVER CONNECT. `if (!streamOpen) connectStream()` looks like the same thing and is
	// not: `streamOpen` was false for the whole of an outage, so every foreground during one
	// started another attempt, on top of the browser's own reconnect loop and on top of anything
	// already in flight — three openers, and the app could only ever hold the last source any of
	// them produced. `wake()` fires the retry that is ALREADY OWED, immediately, because he is
	// looking at the screen; it opens nothing beside anything.
	if (link) link.wake(); else connectStream();
	flushQueue();
});

// ---------------------------------------------------------------------------------------------
// Verb 4 — hear Rich
// ---------------------------------------------------------------------------------------------

function unlockPlayer() {
	if (playerUnlocked || !player) return;
	// Safari will not start audio outside a user gesture, and an `await` loses the gesture. So the
	// element is started on ten milliseconds of our own silence inside his first tap; from then on
	// it can be played with real audio after a fetch.
	player.src = silentWavUrl;
	const attempt = player.play();
	if (attempt && attempt.catch) attempt.catch(() => { /* it will be unlocked by a later tap */ });
	playerUnlocked = true;
}

async function hearIt(messageId, button) {
	if (playingButton && playingButton !== button) {
		playingButton.textContent = 'Hear it';
		playingButton.classList.remove('playing');
	}
	if (player && !player.paused && playingButton === button) {
		player.pause();
		button.textContent = 'Hear it';
		button.classList.remove('playing');
		return;
	}

	button.disabled = true;
	button.textContent = 'Getting it…';
	try {
		const blob = await api.fetchAudio(messageId);
		const url = URL.createObjectURL(blob);
		player.onended = () => {
			button.textContent = 'Hear it';
			button.classList.remove('playing');
			URL.revokeObjectURL(url);
		};
		player.src = url;
		await player.play();
		button.textContent = 'Stop';
		button.classList.add('playing');
		playingButton = button;
	} catch (err) {
		button.textContent = 'Hear it';
		handleApiError(err);
		if (err && err.name === 'NotAllowedError') setLinkState('away', 'Tap "Hear it" once more — this phone wants a tap before it will play sound.');
	} finally {
		button.disabled = false;
	}
}

// ---------------------------------------------------------------------------------------------
// Push (plan §3.4). The phone obeys the tiers the Mac sends and invents no policy of its own.
// ---------------------------------------------------------------------------------------------

async function refreshPushOffer() {
	const offer = $('push-offer');
	if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) {
		// THIS BROWSER CANNOT TAKE A PUSH AT ALL, and on iOS that is not a dead end — it is an app
		// that has not been installed yet. Saying nothing, which is what this used to do, left him
		// with no way to find out. The control is named in the device's own words or not at all.
		const sentence = installSentence();
		if (sentence && !alreadyInstalled()) {
			offer.hidden = false;
			$('push-offer-text').textContent = sentence;
			// There is no control this app can offer that does this: the item is in the browser's
			// own menu, so the sentence says where it is instead of pretending to be a button.
			$('push-on').hidden = true;
			return;
		}
		offer.hidden = true;
		return;
	}
	if (Notification.permission === 'denied') {
		// There is no control this app can offer that will change this — iOS only allows it from
		// Settings — so the sentence says where the control is instead of pretending to be one.
		offer.hidden = false;
		$('push-offer-text').textContent = 'Notifications are switched off for this app in your phone\u2019s settings, so Rich cannot reach you when it is closed.';
		$('push-on').hidden = true;
		return;
	}
	if (Notification.permission === 'granted') {
		const registration = await navigator.serviceWorker.getRegistration();
		const existing = registration ? await registration.pushManager.getSubscription() : null;
		offer.hidden = Boolean(existing);
		return;
	}
	offer.hidden = false;
	$('push-on').hidden = false;
	// **THE ANSWER HE ALREADY GAVE, KEPT ACROSS A RELOAD.** Ray, candidate .11, §5: after he
	// declined, the banner said the right thing — "Notifications stayed off, so Rich can only
	// reach you while this app is open" — and a reload put the generic offer back.
	//
	// The permission cannot carry this. Both a phone that has never been asked and a phone whose
	// owner dismissed the system prompt report `Notification.permission === 'default'`, which is
	// exactly what Ray hit: he allowed Chrome's site prompt and dismissed Android's, and the
	// browser's state was indistinguishable from never having asked. So what is remembered is HIS
	// ANSWER, on this phone, and it is cleared the moment the permission is granted.
	$('push-offer-text').textContent = notificationsDeclined
		? 'Notifications stayed off, so Rich can only reach you while this app is open.'
		: 'Notifications are off, so Rich cannot reach you when this app is closed.';
}

$('push-on').addEventListener('click', async () => {
	$('push-on').disabled = true;
	try {
		// The request must be inside the gesture, which this is.
		const permission = await Notification.requestPermission();
		if (permission !== 'granted') {
			notificationsDeclined = true;
			settings.set('notificationsDeclined', true).catch(() => { /* the sentence is the half that matters now */ });
			$('push-offer-text').textContent = 'Notifications stayed off, so Rich can only reach you while this app is open.';
			return;
		}
		// He said yes. The earlier no is not his position any more, and a stale one would put the
		// wrong sentence in front of him the next time the offer is shown for any other reason.
		notificationsDeclined = false;
		settings.set('notificationsDeclined', false).catch(() => {});
		if (!vapidPublicKey) {
			$('push-offer-text').textContent = 'Your Mac has not sent this phone a notification key yet. Open this again once your Mac is reachable.';
			return;
		}

		const registration = await navigator.serviceWorker.register('/sw.js', { scope: '/' });
		await navigator.serviceWorker.ready;

		let subscription = await registration.pushManager.getSubscription();
		if (subscription) {
			const current = new Uint8Array(subscription.options.applicationServerKey || new ArrayBuffer(0));
			const wanted = base64UrlToBytes(vapidPublicKey);
			const same = current.length === wanted.length && current.every((v, i) => v === wanted[i]);
			if (!same) { await subscription.unsubscribe(); subscription = null; }
		}
		if (!subscription) {
			subscription = await registration.pushManager.subscribe({
				// Required by WebKit: every push must display a notification, so there is no such
				// thing as a silent one to ask for.
				userVisibleOnly: true,
				applicationServerKey: base64UrlToBytes(vapidPublicKey)
			});
		}
		await api.registerPush(subscription.toJSON());
		$('push-offer').hidden = true;
	} catch (err) {
		$('push-offer-text').textContent = 'Notifications could not be turned on just now. Try again when your Mac is reachable.';
		handleApiError(err);
	} finally {
		$('push-on').disabled = false;
	}
});

function base64UrlToBytes(value) {
	const padding = '='.repeat((4 - (value.length % 4)) % 4);
	const raw = atob((value + padding).replace(/-/g, '+').replace(/_/g, '/'));
	const out = new Uint8Array(raw.length);
	for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
	return out;
}

if ('serviceWorker' in navigator) {
	navigator.serviceWorker.addEventListener('message', (event) => {
		const data = event.data || {};
		// A push arrived while the app was open, or he tapped one. Either way the service worker
		// hands over the row it already wrote to storage, so the screen and the cache agree.
		if (data.type === 'push-message' && data.message) {
			if (data.api_base && api) api.setApiBase(data.api_base);
			if (!thread) return;
			if (data.message.thread_id && data.message.thread_id !== currentThreadId) return;
			thread.merge(data.message);
			scheduleRender();
		}
		if (data.type === 'notification-clicked') {
			if (!thread) return;
			scheduleRender();
			$('thread').scrollTop = $('thread').scrollHeight;
		}
	});
	if (navigator.clearAppBadge) navigator.clearAppBadge().catch(() => {});
	// Registered at boot as well as at the notification offer, because the worker is also what
	// caches the shell so the app opens where the origin does not resolve.
	navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => { /* reported by the offer */ });
}

// ---------------------------------------------------------------------------------------------
// Go
// ---------------------------------------------------------------------------------------------

player = new Audio();
player.preload = 'auto';
silentWavUrl = URL.createObjectURL(new Blob([pcm.encodeWav(new Float32Array(160), pcm.TARGET_RATE)], { type: 'audio/wav' }));

boot().catch((err) => {
	setLinkState('away', 'This app could not start. Tell Rich what it said: ' + String(err && err.message ? err.message : err));
});

// Exposed for the browser harness only: it drives the real app rather than a copy of it, and this
// is how it reads the state it is asserting about. Nothing in the app reads these back.
globalThis.__richosPhone = {
	get queue() { return queue; },
	get thread() { return thread; },
	get api() { return api; },
	get state() { return apiState; },
	get link() { return link; },
	render, flushQueue, connectStream, applyCapabilities
};

})();

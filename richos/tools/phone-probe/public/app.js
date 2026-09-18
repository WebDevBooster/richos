'use strict';

// The page. Five checks, in order, on one screen.
//
// The audio math lives in pcm.js so it can be tested without a browser; this file is the wiring:
// what he taps, what the phone reports back, and what gets written into the results panel. Every
// verdict is stored on the device so the second launch can show what the first one found.

(function () {

// ---------------------------------------------------------------------------
// The access code, and why every URL in this file goes through withCode()
// ---------------------------------------------------------------------------

const params = new URLSearchParams(location.search);
const CODE = params.get('k') || '';

function withCode(path) {
	if (!CODE) return path;
	return path + (path.includes('?') ? '&' : '?') + 'k=' + encodeURIComponent(CODE);
}

// The manifest and the touch icon are fetched by iOS itself, which does not send our header, so the
// code has to be in their URLs before Add to Home Screen reads them. Rewriting the two <link> hrefs
// here is what stops the installed app 404ing on its own first launch.
if (CODE) {
	const manifestLink = document.getElementById('manifest-link');
	if (manifestLink) manifestLink.href = withCode('/manifest.webmanifest');
	const touchIcon = document.getElementById('touch-icon');
	if (touchIcon) touchIcon.href = withCode('/icons/apple-touch-icon.png');
}

// ---------------------------------------------------------------------------
// Stored results
// ---------------------------------------------------------------------------

const STORE_KEY = 'richos-phone-probe-v1';

const blankState = () => ({
	launches: 0,
	firstLaunchAt: null,
	checks: {
		trust: null,
		install: null,
		microphone: null,
		persistence: null,
		push: null,
		wake: null
	},
	subscriptionId: null,
	device: null
});

function load() {
	try {
		const raw = localStorage.getItem(STORE_KEY);
		if (!raw) return blankState();
		return Object.assign(blankState(), JSON.parse(raw));
	} catch {
		// Private browsing, a full quota, a corrupted value — none of them are worth a dead page.
		return blankState();
	}
}

function save() {
	try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch { /* the page still works */ }
}

const state = load();
state.launches += 1;
if (!state.firstLaunchAt) state.firstLaunchAt = new Date().toISOString();

// Declared here, not beside check 4 where they are filled in: check 1 runs first and calls
// renderResults(), which reads buildLine. A `let` further down the file would leave it in the
// temporal dead zone at that moment and throw before the page ever rendered anything.
let vapidPublicKey = null;
let buildLine = 'unknown';

// ---------------------------------------------------------------------------
// Small DOM helpers
// ---------------------------------------------------------------------------

const $ = (id) => document.getElementById(id);

// `status` is one of: pass | fail | ask | waiting. It picks the stripe and the label color, all of
// which are computed against WCAG AA in both themes by test/contrast.test.js.
function setVerdict(n, status, label, detail) {
	const box = $('v' + n);
	box.className = 'verdict ' + status;
	box.querySelector('.label').textContent = label;
	const d = $('d' + n);
	if (d && detail !== undefined) d.textContent = detail;
}

function record(check, status, line, detail) {
	state.checks[check] = { status, line, detail: detail || '', at: new Date().toISOString() };
	save();
	renderResults();
}

// ---------------------------------------------------------------------------
// The results panel
// ---------------------------------------------------------------------------

const CHECK_ORDER = [
	['trust', '0. Trust'],
	['install', '1. Install'],
	['microphone', '2. Microphone'],
	['persistence', '3. Permission persistence'],
	['push', '4. Push with the app closed'],
	['wake', '5. Tap to open']
];

function renderResults() {
	const lines = CHECK_ORDER.map(([key, title]) => {
		const r = state.checks[key];
		if (!r) return `${title}: not run yet`;
		return `${title}: ${r.line}${r.detail ? ` — ${r.detail}` : ''}`;
	});
	lines.push('');
	lines.push(`Device: ${state.device || navigator.userAgent}`);
	lines.push(`Launches: ${state.launches}`);
	lines.push(`Build: ${buildLine}`);
	$('results-text').value = lines.join('\n');
}

// ---------------------------------------------------------------------------
// Check 0 — the hosting step: did his phone reach his Mac over HTTPS, cleanly?
// ---------------------------------------------------------------------------
//
// This check has a machine half and a human half, and the machine half CANNOT answer it alone.
//
// What the page can see for itself: whether the origin is HTTPS and whether the browser treats it as
// a secure context. What it cannot see: whether Safari showed him a "this connection is not private"
// interstitial that he tapped through. After tapping through, the origin is still HTTPS and
// `isSecureContext` is still true — so a page that inferred "trusted" from those two would report a
// pass for the one arrangement the whole step exists to test.
//
// So the verdict is HIS observation, like check 3 and check 4, and the machine facts are printed
// beside it so his answer can be read against something rather than taken alone.

const secureOrigin = location.protocol === 'https:';

function trustFacts(config) {
	const parts = [`Reached ${location.host} over ${location.protocol.replace(':', '')}`];
	if (window.isSecureContext !== undefined) parts.push(`secure context: ${window.isSecureContext ? 'yes' : 'no'}`);
	if (config && config.tls) {
		parts.push(`the certificate covers ${config.tls.names}`);
		// SIX WORDS, NEVER THE HASH. This line used to print the root's SHA-256 in full, and on the
		// CEO's own walk on 2026-09-18 it was what put a horizontal scroll bar on this page: "the
		// long SHA256 which was all in one line on the second page". The words are the same identity
		// in a form he can compare, and they are what the real phone app shows at pairing.
		if (config.tls.caWords) parts.push(`its six-word name is "${config.tls.caWords}"`);
	}
	return parts.join('. ') + '.';
}

if (!secureOrigin) {
	// Reaching the probe over plain HTTP is not a failure of his phone — it means he opened the wrong
	// one of the two URLs, and saying so is more useful than a red verdict.
	setVerdict(0, 'ask', 'This is the plain page, not the secure one.',
		'Checks 2 and 4 cannot work here: an iPhone gives a non-secure page no microphone and no notifications. Go back to the trust step and open the https link.');
	record('trust', 'ask', 'NOT ON HTTPS — opened the plain URL rather than the secure one');
} else {
	setVerdict(0, 'ask', 'You are here over HTTPS. Did Safari warn you on the way in?',
		'Tap whichever happened. If it warned you, the certificate is installed but not switched on — Settings, General, About, Certificate Trust Settings.');
	$('trust-row').hidden = false;
}

$('trust-clean').addEventListener('click', () => {
	setVerdict(0, 'pass', 'Your Mac served this to your phone, and your phone accepted it.', $('trust-facts').textContent);
	record('trust', 'pass', 'PASS — the Mac-hosted HTTPS origin opened with no warning', `${location.host}; the trust step held`);
	$('trust-row').hidden = true;
});

$('trust-warned').addEventListener('click', () => {
	// A warning he tapped through is a REAL failure of check 0 even though the page loaded, because
	// the product cannot ask a person to tap through a security warning every time.
	setVerdict(0, 'fail', 'It warned you, so the trust step did not hold.',
		'The certificate is probably installed but not switched on. Settings, General, About, Certificate Trust Settings — turn on the RichOS switch, then reload this page.');
	record('trust', 'fail', 'FAIL — Safari warned about the connection; the root is not fully trusted', $('trust-facts').textContent);
	$('trust-row').hidden = true;
});

// ---------------------------------------------------------------------------
// Check 1 — install
// ---------------------------------------------------------------------------

const standalone = window.matchMedia('(display-mode: standalone)').matches
	|| window.matchMedia('(display-mode: fullscreen)').matches
	// The legacy iOS signal, still the only true one on some versions.
	|| window.navigator.standalone === true;

state.device = navigator.userAgent;

if (standalone) {
	setVerdict(1, 'pass', 'Running in a standalone window.');
	record('install', 'pass', 'PASS — opened in a standalone window with no address bar');
	$('tab-banner').hidden = true;
	$('install-how').hidden = true;
} else {
	setVerdict(1, 'ask', 'Running in a browser tab — not installed yet.');
	record('install', 'ask', 'IN A BROWSER TAB — add to the Home Screen and reopen from the icon');
	$('tab-banner').hidden = false;
}

// ---------------------------------------------------------------------------
// Check 2 — the microphone
// ---------------------------------------------------------------------------

const pcm = window.ProbePCM;

let micStream = null;
let audioCtx = null;
let captureNode = null;
let chunks = [];
let recording = false;
let lastWavBlobUrl = null;
let capturePath = 'unknown';
let autoStopTimer = null;

const MAX_RECORD_SECONDS = 10;

$('d2').textContent = `Non-silent means a peak above ${pcm.SILENCE_PEAK_DBFS} dBFS. Hold for at least ${pcm.MIN_USEFUL_SECONDS} seconds.`;

function setLevel(rms) {
	const db = pcm.toDbfs(rms);
	// -60 dBFS at the left, 0 at the right. A linear amplitude bar spends nearly all its travel in
	// the top few dB and reads as dead for normal speech, which is the opposite of what a level
	// meter is for on this page.
	const pct = Math.max(0, Math.min(100, ((db + 60) / 60) * 100));
	$('meter-fill').style.setProperty('--level', pct.toFixed(1) + '%');
	$('meter-read').textContent = `Level: ${pcm.formatDbfs(db)} dBFS`;
}

$('mic-on').addEventListener('click', async () => {
	// SEPARATE from the recorder on purpose. iOS puts its permission dialog up over the page; if
	// that happened while he was holding the record button, lifting his finger to tap Allow would
	// end the recording before the microphone ever opened, and a working microphone would be
	// reported as broken. Asking here means the dialog is never competing with a held button.
	$('mic-on').disabled = true;
	$('mic-on').textContent = 'Opening the microphone…';
	try {
		micStream = await navigator.mediaDevices.getUserMedia({
			audio: {
				channelCount: 1,
				// All three processing stages OFF. This check is asking what the microphone actually
				// captured; automatic gain and noise suppression are third-party defaults that would
				// sit between the question and the answer, and noise suppression in particular can
				// gate a quiet room to digital silence and produce a false failure.
				echoCancellation: false,
				noiseSuppression: false,
				autoGainControl: false
			}
		});
		const track = micStream.getAudioTracks()[0];
		const settings = track && track.getSettings ? track.getSettings() : {};
		$('mic-on').textContent = 'Microphone is on';
		$('record').disabled = false;
		setVerdict(2, 'ask', 'Microphone opened. Now hold the button and talk.',
			`Track: ${settings.sampleRate || 'rate not reported'} Hz, ${settings.channelCount || 1} channel. Non-silent means a peak above ${pcm.SILENCE_PEAK_DBFS} dBFS.`);
		if (state.launches > 1) $('persist-row').hidden = false;
	} catch (err) {
		$('mic-on').disabled = false;
		$('mic-on').textContent = 'Turn on the microphone';
		// NotAllowedError is him declining or the OS refusing; NotFoundError is no device at all.
		// They are different findings and the plan's fallback depends on which.
		const named = `${err.name || 'Error'}: ${err.message || String(err)}`;
		setVerdict(2, 'fail', 'The microphone would not open.', named);
		record('microphone', 'fail', 'FAIL — the microphone would not open', named);
	}
});

async function startRecording() {
	if (recording || !micStream) return;
	chunks = [];
	recording = true;
	$('record').classList.add('recording');
	$('record').textContent = 'Recording — keep talking…';
	$('playback-row').hidden = true;

	if (!audioCtx) {
		const Ctx = window.AudioContext || window.webkitAudioContext;
		// Asking for 16 kHz directly would save the resampling, but Safari has historically ignored
		// or thrown on the option, so the real rate is READ from the context rather than assumed and
		// pcm.js converts from whatever we actually got.
		try {
			audioCtx = new Ctx({ sampleRate: pcm.TARGET_RATE });
		} catch {
			audioCtx = new Ctx();
		}
	}
	// iOS starts a context suspended until a gesture; this handler is inside one.
	if (audioCtx.state === 'suspended') await audioCtx.resume();

	const source = audioCtx.createMediaStreamSource(micStream);

	if (audioCtx.audioWorklet) {
		try {
			await audioCtx.audioWorklet.addModule(withCode('/recorder-worklet.js'));
			const node = new AudioWorkletNode(audioCtx, 'probe-capture');
			node.port.onmessage = (event) => {
				if (!recording) return;
				chunks.push(event.data);
				setLevel(pcm.measure([event.data]).rms);
			};
			source.connect(node);
			// A worklet with no destination is not guaranteed to be pulled. Connecting through a
			// muted gain node keeps the graph alive WITHOUT routing the microphone to the speaker —
			// which would be an instant feedback loop on a phone held to the face.
			const mute = audioCtx.createGain();
			mute.gain.value = 0;
			node.connect(mute);
			mute.connect(audioCtx.destination);
			captureNode = { node, source, mute, kind: 'worklet' };
			capturePath = 'AudioWorklet';
		} catch {
			captureNode = null;
		}
	}

	if (!captureNode) {
		// ScriptProcessorNode is deprecated and still the only fallback that works everywhere.
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
		capturePath = 'ScriptProcessor (no AudioWorklet on this browser)';
	}

	// A stuck pointer must never leave the microphone running forever.
	autoStopTimer = setTimeout(() => { if (recording) stopRecording(); }, MAX_RECORD_SECONDS * 1000);
}

function teardownGraph() {
	if (!captureNode) return;
	try {
		if (captureNode.kind === 'worklet') captureNode.node.port.postMessage('stop');
		else captureNode.node.onaudioprocess = null;
		captureNode.source.disconnect();
		captureNode.node.disconnect();
		captureNode.mute.disconnect();
	} catch { /* teardown must not throw over a verdict */ }
	captureNode = null;
}

function stopRecording() {
	if (!recording) return;
	recording = false;
	clearTimeout(autoStopTimer);
	$('record').classList.remove('recording');
	$('record').textContent = 'Hold to record';
	teardownGraph();
	setLevel(0);

	const captureRate = audioCtx ? audioCtx.sampleRate : 0;
	const result = pcm.analyze(chunks, captureRate);
	chunks = [];

	const rate = `Captured at ${captureRate} Hz via ${capturePath}`;

	if (result.outcome === 'too-short') {
		// Not a verdict. Saying "failed" here is how a working microphone gets reported as broken.
		setVerdict(2, 'ask', `That was only ${result.seconds.toFixed(2)} seconds — hold it longer.`,
			`Hold the button for at least ${pcm.MIN_USEFUL_SECONDS} seconds and talk while you hold. ${rate}.`);
		return;
	}

	if (result.outcome === 'no-samples') {
		setVerdict(2, 'fail', 'The microphone opened but delivered no audio at all.', `${rate}. No sample blocks arrived.`);
		record('microphone', 'fail', 'FAIL — the microphone opened but delivered no audio', rate);
		return;
	}

	const s = result.stats;
	const detail = `${result.seconds.toFixed(2)} s, peak ${pcm.formatDbfs(s.peakDbfs)} dBFS, RMS ${pcm.formatDbfs(s.rmsDbfs)} dBFS, ` +
		`${result.resampledCount} samples at ${result.targetRate} Hz, ${(result.wavBytes / 1000).toFixed(1)} KB WAV. ${rate}.`;

	if (result.outcome === 'non-silent') {
		setVerdict(2, 'pass', 'The microphone works in this app. Non-silent audio captured.', detail);
		record('microphone', 'pass', `PASS — ${result.seconds.toFixed(2)} s of non-silent audio, peak ${pcm.formatDbfs(s.peakDbfs)} dBFS`, detail);
	} else {
		setVerdict(2, 'fail', 'The microphone opened, but everything it captured was silent.', detail);
		record('microphone', 'fail', `FAIL — captured ${result.seconds.toFixed(2)} s but the peak was only ${pcm.formatDbfs(s.peakDbfs)} dBFS`, detail);
	}

	// Offer a playback so he can hear for himself, then let the audio go. The WAV exists only as a
	// blob on the device; it is never uploaded, and Start over revokes it.
	if (result.wav) {
		if (lastWavBlobUrl) URL.revokeObjectURL(lastWavBlobUrl);
		lastWavBlobUrl = URL.createObjectURL(new Blob([result.wav], { type: 'audio/wav' }));
		$('playback-row').hidden = false;
	}

	if (state.launches > 1) $('persist-row').hidden = false;
}

// pointerdown on the button, pointerup on the WINDOW: if his finger slides off the control before
// he lifts it, the button never sees the release and the recording would run to the auto-stop.
$('record').addEventListener('pointerdown', (event) => {
	event.preventDefault();
	if ($('record').disabled) return;
	startRecording();
});
window.addEventListener('pointerup', () => { if (recording) stopRecording(); });
window.addEventListener('pointercancel', () => { if (recording) stopRecording(); });
// Leaving the app mid-hold suspends the context; stop cleanly rather than keeping a dead graph.
document.addEventListener('visibilitychange', () => { if (document.hidden && recording) stopRecording(); });

$('play').addEventListener('click', () => {
	if (!lastWavBlobUrl) return;
	// Playback is a user gesture, so Safari's autoplay policy is not in play. It is offered as
	// confirmation for him, never as the verdict — the verdict is the numbers above.
	const audio = new Audio(lastWavBlobUrl);
	audio.play().catch(() => {
		$('d2').textContent += ' (Playback was refused by the browser; the numbers above are the result.)';
	});
});

// ---------------------------------------------------------------------------
// Check 3 — is the permission asked again?
// ---------------------------------------------------------------------------

async function describePermission() {
	// Safari does not implement the microphone permission query, so this is reported as
	// "not reportable" rather than guessed at. His own observation is the real answer.
	if (!navigator.permissions || !navigator.permissions.query) return 'this browser does not report permission state';
	try {
		const status = await navigator.permissions.query({ name: 'microphone' });
		return `the browser reports "${status.state}"`;
	} catch {
		return 'this browser does not report permission state';
	}
}

(async () => {
	const reported = await describePermission();
	if (state.launches === 1) {
		setVerdict(3, 'waiting', 'This is the first launch.',
			`Close the app completely, open it again from the Home Screen icon, and record once more. (Right now, ${reported}.)`);
	} else if (!state.checks.persistence) {
		setVerdict(3, 'ask', `This is launch ${state.launches}. Record again, then tell us what happened.`,
			`Did iOS ask for the microphone again? (Right now, ${reported}.)`);
		$('persist-row').hidden = false;
	}
})();

$('asked-again').addEventListener('click', async () => {
	const reported = await describePermission();
	setVerdict(3, 'ask', 'iOS asks every launch. A cost, not a blocker.', reported);
	record('persistence', 'ask', 'ASKS AGAIN — iOS re-prompts for the microphone on each launch', `launch ${state.launches}; ${reported}`);
	$('persist-row').hidden = true;
});

$('asked-once').addEventListener('click', async () => {
	const reported = await describePermission();
	setVerdict(3, 'pass', 'The permission stuck. It did not ask again.', reported);
	record('persistence', 'pass', 'PASS — the permission persisted across a relaunch', `launch ${state.launches}; ${reported}`);
	$('persist-row').hidden = true;
});

// ---------------------------------------------------------------------------
// Check 4 — push with the app closed
// ---------------------------------------------------------------------------

function urlBase64ToUint8Array(base64) {
	const padding = '='.repeat((4 - (base64.length % 4)) % 4);
	const raw = atob((base64 + padding).replace(/-/g, '+').replace(/_/g, '/'));
	const out = new Uint8Array(raw.length);
	for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
	return out;
}

async function api(path, options) {
	const init = Object.assign({ headers: {} }, options || {});
	init.headers = Object.assign({ 'Content-Type': 'application/json' }, init.headers);
	if (CODE) init.headers['x-probe-code'] = CODE;
	const response = await fetch(withCode(path), init);
	if (!response.ok) throw new Error(`${path} returned ${response.status}`);
	return response.json();
}

$('notif-on').addEventListener('click', async () => {
	$('notif-on').disabled = true;
	try {
		if (!('serviceWorker' in navigator)) throw new Error('this browser has no service worker support');
		if (!('PushManager' in window)) throw new Error('this browser has no Push API');

		// The permission request must be inside the gesture, which it is.
		const permission = await Notification.requestPermission();
		if (permission !== 'granted') {
			setVerdict(4, 'fail', `Notification permission was ${permission}.`, 'Without permission there is nothing to test here.');
			record('push', 'fail', `FAIL — notification permission was ${permission}`);
			$('notif-on').disabled = false;
			return;
		}

		const registration = await navigator.serviceWorker.register(withCode('/sw.js'), { scope: '/' });
		await navigator.serviceWorker.ready;

		// Re-subscribing on EVERY launch is plan risk 2's mitigation: push subscriptions are widely
		// reported to lapse after inactivity, and a silently dead channel is the failure that
		// matters. An existing subscription is reused if the server key still matches.
		let subscription = await registration.pushManager.getSubscription();
		if (subscription) {
			const current = new Uint8Array(subscription.options.applicationServerKey || new ArrayBuffer(0));
			const wanted = urlBase64ToUint8Array(vapidPublicKey);
			const same = current.length === wanted.length && current.every((v, i) => v === wanted[i]);
			if (!same) { await subscription.unsubscribe(); subscription = null; }
		}
		if (!subscription) {
			subscription = await registration.pushManager.subscribe({
				// Required by WebKit: every push must display a notification, so there is no such
				// thing as a silent one to ask for.
				userVisibleOnly: true,
				applicationServerKey: urlBase64ToUint8Array(vapidPublicKey)
			});
		}

		const saved = await api('/api/subscribe', { method: 'POST', body: JSON.stringify({ subscription: subscription.toJSON() }) });
		state.subscriptionId = saved.id;
		save();

		$('notif-on').textContent = 'Notifications are on';
		$('send-push').disabled = false;
		setVerdict(4, 'ask', 'Subscribed. Now ask for the test push and close the app.',
			`Push service: ${saved.pushService}`);
	} catch (err) {
		$('notif-on').disabled = false;
		const named = `${err.name || 'Error'}: ${err.message || String(err)}`;
		setVerdict(4, 'fail', 'Could not subscribe to notifications.', named);
		record('push', 'fail', 'FAIL — could not subscribe to notifications', named);
	}
});

$('send-push').addEventListener('click', async () => {
	$('send-push').disabled = true;
	try {
		const scheduled = await api('/api/test-push', {
			method: 'POST',
			body: JSON.stringify({ id: state.subscriptionId, delaySeconds: 60 })
		});
		// Only now is it safe to tell him to close the app: the request has been acknowledged.
		let remaining = scheduled.delaySeconds;
		setVerdict(4, 'ask', `Scheduled. CLOSE THIS APP COMPLETELY NOW — ${remaining} seconds.`,
			'Swipe up from the bottom and swipe this app away, so it is not merely in the background. The notification should arrive when the countdown ends.');
		const tick = setInterval(() => {
			remaining -= 1;
			if (remaining <= 0) {
				clearInterval(tick);
				setVerdict(4, 'ask', 'The push has been sent. Did a notification appear?',
					'If you are reading this, the app was open — the check still counts, but closing it fully is the stronger answer.');
				$('push-answer-row').hidden = false;
				pollSendResult();
				return;
			}
			setVerdict(4, 'ask', `Scheduled. CLOSE THIS APP COMPLETELY NOW — ${remaining} seconds.`,
				'Swipe up from the bottom and swipe this app away, so it is not merely in the background.');
		}, 1000);
	} catch (err) {
		$('send-push').disabled = false;
		setVerdict(4, 'fail', 'Could not schedule the test push.', String(err.message || err));
	}
});

// What the push SERVICE said is half the answer and is the half he cannot see. A 201 with no
// notification is a completely different finding from a 4xx, and only one of them is our problem.
async function pollSendResult() {
	try {
		const status = await api(`/api/status?id=${encodeURIComponent(state.subscriptionId)}`);
		if (status.lastSend) {
			const s = status.lastSend;
			const text = s.ok
				? `The push service accepted it (HTTP ${s.statusCode}).`
				: `The push service rejected it (HTTP ${s.statusCode}${s.detail ? `: ${s.detail}` : ''}).`;
			$('d4').textContent = text;
			if (!s.ok) {
				setVerdict(4, 'fail', 'The push was never delivered to Apple.', text);
				record('push', 'fail', `FAIL — the push service rejected it, HTTP ${s.statusCode}`, s.detail || '');
			}
		}
	} catch { /* the buttons below are still the real answer */ }
}

$('push-yes').addEventListener('click', () => {
	setVerdict(4, 'pass', 'A notification arrived with the app closed.', $('d4').textContent);
	record('push', 'pass', 'PASS — the notification arrived with the app closed', $('d4').textContent);
	$('push-answer-row').hidden = true;
});

$('push-no').addEventListener('click', () => {
	setVerdict(4, 'fail', 'No notification arrived.', $('d4').textContent);
	record('push', 'fail', 'FAIL — no notification arrived', $('d4').textContent);
	$('push-answer-row').hidden = true;
});

// ---------------------------------------------------------------------------
// Check 5 — the tap opens the app
// ---------------------------------------------------------------------------

function markWoken(how) {
	setVerdict(5, 'pass', 'You arrived here from the notification.', how);
	record('wake', 'pass', 'PASS — tapping the notification opened the app', how);
	// If he got here from the notification, the notification existed. Only fill in check 4 if he
	// has not already answered it himself — his own observation outranks this inference.
	if (!state.checks.push || state.checks.push.status !== 'pass') {
		setVerdict(4, 'pass', 'A notification arrived and you tapped it.', $('d4').textContent);
		record('push', 'pass', 'PASS — the notification arrived and was tapped', 'inferred from the app being opened by the notification');
		$('push-answer-row').hidden = true;
	}
}

if (params.get('from') === 'push') {
	markWoken(standalone ? 'opened into the standalone window' : 'opened into a browser tab');
} else if (!state.checks.wake) {
	setVerdict(5, 'waiting', 'Waiting for you to tap the notification from step 4.', '');
}

if ('serviceWorker' in navigator) {
	navigator.serviceWorker.addEventListener('message', (event) => {
		const data = event.data || {};
		if (data.type === 'notification-clicked') markWoken('the app was already open and was focused by the tap');
		if (data.type === 'push-arrived') {
			$('d4').textContent = 'The push reached this device while the app was open.';
			$('push-answer-row').hidden = false;
		}
	});
	if (navigator.clearAppBadge) navigator.clearAppBadge().catch(() => {});
}

// ---------------------------------------------------------------------------
// Results panel controls
// ---------------------------------------------------------------------------

$('copy').addEventListener('click', async () => {
	const text = $('results-text').value;
	try {
		await navigator.clipboard.writeText(text);
		$('copy-said').textContent = 'Copied. Paste it to Rich.';
	} catch {
		// The clipboard API needs a secure context and a gesture and can still refuse. Selecting the
		// text means there is always a way through.
		const box = $('results-text');
		box.removeAttribute('readonly');
		box.focus();
		box.select();
		box.setAttribute('readonly', 'readonly');
		$('copy-said').textContent = 'Could not copy automatically — the text above is selected, so copy it by hand.';
	}
});

$('reset').addEventListener('click', async () => {
	// Deleting the subscription at the server is the visible half of the promise in the note at the
	// bottom of the page, so it happens before the local state goes.
	if (state.subscriptionId) {
		try { await api('/api/forget', { method: 'POST', body: JSON.stringify({ id: state.subscriptionId }) }); } catch { /* clearing locally regardless */ }
	}
	if (lastWavBlobUrl) { URL.revokeObjectURL(lastWavBlobUrl); lastWavBlobUrl = null; }
	try { localStorage.removeItem(STORE_KEY); } catch { /* nothing to do */ }
	location.href = withCode('/');
});

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

(async () => {
	try {
		const config = await api('/api/config');
		vapidPublicKey = config.vapidPublicKey;
		buildLine = `${config.buildSha}${config.vapidEphemeral ? ' (temporary push keys)' : ''}`;
		$('build').textContent = `Launch ${state.launches} · build ${buildLine}`;
		// Check 0's machine half, from the server rather than guessed at in the page. `tls.secure` is
		// read off the socket at the server, which is the only thing that cannot be faked by a header.
		$('trust-facts').textContent = trustFacts(config);
		if (config.tls && !config.tls.secure && secureOrigin) {
			// Cannot happen over a direct connection, and would mean something is terminating TLS in
			// between. Worth saying out loud rather than passing quietly.
			setVerdict(0, 'fail', 'This page arrived over HTTPS but the server saw a plain connection.',
				'Something between the phone and the Mac is terminating the connection. That is a finding — tell Rich.');
			record('trust', 'fail', 'FAIL — the browser saw HTTPS and the server saw plain HTTP', 'something is terminating TLS in between');
			$('trust-row').hidden = true;
		}
	} catch (err) {
		buildLine = 'server unreachable';
		$('build').textContent = `Launch ${state.launches} · the server did not answer`;
		$('trust-facts').textContent = trustFacts(null);
		$('notif-on').disabled = true;
		setVerdict(4, 'fail', 'The server did not answer, so notifications cannot be tested.', String(err.message || err));
	}
	save();
	renderResults();
})();

})();

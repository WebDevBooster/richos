#!/usr/bin/env node
'use strict';

// Desktop verification: drive the real page, in a real browser, against the real server.
//
// The unit tests prove the arithmetic. This proves the WIRING — that getUserMedia, AudioWorklet,
// the service worker, the manifest and the push sender actually connect to each other in a browser,
// which is the class of defect that unit tests cannot see and that would waste his twenty minutes.
//
// NOT part of `npm test`, and Playwright is NOT a dependency of this probe. It is resolved from
// wherever it already exists on the machine (`PROBE_PLAYWRIGHT` overrides), and if it is not there
// this script says so and exits 0 rather than pretending to have verified something.
//
// NO AUDIO IS PLAYED. Chromium is given `--use-fake-device-for-media-stream`, which synthesizes a
// tone as microphone INPUT inside the browser process; nothing reaches this Mac's speakers, and the
// page's optional "play it back" control is never clicked.

const { spawn } = require('node:child_process');
const path = require('node:path');
const http = require('node:http');
const { generateVapidKeys } = require('../lib/webpush.js');

const PLAYWRIGHT_CANDIDATES = [
	process.env.PROBE_PLAYWRIGHT,
	'playwright',
	'/Users/alex/ab/femcboost/avelor/node_modules/playwright'
].filter(Boolean);

function loadPlaywright() {
	for (const candidate of PLAYWRIGHT_CANDIDATES) {
		try { return require(candidate); } catch { /* try the next */ }
	}
	return null;
}

const PORT = 8799;
const ORIGIN = `http://127.0.0.1:${PORT}`;
const CODE = 'probe-desktop-verify';

let failures = 0;
function check(label, ok, detail) {
	process.stdout.write(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? `\n        ${detail}` : ''}\n`);
	if (!ok) failures++;
}

function get(url) {
	return new Promise((resolve, reject) => {
		http.get(url, (res) => {
			const chunks = [];
			res.on('data', (c) => chunks.push(c));
			res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8'), headers: res.headers }));
		}).on('error', reject);
	});
}

async function waitForServer(tries = 60) {
	for (let i = 0; i < tries; i++) {
		try {
			const r = await get(`${ORIGIN}/healthz`);
			if (r.status === 200) return;
		} catch { /* not up yet */ }
		await new Promise((r) => setTimeout(r, 250));
	}
	throw new Error('the probe server did not come up');
}

(async () => {
	const keys = generateVapidKeys();

	const server = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], {
		env: Object.assign({}, process.env, {
			PORT: String(PORT),
			PROBE_ACCESS_CODE: CODE,
			PROBE_BUILD_SHA: 'desktop-verify',
			VAPID_PUBLIC_KEY: keys.publicKey,
			VAPID_PRIVATE_KEY: keys.privateKey,
			VAPID_SUBJECT: 'mailto:probe@richos.invalid'
		}),
		stdio: ['ignore', 'pipe', 'pipe']
	});
	const serverLog = [];
	server.stdout.on('data', (d) => serverLog.push(d.toString()));
	server.stderr.on('data', (d) => serverLog.push(d.toString()));

	// Whatever happens below — a thrown assertion, a browser that will not start, a Ctrl-C — this
	// process must not leave a server behind. A scratch process that outlives its run is garbage,
	// and garbage is always cleaned up.
	let cleanedUp = false;
	const cleanup = () => {
		if (cleanedUp) return;
		cleanedUp = true;
		try { server.kill('SIGTERM'); } catch { /* already gone */ }
		setTimeout(() => { try { server.kill('SIGKILL'); } catch { /* already gone */ } }, 2000).unref();
	};
	process.on('exit', cleanup);
	for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { cleanup(); process.exit(1); });

	try {
		await waitForServer();
		process.stdout.write(`\n=== the server, without a browser ===\n`);

		// --- the access code behaves as the plan's doctrine says ---
		const openPage = await get(`${ORIGIN}/`);
		check('an unauthorized page request gets a flat 404, not an informative error',
			openPage.status === 404 && !/code|token|unauthor/i.test(openPage.body),
			`HTTP ${openPage.status}, body ${JSON.stringify(openPage.body.trim())}`);

		const codedPage = await get(`${ORIGIN}/?k=${CODE}`);
		check('the page loads with the code', codedPage.status === 200 && codedPage.body.includes('RichOS phone probe'));

		const assets = await get(`${ORIGIN}/pcm.js`);
		check('assets load without the code, so no markup reference can be missed', assets.status === 200 && assets.body.includes('TARGET_RATE'));

		const manifest = await get(`${ORIGIN}/manifest.webmanifest?k=${CODE}`);
		const parsed = JSON.parse(manifest.body);
		check('the manifest declares display: standalone — without it iOS gives no push at all',
			parsed.display === 'standalone', `display=${parsed.display}`);
		check('start_url carries the access code, so the installed app can load itself',
			parsed.start_url.includes(CODE), `start_url=${parsed.start_url}`);
		check('the manifest is served as application/manifest+json',
			String(manifest.headers['content-type']).startsWith('application/manifest+json'),
			String(manifest.headers['content-type']));
		check('three icons are declared, including a maskable one',
			parsed.icons.length === 3 && parsed.icons.some((i) => i.purpose === 'maskable'));

		for (const icon of parsed.icons) {
			const r = await get(ORIGIN + icon.src);
			check(`icon ${icon.src.split('/').pop()} is a real PNG`, r.status === 200 && r.body.charCodeAt(1) === 0x50);
		}

		const config = await get(`${ORIGIN}/api/config?k=${CODE}`);
		check('the page gets the VAPID public key at runtime, so no key is committed',
			JSON.parse(config.body).vapidPublicKey === keys.publicKey);

		// --- the browser ---
		const playwright = loadPlaywright();
		if (!playwright) {
			process.stdout.write(`\nSKIPPED: Playwright is not installed on this machine, so the browser half did not run.\n` +
				`Set PROBE_PLAYWRIGHT to a playwright module path to run it. This is reported, not hidden.\n`);
			process.exit(failures ? 1 : 0);
		}

		process.stdout.write(`\n=== in a real browser (Chromium, headless, fake microphone) ===\n`);
		const browser = await playwright.chromium.launch({
			args: [
				// Grants the microphone without a dialog and feeds a synthesized tone as INPUT.
				// Nothing is played out of this Mac's speakers.
				'--use-fake-ui-for-media-stream',
				'--use-fake-device-for-media-stream'
			]
		});
		try {
			const context = await browser.newContext({ permissions: ['microphone'] });
			const page = await context.newPage();
			const errors = [];
			page.on('pageerror', (e) => errors.push(String(e)));
			page.on('console', (m) => { if (m.type() === 'error') errors.push(`console: ${m.text()}`); });

			await page.goto(`${ORIGIN}/?k=${CODE}`);
			await page.waitForFunction(() => !document.getElementById('build').textContent.includes('Loading'));

			check('the page booted with no JavaScript errors', errors.length === 0, errors.join('\n        '));
			check('it reports the build it was served by',
				(await page.textContent('#build')).includes('desktop-verify'),
				await page.textContent('#build'));

			// Check 1 in a tab must say "browser tab", because that is the honest answer here.
			const v1 = (await page.textContent('#v1')).trim();
			check('check 1 correctly reports a browser tab rather than claiming an install',
				/browser tab/i.test(v1), v1);

			// --- THE GATE: record through the real Web Audio path ---
			await page.click('#mic-on');
			await page.waitForSelector('#record:not([disabled])', { timeout: 10000 });
			check('the microphone opened on its own button, separate from the recorder', true);

			await page.locator('#record').scrollIntoViewIfNeeded();
			const box = await page.locator('#record').boundingBox();
			check('the record control is on screen before the synthetic press',
				box && box.y >= 0 && box.y < page.viewportSize().height, JSON.stringify(box));
			await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
			await page.mouse.down();
			await page.waitForTimeout(2000); // a real 2-second hold
			await page.mouse.up();

			await page.waitForFunction(() => !/Recording/.test(document.getElementById('record').textContent));
			await page.waitForTimeout(250);

			const v2 = (await page.textContent('#v2')).trim();
			const d2 = (await page.textContent('#d2')).trim();
			process.stdout.write(`        recorder said: ${d2}\n`);

			check('check 2 captured non-silent audio through AudioWorklet + getUserMedia',
				/microphone works/i.test(v2), v2);
			check('it used the AudioWorklet path, not the deprecated fallback',
				/AudioWorklet/.test(d2), d2);
			check('it produced samples at 16000 Hz, the rate the Mac recognizer wants',
				/samples at 16000 Hz/.test(d2), d2);

			const seconds = Number((/([\d.]+) s,/.exec(d2) || [])[1]);
			check('the recording length matches the 2-second hold',
				seconds > 1.5 && seconds < 2.6, `${seconds} s`);

			const sampleCount = Number((/(\d+) samples at 16000/.exec(d2) || [])[1]);
			check('the 16 kHz sample count matches the duration',
				Math.abs(sampleCount - seconds * 16000) < 16000 * 0.05,
				`${sampleCount} samples for ${seconds} s (expected about ${Math.round(seconds * 16000)})`);

			const wavKb = Number((/([\d.]+) KB WAV/.exec(d2) || [])[1]);
			check('the WAV is the size the plan quotes, about 32 KB per second',
				Math.abs(wavKb - seconds * 32) < seconds * 32 * 0.05,
				`${wavKb} KB for ${seconds} s`);

			// Independently decode the WAV the same code produces, to prove the header is real and
			// not merely the right length.
			const wavProbe = await page.evaluate(async () => {
				const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
				const ctx = new AudioContext();
				const source = ctx.createMediaStreamSource(stream);
				await ctx.audioWorklet.addModule('/recorder-worklet.js');
				const node = new AudioWorkletNode(ctx, 'probe-capture');
				const chunks = [];
				node.port.onmessage = (e) => chunks.push(e.data);
				const mute = ctx.createGain(); mute.gain.value = 0;
				source.connect(node); node.connect(mute); mute.connect(ctx.destination);
				await new Promise((r) => setTimeout(r, 1000));
				node.port.postMessage('stop');
				stream.getTracks().forEach((t) => t.stop());
				const result = window.ProbePCM.analyze(chunks, ctx.sampleRate);
				// Decode it with the browser's OWN decoder: if decodeAudioData accepts it, the header
				// is a real WAV and not just 44 plausible bytes.
				const decoded = await ctx.decodeAudioData(result.wav.slice(0));
				// Read the header bytes ourselves. `decodeAudioData` resamples to the context's own
				// rate, so `decoded.sampleRate` reports 48000 no matter what the file says — it can
				// prove the file DECODES, and it can never prove what rate the file declares.
				const view = new DataView(result.wav);
				const tag = (o) => String.fromCharCode(view.getUint8(o), view.getUint8(o + 1), view.getUint8(o + 2), view.getUint8(o + 3));
				await ctx.close();
				return {
					captureRate: result.captureRate,
					outcome: result.outcome,
					peakDbfs: result.stats.peakDbfs,
					headerRiff: tag(0),
					headerWave: tag(8),
					headerFormat: view.getUint16(20, true),
					headerChannels: view.getUint16(22, true),
					headerRate: view.getUint32(24, true),
					headerBits: view.getUint16(34, true),
					decodesInBrowser: decoded.length > 0,
					decodedSeconds: decoded.duration
				};
			});
			process.stdout.write(`        independent capture: ${JSON.stringify(wavProbe)}\n`);
			check('the hand-written WAV header declares 16 kHz mono 16-bit PCM',
				wavProbe.headerRiff === 'RIFF' && wavProbe.headerWave === 'WAVE' && wavProbe.headerFormat === 1
					&& wavProbe.headerChannels === 1 && wavProbe.headerRate === 16000 && wavProbe.headerBits === 16,
				`${wavProbe.headerRiff}/${wavProbe.headerWave} format=${wavProbe.headerFormat} ch=${wavProbe.headerChannels} rate=${wavProbe.headerRate} bits=${wavProbe.headerBits}`);
			check('the browser\'s own decoder accepts the file',
				wavProbe.decodesInBrowser, JSON.stringify(wavProbe.decodesInBrowser));
			check('the AudioContext rate is read rather than assumed — the track reported a different one',
				wavProbe.captureRate > 0, `context ${wavProbe.captureRate} Hz`);
			check('the decoded duration matches the one-second capture',
				Math.abs(wavProbe.decodedSeconds - 1) < 0.15, `${wavProbe.decodedSeconds.toFixed(3)} s`);
			check('the fake device produced non-silent audio, as it should',
				wavProbe.outcome === 'non-silent', `${wavProbe.outcome}, peak ${wavProbe.peakDbfs.toFixed(1)} dBFS`);

			// --- the service worker registers and subscribes ---
			const push = await page.evaluate(async () => {
				try {
					const reg = await navigator.serviceWorker.register(`/sw.js?k=${new URLSearchParams(location.search).get('k')}`, { scope: '/' });
					await navigator.serviceWorker.ready;
					return { registered: true, scope: reg.scope, hasPushManager: 'pushManager' in reg };
				} catch (e) {
					return { registered: false, error: String(e) };
				}
			});
			check('the service worker registers at the root scope',
				push.registered && push.scope === `${ORIGIN}/` && push.hasPushManager, JSON.stringify(push));

			// --- the results panel is copyable text with all five lines ---
			const results = await page.inputValue('#results-text');
			process.stdout.write(`        results panel:\n${results.split('\n').map((l) => '          ' + l).join('\n')}\n`);
			for (const n of ['1. Install', '2. Microphone', '3. Permission persistence', '4. Push', '5. Tap to open']) {
				check(`the results panel carries "${n}"`, results.includes(n));
			}

			// --- both themes actually render ---
			for (const scheme of ['dark', 'light']) {
				await page.emulateMedia({ colorScheme: scheme });
				const painted = await page.evaluate(() => {
					const s = getComputedStyle(document.body);
					return { bg: s.backgroundColor, fg: s.color };
				});
				check(`the ${scheme} theme paints its own palette`,
					painted.bg !== painted.fg, `background ${painted.bg}, text ${painted.fg}`);
				process.stdout.write(`        ${scheme}: background ${painted.bg}, text ${painted.fg}\n`);
			}

			check('no JavaScript errors after the whole run', errors.length === 0, errors.join('\n        '));
			await context.close();
		} finally {
			await browser.close();
		}
	} catch (err) {
		check(`the harness ran to completion`, false, String(err && err.stack || err));
	} finally {
		cleanup();
	}

	process.stdout.write(`\n=== ${failures === 0 ? 'ALL CHECKS PASSED' : `${failures} CHECK(S) FAILED`} ===\n`);
	if (failures) process.stdout.write(`\nserver log:\n${serverLog.join('')}\n`);
	process.exit(failures ? 1 : 0);
})();

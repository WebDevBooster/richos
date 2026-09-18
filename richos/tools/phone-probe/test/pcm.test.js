'use strict';

// The audio math for check 2, driven in Node with synthesized input.
//
// Check 2 is the gate the whole plan turns on. If this code says "silent" when the microphone
// worked, or "non-silent" when it did not, the probe returns the one wrong answer that would move a
// week of engineering onto the native track for no reason. So the decision function is tested
// against signals whose correct answers are arithmetic, not opinion.

const test = require('node:test');
const assert = require('node:assert');
const pcm = require('../public/pcm.js');

function tone({ seconds, rate, hz = 440, amplitude = 0.5, chunk = 128 }) {
	const total = Math.round(seconds * rate);
	const chunks = [];
	for (let i = 0; i < total; i += chunk) {
		const n = Math.min(chunk, total - i);
		const c = new Float32Array(n);
		for (let j = 0; j < n; j++) c[j] = amplitude * Math.sin((2 * Math.PI * hz * (i + j)) / rate);
		chunks.push(c);
	}
	return chunks;
}

function silence({ seconds, rate, chunk = 128 }) {
	return tone({ seconds, rate, amplitude: 0, chunk });
}

// --- measure ---------------------------------------------------------------

test('peak and RMS of a half-amplitude sine are the textbook values', () => {
	const s = pcm.measure(tone({ seconds: 1, rate: 48000, amplitude: 0.5 }));
	assert.ok(Math.abs(s.peak - 0.5) < 0.001, `peak ${s.peak}`);
	// RMS of a sine is amplitude / sqrt(2).
	assert.ok(Math.abs(s.rms - 0.5 / Math.SQRT2) < 0.001, `rms ${s.rms}`);
	assert.ok(Math.abs(s.peakDbfs - (-6.02)) < 0.05, `peak dBFS ${s.peakDbfs}`);
	assert.ok(Math.abs(s.rmsDbfs - (-9.03)) < 0.05, `rms dBFS ${s.rmsDbfs}`);
});

test('digital silence reports -inf rather than 0 dBFS', () => {
	const s = pcm.measure(silence({ seconds: 0.5, rate: 48000 }));
	assert.strictEqual(s.peak, 0);
	assert.strictEqual(s.peakDbfs, -Infinity);
	assert.strictEqual(pcm.formatDbfs(s.peakDbfs), '-inf');
	// 0 dBFS would mean full scale — the loudest possible signal. Printing that for silence is the
	// kind of readout that makes a working microphone look broken and vice versa.
});

// --- the verdict -----------------------------------------------------------

test('a three-second tone at a normal speaking level reads non-silent', () => {
	const r = pcm.analyze(tone({ seconds: 3, rate: 48000, amplitude: 0.2 }), 48000);
	assert.strictEqual(r.outcome, 'non-silent');
	assert.ok(Math.abs(r.seconds - 3) < 0.01);
	assert.strictEqual(r.targetRate, 16000);
});

test('three seconds of silence reads silent, not failed', () => {
	const r = pcm.analyze(silence({ seconds: 3, rate: 48000 }), 48000);
	assert.strictEqual(r.outcome, 'silent');
	// A silent recording still produced a WAV: the microphone opened and delivered samples, and the
	// distinction between "opened but heard nothing" and "never opened" is the whole diagnosis.
	assert.ok(r.wav, 'a silent capture must still yield a file');
});

test('a signal just either side of the stated -50 dBFS threshold falls the right way', () => {
	const rate = 48000;
	// -46 dBFS
	const loud = pcm.analyze(tone({ seconds: 1, rate, amplitude: Math.pow(10, -46 / 20) }), rate);
	// -54 dBFS
	const quiet = pcm.analyze(tone({ seconds: 1, rate, amplitude: Math.pow(10, -54 / 20) }), rate);
	assert.strictEqual(loud.outcome, 'non-silent');
	assert.strictEqual(quiet.outcome, 'silent');
	assert.strictEqual(pcm.SILENCE_PEAK_DBFS, -50, 'the threshold printed on the page');
});

test('a slip of the finger is "too-short", never a failure', () => {
	// THE edge case. iOS raises its microphone permission dialog under his finger; he lifts the
	// finger to reach Allow; pointerup ends the recording before the microphone ever opened. If that
	// is reported as a failed microphone, the probe moves voice notes to native for no reason.
	const r = pcm.analyze(tone({ seconds: 0.2, rate: 48000, amplitude: 0.3 }), 48000);
	assert.strictEqual(r.outcome, 'too-short');
	assert.ok(r.seconds > 0, 'the duration is still reported, so he is told what happened');
	assert.strictEqual(pcm.MIN_USEFUL_SECONDS, 0.5);
});

test('no samples at all is its own outcome, distinct from silence', () => {
	const r = pcm.analyze([], 48000);
	assert.strictEqual(r.outcome, 'no-samples');
	// "The microphone never delivered a block" and "the microphone delivered quiet blocks" are
	// different findings with different fallbacks. Collapsing them loses the diagnosis.
});

// --- downsampling ----------------------------------------------------------

test('48 kHz downsamples to exactly the right number of 16 kHz samples', () => {
	const input = new Float32Array(48000);
	const out = pcm.downsample(input, 48000, 16000);
	assert.strictEqual(out.length, 16000);
});

test('44.1 kHz — the other rate phones use — produces a sane length', () => {
	const out = pcm.downsample(new Float32Array(44100), 44100, 16000);
	// 44100/16000 is not an integer ratio; 16000 output samples is the floor and the right answer.
	assert.strictEqual(out.length, 16000);
});

test('a context already at 16 kHz is passed through, and is a copy', () => {
	const input = new Float32Array([0.1, -0.2, 0.3]);
	const out = pcm.downsample(input, 16000, 16000);
	assert.deepStrictEqual(Array.from(out), [0.1, -0.2, 0.3].map((v) => Math.fround(v)));
	out[0] = 9;
	assert.notStrictEqual(input[0], 9, 'must not alias the caller\'s buffer');
});

test('the anti-alias filter passes speech and stops everything above 8 kHz', () => {
	// The reason this test is specific rather than "it attenuates a bit": the first implementation
	// here WAS a box average, it looked like a low-pass, and measured it gave a 12 kHz tone only
	// -9.5 dB. A probe whose check 2 passes either way would never have surfaced that, and plan
	// §3.3 makes this recorder the one v1 inherits. So the response is pinned at named frequencies.
	const peakOf = (a) => {
		// Skip the first and last tenth: the filter is zero-padded at the edges, so those samples
		// are a deliberate fade and not part of the response being measured.
		let m = 0;
		for (let i = Math.floor(a.length * 0.1); i < Math.floor(a.length * 0.9); i++) m = Math.max(m, Math.abs(a[i]));
		return m;
	};
	const at = (hz, rate) => peakOf(pcm.downsample(pcm.concat(tone({ seconds: 0.5, rate, hz, amplitude: 0.5 })), rate, 16000));

	for (const rate of [48000, 44100]) {
		// Speech band: through untouched. A filter that quietly attenuates the signal would drag the
		// measured peak toward the silence threshold and bias check 2 itself.
		for (const hz of [100, 500, 2000, 4000]) {
			const db = 20 * Math.log10(at(hz, rate) / 0.5);
			assert.ok(Math.abs(db) < 0.5, `${hz} Hz at ${rate} must pass unattenuated, measured ${db.toFixed(2)} dB`);
		}
		// Above the 8 kHz Nyquist limit of the 16 kHz target: gone, not folded back in.
		for (const hz of [8000, 9000, 12000, 20000]) {
			const db = 20 * Math.log10(at(hz, rate) / 0.5 + 1e-12);
			assert.ok(db < -40, `${hz} Hz at ${rate} must be rejected by at least 40 dB, measured ${db.toFixed(1)} dB`);
		}
	}
});

test('upsampling is refused loudly, because no real device needs it', () => {
	assert.throws(() => pcm.downsample(new Float32Array(10), 8000, 16000), /refusing to upsample/);
});

// --- the WAV file ----------------------------------------------------------

test('the WAV header is a valid 16 kHz mono 16-bit PCM header', () => {
	const samples = new Float32Array(16000); // exactly one second
	const buf = pcm.encodeWav(samples, 16000);
	const view = new DataView(buf);
	const str = (o, n) => Array.from({ length: n }, (_, i) => String.fromCharCode(view.getUint8(o + i))).join('');

	assert.strictEqual(buf.byteLength, 44 + 32000, '44-byte header plus two bytes per sample');
	assert.strictEqual(str(0, 4), 'RIFF');
	assert.strictEqual(view.getUint32(4, true), 36 + 32000);
	assert.strictEqual(str(8, 4), 'WAVE');
	assert.strictEqual(str(12, 4), 'fmt ');
	assert.strictEqual(view.getUint32(16, true), 16);
	assert.strictEqual(view.getUint16(20, true), 1, 'PCM, uncompressed — no codec anywhere');
	assert.strictEqual(view.getUint16(22, true), 1, 'mono');
	assert.strictEqual(view.getUint32(24, true), 16000, 'the rate the Mac recognizer wants');
	assert.strictEqual(view.getUint32(28, true), 32000, 'byte rate');
	assert.strictEqual(view.getUint16(32, true), 2, 'block align');
	assert.strictEqual(view.getUint16(34, true), 16, 'bits per sample');
	assert.strictEqual(str(36, 4), 'data');
	assert.strictEqual(view.getUint32(40, true), 32000);
});

test('the plan\'s stated size — about 32 KB per second — is what this actually produces', () => {
	// Plan §3.3 quotes ~32 KB/s so nobody is surprised by a voice note on cellular. Asserting it
	// here means the number in the plan and the number on the wire cannot drift apart silently.
	const oneSecond = pcm.encodeWav(new Float32Array(16000), 16000).byteLength;
	assert.strictEqual(oneSecond, 32044, '16000 samples x 2 bytes, plus the 44-byte header');
	// KB decimal, which is the unit the plan quotes. 32000 bytes is 32 KB and 31.25 KiB; checking
	// this against 1024 was my own error on the first run, and the plan's number was right.
	assert.ok(Math.abs(oneSecond / 1000 - 32) < 0.1, `${(oneSecond / 1000).toFixed(2)} KB per second`);
});

test('samples are clamped, so one clipped sample cannot wrap to a click', () => {
	const buf = pcm.encodeWav(new Float32Array([1.5, -1.5, 1, -1, 0]), 16000);
	const view = new DataView(buf);
	assert.strictEqual(view.getInt16(44, true), 32767, '+1.5 must clamp to full positive scale');
	assert.strictEqual(view.getInt16(46, true), -32768, '-1.5 must clamp to full negative scale');
	assert.strictEqual(view.getInt16(48, true), 32767);
	assert.strictEqual(view.getInt16(50, true), -32768);
	assert.strictEqual(view.getInt16(52, true), 0);
});

test('a full round trip: three seconds at 48 kHz yields a 3-second 16 kHz WAV of the stated size', () => {
	const r = pcm.analyze(tone({ seconds: 3, rate: 48000, amplitude: 0.3 }), 48000);
	assert.strictEqual(r.outcome, 'non-silent');
	assert.strictEqual(r.resampledCount, 48000, '3 s at 16 kHz');
	assert.strictEqual(r.wavBytes, 44 + 48000 * 2);
	assert.ok(Math.abs(r.wavBytes / 1000 - 96) < 0.2, `${(r.wavBytes / 1000).toFixed(1)} KB for 3 s`);
});

// The audio math for check 2, kept apart from the page on purpose.
//
// The microphone question is the gate the whole plan turns on (§3.2 check 2, §7 risk 1), so the
// code that decides "non-silent: yes/no" must be testable without a phone, without a browser and
// without a microphone. Everything here is a pure function of numbers; `test/pcm.test.js` drives it
// in Node with synthesized input whose correct answers are known in advance.
//
// Loads both as a plain script (defines `globalThis.ProbePCM`) and as a CommonJS module.

(function (root, factory) {
	const api = factory();
	if (typeof module === 'object' && module.exports) module.exports = api;
	root.ProbePCM = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
	'use strict';

	// The rate the Mac's recognizer wants. `SttEngine::transcribe` takes `&[f32]` samples, and the
	// whisper models the app provisions are 16 kHz mono — so the phone produces exactly that and
	// the Mac decodes nothing. Plan §3.3.
	const TARGET_RATE = 16000;

	// The stated threshold for check 2. It is printed on the page next to the result, because a
	// pass/fail with an unstated threshold is an opinion.
	const SILENCE_PEAK_DBFS = -50;

	// Below this, a recording is not a failure — it is a slip. Reporting "no audio" for a 200 ms
	// press is the single most likely way this probe returns the WRONG answer on the one check that
	// decides the plan: iOS puts its permission dialog up UNDER his finger, he lifts the finger to
	// tap Allow, pointerup fires, and the recording is over before the microphone ever opened.
	const MIN_USEFUL_SECONDS = 0.5;

	function toDbfs(amplitude) {
		if (!(amplitude > 0)) return -Infinity;
		return 20 * Math.log10(amplitude);
	}

	// Peak and RMS over the samples AS CAPTURED, before any rate conversion — this is the honest
	// measure of what the microphone gave us, rather than of what our own filter left behind.
	function measure(chunks) {
		let peak = 0;
		let sumSquares = 0;
		let count = 0;
		for (const chunk of chunks) {
			for (let i = 0; i < chunk.length; i++) {
				const v = chunk[i];
				const a = v < 0 ? -v : v;
				if (a > peak) peak = a;
				sumSquares += v * v;
				count++;
			}
		}
		const rms = count ? Math.sqrt(sumSquares / count) : 0;
		return {
			sampleCount: count,
			peak,
			rms,
			peakDbfs: toDbfs(peak),
			rmsDbfs: toDbfs(rms)
		};
	}

	function concat(chunks) {
		let total = 0;
		for (const c of chunks) total += c.length;
		const out = new Float32Array(total);
		let at = 0;
		for (const c of chunks) { out.set(c, at); at += c.length; }
		return out;
	}

	// Anti-alias filter length and cutoff for the decimation below.
	//
	// 0.45 of the target rate leaves a little room below the 8 kHz Nyquist limit for the filter's
	// transition band. 127 taps is what makes that transition narrow enough to actually land in that
	// room; it costs a few million multiplications for a voice note, on audio that is already over.
	const FILTER_TAPS = 127;
	const FILTER_CUTOFF_FRACTION = 0.45;

	// A windowed-sinc low-pass, normalized to unity gain at DC.
	function designLowPass(cutoffHz, sampleRate, taps) {
		const fc = cutoffHz / sampleRate; // cycles per sample
		const M = taps - 1;
		const h = new Float64Array(taps);
		let sum = 0;
		for (let n = 0; n <= M; n++) {
			const k = n - M / 2;
			const sinc = k === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * k) / (Math.PI * k);
			// Blackman: the sidelobes matter more here than the slightly wider main lobe, because a
			// sidelobe is exactly the path an out-of-band tone takes to get in.
			const w = 0.42 - 0.5 * Math.cos((2 * Math.PI * n) / M) + 0.08 * Math.cos((4 * Math.PI * n) / M);
			h[n] = sinc * w;
			sum += h[n];
		}
		// Unity at DC, so a quiet recording is not made quieter by its own filter — which would
		// move the measured peak toward the silence threshold and bias check 2 itself.
		for (let n = 0; n < taps; n++) h[n] /= sum;
		return h;
	}

	// Downsample to 16 kHz: low-pass first, then decimate.
	//
	// Plain decimation (take every Nth sample) is shorter and wrong: everything above 8 kHz folds
	// back into the band as alias noise, and on a 48 kHz phone microphone that is most of the
	// sibilance in his voice arriving as hiss in the middle of speech.
	//
	// A box average over each window was the first thing here, on the grounds that it is a low-pass
	// and "good enough". MEASURED, it is not: a 12 kHz tone came through at 0.167 against an in-band
	// 0.498, i.e. only -9.5 dB, and 20 kHz at -13.5 dB. That is a weak filter and it would have
	// shipped unnoticed, because the probe's own check 2 passes either way. It matters because plan
	// §3.3 makes this recorder the one v1 inherits, and what it feeds is whisper — so the cost of
	// getting it right is 25 lines, once, here.
	function downsample(samples, fromRate, toRate) {
		if (!(fromRate > 0)) throw new Error('fromRate must be positive');
		if (fromRate === toRate) return samples.slice();
		if (fromRate < toRate) {
			// Upsampling is not something a real device should ever need — no phone records below
			// 16 kHz — so it is refused rather than silently approximated.
			throw new Error(`refusing to upsample ${fromRate} Hz to ${toRate} Hz: a device that records below the target rate is a finding, not something to paper over`);
		}
		const ratio = fromRate / toRate;
		const outLength = Math.floor(samples.length / ratio);
		const out = new Float32Array(outLength);

		const h = designLowPass(FILTER_CUTOFF_FRACTION * toRate, fromRate, FILTER_TAPS);
		const half = (FILTER_TAPS - 1) / 2;

		for (let i = 0; i < outLength; i++) {
			const center = Math.round(i * ratio);
			let acc = 0;
			for (let t = 0; t < FILTER_TAPS; t++) {
				const src = center + t - half;
				// Zero-padded at both edges. The cost is a few milliseconds of fade at the very
				// start and end of a recording, which is inaudible and cannot affect a verdict.
				if (src >= 0 && src < samples.length) acc += samples[src] * h[t];
			}
			out[i] = acc;
		}
		return out;
	}

	// A 16-bit PCM mono WAV, header written by hand. 44 bytes of RIFF and nothing else — this is the
	// file `whisper-cli` wants and the reason no codec is involved anywhere in this probe.
	function encodeWav(samples, sampleRate) {
		const bytesPerSample = 2;
		const dataBytes = samples.length * bytesPerSample;
		const buffer = new ArrayBuffer(44 + dataBytes);
		const view = new DataView(buffer);

		const ascii = (offset, text) => {
			for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
		};

		ascii(0, 'RIFF');
		view.setUint32(4, 36 + dataBytes, true); // everything after this field
		ascii(8, 'WAVE');
		ascii(12, 'fmt ');
		view.setUint32(16, 16, true);            // fmt chunk length
		view.setUint16(20, 1, true);             // 1 = PCM, uncompressed
		view.setUint16(22, 1, true);             // mono
		view.setUint32(24, sampleRate, true);
		view.setUint32(28, sampleRate * bytesPerSample, true); // byte rate, mono
		view.setUint16(32, bytesPerSample, true);              // block align, mono
		view.setUint16(34, 16, true);            // bits per sample
		ascii(36, 'data');
		view.setUint32(40, dataBytes, true);

		let at = 44;
		for (let i = 0; i < samples.length; i++) {
			// Clamp before scaling. A float above 1.0 wraps to a large negative int16 otherwise,
			// which turns one clipped sample into an audible click.
			let v = samples[i];
			if (v > 1) v = 1; else if (v < -1) v = -1;
			// Asymmetric scaling, because int16 runs -32768..32767.
			view.setInt16(at, v < 0 ? v * 0x8000 : v * 0x7fff, true);
			at += bytesPerSample;
		}
		return buffer;
	}

	// The whole of check 2's verdict, as a pure function. `captureRate` is what the AudioContext
	// actually gave us, which on iOS is usually 48000 and is never assumed.
	function analyze(chunks, captureRate) {
		const stats = measure(chunks);
		const seconds = captureRate > 0 ? stats.sampleCount / captureRate : 0;

		if (stats.sampleCount === 0) {
			return { outcome: 'no-samples', seconds: 0, captureRate, stats, wav: null };
		}
		if (seconds < MIN_USEFUL_SECONDS) {
			return { outcome: 'too-short', seconds, captureRate, stats, wav: null };
		}

		const joined = concat(chunks);
		const resampled = downsample(joined, captureRate, TARGET_RATE);
		const wav = encodeWav(resampled, TARGET_RATE);

		return {
			outcome: stats.peakDbfs > SILENCE_PEAK_DBFS ? 'non-silent' : 'silent',
			seconds,
			captureRate,
			stats,
			targetRate: TARGET_RATE,
			resampledCount: resampled.length,
			wav,
			wavBytes: wav.byteLength
		};
	}

	function formatDbfs(db) {
		if (!isFinite(db)) return '-inf';
		return `${db >= 0 ? '+' : ''}${db.toFixed(1)}`;
	}

	return {
		TARGET_RATE,
		SILENCE_PEAK_DBFS,
		MIN_USEFUL_SECONDS,
		toDbfs,
		measure,
		concat,
		downsample,
		encodeWav,
		analyze,
		formatDbfs
	};
});

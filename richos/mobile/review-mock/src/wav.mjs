// VOICE NOTES IN, AND A SPOKEN-REPLY STAND-IN OUT.
//
// In: the Mac's own acceptance rule (`app/crates/richos-voice/src/wav.rs` read_pcm16 and
// `phone/voice.rs` validate), so a recording the review host takes is one a real Mac would take.
// The review host does not recognize speech; it measures the length and says so in the row.
//
// Out: RichConnect plays Rich's replies aloud from `GET /api/audio/<id>`, which a Mac synthesizes
// with its own voice. The review host has no voice, so it serves a short, quiet two-note chime and
// every demo reply says that is what the play button will produce.

import { MAX_VOICE_BYTES, MAX_VOICE_SECONDS } from './limits.mjs';

const u16 = (b, i) => b[i] | (b[i + 1] << 8);
const u32 = (b, i) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;
const tag = (b, i) => String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);

/** `wav.rs` read_pcm16, returning the sample count rather than the samples. */
export function readPcm16(bytes) {
	if (bytes.length < 12 || tag(bytes, 0) !== 'RIFF' || tag(bytes, 8) !== 'WAVE') throw new Error('not a RIFF/WAVE file');
	let pos = 12, sampleRate = 0, channels = 0, bits = 0, dataBytes = null;
	while (pos + 8 <= bytes.length) {
		const id = tag(bytes, pos), size = u32(bytes, pos + 4);
		const start = pos + 8, end = Math.min(start + size, bytes.length);
		if (id === 'fmt ') {
			if (end - start < 16) throw new Error('truncated fmt chunk');
			channels = u16(bytes, start + 2);
			sampleRate = u32(bytes, start + 4);
			bits = u16(bytes, start + 14);
		} else if (id === 'data') {
			dataBytes = end - start;
		}
		pos = start + size + (size & 1);
	}
	if (dataBytes === null) throw new Error('no data chunk');
	if (bits !== 16) throw new Error(`expected 16-bit PCM, got ${bits}-bit`);
	if (channels === 0 || sampleRate === 0) throw new Error('missing fmt chunk');
	return { samples: Math.floor(dataBytes / 2), sampleRate, channels };
}

/**
 * `phone/voice.rs` validate, with the Mac's own sentences. Returns the duration in milliseconds
 * (`voice_notes.rs` duration_ms: samples * 1000 / 16000) or throws an Error whose message is the
 * sentence the phone shows.
 */
export function validateVoice(bytes) {
	if (bytes.length > MAX_VOICE_BYTES) throw new Error('The recording exceeds the upload limit.');
	let pcm;
	try { pcm = readPcm16(bytes); } catch { throw new Error('This recording is not a supported WAV file.'); }
	if (pcm.channels !== 1 || pcm.sampleRate !== 16000 || pcm.samples === 0 || pcm.samples > MAX_VOICE_SECONDS * 16000) {
		throw new Error('This voice message exceeds the 30-minute sending limit. It has been kept on your phone.');
	}
	return Math.floor((pcm.samples * 1000) / 16000);
}

/** A 16 kHz mono PCM16 WAV of `samples` (floats in -1..1). The Mac's `encode_pcm16_mono` layout. */
export function encodeWav(samples, sampleRate = 16000) {
	const data = samples.length * 2;
	const out = new Uint8Array(44 + data);
	const view = new DataView(out.buffer);
	const text = (at, s) => { for (let i = 0; i < 4; i++) out[at + i] = s.charCodeAt(i); };
	text(0, 'RIFF'); view.setUint32(4, 36 + data, true); text(8, 'WAVE');
	text(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
	view.setUint32(24, sampleRate, true); view.setUint32(28, sampleRate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
	text(36, 'data'); view.setUint32(40, data, true);
	for (let i = 0; i < samples.length; i++) {
		const s = Math.max(-1, Math.min(1, samples[i]));
		view.setInt16(44 + i * 2, Math.round(s * 32767), true);
	}
	return out;
}

/**
 * The stand-in for a spoken reply: two soft notes (E5 then A4), 1.2 seconds, faded in and out so
 * nothing clicks, at a quarter of full scale. Deterministic, so a replayed request gets the same
 * bytes. About 38 KB, far under the Mac's 6 MB reply ceiling.
 */
export function chime() {
	const rate = 16000, seconds = 1.2, total = Math.round(rate * seconds);
	const samples = new Float32Array(total);
	const notes = [{ hz: 659.25, from: 0, to: 0.55 }, { hz: 440, from: 0.5, to: 1.2 }];
	for (const note of notes) {
		const start = Math.round(note.from * rate), end = Math.round(note.to * rate);
		for (let i = start; i < end; i++) {
			const t = (i - start) / rate, length = (end - start) / rate;
			const envelope = Math.min(1, t / 0.02) * Math.max(0, 1 - t / length) ** 2;
			samples[i] += 0.25 * envelope * Math.sin(2 * Math.PI * note.hz * t);
		}
	}
	return encodeWav(samples, rate);
}

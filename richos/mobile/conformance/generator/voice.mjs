// voice.json: the voice upload's metadata, body and limits.
//
// The requests come from the real `api.js` `sendVoice`, and the WAV bytes from the real
// `web/web-app/lib/pcm.js` `encodeWav`. The limits are READ OUT OF THE MAC'S RUST SOURCE by
// pattern, with the file each came from, so a changed limit is a `--check` diff rather than a
// stale number in a JSON file.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { load, makeApi, answer, transcript, challenge, RICHOS } from './harness.mjs';
import { mac } from './signing.mjs';

const PHONE = 'richos/app/src-tauri/src/phone';

function constant(file, name) {
	const text = readFileSync(join(RICHOS, '..', PHONE, file), 'utf8');
	const m = text.match(new RegExp(`(?:pub )?const ${name}: [a-z0-9]+ = ([^;]+);`));
	if (!m) throw new Error(`${PHONE}/${file}: no constant ${name} (the Mac changed; update generator/voice.mjs)`);
	const expr = m[1].replace(/_/g, '').trim();
	if (!/^[0-9 *+()-]+$/.test(expr)) throw new Error(`${PHONE}/${file}: ${name} = ${m[1]} is not arithmetic this generator can read`);
	return { value: Function(`return (${expr});`)(), source: `${PHONE}/${file} ${name}` };
}

function wavHeader(bytes) {
	const b = Buffer.from(bytes);
	return {
		riff: b.toString('ascii', 0, 4), riff_size: b.readUInt32LE(4), wave: b.toString('ascii', 8, 12),
		fmt_chunk: b.toString('ascii', 12, 16), fmt_size: b.readUInt32LE(16), audio_format_pcm: b.readUInt16LE(20),
		channels: b.readUInt16LE(22), sample_rate: b.readUInt32LE(24), byte_rate: b.readUInt32LE(28),
		block_align: b.readUInt16LE(32), bits_per_sample: b.readUInt16LE(34), data_chunk: b.toString('ascii', 36, 40),
		data_size: b.readUInt32LE(40), total_bytes: b.length
	};
}

async function upload(name, fields) {
	const c = challenge('voice:' + name);
	const { api, mac: fake, signer } = makeApi({ script: [answer(200, { message_id: 'intake_7', cursor: 7, thread_id: 'thr_5c1e', accepted_at: '2026-09-22T13:00:00.412Z', duplicate: false, text_sha256: 'a'.repeat(64) }, { 'Content-Type': 'application/json; charset=utf-8', 'X-RichOS-Challenge': c })], state: { challenge: c } });
	await api.sendVoice(fields);
	const [request] = transcript(fake, signer);
	const query = Object.fromEntries(new URLSearchParams(request.target.split('?')[1]));
	return { name, input: { ...fields, bytes: undefined }, request: { ...request, mac: mac(request) }, query_parameters_in_order: Object.keys(query), decoded_query: query };
}

export async function voice() {
	const samples = Float32Array.from({ length: 320 }, (_, i) => Math.sin((2 * Math.PI * 440 * i) / 16000) * 0.5);
	const wav = new Uint8Array(load('pcm').encodeWav(samples, 16000));
	const base = { clientId: '01J8CONFORMANCEVOICE0000002', threadId: 'thr_5c1e', bytes: wav, sentAt: '2026-09-22T13:00:02.000Z' };
	const uploads = [
		await upload('20 ms, 440 Hz tone at 16 kHz', { ...base, seconds: 0.02 }),
		await upload('seconds as a whole number', { ...base, seconds: 12 }),
		await upload('seconds just under the 30-minute ceiling', { ...base, seconds: 1799.9 }),
		await upload('thread id and client id that need percent-encoding', { ...base, clientId: 'a b/c+d', threadId: 'thr_é&x=1' }),
		await upload('explicit codec and sample rate', { ...base, seconds: 1.5, codec: 'wav16k', sampleRate: 16000 })
	];
	const maxBody = constant('mod.rs', 'MAX_BODY_BYTES');
	const voiceMax = constant('voice.rs', 'MAX_UPLOAD');
	const voiceSeconds = constant('voice.rs', 'MAX_SECONDS');
	const replyMax = constant('voice.rs', 'MAX_REPLY');
	const lifetime = constant('device.rs', 'CHALLENGE_LIFETIME_MS');
	return {
		source: 'web/web-app/lib/api.js sendVoice; web/web-app/lib/pcm.js encodeWav; limits read from the Mac Rust source',
		route: 'POST /api/messages?client_id&thread_id&kind=voice&codec&sample_rate&seconds&sent_at with Content-Type: audio/wav and the WAV bytes as the body',
		required_by_the_mac: ['Content-Type exactly audio/wav', 'kind=voice', 'client_id 1..128 bytes', 'thread_id one of the Mac threads', 'PCM 16-bit mono 16000 Hz WAV'],
		signed_but_not_read_by_the_mac: ['codec', 'sample_rate', 'seconds', 'sent_at'],
		wav_header_of_the_reference_recording: wavHeader(wav),
		limits: {
			json_body_bytes: maxBody,
			voice_body_bytes: voiceMax,
			voice_seconds: voiceSeconds,
			reply_audio_bytes: replyMax,
			challenge_lifetime_ms: lifetime
		},
		uploads
	};
}

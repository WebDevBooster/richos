// events.json: the event stream, from raw bytes to what the conversation shows.
//
// Three layers, each from a real module:
//   1. bytes -> frames:        `mobile/platform/native.js` `sseParser`, the parser the preserved
//                              iPhone app runs, fed through a streaming UTF-8 decoder exactly
//                              as its `NativeEvents` does, at every chunking listed.
//   2. hello -> client state:  `web/web-app/lib/api.js` `openEvents` (challenge, api_base,
//                              capabilities and build are taken from `hello`).
//   3. frames -> conversation: `web/web-app/lib/thread.js` (merge by id, the Mac overwrites,
//                              deltas append, order by cursor, stand-ins retire on text).
//
// The WIRE is built from the frame list in the Mac's own format (`phone/stream.rs`
// `Frame::to_wire`: `id: <cursor>\nevent: <name>\ndata: <json>\n\n`; comments start with `:`).

import { load, makeApi, challenge, recordingEventSource, ORIGIN } from './harness.mjs';

const row = (id, thread, cursor, role, text, extra = {}) => ({
	id, thread_id: thread, cursor, role, kind: 'text', text,
	created_at: `2026-09-22T13:0${Math.min(cursor, 9)}:00.000Z`, client_id: null, has_audio: false,
	from_microphone: false, state: role === 'ceo' ? 'sent' : 'complete', complete: true, ...extra
});
const streaming = (id, thread, cursor) => row(id, thread, cursor, 'rich', '', { state: 'streaming', complete: false });
const delta = (id, cursor, text) => ({ message_id: id, cursor, text });

const hello = (thread, messages, extra = {}) => ({
	challenge: challenge('hello'), api_base: ORIGIN, thread_id: thread, latest_cursor: messages.length,
	threads: [{ id: 'thr_5c1e', title: 'the proposal' }, { id: 'thr_77aa', title: 'hiring' }],
	vapid_public_key: 'BExampleVapidKeyOnlyTheWebPushClientUsesIt', capabilities: ['text', 'voice', 'audio', 'native-push'],
	build: '1.2.0', messages, ...extra
});

function wire(frames) {
	return frames.map((f) => (f.comment !== undefined ? `: ${f.comment}\n\n` : `id: ${f.id}\nevent: ${f.event}\ndata: ${JSON.stringify(f.data)}\n\n`)).join('');
}

/// Run the reference parser over `chunks` (byte arrays) the way `NativeEvents` does.
function parse(chunks) {
	const { sseParser } = load('native');
	const out = [];
	const feed = sseParser((event, data) => out.push({ event, data }));
	const decoder = new TextDecoder();
	for (const chunk of chunks) feed(decoder.decode(chunk, { stream: true }));
	return out;
}

/// The chunkings every native parser must survive. Byte offsets, so a split can land inside a
/// multi-byte UTF-8 character, inside `data:`, or between the two newlines that end a frame.
/// A plan is `{ every: n }` (fixed-size chunks) or `{ cut_at: [byte offsets] }`.
function chunkings(bytes, text) {
	const at = (needle, plus = 0) => Buffer.byteLength(text.slice(0, text.indexOf(needle))) + plus;
	const multibyte = [...text].findIndex((ch) => Buffer.byteLength(ch) > 1);
	const plans = {
		whole: { cut_at: [] },
		one_byte_at_a_time: { every: 1 },
		seven_byte_chunks: { every: 7 },
		between_the_two_newlines_of_a_frame_end: { cut_at: [at('\n\n', 1)] },
		inside_the_data_field_name: { cut_at: [at('data:', 2)] }
	};
	if (multibyte !== -1) plans.inside_a_multibyte_character = { cut_at: [Buffer.byteLength([...text].slice(0, multibyte).join('')) + 1] };
	const result = {};
	for (const [name, plan] of Object.entries(plans)) {
		const cuts = plan.every ? Array.from({ length: Math.ceil(bytes.length / plan.every) - 1 }, (_, i) => (i + 1) * plan.every) : plan.cut_at;
		const edges = [0, ...cuts, bytes.length];
		result[name] = { plan, chunks: edges.slice(1).map((end, i) => bytes.subarray(edges[i], end)) };
	}
	return result;
}

function wireCase(name, frames, { crlf = false } = {}) {
	let text = wire(frames);
	if (crlf) text = text.replace(/\n/g, '\r\n');
	const bytes = Buffer.from(text, 'utf8');
	const plans = chunkings(bytes, text);
	const expected = parse(plans.whole.chunks);
	const splits = {};
	for (const [name2, { plan, chunks }] of Object.entries(plans)) {
		const got = parse(chunks);
		if (JSON.stringify(got) !== JSON.stringify(expected)) throw new Error(`${name}: the reference parser disagrees with itself under ${name2}`);
		splits[name2] = plan;
	}
	return { name, frames, wire_utf8: text, wire_bytes: bytes.length, chunkings: splits, expected_events: expected.map((e) => ({ event: e.event, data: JSON.parse(e.data) })) };
}

// ---- the conversation the frames produce --------------------------------------------------

function project(model) {
	return model.view([]).map((r) => ({ id: r.id, cursor: r.cursor, role: r.role, text: r.text, complete: r.complete }));
}

/// Contract section 10 (Reed): the stream is global, so a client watching `selected` keeps only
/// `message` rows whose `thread_id` is `selected`, and only `delta`s whose `message_id` it
/// already holds for `selected`. The shipped clients do NOT filter (contract section 11 item 4);
/// `unfiltered_view` below is what they show, recorded so the difference is visible.
function applyFrames(frames, selected, filter) {
	const { createThread } = load('thread');
	const model = createThread();
	for (const f of frames) {
		if (f.comment !== undefined) continue;
		if (f.event === 'hello') { if (Array.isArray(f.data.messages)) model.merge(filter ? f.data.messages.filter((m) => m.thread_id === selected) : f.data.messages); continue; }
		if (f.event === 'message') { if (!filter || f.data.thread_id === selected) model.merge(f.data); continue; }
		if (f.event === 'delta') { if (!filter || model.get(f.data.message_id)) model.applyDelta(f.data); }
	}
	return project(model);
}

function threadCase(name, frames, selected = 'thr_5c1e') {
	const filtered = applyFrames(frames, selected, true);
	const unfiltered = applyFrames(frames, selected, false);
	return {
		name, selected_thread: selected, frames,
		expected_view: filtered,
		unfiltered_view: unfiltered,
		filter_changes_the_view: JSON.stringify(filtered) !== JSON.stringify(unfiltered)
	};
}

async function helloCase(name, data) {
	const { Recorded, opened } = recordingEventSource();
	const { api, state } = makeApi({ state: { challenge: challenge('before-hello'), capabilities: ['text', 'voice'] }, eventSource: Recorded });
	await api.openEvents('thr_5c1e', null, {});
	opened[0].emit('hello', data);
	return {
		name, hello: data,
		state_after: {
			challenge: state.challenge, api_base: state.apiBase,
			api_base_refusal: state.apiBaseRefusal ? state.apiBaseRefusal.reason : null,
			capabilities: state.capabilities, build: state.build,
			offers_voice: api.offers('voice'), offers_audio: api.offers('audio')
		}
	};
}

export async function events() {
	const A = 'thr_5c1e', B = 'thr_77aa';
	const turn = [
		{ id: 2, event: 'hello', data: hello(A, [row('turn_8:user', A, 1, 'ceo', 'where are we on the proposal?'), row('turn_8:text:0', A, 2, 'rich', 'On it! The proposal is with legal.')]) },
		{ id: 3, event: 'message', data: row('turn_9:user', A, 3, 'ceo', 'and the numbers?') },
		{ id: 4, event: 'message', data: streaming('turn_9:text:0', A, 4) },
		{ id: 4, event: 'delta', data: delta('turn_9:text:0', 4, 'The numbers ') },
		{ id: 4, event: 'delta', data: delta('turn_9:text:0', 4, 'are in.') },
		{ id: 4, event: 'message', data: row('turn_9:text:0', A, 4, 'rich', 'The numbers are in.') },
		{ comment: 'keep-alive 1790000000000' }
	];
	const unicode = [
		{ id: 5, event: 'message', data: row('turn_10:user', A, 5, 'ceo', 'Café naïve — 東京 🚀') },
		{ id: 6, event: 'message', data: streaming('turn_10:text:0', A, 6) },
		{ id: 6, event: 'delta', data: delta('turn_10:text:0', 6, 'Grüße 👋') }
	];
	const lag = [{ id: 7, event: 'message', data: row('turn_11:user', A, 7, 'ceo', 'ok') }, { comment: 're-snapshot 300' }];
	const interleaved = [
		{ id: 2, event: 'hello', data: hello(A, [row('turn_8:user', A, 1, 'ceo', 'where are we on the proposal?')]) },
		{ id: 3, event: 'message', data: row('turn_20:user', B, 3, 'ceo', 'post the job ad') },
		{ id: 4, event: 'message', data: streaming('turn_20:text:0', B, 4) },
		{ id: 4, event: 'delta', data: delta('turn_20:text:0', 4, 'Posted to ') },
		{ id: 5, event: 'message', data: row('turn_9:user', A, 5, 'ceo', 'and the numbers?') },
		{ id: 6, event: 'message', data: streaming('turn_9:text:0', A, 6) },
		{ id: 4, event: 'delta', data: delta('turn_20:text:0', 4, 'three boards.') },
		{ id: 6, event: 'delta', data: delta('turn_9:text:0', 6, 'The numbers are in.') },
		{ id: 4, event: 'message', data: row('turn_20:text:0', B, 4, 'rich', 'Posted to three boards.') }
	];
	const replay = [
		...turn.slice(0, 4),
		{ id: 3, event: 'message', data: row('turn_9:user', A, 3, 'ceo', 'and the numbers?') },
		{ id: 4, event: 'message', data: streaming('turn_9:text:0', A, 4) },
		...turn.slice(3)
	];
	const standIn = [
		{ id: 1, event: 'message', data: row('intake_42', A, 1, 'ceo', 'typed at the Mac') },
		{ id: 2, event: 'message', data: row('turn_30:user', A, 2, 'ceo', 'typed at the Mac') }
	];
	const deltaFirst = [
		{ id: 4, event: 'delta', data: delta('turn_9:text:0', 4, 'early ') },
		{ id: 4, event: 'message', data: row('turn_9:text:0', A, 4, 'rich', 'early and complete') }
	];

	const { createThread } = load('thread');
	const page = { messages: [row('turn_1:user', A, 1, 'ceo', 'first'), row('turn_1:text:0', A, 2, 'rich', 'first reply')], more: false };
	const backfilled = createThread().merge(row('turn_2:user', A, 3, 'ceo', 'latest')).prependOlder(page);

	return {
		source: 'mobile/platform/native.js sseParser; web/web-app/lib/api.js openEvents; web/web-app/lib/thread.js createThread',
		wire_format: 'id: <cursor>\\nevent: <hello|message|delta>\\ndata: <one line of JSON>\\n\\n; a line starting with ":" is a comment (keep-alive, re-snapshot). The reference parser delivers (event, data) and ignores id.',
		reconnect_rule: 'reconnect with since = latest cursor - 1 so at least one frame arrives; after ": re-snapshot" the socket ends: reconnect WITHOUT since (contract section 5.4)',
		wire_cases: [
			wireCase('a whole turn: hello, CEO row, streaming row, two deltas, final row, keep-alive', turn),
			wireCase('non-ASCII text split across chunks', unicode),
			wireCase('the lag notice comment', lag),
			wireCase('CRLF line endings are tolerated by the reference parser', turn.slice(1, 4), { crlf: true })
		],
		thread_cases: [
			threadCase('a whole turn: deltas append, the final row overwrites', turn),
			threadCase('two conversations interleaved on one stream: only the selected one is shown', interleaved),
			threadCase('the same frames replayed after a reconnect change nothing', replay),
			threadCase('a Mac stand-in (intake_) retires when the projected CEO row with the same text arrives', standIn),
			threadCase('a delta before its row: dropped under the filter, the final row carries the full text', deltaFirst)
		],
		hello_cases: [
			await helloCase('hello takes the challenge, keeps the paired origin and replaces capabilities', hello(A, [])),
			await helloCase('hello with no capabilities offers nothing', hello(A, [], { capabilities: undefined, build: undefined })),
			await helloCase('hello naming another origin is refused and the paired origin is kept', hello(A, [], { api_base: 'https://evil.example:8443' }))
		],
		backfill_case: {
			name: 'an older page is prepended; more:false marks the beginning',
			held: [row('turn_2:user', A, 3, 'ceo', 'latest')],
			page,
			expected_view: project(backfilled),
			at_the_beginning: backfilled.atTheBeginning()
		}
	};
}

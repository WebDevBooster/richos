// WHAT A REVIEWER SEES: fictional conversations and simulated replies, labeled as a demo.
//
// Nothing here is real. The people, companies and numbers are invented for the review. Every
// reply the review host writes starts with "Demo reply" and says what a real Mac would do
// instead, so no reviewer can mistake a canned answer for Rich. There is no AI behind it.

export const DEMO_PREFIX = 'Demo reply';

/** The conversations every review host starts with, and returns to on an explicit reset. */
export const THREADS = [
	{ id: 'thr_review_welcome', title: 'Welcome to the review demo' },
	{ id: 'thr_board_prep', title: 'Board meeting prep' },
	{ id: 'thr_hiring', title: 'Hiring a head of sales' }
];

const HOUR = 3_600_000;

const WELCOME = 'Welcome to the RichConnect review demo.\n\nThis review host stands in for a Mac running RichOS. It uses fictional conversations and writes simulated replies; there is no AI behind it. Files you attach are checked and then discarded, and the conversation is kept only on this review host.\n\nTry it: send a text message, hold the microphone to send a voice message, or attach a photo or a file. A demo reply arrives within a few seconds.';
const WITH_PUSH = ' Turn on notifications and close the app to receive the reply as a notification.';
const WITHOUT_PUSH = ' Notifications are not switched on for this review host.';

/**
 * The sample rows, oldest first, as `[thread, role, text, hoursAgo]`. The CEO rows are what a
 * person would have typed; the Rich rows are clearly sample content.
 */
const SAMPLE = [
	['thr_board_prep', 'ceo', 'Can you pull together talking points for Thursday\'s board meeting?', 50],
	['thr_board_prep', 'rich', 'Sample conversation (review demo). Here is a draft outline for Thursday:\n\n1. Third-quarter revenue: up 12% over the second quarter, led by renewals.\n2. Hiring: two of three open roles filled.\n3. Ask: approve the budget for the new support team.\n\nAll names and numbers in this demo are invented.', 49.9],
	['thr_board_prep', 'ceo', 'Move the hiring update to the end.', 30],
	['thr_board_prep', 'rich', 'Sample conversation (review demo). Done. The hiring update is now the last item, after the budget request.', 29.9],
	['thr_hiring', 'ceo', 'Where are we on the head of sales search?', 26],
	['thr_hiring', 'rich', 'Sample conversation (review demo). Three candidates are in the final round. Interviews are booked for Monday and Tuesday. The candidates in this demo are fictional.', 25.9],
	['thr_review_welcome', 'rich', WELCOME, 1]
];

/** The sample rows with ids, threads and timestamps relative to `now`. Cursors are assigned by the caller. */
export function sampleRows(now, { push = false } = {}) {
	return SAMPLE.map(([thread, role, text, hoursAgo], i) => ({
		id: role === 'ceo' ? `sample_${i + 1}:user` : `sample_${i + 1}:text:0`,
		thread_id: thread,
		role,
		kind: 'text',
		text: text === WELCOME ? text + (push ? WITH_PUSH : WITHOUT_PUSH) : text,
		created_at: new Date(now - Math.round(hoursAgo * HOUR)).toISOString(),
		client_id: null,
		has_audio: false,
		from_microphone: false,
		state: role === 'ceo' ? 'sent' : 'complete',
		complete: true
	}));
}

const quote = (text) => {
	const flat = String(text).split(/\s+/).filter(Boolean).join(' ');
	const chars = Array.from(flat);
	return chars.length > 80 ? chars.slice(0, 79).join('') + '…' : flat;
};

const seconds = (ms) => (ms / 1000).toFixed(1);

/**
 * The simulated reply to one accepted message. `what` is the message as the review host
 * recorded it: `{ kind: 'text', text }`, `{ kind: 'voice', durationMs }` or
 * `{ kind: 'attachments', text, files: [{ name, media_type, size }] }`.
 */
export function replyFor(what) {
	const tail = 'On a real Mac, Rich would answer this himself. Tap play to hear the spoken version; in this demo it is a short chime instead of a voice.';
	if (what.kind === 'voice') {
		return `${DEMO_PREFIX}: your ${seconds(what.durationMs)}-second voice message arrived. The review demo measures the recording but does not transcribe speech. ${tail}`;
	}
	if (what.kind === 'attachments') {
		const names = what.files.map((f) => `${f.name} (${f.size} bytes)`).join(', ');
		const count = what.files.length === 1 ? '1 file' : `${what.files.length} files`;
		return `${DEMO_PREFIX}: ${count} arrived: ${names}. The review demo checked ${what.files.length === 1 ? 'it' : 'them'} the way a Mac would, then discarded ${what.files.length === 1 ? 'it' : 'them'}.${what.text ? ` Your note said: “${quote(what.text)}”.` : ''} ${tail}`;
	}
	return `${DEMO_PREFIX}: your message arrived: “${quote(what.text)}”. ${tail}`;
}

/** Split a reply into the pieces the stream sends as `delta`s, about four words each. */
export function chunks(text) {
	const words = text.split(/(\s+)/);
	const out = [];
	for (let i = 0; i < words.length; i += 8) out.push(words.slice(i, i + 8).join(''));
	return out.filter((s) => s.length);
}

/** The reviewer-visible sentence for a voice note the review host received. */
export function voiceRowText(durationMs) {
	return `Voice message (${seconds(durationMs)} seconds). The review demo does not transcribe speech.`;
}

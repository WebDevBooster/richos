// attachments.json and push-registration-fcm.json: the protocol additions the native apps need.
//
// THESE AREAS ARE MAC-DEFINED. No reference client implements them, so the phone side cannot be
// "what the shipped client does". Instead:
//   * every REQUEST is built with the real `api.js` canonicalization (`signingInput`) and, where
//     `api.js` has a method (`registerNativePush`), by that method itself;
//   * every EXPECTED MAC OUTCOME is declared here, next to the case, citing the Mac code it
//     comes from (Echo's protocol additions, `65952d16`..`194fcb75`), and `verifier/` proves each
//     one against that production code: `Registration` parsing and `validate()`,
//     `AttachmentDesk::stage` and `staged`, `valid_id`, `sanitize_name`, the limits and the
//     capability list. Until those additions are in the tree, the verifier says so by name
//     instead of passing; once they are, a wrong expectation here fails.

import { makeApi, answer, transcript, signedRequest, challenge, sha256hex, b64url, DEVICE_ID } from './harness.mjs';
import { mac } from './signing.mjs';

const withMac = (request) => ({ ...request, mac: mac(request) });
const SOURCE = 'The Mac protocol additions for the native apps (echo-opus-m1: 65952d16 FCM registration, e9b0a89e delta thread_id, 22e59ed8 attachment intake, 194fcb75 capabilities, limits and protocol_version).';

// ---- the advertised surface (hello and the pairing answer) -----------------------------------

export const PROTOCOL_VERSION = 1;
// `pair-v2` is appended by every Mac from Sage's pairing review on (phone/routes.rs
// `capabilities`, phone/words.rs PAIR_V2_CAPABILITY); verifier/ holds this list to that function.
export const CAPABILITIES_FULL = ['text', 'voice', 'audio', 'native-push', 'attachments', 'native-push-fcm', 'pair-v2'];
export const ATTACHMENT_LIMITS = {
	max_file_bytes: 25 * 1024 * 1024,
	max_files_per_message: 10,
	max_message_bytes: 100 * 1024 * 1024,
	upload_seconds: 300,
	media_types: [
		'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/gif', 'image/webp', 'application/pdf',
		'text/plain', 'text/markdown', 'text/csv',
		'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
		'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
		'application/vnd.openxmlformats-officedocument.presentationml.presentation'
	]
};

// ---- FCM registration ------------------------------------------------------------------------

const fcmToken = () => `${'d'.repeat(11)}:APA91b${'x-y_z'.repeat(28)}`;
const apnsToken = 'ab'.repeat(32);
const previewKey = b64url(Buffer.alloc(32, 9));

// [name, the native_push value, accepted by the Mac, transport it records]
const REGISTRATIONS = [
	['FCM for RichConnect production', { platform: 'fcm', token: fcmToken(), topic: 'dev.richos.connect' }, true, 'fcm'],
	['APNs for RichConnect production', { token: apnsToken, environment: 'production', topic: 'dev.richos.connect' }, true, 'apns'],
	['FCM production refuses APNs environment', { platform: 'fcm', token: fcmToken(), environment: 'production', topic: 'dev.richos.connect' }, false, null],
	['APNs production refuses an FCM token', { token: fcmToken(), environment: 'production', topic: 'dev.richos.connect' }, false, null],
	['FCM, minimal', { platform: 'fcm', token: fcmToken(), topic: 'dev.richos.native.android' }, true, 'fcm'],
	['FCM with a preview key', { platform: 'fcm', token: fcmToken(), topic: 'dev.richos.native.android', preview_key: previewKey, previews: true }, true, 'fcm'],
	['FCM with previews off', { platform: 'fcm', token: fcmToken(), topic: 'dev.richos.native.android', previews: false }, true, 'fcm'],
	['FCM token of 4,096 characters (the ceiling)', { platform: 'fcm', token: 'x'.repeat(4096), topic: 'dev.richos.native.android' }, true, 'fcm'],
	['FCM token of 4,097 characters', { platform: 'fcm', token: 'x'.repeat(4097), topic: 'dev.richos.native.android' }, false, null],
	['FCM token of 31 characters', { platform: 'fcm', token: 'x'.repeat(31), topic: 'dev.richos.native.android' }, false, null],
	['FCM token with a space', { platform: 'fcm', token: fcmToken() + ' x', topic: 'dev.richos.native.android' }, false, null],
	['FCM token with a slash', { platform: 'fcm', token: fcmToken() + '/..', topic: 'dev.richos.native.android' }, false, null],
	['FCM with an environment key (FCM has no sandbox)', { platform: 'fcm', token: fcmToken(), environment: 'production', topic: 'dev.richos.native.android' }, false, null],
	['FCM under the iPhone app ID', { platform: 'fcm', token: fcmToken(), topic: 'dev.richos.native.ios' }, false, null],
	['platform spelled FCM in capitals', { platform: 'FCM', token: fcmToken(), topic: 'dev.richos.native.android' }, false, null],
	['an unknown platform', { platform: 'hms', token: fcmToken(), topic: 'dev.richos.native.android' }, false, null],
	['an unknown key (sender_id)', { platform: 'fcm', token: fcmToken(), topic: 'dev.richos.native.android', sender_id: '123' }, false, null],
	['no token', { platform: 'fcm', topic: 'dev.richos.native.android' }, false, null],
	['a preview key that is not 32 bytes', { platform: 'fcm', token: fcmToken(), topic: 'dev.richos.native.android', preview_key: 'short' }, false, null],
	['APNs, the preserved iPhone app, byte for byte as before', { token: apnsToken, environment: 'sandbox', topic: 'dev.richos.mobile.loop', preview_key: previewKey, previews: true }, true, 'apns'],
	['APNs with platform spelled out', { platform: 'apns', token: apnsToken, environment: 'production', topic: 'dev.richos.mobile.loop' }, true, 'apns'],
	['APNs for the new native iPhone app', { token: apnsToken, environment: 'sandbox', topic: 'dev.richos.native.ios' }, true, 'apns'],
	['APNs under the Android application ID', { token: apnsToken, environment: 'sandbox', topic: 'dev.richos.native.android' }, false, null],
	['APNs token in uppercase hex', { token: apnsToken.toUpperCase(), environment: 'sandbox', topic: 'dev.richos.native.ios' }, false, null]
];

async function viaApi(name, registration, reply) {
	const { api, mac: fake, signer } = makeApi({ script: [answer(200, reply, { 'Content-Type': 'application/json; charset=utf-8', 'X-RichOS-Challenge': challenge('fcm:' + name) })], state: { challenge: challenge('fcm:' + name) } });
	await api.registerNativePush(registration);
	const [request] = transcript(fake, signer);
	return { name, request: withMac(request) };
}

export async function fcm() {
	return {
		source: SOURCE,
		requires_capability: 'native-push-fcm',
		rule: 'Send the FCM shape only to a Mac whose hello (or pairing answer) lists native-push-fcm. An older Mac refuses the unknown platform key.',
		shapes: {
			fcm: '{"platform":"fcm","token":"<32..4096 of A-Z a-z 0-9 _ - :>","topic":"<Android application ID>","preview_key":"<base64url of 32 bytes>"?,"previews":bool?}',
			apns: '{"token":"<lowercase hex 32..512>","environment":"sandbox"|"production","topic":"<bundle ID>","preview_key"?,"previews"?}  (platform absent or "apns")'
		},
		allowed_ids: { fcm: ['dev.richos.native.android', 'dev.richos.connect'], apns: ['dev.richos.mobile.loop', 'dev.richos.mobile.integration', 'dev.richos.native.ios', 'dev.richos.connect'] },
		answers: [
			{ status: 200, body: '{"host_id":"<32 lowercase hex>|null","registered":bool}', client_action: 'check host_id and that registered matches what was asked; keep host_id to validate incoming notifications' },
			{ status: 404, body: '', client_action: 'the Mac refused the registration (a shape or ID it does not take, or no native-push-fcm on this Mac): do not retry the same body' },
			{ status: 503, body: '{"reason":"unreachable","retryable":true,"message":…}', client_action: 'retry later (the hosted service could not be reached, or the phone is not confirmed)' },
			{ status: 422, body: '{"reason":"unsupported","retryable":false}', client_action: 'final: this Mac offers no native push' }
		],
		registration_cases: REGISTRATIONS.map(([name, native_push, accepted, transport]) => ({ name, native_push, mac_outcome: accepted ? { accepted: true, transport } : { accepted: false } })),
		requests: [
			await viaApi('register FCM (api.js registerNativePush)', REGISTRATIONS[1][1], { host_id: '5de0dbe0862dd461ae305af5cef35202', registered: true }),
			await viaApi('unregister (api.js registerNativePush with null)', null, { host_id: '5de0dbe0862dd461ae305af5cef35202', registered: false }),
			{
				name: 'the Android app confirms the six words and names FCM as its push service',
				request: withMac(signedRequest({ method: 'POST', path: '/api/pair', body: JSON.stringify({ device_id: DEVICE_ID, fingerprint_confirmed: true, push_transport: 'fcm' }), contentType: 'application/json', label: 'fcm:confirm' }))
			}
		],
		push_transport_on_confirmation: 'The Android app sends push_transport "fcm" with fingerprint_confirmed true. The shipped web client sends "apns" for every native client (api.js confirmFingerprint); an Android app must not copy that.'
	};
}

// ---- attachments -----------------------------------------------------------------------------

const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10]), Buffer.from('JFIF\0conformance jpeg bytes')]);
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from('conformance png bytes')]);
const PDF = Buffer.from('%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n');
const HEIC = Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypheic'), Buffer.from([0, 0, 0, 0]), Buffer.from('mif1heic')]);
const DOCX = Buffer.concat([Buffer.from('PK\x03\x04', 'latin1'), Buffer.from('conformance docx container')]);
const TEXT = Buffer.from('Buy milk\nCall Sam about the proposal\n');

function upload(label, client, id, name, mediaType, bytes, expected) {
	const query = { kind: 'attachment', client_id: client, attachment_id: id };
	if (name !== null) query.name = name;
	const request = withMac(signedRequest({ method: 'POST', path: '/api/messages', query, body: bytes, contentType: mediaType, label: 'attach:' + label }));
	const ok = expected.outcome === 'stored' || expected.outcome === 'duplicate';
	return {
		name: label,
		request,
		mac_outcome: {
			...expected,
			status: ok ? 200 : { conflict: 409, refused: 422, limit: 422 }[expected.outcome],
			...(ok ? { answer: { attachment_id: id, name: expected.stored_name, media_type: expected.media_type, size: bytes.length, sha256: sha256hex(bytes), duplicate: expected.outcome === 'duplicate' } } : {})
		}
	};
}

function commit(label, client, text, files, expected) {
	const body = JSON.stringify({ client_id: client, thread_id: 'thr_5c1e', kind: 'attachments', text, attachments: files.map(([id, bytes]) => ({ id, sha256: sha256hex(bytes) })), sent_at: '2026-09-22T13:05:00.000Z' });
	return { name: label, request: withMac(signedRequest({ method: "POST", path: "/api/messages", body, contentType: "application/json", label: "commit:" + label })), mac_outcome: expected };
}

export function attachments() {
	const stored = (name, type) => ({ outcome: 'stored', stored_name: name, media_type: type });
	const uploads = [
		upload('a JPEG photo; the extension is lowercased', 'msg-photos', 'p1', 'IMG_0001.JPG', 'image/jpeg', JPEG, stored('IMG_0001.jpg', 'image/jpeg')),
		upload('a PNG screenshot keeps its name', 'msg-photos', 'p2', 'Screen Shot 2026-09-22 at 10.00.00.png', 'image/png', PNG, stored('Screen Shot 2026-09-22 at 10.00.00.png', 'image/png')),
		upload('a HEIC photo', 'msg-photos', 'p3', 'IMG_0002.HEIC', 'image/heic', HEIC, stored('IMG_0002.heic', 'image/heic')),
		upload('the same bytes again under the same ID: duplicate, nothing new stored', 'msg-photos', 'p1', 'IMG_0001.JPG', 'image/jpeg', JPEG, { outcome: 'duplicate', stored_name: 'IMG_0001.jpg', media_type: 'image/jpeg' }),
		upload('different bytes under an ID already used: conflict', 'msg-photos', 'p1', 'IMG_0001.JPG', 'image/jpeg', Buffer.concat([JPEG, Buffer.from('changed')]), { outcome: 'conflict' }),
		upload('a PDF', 'msg-files', 'f1', 'Q3 report.pdf', 'application/pdf', PDF, stored('Q3 report.pdf', 'application/pdf')),
		upload('a text note with no extension gets .txt', 'msg-files', 'f2', 'notes', 'text/plain', TEXT, stored('notes.txt', 'text/plain')),
		upload('a media type with parameters', 'msg-files', 'f3', 'list.csv', 'text/csv; charset=utf-8', Buffer.from('a,b\n1,2\n'), stored('list.csv', 'text/csv')),
		upload('a path in the name is cut to its last component', 'msg-files', 'f4', '../../etc/plan.md', 'text/markdown', Buffer.from('# Plan\n'), stored('plan.md', 'text/markdown')),
		upload('a Word document (ZIP container)', 'msg-files', 'f5', 'Contract.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', DOCX, stored('Contract.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document')),
		upload('no name at all', 'msg-files', 'f6', null, 'image/png', PNG, stored('attachment.png', 'image/png')),
		upload('a PNG sent as image/jpeg is refused', 'msg-refused', 'r1', 'photo.jpg', 'image/jpeg', PNG, { outcome: 'refused' }),
		upload('text containing a NUL byte is refused', 'msg-refused', 'r2', 'notes.txt', 'text/plain', Buffer.from('a\0b'), { outcome: 'refused' }),
		upload('a ZIP archive is a type the Mac does not take', 'msg-refused', 'r3', 'photos.zip', 'application/zip', DOCX, { outcome: 'refused' }),
		upload('an empty file is refused (signed with an EMPTY fourth line, as every bodiless request)','msg-refused', 'r4', 'empty.txt', 'text/plain', Buffer.alloc(0), { outcome: 'refused' })
	];
	const many = [];
	for (let i = 1; i <= 11; i++) {
		const bytes = Buffer.from(`file ${i}\n`);
		many.push(upload(`message with many files: file ${i}${i === 11 ? ' is one more than a message can carry' : ''}`, 'msg-many', `m${i}`, `f${i}.txt`, 'text/plain', bytes, i === 11 ? { outcome: 'limit' } : stored(`f${i}.txt`, 'text/plain')));
	}
	const commits = [
		commit('commit two uploaded files with text', 'msg-files', 'Here are the files', [['f1', PDF], ['f2', TEXT]], { all_present: true, files: [{ id: 'f1', name: 'Q3 report.pdf' }, { id: 'f2', name: 'notes.txt' }] }),
		commit('commit naming a file that was never uploaded', 'msg-files', null, [['f1', PDF], ['never', TEXT]], { all_present: false, missing: ['never'] }),
		commit('commit naming a file with the wrong SHA-256', 'msg-files', null, [['f2', PDF]], { all_present: false, missing: ['f2'] })
	];
	const ids = [['p1', true], ['IMG-0001_a', true], ['x'.repeat(128), true], ['x'.repeat(129), false], ['', false], ['a b', false], ['a/b', false], ['a.b', false], ['a:b', false], ['ü', false]];
	return {
		source: SOURCE,
		requires_capability: 'attachments',
		limits: ATTACHMENT_LIMITS,
		limits_rule: 'Read the limits from attachment_limits in hello or the pairing answer; never hard-code them. Refuse a file on the phone before uploading it when it breaks one.',
		upload_route: 'POST /api/messages?kind=attachment&client_id=<the message client_id>&attachment_id=<id>[&name=<percent-encoded file name>], Content-Type: the file media type, body: the raw bytes. One file per request; signed like every request.',
		commit_route: 'POST /api/messages with {"client_id","thread_id","kind":"attachments","text"?,"attachments":[{"id","sha256"}],"sent_at"}. Only the 200 answer to THIS request means the Mac accepted the message.',
		answers: [
			{ route: 'upload', status: 200, body: '{"attachment_id","name","media_type","size","sha256","duplicate"}', client_action: 'the file is held on the Mac; the message is NOT delivered until its commit is answered 200' },
			{ route: 'upload', status: 409, body: '{"accepted":false,"retry":false,"reason"}', client_action: 'final for this file: that ID already holds different bytes' },
			{ route: 'upload', status: 422, body: '{"accepted":false,"retry":false,"reason"}', client_action: 'final for this file: its type, content, emptiness, count or size is refused; show the reason' },
			{ route: 'upload', status: 413, body: '', client_action: 'final for this file: over the per-file limit' },
			{ route: 'upload', status: 503, body: '{"accepted":false,"retry":true,"reason"}', client_action: 'retry the same bytes later' },
			{ route: 'commit', status: 200, body: '{"message_id","cursor","thread_id","accepted_at","attachments":[{"id","name","media_type","size"}],"duplicate"}', client_action: 'delivered' },
			{ route: 'commit', status: 422, body: '{"accepted":false,"retry":true,"missing":[ids],"reason"}', client_action: 'upload the missing files, then resend the SAME commit bytes (nothing was reserved)' },
			{ route: 'commit', status: 409, body: '{"accepted":false,"retry":false,"reason"}', client_action: 'final for this message: client_id reused with different bytes' },
			{ route: 'commit', status: 503, body: '{"accepted":false,"retry":false,"reason"}', client_action: 'final for this message: ask the person to check the conversation' }
		],
		attachment_id_cases: ids.map(([id, valid]) => ({ id, mac_outcome: { valid } })),
		upload_cases: uploads,
		limit_sequence: many,
		commit_cases: commits
	};
}

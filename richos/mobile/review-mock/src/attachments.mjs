// PHOTOS AND FILES, checked the way the Mac checks them — and then NOT kept.
//
// A port of `phone/attachments.rs` (the accepted kinds, the content sniffing, `sanitize_name`,
// `valid_id`, `describe`). The review host verifies every upload exactly as a Mac would, records
// its name, type, size and SHA-256, and discards the bytes: nothing a reviewer sends is stored.
// `test/conformance.test.mjs` replays `vectors/attachments.json` through these functions.

export const ACCEPTED = [
	{ media_type: 'image/jpeg', extension: 'jpg', extensions: ['jpg', 'jpeg'], label: 'JPEG photo', sniff: 'jpeg' },
	{ media_type: 'image/png', extension: 'png', extensions: ['png'], label: 'PNG image', sniff: 'png' },
	{ media_type: 'image/heic', extension: 'heic', extensions: ['heic', 'heif'], label: 'HEIC photo', sniff: 'heif' },
	{ media_type: 'image/heif', extension: 'heif', extensions: ['heif', 'heic'], label: 'HEIF photo', sniff: 'heif' },
	{ media_type: 'image/gif', extension: 'gif', extensions: ['gif'], label: 'GIF image', sniff: 'gif' },
	{ media_type: 'image/webp', extension: 'webp', extensions: ['webp'], label: 'WebP image', sniff: 'webp' },
	{ media_type: 'application/pdf', extension: 'pdf', extensions: ['pdf'], label: 'PDF', sniff: 'pdf' },
	{ media_type: 'text/plain', extension: 'txt', extensions: ['txt', 'text', 'log'], label: 'text file', sniff: 'text' },
	{ media_type: 'text/markdown', extension: 'md', extensions: ['md', 'markdown'], label: 'Markdown file', sniff: 'text' },
	{ media_type: 'text/csv', extension: 'csv', extensions: ['csv'], label: 'CSV file', sniff: 'text' },
	{ media_type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', extension: 'docx', extensions: ['docx'], label: 'Word document', sniff: 'zip' },
	{ media_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', extension: 'xlsx', extensions: ['xlsx'], label: 'Excel workbook', sniff: 'zip' },
	{ media_type: 'application/vnd.openxmlformats-officedocument.presentationml.presentation', extension: 'pptx', extensions: ['pptx'], label: 'PowerPoint presentation', sniff: 'zip' }
];

/** `attachments.rs` kind_of: the media type without parameters, lowercased, if accepted. */
export function kindOf(contentType) {
	const bare = String(contentType || '').split(';')[0].trim().toLowerCase();
	return ACCEPTED.find((k) => k.media_type === bare) || null;
}

const startsWith = (bytes, prefix) => prefix.length <= bytes.length && prefix.every((b, i) => bytes[i] === b);
const ascii = (s) => Array.from(s, (c) => c.charCodeAt(0));
const at = (bytes, from, to) => String.fromCharCode(...bytes.subarray(from, to));
const HEIF_BRANDS = ['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1', 'heif'];

function isUtf8(bytes) {
	try { new TextDecoder('utf-8', { fatal: true }).decode(bytes); return true; } catch { return false; }
}

/** `attachments.rs` content_matches. */
export function contentMatches(kind, bytes) {
	switch (kind.sniff) {
	case 'jpeg': return startsWith(bytes, [0xff, 0xd8, 0xff]);
	case 'png': return startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
	case 'gif': return startsWith(bytes, ascii('GIF87a')) || startsWith(bytes, ascii('GIF89a'));
	case 'webp': return bytes.length >= 12 && at(bytes, 0, 4) === 'RIFF' && at(bytes, 8, 12) === 'WEBP';
	case 'heif': return bytes.length >= 12 && at(bytes, 4, 8) === 'ftyp' && HEIF_BRANDS.includes(at(bytes, 8, 12));
	case 'pdf': return startsWith(bytes, ascii('%PDF-'));
	case 'text': return !bytes.includes(0) && isUtf8(bytes);
	case 'zip': return startsWith(bytes, [0x50, 0x4b, 0x03, 0x04]);
	default: return false;
	}
}

const isBidiControl = (c) => /[‎‏‪-‮⁦-⁩]/.test(c);
// Rust's `char::is_control` is the Unicode Cc category.
const isControl = (c) => /\p{Cc}/u.test(c);

/** Truncate to at most `max` UTF-8 bytes on a character boundary. */
function truncateBytes(text, max) {
	const encoder = new TextEncoder();
	if (encoder.encode(text).length <= max) return text;
	let out = '';
	for (const ch of text) {
		if (encoder.encode(out + ch).length > max) break;
		out += ch;
	}
	return out;
}

const trimStartDots = (s) => s.replace(/^\.+/, '');
const trimEndDots = (s) => s.replace(/\.+$/, '');

/** `attachments.rs` sanitize_name. */
export function sanitizeName(raw, kind) {
	const last = String(raw).split(/[/\\:]/).pop() || '';
	const cleaned = trimStartDots(Array.from(last).filter((c) => !isControl(c) && !isBidiControl(c)).join('').trim()).trim();
	let stem, extension;
	const dot = cleaned.lastIndexOf('.');
	if (dot !== -1 && kind.extensions.includes(cleaned.slice(dot + 1).toLowerCase())) {
		stem = cleaned.slice(0, dot);
		extension = cleaned.slice(dot + 1).toLowerCase();
	} else {
		stem = cleaned;
		extension = kind.extension;
	}
	stem = truncateBytes(trimEndDots(stem.trim()).trim(), 100).trim();
	if (!stem) stem = 'attachment';
	return `${stem}.${extension}`;
}

/** `attachments.rs` valid_id: 1 to 128 of `A-Z a-z 0-9 _ -`. */
export function validId(id) {
	return typeof id === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(id);
}

/** Rename collisions within one message the way `AttachmentDesk::commit` does: "name (2).ext". */
export function uniqueNames(files) {
	const taken = [];
	return files.map((file) => {
		const dot = file.name.lastIndexOf('.');
		const stem = dot === -1 ? file.name : file.name.slice(0, dot);
		const ext = dot === -1 ? '' : file.name.slice(dot + 1);
		let name = file.name;
		for (let n = 2; taken.includes(name.toLowerCase()); n++) name = `${stem} (${n}).${ext}`;
		taken.push(name.toLowerCase());
		return { ...file, name };
	});
}

/**
 * The CEO row text for a message with files. The Mac's `describe` lists the saved paths on the
 * Mac; the review host says plainly that it kept nothing.
 */
export function describe(text, files) {
	const count = files.length === 1 ? '1 file' : `${files.length} files`;
	const lines = [];
	if (text) lines.push(text, '');
	lines.push(`Attached from the phone (${count}; the review demo checked ${files.length === 1 ? 'it' : 'them'} and did not keep ${files.length === 1 ? 'it' : 'them'}):`);
	for (const f of files) lines.push(`- ${f.name} (${f.media_type}, ${f.size} bytes)`);
	return lines.join('\n');
}

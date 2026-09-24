// The QR code and the six words on the access page — both from modules that already exist, read
// only, so nothing here is a second implementation to be wrong in a second way:
//
//   * `richos/app/ui/qr.js` is the Mac's own pairing-screen QR encoder (itself a checked port of
//     `tools/phone-probe/lib/qr.js`, verified against ISO/IEC 18004 and decoded with Apple Vision).
//   * `richos/web/web-app/lib/fingerprint.js` (with its 256-word list) is the phone's own rendering
//     of a fingerprint. The words on the access page come from the same function over the same
//     value the pairing answer carries, so they are the words the reviewer's phone will show.

import qr from '../../../app/ui/qr.js';
import fingerprint from '../../../web/web-app/lib/fingerprint.js';

/**
 * An SVG of `text` as a QR code: dark modules on a white field with the four-module quiet zone
 * the standard requires. Always dark on light, whatever the page theme, because that is what a
 * phone camera reads.
 */
export function qrSvg(text, { moduleSize = 6 } = {}) {
	const { size, modules } = qr.encode(text);
	const quiet = 4, full = (size + quiet * 2) * moduleSize;
	let path = '';
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			if (modules[y][x]) path += `M${(x + quiet) * moduleSize} ${(y + quiet) * moduleSize}h${moduleSize}v${moduleSize}h-${moduleSize}z`;
		}
	}
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${full} ${full}" width="${full}" height="${full}" role="img" aria-label="QR code for the pairing link" shape-rendering="crispEdges"><rect width="${full}" height="${full}" fill="#ffffff"/><path fill="#000000" d="${path}"/></svg>`;
}

/**
 * The six words for a fingerprint (`web/web-app/lib/fingerprint.js`: the first six bytes of the
 * hash index the word list).
 */
export function sixWords(fingerprintHex) {
	return fingerprint.wordsFromHex(fingerprintHex);
}

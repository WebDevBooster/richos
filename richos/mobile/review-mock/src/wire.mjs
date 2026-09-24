// What a review host advertises, in the Mac's shapes (`phone/routes.rs` capabilities and
// attachment_limits). `test/conformance.test.mjs` compares both with the corpus.

import { ACCEPTED } from './attachments.mjs';
import { MAX_FILE_BYTES, MAX_FILES_PER_MESSAGE, MAX_MESSAGE_BYTES, UPLOAD_SECONDS } from './limits.mjs';

/** `routes.rs` CAPABILITIES: the long-standing entry every Mac sends first. */
export const CAPABILITIES_BASE = ['text'];

/** `routes.rs` attachment_limits. */
export const ATTACHMENT_LIMITS_WIRE = Object.freeze({
	max_file_bytes: MAX_FILE_BYTES,
	max_files_per_message: MAX_FILES_PER_MESSAGE,
	max_message_bytes: MAX_MESSAGE_BYTES,
	upload_seconds: UPLOAD_SECONDS,
	media_types: ACCEPTED.map((k) => k.media_type)
});

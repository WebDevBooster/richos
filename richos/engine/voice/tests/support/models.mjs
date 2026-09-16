import fs from 'node:fs';
import crypto from 'node:crypto';
import { GGML_MAGIC_HEX } from '../../provisioning/model-catalog.js';

export const GGML = Buffer.from(GGML_MAGIC_HEX, 'hex');

/** A stand-in model: real magic, real hash, 4 KB instead of 574 MB. */
export function fakeModel(seed = 'norm', bytes = 4096) {
  const filler = crypto.createHash('sha512').update(seed).digest();
  const body = Buffer.concat([GGML, Buffer.alloc(bytes - 4)]);
  for (let i = 4; i < bytes; i += 1) body[i] = filler[i % filler.length];
  return body;
}
export function pinOf(body, id = 'test.model') {
  return {
    id,
    file: `ggml-${id}.bin`,
    bytes: body.length,
    sha256: crypto.createHash('sha256').update(body).digest('hex'),
    provenance: ['test'],
    witness: '',
    note: 'synthetic',
  };
}

/** A file of the pinned SIZE without the pinned bytes on disk — sparse, so 487 MB costs nothing. */
export function sparseModel(filePath, bytes, magic = GGML) {
  fs.writeFileSync(filePath, magic);
  fs.truncateSync(filePath, bytes);
}

export const CAPTIVE_PORTAL = Buffer.from(
  '<!DOCTYPE html>\n<html><head><title>Hotel Wi-Fi — Sign in</title>\n' +
    '<meta http-equiv="refresh" content="0;url=/portal/login">\n</head>\n' +
    '<body>Please accept the terms to continue.</body></html>\n',
);
// A portal stub with no doctype and no <html> element at all — what a cheap gateway actually emits.
export const PORTAL_STUB = Buffer.from('<meta http-equiv="refresh" content="0; url=https://wifi.example/login">\n');

/** Capture writes stay in one real session directory outside the product checkout. */
import fs from 'node:fs';
import path from 'node:path';
import { assertEvidenceOutsideProductRepo } from './workspace/privacy.js';

function component(value) {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9]/.test(value)
    || /[<>:"/\\|?*\u0000-\u001f]/.test(value) || /[. ]$/.test(value)) {
    throw new Error('capture boundary: expected a single portable path component');
  }
  return value;
}

export function audioExtension(value) {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9]{1,16}$/.test(value)) {
    throw new Error('capture boundary: invalid audio extension');
  }
  return value;
}

export function sessionDirectory(zone, sessionId) {
  component(sessionId);
  const root = fs.realpathSync.native(assertEvidenceOutsideProductRepo(zone));
  const dir = path.join(root, sessionId);
  const entry = fs.lstatSync(dir, { throwIfNoEntry: false });
  if (entry && (!entry.isDirectory() || entry.isSymbolicLink())) {
    throw new Error('capture boundary: session directory must not be a link');
  }
  if (entry && path.dirname(fs.realpathSync.native(dir)) !== root) {
    throw new Error('capture boundary: session directory escapes the drop zone');
  }
  assertEvidenceOutsideProductRepo(dir);
  return dir;
}

export function sessionFile(zone, sessionId, name) {
  const file = path.join(sessionDirectory(zone, sessionId), component(name));
  const entry = fs.lstatSync(file, { throwIfNoEntry: false });
  if (entry && (!entry.isFile() || entry.isSymbolicLink() || entry.nlink !== 1)) {
    throw new Error('capture boundary: output must be a regular unlinked file');
  }
  return file;
}

export function writeSessionFile(zone, sessionId, name, data, append = false) {
  const file = sessionFile(zone, sessionId, name);
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | (fs.constants.O_NOFOLLOW || 0)
    | (append ? fs.constants.O_APPEND : 0);
  const fd = fs.openSync(file, flags, 0o600);
  try {
    const entry = fs.fstatSync(fd);
    if (!entry.isFile() || entry.nlink !== 1) {
      throw new Error('capture boundary: output must be a regular unlinked file');
    }
    // Validate the opened file before truncating an existing recording or record.
    if (!append) fs.ftruncateSync(fd, 0);
    fs.writeFileSync(fd, data);
  } finally {
    fs.closeSync(fd);
  }
}

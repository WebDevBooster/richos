import fs from 'node:fs';
import { privateFile } from './private-files.js';

/** Keep damaged bytes, but never join an accepted JSON record to a torn tail. */
export function appendJsonLine(file, record) {
  const line = Buffer.from(`${JSON.stringify(record)}\n`);
  const target = privateFile(file);
  const fd = fs.openSync(target, fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_APPEND
    | (fs.constants.O_NOFOLLOW || 0), 0o600);
  try {
    const entry = fs.fstatSync(fd);
    if (!entry.isFile() || entry.nlink !== 1) {
      throw new Error('storage boundary: log must be a regular unlinked file');
    }
    const tail = Buffer.alloc(1);
    const separate = entry.size > 0 && fs.readSync(fd, tail, 0, 1, entry.size - 1) === 1
      && tail[0] !== 10;
    fs.writeFileSync(fd, separate ? Buffer.concat([Buffer.from('\n'), line]) : line);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

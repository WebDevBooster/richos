// Loro write boundary. Compiler modules remain read-only.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { productCheckoutContaining } from '../lib/layout.js';

function refuse(message) {
  const error = new Error(`loro write: ${message}`);
  error.code = 5;
  throw error;
}

// The selected root may itself be a safe alias. No descendant may redirect a
// write, including dangling links and multiply linked regular files.
export function assertWritePath(corpusRoot, file, kind = 'file') {
  const root = path.resolve(corpusRoot.root);
  const target = path.resolve(file);
  const relative = path.relative(root, target);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    refuse(`refusing to write outside the corpus: ${target}`);
  }
  const physicalRoot = fs.realpathSync.native(root);
  if (!fs.statSync(physicalRoot).isDirectory()) refuse('the corpus is not a directory');
  let current = physicalRoot;
  const parts = relative.split(path.sep);
  for (let i = 0; i < parts.length; i += 1) {
    current = path.join(current, parts[i]);
    const stat = fs.lstatSync(current, { throwIfNoEntry: false });
    if (!stat) break;
    if (stat.isSymbolicLink()) refuse(`linked output path is not allowed: ${target}`);
    const directory = i < parts.length - 1 || kind === 'directory';
    if (directory ? !stat.isDirectory() : !stat.isFile() || stat.nlink !== 1) {
      refuse(`output must be an ordinary ${directory ? 'directory' : 'single-link file'}: ${target}`);
    }
    // An explicitly external corpus cannot hide product code beneath its root.
    if (corpusRoot.layout === 'corpus' && stat.isDirectory() && productCheckoutContaining(current)) {
      refuse(`output is inside the RichOS product repo: ${target}`);
    }
  }
  if (corpusRoot.layout === 'corpus' && productCheckoutContaining(physicalRoot)) {
    refuse(`output is inside the RichOS product repo: ${target}`);
  }
  return target;
}

export function makeWriteDirectory(corpusRoot, directory) {
  assertWritePath(corpusRoot, directory, 'directory');
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  assertWritePath(corpusRoot, directory, 'directory');
}

export function writePrivateFile(corpusRoot, file, text, { createOnly = false } = {}) {
  const target = assertWritePath(corpusRoot, file);
  makeWriteDirectory(corpusRoot, path.dirname(target));
  assertWritePath(corpusRoot, target);
  const temporary = path.join(path.dirname(target), `.loro-${randomUUID()}.incoming`);
  try {
    const fd = fs.openSync(temporary, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
    try {
      fs.writeFileSync(fd, text, 'utf8');
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    assertWritePath(corpusRoot, target);
    if (createOnly) {
      // Publishing a new record must never replace a concurrent writer's file.
      fs.linkSync(temporary, target);
      fs.unlinkSync(temporary);
    } else {
      fs.renameSync(temporary, target);
    }
    const directory = fs.openSync(path.dirname(target), fs.constants.O_RDONLY);
    try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

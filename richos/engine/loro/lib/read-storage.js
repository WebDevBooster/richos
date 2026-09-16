// Read paths determine audience and company scope. Only the selected corpus
// root may be an alias; descendants must not borrow another source's identity.
import fs from 'node:fs';
import path from 'node:path';

export function assertReadPath(root, target, kind = 'file') {
  const relative = path.relative(path.resolve(root), path.resolve(target));
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`loro read: source escapes the corpus: ${target}`);
  }
  if (!fs.existsSync(root)) return false;
  let current = fs.realpathSync.native(root);
  const parts = relative.split(path.sep).filter(Boolean);
  for (let i = 0; i < parts.length; i += 1) {
    current = path.join(current, parts[i]);
    const entry = fs.lstatSync(current, { throwIfNoEntry: false });
    if (!entry) return false;
    if (entry.isSymbolicLink()) throw new Error(`loro read: linked source path is not allowed: ${target}`);
    const directory = i < parts.length - 1 || kind === 'directory';
    if (directory ? !entry.isDirectory() : !entry.isFile() || entry.nlink !== 1) {
      throw new Error(`loro read: source must be an ordinary ${directory ? 'directory' : 'single-link file'}: ${target}`);
    }
  }
  return true;
}

export function readSource(root, file) {
  assertReadPath(root, file);
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const entry = fs.fstatSync(fd);
    if (!entry.isFile() || entry.nlink !== 1) throw new Error(`loro read: source must be a single-link file: ${file}`);
    return fs.readFileSync(fd, 'utf8');
  } finally {
    fs.closeSync(fd);
  }
}

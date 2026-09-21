// Suite-owned storage. Never depend on the operator's shell TMPDIR.
const fs = require('node:fs');
const { join, dirname, resolve } = require('node:path');
const volume = '/Volumes/E1TB';
class StorageUnavailable extends Error {}
function createScratch(label) {
  if (!fs.existsSync(volume) || fs.statSync(volume).dev === fs.statSync(dirname(volume)).dev) {
    throw new StorageUnavailable('mount /Volumes/E1TB for test storage');
  }
  const configured = process.env.TMPDIR && resolve(process.env.TMPDIR);
  const base = configured?.startsWith(volume + '/') ? configured : join(volume, 'tmp/codex');
  fs.mkdirSync(base, { recursive: true });
  if (!fs.realpathSync(base).startsWith(fs.realpathSync(volume) + '/')) throw new Error('Suite scratch must resolve onto /Volumes/E1TB');
  return fs.mkdtempSync(join(base, `richos-mobile-${label}-`));
}
function proofCache(base, storage, override) {
  if (!['system', 'external'].includes(storage)) throw new Error('Simulator storage must be system or external');
  if (override) return override; // Explicit paths remain subject to the CLI's policy checks.
  const policy = join(base, 'simulator-storage.json');
  // Reuse matching earlier caches. Never rewrite a saved choice or reuse a failed
  // external device set when the suite now requests the approved system storage.
  if (fs.existsSync(policy) && JSON.parse(fs.readFileSync(policy, 'utf8')).storage === storage) return base;
  return `${base}-${storage}`;
}
module.exports = { createScratch, proofCache, StorageUnavailable };

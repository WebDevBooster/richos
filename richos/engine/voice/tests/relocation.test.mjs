import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test, tmp, finish } from './support/harness.mjs';

const voice = path.resolve(import.meta.dirname, '..');
const product = path.resolve(voice, '../..');
const scratch = path.join(tmp(), 'release with spaces');
const copied = path.join(scratch, 'engine/voice');
const filter = (file) => !['.git', 'node_modules', 'target', '.DS_Store', '.build'].includes(path.basename(file));
fs.cpSync(voice, copied, { recursive: true, filter });
const run = (args, extra = {}) => spawnSync(process.execPath, args, { cwd: os.tmpdir(), encoding: 'utf8', timeout: 60000, ...extra });
const good = (result) => assert.equal(result.status, 0, (result.stdout || '') + (result.stderr || ''));

test('engine-only copy runs its own core suites from an unrelated directory', () => {
  good(run([path.join(copied, 'tests/run.mjs')]));
  assert.equal(JSON.parse(fs.readFileSync(path.join(copied, 'package.json'))).type, 'module');
  assert.equal(fs.existsSync(path.join(scratch, 'tools')), false);
});

test('copied service and HUD use the release-local voice component', () => {
  // Copy only the existing tool dependency closure, not the app, private repos or source checkout.
  for (const name of ['richos-service', 'richos-hud', 'richos-extension']) {
    fs.cpSync(path.join(product, 'tools', name), path.join(scratch, 'tools', name), { recursive: true, filter });
  }
  good(run([path.join(copied, 'tests/consumers.test.mjs'), '--without-rust']));
  const cli = path.join(scratch, 'tools/richos-service/bin/richos-service.js');
  const models = run([cli, 'models', '--dir', path.join(scratch, 'empty-models')]);
  good(models);
  assert.match(models.stdout, /small.en/);
});

test('missing canonical pins cannot fall back to the original checkout or legacy JSON', () => {
  const pin = path.join(copied, 'models/model-pins.json');
  fs.renameSync(pin, pin + '.held');
  try {
    const result = run([path.join(scratch, 'tools/richos-service/bin/richos-service.js'), 'models']);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /ENOENT/);
    assert.ok(result.stderr.includes(pin));
    const shell = spawnSync('/bin/bash', [path.join(scratch, 'tools/richos-hud/fetch-dictation-models.sh'), '--print-pins'], { cwd: os.tmpdir(), encoding: 'utf8' });
    assert.notEqual(shell.status, 0);
  } finally { fs.renameSync(pin + '.held', pin); }
});

test('missing canonical costs fails in the actual service reader', () => {
  const file = path.join(copied, 'models/model-costs.json');
  fs.renameSync(file, file + '.held');
  try {
    const result = run(['--input-type=module', '-e', `import {loadCosts} from ${JSON.stringify(new URL('file://' + path.join(scratch, 'tools/richos-service/lib/hardware.js')).href)}; loadCosts();`]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /model-costs.json/);
  } finally { fs.renameSync(file + '.held', file); }
});
await finish();

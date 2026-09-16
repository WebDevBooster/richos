// Repository integration: requires sibling tools and app, unlike the component core suite.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { test, testAsync, tmp, finish } from './support/harness.mjs';
import { MODEL_PINS, PIN_FILE, TOOLCHAIN_REFERENCE } from '../provisioning/model-catalog.js';
import { loadCosts } from '../../../tools/richos-service/lib/hardware.js';

const product = path.resolve(import.meta.dirname, '../../..');
const service = path.join(product, 'tools/richos-service');

test('the shell fetcher and the service read the SAME pin table, field for field', () => {
  const script = path.join(product, 'tools/richos-hud/fetch-dictation-models.sh');
  const out = execFileSync('/bin/bash', [script, '--print-pins'], { cwd: os.tmpdir(), encoding: 'utf8', env: { ...process.env, PATH: '/usr/bin:/bin' } });
  const fromShell = out.trim().split('\n').map((l) => l.split('\t'));
  const fromJs = MODEL_PINS.map((m) => [m.id, m.file, String(m.bytes), m.sha256]);
  assert.deepEqual(fromShell, fromJs, 'the shell parser and the service disagree about the pin table');
});

testAsync('legacy JavaScript imports share canonical exports and object identity', async () => {
  for (const name of ['model-catalog', 'model-integrity', 'model-fetch']) {
    const canonical = await import(`../provisioning/${name}.js`);
    const legacy = await import(pathToFileURL(path.join(service, `lib/${name}.js`)));
    assert.deepEqual(Object.keys(legacy), Object.keys(canonical));
    for (const key of Object.keys(canonical)) assert.equal(legacy[key], canonical[key], `${name}.${key}`);
  }
  assert.equal(fs.realpathSync(PIN_FILE), fs.realpathSync(path.join(product, 'engine/voice/models/model-pins.json')));
});

test('service cost reader uses canonical defaults and preserves file injection', () => {
  const original = loadCosts();
  const file = path.join(tmp(), 'costs.json');
  const custom = JSON.parse(fs.readFileSync(path.join(product, 'engine/voice/models/model-costs.json')));
  custom.safeRung.value = 'fixture-model';
  fs.writeFileSync(file, JSON.stringify(custom));
  assert.equal(loadCosts(file).safeRung, 'fixture-model');
  assert.notEqual(original.safeRung, 'fixture-model');
});

if (!process.argv.includes('--without-rust')) {
  test('compiled Rust readers agree with the JavaScript metadata consumers', () => {
    // No independent JSON inclusion: this invokes Costs::load and pinned_sha256 in the crate.
    const output = execFileSync(process.env.CARGO || 'cargo', ['run', '--quiet', '--locked', '-p', 'richos-voice', '--example', 'model_metadata'], {
      cwd: path.join(product, 'app'), encoding: 'utf8', timeout: 300000,
    });
    const rust = JSON.parse(output);
    const js = loadCosts();
    assert.deepEqual(rust.models.map((m) => m.id).sort(), [...js.models.keys()].sort());
    for (const model of rust.models) {
      const cost = js.models.get(model.id);
      assert.equal(model.sha256, MODEL_PINS.find((p) => p.id === model.id)?.sha256 ?? null);
      for (const field of ['utterancePeakRssBytes', 'referenceUtteranceSeconds', 'longFormSecondsPerAudioSecond', 'longFormPeakRssBytes']) {
        assert.equal(model[field], cost[field] ?? null, `${model.id}.${field}`);
      }
    }
    for (const field of ['liveLadder', 'batchLadder', 'safeRung', 'liveCeilingSeconds', 'batchRealTimeMultiple']) assert.deepEqual(rust[field], js[field], field);
    const raw = JSON.parse(fs.readFileSync(path.join(product, 'engine/voice/models/model-costs.json')));
    assert.equal(rust.liveTargetSeconds, raw.liveUtteranceCeilingSeconds.targetSeconds);
    assert.equal(rust.referenceVersion, TOOLCHAIN_REFERENCE.whisperCppVersion);
  });
} else {
  console.log('NOT RUN: Rust conformance (run npm run test:consumers with Cargo for the full check)');
}
await finish();

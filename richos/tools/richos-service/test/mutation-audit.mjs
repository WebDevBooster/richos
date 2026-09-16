// Retained aggregate command: component audit followed by service/HUD consumer audit.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { audit, testNames } from '../../../engine/voice/tests/support/mutation-runner.mjs';
const product = path.resolve(import.meta.dirname, '../../..');
const voice = path.join(product, 'engine/voice');
const list = process.argv.includes('--list');
const core = spawnSync(process.execPath, [path.join(voice, 'tests/mutation-audit.mjs'), ...(list ? ['--list'] : [])], { stdio: 'inherit' });
if (core.status !== 0) process.exit(core.status || 1);
const serviceTests = fs.readFileSync(path.join(import.meta.dirname, 'run.js'), 'utf8');
const start = serviceTests.indexOf("group('model resolution");
const end = serviceTests.indexOf("group('whisper toolchain", start);
if (start < 0 || end < 0) throw new Error('Service model-resolution group not found');
const checks = [...testNames(serviceTests.slice(start, end)), 'the shell fetcher and the service read the SAME pin table, field for field'];
const ok = await audit({
  sources: [{ source: voice, destination: 'richos/engine/voice' }, { source: path.join(product, 'tools'), destination: 'richos/tools' }],
  mutations: JSON.parse(fs.readFileSync(path.join(import.meta.dirname, 'mutations.json'))),
  suites: [
    { args: ['richos/tools/richos-service/test/run.js'] },
    { args: ['richos/engine/voice/tests/consumers.test.mjs', '--without-rust'] },
  ], checks, list,
});
if (!ok) process.exitCode = 1;

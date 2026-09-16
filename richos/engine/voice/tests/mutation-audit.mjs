import fs from 'node:fs';
import path from 'node:path';
import { audit, testNames } from './support/mutation-runner.mjs';
const voice = path.resolve(import.meta.dirname, '..');
const checks = ['models.test.mjs', 'fetch.test.mjs'].flatMap((name) => testNames(fs.readFileSync(path.join(import.meta.dirname, name), 'utf8')));
const ok = await audit({
  sources: [{ source: voice, destination: 'richos/engine/voice' }],
  mutations: JSON.parse(fs.readFileSync(path.join(import.meta.dirname, 'mutations.json'))),
  suites: [{ args: ['richos/engine/voice/tests/run.mjs'] }], checks,
  list: process.argv.includes('--list'),
});
if (!ok) process.exitCode = 1;

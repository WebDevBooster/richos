import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { audit } from './support/mutation-runner.mjs';
import { testAsync, tmp, finish } from './support/harness.mjs';

function fixture() {
  const source = tmp();
  const original = 'export const a = 1;\nexport const b = 2;\n';
  fs.writeFileSync(path.join(source, 'values.mjs'), original);
  fs.writeFileSync(path.join(source, 'unrelated-edit.txt'), 'uncommitted caller edit');
  fs.writeFileSync(path.join(source, 'case.mjs'), `import {a,b} from './values.mjs';
const failures = [a !== 1 && 'a is intact', b !== 2 && 'b is intact'].filter(Boolean);
for (const name of failures) console.log('FAIL  ' + name);
console.log((2-failures.length) + ' passed, ' + failures.length + ' failed');
process.exitCode = failures.length ? 1 : 0;
`);
  const options = {
    sources: [{ source, destination: 'fixture' }],
    mutations: [{ label: 'break a', file: 'fixture/values.mjs', from: 'a = 1', to: 'a = 0' }, { label: 'break b', file: 'fixture/values.mjs', from: 'b = 2', to: 'b = 0' }],
    suites: [{ args: ['fixture/case.mjs'] }], checks: ['a is intact', 'b is intact'],
  };
  return { source, original, options };
}
function unchanged(f) {
  assert.equal(fs.readFileSync(path.join(f.source, 'values.mjs'), 'utf8'), f.original);
  assert.equal(fs.readFileSync(path.join(f.source, 'unrelated-edit.txt'), 'utf8'), 'uncommitted caller edit');
}

testAsync('mutation audit starts each case intact and leaves caller edits untouched', async () => {
  const f = fixture();
  assert.equal(await audit(f.options), true);
  unchanged(f);
});
testAsync('mutation audit refuses missing anchors, survivors and import crashes', async () => {
  for (const to of ['a = 1', 'a = ;']) {
    const f = fixture();
    f.options.mutations[0].to = to;
    assert.equal(await audit(f.options), false);
    unchanged(f);
  }
  const f = fixture();
  f.options.mutations[0].from = 'missing anchor';
  assert.equal(await audit(f.options), false);
  unchanged(f);
});
testAsync('mutation audit refuses a failing intact positive control', async () => {
  const f = fixture();
  fs.writeFileSync(path.join(f.source, 'case.mjs'), 'throw new Error("broken positive control");');
  await assert.rejects(audit(f.options), /Intact positive control failed/);
  unchanged(f);
});
testAsync('interrupted mutation audit cannot leave a mutation in the caller', async () => {
  const f = fixture();
  const ready = path.join(tmp(), 'ready');
  fs.writeFileSync(path.join(f.source, 'case.mjs'), `import {a} from './values.mjs';
import fs from 'node:fs';
if (a !== 1) { fs.writeFileSync(${JSON.stringify(ready)}, 'ready'); await new Promise(r => setTimeout(r, 30000)); }
console.log('2 passed, 0 failed');
`);
  const worker = path.join(tmp(), 'worker.mjs');
  fs.writeFileSync(worker, `import {audit} from ${JSON.stringify(pathToFileURL(path.join(import.meta.dirname, 'support/mutation-runner.mjs')).href)}; await audit(${JSON.stringify(f.options)});`);
  const child = spawn(process.execPath, [worker], { stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', b => { output += b; });
  child.stderr.on('data', b => { output += b; });
  const closed = new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
  try {
    const deadline = Date.now() + 10000;
    while (!fs.existsSync(ready) && Date.now() < deadline) await new Promise(r => setTimeout(r, 20));
    assert.ok(fs.existsSync(ready), output);
    child.kill('SIGTERM');
    assert.notEqual(await closed, 0);
    assert.match(output, /Mutation audit interrupted/);
    unchanged(f);
  } finally { child.kill('SIGKILL'); }
});
await finish();

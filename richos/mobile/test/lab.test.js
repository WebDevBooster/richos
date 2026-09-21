const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { generateKeyPairSync, sign, createHash } = require('node:crypto');
const { rmSync, existsSync } = require('node:fs');
const { join } = require('node:path');
const { createScratch } = require('./storage.cjs');

test('isolated lab verifies real signatures, deduplicates a send and shuts down its CLI session', { timeout: 15000 }, async t => {
  const dir = createScratch('native-lab');
  const child = spawn(process.execPath, [join(__dirname, '../cli/mobile.mjs'), 'lab', 'serve'], {
    env: { ...process.env, RICHOS_MOBILE_CACHE: dir, RICHOS_LAB_PORT: '0', TMPDIR: dir + '/' },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const stopped = once(child, 'close');
  let stderr = ''; child.stderr.on('data', data => { stderr += data; });
  t.after(async () => { if (child.exitCode === null) child.kill('SIGTERM'); await stopped; rmSync(dir, { recursive: true, force: true }); });
  const first = await new Promise((resolve, reject) => {
    let text = '';
    child.once('error', reject);
    child.once('exit', code => reject(Error(`Lab exited ${code}: ${stderr}`)));
    child.stdout.on('data', chunk => { text += chunk; if (text.includes('\n')) resolve(JSON.parse(text.split('\n')[0])); });
  });
  const base = `http://127.0.0.1:${first.state.port}`;
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const paired = await (await fetch(base + '/api/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code: first.state.pairingCode, public_key_jwk: publicKey.export({ format: 'jwk' }), device_name: 'Isolated proof' }) })).json();
  assert(paired.device_id); assert(paired.challenge);
  let challenge = paired.challenge;
  async function request(path, body, wrongSignature = false) {
    const text = JSON.stringify(body);
    const input = `${challenge}\nPOST\n${path}\n${createHash('sha256').update(text).digest('hex')}`;
    const signature = sign('sha256', Buffer.from(wrongSignature ? input + 'wrong' : input), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
    const response = await fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json',
      Authorization: `RichOS-Device ${paired.device_id}.${challenge}.${signature}` }, body: text });
    challenge = response.headers.get('X-RichOS-Challenge') || challenge;
    return response;
  }
  assert((await request('/api/pair', { ca_verified: true })).ok);
  const message = { client_id: 'one-message', thread_id: paired.threads[0].id, kind: 'text', text: 'Signed lab proof', sent_at: new Date().toISOString() };
  assert.equal((await request('/api/messages', message, true)).status, 404);
  const accepted = await request('/api/messages', message); assert(accepted.ok);
  const retry = await (await request('/api/messages', message)).json(); assert.equal(retry.duplicate, true);
  child.kill('SIGTERM');
  const [code] = await stopped; assert.equal(code, 0, stderr);
  assert.equal(existsSync(join(dir, 'lab.cli.lock')), false);
  await assert.rejects(fetch(base + '/api/challenge'));
});

test('independent update lab uses the publication path and stops its service and timers', { timeout: 15000 }, async t => {
  const dir = createScratch('update-lab');
  const child = spawn(process.execPath, [join(__dirname, '../cli/mobile.mjs'), 'lab', 'updates'], { env: { ...process.env, RICHOS_MOBILE_CACHE: dir, TMPDIR: dir + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stopped = once(child, 'close'); let stderr = ''; child.stderr.on('data', chunk => { stderr += chunk; });
  t.after(async () => { if (child.exitCode === null) child.kill('SIGTERM'); await stopped; rmSync(dir, { recursive: true, force: true }); });
  const first = await new Promise((resolve, reject) => {
    let output = ''; child.once('error', reject); child.once('exit', code => reject(Error(`Lab exited ${code}: ${stderr}`)));
    child.stdout.on('data', chunk => { output += chunk; if (output.includes('\n')) resolve(JSON.parse(output.split('\n')[0])); });
  });
  const url = `http://127.0.0.1:${first.policyLab.port}/v1/policy`;
  const policy = await (await fetch(url)).json(); assert.equal(policy.severity, 'none'); assert.equal(policy.features.recording, true);
  child.kill('SIGTERM'); const [code] = await stopped; assert.equal(code, 0, stderr); await assert.rejects(fetch(url));
});

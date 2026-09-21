// Disposable physical-device proof. It publishes through the same operator path as
// production and serves through the real policy service. It cannot touch a Mac pairing.
import { join } from 'node:path';
import { writeFileSync, mkdirSync } from 'node:fs';
import { preview, publish, serve } from '../service/policy.mjs';
export async function policyLab(cache) {
  const directory = join(cache, `policy-lab-${Date.now()}`); mkdirSync(directory, { mode: 0o700 });
  const trace = []; const timers = new Set(); let armed = true;
  const change = (revision, disabled) => {
    const now = Date.now(), policy = { schema: 1, revision, issuedAt: new Date(now).toISOString(), expiresAt: new Date(now + 600000).toISOString(),
      severity: 'none', title: '', message: disabled ? 'Update service test: recording temporarily paused.' : '', allowDismiss: true, remindAfterSeconds: 60, features: { recording: !disabled } };
    publish(directory, policy, { operator: 'physical-device-lab', previewDigest: preview(policy, []).digest });
    trace.push({ kind: 'published', revision, at: now }); writeFileSync(join(directory, 'trace.json'), JSON.stringify(trace, null, 2));
  };
  const firstRevision = Date.now(); change(firstRevision, false);
  const service = serve(directory);
  service.server.on('request', (req) => {
    if (req.method !== 'GET' || req.url !== '/v1/policy') return;
    trace.push({ kind: 'policy-request', at: Date.now() });
    if (armed) {
      armed = false;
      timers.add(setTimeout(() => change(firstRevision + 1, true), 2000));
      timers.add(setTimeout(() => change(firstRevision + 2, false), 12000));
    }
    writeFileSync(join(directory, 'trace.json'), JSON.stringify(trace, null, 2));
  });
  await new Promise(resolve => service.server.once('listening', resolve));
  const result = { port: service.server.address().port, directory };
  writeFileSync(join(cache, 'policy-lab.json'), JSON.stringify(result)); console.log(JSON.stringify({ policyLab: result }));
  await new Promise(resolve => { process.once('SIGTERM', resolve); process.once('SIGINT', resolve); });
  for (const timer of timers) clearTimeout(timer); await service.close(); return { stopped: true, trace, directory };
}

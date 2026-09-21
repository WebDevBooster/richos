// The public service is read-only. Publication is a local operator command with an
// exclusive filesystem lock and a durable revision record, never an unauthenticated HTTP route.
import { createServer } from 'node:http';
import { mkdirSync, readFileSync, writeFileSync, renameSync, existsSync, statSync, readdirSync, rmdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
const { validate, evaluate } = createRequire(import.meta.url)('../core/updates.js');
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export function readPolicy(directory) {
  const record = JSON.parse(readFileSync(join(directory, 'active.json'), 'utf8'));
  return validate(record.policy);
}
export function preview(policy, clients, now = Date.now()) {
  policy = validate(policy);
  if (Date.parse(policy.issuedAt) > now + 300000 || Date.parse(policy.expiresAt) <= now) throw Error('Policy is not currently valid');
  return { digest: digest(policy), revision: policy.revision, decisions: clients.map(client => ({ client, decision: evaluate(policy, client, now) })) };
}
export function publish(directory, policy, { operator, previewDigest, availability } = {}) {
  policy = validate(policy); preview(policy, []);
  if (typeof operator !== 'string' || !/^[a-zA-Z0-9_.@ -]{1,100}$/.test(operator)) throw Error('An operator identity is required');
  if (previewDigest !== digest(policy)) throw Error('Preview this exact policy before publication');
  if (policy.latest) {
    // Availability is a release operator's attestation of an actual download, not App Review approval.
    // Store checks must be performed for every included storefront and the supported OS floor.
    if (!availability || availability.downloadVerified !== true || availability.appId !== policy.latest.appId ||
      availability.version !== policy.latest.version || availability.build !== policy.latest.build ||
      availability.minimumOS !== policy.latest.minimumOS || availability.verifiedAt !== policy.latest.verifiedAt ||
      JSON.stringify([...availability.storefronts || []].sort()) !== JSON.stringify([...policy.latest.storefronts].sort()) ||
      typeof availability.evidence !== 'string' || availability.evidence.length < 10 || availability.evidence.length > 2000) throw Error('A matching download verification receipt is required');
  }
  directory = resolve(directory);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  if ((statSync(directory).mode & 0o077) !== 0) throw Error('Policy directory must be private (mode 0700)');
  const lock = join(directory, '.publish-lock'); mkdirSync(lock, { mode: 0o700 });
  try {
    const revisions = readdirSync(directory).filter(x => /^revision-\d+\.json$/.test(x)).map(x => Number(x.slice(9, -5)));
    if (policy.revision <= Math.max(0, ...revisions)) throw Error('Publication and rollback require a new increasing revision');
    const record = { policy, audit: { operator, publishedAt: new Date().toISOString(), digest: digest(policy), availability: availability || null } };
    const bytes = JSON.stringify(record, null, 2) + '\n';
    // Archive first. A crash before activation consumes the revision and leaves a reviewable record.
    writeFileSync(join(directory, `revision-${policy.revision}.json`), bytes, { mode: 0o600, flag: 'wx', flush: true });
    writeFileSync(join(directory, 'active.new'), bytes, { mode: 0o600, flush: true });
    renameSync(join(directory, 'active.new'), join(directory, 'active.json'));
    return { revision: policy.revision, digest: digest(policy) };
  } finally { rmdirSync(lock); }
}
export function serve(directory, { port = 0, host = '127.0.0.1', signalInterval = 1000 } = {}) {
  const streams = new Set(); let revision = 0;
  const metricsFile = join(directory, 'metrics.json');
  let metrics = {}; try { metrics = JSON.parse(readFileSync(metricsFile, 'utf8')); } catch { /* first run */ }
  function count(event, version = 'unknown', build = 'unknown', revision = 0) {
    const key = JSON.stringify([new Date().toISOString().slice(0, 10), event, version, build, revision]);
    if (Object.keys(metrics).length < 10000 || metrics[key]) metrics[key] = (metrics[key] || 0) + 1;
  }
  function saveMetrics() {
    if (!existsSync(directory)) return;
    const oldest = Date.now() - 30 * 86400000;
    metrics = Object.fromEntries(Object.entries(metrics).filter(([key]) => Date.parse(JSON.parse(key)[0]) >= oldest));
    writeFileSync(metricsFile + '.new', JSON.stringify(metrics), { mode: 0o600 }); renameSync(metricsFile + '.new', metricsFile);
  }
  const server = createServer((req, res) => {
    res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Content-Type-Options', 'nosniff');
    // No query data, cookies, identity or conversation content is accepted or logged.
    if (req.method === 'POST' && req.url === '/v1/metrics') {
      let body = ''; req.setTimeout(5000, () => req.destroy());
      req.on('data', chunk => { body += chunk; if (body.length > 512) req.destroy(); });
      req.on('end', () => {
        try {
          const value = JSON.parse(body);
          if (Object.keys(value).some(key => !['event', 'version', 'build', 'revision'].includes(key)) ||
            !['policy-visible', 'policy-failed', 'store-opened', 'store-failed'].includes(value.event) ||
            !/^\d+(\.\d+){0,2}$/.test(value.version) || !/^\d+(\.\d+){0,2}$/.test(value.build) ||
            !Number.isSafeInteger(value.revision) || value.revision < 0) throw Error('Invalid metric');
          count(value.event, value.version, value.build, value.revision); res.writeHead(204); res.end();
        } catch { res.writeHead(400); res.end(); }
      }); return;
    }
    if (req.method !== 'GET') { res.writeHead(405); return res.end(); }
    if (req.url === '/v1/policy') {
      try { const value = readPolicy(directory); count('policy-served', 'unknown', 'unknown', value.revision); res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); }
      catch { res.writeHead(503); res.end(); } return;
    }
    if (req.url === '/v1/events') {
      if (streams.size >= 1000) { res.writeHead(503); return res.end(); }
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'X-Accel-Buffering': 'no' });
      res.write(`event: policy\ndata: ${revision}\n\n`); streams.add(res);
      req.on('close', () => streams.delete(res)); return;
    }
    res.writeHead(404); res.end();
  });
  let ticks = 0;
  const timer = setInterval(() => {
    let next = revision; try { next = readPolicy(directory).revision; } catch { /* clients retain bounded cached policy */ }
    ticks++;
    if (ticks % 60 === 0) { try { saveMetrics(); } catch { /* request handling does not depend on metrics storage */ } }
    for (const stream of streams) {
      if (next !== revision || ticks % 15 === 0) {
        if (!stream.write(next !== revision ? `event: policy\ndata: ${next}\n\n` : ': alive\n\n')) { stream.destroy(); streams.delete(stream); }
      }
    }
    revision = next;
  }, signalInterval);
  server.on('close', () => { clearInterval(timer); try { saveMetrics(); } catch { /* metrics are best effort */ } });
  server.listen(port, host);
  return { server, async close() { for (const stream of streams) stream.end(); clearInterval(timer); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); } };
}
export async function command(name, file, cache) {
  const directory = process.env.RICHOS_UPDATE_DIRECTORY || join(cache, 'update-policy');
  if (name === 'serve') {
    const instance = serve(directory, { port: Number(process.env.RICHOS_UPDATE_PORT || 0) });
    await new Promise(resolve => instance.server.once('listening', resolve));
    console.log(JSON.stringify({ policyService: `http://127.0.0.1:${instance.server.address().port}`, directory }));
    await new Promise(resolve => { process.once('SIGINT', resolve); process.once('SIGTERM', resolve); });
    await instance.close(); return { stopped: true };
  }
  if (name === 'metrics') return JSON.parse(readFileSync(join(directory, 'metrics.json'), 'utf8'));
  if (!file) throw Error('Provide a policy request JSON file');
  const input = JSON.parse(readFileSync(file, 'utf8'));
  if (name === 'preview') return preview(input.policy, input.clients || []);
  if (name === 'publish') return publish(directory, input.policy, input);
  throw Error('Use update preview, publish or serve');
}

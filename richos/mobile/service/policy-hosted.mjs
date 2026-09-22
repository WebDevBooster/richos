// Operator side of the hosted update policy. The Worker (policy-worker.mjs) has no write route.
// Publication applies the same authorization as the local store (preview digest, operator identity,
// availability receipt), then inserts one append-only D1 row through Cloudflare's API with a
// short-lived operator token read from a private file. The token never enters argv, output or errors.
import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { authorize, digest } from './policy.mjs';
import { LATEST } from './policy-store.mjs';

// One statement: the insert happens only if it is newer than every stored revision, so two
// operators racing, a replayed request or an out-of-order rollback can never lower the latest.
// D1's HTTP API binds parameters as strings; CAST keeps the comparison numeric.
export const PUBLISH = `INSERT INTO revisions (revision, policy, digest, audit, published_at)
SELECT CAST(?1 AS INTEGER), ?2, ?3, ?4, ?5
WHERE CAST(?1 AS INTEGER) > (SELECT COALESCE(MAX(revision), 0) FROM revisions)`;

const MODULES = ['service/policy-worker.mjs', 'service/policy-store.mjs', 'core/updates.js'];
export const COMPATIBILITY_DATE = '2026-09-21';

export function checkProfile(profile) {
  if (!profile || typeof profile !== 'object') throw Error('Invalid deployment profile');
  if (!/^[a-f0-9]{32}$/.test(profile.accountId)) throw Error('Invalid deployment identifier');
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(profile.databaseId)) throw Error('Invalid policy database ID');
  // A first-level name under the zone stays inside the parent's Universal SSL certificate.
  if (typeof profile.hostname !== 'string' || !/^[a-z0-9-]+\.[a-z0-9-]+\.[a-z]{2,}$/.test(profile.hostname)) throw Error('Invalid policy hostname');
  return profile;
}

const sha256 = text => createHash('sha256').update(text).digest('hex');
const read = name => readFileSync(new URL('../' + name, import.meta.url), 'utf8');

// One statement per CREATE, so trigger bodies keep their inner semicolons.
export function schemaStatements() {
  return read('service/policy-schema.sql').split('\n').filter(line => !line.startsWith('--')).join('\n')
    .split(/\n(?=CREATE )/).map(statement => statement.trim()).filter(Boolean);
}
const EXPECTED_SCHEMA = ['revisions', 'revisions_no_delete', 'revisions_no_update'];

// The exact multipart upload: module names mirror the source tree so '../core/updates.js' resolves.
export function workerArtifact(profile) {
  checkProfile(profile);
  const schema = read('service/policy-schema.sql');
  return {
    stage: 'update-policy',
    worker: 'richos-update-policy',
    hostname: profile.hostname,
    policyURL: `https://${profile.hostname}/v1/policy`,
    metadata: {
      main_module: MODULES[0], compatibility_date: COMPATIBILITY_DATE,
      bindings: [{ name: 'DB', type: 'd1', id: profile.databaseId }],
      observability: { enabled: false }, logpush: false, tail_consumers: [],
    },
    modules: MODULES.map(name => { const source = read(name); return { name, type: 'application/javascript+module', source, sha256: sha256(source) }; }),
    subdomain: { enabled: false, previews_enabled: false },
    schema: { database: 'richos-update-policy', sql: schema, sha256: sha256(schema) },
  };
}

export function readToken(path) {
  if (!path) throw Error('Set RICHOS_POLICY_TOKEN_FILE to a private file holding a short-lived D1 token');
  if ((statSync(path).mode & 0o077) !== 0) throw Error('The policy token file must be private (mode 0600)');
  const token = readFileSync(path, 'utf8').trim();
  if (!/^[A-Za-z0-9_-]{20,200}$/.test(token)) throw Error('The policy token file does not hold a Cloudflare API token');
  return token;
}

function d1(profile, token, fetchImpl) {
  const endpoint = `https://api.cloudflare.com/client/v4/accounts/${profile.accountId}/d1/database/${profile.databaseId}/query`;
  return async (sql, params = []) => {
    const response = await fetchImpl(endpoint, { method: 'POST', redirect: 'error',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ sql, params }) });
    const body = await response.json().catch(() => null);
    const result = body?.result?.[0];
    if (!response.ok || body?.success !== true || result?.success !== true) {
      // Only numeric codes are surfaced: provider messages can echo request material.
      const codes = (body?.errors || []).map(error => error?.code).filter(Number.isInteger).join(',');
      throw Error(`Cloudflare D1 query failed (HTTP ${response.status}${codes ? ', codes ' + codes : ''})`);
    }
    return result;
  };
}

export async function publishHosted(profile, request, { token, fetch: fetchImpl = fetch } = {}) {
  checkProfile(profile);
  // Refused before any network call when the digest, operator or availability receipt is wrong.
  const { policy, audit } = authorize(request?.policy, request || {});
  const query = d1(profile, token, fetchImpl);
  const hosted = (await query(LATEST)).results?.[0]?.revision || 0;
  if (policy.revision <= hosted) throw Error(`Publication and rollback require a new increasing revision (hosted revision is ${hosted})`);
  const inserted = await query(PUBLISH, [String(policy.revision), JSON.stringify(policy), audit.digest, JSON.stringify(audit), audit.publishedAt]);
  if (inserted.meta?.changes !== 1) throw Error('A newer revision was published concurrently; preview again with a higher revision');
  const stored = (await query(LATEST)).results?.[0];
  if (stored?.revision !== policy.revision || digest(JSON.parse(stored.policy)) !== audit.digest) throw Error('Hosted readback does not match the published revision');
  // Public readback through the served route. The insert is already durable if this fails.
  let served = null, servedError = null;
  try {
    const response = await fetchImpl(`https://${profile.hostname}/v1/policy`, { redirect: 'error', cache: 'no-store', headers: { Accept: 'application/json' } });
    if (!response.ok) throw Error(`HTTP ${response.status}`);
    served = (await response.json()).revision;
  } catch (error) { servedError = error.message; }
  return { revision: policy.revision, digest: audit.digest, operator: audit.operator, publishedAt: audit.publishedAt, stored: true, served, servedError };
}

// Idempotent (IF NOT EXISTS). Verifies the table and both append-only triggers exist afterwards.
export async function applySchema(profile, { token, fetch: fetchImpl = fetch } = {}) {
  checkProfile(profile);
  const query = d1(profile, token, fetchImpl);
  for (const statement of schemaStatements()) await query(statement);
  const names = (await query("SELECT name FROM sqlite_master WHERE name IN ('revisions', 'revisions_no_update', 'revisions_no_delete') ORDER BY name")).results.map(row => row.name);
  if (JSON.stringify(names) !== JSON.stringify(EXPECTED_SCHEMA)) throw Error('Hosted schema readback is incomplete');
  return { schema: names, sha256: sha256(read('service/policy-schema.sql')) };
}

export async function command(name, file) {
  if (name === 'worker-artifact') {
    if (!file) throw Error('Provide the private deployment profile JSON file');
    return workerArtifact(JSON.parse(readFileSync(file, 'utf8')));
  }
  if (name === 'publish-hosted' && !file) throw Error('Provide a policy request JSON file');
  const profilePath = process.env.RICHOS_POLICY_PROFILE;
  if (!profilePath) throw Error('Set RICHOS_POLICY_PROFILE to the private deployment profile JSON file');
  const profile = JSON.parse(readFileSync(profilePath, 'utf8')), token = readToken(process.env.RICHOS_POLICY_TOKEN_FILE);
  if (name === 'schema-hosted') return applySchema(profile, { token });
  return publishHosted(profile, JSON.parse(readFileSync(file, 'utf8')), { token });
}

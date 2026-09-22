import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

// Domain/account identifiers belong in the operator's private deployment record.
// This artifact contains only the reproducible upload and its source digest.
export function artifact() {
  const source = readFileSync(new URL('../service/connect-bootstrap.mjs', import.meta.url), 'utf8');
  return {
    stage: 'bootstrap',
    sha256: createHash('sha256').update(source).digest('hex'),
    metadata: {
      main_module: 'connect-bootstrap.mjs',
      compatibility_date: '2026-09-21',
      bindings: [],
      observability: { enabled: false },
      logpush: false,
      tail_consumers: [],
    },
    modules: [{ name: 'connect-bootstrap.mjs', type: 'application/javascript+module', source }],
    subdomain: { enabled: false, previews_enabled: false },
  };
}

export function managedArtifact(profile) {
  for (const name of ['accountId', 'zoneId']) if (!/^[a-f0-9]{32}$/.test(profile[name])) throw Error('Invalid deployment identifier');
  if (!/^[a-f0-9-]{36}$/.test(profile.databaseId) || !/^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$/.test(profile.domain)) throw Error('Invalid deployment domain/database');
  if (!Number.isInteger(profile.capacity) || profile.capacity < 1 || profile.capacity > 10) throw Error('Pilot capacity must be between 1 and 10');
  const names = ['connect-worker.mjs', 'connect/auth.mjs', 'connect/store.mjs', 'connect/provider.mjs', 'connect/lifecycle.mjs'];
  return {
    stage: 'managed',
    metadata: {
      main_module: 'connect-worker.mjs', compatibility_date: '2026-09-21',
      keep_bindings: ['secret_text'], observability: { enabled: false }, logpush: false, tail_consumers: [],
      bindings: [
        { name: 'DB', type: 'd1', id: profile.databaseId },
        { name: 'REQUEST_LIMIT', type: 'ratelimit', namespace_id: '18443', simple: { limit: 60, period: 60 } },
        ...Object.entries({ CF_ACCOUNT_ID: profile.accountId, CF_ZONE_ID: profile.zoneId, CONNECT_DOMAIN: profile.domain,
          HOST_CAPACITY: String(profile.capacity), ENROLLMENT_OPEN: 'false' }).map(([name, text]) => ({ name, type: 'plain_text', text })),
      ],
    },
    modules: names.map(name => {
      const source = readFileSync(new URL('../service/' + name, import.meta.url), 'utf8');
      return { name, type: 'application/javascript+module', source, sha256: createHash('sha256').update(source).digest('hex') };
    }),
    subdomain: { enabled: false, previews_enabled: false },
    schedules: [{ cron: '*/5 * * * *' }],
  };
}

export async function command(action, file) {
  if (action === 'managed-artifact' && file) return managedArtifact(JSON.parse(readFileSync(file, 'utf8')));
  if (action !== 'artifact') throw Error('Expected connect artifact or managed-artifact <profile.json>. This command prepares an upload; it does not deploy.');
  return artifact();
}

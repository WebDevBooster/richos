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

export async function command(action) {
  if (action !== 'artifact') throw Error('Expected connect artifact. This command prepares an upload; it does not deploy.');
  return artifact();
}

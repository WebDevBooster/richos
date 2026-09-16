// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
export const AUDIENCES = ['rich', 'worker', 'org'];

export const AUDIENCE_SCOPES = {
  rich: ['ceo-private', 'org-shared', 'external'],
  worker: ['org-shared', 'external'],
  org: ['org-shared', 'external'],
};

export function assertAudience(audience) {
  if (typeof audience !== 'string' || !AUDIENCES.includes(audience)) {
    throw new Error(
      `privacy invariant: unknown audience "${audience}". Must be one of ${AUDIENCES.join(' | ')} — ` +
        'refusing to guess, because guessing wide would leak CEO-private memory.',
    );
  }
  return audience;
}

export function scopeAllowed(scope, audience) {
  return AUDIENCE_SCOPES[assertAudience(audience)].includes(scope);
}

export function filterByAudience(records, audience) {
  assertAudience(audience);
  const allowed = [];
  const withheld = [];
  for (const rec of records) {
    if (scopeAllowed(rec.scope, audience)) allowed.push(rec);
    else withheld.push(rec);
  }
  return { allowed, withheld };
}

export function assertNoScopeLeak(slice, audience) {
  assertAudience(audience);
  const items = (slice && slice.items) || [];
  for (const item of items) {
    if (!scopeAllowed(item.scope, audience)) {
      throw new Error(
        `privacy invariant VIOLATED: slice for audience "${audience}" contains a "${item.scope}" ` +
          `record (${item.ref}). Refusing to emit.`,
      );
    }
  }
  return true;
}

function codeOnly(source) {
  return String(source)
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/(^|[^:])\/\/[^\n]*/g, '$1 ')
    .replace(/'(?:[^'\\\n]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\\n]|\\.)*"/g, '""')
    .replace(/`(?:[^`\\]|\\.)*`/g, '``');
}

const NETWORK_PATTERNS = [
  ['\\bfetch\\s*\\(', 'fetch()'],
  ['\\bXMLHttpRequest\\b', 'XMLHttpRequest'],
  ['\\bWebSocket\\b', 'WebSocket'],
  ['\\bnode:(?:http|https|net|tls|dgram|dns)\\b', 'a node network module'],
];

const WRITE_PATTERNS = [
  ['\\bfs\\.(?:write|append|rm|unlink|mkdir|rename|copyFile|truncate|chmod)', 'a filesystem write'],
  ['\\bchild_process\\b', 'child_process'],
  ['\\bprocess\\.exit\\b', 'process.exit (a library must not kill its host)'],
];

export function assertNoSideEffects(source, label = 'module') {
  const code = codeOnly(source);
  const problems = [];
  for (const [pattern, what] of NETWORK_PATTERNS) {
    if (new RegExp(pattern).test(code)) {
      problems.push(`${label} reaches for ${what} — the context compiler must make NO network call`);
    }
  }
  for (const [pattern, what] of WRITE_PATTERNS) {
    if (new RegExp(pattern).test(code)) {
      problems.push(`${label} performs ${what} — the context compiler is READ-ONLY over loro`);
    }
  }
  return problems;
}

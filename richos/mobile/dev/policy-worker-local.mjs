// Runs the exact update-policy upload in Cloudflare's local runtime (workerd through Miniflare)
// with a local D1, because Node-only tests cannot prove Worker behavior. Nothing is installed:
// Miniflare is taken from RICHOS_MINIFLARE or from the Wrangler already on PATH. Loopback only;
// the workerd process is owned by the returned handle and ends with dispose().
import { existsSync, realpathSync } from 'node:fs';
import { dirname, join, resolve, delimiter } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { workerArtifact, schemaStatements, PUBLISH } from '../service/policy-hosted.mjs';

const mobile = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function locateMiniflare(env = process.env) {
  if (env.RICHOS_MINIFLARE) return existsSync(env.RICHOS_MINIFLARE) ? env.RICHOS_MINIFLARE : null;
  for (const directory of (env.PATH || '').split(delimiter)) {
    const wrangler = join(directory, 'wrangler');
    if (!existsSync(wrangler)) continue;
    // Homebrew and npm link bin/wrangler.js inside the wrangler package, beside its node_modules.
    const entry = join(dirname(dirname(realpathSync(wrangler))), 'node_modules', 'miniflare', 'dist', 'src', 'index.js');
    if (existsSync(entry)) return entry;
  }
  return null;
}

export async function startLocalPolicyWorker(entry = locateMiniflare()) {
  if (!entry) throw Error('Cloudflare local runtime not installed (no Wrangler with Miniflare on PATH; set RICHOS_MINIFLARE)');
  const { Miniflare, supportedCompatibilityDate } = await import(pathToFileURL(entry).href);
  const artifact = workerArtifact({ accountId: '0'.repeat(32), databaseId: '00000000-0000-0000-0000-000000000000', hostname: 'updates.example.com' });
  // The installed runtime may predate the upload's date; the older date is used and reported.
  const compatibilityDate = artifact.metadata.compatibility_date <= supportedCompatibilityDate ? artifact.metadata.compatibility_date : supportedCompatibilityDate;
  const mf = new Miniflare({
    // cf: false keeps Miniflare from downloading Cloudflare's request-metadata file into ./.wrangler.
    modulesRoot: mobile, compatibilityDate, cf: false,
    modules: artifact.modules.map(module => ({ type: 'ESModule', path: join(mobile, module.name), contents: module.source })),
    d1Databases: { DB: 'richos-update-policy-local' },
  });
  let db;
  try {
    await mf.ready;
    db = await mf.getD1Database('DB');
    await db.batch(schemaStatements().map(statement => db.prepare(statement)));
  } catch (error) { await mf.dispose().catch(() => {}); throw error; }
  // The same statement and string parameters the operator sends through Cloudflare's D1 API.
  const insert = (policy, operator = 'local-runtime-check') => db.prepare(PUBLISH)
    .bind(String(policy.revision), JSON.stringify(policy), 'f'.repeat(64), JSON.stringify({ operator }), new Date().toISOString()).run();
  return { mf, db, insert, compatibilityDate, runtime: { miniflare: entry, requestedDate: artifact.metadata.compatibility_date },
    fetch: (path, init) => mf.dispatchFetch('https://updates.example.com' + path, init), dispose: () => mf.dispose() };
}

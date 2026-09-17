/**
 * RichOS Workspace source — the loro-backed writer for the promotion pass (§4.4 step 4).
 *
 * `promotion.js` decides WHAT to promote and never writes. This is the one place that reaches the
 * corpus, and it does it through loro's OWN writer component (`<loro>/writer/writer.js`) rather than
 * by rendering front matter here: a second implementation of "how a record file is written" would
 * drift from the first the day the record format gains a field, and the writer owns the write lock,
 * the create-only publish, the id/scope/authority refusals and the supersede chain.
 *
 * The loro component is NOT part of this package and is never inferred from a guess: `RICHOS_LORO_DIR`
 * names it (the same variable `richos-core` reads), and the in-repo `engine/loro` is the fallback for
 * a source checkout. When neither is there, this REFUSES loudly instead of returning a writer that
 * quietly drops promotions — a Workspace sync that silently promotes nothing is the failure this
 * whole file exists to end.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { corpusRoot } from '../config.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** `richos/tools/richos-service/lib/workspace` → four up is `richos/`, which holds `engine/loro`. */
export const IN_REPO_LORO_DIR = path.resolve(HERE, '..', '..', '..', '..', 'engine', 'loro');

/**
 * Where the loro component is. Explicit first, in-repo second, refusal third.
 * @param {{env?:Object}} [opts]
 * @returns {string}
 */
export function resolveLoroDir(opts = {}) {
  const env = opts.env || process.env;
  const tried = [];
  const named = (env.RICHOS_LORO_DIR || '').trim();
  if (named) {
    tried.push(named);
    if (fs.existsSync(path.join(named, 'writer', 'writer.js'))) return named;
  }
  tried.push(IN_REPO_LORO_DIR);
  if (fs.existsSync(path.join(IN_REPO_LORO_DIR, 'writer', 'writer.js'))) return IN_REPO_LORO_DIR;
  throw new Error(
    `Workspace promotion: the loro writer is not installed. Looked in: ${tried.join(', ')}. ` +
      'RICHOS_LORO_DIR names it explicitly. Refusing to promote nothing and report success.',
  );
}

/**
 * Build the `write(request)` function `promoteFromEvidence` takes.
 *
 * A request carrying `supersedes` goes through the writer's `supersedeRecord`, which writes the new
 * record AND stamps the predecessor `supersededBy` — two writes that must not come apart, which is
 * why this asks the writer for them rather than doing an append and a patch.
 *
 * @param {{loroDir?:string, corpus?:string, now?:number, env?:Object}} [opts]
 * @returns {Promise<{write:(request:Object) => {ref:string}, corpusRoot:Object, loroDir:string}>}
 */
export async function loroWriter(opts = {}) {
  const loroDir = opts.loroDir || resolveLoroDir(opts);
  const writerUrl = new URL(`file://${path.join(loroDir, 'writer', 'writer.js')}`);
  const layoutUrl = new URL(`file://${path.join(loroDir, 'lib', 'layout.js')}`);
  const { appendRecord, supersedeRecord } = await import(writerUrl);
  const { resolveCorpusRoot } = await import(layoutUrl);

  const resolved = resolveCorpusRoot({
    corpus: opts.corpus || corpusRoot(),
    env: opts.env || process.env,
  });

  const write = (request) => {
    const now = typeof opts.now === 'number' ? opts.now : Date.now();
    const base = { ...request, corpusRoot: resolved, now };
    if (request.supersedes) {
      return supersedeRecord({
        ...base,
        ref: request.supersedes,
        // `supersedeRecord` forwards `refSource || ref` as the new record's provenance ref, and the
        // writer's own test calls that out: the replacement must cite ITS OWN evidence, not the
        // record it replaces. Ours is the vendor item id, which is what resolves the evidence file.
        refSource: request.ref,
        why: 'the item changed at the source, so the Workspace sync observed a new revision',
      });
    }
    return appendRecord(base);
  };

  return { write, corpusRoot: resolved, loroDir };
}

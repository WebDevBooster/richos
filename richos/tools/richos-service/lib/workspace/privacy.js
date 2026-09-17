/**
 * RichOS Workspace source — the PRIVACY INVARIANT, enforced in code (the system architecture §1).
 *
 * > RichOS reads the CEO's own Google data through a first-party OAuth app the CEO owns, and every byte
 * > of synthesis and storage stays on the CEO's machine. No RichOS server ever sees, proxies, brokers,
 * > or stores the data. "Local-first" here = the CEO's own trusted cloud → the CEO's own machine, with
 * > no third party in the path.
 *
 * This is not a policy note — it is the shape of the design, and this module makes two of its three
 * guarantees CHECKABLE (the third, CEO-owned OAuth client, is enforced by shipping instructions + a
 * config template, never a bundled RichOS secret. The CEO's OWN client has a secret and Google
 * requires it at the token endpoint — see client-secret.js — which changes where that value is kept,
 * not whose app it is: the OS keychain, alongside the tokens, under guarantee 2 below):
 *
 *   1. Every API call is machine-DIRECT to the CEO's own cloud. `assertDirectGoogleEndpoint` rejects
 *      any URL whose host is not a Google-owned API host — so no code path can point the client at a
 *      RichOS server or any third-party proxy.
 *   2. Tokens never leave the machine. `assertLocalTokenLocation` rejects any token-store target that
 *      is not the OS secure store or a path under the user's home — never a repo file, never a network
 *      location. (The repo secret-scan write-guard already blocks credential literals in commits — the
 *      same posture.) The CEO's OAuth client secret is held to the identical rule: keychain only,
 *      never `_oauth_client.json`, never any other file in the zone, never a printed line.
 *   3. Polling, not webhooks (§4.3): there is deliberately NO listener/server in this layer. The core
 *      polls with delta tokens; adapters expose `listChanges`, never a `watch`/`subscribe` method. A
 *      structural test asserts the adapter surface has no push method.
 *   4. The harvest gets the same rule as the credential. `assertEvidenceOutsideProductRepo` refuses an
 *      evidence zone inside the product repo — because guarding the token while the data it fetches
 *      defaults into a publicly-shipping repo is not a boundary, it is half of one.
 */

import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * The RichOS product checkout: `richos/tools/richos-service/lib/workspace` -> five up. Computed here rather than imported from
 * `config.js`, which imports THIS module — and computed at all because "not in the publicly-shipping
 * repo" has to be a control, not a comment.
 */
export const PRODUCT_REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..', '..');

/** Resolve existing ancestors before checking a path that may not exist yet. */
function canonicalPath(target) {
  let ancestor = path.resolve(target);
  const missing = [];
  for (;;) {
    try {
      // The native resolver also returns the filesystem's actual letter casing.
      // The JavaScript resolver can retain an alias spelling on case-insensitive volumes.
      return path.join(fs.realpathSync.native(ancestor), ...missing);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      // A dangling symlink is not a missing directory. Its destination cannot
      // be verified, so refuse it instead of treating its name as a safe path.
      if (fs.lstatSync(ancestor, { throwIfNoEntry: false })) throw error;
      const parent = path.dirname(ancestor);
      if (parent === ancestor) throw error;
      missing.unshift(path.basename(ancestor));
      ancestor = parent;
    }
  }
}

/** Is `p` physically inside `root`, including through symlinked ancestors? */
function isInside(p, root) {
  const relative = path.relative(canonicalPath(root), canonicalPath(p));
  return relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
}

/** Google-owned API hosts the client is allowed to reach directly. Nothing else is permitted. */
export const ALLOWED_GOOGLE_HOSTS = [
  'www.googleapis.com',
  'oauth2.googleapis.com',
  'accounts.google.com',
  'gmail.googleapis.com',
  'calendar.googleapis.com',
  'people.googleapis.com',
];

/**
 * Throw unless `url` targets a Google-owned API host over HTTPS. This is the single choke point every
 * outbound Workspace request passes through — it makes "no RichOS server in the path" a code invariant,
 * not a promise. A future Microsoft adapter adds `graph.microsoft.com` to its own allow-list module.
 * @param {string} url
 * @returns {URL}
 */
export function assertDirectGoogleEndpoint(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    throw new Error(`privacy invariant: not a valid URL: ${url}`);
  }
  if (u.protocol !== 'https:') {
    throw new Error(`privacy invariant: refusing non-HTTPS Workspace request to ${u.host}`);
  }
  if (!ALLOWED_GOOGLE_HOSTS.includes(u.hostname)) {
    throw new Error(
      `privacy invariant: refusing Workspace request to non-Google host "${u.hostname}". ` +
        `All calls must be machine-direct to the CEO's own Google cloud — no RichOS server, no proxy.`,
    );
  }
  return u;
}

/**
 * Throw unless `target` is a local, machine-only token location: the OS secure store (a keychain
 * service name, not a filesystem path) or a path under the user's home directory. A repo path, a temp
 * path outside home, or anything network-shaped is refused.
 * @param {{backend:'keychain'|'dpapi'|'file', service?:string, filePath?:string}} target
 * @returns {true}
 */
export function assertLocalTokenLocation(target) {
  if (!target || typeof target !== 'object') throw new Error('privacy invariant: no token location given');
  if (target.backend === 'keychain' || target.backend === 'dpapi') {
    if (!target.service) throw new Error('privacy invariant: OS secure store needs a service name');
    return true; // OS keychain / DPAPI: encrypted at rest by the OS, never on disk in plaintext.
  }
  if (target.backend === 'file') {
    const p = path.resolve(target.filePath || '');
    const home = os.homedir();
    if (!isInside(p, home) || canonicalPath(p) === canonicalPath(home)) {
      throw new Error(`privacy invariant: refusing token file outside the user's home: ${p}`);
    }
    // The docblock above has always said "never a repo file", but "under home" did not enforce it:
    // a checkout under the user's home passed. It does not any more — and the evidence rule below
    // draws the same line, so the credential and the data it fetches obey one boundary, not two.
    if (isInside(p, PRODUCT_REPO)) {
      throw new Error(
        `privacy invariant: refusing token file inside the RichOS product repo: ${p}. ` +
          'RichOS ships publicly; a credential in the checkout is one commit from being published.',
      );
    }
    return true;
  }
  throw new Error(`privacy invariant: unknown token backend "${target.backend}"`);
}

/**
 * Throw unless `target` is a legitimate place to put HARVESTED EVIDENCE — the CEO's call recordings,
 * transcripts, Calendar/Drive/Gmail pulls.
 *
 * This closes an incoherence in the boundary above. `assertLocalTokenLocation` treats the OAuth
 * credential as secret and refuses a repo path for it, while the DATA that credential fetches used to
 * default straight into the product repo (`config.js:29-30` → `<repo>/wiki/raw/meetings`,
 * `:243-244` → `<repo>/loro/raw/workspace`). The credential was guarded and the harvest was not —
 * and RichOS ships publicly, so evidence in the product repo is one
 * commit from being published. The loro structure notes name this asymmetry directly: *"the
 * credentials are forbidden from the repo while the data they fetch defaults into it."*
 *
 * A `.gitignore` line is a convention; this is the control. Same posture, no permissive fallback.
 *
 * @param {string} target the resolved absolute evidence path
 * @param {string} repoRoot the product checkout to refuse
 * @param {string} [what] what the path is, for the message
 * @returns {string} the validated target
 */
export function assertEvidenceOutsideProductRepo(target, repoRoot = PRODUCT_REPO, what = 'evidence') {
  if (!target) throw new Error('privacy invariant: no evidence location given');
  const p = path.resolve(String(target));
  if (isInside(p, repoRoot)) {
    throw new Error(
      `privacy invariant: refusing to write ${what} inside the RichOS product repo (${p}). ` +
        'RichOS ships publicly and this is the CEO\'s own material — recordings, transcripts, ' +
        'Calendar and Gmail pulls. Point it at the corpus (LORO_CORPUS) or an explicit path outside ' +
        'the checkout. The OAuth token that fetches this data is already refused a repo path; the ' +
        'data it fetches gets the same rule.',
    );
  }
  return p;
}

/**
 * The loopback hosts the OAuth consent redirect may come back on. Nothing else — a redirect to any
 * routable host would send the CEO's authorization code somewhere other than his own machine.
 * `new URL()` keeps IPv6 literals bracketed, so both spellings of ::1 are listed rather than parsed.
 */
export const ALLOWED_REDIRECT_HOSTS = ['127.0.0.1', '::1', '[::1]'];

/**
 * Throw unless `uri` is a LOOPBACK redirect for the consent ceremony (§6.1, the native-app PKCE
 * pattern the setup guide's Step 5 pins: `http://127.0.0.1:<port>/callback`).
 *
 * THIS IS NOT THE LISTENER §4.3 FORBIDS, and the difference is the whole reason this control exists
 * rather than a comment. The forbidden thing is a webhook: a PUBLIC HTTPS endpoint a vendor pushes to,
 * which cannot exist without a RichOS server. What this permits is a socket bound to the loopback
 * interface — unreachable from any other machine — which exists for the seconds between opening the
 * consent screen and the CEO clicking Continue, receives one redirect from HIS OWN browser, and is
 * closed before the command returns. Ingestion remains polling-only: `assertPollingOnly` still refuses
 * an adapter that grows a push method, and nothing here gives one a way in.
 *
 * `http:` is correct and deliberate here: loopback redirects are exempt from the HTTPS rule by
 * construction (a certificate for 127.0.0.1 would have to be self-signed and trusted machine-wide,
 * which is worse), and the code never leaves the machine. Every OUTBOUND call still goes through
 * `assertDirectGoogleEndpoint`, which refuses anything that is not HTTPS to a Google host.
 *
 * @param {string} uri
 * @returns {URL}
 */
export function assertLoopbackRedirect(uri) {
  let u;
  try {
    u = new URL(String(uri));
  } catch {
    throw new Error(`privacy invariant: not a valid redirect URI: ${uri}`);
  }
  if (u.protocol !== 'http:') {
    throw new Error(
      `privacy invariant: the consent redirect must be plain http on loopback, not "${u.protocol}" (${uri}). ` +
        'A desktop PKCE client redirects to 127.0.0.1; the code never leaves the machine.',
    );
  }
  if (!ALLOWED_REDIRECT_HOSTS.includes(u.hostname)) {
    throw new Error(
      `privacy invariant: refusing a consent redirect to non-loopback host "${u.hostname}". ` +
        'The authorization code must come back to the CEO\'s own machine — no public URL, no RichOS server.',
    );
  }
  if (!u.port) {
    throw new Error(`privacy invariant: the consent redirect needs an explicit port so the listener binds one deliberately: ${uri}`);
  }
  return u;
}

/**
 * Structural check used by tests + at wiring time: an adapter must be poll-only (§4.3). It must expose
 * `listChanges` and must NOT expose any push/webhook method, so no code path can create a public
 * listener (which would require a RichOS server).
 * @param {object} adapter
 * @returns {string[]} problems (empty = compliant)
 */
export function assertPollingOnly(adapter) {
  const problems = [];
  if (!adapter || typeof adapter.listChanges !== 'function') problems.push('adapter missing listChanges (poll primitive)');
  for (const banned of ['watch', 'subscribe', 'startWebhook', 'listen', 'openChannel']) {
    if (adapter && typeof adapter[banned] === 'function') problems.push(`adapter exposes a push method "${banned}" — webhooks are forbidden (§4.3)`);
  }
  return problems;
}

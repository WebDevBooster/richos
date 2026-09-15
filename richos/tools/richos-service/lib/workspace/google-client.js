/**
 * RichOS Workspace source — a thin Google API client (the system architecture §4.3).
 *
 * The single outbound gateway to the CEO's own Google cloud. Every request:
 *   - passes through `assertDirectGoogleEndpoint` (privacy invariant §1 — machine-direct, no server);
 *   - carries a bearer access token minted by the TokenManager (never a stored raw token here);
 *   - honors `429`/`5xx` with exponential backoff + jitter and `Retry-After` (§4.3). A single user is
 *     far under any project quota; this is not a rate-limit-sensitive workload.
 *   - treats `410 Gone` (an expired sync token) as a caller-visible signal, NOT an error to swallow —
 *     the adapter resets its cursor and does a bounded full resync, deduped by the ingest ledger.
 *
 * The HTTP transport is injected (default: global `fetch`) so the entire client is unit-testable with a
 * MOCK — no live account. Backoff sleeps are injectable for deterministic tests.
 */

import { assertDirectGoogleEndpoint } from './privacy.js';

export class GoneError extends Error {
  constructor(message) {
    super(message);
    this.name = 'GoneError';
    this.status = 410;
  }
}

const DEFAULT_MAX_RETRIES = 5;

export class GoogleClient {
  /**
   * @param {{getAccessToken:() => Promise<string>, http?:Function, sleep?:(ms:number)=>Promise<void>,
   *   maxRetries?:number, rand?:() => number}} opts
   */
  constructor(opts) {
    this.getAccessToken = opts.getAccessToken;
    this.http = opts.http || globalThis.fetch;
    this.sleep = opts.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.maxRetries = opts.maxRetries ?? DEFAULT_MAX_RETRIES;
    this.rand = opts.rand || Math.random;
  }

  /**
   * GET a Google API URL and return parsed JSON. Retries throttling/5xx with backoff; maps 410 to
   * `GoneError` (sync-token loss); throws on other 4xx.
   * @param {string} url  a fully-qualified googleapis.com URL
   * @returns {Promise<any>}
   */
  async getJson(url) {
    assertDirectGoogleEndpoint(url);
    let attempt = 0;
    for (;;) {
      const token = await this.getAccessToken();
      const res = await this.http(url, {
        method: 'GET',
        headers: { authorization: `Bearer ${token}`, accept: 'application/json' },
      });
      if (res.ok) {
        const text = await res.text();
        return text ? JSON.parse(text) : {};
      }
      if (res.status === 410) {
        throw new GoneError('sync token expired (410 Gone) — full resync required');
      }
      const retriable = res.status === 429 || (res.status >= 500 && res.status <= 599);
      if (!retriable || attempt >= this.maxRetries) {
        const body = await safeText(res);
        throw new Error(`google GET ${url} failed: ${res.status} ${body}`);
      }
      await this.sleep(this.backoffMs(attempt, res));
      attempt += 1;
    }
  }

  /** Exponential backoff with jitter, respecting a numeric `Retry-After` (seconds) when present. */
  backoffMs(attempt, res) {
    const ra = res && res.headers && typeof res.headers.get === 'function' ? res.headers.get('retry-after') : null;
    if (ra && /^\d+$/.test(String(ra))) return Number(ra) * 1000;
    const base = Math.min(1000 * 2 ** attempt, 32000);
    return Math.floor(base * (0.5 + this.rand() * 0.5)); // 50–100% jitter
  }
}

async function safeText(res) {
  try {
    return await res.text();
  } catch {
    return '';
  }
}

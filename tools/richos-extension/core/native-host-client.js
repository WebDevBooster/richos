/**
 * RichOS extension — native-host client (the seam to the local service).
 *
 * The unified architecture (architecture §5.1) replaces the Downloads hop with a native-messaging bridge to
 * the RichOS local service, which writes the contract directory DIRECTLY into the loro drop zone and
 * runs the transcription pipeline. This module is that client — and it is written so the extension
 * DEGRADES GRACEFULLY: if the service is not installed/running, `isAvailable()` is false and the
 * caller keeps using the existing Downloads path unchanged. The service is never a dependency for
 * capture to keep working.
 *
 * The message BUILDERS are pure (no `chrome.*`) so they are node-testable; only `NativeHostClient`
 * touches `chrome.runtime.connectNative`. Message shapes match lib/host-handlers.js in the service.
 */

/** Must equal the `name` in the service's host manifest (host/com.richos.host.json). */
export const NATIVE_HOST_ID = 'com.richos.host';

/** @param {Record<string, any>} record the session record written at call START */
export function buildStartMessage(record) {
  return { type: 'session-start', record, audioExt: 'webm' };
}

/**
 * @param {string} sessionId
 * @param {number} part
 * @param {string} dataB64 base64 of the raw Opus/WebM chunk bytes
 */
export function buildChunkMessage(sessionId, part, dataB64) {
  return { type: 'audio-chunk', sessionId, part, ext: 'webm', dataB64 };
}

/** @param {string} sessionId @param {object} line one health record */
export function buildHealthMessage(sessionId, line) {
  return { type: 'health', sessionId, line };
}

/** @param {string} sessionId @param {object} line one caption revision */
export function buildCaptionMessage(sessionId, line) {
  return { type: 'caption', sessionId, line };
}

/** @param {string} sessionId @param {number} t epoch ms */
export function buildHeartbeatMessage(sessionId, t) {
  return { type: 'heartbeat', sessionId, t };
}

/** @param {string} sessionId @param {Record<string, any>} record final accounting to merge */
export function buildCloseMessage(sessionId, record) {
  return { type: 'session-close', sessionId, record };
}

/**
 * Which sink should the writer use? Pure decision so it is testable without chrome.
 * @param {{available: boolean}} hostState
 * @returns {'native'|'downloads'}
 */
export function chooseSink(hostState) {
  return hostState && hostState.available ? 'native' : 'downloads';
}

/**
 * Thin wrapper over the native-messaging port. Connects lazily; any failure leaves `available`
 * false so the caller falls back to Downloads. The port dies with the browser (no listening port).
 */
export class NativeHostClient {
  constructor({ hostId = NATIVE_HOST_ID } = {}) {
    this.hostId = hostId;
    this.available = false;
    this._port = null;
    /** @type {Map<string, (msg: any) => void>} */
    this._waiters = new Map();
  }

  /**
   * Try to connect + handshake. Resolves to true if the local service answered `ready`.
   * @param {number} [timeoutMs]
   * @returns {Promise<boolean>}
   */
  async connect(timeoutMs = 1500) {
    if (typeof chrome === 'undefined' || !chrome.runtime || !chrome.runtime.connectNative) return false;
    try {
      this._port = chrome.runtime.connectNative(this.hostId);
      this._port.onMessage.addListener((msg) => this._onMessage(msg));
      this._port.onDisconnect.addListener(() => {
        this.available = false;
        this._port = null;
      });
    } catch {
      this.available = false;
      return false;
    }
    const ready = await this._request({ type: 'hello' }, 'ready', timeoutMs);
    this.available = ready != null;
    return this.available;
  }

  _onMessage(msg) {
    const waiter = msg && msg.type ? this._waiters.get(msg.type) : null;
    if (waiter) {
      this._waiters.delete(msg.type);
      waiter(msg);
    }
  }

  _request(message, expectType, timeoutMs = 3000) {
    return new Promise((resolve) => {
      if (!this._port) return resolve(null);
      const timer = setTimeout(() => {
        this._waiters.delete(expectType);
        resolve(null);
      }, timeoutMs);
      this._waiters.set(expectType, (msg) => {
        clearTimeout(timer);
        resolve(msg);
      });
      try {
        this._port.postMessage(message);
      } catch {
        clearTimeout(timer);
        resolve(null);
      }
    });
  }

  /** Fire-and-forget send (chunks/health/captions don't need a per-message await). */
  post(message) {
    if (!this._port) return false;
    try {
      this._port.postMessage(message);
      return true;
    } catch {
      return false;
    }
  }

  startSession(record) {
    return this._request(buildStartMessage(record), 'started');
  }

  sendChunk(sessionId, part, dataB64) {
    return this.post(buildChunkMessage(sessionId, part, dataB64));
  }

  closeSession(sessionId, record) {
    return this._request(buildCloseMessage(sessionId, record), 'closed');
  }
}

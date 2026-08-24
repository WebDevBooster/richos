/**
 * RichOS local service — native-messaging host handlers (the drop-zone WRITER + watchdog state).
 *
 * This is the half of the native host that has nothing to do with stdio, so it is node-testable:
 * feed it decoded messages, assert what lands in the drop zone. It writes the SAME session
 * directory contract (§3) the sync helper produces today — so switching the extension from the
 * Downloads hop to the service is a transport change, not a format change.
 *
 * It also holds the outside-the-browser watchdog STATE: last-heartbeat per open session, so a
 * browser that stops talking (crash/hang/OOM) is caught by `checkWatchdog` in seconds, and any
 * still-open session is finalized `interrupted` + alarmed on pipe EOF (the system architecture §6.3).
 */

import fs from 'node:fs';
import path from 'node:path';
import { upgradeRecord } from './contract.js';
import { decideClaimOnDisk, markPromotable, PROMOTE_AFTER_MS } from './coordination.js';
import { log } from './log.js';

const HEARTBEAT_STALL_MS = 10000;

export class SessionSink {
  /** @param {string} zone drop-zone root */
  constructor(zone) {
    this.zone = zone;
    /** @type {Map<string, {dir: string, lastHeartbeat: number, lastAudioExt: string}>} */
    this.open = new Map();
    fs.mkdirSync(zone, { recursive: true });
  }

  _dir(sessionId) {
    return path.join(this.zone, sessionId);
  }

  /**
   * Handle one decoded message. Returns a response to send back (or null), possibly carrying a
   * `_trigger` sessionId the stdio host should hand to the pipeline.
   * @param {any} msg
   * @param {number} [now]
   * @returns {any}
   */
  handle(msg, now = Date.now()) {
    switch (msg?.type) {
      case 'hello':
        return { type: 'ready', product: 'richos-service', zone: this.zone };

      case 'claim': {
        // Surface-agnostic ownership handshake (§5.4). The drop zone is the authority: a companion
        // or the extension asks "may I own this call, or must I stand down to avoid a double?".
        const decision = decideClaimOnDisk(
          this.zone,
          {
            surface: msg.surface,
            sessionId: msg.sessionId,
            captureKind: msg.captureKind,
            processHint: msg.processHint,
          },
          { now },
        );
        return { type: 'claim-result', sessionId: msg.sessionId, ...decision };
      }

      case 'session-start': {
        const record = upgradeRecord({ ...msg.record });
        const sessionId = record.sessionId || record.dir;
        if (!sessionId) return { type: 'error', error: 'session-start without a sessionId' };
        const dir = this._dir(sessionId);
        fs.mkdirSync(dir, { recursive: true });
        record.status = 'open';
        fs.writeFileSync(path.join(dir, 'session.json'), `${JSON.stringify(record, null, 2)}\n`);
        this.open.set(sessionId, { dir, lastHeartbeat: now, lastAudioExt: msg.audioExt || 'webm' });
        log.info(`session-start ${sessionId} -> ${dir}`);
        return { type: 'started', sessionId };
      }

      case 'audio-chunk': {
        const s = this.open.get(msg.sessionId);
        if (!s) return { type: 'error', error: `audio-chunk for unknown session ${msg.sessionId}` };
        const ext = msg.ext || s.lastAudioExt || 'webm';
        const part = Number.isInteger(msg.part) ? msg.part : 0;
        const file = path.join(s.dir, `audio-part-${String(part).padStart(2, '0')}.${ext}`);
        fs.appendFileSync(file, Buffer.from(msg.dataB64 || '', 'base64'));
        s.lastHeartbeat = now;
        return msg.ack === false ? null : { type: 'chunk-ack', sessionId: msg.sessionId, part };
      }

      case 'health': {
        const s = this.open.get(msg.sessionId);
        if (!s) return { type: 'error', error: `health for unknown session ${msg.sessionId}` };
        fs.appendFileSync(path.join(s.dir, 'health.ndjson'), `${JSON.stringify(msg.line)}\n`);
        s.lastHeartbeat = now;
        return null;
      }

      case 'caption': {
        const s = this.open.get(msg.sessionId);
        if (!s) return { type: 'error', error: `caption for unknown session ${msg.sessionId}` };
        fs.appendFileSync(path.join(s.dir, 'captions.ndjson'), `${JSON.stringify(msg.line)}\n`);
        return null;
      }

      case 'heartbeat': {
        const s = this.open.get(msg.sessionId);
        if (s) s.lastHeartbeat = now;
        return { type: 'heartbeat-ack', sessionId: msg.sessionId };
      }

      case 'session-close': {
        const s = this.open.get(msg.sessionId);
        const dir = s ? s.dir : this._dir(msg.sessionId);
        let record = null;
        try {
          record = JSON.parse(fs.readFileSync(path.join(dir, 'session.json'), 'utf8'));
        } catch {
          record = msg.record ? { ...msg.record } : null;
        }
        if (!record) return { type: 'error', error: `session-close for unknown session ${msg.sessionId}` };
        // Merge any final accounting the extension sends (audio parts/bytes, health tally, captions).
        if (msg.record) Object.assign(record, msg.record);
        record = upgradeRecord(record);
        record.status = 'closed';
        record.endedAt = record.endedAt || now;
        fs.writeFileSync(path.join(dir, 'session.json'), `${JSON.stringify(record, null, 2)}\n`);
        this.open.delete(msg.sessionId);
        log.info(`session-close ${msg.sessionId} -> pipeline queued`);
        return { type: 'closed', sessionId: msg.sessionId, _trigger: msg.sessionId };
      }

      default:
        return { type: 'error', error: `unknown message type: ${msg?.type}` };
    }
  }

  /**
   * The outside-the-browser watchdog: any open session whose last heartbeat is stale is a LOUD
   * alarm the browser cannot suppress (catches a tab/browser crash mid-call).
   * @param {number} [now]
   * @returns {{sessionId: string, staleMs: number}[]}
   */
  checkWatchdog(now = Date.now()) {
    const alarms = [];
    for (const [sessionId, s] of this.open) {
      const staleMs = now - s.lastHeartbeat;
      if (staleMs > HEARTBEAT_STALL_MS) {
        alarms.push({ sessionId, staleMs });
        log.alarm(`${sessionId} — the browser stopped heart-beating (${staleMs} ms) — capture may be dead`, {
          staleMs,
        });
        // Failover promotion (§5.4): past the promote threshold, mark the session promotable ON DISK
        // (once) so ANY companion can take over the call from the drop zone alone — the browser can't
        // suppress this because it is written by the outside-the-browser service.
        if (staleMs > PROMOTE_AFTER_MS && !s.promotableMarked) {
          if (markPromotable(this.zone, sessionId, now)) {
            s.promotableMarked = true;
            log.alarm(`${sessionId} — marked PROMOTABLE — a companion may supersede this call`, { staleMs });
          }
        }
      }
    }
    return alarms;
  }

  /**
   * On pipe EOF (browser quit/crash), finalize every still-open session as `interrupted` so a lost
   * call is PRESENT on disk (a loud anomaly), never an absence nobody notices.
   * @param {number} [now]
   * @returns {string[]} the session ids finalized
   */
  finalizeOnEof(now = Date.now()) {
    const finalized = [];
    for (const [sessionId, s] of this.open) {
      try {
        const record = JSON.parse(fs.readFileSync(path.join(s.dir, 'session.json'), 'utf8'));
        record.status = 'interrupted';
        record.endedAt = now;
        record.notes = record.notes || [];
        record.notes.push('finalized as interrupted by the native host on pipe EOF (browser closed/crashed mid-call)');
        // Failover (§5.4): an interrupted browser call may still be ongoing — mark it promotable so a
        // companion can supersede it and keep capturing through the browser's death.
        record.ownership = record.ownership || {};
        record.ownership.promotable = true;
        record.ownership.staleSince = now;
        fs.writeFileSync(path.join(s.dir, 'session.json'), `${JSON.stringify(record, null, 2)}\n`);
        finalized.push(sessionId);
        log.alarm(`${sessionId} — browser pipe closed while the call was still OPEN — finalized interrupted`);
      } catch (err) {
        log.error(`failed to finalize ${sessionId} on EOF: ${String(err.message || err)}`);
      }
    }
    this.open.clear();
    return finalized;
  }
}

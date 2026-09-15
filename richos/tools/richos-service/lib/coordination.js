/**
 * RichOS local service — cross-surface capture COORDINATION (the system architecture §5.4, P4).
 *
 * When both the Chrome extension (browser-tab capture) and a desktop companion (system-audio
 * capture) are live, a browser call would otherwise be captured by BOTH -> a duplicate. This module
 * is the single, SURFACE-AGNOSTIC authority that guarantees exactly one surface owns a given call,
 * and that a companion PROMOTES to take over if a browser-owned call goes dark (browser crash/hang).
 *
 * It is built in the SHARED layer (the service), not duplicated per surface: the extension consults
 * it over native messaging (core/native-host-client.js), and a companion — macOS today, Windows
 * later — consults it via the `claim` / `failover-scan` CLI. It is generic over companion type by
 * construction: it reasons about capture SCOPE ('browser-tab' vs 'system' vs 'process:<app>'), never
 * about a specific OS.
 *
 * The AUTHORITATIVE state is the drop zone on disk (the same "absence made present on disk" doctrine
 * the rest of the system uses): every surface writes its session.json at call START with status
 * 'open' + an `ownership` block, so any process can read the live set. The pure decision functions
 * below take plain descriptors so they are deterministically node-testable; the fs layer at the
 * bottom builds those descriptors from the drop zone.
 */

import fs from 'node:fs';
import path from 'node:path';
import { CAPTURE_SOURCE } from './contract.js';

/** Capture SCOPE — what a surface's RIGHT channel is recording. Generic over OS/companion type. */
export const CAPTURE_KIND = {
  browserTab: 'browser-tab', // extension: one browser tab's playback
  system: 'system', // companion: all system output (Granola-parity, includes browser + every app)
  process: 'process', // companion: scoped to one app's audio (process-loopback / per-app tap)
};

/** A live session is one still capturing (status 'open') whose heartbeat is fresh. */
export const CLAIM_STALE_MS = 15000;
/** After this much heartbeat silence, a browser-owned call is a promotion candidate. */
export const PROMOTE_AFTER_MS = 12000;

/**
 * Preference rank — higher wins a conflict because it produces the RICHER session. The extension's
 * browser-tab capture is richest (clean 2-channel separation + platform captions + speaker names),
 * so it owns browser calls; a per-app companion scope beats all-system; all-system is the coverage
 * net of last resort (architecture §5.4 "rule of preference").
 * @param {string} kind
 */
export function preferenceRank(kind) {
  switch (kind) {
    case CAPTURE_KIND.browserTab:
      return 3;
    case CAPTURE_KIND.process:
      return 2;
    case CAPTURE_KIND.system:
      return 1;
    default:
      return 0;
  }
}

/** Case-insensitive process-hint match (e.g. "Google Chrome" vs "google chrome"). */
function hintMatch(a, b) {
  if (!a || !b) return false;
  return String(a).trim().toLowerCase() === String(b).trim().toLowerCase();
}

/**
 * Would two captures record the SAME audio (i.e. is there a double-capture risk)? Symmetric.
 * - 'system' overlaps everything (all-output includes every app + every browser tab).
 * - 'browser-tab' overlaps 'system'; and overlaps 'process:<browser>' when the process is that browser.
 * - 'process:X' overlaps 'process:Y' only when X === Y; overlaps 'system' always.
 * @param {{kind:string, processHint?:string}} a
 * @param {{kind:string, processHint?:string}} b
 */
export function scopesOverlap(a, b) {
  if (!a || !b) return false;
  if (a.kind === CAPTURE_KIND.system || b.kind === CAPTURE_KIND.system) return true;
  const bt = CAPTURE_KIND.browserTab;
  const pr = CAPTURE_KIND.process;
  if (a.kind === bt && b.kind === bt) return true; // both browser tabs (same machine) — treat as overlap
  if (a.kind === pr && b.kind === pr) return hintMatch(a.processHint, b.processHint);
  // one browser-tab + one process: overlap only if the process IS that browser
  if ((a.kind === bt && b.kind === pr) || (a.kind === pr && b.kind === bt)) {
    return hintMatch(a.processHint, b.processHint);
  }
  return false;
}

/**
 * Decide whether a surface may OWN a call right now, or must stand down (architecture §5.4 handshake).
 *
 * @param {{surface:string, sessionId?:string, captureKind:string, processHint?:string}} req
 * @param {{sessionId:string, surface:string, captureKind:string, processHint?:string,
 *          status:string, lastHeartbeat:number}[]} liveSessions descriptors from the drop zone
 * @param {{now?:number, staleMs?:number}} [opts]
 * @returns {{decision:'own'|'stand-down', reason:string, conflictSessionId?:string,
 *            excludeProcessHint?:string|null, supersede?:string[]}}
 */
export function decideClaim(req, liveSessions = [], opts = {}) {
  const now = opts.now ?? Date.now();
  const staleMs = opts.staleMs ?? CLAIM_STALE_MS;
  const reqScope = { kind: req.captureKind, processHint: req.processHint };

  // Only sessions that are ACTUALLY still capturing count as conflicts: status 'open' and a fresh
  // heartbeat. A stale/interrupted owner is not a live conflict — it is a promotion candidate.
  const live = liveSessions.filter(
    (s) =>
      s.sessionId !== req.sessionId &&
      s.status === 'open' &&
      now - s.lastHeartbeat <= staleMs &&
      scopesOverlap(reqScope, { kind: s.captureKind, processHint: s.processHint }),
  );

  if (live.length === 0) {
    return { decision: 'own', reason: 'no conflicting live capture', supersede: [] };
  }

  const reqRank = preferenceRank(req.captureKind);
  const strongest = live.reduce((a, b) => (preferenceRank(b.captureKind) > preferenceRank(a.captureKind) ? b : a));
  const strongestRank = preferenceRank(strongest.captureKind);

  if (reqRank > strongestRank) {
    // The requester is the richer surface (e.g. the extension arriving after a companion's all-system
    // capture): it owns; the weaker live sessions should stand down.
    return {
      decision: 'own',
      reason: `richer surface (${req.captureKind}) supersedes ${live.length} weaker live capture(s)`,
      supersede: live.map((s) => s.sessionId),
    };
  }

  // Requester is not richer -> stand down. Hand back the owner + the process to exclude so a companion
  // that CAN scope (Windows PID exclude, macOS per-process tap) may exclude rather than fully defer.
  return {
    decision: 'stand-down',
    reason: `${strongest.surface} already owns this call (${strongest.captureKind}); avoid double-capture`,
    conflictSessionId: strongest.sessionId,
    excludeProcessHint: strongest.processHint || null,
  };
}

/**
 * Which owned sessions have gone dark and are candidates for failover PROMOTION (architecture §5.4)? A
 * browser that crashes/hangs mid-call either leaves its session 'interrupted' (the host finalized it
 * on pipe EOF) or 'open' with a stale heartbeat past the promote threshold. Either way the call may
 * still be happening — a companion should take over. Already-transcribed or already-superseded
 * sessions are never promoted.
 *
 * @param {{sessionId:string, surface:string, captureKind:string, processHint?:string, status:string,
 *          lastHeartbeat:number, hasTranscript?:boolean, supersededBy?:string|null}[]} sessions
 * @param {{now?:number, promoteAfterMs?:number}} [opts]
 * @returns {{sessionId:string, surface:string, captureKind:string, processHint?:string,
 *            reason:string, staleMs:number}[]}
 */
export function findPromotable(sessions = [], opts = {}) {
  const now = opts.now ?? Date.now();
  const promoteAfterMs = opts.promoteAfterMs ?? PROMOTE_AFTER_MS;
  const out = [];
  for (const s of sessions) {
    if (s.hasTranscript) continue; // done; nothing to take over
    if (s.supersededBy) continue; // someone already promoted over it
    const staleMs = now - s.lastHeartbeat;
    const interrupted = s.status === 'interrupted';
    const staleOpen = s.status === 'open' && staleMs > promoteAfterMs;
    if (interrupted || staleOpen) {
      out.push({
        sessionId: s.sessionId,
        surface: s.surface,
        captureKind: s.captureKind,
        processHint: s.processHint || null,
        reason: interrupted ? 'owner interrupted (browser closed/crashed mid-call)' : `owner heartbeat stale ${staleMs} ms`,
        staleMs,
      });
    }
  }
  return out;
}

/**
 * The ownership block for a companion session that PROMOTES to supersede a dead owner.
 * @param {{deadSessionId:string, surface:string, processHint?:string|null}} p
 */
export function buildPromotionOwnership(p) {
  return { ownerSurface: p.surface, supersedes: p.deadSessionId, processHint: p.processHint ?? null };
}

/** Richness score for the pipeline dedup backstop — captions + clean 2-channel win. */
export function richnessScore(desc) {
  return (desc.captionCount > 0 ? 100 : 0) + preferenceRank(desc.captureKind) + (desc.channels === 2 ? 1 : 0);
}

/** Do two [start,end] windows overlap by at least `minMs`? */
function timeOverlap(a, b, minMs) {
  const ov = Math.min(a.endedAt || Infinity, b.endedAt || Infinity) - Math.max(a.startedAt || 0, b.startedAt || 0);
  return ov >= minMs;
}

/**
 * Pipeline dedup BACKSTOP (architecture §5.4): if a coordination miss produced two sessions that overlap
 * heavily in time, keep the RICHER one for transcription and shadow the other (its audio is retained
 * as backup, never a silent double, never a silent drop).
 * @param {{sessionId:string, captureKind:string, captionCount?:number, channels?:number,
 *          startedAt:number, endedAt?:number}[]} descriptors
 * @param {{minOverlapMs?:number}} [opts]
 * @returns {{keep:string[], shadow:{sessionId:string, preferredSessionId:string, reason:string}[]}}
 */
export function dedupeOverlapping(descriptors = [], opts = {}) {
  const minOverlapMs = opts.minOverlapMs ?? 30000;
  const items = descriptors.map((d) => ({
    ...d,
    captionCount: d.captionCount || 0,
    channels: d.channels || 2,
    score: richnessScore({ captionCount: d.captionCount || 0, captureKind: d.captureKind, channels: d.channels || 2 }),
  }));
  const keep = new Set(items.map((i) => i.sessionId));
  const shadow = [];
  for (let i = 0; i < items.length; i += 1) {
    for (let j = i + 1; j < items.length; j += 1) {
      const a = items[i];
      const b = items[j];
      if (!keep.has(a.sessionId) || !keep.has(b.sessionId)) continue;
      if (!timeOverlap(a, b, minOverlapMs)) continue;
      const [win, lose] = a.score >= b.score ? [a, b] : [b, a];
      keep.delete(lose.sessionId);
      shadow.push({
        sessionId: lose.sessionId,
        preferredSessionId: win.sessionId,
        reason: `overlaps ${win.sessionId} in time; ${win.sessionId} is richer (score ${win.score} vs ${lose.score}) — kept as backup audio, not transcribed as a duplicate`,
      });
    }
  }
  return { keep: [...keep], shadow };
}

// ============================ fs layer — build descriptors from disk ============================

/** Map a session.json record to a coordination descriptor (PURE). */
export function sessionDescriptor(record, extra = {}) {
  const source = record?.ownership?.ownerSurface || record?.capture?.source || 'unknown';
  const target = record?.capture?.captureTarget || '';
  let captureKind = CAPTURE_KIND.system;
  if (source === CAPTURE_SOURCE.extension) captureKind = CAPTURE_KIND.browserTab;
  else if (typeof target === 'string' && target.startsWith('process:')) captureKind = CAPTURE_KIND.process;
  else captureKind = CAPTURE_KIND.system;
  return {
    sessionId: record?.sessionId || record?.dir || extra.sessionId || null,
    surface: source,
    captureKind,
    processHint: record?.ownership?.processHint || null,
    status: record?.status || 'unknown',
    startedAt: Number(record?.startedAt || 0),
    endedAt: record?.endedAt ? Number(record.endedAt) : null,
    lastHeartbeat: extra.lastHeartbeat ?? Number(record?.endedAt || record?.startedAt || 0),
    hasTranscript: !!extra.hasTranscript,
    supersededBy: record?.ownership?.supersededBy || null,
    captionCount: Number(record?.captions?.count || 0),
    channels: 2,
  };
}

/** Last absolute `t` in a session's health.ndjson (its freshest heartbeat), or null. */
function lastHealthT(sessionDir) {
  try {
    const raw = fs.readFileSync(path.join(sessionDir, 'health.ndjson'), 'utf8').trim();
    if (!raw) return null;
    const lastLine = raw.split(/\r?\n/).pop();
    const t = JSON.parse(lastLine)?.t;
    return Number.isFinite(t) ? Number(t) : null;
  } catch {
    return null;
  }
}

/** Build coordination descriptors for every session directory in the drop zone. */
export function readSessions(zone) {
  if (!fs.existsSync(zone)) return [];
  const out = [];
  for (const entry of fs.readdirSync(zone, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('_') || entry.name.startsWith('.')) continue;
    const dir = path.join(zone, entry.name);
    let record;
    try {
      record = JSON.parse(fs.readFileSync(path.join(dir, 'session.json'), 'utf8'));
    } catch {
      continue;
    }
    const hasTranscript = fs.existsSync(path.join(dir, 'transcript.md'));
    const healthT = lastHealthT(dir);
    out.push(sessionDescriptor(record, {
      hasTranscript,
      lastHeartbeat: healthT ?? Number(record?.endedAt || record?.startedAt || 0),
    }));
  }
  return out;
}

/** Disk-backed claim decision — the surface-agnostic authority a companion/extension consults. */
export function decideClaimOnDisk(zone, req, opts = {}) {
  return decideClaim(req, readSessions(zone), opts);
}

/** Disk-backed promotion scan — what a companion polls to know a browser-owned call went dark. */
export function findPromotableOnDisk(zone, opts = {}) {
  return findPromotable(readSessions(zone), opts);
}

/**
 * Mark a session promotable on disk (a stale/interrupted owner) so any companion can detect the
 * failover opportunity from the drop zone alone. Idempotent.
 * @param {string} zone
 * @param {string} sessionId
 * @param {number} now
 */
export function markPromotable(zone, sessionId, now = Date.now()) {
  const file = path.join(zone, sessionId, 'session.json');
  try {
    const record = JSON.parse(fs.readFileSync(file, 'utf8'));
    record.ownership = record.ownership || {};
    if (record.ownership.promotable === true) return false;
    record.ownership.promotable = true;
    record.ownership.staleSince = now;
    fs.writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
    return true;
  } catch {
    return false;
  }
}

/** Record on the dead session that a companion has superseded it (closes the failover loop). */
export function markSuperseded(zone, deadSessionId, bySessionId) {
  const file = path.join(zone, deadSessionId, 'session.json');
  try {
    const record = JSON.parse(fs.readFileSync(file, 'utf8'));
    record.ownership = record.ownership || {};
    record.ownership.supersededBy = bySessionId;
    fs.writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
    return true;
  } catch {
    return false;
  }
}

/**
 * RichOS local service — configuration + external-tool resolution.
 *
 * Cross-platform-clean: no Mac-only literals in the resolution logic. Every path is either an
 * env override, a `which`-resolved binary, or a home-relative default computed with `os.homedir()`
 * + `path.join`. The one place that names concrete files (the model filename) derives them from a
 * portable model *id*, so a Windows/Linux host resolves them the same way.
 *
 * Everything the pipeline shells out to (ffmpeg, whisper.cpp) is a native binary — the reason the
 * pipeline lives in this service and not the MV3 extension (the system architecture §4.1).
 */

import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** The richos repo root: tools/richos-service/lib -> repo root is three up. */
export const REPO_ROOT = path.resolve(HERE, '..', '..', '..');

/**
 * The loro drop zone the contract (§3) lives in. Every capture surface writes one session
 * directory here; the pipeline consumes only this. Overridable for tests / alternate loro checkouts.
 * @returns {string}
 */
export function dropZone() {
  return expand(process.env.RICHOS_DROP_ZONE || path.join(REPO_ROOT, 'wiki', 'raw', 'meetings'));
}

/** The idempotent ingest ledger, one JSON line per transcribed session. */
export function ingestLedgerPath(zone = dropZone()) {
  return path.join(zone, '_ingest.jsonl');
}

/** Expand a leading `~` and resolve to absolute. */
export function expand(p) {
  if (!p) return p;
  const resolved = p.startsWith('~') ? path.join(os.homedir(), p.slice(1)) : p;
  return path.resolve(resolved);
}

/**
 * Resolve an external binary: env override first, then PATH via the platform's lookup, then a
 * short list of well-known install locations. Throws with an actionable message if not found.
 * @param {string} name e.g. 'ffmpeg'
 * @param {string} envVar e.g. 'RICHOS_FFMPEG_BIN'
 * @param {string[]} [extraDirs]
 * @returns {string}
 */
export function resolveBinary(name, envVar, extraDirs = []) {
  if (process.env[envVar]) {
    const v = expand(process.env[envVar]);
    if (fs.existsSync(v)) return v;
    throw new Error(`${envVar}=${v} does not exist`);
  }
  const exe = process.platform === 'win32' ? `${name}.exe` : name;
  // PATH lookup, portable: `command -v` on POSIX, `where` on Windows.
  try {
    const finder = process.platform === 'win32' ? 'where' : 'command';
    const args = process.platform === 'win32' ? [exe] : ['-v', exe];
    const out = execFileSync(finder, args, { encoding: 'utf8' }).split(/\r?\n/)[0].trim();
    if (out && fs.existsSync(out)) return out;
  } catch {
    /* fall through to well-known dirs */
  }
  const wellKnown = [
    '/opt/homebrew/bin', // Apple Silicon Homebrew
    '/usr/local/bin', // Intel Homebrew / Linux
    '/usr/bin',
    ...extraDirs,
  ];
  for (const dir of wellKnown) {
    const candidate = path.join(dir, exe);
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(
    `could not find "${name}" — install it or set ${envVar} to its absolute path (searched PATH + ${wellKnown.join(', ')})`,
  );
}

export function ffmpegBin() {
  return resolveBinary('ffmpeg', 'RICHOS_FFMPEG_BIN');
}

/** whisper.cpp ships its CLI as `whisper-cli` (Homebrew bottle) — the benchmarked binary. */
export function whisperBin() {
  return resolveBinary('whisper-cli', 'RICHOS_WHISPER_BIN');
}

/** Default model id per the model benchmark (2026-08-24). */
export const DEFAULT_MODEL = 'large-v3-turbo';

/**
 * Resolve a whisper.cpp GGML model file from a portable model id.
 * @param {string} [modelId]
 * @returns {string} absolute path to the .bin
 */
export function resolveModel(modelId = DEFAULT_MODEL) {
  if (process.env.RICHOS_WHISPER_MODEL) {
    const v = expand(process.env.RICHOS_WHISPER_MODEL);
    if (fs.existsSync(v)) return v;
    throw new Error(`RICHOS_WHISPER_MODEL=${v} does not exist`);
  }
  const file = `ggml-${modelId}.bin`;
  const dirs = [
    process.env.RICHOS_MODEL_DIR ? expand(process.env.RICHOS_MODEL_DIR) : null,
    path.join(os.homedir(), 'Models', 'Whisper'),
    path.join(os.homedir(), '.config', 'open-wispr', 'models'),
    path.join(os.homedir(), '.cache', 'whisper.cpp'),
  ].filter(Boolean);
  for (const dir of dirs) {
    const candidate = path.join(dir, file);
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(
    `could not find whisper model "${modelId}" (${file}) — set RICHOS_WHISPER_MODEL to its path or RICHOS_MODEL_DIR to its folder (searched ${dirs.join(', ')})`,
  );
}

/**
 * Decode settings per channel. These are the benchmark-validated defaults for `large-v3-turbo`
 * (clean, zero hallucination at defaults on the M4). Kept as data so re-transcription and the
 * `large-v3` opt-in tier (P5) can pass different values without touching pipeline code.
 *
 * `-l en` matches the benchmark; `-t 4` matches the perf-core count used there; Metal does the
 * heavy lifting regardless. `-oj` emits per-segment timestamps the merge needs.
 * @param {{model?: string, language?: string, threads?: number, extraArgs?: string[]}} [opts]
 */
export function whisperArgs(opts = {}) {
  const language = opts.language || process.env.RICHOS_WHISPER_LANG || 'en';
  const threads = opts.threads || Number(process.env.RICHOS_WHISPER_THREADS) || 4;
  return [
    '-l', language,
    '-t', String(threads),
    '-oj',
    '-np', // no progress prints — keep stdout clean for logging
    ...(opts.extraArgs || []),
  ];
}

/** How long after a session is marked `closed` before a missing transcript is itself an anomaly. */
export const TRANSCRIPT_SLA_MS = Number(process.env.RICHOS_TRANSCRIPT_SLA_MS) || 10 * 60 * 1000;

/** A transcript with fewer than this many words is "trivial" — a probable ASR failure -> anomaly. */
export const MIN_TRANSCRIPT_WORDS = Number(process.env.RICHOS_MIN_TRANSCRIPT_WORDS) || 3;

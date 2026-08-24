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
 * P5 model-tiering (the system architecture §4.1 + §9-P5). Accuracy/robustness is a function of the
 * host: turbo is the reliable default everywhere; full large-v3 is an OPT-IN "maximum accuracy" tier
 * gated behind repetition-guard decode params (it reproducibly looped at bare defaults — see the
 * benchmark); quantized/small models are the fallback on weak / non-Apple-Silicon / low-RAM hosts.
 *
 * A tier is data — { model, decodeArgs, repetitionGuard } — so re-transcription and the opt-in tier
 * pass different values without touching pipeline code. `decodeArgs` are appended to `whisperArgs`.
 *
 * The repetition-guard decode params for the `max` tier, chosen against the whisper.cpp CLI:
 *   -mc 0    max-context 0 — do NOT condition on previously decoded text (the primary loop fix;
 *            whisper.cpp's equivalent of `condition_on_previous_text=false`). Default is -1 (carry
 *            full context), which is exactly what fed the reproduced 4x repetition loop.
 *   -et 2.4  entropy threshold — a low-entropy (degenerate/repeating) decode fails and falls back.
 *   -lpt -1  logprob threshold — a low-confidence decode fails and falls back.
 *   -nth 0.6 no-speech threshold — silence is dropped rather than hallucinated over.
 * Temperature fallback stays ON (we do NOT pass -nf), so a failed segment is retried hotter. This is
 * the decode half of the guard; `lib/repetition-guard.js` is the model-agnostic post-decode half.
 */
export const MODEL_TIERS = {
  turbo: {
    model: 'large-v3-turbo',
    decodeArgs: [],
    repetitionGuard: true,
    description:
      'DEFAULT. Distilled large-v3; ~3.9 min/call-hour on the M4, ~2 GB RAM, zero hallucination at ' +
      'defaults (benchmark). The reliable everywhere-on-Apple-Silicon choice.',
  },
  max: {
    model: 'large-v3',
    decodeArgs: ['-mc', '0', '-et', '2.4', '-lpt', '-1.0', '-nth', '0.6'],
    repetitionGuard: true,
    description:
      'OPT-IN maximum accuracy. Full large-v3 with repetition-guard decode params (no previous-text ' +
      'conditioning + temperature fallback) AND the post-decode repetition detector. Slower (~17.5 ' +
      'min/call-hour) and GATED: bare-default large-v3 reproducibly hallucinated a 4x repetition loop ' +
      'in the benchmark. Best-in-class on rare proper nouns when the guard is on.',
  },
  'low-resource': {
    model: 'small.en',
    decodeArgs: [],
    repetitionGuard: true,
    description:
      'FALLBACK for weak / non-Apple-Silicon / low-RAM hosts. small.en (clean + fast, no hallucination ' +
      'in the benchmark). Point RICHOS_WHISPER_MODEL at a quantized .bin to run the quantized variant.',
  },
  quantized: {
    model: 'large-v3-turbo-q5_0',
    decodeArgs: [],
    repetitionGuard: true,
    description:
      'Quantized turbo for low-resource Apple Silicon: ~half the RAM/disk of turbo at a small accuracy ' +
      'cost. Requires the quantized .bin (build once with `whisper-quantize`, or point ' +
      'RICHOS_WHISPER_MODEL at it).',
  },
};

/** The tier chosen when nothing is specified. */
export const DEFAULT_TIER = 'turbo';

/**
 * Resolve a tier name OR a raw model id into a concrete { name, model, decodeArgs, repetitionGuard }.
 *
 * - a known tier name -> that tier.
 * - `null`/empty -> the default tier (turbo).
 * - anything else -> a "custom" tier wrapping the raw model id (backward compat with `--model`),
 *   AND if that raw id is bare full large-v3 (not turbo) the repetition-guard decode params are
 *   auto-attached — so full large-v3 can NEVER run through this pipeline unguarded (the gate).
 * @param {string|null|undefined} tier
 * @returns {{name: string, model: string, decodeArgs: string[], repetitionGuard: boolean, description?: string}}
 */
export function resolveTier(tier) {
  const key = tier == null ? '' : String(tier);
  if (!key) return { name: DEFAULT_TIER, ...MODEL_TIERS[DEFAULT_TIER] };
  if (MODEL_TIERS[key]) return { name: key, ...MODEL_TIERS[key] };
  const isBareLargeV3 = /^large-v3(?!-turbo)/.test(key);
  return {
    name: 'custom',
    model: key,
    decodeArgs: isBareLargeV3 ? [...MODEL_TIERS.max.decodeArgs] : [],
    repetitionGuard: true,
    description: isBareLargeV3
      ? `custom model "${key}" — full large-v3 detected; repetition-guard decode params auto-applied (gate)`
      : `custom model "${key}"`,
  };
}

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

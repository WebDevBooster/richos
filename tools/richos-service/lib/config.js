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

import { assertEvidenceOutsideProductRepo } from './workspace/privacy.js';
import { pinFor as pinForModel } from './model-catalog.js';
import {
  classify as classifyModel,
  describe as describeModelFinding,
  readHead as readModelHead,
} from './model-integrity.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** The richos repo root: tools/richos-service/lib -> repo root is three up. */
export const REPO_ROOT = path.resolve(HERE, '..', '..', '..');

/**
 * Where the CEO's corpus lives — the ONE root every piece of his own material hangs off.
 *
 * `LORO_CORPUS` is the same variable the context compiler reads (`loro/lib/layout.js`), on purpose:
 * one corpus, one root, one answer to "where is my stuff". Unset, this falls back to the visible
 * home-directory location the loro structure notes recommend (CEO decision 4) — NOT to the product
 * repo, and never to the product repo.
 *
 * Note the deliberate asymmetry with the compiler, which has no default at all: reading from an
 * unconfigured root silently answers out of the wrong company's memory, while refusing to WRITE would
 * throw away a recording the CEO cannot make again. So the reader refuses and the writer degrades —
 * visibly, to a path he can open in Finder.
 * @returns {string}
 */
export function corpusRoot() {
  return expand(process.env.LORO_CORPUS || DEFAULT_CORPUS_ROOT);
}

/** The recommended corpus location when none is configured (loro structure notes, decision 4). */
export const DEFAULT_CORPUS_ROOT = '~/RichOS/corpus';

/** True when the CEO (or the installer) actually said where his corpus is. */
export function corpusRootConfigured() {
  return Boolean(process.env.LORO_CORPUS);
}

/**
 * The company partition new evidence belongs to — mechanism 2, "the active company"
 * (the loro structure notes). Unset is legitimate and permanent, not an error.
 * @returns {string|null}
 */
export function activeCompany() {
  const v = process.env.RICHOS_ACTIVE_COMPANY;
  return v && v.trim() ? v.trim() : null;
}

/**
 * The evidence tree for the active company, or the unfiled one when nothing is bound.
 *
 * `companies/<id>/evidence/` is the published layout. The unfiled branch is NOT in that tree and is
 * mine: the page has no CEO-level evidence directory, but it also rules that **filing may never
 * block a write** (mechanism 5), and a call that arrives before the CEO has named a company still has
 * to land somewhere he can find. Recorded as a deviation in
 * the loro-corpus defects brief, 2026-08-26.
 * @returns {string}
 */
export function evidenceRoot() {
  const company = activeCompany();
  return company
    ? path.join(corpusRoot(), 'companies', company, 'evidence')
    : path.join(corpusRoot(), 'ceo', 'unfiled', 'evidence');
}

/**
 * The loro drop zone the contract (§3) lives in. Every capture surface writes one session
 * directory here; the pipeline consumes only this. Overridable for tests / alternate corpora.
 *
 * The default used to be `<repo>/wiki/raw/meetings` — the CEO's call recordings and transcripts,
 * inside a repo that ships publicly, while the OAuth token that fetches his Calendar was already
 * refused a repo path. Both halves of that boundary now say the same thing.
 * @returns {string}
 * @throws {Error} if the resolved zone is inside the product repo
 */
export function dropZone() {
  const zone = expand(process.env.RICHOS_DROP_ZONE || path.join(evidenceRoot(), 'meetings'));
  return assertEvidenceOutsideProductRepo(zone, REPO_ROOT, 'call recordings and transcripts');
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

/**
 * P5 model-tiering (the system architecture §4.1 + §9-P5). Accuracy/robustness is a function of the
 * host: the quantized turbo is the shipping default everywhere; full turbo and full large-v3 are
 * OPT-IN accuracy tiers; small.en is the fallback on weak / non-Apple-Silicon / low-RAM hosts.
 *
 * THE DEFAULT IS `quantized` SINCE 2026-09-10 — CEO decision page §10, decided by Rich from
 * `docs/measurements/whisper-model-choice-2026-09-10/`. Memory decided it: 884,981,760 B peak RSS
 * at call length against full turbo's 2,014,101,504 B, a factor of 2.28, stable across corpus
 * renders and flags. Two things pushed the same way — full turbo duplicated a 17-word sentence at
 * call length under `-mc 0` deterministically and the repetition guard KEEPS it, where q5_0 on
 * identical audio and identical argv emitted it once; and 574,041,195 B against 1,624,555,275 B is
 * what a new user downloads before the product works at all. What full turbo wins is proper nouns,
 * on both renders, by 3 then 6 of 66 — which is why the `turbo` tier below is still here.
 *
 * TIER IDS NEVER CHANGE MEANING. `turbo` is full `large-v3-turbo` today exactly as it was before
 * this ruling; what moved is which tier `DEFAULT_TIER` names. A `session.json` written last month
 * recording `tier: "turbo"` still means the same weights it meant when it was written, which is the
 * whole reason the default moved by re-pointing a pointer rather than by re-defining a name.
 *
 * A tier is data — { model, decodeArgs, repetitionGuard } — so re-transcription and the opt-in tier
 * pass different values without touching pipeline code. `decodeArgs` are appended to `whisperArgs`.
 *
 * DECODE CONTEXT IS NOW A PIPELINE-WIDE INVARIANT, NOT TIER DATA (`MAX_CONTEXT_TOKENS`, below).
 * Until 2026-08-29 `-mc 0` lived ONLY in this `max` tier's `decodeArgs`, so the two tiers that
 * actually ship (`turbo`, `quantized`) ran at whisper.cpp's `-mc -1` — carry ALL previous decoded
 * text — which is precisely the accumulation that destroyed up to 44.1% of a 92-minute channel
 * (the real-audio brief 2026-08-29 §0b/§4.3). The fix was written down in this file and withheld
 * from the tiers that ship. It is now structural so no tier can omit it again.
 *
 * The other three params this tier used to carry — `-et 2.4 -lpt -1.0 -nth 0.6` — are whisper-cli's
 * OWN defaults (verify with `whisper-cli --help`), so they changed nothing. Measured 2026-08-29:
 * a full 92-minute q5_0 run with `-mc 0` alone and one with `-mc 0 -et 2.4 -lpt -1.0 -nth 0.6`
 * produced BYTE-IDENTICAL JSON (sha256 07ad0d16b1e94e99bb66da32a6a1588701aed9629c4c2e7653c6791e87ae961b).
 * They are dropped rather than left in place implying a defense that was never running.
 *
 * AND `-nth` IS NOT A DEFENSE AT ANY VALUE, NOT ONLY AT ITS DEFAULT — measured 2026-08-29 (second
 * pass), because "no-speech-thold" is the parameter anyone looking at whisper hallucinating over
 * silence reaches for first, and reaching for it here is a dead end. On a 700 s slice of a real
 * host channel holding 14 segments emitted over MEASURED SILENCE, six full decodes at
 * `-nth 0.01 / 0.1 / 0.2 / 0.4 / 0.6 / 0.9` produced SIX BYTE-IDENTICAL JSON files (sha256
 * e8f7998b56d3740ad8d0c662db049b2ba83206a74b305054bbe6c51f18060d16). The parameter is inert in this
 * whisper.cpp build across a 90x range. `-lpt 0.0` — the other arm of whisper.cpp's no-speech
 * branch — removed ONE of the 14 for +90% wall clock (24.9 s -> 47.4 s) and perturbed the real
 * decode as well (+1 segment, +8 words), which is a cost with no defensible benefit.
 *
 * So the silence-fabrication class is handled POST-DECODE, in `repetition-guard.js` class 4, and
 * NO tier value changes for it. This paragraph exists so the next person to meet 60% of a channel
 * filled with "Thank you." does not spend a day on a decode flag that cannot help.
 */
export const MODEL_TIERS = {
  turbo: {
    model: 'large-v3-turbo',
    decodeArgs: [],
    repetitionGuard: true,
    description:
      'OPT-IN, for proper-noun fidelity. Was the default until 2026-09-10 (CEO decision page ' +
      '§10); it is no longer what a user gets and it is NOT deleted. Fetch it with ' +
      '`richos-service fetch-model large-v3-turbo` and select it with `--tier turbo`. It renders ' +
      '47 and 48 of 66 proper nouns across two corpus renders against the default q5_0 tier\'s 44 ' +
      'and 42 — the one axis it wins on both renders. It costs 2,014,101,504 B peak RSS at call ' +
      'length against 884,981,760 B, and 1,624,555,275 B on disk against 574,041,195 B. And on ' +
      'render A of the invented corpus it emitted one 17-word sentence of the script TWICE, ' +
      'deterministically, at `-mc 0`, at call length, and repetition-guard.js does not remove it ' +
      '(the model-choice measurement 2026-09-10, §3). ' +
      'Distilled large-v3; ~3.9 min/call-hour on the M4. NO hallucination on the ' +
      '213 s benchmark sample — but NOT hallucination-free in general: on an 11-minute NOISY sample ' +
      'it fabricated a running list numeral onto 59 of 88 segments (65% of the call), ' +
      'deterministically in 3/3 runs (measured 2026-08-26, the q5 call-transcription brief). q5_0 did ' +
      'not reproduce it on the same audio. As of 2026-08-28 repetition-guard.js DETECTS that class ' +
      'and reports it loudly, but does NOT repair it — the fabricated span contains real speech, so ' +
      'the markers stay in the transcript and re-transcription is the remedy. On 92 minutes of REAL ' +
      'audio at the old -mc -1 default it replaced 290 s of real speech with one phrase 203 times; ' +
      'at MAX_CONTEXT_TOKENS=0 the same file yields ZERO loop findings on both channels (2026-08-29).',
  },
  max: {
    model: 'large-v3',
    decodeArgs: [],
    repetitionGuard: true,
    description:
      'OPT-IN maximum accuracy. Full large-v3. Slower (~17.5 min/call-hour). Bare-default large-v3 ' +
      'reproducibly hallucinated a 4x repetition loop in the 2026-08-24 benchmark; the fix for that ' +
      '(-mc 0, no previous-text conditioning) is no longer this tier\'s private decodeArg — it is the ' +
      'pipeline-wide MAX_CONTEXT_TOKENS default every tier gets. Best-in-class on rare proper nouns.',
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
      'DEFAULT since 2026-09-10 (CEO decision page §10). Quantized turbo. 574,041,195 B on disk vs ' +
      'full turbo 1,624,555,275 B (-1,050,514,080 B); 884,981,760 B peak RSS at call length vs ' +
      '2,014,101,504 B (-56.1%) and 1,859,256,320 B vs 2,817,949,696 B (-34.0%) on 92 minutes. ' +
      'Post-guard WER on two independent renders of the invented 6-call corpus: 2.78% and 2.94%, ' +
      'against full turbo\'s 3.78% and 2.99% — ahead on both, but by 1.00 point on one render and ' +
      '0.05 on the other, so NOTHING here is decided on that column. Zero loop findings and zero ' +
      'fabricated timeline on 184.6 minutes of real audio, same as full turbo, at ' +
      'MAX_CONTEXT_TOKENS=0. It costs 7.0% wall clock on long form (498.7 s vs 466.1 s for both ' +
      '92-minute channels) and 3 to 6 proper nouns of 66. Measured 2026-09-10, ' +
      'docs/measurements/whisper-model-choice-2026-09-10/. The earlier 2026-08-29 result that put ' +
      'this model far WORSE than full turbo (44.1% of a channel destroyed against 8.6%) was ' +
      'measured at the old -mc -1 and is superseded: at MAX_CONTEXT_TOKENS=0 those same two ' +
      'numbers are 0.0% and 0.0%.',
  },
};

/**
 * The tier chosen when nothing is specified — and, through DEFAULT_MODEL below, the ONE place the
 * shipping model is decided. Moved from `turbo` to `quantized` on 2026-09-10 (CEO decision page §10).
 */
export const DEFAULT_TIER = 'quantized';

/**
 * The default model id. DERIVED from the default tier, never stated a second time.
 *
 * It used to be its own literal — `'large-v3-turbo'` — sitting 90 lines above a tier table that
 * happened to name the same string. Two declarations that agree today are one edit away from a
 * default that depends on which consumer you ask: `transcribeChannel()` reads this, `runPipeline()`
 * reads the tier, and nothing made them agree except that both had been written by someone who
 * remembered the other. Deriving it makes disagreement impossible rather than merely unlikely.
 */
export const DEFAULT_MODEL = MODEL_TIERS[DEFAULT_TIER].model;

/**
 * Resolve a tier name OR a raw model id into a concrete { name, model, decodeArgs, repetitionGuard }.
 *
 * - a known tier name -> that tier.
 * - `null`/empty -> the default tier (DEFAULT_TIER, `quantized` since 2026-09-10).
 * - anything else -> a "custom" tier wrapping the raw model id (backward compat with `--model`).
 *
 * THE GATE MOVED, IT DID NOT GO AWAY. This function used to auto-attach `-mc 0` to a raw bare
 * `large-v3` so full large-v3 could never run unguarded — while leaving every OTHER model, including
 * the two that actually ship, to run with full context carry-over. That got it exactly backwards:
 * the failure is a property of long-form decoding, not of one model id. `-mc 0` is now emitted by
 * `whisperArgs()` for every model and every tier (`MAX_CONTEXT_TOKENS`), so the gate holds for
 * `large-v3` AND for everything else, and there is nothing left here to forget.
 * @param {string|null|undefined} tier
 * @returns {{name: string, model: string, decodeArgs: string[], repetitionGuard: boolean, description?: string}}
 */
export function resolveTier(tier) {
  const key = tier == null ? '' : String(tier);
  if (!key) return { name: DEFAULT_TIER, ...MODEL_TIERS[DEFAULT_TIER] };
  if (MODEL_TIERS[key]) return { name: key, ...MODEL_TIERS[key] };
  return {
    name: 'custom',
    model: key,
    decodeArgs: [],
    repetitionGuard: true,
    description: `custom model "${key}" — decode context is capped at MAX_CONTEXT_TOKENS for every model`,
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
  const dirs = modelSearchDirs();
  for (const dir of dirs) {
    const candidate = path.join(dir, file);
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(
    `could not find whisper model "${modelId}" (${file}) — set RICHOS_WHISPER_MODEL to its path or RICHOS_MODEL_DIR to its folder (searched ${dirs.join(', ')})`,
  );
}

/**
 * Resolve a model file AND refuse the ones that are visibly not the model.
 *
 * `resolveModel` above answers "the first file with this name that exists", which is a directory
 * listing wearing the word resolve. A truncated leftover, or an HTML error page somebody saved as
 * `ggml-small.en.bin`, is the answer it gives, and whisper.cpp then fails somewhere far away with
 * something inscrutable. This function walks the SAME directories in the SAME order and skips a
 * candidate that fails the cheap check — size and GGML magic against the pin — so a good copy in a
 * later directory still wins, and the error, when there is one, names what was actually found.
 *
 * CHEAP, NOT CRYPTOGRAPHIC, AND THAT IS DELIBERATE. Hashing 1.6 GB on every resolve would put
 * seconds onto every transcription. The sha256 is the FETCH path's guarantee (`model-fetch.js`):
 * nothing reaches this directory under a model's name without having hashed correctly first. Pass
 * `deep` to `inspectFile` when you want the full check on demand — `richos-service models` does.
 *
 * `resolveModel` is left exactly as it was: it is on the transcription hot path and several call
 * sites depend on its behaviour. This is the additive, opt-in form.
 *
 * @param {string} [modelId]
 * @returns {{path: string, pin: object|null, rejected: Array<{path: string, message: string}>}}
 */
export function resolveModelChecked(modelId = DEFAULT_MODEL) {
  const pin = pinForModel(modelId);
  if (process.env.RICHOS_WHISPER_MODEL) {
    const v = expand(process.env.RICHOS_WHISPER_MODEL);
    if (!fs.existsSync(v)) throw new Error(`RICHOS_WHISPER_MODEL=${v} does not exist`);
    // An explicit override is the operator saying "use this file". It is checked and reported on,
    // but never silently replaced by something else — overriding is the whole point of an override.
    return { path: v, pin: pin || null, rejected: [] };
  }
  const file = `ggml-${modelId}.bin`;
  const dirs = modelSearchDirs();
  const rejected = [];
  for (const dir of dirs) {
    const candidate = path.join(dir, file);
    if (!fs.existsSync(candidate)) continue;
    if (!pin) return { path: candidate, pin: null, rejected }; // unpinned: nothing to check against
    const bytes = fs.statSync(candidate).size;
    const head = readModelHead(candidate);
    const verdict = classifyModel({ exists: true, bytes, head, sha256: null, pin });
    if (verdict.ok) return { path: candidate, pin, rejected };
    rejected.push({ path: candidate, message: describeModelFinding(verdict, { file: candidate, context: 'disk' }) });
  }
  const tail = rejected.length
    ? ` Files with that name WERE found and rejected:\n  - ${rejected.map((r) => r.message).join('\n  - ')}`
    : ` (searched ${dirs.join(', ')})`;
  throw new Error(
    `could not find a usable whisper model "${modelId}" (${file}) — set RICHOS_WHISPER_MODEL to its path or RICHOS_MODEL_DIR to its folder.${tail}`,
  );
}

/** The model search path, in order. One definition, shared by both resolvers. */
export function modelSearchDirs() {
  return [
    process.env.RICHOS_MODEL_DIR ? expand(process.env.RICHOS_MODEL_DIR) : null,
    path.join(os.homedir(), 'Models', 'Whisper'),
    path.join(os.homedir(), '.config', 'open-wispr', 'models'),
    path.join(os.homedir(), '.cache', 'whisper.cpp'),
  ].filter(Boolean);
}

/**
 * How many previously-decoded text tokens whisper.cpp may condition the next window on (`-mc`).
 *
 * ZERO, on every tier and every model, because accumulated decode context is THE long-form failure
 * mechanism — measured, not inferred (real-audio brief 2026-08-29; the fix run 2026-08-29):
 *
 *   large-v3-turbo-q5_0, 92-minute channel `me`, share of the timeline inside a fabricated
 *   repetition span, as a function of -mc:
 *     -mc 0    0 loop findings      0.0 s      0.0%      249 s wall
 *     -mc 16   0 loop findings      0.0 s      0.0%      387 s
 *     -mc 32   3 loop findings     44.0 s      0.8%      339 s
 *     -mc 64   3 loop findings     64.0 s      1.2%      462 s
 *     -mc 128 14 loop findings    358.0 s      6.5%      714 s
 *     -mc -1  16 loop findings  2,444.0 s     44.1%      469 s   <- the shipped default until today
 *
 *   large-v3-turbo on the same channel: -mc 0 -> 0 findings; -mc 32 -> 4 findings / 162.0 s / 2.9%;
 *   -mc -1 -> 12 findings / 473.8 s / 8.6%, including 290 s of real speech replaced by
 *   "We're going to take a moment." 203 times.
 *
 * So the failure ONSET on this corpus is between 16 and 32 carried tokens, on BOTH models, and it
 * grows monotonically to catastrophic at full context. 0 is chosen over 16 for the margin: 16 held
 * but sits one step from the first observed corruption, and it was slower (387 s vs 249 s).
 *
 * This is NOT free, and SINCE 2026-09-10 THE COST IS MEASURED — the sentence that used to sit here
 * saying it was not is superseded (`docs/measurements/whisper-settings-2026-09-10/`). On the 6-call
 * invented corpus, where a true WER exists because the script IS the reference:
 *
 *   proper nouns rendered exactly, of 66:   -mc 0   46 (69.70%)
 *                                           -mc -1  49 (74.24%)
 *                                           -mc 64 + carried entity prompt  55 (83.33%)
 *   short-call WER:                         -mc 0   2.89%   -mc -1  2.78%   -mc 64+prompt  2.73%
 *
 * So the price of this invariant is NAME SPELLING, not accuracy at brevity, and it is about 9
 * proper nouns in 66. What that costs to buy back, on the same day and the same build, is 3.3% of a
 * 92-minute timeline filled with fabricated repetition at `-mc 64` — against 0.0% here.
 *
 * AND THE ESCAPE THAT LOOKED AVAILABLE IS NOT ONE. `--prompt` (with or without
 * `--carry-initial-prompt`) is BYTE-IDENTICAL to passing no prompt at all while this is 0: a zero
 * text-context budget leaves no room for the prompt tokens. Entity biasing and long-form fabrication
 * are the same knob, not two. Do not add `--prompt` here expecting it to do anything.
 *
 * `RICHOS_WHISPER_MAX_CONTEXT` is the escape hatch; set it to -1 to restore whisper.cpp's own
 * behavior, which on 92 minutes of real audio is 7.8% of the channel replaced by one sentence.
 */
export const MAX_CONTEXT_TOKENS = 0;

/**
 * Decode settings per channel. Kept as data so re-transcription and the `large-v3` opt-in tier (P5)
 * can pass different values without touching pipeline code.
 *
 * EVERY VALUE HERE IS CHOSEN AND EVERY ONE IS MEASURED — the full table, one row per flag this
 * binary accepts including the ones we deliberately leave unset, is
 * `docs/measurements/whisper-settings-2026-09-10/whisper-settings-decisions.md`. The short version:
 *
 *   -l en   byte-identical to `-l auto` on the corpus and 20% FASTER (76 s vs 91 s); pinned rather
 *           than inherited because a mis-detected language changes every word.
 *   -t 4    byte-identical to `-t 8` at the SAME wall clock — the decode is Metal-bound, so threads
 *           past 4 buy nothing. Pinned so the value is ours, not the vendor's idea of this machine.
 *   -mc     see MAX_CONTEXT_TOKENS above. Emitted BEFORE `extraArgs` so a tier or a caller can still
 *           override it (whisper-cli takes the last value).
 *   -oj     per-segment timestamps the merge needs; the plain text output has none.
 *   -np     progress prints would corrupt the log; the transcript is read from the JSON file.
 *   -fa     FLASH ATTENTION, and it is passed EXPLICITLY although whisper.cpp 1.9.1 already defaults
 *           it on. Measured: `-nfa` costs 1.57 WER points (4.46% against 2.89%, insertions 8 -> 29)
 *           and 18% wall clock, and drops proper-noun hits 46 -> 41 of 66. A setting worth 1.57
 *           points is too valuable to hold by inheritance from a default that a formula bump can
 *           flip; passing it is byte-identical today and cannot silently change. If a future
 *           whisper-cli drops the flag this fails LOUDLY at the exec, which is the failure mode to
 *           want — the alternative is a silent accuracy regression nobody would attribute.
 *
 * @param {{model?: string, language?: string, threads?: number, maxContext?: number,
 *          extraArgs?: string[]}} [opts]
 */
export function whisperArgs(opts = {}) {
  const language = opts.language || process.env.RICHOS_WHISPER_LANG || 'en';
  const threads = opts.threads || Number(process.env.RICHOS_WHISPER_THREADS) || 4;
  const maxContext =
    opts.maxContext != null
      ? Number(opts.maxContext)
      : process.env.RICHOS_WHISPER_MAX_CONTEXT != null && process.env.RICHOS_WHISPER_MAX_CONTEXT !== ''
        ? Number(process.env.RICHOS_WHISPER_MAX_CONTEXT)
        : MAX_CONTEXT_TOKENS;
  return [
    '-l', language,
    '-t', String(threads),
    '-mc', String(Number.isFinite(maxContext) ? maxContext : MAX_CONTEXT_TOKENS),
    '-oj',
    '-np', // no progress prints — keep stdout clean for logging
    '-fa', // flash attention, pinned rather than inherited — worth 1.57 WER points, see above
    ...(opts.extraArgs || []),
  ];
}

// ---------------------------------------------------------------------------------------------------
// Workspace source (the system architecture §2/§4.2) — the CEO-information-perimeter ingest layer.
// A NEW MODULE inside this same local service (not a second daemon): reuses the drop-zone discipline,
// the ledger pattern, and — critically — the entities.js/correct.js seam it feeds (§4.5).
// ---------------------------------------------------------------------------------------------------

/**
 * The Workspace evidence zone (§4.2): the immutable raw-evidence store, one dir per SourceItem version,
 * laid out `<zone>/<vendor>/<source>/<sourceItemId>/`. Overridable for tests / alternate corpora.
 * Lives in the user's own CORPUS — not under a RichOS server (§1), and not in the product repo.
 * @returns {string}
 * @throws {Error} if the resolved zone is inside the product repo
 */
export function workspaceZone() {
  const zone = expand(process.env.RICHOS_WORKSPACE_ZONE || path.join(evidenceRoot(), 'workspace'));
  return assertEvidenceOutsideProductRepo(zone, REPO_ROOT, 'Workspace evidence (Calendar/Drive/Gmail)');
}

/** The idempotent Workspace ingest ledger (§4.2), one JSON line per (sourceItemId, vendorEtag). */
export function workspaceLedgerPath(zone = workspaceZone()) {
  return path.join(zone, '_workspace_ingest.jsonl');
}

/**
 * The delta/sync-token store (§4.3): opaque per-(vendor,source) incremental-sync cursors the core
 * persists so it never re-pulls the world. Kept OUT of the evidence tree (it is operational state).
 */
export function workspaceSyncStatePath(zone = workspaceZone()) {
  return path.join(zone, '_sync_state.json');
}

/**
 * Least-privilege READ-ONLY Google scopes (§6.2). Calendar is P1 (smallest privacy surface, temporal
 * skeleton first); Drive/Gmail are wired in P2/P3. `calendar.events.readonly` is the narrowest that
 * lists events. NO write scopes — this layer observes, it never modifies the CEO's cloud.
 */
export const GOOGLE_SCOPES = {
  calendar: 'https://www.googleapis.com/auth/calendar.events.readonly',
  drive: 'https://www.googleapis.com/auth/drive.metadata.readonly', // P2
  mail: 'https://www.googleapis.com/auth/gmail.metadata', // P3, metadata-first (graduated privacy)
};

/** How long after a session is marked `closed` before a missing transcript is itself an anomaly. */
export const TRANSCRIPT_SLA_MS = Number(process.env.RICHOS_TRANSCRIPT_SLA_MS) || 10 * 60 * 1000;

/** A transcript with fewer than this many words is "trivial" — a probable ASR failure -> anomaly. */
export const MIN_TRANSCRIPT_WORDS = Number(process.env.RICHOS_MIN_TRANSCRIPT_WORDS) || 3;

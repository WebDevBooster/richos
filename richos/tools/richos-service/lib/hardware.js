/**
 * WHICH MODEL THIS MACHINE CAN CARRY — the call-transcription half.
 *
 * The Rust voice path's `app/crates/richos-voice/src/hardware.rs` is the other half. Both read
 * `model-costs.json`, both use the speed cache at `~/.config/richos/whisper-speed.json`, and both
 * key it the same way, so a machine calibrated by one surface is calibrated for the other. That
 * is the same discipline `stt.rs` already states for the model directories and the toolchain
 * lock: one machine feeds all three.
 *
 * ## What is different here, and it is not a detail
 *
 * A batch decode has NO per-utterance budget. Nobody is waiting through a pause in a 92-minute
 * transcription, so the live path's 1.000 s ceiling is meaningless on this surface and is not
 * applied. Live dictation and a 92-minute batch job are different problems and are treated as
 * such.
 *
 * The ceiling here is the CEO decision page §10 ruling — `large-v3-turbo-q5_0` — and this module
 * NEVER promotes above it, no matter how much machine is available. §10 decided on post-guard WER
 * on both corpus renders, on fabrication, and on the 1,050,514,080 B a new user downloads before
 * the product works. None of those is a hardware question, and promoting a big machine to full
 * turbo would be re-deciding §10 from a rig that measured none of what §10 decided on.
 *
 * What is new is the other direction. `config.js` has carried a `low-resource` tier since it was
 * written, it names `small.en`, and NOTHING IN THE PRODUCT HAS EVER SELECTED IT — a human has to
 * pass `--tier low-resource`. So a machine that cannot keep up has always been handed exactly the
 * decode a fast one gets. That is the gap this closes.
 *
 * ## `os.freemem()` IS NOT THE MEMORY THIS MACHINE HAS, and the number is not close
 *
 * Measured on the CEO's own Mac, 2026-09-10, at the same moment:
 *
 *     os.freemem()                                          390,676,480 B
 *     free + inactive + speculative + purgeable           6,457,278,464 B
 *
 * A factor of 16.5. Node's `os.freemem()` reports only genuinely FREE pages; on macOS almost
 * everything reclaimable sits in `inactive` and in the compressor. A memory guard built on it
 * would have refused every model on a healthy 24 GB machine with 6.4 GB spare, and it is the
 * obvious call to make.
 *
 * The CEO's standing rule is exactly this: *"NEVER use the default settings of ANY third-party
 * tool/software for ANYTHING. UNLESS the default settings have proven to be the best possible
 * settings."* `os.freemem()` is a vendor default answer to a question, and it is the wrong
 * answer. So this module reads `vm_stat` and sums the same four buckets the Rust path's
 * `host_statistics64` call sums and the measurement record's `machine-state.py` prints — one
 * number, three readers, no drift.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** The measured cost table and the ladders, from the ONE place they live. */
export function loadCosts(file = path.join(HERE, 'model-costs.json')) {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  const models = new Map();
  for (const m of raw.models) models.set(m.id, m);
  return {
    models,
    liveLadder: raw.ladders.live,
    batchLadder: raw.ladders.batch,
    safeRung: raw.safeRung.value,
    liveCeilingSeconds: raw.liveUtteranceCeilingSeconds.value,
    batchRealTimeMultiple: raw.batchRealTimeMultiple.value,
    probe: raw.probe,
    referenceHost: raw.referenceHost,
  };
}

/**
 * Reclaimable-inclusive available memory, in BYTES, from `vm_stat`.
 *
 * NOT `os.freemem()` — see the module header for the 16.5x that costs. Returns `null` rather than
 * a guess when `vm_stat` cannot be read or parsed, so a caller can tell "the machine has little"
 * from "the machine did not answer"; only one of those is a reason to demote.
 *
 * @returns {number|null}
 */
export function availableMemoryBytes() {
  let out;
  try {
    out = execFileSync('vm_stat', { encoding: 'utf8' });
  } catch {
    return null;
  }
  const pageMatch = out.match(/page size of (\d+) bytes/);
  if (!pageMatch) return null;
  const pageSize = Number(pageMatch[1]);
  const bucket = (label) => {
    const m = out.match(new RegExp(`${label}:\\s+(\\d+)\\.`));
    return m ? Number(m[1]) : 0;
  };
  const pages =
    bucket('Pages free') +
    bucket('Pages inactive') +
    bucket('Pages speculative') +
    bucket('Pages purgeable');
  if (!Number.isFinite(pages) || pages <= 0) return null;
  return pages * pageSize;
}

/**
 * What the host says about itself.
 *
 * `RICHOS_HW_TOTAL_MEMORY_BYTES` / `RICHOS_HW_AVAILABLE_MEMORY_BYTES` force the inputs — the same
 * two seams the Rust path carries, and for the same reason: "a low-memory machine demotes" has to
 * be demonstrable on a machine that has plenty, or nobody ever sees it happen.
 */
export function readMachine(env = process.env) {
  const forcedTotal = Number(env.RICHOS_HW_TOTAL_MEMORY_BYTES);
  const forcedAvail = Number(env.RICHOS_HW_AVAILABLE_MEMORY_BYTES);
  const totalBytes = Number.isFinite(forcedTotal) && forcedTotal > 0 ? forcedTotal : os.totalmem();
  const availableBytes = Number.isFinite(forcedAvail) && forcedAvail > 0 ? forcedAvail : availableMemoryBytes();
  return {
    totalBytes,
    // `total` when vm_stat could not answer: a zero would refuse every model including the
    // smallest, and a guard that fails closed onto no transcription at all is worse than none.
    availableBytes: availableBytes == null ? totalBytes : availableBytes,
    availableWasRead: availableBytes != null,
    cores: os.cpus().length,
  };
}

/** Where the shared speed cache lives. The SAME file the Rust voice path reads and writes. */
export function speedCachePath(env = process.env) {
  if (env.RICHOS_WHISPER_SPEED_CACHE) return env.RICHOS_WHISPER_SPEED_CACHE;
  return path.join(os.homedir(), '.config/richos/whisper-speed.json');
}

/**
 * The cache key. MUST match `hardware.rs::cache_key` byte for byte or the two surfaces silently
 * keep separate caches and each pays for its own calibration — which would look exactly like
 * working.
 */
export function cacheKey(binSha256, machine) {
  return `${String(binSha256).slice(0, 12)}|${machine.totalBytes}|${machine.cores}`;
}

/** Measured seconds per model for this key, or an empty object. */
export function loadSpeeds(key, env = process.env) {
  try {
    const root = JSON.parse(fs.readFileSync(speedCachePath(env), 'utf8'));
    const entry = root[key];
    if (entry && entry.models && typeof entry.models === 'object') return entry.models;
  } catch {
    /* no cache yet, or unreadable — an absent measurement, not a slow machine */
  }
  return {};
}

/**
 * This machine's speed relative to the reference host, from one measured model.
 *
 * 1.0 means "as fast as the M4 every reference figure was taken on"; 2.0 means half the speed.
 * Prefers the model with the LARGEST reference time among those measured, because a longer decode
 * carries proportionally less fixed per-invocation overhead and is therefore the better estimator
 * of sustained throughput — which is what a 92-minute job is made of.
 *
 * @returns {{factor: number, from: string}|null}
 */
export function speedFactor(costs, speeds) {
  let best = null;
  for (const [id, secs] of Object.entries(speeds)) {
    const cost = costs.models.get(id);
    if (!cost || !(cost.referenceUtteranceSeconds > 0) || !(secs > 0)) continue;
    if (!best || cost.referenceUtteranceSeconds > best.reference) {
      best = { factor: secs / cost.referenceUtteranceSeconds, from: id, reference: cost.referenceUtteranceSeconds };
    }
  }
  return best ? { factor: best.factor, from: best.from } : null;
}

/**
 * Walk the batch ladder and take the first rung this machine clears.
 *
 * PURE over (costs, machine, speedFactor, installed) so every outcome is decided in a test with
 * no decoder, no audio and no subprocess — the same shape the Rust rule has, and the only way a
 * resolution rule gets tested at all.
 *
 * Gates, in order, and neither carries a constant anyone chose:
 *   1. the model's measured 92-minute peak RSS fits the memory this machine has available;
 *   2. its projected throughput stays under real time.
 *
 * `1.0x real time` is the boundary at which a transcription stops being a batch job and becomes a
 * backlog — a physical line, not a threshold somebody liked. The reference machine sits 21.1x
 * clear of it (0.0473 s of compute per second of audio), which is the right shape for a guard:
 * silent on any healthy machine, loud on one that cannot cope.
 *
 * A `null` speed factor means the machine has never been measured. It does NOT demote: an absence
 * of evidence is not evidence of slowness, and the ceiling is where an unmeasured machine starts.
 *
 * @returns {{tier: string, model: string, basis: string, rejected: object|null, projected: number|null}}
 */
export function resolveBatchModel(costs, machine, factor, installed = () => true) {
  const budget = machine.availableBytes;
  let rejected = null;

  for (let i = 0; i < costs.batchLadder.length; i += 1) {
    const id = costs.batchLadder[i];
    if (!installed(id)) continue;
    const cost = costs.models.get(id);
    if (!cost) continue;
    const last = i === costs.batchLadder.length - 1;

    if (!last) {
      if (cost.longFormPeakRssBytes && cost.longFormPeakRssBytes > budget) {
        rejected = { id, reason: 'memory', bytes: cost.longFormPeakRssBytes, budget };
        continue;
      }
      if (factor != null && cost.longFormSecondsPerAudioSecond) {
        const projected = cost.longFormSecondsPerAudioSecond * factor;
        if (projected >= costs.batchRealTimeMultiple) {
          rejected = { id, reason: 'speed', projected };
          continue;
        }
      }
    }

    const projected =
      factor != null && cost.longFormSecondsPerAudioSecond
        ? cost.longFormSecondsPerAudioSecond * factor
        : null;
    return {
      model: id,
      basis: i === 0 ? 'top-rung' : rejected && rejected.reason === 'speed' ? 'too-slow' : 'too-large',
      rejected,
      projected,
    };
  }

  // Nothing on the ladder is installed. The safe rung, and the caller's `resolveModel` will raise
  // its own calm sentence if that is missing too.
  return { model: costs.safeRung, basis: 'unmeasured', rejected, projected: null };
}

/**
 * The line a person reads when the machine could not carry the shipping model.
 *
 * Plain language, no byte counts and no model filenames — the register `SttError::ceo_message`
 * already established, and for the same reason: he cannot act on a path.
 *
 * `null` on the top rung. A machine getting the model it was meant to get is the product working,
 * and a notice for it would be noise — which is what makes a real notice get ignored.
 */
export function explain(resolution) {
  switch (resolution.basis) {
    case 'too-slow':
      return (
        'I transcribed this with my faster setting. On this machine the more accurate one would ' +
        'take longer than the recording itself, and a transcript that arrives after you have ' +
        'stopped needing it is not much use. Ask me to redo any call and I will take the slow ' +
        'road on that one.'
      );
    case 'too-large':
      return (
        'I transcribed this with my lighter setting — there is not enough free memory on this ' +
        'machine for the more accurate one, and I would rather not slow everything else down.'
      );
    case 'unmeasured':
      return (
        'I transcribed this with the setting that works everywhere, because I have not worked ' +
        'out yet what this machine can manage.'
      );
    default:
      return null;
  }
}

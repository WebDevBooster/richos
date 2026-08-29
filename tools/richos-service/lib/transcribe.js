/**
 * RichOS local service — pipeline stage 3: TRANSCRIBE (whisper.cpp, per channel).
 *
 * whisper.cpp (`whisper-cli`, Metal auto-on) is a native binary the service shells out to — the
 * precise reason the pipeline is not in the MV3 extension (the system architecture §4.1). Each channel
 * is transcribed independently, so every segment is ALREADY speaker-attributed by channel
 * (me / others) before the merge — no diarization model involved.
 *
 * Default model `large-v3-turbo` per the benchmark: ~3.9 min per call-hour on the M4, ~2 GB RAM,
 * zero hallucination at defaults (the model benchmark, 2026-08-24).
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { whisperBin, resolveModel, whisperArgs, DEFAULT_MODEL } from './config.js';

/**
 * Per-token start offsets of one whisper.cpp segment, in ms — the model's OWN claim about where
 * its words are, present only when the run passed `-ojf` (`--output-json-full`).
 *
 * WHY THIS MATTERS AND WHY IT IS NOT OPTIONAL POLISH: the deletion detector
 * (`deletion-guard.js`) asks "did the run emit any word over this second of audio?", and a
 * whisper.cpp SEGMENT extent cannot answer it. Segments routinely stretch across the pauses around
 * them — measured on the 2026-08-29 corpus, one 30-second segment carried 8 words over 2.2 seconds
 * of actual speech, and 23-second segments carrying 6 words are ordinary. Score coverage on the
 * extent and the words get smeared across silence the speaker never filled, which invents
 * deletions where there are none. Score it on the token offsets and the same eight spans land
 * inside their bursts, correctly, every time.
 *
 * ONE TIME PER WORD, NOT PER TOKEN, and the difference is not cosmetic. whisper's vocabulary is
 * sub-word: a hyphenated compound arrives as several pieces, and a continuation piece carries its own
 * offset which can land well inside the following pause. Counting pieces therefore marks a burst
 * "covered" because the tail of the PREVIOUS word drifted into it. A word starts where whisper puts
 * a leading space; continuation pieces extend it and contribute no time of their own. This is the
 * same unit the 2026-08-29 coverage measurement used, and adopting it moved this pipeline's
 * detector from 6 of the 9 documented deletions to 8.
 *
 * `[_BEG_]` / `[_TT_nn]` are whisper's own structural markers, not words, and are dropped.
 * @param {any} segment one `transcription[]` row
 * @returns {number[]}
 */
export function parseSegmentWordTimes(segment) {
  const toks = Array.isArray(segment?.tokens) ? segment.tokens : [];
  const out = [];
  let started = false;
  for (const t of toks) {
    const text = String(t?.text ?? '');
    if (/^\[_/.test(text)) continue;
    if (!text.trim()) continue;
    const isWordStart = /^\s/.test(text) || !started;
    started = true;
    if (!isWordStart) continue;
    const ms = Number(t?.offsets?.from);
    if (Number.isFinite(ms)) out.push(ms);
  }
  return out;
}

/**
 * Parse whisper.cpp `-oj` JSON into normalized segments.
 *
 * `wordTimesMs` rides ON the segment rather than in a parallel array, deliberately: every later
 * stage that drops, collapses or splits a segment (the repetition guard, diarization) then carries
 * its word times with it for free, and a segment the guard removed cannot leave orphaned token
 * times behind claiming coverage for text that is no longer in the transcript.
 *
 * @param {any} json parsed whisper JSON
 * @param {string} speaker channel label ("me" | "others")
 * @returns {{startMs: number, endMs: number, text: string, speaker: string, wordTimesMs?: number[]}[]}
 */
export function parseWhisperJson(json, speaker) {
  const rows = Array.isArray(json?.transcription) ? json.transcription : [];
  return rows
    .map((r) => {
      const seg = {
        startMs: Number(r?.offsets?.from ?? 0),
        endMs: Number(r?.offsets?.to ?? 0),
        text: String(r?.text ?? '').trim(),
        speaker,
      };
      const times = parseSegmentWordTimes(r);
      if (times.length) seg.wordTimesMs = times;
      return seg;
    })
    .filter((s) => s.text.length > 0);
}

/** whisper-cli's version banner line, for provenance. */
export function whisperVersion() {
  try {
    // whisper-cli has no --version; the model-load banner carries the build. Probe cheaply.
    const out = execFileSync(whisperBin(), ['--help'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    const m = out.match(/whisper\.cpp|usage/i);
    return m ? 'whisper.cpp (whisper-cli)' : 'whisper-cli';
  } catch {
    return 'whisper-cli';
  }
}

/**
 * Transcribe one mono WAV channel.
 * @param {string} wavPath
 * @param {string} speaker "me" | "others"
 * @param {{model?: string, outDir?: string, extraArgs?: string[], language?: string}} [opts]
 * @returns {{segments: object[], jsonPath: string, model: string}}
 */
export function transcribeChannel(wavPath, speaker, opts = {}) {
  const modelId = opts.model || DEFAULT_MODEL;
  const modelPath = resolveModel(modelId);
  const outDir = opts.outDir || path.dirname(wavPath);
  const outBase = path.join(outDir, `${speaker}`);
  const args = [
    '-m', modelPath,
    '-f', wavPath,
    ...whisperArgs({ extraArgs: opts.extraArgs, language: opts.language }),
    // OUTPUT verbosity, NOT a decode parameter — it sits out here with `-of` for exactly that
    // reason, so `whisperArgs()` stays the honest record of how the audio was decoded. `-ojf` adds
    // per-token offsets to the JSON and changes nothing else: proven on the 92-minute corpus, where
    // a run with `-ojf` produced a transcript byte-identical (sha256) to the committed run without
    // it. The deletion detector cannot localize anything without these times — see
    // `parseSegmentWordTimes` — and a detector scored on segment extents invents deletions.
    '-ojf',
    '-of', outBase,
  ];
  execFileSync(whisperBin(), args, { stdio: ['ignore', 'ignore', 'inherit'] });
  const jsonPath = `${outBase}.json`;
  const json = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
  return { segments: parseWhisperJson(json, speaker), jsonPath, model: modelId };
}

/**
 * Transcribe both channels of a normalized session.
 * @param {{me: string, others: string}} channels
 * @param {{model?: string, outDir?: string, extraArgs?: string[], language?: string}} [opts]
 * @returns {{me: object[], others: object[], model: string, whisper: string}}
 */
export function transcribeSession(channels, opts = {}) {
  const me = transcribeChannel(channels.me, 'me', opts);
  const others = transcribeChannel(channels.others, 'others', opts);
  return { me: me.segments, others: others.segments, model: me.model, whisper: whisperVersion() };
}

/**
 * Decode a batch of short CLIPS in ONE whisper-cli invocation — the isolated re-decode the
 * deletion detector adjudicates on (`deletion-guard.js`).
 *
 * ONE invocation, not N, and that is the whole reason this function exists rather than a loop over
 * `transcribeChannel`. `whisper-cli` takes `file0 file1 ...` and loads the model ONCE; a loop pays
 * the model load — which dominates a 3-second clip by an order of magnitude — for every span. This
 * is what keeps the detector's cost proportional to the number of SUSPECT SPANS rather than to the
 * length of the recording, and a detector that must re-run the whole file is not shippable.
 *
 * Decode parameters are `whisperArgs()`, exactly as the main pass uses them — a probe decoded on
 * different settings from the run it is judging would not be a control. `-of` is deliberately NOT
 * passed: with several inputs one output base would make every clip overwrite the last, so each
 * clip's JSON lands next to the clip as `<clip>.json`.
 *
 * @param {string[]} clipPaths
 * @param {{model?: string, extraArgs?: string[], language?: string}} [opts]
 * @returns {string[]} one decoded text per clip, in the order given ('' where the clip decoded to
 *   nothing at all, which for this caller is a meaningful answer rather than a failure)
 */
export function transcribeClips(clipPaths, opts = {}) {
  const paths = (clipPaths || []).filter(Boolean);
  if (!paths.length) return [];
  const modelPath = resolveModel(opts.model || DEFAULT_MODEL);
  execFileSync(
    whisperBin(),
    ['-m', modelPath, ...whisperArgs({ extraArgs: opts.extraArgs, language: opts.language }), ...paths],
    { stdio: ['ignore', 'ignore', 'ignore'] },
  );
  return paths.map((p) => {
    try {
      const json = JSON.parse(fs.readFileSync(`${p}.json`, 'utf8'));
      return (json.transcription || [])
        .map((r) => String(r?.text ?? ''))
        .join(' ')
        .replace(/\s+/g, ' ')
        .trim();
    } catch {
      return '';
    }
  });
}

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
 * Parse whisper.cpp `-oj` JSON into normalized segments.
 * @param {any} json parsed whisper JSON
 * @param {string} speaker channel label ("me" | "others")
 * @returns {{startMs: number, endMs: number, text: string, speaker: string}[]}
 */
export function parseWhisperJson(json, speaker) {
  const rows = Array.isArray(json?.transcription) ? json.transcription : [];
  return rows
    .map((r) => ({
      startMs: Number(r?.offsets?.from ?? 0),
      endMs: Number(r?.offsets?.to ?? 0),
      text: String(r?.text ?? '').trim(),
      speaker,
    }))
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

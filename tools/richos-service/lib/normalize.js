/**
 * RichOS local service — pipeline stage 2: NORMALIZE (ffmpeg).
 *
 * Concatenate the session's self-contained audio parts, then split the stereo contract stream into
 * two 16 kHz mono WAVs — LEFT = me (mic), RIGHT = others (system/tab). This is exactly the
 * production step the benchmark measured (webm/opus -> 16 kHz mono WAV), extended with the
 * channelsplit the 2-channel contract makes free (the system architecture §4, stage 2 + §3.1).
 *
 * The contract does not mandate a codec (§3.1) — ffmpeg decodes whatever the surface wrote
 * (Opus-in-WebM from the extension; Opus-in-Ogg or WAV from a companion). Parts are self-contained
 * so a corrupt part cannot poison the rest.
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { ffmpegBin } from './config.js';

export const SAMPLE_RATE = 16000;
export const CHANNEL_FILES = { me: 'me.wav', others: 'others.wav' };

/** Audio part files, in stable numeric order, as written by any capture surface. */
export function listAudioParts(sessionDir) {
  return fs
    .readdirSync(sessionDir)
    .filter((f) => /^audio-part-\d+\.[a-z0-9]+$/i.test(f))
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
}

/** ffmpeg -version's first line, for the pipeline provenance record. */
export function ffmpegVersion() {
  try {
    const out = execFileSync(ffmpegBin(), ['-version'], { encoding: 'utf8' });
    return out.split(/\r?\n/)[0].trim();
  } catch {
    return null;
  }
}

/**
 * Number of channels in an audio file, via ffprobe-free ffmpeg stderr parse (ffprobe may be absent).
 * @param {string} file
 * @returns {number}
 */
function channelCount(file) {
  try {
    const res = execFileSync(ffmpegBin(), ['-i', file, '-hide_banner'], {
      encoding: 'utf8',
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    return parseChannels(res);
  } catch (err) {
    // ffmpeg exits non-zero on `-i` with no output; the info we want is on stderr regardless.
    return parseChannels(String(err.stderr || ''));
  }
}

/**
 * Peak/mean volume of a WAV via ffmpeg `volumedetect` — a deterministic energy probe that does not
 * depend on the ASR (whisper hallucinates "Thank you." on pure silence, so word count alone cannot
 * distinguish a silent capture from a real one). Returns dBFS; -inf/very-low = digital silence.
 * @param {string} wavPath
 * @returns {{meanDb: number, maxDb: number}}
 */
export function measureVolume(wavPath) {
  // volumedetect prints its stats to stderr and ffmpeg exits 0, so use spawnSync (execFileSync only
  // surfaces stderr when the process throws).
  const res = spawnSync(ffmpegBin(), ['-i', wavPath, '-af', 'volumedetect', '-f', 'null', '-'], {
    encoding: 'utf8',
  });
  return parseVolume(String(res.stderr || ''));
}

/** @param {string} ffmpegStderr */
export function parseVolume(ffmpegStderr) {
  const mean = ffmpegStderr.match(/mean_volume:\s*(-?[\d.]+|-inf)\s*dB/i);
  const max = ffmpegStderr.match(/max_volume:\s*(-?[\d.]+|-inf)\s*dB/i);
  const num = (m) => (m ? (/-inf/i.test(m[1]) ? -Infinity : Number(m[1])) : -Infinity);
  return { meanDb: num(mean), maxDb: num(max) };
}

/** dBFS at/below which a channel is treated as digitally silent (a dead/empty capture). */
export const SILENCE_MAX_DB = -60;

/**
 * Is a normalized session effectively silent on BOTH channels? That is the honest "captured but
 * nothing recorded" signal, independent of ASR hallucination.
 * @param {{me: string, others: string}} channels
 * @returns {{silent: boolean, me: {meanDb:number,maxDb:number}, others: {meanDb:number,maxDb:number}}}
 */
export function detectSilence(channels) {
  const me = measureVolume(channels.me);
  const others = measureVolume(channels.others);
  const silent = me.maxDb <= SILENCE_MAX_DB && others.maxDb <= SILENCE_MAX_DB;
  return { silent, me, others };
}

/** @param {string} ffmpegStderr */
export function parseChannels(ffmpegStderr) {
  const m = ffmpegStderr.match(/Audio:.*?,\s*(?:mono|stereo|(\d+)\s*channels)/i);
  if (!m) return 0;
  if (/mono/i.test(m[0])) return 1;
  if (/stereo/i.test(m[0])) return 2;
  return Number(m[1]) || 0;
}

/**
 * Normalize a session's audio into two mono 16 kHz WAV channels.
 *
 * @param {string} sessionDir absolute path to the session directory
 * @param {{workDir?: string}} [opts] where to put intermediate files (defaults to sessionDir)
 * @returns {{me: string, others: string, parts: string[], stereo: boolean, ffmpeg: string|null}}
 */
export function normalizeSession(sessionDir, opts = {}) {
  const ffmpeg = ffmpegBin();
  const parts = listAudioParts(sessionDir);
  if (parts.length === 0) throw new Error('normalize: no audio parts to normalize');
  const workDir = opts.workDir || sessionDir;
  fs.mkdirSync(workDir, { recursive: true });

  // 1) Concatenate parts. Single part -> use it directly; many -> ffmpeg concat demuxer.
  let concatInput;
  const cleanup = [];
  if (parts.length === 1) {
    concatInput = path.join(sessionDir, parts[0]);
  } else {
    const listFile = path.join(workDir, '_concat.txt');
    fs.writeFileSync(
      listFile,
      parts.map((p) => `file '${path.join(sessionDir, p).replace(/'/g, "'\\''")}'`).join('\n'),
    );
    concatInput = path.join(workDir, '_concat.webm');
    execFileSync(ffmpeg, ['-y', '-f', 'concat', '-safe', '0', '-i', listFile, '-c', 'copy', concatInput]);
    cleanup.push(listFile, concatInput);
  }

  const channels = channelCount(concatInput);
  const stereo = channels >= 2;
  const mePath = path.join(workDir, CHANNEL_FILES.me);
  const othersPath = path.join(workDir, CHANNEL_FILES.others);

  if (stereo) {
    // channelsplit gives free me-vs-them separation with no diarization model (§3.1).
    execFileSync(ffmpeg, [
      '-y', '-i', concatInput,
      '-filter_complex', 'channelsplit=channel_layout=stereo[L][R]',
      '-map', '[L]', '-ac', '1', '-ar', String(SAMPLE_RATE), mePath,
      '-map', '[R]', '-ac', '1', '-ar', String(SAMPLE_RATE), othersPath,
    ]);
  } else {
    // In-person / mono fallback (§3.1): both voices on LEFT; the 2-channel split degrades to
    // single-channel gracefully. `others.wav` is a silent placeholder so downstream stays uniform.
    execFileSync(ffmpeg, ['-y', '-i', concatInput, '-ac', '1', '-ar', String(SAMPLE_RATE), mePath]);
    execFileSync(ffmpeg, [
      '-y', '-f', 'lavfi', '-t', '0.1', '-i', `anullsrc=r=${SAMPLE_RATE}:cl=mono`, othersPath,
    ]);
  }

  for (const f of cleanup) {
    try {
      fs.rmSync(f, { force: true });
    } catch {
      /* best-effort */
    }
  }

  return { me: mePath, others: othersPath, parts, stereo, ffmpeg: ffmpegVersion() };
}

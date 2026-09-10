/**
 * RichOS local service — WHICH BINARY AND WHICH WEIGHTS PRODUCED THIS TRANSCRIPT.
 *
 * WHY THIS FILE EXISTS. The whisper settings decision table
 * (`docs/measurements/whisper-settings-2026-09-10/whisper-settings-decisions.md`) decides every
 * flag this pipeline passes, and its §4 names the hole it did not close, in its own words:
 * `whisper-cli` and the ggml backends are **unpinned**, and `whisperVersion()` "records nothing
 * that would let anyone notice the change". Every "vendor default" column in that table is a
 * property of ONE build. `-fa` alone is worth 1.57 WER points and is a DEFAULT: a formula bump
 * that flips it costs more accuracy than any tuning decision in the table recovers, and nobody
 * would attribute the regression. This module is the answer to that.
 *
 * ## Two tiers of expectation, deliberately unequal — and the asymmetry IS the design
 *
 * **1. SOURCE PINS — model weights.** They already exist, in `model-pins.json`, vouched for by
 * HuggingFace's `x-linked-etag` plus a shasum of the CEO's own copy. That table has AUTHORITY: it
 * says what the bytes are SUPPOSED to be. A mismatch against it is therefore a **REFUSAL**, and it
 * has to be, because the fetch path already refuses on the same hash — a decode path that
 * transcribed anyway would quietly overrule the fetch path's own guarantee.
 *
 * **2. A MACHINE LOCK — the binary and its backends.** `whisper-cli` arrives from Homebrew. There
 * is no upstream sha256 we could carry in source that a different arch, a different OS version or
 * a bottle rebuild would not legitimately fail, and a pin that every other machine fails is a pin
 * nobody keeps. So the binary is locked on FIRST USE, on the machine, into
 * `~/.config/richos/whisper-toolchain.lock.json`. That lock records what WAS there; it has no
 * authority to say the new one is worse. A mismatch against it is therefore a **LOUD WARNING**
 * that names the old and the new identity, never a silent pass and never a refusal — see
 * `SEVERITY` below, where that decision is written out with its reason.
 *
 * ONE registry, not two: the reference build lives in the SAME `model-pins.json` the weights do
 * (its `toolchain` block), because two places to look is how the second unpinned consumer happened.
 *
 * ## The version string is a LABEL. The sha256 is the IDENTITY. This is measured, not asserted.
 *
 * Measured on this machine, 2026-09-10, both builds present under Homebrew's Cellar:
 *
 *   /opt/homebrew/Cellar/whisper-cpp/1.9.1/bin/whisper-cli --version
 *     exit 0, stdout: "whisper.cpp version: 1.9.1"
 *   /opt/homebrew/Cellar/whisper-cpp/1.8.3/bin/whisper-cli --version
 *     exit 0, stdout: EMPTY (0 bytes), stderr: "error: unknown argument: --version"
 *
 * **1.8.3 rejects the flag and exits ZERO.** A probe that trusts the exit code sees success and an
 * empty version, which is indistinguishable from a build that has no version. That is the exact
 * silent-fallthrough this work exists to close, so the version string is never load-bearing here:
 * it is a human label attached to a sha256, and a build that will not say its version gets a
 * finding of its own rather than an empty field nobody reads.
 *
 * ## What gets hashed when, and the numbers behind it
 *
 * Measured on this M4, 2026-09-10, `shasum -a 256`, three runs each:
 *
 *   whisper-cli            654,720 B        0.01 s / 0.01 s / 0.01 s
 *   ggml backends (x3)     ~2.6 MB total    under 0.05 s
 *   ggml-small.en.bin      487,614,201 B    0.95 s / 0.93 s / 0.93 s
 *   ggml-large-v3-turbo    1,624,555,275 B  3.13 s / 3.11 s
 *
 * So the **binary and its backends are hashed on EVERY run** — 0.01 s is free, and the binary is
 * precisely the thing a package manager swaps under you between one call and the next. The
 * **models are hashed on a cache miss only**, keyed on (path, bytes, mtime, inode, device), because
 * a conversational dictation utterance decodes in 0.47-0.74 s (`stt.rs`) and a 0.93 s hash on every
 * one of them would nearly triple the latency the voice path was tuned for. On the call path the
 * 3.1 s hash is 1.4% of a 226 s decode of 92 minutes, and it is still cached — there is no reason
 * to pay it twice.
 *
 * **The limit of that cache, stated rather than buried:** a substitution that rewrites a model file
 * in place while restoring its size, mtime, inode AND device would be believed until something
 * re-hashes it. `richos-service verify-model <id>` and `richos-service toolchain --recheck` both
 * force the full hash, and the fetch path never populates the cache without hashing first. The
 * cache is an optimization over a check that DID happen, never a substitute for one that did not.
 *
 * Everything above `// ---- I/O` is PURE: it takes observed identities and locked identities and
 * decides. That is what makes every refusal and every warning testable without a whisper binary.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

import { pinFor as pinForModel, TOOLCHAIN_REFERENCE } from './model-catalog.js';

/** Lock-file schema version. Bump when a field's MEANING changes, never for an addition. */
export const LOCK_SCHEMA = 1;

/**
 * Every way the toolchain can differ from what was expected. Exported so callers branch on a kind
 * rather than match on a message, and so the test suite can assert the set has not silently shrunk.
 */
export const TOOLCHAIN_FINDING = Object.freeze({
  /** No lock existed. Nothing was compared; what was found is now the lock. */
  FIRST_LOCK: 'first-lock',
  /** The `whisper-cli` bytes are not the bytes this machine locked. */
  BIN_CHANGED: 'bin-changed',
  /** A ggml backend the binary loaded is not the one locked, or the set itself changed. */
  BACKEND_CHANGED: 'backend-changed',
  /** The binary answers `--version` with a different version than the locked one. */
  VERSION_CHANGED: 'version-changed',
  /** The binary would not say its version (1.8.3 exits 0 with empty stdout — see the header). */
  VERSION_UNKNOWN: 'version-unknown',
  /** The binary is not the build the decision table's measurements were taken on. */
  VERSION_OFF_REFERENCE: 'version-off-reference',
  /** A model file's sha256 is not the sha256 pinned in source for that model. */
  MODEL_HASH_MISMATCH: 'model-hash-mismatch',
  /** A model is in use that source pins nothing for — an override, or an unlisted model. */
  MODEL_UNPINNED: 'model-unpinned',
  /** The binary could not be probed at all. */
  PROBE_FAILED: 'probe-failed',
});

/**
 * How loud each finding is, and WHY it is that loud rather than the other one. This table is the
 * decision the brief asks to be stated plainly, so it is data rather than prose scattered through
 * branches.
 *
 * - `refuse` — the run does not happen. Reserved for a mismatch against a SOURCE pin, which is a
 *   statement of what the bytes are supposed to be, backed by upstream plus a witness on disk.
 *   The fetch path already refuses on exactly this hash; a decode path that shrugged would be
 *   overruling it.
 * - `warn` — the run happens, and the finding is written where a reader meets it: the pipeline
 *   log as an alarm, `verification.warnings` (the ONE warnings vocabulary the merge stage already
 *   uses for fabricated and deleted speech), and the session record's toolchain block. Chosen over
 *   `refuse` for everything the machine LOCK notices, because the lock records what was there, not
 *   what is right — a routine `brew upgrade whisper-cpp` must not leave an already-captured call
 *   untranscribable, and the CEO cannot re-record a meeting. Loud and attributable beats blocked.
 * - `note` — recorded in provenance, not surfaced as a problem. Nothing is wrong.
 *
 * `RICHOS_WHISPER_STRICT_TOOLCHAIN=1` escalates every `warn` to `refuse`. That is for reproducing
 * the measurements in the decision table, where "the binary changed" invalidates the run. It is
 * OFF by default and the default is a decision: on by default would mean a Homebrew upgrade
 * silently stops transcription for a CEO who has no idea what a bottle is.
 */
export const SEVERITY = Object.freeze({
  [TOOLCHAIN_FINDING.FIRST_LOCK]: 'note',
  [TOOLCHAIN_FINDING.BIN_CHANGED]: 'warn',
  [TOOLCHAIN_FINDING.BACKEND_CHANGED]: 'warn',
  [TOOLCHAIN_FINDING.VERSION_CHANGED]: 'warn',
  [TOOLCHAIN_FINDING.VERSION_UNKNOWN]: 'warn',
  [TOOLCHAIN_FINDING.VERSION_OFF_REFERENCE]: 'warn',
  [TOOLCHAIN_FINDING.MODEL_HASH_MISMATCH]: 'refuse',
  [TOOLCHAIN_FINDING.MODEL_UNPINNED]: 'warn',
  [TOOLCHAIN_FINDING.PROBE_FAILED]: 'warn',
});

/** Is strict mode on? Off by default, deliberately — see `SEVERITY`. */
export function strictMode(env = process.env) {
  const v = env.RICHOS_WHISPER_STRICT_TOOLCHAIN;
  return v === '1' || v === 'true' || v === 'yes';
}

/**
 * The severity of a finding, after strict mode has had its say.
 * @param {string} kind
 * @param {boolean} [strict]
 */
export function severityOf(kind, strict = false) {
  const base = SEVERITY[kind] || 'note';
  if (strict && base === 'warn') return 'refuse';
  return base;
}

// ---------------------------------------------------------------------------------------------
// PURE — parsing what the binary said about itself
// ---------------------------------------------------------------------------------------------

/**
 * The version out of `whisper-cli --version` STDOUT.
 *
 * Only stdout, and only a line that actually claims to be a version. 1.8.3 writes its whole usage
 * banner to stderr and exits 0, so anything that read stderr — or trusted the exit code — would
 * call that a successful probe of a build with no version. Returns `null` when the binary did not
 * say, which is a finding (`VERSION_UNKNOWN`), never an empty string quietly stored.
 * @param {string} stdout
 * @returns {string|null}
 */
export function parseVersion(stdout) {
  const m = String(stdout || '').match(/whisper\.cpp\s+version\s*:\s*(\S+)/i);
  return m ? m[1] : null;
}

/**
 * The ggml compute backends the binary ACTUALLY loaded, read off its own startup lines.
 *
 * Measured, not inferred: whisper-cli prints one `load_backend:` line per backend on stderr before
 * it does anything, naming the .so it dlopen'd. That is the honest source for "which backends is
 * this build running" — better than guessing a Cellar path, because the binary is telling us the
 * path it resolved, including a `GGML_BACKEND_PATH` override we would otherwise never see.
 *
 *   load_backend: loaded BLAS backend from /opt/homebrew/Cellar/ggml/0.17.0/libexec/libggml-blas.so
 *
 * @param {string} stderr
 * @returns {{name: string, path: string}[]} in the order the binary loaded them
 */
export function parseBackends(stderr) {
  const out = [];
  for (const line of String(stderr || '').split(/\r?\n/)) {
    const m = line.match(/^load_backend:\s*loaded\s+(\S+)\s+backend\s+from\s+(.+?)\s*$/);
    if (m) out.push({ name: m[1], path: m[2] });
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// PURE — the comparison
// ---------------------------------------------------------------------------------------------

/**
 * Compare an observed toolchain against the machine lock and the source reference.
 *
 * @param {{observed: object, locked: object|null, reference: object|null, strict?: boolean}} input
 *   observed  {bin: {path, realPath, bytes, sha256, version, probeError?}, backends: [{name, path, bytes, sha256}]}
 *   locked    the same shape, off disk, or null on a first install
 *   reference `model-pins.json`'s `toolchain` block: the build the decision table was measured on
 * @returns {{findings: object[], verdict: 'ok'|'warn'|'refuse', relock: boolean}}
 */
export function compareToolchain({ observed, locked, reference = null, strict = false }) {
  const findings = [];
  const add = (kind, fields) => findings.push({ kind, severity: severityOf(kind, strict), ...fields });

  if (observed?.bin?.probeError) {
    add(TOOLCHAIN_FINDING.PROBE_FAILED, { detail: observed.bin.probeError, path: observed.bin.path });
  }

  if (!locked) {
    add(TOOLCHAIN_FINDING.FIRST_LOCK, {
      now: observed?.bin?.sha256 || null,
      version: observed?.bin?.version || null,
      path: observed?.bin?.path || null,
      backends: (observed?.backends || []).map((b) => b.name),
    });
  } else {
    if (locked.bin?.sha256 && observed.bin?.sha256 && locked.bin.sha256 !== observed.bin.sha256) {
      add(TOOLCHAIN_FINDING.BIN_CHANGED, {
        was: locked.bin.sha256,
        now: observed.bin.sha256,
        wasVersion: locked.bin.version || null,
        nowVersion: observed.bin.version || null,
        wasPath: locked.bin.realPath || locked.bin.path || null,
        nowPath: observed.bin.realPath || observed.bin.path || null,
        lockedOn: locked.lockedOn || null,
      });
    }
    if (locked.bin?.version && observed.bin?.version && locked.bin.version !== observed.bin.version) {
      add(TOOLCHAIN_FINDING.VERSION_CHANGED, { was: locked.bin.version, now: observed.bin.version });
    }
    // Backends are compared only when the probe actually saw some. A build that does not print
    // `load_backend:` lines has told us nothing about its backends, and "nothing" is not "changed"
    // — the binary hash above already carries that case.
    const obs = observed.backends || [];
    const lock = locked.backends || [];
    if (obs.length && lock.length) {
      const lockByName = new Map(lock.map((b) => [b.name, b]));
      for (const b of obs) {
        const was = lockByName.get(b.name);
        if (!was) {
          add(TOOLCHAIN_FINDING.BACKEND_CHANGED, { backend: b.name, was: null, now: b.sha256, nowPath: b.path });
        } else if (was.sha256 && b.sha256 && was.sha256 !== b.sha256) {
          add(TOOLCHAIN_FINDING.BACKEND_CHANGED, {
            backend: b.name,
            was: was.sha256,
            now: b.sha256,
            wasPath: was.path,
            nowPath: b.path,
          });
        }
      }
      const obsNames = new Set(obs.map((b) => b.name));
      for (const b of lock) {
        if (!obsNames.has(b.name)) {
          add(TOOLCHAIN_FINDING.BACKEND_CHANGED, { backend: b.name, was: b.sha256, now: null, wasPath: b.path });
        }
      }
    }
  }

  if (!observed?.bin?.version && !observed?.bin?.probeError) {
    add(TOOLCHAIN_FINDING.VERSION_UNKNOWN, {
      path: observed?.bin?.path || null,
      sha256: observed?.bin?.sha256 || null,
      detail: observed?.bin?.probeStderrFirstLine || null,
    });
  } else if (
    reference?.whisperCppVersion &&
    observed?.bin?.version &&
    observed.bin.version !== reference.whisperCppVersion
  ) {
    add(TOOLCHAIN_FINDING.VERSION_OFF_REFERENCE, {
      was: reference.whisperCppVersion,
      now: observed.bin.version,
      measuredOn: reference.measuredOn || null,
    });
  }

  return {
    findings,
    verdict: verdictOf(findings),
    relock: findings.some((f) => f.kind !== TOOLCHAIN_FINDING.VERSION_OFF_REFERENCE),
  };
}

/**
 * Compare one model file against its SOURCE pin.
 *
 * @param {{modelId: string, filePath: string, sha256: string|null, pin: object|null, strict?: boolean}} input
 * @returns {object|null} a finding, or null when the file is exactly the pinned bytes
 */
export function compareModel({ modelId, filePath, sha256, pin, strict = false }) {
  const mk = (kind, fields) => ({ kind, severity: severityOf(kind, strict), modelId, path: filePath, ...fields });
  if (!pin) return mk(TOOLCHAIN_FINDING.MODEL_UNPINNED, { now: sha256 || null });
  if (!sha256) return null; // nothing hashed yet — the caller decides whether that is acceptable
  if (String(sha256).toLowerCase() !== String(pin.sha256).toLowerCase()) {
    return mk(TOOLCHAIN_FINDING.MODEL_HASH_MISMATCH, { was: pin.sha256, now: String(sha256).toLowerCase() });
  }
  return null;
}

/** The worst severity present, as a verdict. */
export function verdictOf(findings) {
  if (findings.some((f) => f.severity === 'refuse')) return 'refuse';
  if (findings.some((f) => f.severity === 'warn')) return 'warn';
  return 'ok';
}

/**
 * The sentence for a finding — what changed, from what, to what, and what a person does about it.
 *
 * NAMING BOTH IDENTITIES IS THE REQUIREMENT, not a nicety: "the binary changed" sends a reader to
 * a support conversation; "1.9.1 (7dc20e31...) became 1.8.3 (595da05c...)" sends them to `brew`.
 * @param {object} f
 * @returns {string}
 */
export function describeFinding(f) {
  const s = (h) => (h ? `${String(h).slice(0, 12)}…` : 'nothing');
  switch (f.kind) {
    case TOOLCHAIN_FINDING.FIRST_LOCK:
      return (
        `First run on this machine: no whisper toolchain was locked yet, so there was nothing to compare against. ` +
        `RichOS has recorded what it found — whisper-cli ${f.version ? `version ${f.version}` : 'of unknown version'} ` +
        `(sha256 ${s(f.now)}) at ${f.path}${f.backends?.length ? `, ggml backends ${f.backends.join(', ')}` : ''} — ` +
        `and every later run is checked against it. Nothing was refused, because a first install has no earlier ` +
        `identity to be wrong about.`
      );
    case TOOLCHAIN_FINDING.BIN_CHANGED:
      return (
        `THE WHISPER BINARY CHANGED since this machine last transcribed. ` +
        `Was ${f.wasVersion ? `version ${f.wasVersion}` : 'an unversioned build'} sha256 ${s(f.was)}` +
        `${f.wasPath ? ` at ${f.wasPath}` : ''}${f.lockedOn ? ` (locked ${f.lockedOn})` : ''}; ` +
        `now ${f.nowVersion ? `version ${f.nowVersion}` : 'an unversioned build'} sha256 ${s(f.now)}` +
        `${f.nowPath ? ` at ${f.nowPath}` : ''}. ` +
        `Decode defaults are a property of a build: whisper.cpp defaults flash attention ON, and losing it is ` +
        `worth 1.57 WER points measured on this project's own corpus. ` +
        // The two severities need two different last sentences. Under strict mode nothing was
        // transcribed, and telling a reader their transcript "was produced by the new binary"
        // when no transcript exists is the kind of confidently wrong sentence that costs a
        // message its authority.
        (f.severity === 'refuse'
          ? `RICHOS_WHISPER_STRICT_TOOLCHAIN is set, so this is a REFUSAL and nothing was transcribed: the audio ` +
            `is untouched and retained. Put the locked build back, or accept this one with ` +
            `\`richos-service toolchain --relock\`.`
          : `This transcript was produced by the NEW binary and is attributed to it in the session record. If ` +
            `this was a deliberate upgrade, nothing needs doing — the new identity is now the locked one.`)
      );
    case TOOLCHAIN_FINDING.BACKEND_CHANGED:
      return (
        `The ggml ${f.backend} backend changed: sha256 ${s(f.was)} -> ${s(f.now)}` +
        `${f.nowPath ? ` (${f.nowPath})` : ''}. The compute backends load at run time from the ggml formula, ` +
        `independently of whisper-cli's own version, so this can change with the binary untouched. Recorded ` +
        `against this transcript.`
      );
    case TOOLCHAIN_FINDING.VERSION_CHANGED:
      return `whisper-cli reports version ${f.now} where this machine had locked ${f.was}.`;
    case TOOLCHAIN_FINDING.VERSION_UNKNOWN:
      return (
        `whisper-cli at ${f.path} would not say its version: \`--version\` produced no version line on stdout` +
        `${f.detail ? ` (it said: "${String(f.detail).slice(0, 100)}")` : ''}. ` +
        `Measured on this project 2026-09-10: whisper-cpp 1.8.3 rejects \`--version\` and still EXITS 0, so an ` +
        `empty answer here is a real build that will not identify itself, not a probe failure. Its sha256 ` +
        `${s(f.sha256)} is the identity used instead, and it is the identity the transcript is attributed to.`
      );
    case TOOLCHAIN_FINDING.VERSION_OFF_REFERENCE:
      return (
        `whisper-cli is version ${f.now}, and every decode setting RichOS ships was measured against ${f.was}` +
        `${f.measuredOn ? ` (${f.measuredOn})` : ''}. The settings table's "vendor default" column describes ${f.was}, ` +
        `not this build. Transcripts are still produced and attributed; re-run the measurements before trusting ` +
        `the table's numbers on this version.`
      );
    case TOOLCHAIN_FINDING.MODEL_HASH_MISMATCH:
      return (
        `REFUSING TO TRANSCRIBE: the model file for "${f.modelId}" is not the model RichOS pinned. ` +
        `Expected sha256 ${s(f.was)}, found ${s(f.now)} at ${f.path}. These are different weights under the right ` +
        `name — a different model would produce a different transcript and nothing downstream would know. ` +
        `The audio is untouched and retained. Re-fetch the model (\`richos-service fetch-model ${f.modelId}\`) ` +
        `and run again.`
      );
    case TOOLCHAIN_FINDING.MODEL_UNPINNED:
      return (
        `The model in use for "${f.modelId}" is not in RichOS's pin table, so there is no source hash to check it ` +
        `against${f.now ? `; its sha256 ${s(f.now)} has been recorded against this transcript instead` : ''}. ` +
        `That is expected for a deliberate RICHOS_WHISPER_MODEL override and is recorded rather than refused, ` +
        `because overriding is what an override is for.`
      );
    case TOOLCHAIN_FINDING.PROBE_FAILED:
      return `Could not probe whisper-cli at ${f.path} for its identity: ${f.detail}. The transcript's provenance will be incomplete.`;
    default:
      return `toolchain: ${f.kind}`;
  }
}

/** Is this stat-identity the same file, byte for byte, as the one the lock hashed? */
export function sameIdentity(a, b) {
  if (!a || !b) return false;
  return (
    Number(a.bytes) === Number(b.bytes) &&
    Number(a.mtimeMs) === Number(b.mtimeMs) &&
    Number(a.ino) === Number(b.ino) &&
    Number(a.dev) === Number(b.dev)
  );
}

/**
 * One human line naming the binary and the weights — the provenance string.
 * @param {object} tc  the resolved toolchain
 * @returns {string}
 */
export function provenanceString(tc) {
  if (!tc) return 'whisper-cli (identity not recorded)';
  const v = tc.bin?.version ? `whisper.cpp ${tc.bin.version}` : 'whisper.cpp (version not reported)';
  const b = tc.bin?.sha256 ? ` bin:${String(tc.bin.sha256).slice(0, 12)}` : '';
  const backends = (tc.backends || []).map((x) => x.name).join('/');
  const m = tc.model?.sha256 ? ` model:${tc.model.id}@${String(tc.model.sha256).slice(0, 12)}` : '';
  return `${v}${b}${backends ? ` [${backends}]` : ''}${m}`;
}

// ---------------------------------------------------------------------------------------------
// ---- I/O. Thin, no judgment: every decision above is pure and tested without a whisper binary.
// ---------------------------------------------------------------------------------------------

/** Where this machine's lock lives. Operational state — not the repo, not the CEO's corpus. */
export function lockPath(env = process.env) {
  if (env.RICHOS_TOOLCHAIN_LOCK) return path.resolve(expandHome(env.RICHOS_TOOLCHAIN_LOCK));
  return path.join(os.homedir(), '.config', 'richos', 'whisper-toolchain.lock.json');
}

function expandHome(p) {
  return p.startsWith('~') ? path.join(os.homedir(), p.slice(1)) : p;
}

/** I/O — sha256 of a file, streamed. `null` when it cannot be read. */
export function hashFileSync(filePath) {
  try {
    const h = crypto.createHash('sha256');
    const fd = fs.openSync(filePath, 'r');
    try {
      const buf = Buffer.alloc(1 << 20);
      for (;;) {
        const n = fs.readSync(fd, buf, 0, buf.length, null);
        if (n <= 0) break;
        h.update(buf.subarray(0, n));
      }
    } finally {
      fs.closeSync(fd);
    }
    return h.digest('hex');
  } catch {
    return null;
  }
}

/** I/O — the stat tuple that decides whether a cached hash still describes this file. */
export function fileIdentity(filePath) {
  try {
    const st = fs.statSync(filePath);
    return { bytes: st.size, mtimeMs: st.mtimeMs, ino: Number(st.ino), dev: Number(st.dev) };
  } catch {
    return null;
  }
}

/**
 * I/O — ask the binary who it is.
 *
 * ONE `--version` per process (0.04 s measured), and it does double duty: stdout carries the
 * version, stderr carries the `load_backend:` lines naming every compute backend actually loaded.
 * The exit code is deliberately NOT consulted — 1.8.3 exits 0 while rejecting the flag.
 *
 * @param {string} binPath
 * @returns {{bin: object, backends: object[]}}
 */
export function probeWhisper(binPath) {
  const identity = fileIdentity(binPath) || {};
  let realPath = binPath;
  try {
    realPath = fs.realpathSync(binPath);
  } catch {
    /* keep binPath */
  }
  const bin = {
    path: binPath,
    realPath,
    bytes: identity.bytes ?? null,
    sha256: hashFileSync(binPath),
    version: null,
  };
  // `spawnSync`, NOT `execFileSync`, and the reason is the whole probe: execFileSync RETURNS
  // stdout and surfaces stderr only by throwing. whisper-cli 1.9.1 exits 0, so it never throws,
  // so its `load_backend:` lines — the only place the loaded ggml backends are named — would be
  // discarded on exactly the healthy path we care most about. spawnSync hands back both streams
  // and a status, from one invocation, and lets the exit code be RECORDED rather than trusted.
  const r = spawnSync(binPath, ['--version'], { encoding: 'utf8', timeout: 20_000, maxBuffer: 8 << 20 });
  const stdout = r.stdout || '';
  const stderr = r.stderr || '';
  if (r.error && !stdout && !stderr) bin.probeError = String(r.error.message || r.error);
  bin.probeExitStatus = r.status ?? null;
  bin.version = parseVersion(stdout);
  if (!bin.version) {
    bin.probeStderrFirstLine =
      String(stderr)
        .split(/\r?\n/)
        .map((x) => x.trim())
        .find((x) => x.length > 0) || null;
  }
  const backends = parseBackends(stderr).map((b) => {
    const id = fileIdentity(b.path);
    return { name: b.name, path: b.path, bytes: id?.bytes ?? null, sha256: hashFileSync(b.path) };
  });
  return { bin, backends };
}

/** I/O — read the machine lock, or `null` when there is not one (a first install). */
export function loadLock(file = lockPath()) {
  try {
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    return raw && typeof raw === 'object' ? raw : null;
  } catch {
    return null;
  }
}

/** I/O — write the machine lock atomically (temp + rename, so a crash cannot leave half a lock). */
export function saveLock(lock, file = lockPath()) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(lock, null, 2)}\n`);
  fs.renameSync(tmp, file);
  return file;
}

/** The lock object to write for an observed toolchain, preserving the model hash cache. */
export function buildLock({ observed, previous = null, at = new Date() }) {
  return {
    _comment: [
      'RichOS whisper toolchain lock — TRUST ON FIRST USE, on THIS machine.',
      '',
      'What is in here is what was found the first time this machine transcribed, plus every model',
      'file hash it has verified since. It records what WAS; it has no authority to say what is',
      'RIGHT — that is what tools/richos-service/lib/model-pins.json is for, and a mismatch against',
      'THAT refuses. A mismatch against this file warns loudly and names both identities.',
      '',
      'Delete this file to re-lock from scratch, or run `richos-service toolchain --relock`.',
    ],
    schema: LOCK_SCHEMA,
    lockedOn: previous?.lockedOn || at.toISOString(),
    updatedOn: at.toISOString(),
    host: { platform: process.platform, arch: process.arch },
    bin: observed.bin,
    backends: observed.backends,
    models: previous?.models && typeof previous.models === 'object' ? previous.models : {},
  };
}

// ---------------------------------------------------------------------------------------------
// The one call the decode path makes. Probe, compare, decide, record.
// ---------------------------------------------------------------------------------------------

/** Per-process memo, so transcribing both channels of one call probes the binary once. */
const MEMO = new Map();

/** Forget everything memoized. For tests, and for `--recheck`. */
export function resetToolchainCache() {
  MEMO.clear();
}

/**
 * Establish — and check — the identity of everything that is about to touch this audio.
 *
 * Returns rather than throws, so a caller can choose to report instead of refuse
 * (`richos-service toolchain` does exactly that). `assertToolchain` is the decode path's form.
 *
 * @param {{binPath: string, modelPath: string, modelId: string, lockFile?: string,
 *          strict?: boolean, force?: boolean, memo?: boolean, at?: Date}} opts
 * @returns {{verdict: 'ok'|'warn'|'refuse', findings: object[], messages: string[],
 *            toolchain: object, provenance: string, lockFile: string, firstRun: boolean}}
 */
export function resolveToolchain({
  binPath,
  modelPath,
  modelId,
  lockFile = lockPath(),
  strict = strictMode(),
  force = false,
  memo = true,
  at = new Date(),
}) {
  const key = `${binPath}|${modelPath}|${modelId}|${lockFile}|${strict}|${force}`;
  if (memo && MEMO.has(key)) return MEMO.get(key);

  const observed = probeWhisper(binPath);
  const locked = loadLock(lockFile);
  const cmp = compareToolchain({ observed, locked, reference: TOOLCHAIN_REFERENCE, strict });

  // ---- the weights -----------------------------------------------------------------------------
  const identity = fileIdentity(modelPath);
  const cached = locked?.models?.[modelPath] || null;
  const cacheHit = !force && cached && sameIdentity(cached, identity) && cached.sha256;
  const modelSha = cacheHit ? cached.sha256 : hashFileSync(modelPath);
  const pin = pinForModel(modelId);
  const modelFinding = compareModel({ modelId, filePath: modelPath, sha256: modelSha, pin, strict });

  const findings = [...cmp.findings, ...(modelFinding ? [modelFinding] : [])];
  const verdict = verdictOf(findings);
  const messages = findings.map((f) => describeFinding(f));

  const toolchain = {
    bin: observed.bin,
    backends: observed.backends,
    model: {
      id: modelId,
      path: modelPath,
      bytes: identity?.bytes ?? null,
      sha256: modelSha,
      hashed: cacheHit ? 'cached' : 'fresh',
      pinned: Boolean(pin),
    },
    checkedAt: at.toISOString(),
    strict,
    lockFile,
  };

  // ---- record what ran -------------------------------------------------------------------------
  // A refused run never updates the lock: caching the identity of bytes we just rejected would let
  // the SECOND attempt sail past on a cache hit, which is a guard that disarms itself.
  if (verdict !== 'refuse') {
    const next = buildLock({ observed, previous: locked, at });
    if (identity && modelSha) {
      next.models[modelPath] = { id: modelId, ...identity, sha256: modelSha, verifiedOn: at.toISOString() };
    }
    try {
      saveLock(next, lockFile);
    } catch (err) {
      messages.push(`Could not write the toolchain lock at ${lockFile}: ${String(err.message || err)}.`);
    }
  }

  const result = {
    verdict,
    findings,
    messages,
    toolchain,
    provenance: provenanceString(toolchain),
    lockFile,
    firstRun: !locked,
  };
  if (memo) MEMO.set(key, result);
  return result;
}

/**
 * The decode path's form: same check, but a `refuse` verdict throws before a byte of audio is
 * decoded. The message carries every finding, because a reader who is told one thing changed and
 * later discovers a second one stops believing the first.
 * @param {object} opts see `resolveToolchain`
 */
export function assertToolchain(opts) {
  const r = resolveToolchain(opts);
  if (r.verdict === 'refuse') {
    const err = new Error(`whisper toolchain check failed:\n  - ${r.messages.join('\n  - ')}`);
    err.toolchain = r;
    err.code = 'TOOLCHAIN_REFUSED';
    throw err;
  }
  return r;
}


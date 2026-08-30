#!/usr/bin/env node
/**
 * RichOS local service — CLI.
 *
 *   richos-service watch                 # run the drop-zone watcher (pipeline trigger + reconcile net)
 *   richos-service run <sessionId|dir>   # run the pipeline over one session
 *   richos-service retranscribe <id> [--model large-v3]   # re-run stages 2-6 on retained audio
 *   richos-service reconcile             # report-only sweep (never transcribes) — the anomaly audit
 *   richos-service claim ...             # coordination (§5.4): own this call or stand down (no double)
 *   richos-service failover-scan         # browser-owned calls that went dark -> promotion candidates
 *   richos-service mark-superseded ...   # record a companion's takeover of a dead browser call
 *   richos-service learn-term ...        # correction flywheel: fold an explicit "the term is X" fix into loro entities
 *   richos-service learn-from-edits <id> # correction flywheel: propose (or --apply) term fixes from a CEO-edited transcript
 *   richos-service correct-text          # correction flywheel: apply the shared vocabulary to DICTATION text
 *   richos-service dictation-review ...  # correction flywheel: what to ASK about a corrected dictation (learns nothing)
 *   richos-service dictation-answer ...  # correction flywheel: the CEO's answer — the only way a dictation pair is learned
 *   richos-service dictation-asks        # the inspectable suppression list
 *   richos-service dictation-retention   # what persisting dictation costs, and what ages out
 *   richos-service doctor                # verify ffmpeg / whisper-cli / model are resolvable
 *
 * Common flags: --zone <dir> (override the drop zone), --model <id>.
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { runPipeline } from '../lib/pipeline.js';
import { scanZone, watch } from '../lib/watcher.js';
import { decideClaimOnDisk, findPromotableOnDisk, markSuperseded } from '../lib/coordination.js';
import { dropZone, ffmpegBin, whisperBin, resolveModel, resolveTier, MODEL_TIERS, DEFAULT_TIER, DEFAULT_MODEL, REPO_ROOT } from '../lib/config.js';
import { assertEvidenceOutsideProductRepo } from '../lib/workspace/privacy.js';
import { ffmpegVersion } from '../lib/normalize.js';
import { entitiesFilePath, loadEntityMemory } from '../lib/entities.js';
import { learnTerm, learnFromEdits, serializeEntitiesDoc } from '../lib/capture.js';
import { correctText } from '../lib/correct.js';
import { reviewSent, answerAsk, askKey, heardSide, MATCH_WINDOW_MS } from '../lib/dictation.js';
import {
  journalRoot, loadJournal, loadLedger, saveLedger, markReconciled, withConsumed,
  surveyJournal, sweepRetention, costPerHour,
  TEXT_RETENTION_DAYS, TEXT_RETENTION_RECORDS, AUDIO_RETENTION_DAYS, AUDIO_RETENTION_BYTES,
} from '../lib/dictation-store.js';
import { expand } from '../lib/config.js';
import { log } from '../lib/log.js';

function flag(name, fallback = null) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const v = process.argv[i + 1];
  return v && !v.startsWith('--') ? v : true;
}

/** Collect ALL values of a repeatable flag, e.g. --mangled "a" --mangled "b" -> ['a','b']. */
function flags(name) {
  const out = [];
  for (let i = 0; i < process.argv.length; i += 1) {
    if (process.argv[i] === `--${name}`) {
      const v = process.argv[i + 1];
      if (v && !v.startsWith('--')) out.push(v);
    }
  }
  return out;
}

function resolveSessionDir(arg, zone) {
  if (!arg) return null;
  if (arg.includes('/') || arg.includes(path.sep)) return path.resolve(arg);
  return path.join(zone, arg);
}

function main() {
  const cmd = process.argv[2];
  // `--zone` goes through the SAME refusal as the default: an explicit flag is not permission to
  // write the CEO's recordings into a publicly-shipping product repo.
  const zone = flag('zone')
    ? assertEvidenceOutsideProductRepo(path.resolve(String(flag('zone'))), REPO_ROOT, 'call recordings and transcripts')
    : dropZone();
  const model = flag('model') ? String(flag('model')) : undefined;
  const tier = flag('tier') ? String(flag('tier')) : undefined;

  switch (cmd) {
    case 'watch': {
      const handle = watch({ zone, model, tier });
      process.on('SIGINT', () => {
        handle.stop();
        process.exit(0);
      });
      process.on('SIGTERM', () => {
        handle.stop();
        process.exit(0);
      });
      break;
    }

    case 'run': {
      const dir = resolveSessionDir(process.argv[3], zone);
      if (!dir || !fs.existsSync(dir)) fail(`run: session directory not found: ${dir}`);
      const result = runPipeline(dir, { model, tier, zone });
      report(result);
      process.exit(result.status === 'ready' ? 0 : 2);
      break;
    }

    case 'retranscribe': {
      const dir = resolveSessionDir(process.argv[3], zone);
      if (!dir || !fs.existsSync(dir)) fail(`retranscribe: session directory not found: ${dir}`);
      // --tier max re-runs the retained audio through the opt-in accuracy tier (guarded large-v3).
      const result = runPipeline(dir, { model, tier, retranscribe: true, zone });
      report(result);
      process.exit(result.status === 'ready' ? 0 : 2);
      break;
    }

    case 'tiers': {
      // List the P5 model tiers (turbo default, max opt-in, low-resource/quantized fallback).
      console.log('RichOS model tiers (select with --tier <name>, or a raw --model <id>):\n');
      for (const [name, t] of Object.entries(MODEL_TIERS)) {
        const flagName = name === 'turbo' ? `${name} (default)` : name;
        console.log(`  ${flagName}\n    model: ${t.model}${t.decodeArgs.length ? `  decode: ${t.decodeArgs.join(' ')}` : ''}`);
        console.log(`    ${t.description}\n`);
      }
      break;
    }

    case 'reconcile': {
      const r = scanZone({ zone, process: false });
      console.log(`reconcile over ${zone}`);
      console.log(`  ok/skipped: ${r.skipped.length}`);
      if (r.anomalies.length) {
        console.log('\nANOMALIES — a call may not have a transcript:');
        for (const a of r.anomalies) console.log(`  ${a.sessionId}\n    - ${a.problems.join('\n    - ')}`);
        process.exit(2);
      }
      console.log('  no anomalies');
      break;
    }

    case 'claim': {
      // Surface-agnostic ownership handshake (§5.4). A companion (macOS now, Windows later) or the
      // extension asks the SHARED authority whether to own a call or stand down (avoid double-capture).
      const req = {
        surface: flag('surface') ? String(flag('surface')) : 'desktop-companion-macos',
        captureKind: flag('kind') ? String(flag('kind')) : 'system',
        processHint: flag('process-hint') ? String(flag('process-hint')) : null,
        sessionId: flag('session-id') ? String(flag('session-id')) : null,
      };
      const decision = decideClaimOnDisk(zone, req);
      console.log(JSON.stringify({ request: req, ...decision }, null, 2));
      process.exit(decision.decision === 'own' ? 0 : 3);
      break;
    }

    case 'failover-scan': {
      // What a companion polls to learn a browser-owned call went dark (crash/hang) and can be taken
      // over. Prints the promotion candidates; a companion then captures with ownership.supersedes.
      const candidates = findPromotableOnDisk(zone);
      console.log(JSON.stringify({ zone, candidates }, null, 2));
      process.exit(0);
      break;
    }

    case 'mark-superseded': {
      // Close the failover loop: record on the dead session that a companion has taken it over.
      const dead = flag('dead') ? String(flag('dead')) : null;
      const by = flag('by') ? String(flag('by')) : null;
      if (!dead || !by) fail('mark-superseded requires --dead <sessionId> --by <sessionId>');
      const ok = markSuperseded(zone, dead, by);
      console.log(JSON.stringify({ dead, by, marked: ok }, null, 2));
      process.exit(ok ? 0 : 1);
      break;
    }

    case 'learn-term': {
      // EXPLICIT correction intake (the correction flywheel's simple, reliable path). Rich runs this
      // on a direct CEO instruction: "the term is Deepgram, it came out as Deep Graham."
      //   learn-term --canonical "Deepgram" --mangled "deep graham" [--mangled ...] [--type product]
      //              [--alias "Deep Gram Inc"] [--fuzzy false] [--case-sensitive] [--min-score 0.8]
      //              [--file <entities.json>]
      const canonical = flag('canonical') ? String(flag('canonical')) : null;
      if (!canonical) fail('learn-term requires --canonical "<term>" (optionally one or more --mangled "<observed>")');
      const file = flag('file') ? path.resolve(String(flag('file'))) : entitiesFilePath();
      const doc = readEntitiesDoc(file);
      const input = {
        canonical,
        mangled: flags('mangled'),
        aliases: flags('alias'),
      };
      if (flag('type')) input.type = String(flag('type'));
      if (String(flag('fuzzy')) === 'false') input.fuzzy = false;
      if (flag('case-sensitive') === true) input.caseSensitive = true;
      if (flag('min-score')) input.minScore = Number(flag('min-score'));

      const res = learnTerm(doc, input);
      if (res.changed) {
        fs.writeFileSync(file, serializeEntitiesDoc(res.doc));
        log.info(
          `learned "${canonical}" (${res.created ? 'new entity' : 'merged'}) — ` +
            `+${res.added.mangled.length} mangling(s), +${res.added.aliases.length} alias(es); ` +
            `version -> ${res.doc.version}`,
        );
      } else {
        log.info(`no change — "${canonical}" already carries everything supplied`);
      }
      if (res.conflicts.length) log.alarm('learn-term conflicts (skipped)', { conflicts: res.conflicts });
      console.log(JSON.stringify({
        file, changed: res.changed, created: res.created, added: res.added,
        conflicts: res.conflicts, version: res.doc.version,
      }, null, 2));
      process.exit(0);
      break;
    }

    case 'learn-from-edits': {
      // TRANSCRIPT-EDIT diff intake (the richer path). A landed transcript.md the CEO edited to fix a
      // name is a correction signal: diff the working-tree file against its committed baseline and
      // PROPOSE conservative mangling->canonical pairs. Propose by default; --apply folds them in.
      //   learn-from-edits <sessionId|path/to/transcript.md> [--apply] [--baseline <path>] [--file <entities.json>]
      const arg = process.argv[3];
      if (!arg) fail('learn-from-edits requires a session id or a path to transcript.md');
      const editedPath = resolveTranscriptPath(arg, zone);
      if (!fs.existsSync(editedPath)) fail(`learn-from-edits: transcript not found: ${editedPath}`);
      const editedText = fs.readFileSync(editedPath, 'utf8');

      const baselineOverride = flag('baseline') ? path.resolve(String(flag('baseline'))) : null;
      const baselineText = baselineOverride
        ? fs.readFileSync(baselineOverride, 'utf8')
        : gitBaseline(editedPath);
      if (baselineText == null) {
        log.info(`no committed baseline for ${editedPath} (untracked or unchanged) — nothing to learn`);
        console.log(JSON.stringify({ transcript: editedPath, proposals: [], applied: false }, null, 2));
        process.exit(0);
      }

      const apply = flag('apply') === true;
      const file = flag('file') ? path.resolve(String(flag('file'))) : entitiesFilePath();
      const doc = readEntitiesDoc(file);
      const res = learnFromEdits(doc, baselineText, editedText, { apply });

      if (res.proposals.length === 0) {
        log.info('no high-confidence term corrections found in the edits');
      } else {
        for (const p of res.proposals) {
          log.info(`  proposal: "${p.from}" -> "${p.to}"  (confidence ${p.confidence})`);
        }
      }
      if (res.applied && res.proposals.length) {
        fs.writeFileSync(file, serializeEntitiesDoc(res.doc));
        log.info(`applied ${res.results.length} proposal(s) to ${file}; version -> ${res.doc.version}`);
      } else if (res.proposals.length) {
        log.info('proposals NOT applied (re-run with --apply to fold them into entities.json)');
      }
      console.log(JSON.stringify({
        transcript: editedPath, file, applied: res.applied,
        proposals: res.proposals, rejected: res.rejected,
        version: res.applied ? res.doc.version : doc.version,
      }, null, 2));
      process.exit(0);
      break;
    }

    case 'correct-text': {
      // THE DICTATION SIDE OF THE ONE SHARED VOCABULARY — the seam that made `entities.json` a
      // single-reader database. open-wispr calls this between whisper-cli and the paste, so a term
      // the CEO taught the system once is spelled right in dictation as well as in call transcripts.
      //
      // IT CALLS `correctText()`, THE EXACT FUNCTION THE CALL PIPELINE CALLS (`lib/correct.js`, via
      // `correct()` at `lib/pipeline.js`). Not a second implementation, not a lookup table built
      // beside it: one corrector, so dictation cannot drift from what a call transcript would say.
      //
      //   richos-service correct-text --text "..."      # or pipe the text on stdin
      //
      // FAILURE POSTURE: this sits in the paste path of a dictation. It must NEVER be the reason a
      // dictation produces nothing, so every failure below echoes the input back unchanged and
      // reports on stderr. Correction is an accuracy enhancement, never a dependency.
      const text = flag('text') && flag('text') !== true ? String(flag('text')) : readStdin();
      try {
        const file = flag('file') ? path.resolve(String(flag('file'))) : entitiesFilePath();
        const mem = loadEntityMemory(file);
        const res = correctText(text, mem.entities);
        if (flag('json') === true) {
          console.log(JSON.stringify({
            text: res.text, corrections: res.corrections,
            entitiesVersion: mem.entitiesVersion, entitiesSource: mem.source,
          }, null, 2));
        } else {
          process.stdout.write(res.text);
        }
      } catch (err) {
        process.stderr.write(`correct-text: ${String(err.message || err)} — passing the text through unchanged\n`);
        process.stdout.write(text);
      }
      process.exit(0);
      break;
    }

    case 'dictation-review': {
      // ASK, NEVER INFER (ceo-decisions.md §7). Given what the CEO actually sent, find the dictation
      // it came from and report what is worth ASKING about. It learns NOTHING — there is deliberately
      // no `--apply` on this command at all. `dictation-answer` is the only way a pair is learned,
      // and it requires a human answer.
      //
      //   richos-service dictation-review --sent "..." [--journal <dir>] [--now <ms>]
      const sent = flag('sent') && flag('sent') !== true ? String(flag('sent')) : readStdin();
      if (!sent.trim()) fail('dictation-review requires --sent "<what you sent>" (or the text on stdin)');
      const root = flag('journal') ? expandPath(String(flag('journal'))) : journalRoot();
      const now = flag('now') ? Number(flag('now')) : Date.now();
      const ledger = loadLedger(root);
      const journal = withConsumed(loadJournal({ root, sinceMs: now - MATCH_WINDOW_MS }), ledger);
      const res = reviewSent(journal, sent, ledger, { now });
      console.log(JSON.stringify({
        journal: root,
        matched: res.matched,
        // What was PASTED, which is what he edited — not the recogniser's raw output. See
        // `heardSide`: reporting `text` here would name a sentence he never saw.
        entry: res.entry ? { id: res.entry.id, at: res.entry.at, heard: heardSide(res.entry) } : null,
        similarity: res.similarity ?? null,
        reason: res.reason,
        // These are QUESTIONS. Answer one with `dictation-answer --from ... --to ... --confirm`.
        prompts: res.prompts,
        suppressed: res.suppressed,
        // Returned, not discarded: silence that cannot be audited cannot be trusted.
        rejected: res.rejected,
      }, null, 2));
      process.exit(0);
      break;
    }

    case 'dictation-answer': {
      // THE HUMAN STATEMENT. The one place in the dictation flywheel where the system's beliefs
      // change, and it cannot be reached except by someone answering the question.
      //
      //   richos-service dictation-answer --from "deep graham" --to "Deepgram" --confirm
      //   richos-service dictation-answer --from "..." --to "..." --decline   # ask again next repeat
      //   richos-service dictation-answer --from "..." --to "..." --never     # permanently suppressed
      const from = flag('from') && flag('from') !== true ? String(flag('from')) : null;
      const to = flag('to') && flag('to') !== true ? String(flag('to')) : null;
      if (!from || !to) fail('dictation-answer requires --from "<what was heard>" --to "<the term>" and one of --confirm | --decline | --never');
      const answer = flag('confirm') === true ? 'confirm' : flag('never') === true ? 'never' : flag('decline') === true ? 'decline' : null;
      if (!answer) fail('dictation-answer requires exactly one of --confirm | --decline | --never');

      const root = flag('journal') ? expandPath(String(flag('journal'))) : journalRoot();
      const ask = { from, to, key: askKey(from, to) };
      let ledger = loadLedger(root);
      const res = answerAsk(ledger, ask, answer);
      ledger = { ...ledger, ...res.ledger };
      if (flag('entry') && flag('entry') !== true) ledger = markReconciled(ledger, String(flag('entry')));
      saveLedger(ledger, root);

      let learned = null;
      if (res.learn) {
        // A confirmed ask is an EXPLICIT correction, so it goes in by the explicit path — the same
        // `learnTerm` `richos-service learn-term` uses. One writer of the vocabulary, one set of
        // conflict rules, one version bump.
        const file = flag('file') ? path.resolve(String(flag('file'))) : entitiesFilePath();
        const doc = readEntitiesDoc(file);
        const r = learnTerm(doc, { canonical: res.learn.canonical, mangled: res.learn.mangled, type: flag('type') ? String(flag('type')) : undefined });
        if (r.changed) fs.writeFileSync(file, serializeEntitiesDoc(r.doc));
        learned = { file, changed: r.changed, created: r.created, added: r.added, conflicts: r.conflicts, version: r.doc.version };
        log.info(`learned "${res.learn.canonical}" from a confirmed dictation correction — version -> ${r.doc.version}`);
      } else {
        log.info(`"${to}": ${res.outcome}`);
      }
      console.log(JSON.stringify({ ask, answer, outcome: res.outcome, learned }, null, 2));
      process.exit(0);
      break;
    }

    case 'dictation-asks': {
      // THE SUPPRESSION LIST MUST BE INSPECTABLE (§7) — or a term silently refuses to learn with no
      // way to see why.
      const root = flag('journal') ? expandPath(String(flag('journal'))) : journalRoot();
      const ledger = loadLedger(root);
      console.log(JSON.stringify({
        journal: root,
        suppressed: ledger.suppressed,
        declined: ledger.declined,
        reconciledEntries: (ledger.reconciled || []).length,
        override: 'richos-service learn-term --canonical "<term>" --mangled "<observed>" overrides any suppression',
      }, null, 2));
      process.exit(0);
      break;
    }

    case 'dictation-retention': {
      // What persisting dictation actually costs, and what the policy would erase. DRY RUN BY
      // DEFAULT: the first thing anyone should be able to do with a policy that deletes the CEO's
      // speech is read it.
      const root = flag('journal') ? expandPath(String(flag('journal'))) : journalRoot();
      const apply = flag('apply') === true;
      const survey = surveyJournal(root);
      const plan = sweepRetention({ root, dryRun: !apply });
      const cost = costPerHour(loadJournal({ root }));
      console.log(JSON.stringify({
        journal: root,
        policy: {
          tierA: `text: ${TEXT_RETENTION_DAYS} days OR ${TEXT_RETENTION_RECORDS} records, whichever binds first`,
          tierB: `audio: OFF by default; when on, ${AUDIO_RETENTION_DAYS} days OR ${AUDIO_RETENTION_BYTES} bytes, whichever binds first`,
        },
        onDisk: {
          dayFiles: survey.days.length,
          records: survey.days.reduce((a, d) => a + d.records, 0),
          textBytes: survey.days.reduce((a, d) => a + d.bytes, 0),
          audioFiles: survey.audio.length,
          audioBytes: survey.audio.reduce((a, x) => a + x.bytes, 0),
        },
        costPerHourOfDictation: cost,
        dryRun: plan.dryRun,
        evict: {
          dayFiles: plan.evictDays.map((d) => ({ day: d.day, records: d.records, bytes: d.bytes, why: d.why })),
          records: plan.evictedRecords,
          audioFiles: plan.evictAudio.length,
          audioBytes: plan.evictedAudioBytes,
        },
      }, null, 2));
      process.exit(0);
      break;
    }

    case 'doctor': {
      let ok = true;
      try {
        console.log(`ffmpeg:     ${ffmpegBin()}  (${ffmpegVersion()})`);
      } catch (err) {
        ok = false;
        console.log(`ffmpeg:     MISSING — ${String(err.message || err)}`);
      }
      try {
        console.log(`whisper:    ${whisperBin()}`);
      } catch (err) {
        ok = false;
        console.log(`whisper:    MISSING — ${String(err.message || err)}`);
      }
      const resolvedTier = resolveTier(tier || model);
      try {
        console.log(`tier:       ${resolvedTier.name} -> model ${resolvedTier.model}${
          resolvedTier.decodeArgs.length ? ` (decode: ${resolvedTier.decodeArgs.join(' ')})` : ''
        }`);
        console.log(`model:      ${resolveModel(resolvedTier.model)}`);
      } catch (err) {
        // A missing tier model is only fatal if that tier was explicitly requested; the default
        // turbo model must resolve.
        const fatal = !tier && !model ? true : resolvedTier.name === DEFAULT_TIER;
        if (fatal) ok = false;
        console.log(`model:      ${fatal ? 'MISSING' : 'not installed (opt-in tier)'} — ${String(err.message || err)}`);
      }
      console.log(`drop zone:  ${zone}`);
      process.exit(ok ? 0 : 1);
      break;
    }

    default:
      console.log(
        [
          'usage:',
          '  richos-service watch [--zone dir] [--tier turbo|max|low-resource|quantized]',
          '  richos-service run <sessionId|dir> [--zone dir] [--tier name | --model id]',
          '  richos-service retranscribe <sessionId|dir> [--tier max | --model id]',
          '  richos-service tiers',
          '  richos-service reconcile [--zone dir]',
          '  richos-service claim --surface <s> --kind <browser-tab|system|process> [--process-hint h] [--session-id id]',
          '  richos-service failover-scan [--zone dir]',
          '  richos-service mark-superseded --dead <sessionId> --by <sessionId>',
          '  richos-service learn-term --canonical "<term>" [--mangled "<observed>" ...] [--type t] [--alias a ...] [--fuzzy false] [--case-sensitive] [--min-score n] [--file f]',
          '  richos-service learn-from-edits <sessionId|path/to/transcript.md> [--apply] [--baseline path] [--file f]',
          '  richos-service correct-text [--text "..."] [--json] [--file f]      # dictation reads the SAME vocabulary as calls',
          '  richos-service dictation-review --sent "<what you sent>" [--journal dir]   # ASKS; learns nothing',
          '  richos-service dictation-answer --from "<heard>" --to "<term>" (--confirm|--decline|--never) [--entry id]',
          '  richos-service dictation-asks [--journal dir]                      # the inspectable suppression list',
          '  richos-service dictation-retention [--apply] [--journal dir]       # what it costs, and what ages out',
          '  richos-service doctor',
        ].join('\n'),
      );
      process.exit(cmd ? 1 : 0);
  }
}

/** `~`-expanding path resolve, so `--journal ~/...` behaves the way every other path flag does. */
function expandPath(p) {
  return path.resolve(expand(p));
}

/**
 * Read all of stdin, synchronously. `correct-text` sits in the paste path of a dictation, so a
 * pipe is the natural interface and blocking is correct: there is nothing else to do until the
 * sentence has arrived. A closed/absent stdin yields '' rather than throwing.
 */
function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

/** Read the raw entities.json doc (preserving its structure for round-trip write). Missing => a fresh doc. */
function readEntitiesDoc(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return { schemaVersion: 1, version: '', entities: [] };
  }
}

/** Resolve a transcript.md from a session id, a session dir, or a direct file path. */
function resolveTranscriptPath(arg, zone) {
  const p = arg.includes('/') || arg.includes(path.sep) ? path.resolve(arg) : path.join(zone, arg);
  if (p.endsWith('.md')) return p;
  return path.join(p, 'transcript.md');
}

/**
 * The committed (HEAD) version of a git-tracked transcript IS the emitted baseline — the CEO's
 * uncommitted working-tree edits are exactly the correction signal we want. Using git avoids any
 * extra retained-copy machinery and captures precisely those edits. Returns null when the file is
 * untracked or unchanged (nothing to learn).
 */
function gitBaseline(absPath) {
  const rel = path.relative(REPO_ROOT, absPath);
  try {
    // `-C REPO_ROOT` so this works from any cwd; the working tree may live in a git worktree.
    const committed = execFileSync('git', ['-C', REPO_ROOT, 'show', `HEAD:${rel}`], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const current = fs.readFileSync(absPath, 'utf8');
    return committed === current ? null : committed;
  } catch {
    return null; // not tracked at HEAD
  }
}

function report(result) {
  if (result.status === 'ready') {
    log.info(`READY ${result.sessionId} — ${result.words} words -> ${result.transcript}`);
  } else {
    log.alarm(`${result.status.toUpperCase()} ${result.sessionId}`, { problems: result.problems });
  }
}

function fail(msg) {
  log.error(msg);
  process.exit(1);
}

main();

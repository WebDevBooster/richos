# Escape-hatch census, and whether anything notices a habit — 2026-09-14

Every number below carries the command that produced it. Re-run them; none of
this is asserted.

## The question

> Do the engine's escape hatches have a mechanism that notices when one has
> become a habit, and if not, should they?

**They do, and it was already built.** `notice-waiver-repetition.{sh,py}` is a
non-blocking Stop hook, registered in `engine/hooks/hooks.json`, with a lint CLI
(`engine/scripts/waiver-repetition-lint.sh`), a 35-case suite and a 22-mutant
harness. It has no escape hatch and no config key, deliberately. Its own
docstring argues every constant from the real ledgers.

**It could not see the hatch that prompted the question.** That was the finding,
and the three commits accompanying this record fix it.

## Correcting the brief

| Claim in the brief | What the code says |
|---|---|
| `"ALREADY ACKED 26 TIME(S) in this repository"` is NOT in `guard-ci-red-lands.sh` | It IS — `engine/scripts/hooks/guard-ci-red-lands.sh:761`, as a `%d` template. A literal grep for the rendered sentence misses it. |
| unsourced: that `guard-ci-red-lands.sh` counts and prints hatch usage | TRUE. It reads its own log before writing (`:632-641`), prints `ALREADY ACKED %d TIME(S)` in a refusal, and on an accepted ack prints `THIS IS ACK NUMBER %d FOR THIS WORKFLOW … Fix it or delete it.` It is the best-instrumented hatch in the engine. |
| unsourced: the number of acks written that evening | 21 — 13 on 2026-09-13, 8 on 2026-09-14. |
| unsourced: the hatch list is near-complete | It was a good start. The derived census is 22 ledgers plus a distinct class of in-file markers the list did not mention. |

Reproducing the "26":

```
awk -F'\t' '$2=="WebDevBooster/richos" && $3=="engine-self-verify.yml"' \
    ~/.claude/state/ci-red-acks.log | sed -n '27p'
# 2026-09-13T23:41:35Z  WebDevBooster/richos  engine-self-verify.yml  merge  this land IS part of the fix: …
```

The 27th ack of that workflow was written at `2026-09-13T23:41:35Z`, so the
refusal immediately before it said 26. The lead's account was accurate.

## The defect: the most-used hatch in the engine was invisible to the watcher

```
$ bash engine/scripts/waiver-repetition-lint.sh /Users/alex/ab/femcboost
```

Before these commits, `ci-red-acks.log` appeared in **none** of the report's
three buckets — not as a derived hatch, not as "never used", not on the
"claimed by no guard" line. Three independent causes, each silent:

1. **The disk side never looked there.** `state_dirs_for()` listed the entity's
   `.claude/state` and the session team directories. `guard-ci-red-lands.sh:224`
   writes to `${CI_RED_ACK_LOG:-$HOME/.claude/state/ci-red-acks.log}` — outside
   every repository, correctly, because one operator lands into several.
2. **The name crossed a language boundary.** `:224` (shell) → `:608`
   `log_path = os.environ["ACK_LOG"]` → `:694` `open(log_path, "a")`. The
   variable-to-variable resolver followed only the shell spelling `$VAR`.
3. **The vocabulary could not read the past tense.** The append site's context
   says "Every red workflow was **acked** with a real reason" and carries an
   `acked_before` count two lines up. `HATCH_VOCAB` required the word to end at
   `ack`, so even once the name resolved the ledger was filed as a plain record
   and never analyzed.

Each failure mode produces a *shorter, cleaner* report — the exact hazard the
analyzer's own docstring warns about one input over: *"A SCAN THAT STOPS
MATCHING PRODUCES A SHORTER LIST, SILENTLY."*

## Counts

### The hatch in question

```
$ wc -l < ~/.claude/state/ci-red-acks.log
93
$ awk -F'\t' '{print $2"\t"$3}' ~/.claude/state/ci-red-acks.log | sort | uniq -c | sort -rn
  40 WebDevBooster/richos-hq   windows-companion-ci.yml
  35 WebDevBooster/richos      engine-self-verify.yml
  10 WebDevBooster/richos      engine-run-record.yml
   4 WebDevBooster/richos      ui-suite-ci.yml
   4 WebDevBooster/richos      app-voice-ci.yml
$ cut -f1 ~/.claude/state/ci-red-acks.log | cut -dT -f1 | sort | uniq -c
  16 2026-09-10
  22 2026-09-11
  34 2026-09-12
  13 2026-09-13
   8 2026-09-14
```

Not characterized here as high or low. They are the numbers.

### Every derived hatch ledger, femcboost as the entity

```
$ bash engine/scripts/waiver-repetition-lint.sh /Users/alex/ab/femcboost
```

| ledger | entries | read by | flagged as repeated |
|---|---|---|---|
| `ceo-ruled-exempts.log` | 3 | waiver watch | no |
| `ceo-todos-defers.log` | 333 | waiver watch | 23 classes, 287 entries |
| `ci-red-acks.log` | 93 | waiver watch **(new)**, and by its own guard at every use | 4 classes, 74 entries |
| `conceal-acks.log` | never used | waiver watch | no |
| `data-contract-bypasses.log` | 550 | waiver watch | 3 classes, 38 entries |
| `definition-drift-acks.log` | 35 | waiver watch | 1 class, 35 entries |
| `definition-drift.log` | 16 | waiver watch | 1 class, 9 entries |
| `generic-agent-dispatches.log` | 1 | waiver watch | no |
| `hand-roll-acks.log` | 1 | waiver watch | no |
| `inflight-waivers.jsonl` | 12 | waiver watch | 1 class, 12 entries |
| `main-checkout-runs.log` | 45 | waiver watch | 1 class, 42 entries |
| `model-ceiling-acks.log` | 75 | waiver watch | 10 classes, 62 entries |
| `model-downgrade-acks.log` | never used | waiver watch | no |
| `owned-state-acks.log` | never used | waiver watch | no |
| `owned-state-dispositions.log` | 6 | waiver watch | no |
| `resume-acks.log` | 232 | waiver watch | 4 classes, 113 entries |
| `stale-staging-acks.log` | never used | waiver watch | no |
| `stop-work-acks-used.log` | 2 | waiver watch | no |
| `stop-work-acks.jsonl` | 2 | waiver watch | no |
| `unevaluated-payloads.log` | 32 | waiver watch | no |
| `vendoring-acks.log` | never used | waiver watch | no |
| `worktree-remove-acks.log` | 112 | waiver watch | 1 class, 4 entries |

`definition-drift.log` is a known misclassification the analyzer documents
itself: it records agent creations, and the hatch vocabulary appears near its
append site because the real hatch is written eleven lines away.

**So the answer to "does anything ever READ that log" is: yes, all of them, at
every turn end, by a Stop hook and by a lint that runs the same code.** That was
already true before this work for 21 of the 22. The gap was never an unread log;
it was one ledger nothing knew to read.

### The other class: markers that write no ledger at all

These are **in-file** declarations, not prompt or command-line markers. They
leave no ledger row, and they do not need one: the marker stays in the committed
file where a reviewer sees it and a `grep` counts it. This is a different design,
not a missing one.

```
$ cd <richos>; grep -rIo -- "dialect-exempt:" . | wc -l
38
$ grep -rIo -- "entrypoint-exempt:" . | wc -l
15
$ grep -rIo -- "finding-exempt:" . | wc -l
10
$ grep -rIo -- "loro-caps-exempt:" . | wc -l
6
```

These are occurrences of the literal string, which include each guard's own
definition and documentation of its marker. They are an upper bound on use, not
a usage count, and are marked that way deliberately.

`registry-write-exempt:` matched nothing in `engine/scripts/`; it is not a live
engine marker at this SHA. `--ignored-not-needed` is a `workspaces.sh` flag, not
a guard waiver. `inflight-notify` waivers DO leave a ledger —
`inflight-waivers.jsonl`, 12 entries, already read.

### Ledgers on disk that no guard in the engine claims

`ceo-asks.jsonl`, `ceo-inputs.jsonl`, `claim-checks.jsonl`,
`cleanup-delivery-*-journal.jsonl`, `full-suite-acks.log`,
`idle-land-checks.jsonl`, `inflight-acks.jsonl`, `inflight-notices.jsonl`,
`quota-samples.jsonl`, `stated-actions.jsonl`, `turn-manifests.jsonl`,
`worker-events.jsonl`, `worktree-ledger.jsonl`, `worktree-reconciler.log`.

`full-suite-acks.log` is the suite-cost acknowledgement the brief named. Its
writer is a femcboost-local hook, not an engine script, so the engine-side scan
cannot attribute it — it is reported rather than dropped, which is the correct
behavior.

## What was built, and why not more

The honest finding is that **no new mechanism was warranted.** The mechanism
existed, was argued, was tested, and was right. Three narrow repairs made it
able to see what it was built to see, and a fourth changed which three things it
names.

1. `035c708f` — the disk side reads the machine-wide state directory, derived
   from `CLAUDE_CONFIG_DIR` (never `$HOME`, so the suite's sandbox still seals).
2. `6e2e3553` — `_var_refs()` follows `os.environ[...]` / `os.getenv(...)`, and
   `HATCH_VOCAB` reads `acked` / `acking`. Measured across the whole engine
   before the change: exactly one ledger promoted, none demoted.
3. `3b98ad18` — the one-liner orders by `(idle_days // RECENCY_BUCKET, -size)`.

**Ideas measured and rejected:**

- *Report every append site whose ledger could not be resolved.* Measured: 33
  such lines today, of which roughly a third are comments, docstrings and
  regexes containing `>>`, and most of the rest are appends to temp files and
  manifests that are not ledgers at all. That report is wallpaper, which the
  brief forbids. The existing "ON DISK, CLAIMED BY NO GUARD" bucket does the
  same job honestly, and commit 1 is what gives it the directory to do it in.
- *A blocking counter, or making a habitual hatch harder to use.* Rejected for
  the reason the analyzer already gives: in every case measured the waiver was
  the correct act, and a blocking waiver-watcher would itself need an escape
  hatch.

## What a person actually sees

The single sentence the Stop hook puts on the operator's screen, against the
real ledgers, produced by
`python3 engine/scripts/hooks/notice-waiver-repetition.py --engine-root <engine> --entity-root /Users/alex/ab/femcboost --one-liner`:

**Before (`035c708f~1`):**

```
REPEATED WAIVERS, NOT EXCEPTIONS — 9 escape hatches were used over and over for
the same reason instead of the guard being fixed: guard-resume-isolation.sh (86x
one reason, 40 subjects over 6 days), guard-ceo-ask-first.sh (46x one reason, 44
subjects over 3 days), guard-worktree-isolation.sh (42x one reason, 42 subjects
over 2 days) (+6 more). Each repeat is a false-positive class the guard STILL
HAS. Detail: scripts/waiver-repetition-lint.sh
```

**After all three commits:**

```
REPEATED WAIVERS, NOT EXCEPTIONS — 10 escape hatches were used over and over for
the same reason instead of the guard being fixed: guard-ceo-ask-first.sh (46x one
reason, 44 subjects over 3 days), guard-ci-red-lands.sh (40x one reason, over 3
days), guard-model-ceiling.sh (14x one reason, 14 subjects over 2 days) (+7
more). Each repeat is a false-positive class the guard STILL HAS. Detail:
scripts/waiver-repetition-lint.sh
```

Two of the three names changed. The two displaced classes had been idle 12 and
14 days; all three now named were used within the last day, and the second is
the hatch this investigation started from.

## Why it stays quiet when things are fine

Three independent brakes, each asserted by a case that fails if the brake is
removed:

- **One waiver says nothing, and two say nothing** (cases 1, 2). Only the third
  use of the same reason speaks.
- **A fixed guard stops being reported.** `ACTIVE_DAYS = 14` from a class's last
  use (case 8; mutant `window-removed`).
- **The line is state-change de-duplicated.** The key is the SET of flagged
  hatches plus each one's largest class rounded down to a power of two, so a new
  hatch speaks, a fixed one going quiet speaks, a doubling speaks — and 88
  ticking to 89 does not (case 14; mutant `state-key-frozen`).

`RECENCY_BUCKET` orders only; it never includes or excludes. Removing every
flagged class returns the session to a one-time "clear again" line and then
silence (cases 15e, 15g).

## Load-bearing proof

Each change has a mutant that reverts it in a scratch copy and shows the signal
disappear:

```
$ bash engine/scripts/hooks/waiver-repetition.test.sh
  PASS  machine-state-unread — removing it turns "15f. a ledger in the machine-wide state directory is read" red
  PASS  env-hop-unfollowed — removing it turns "11b. a ledger named across the shell/environment/Python hop is derived and analyzed" red
  PASS  past-tense-unmatched — removing it turns "11b. a ledger named across the shell/environment/Python hop is derived and analyzed" red
  PASS  ordered-by-size-alone — removing it turns "21. a live class is named before a larger dormant one" red
  22 mutants killed, 0 survived
  35 passed, 0 failed
```

The harness earned its keep on this change: `RECENCY_BUCKET` displaced the line
that the `window-removed` mutant anchored on, and the harness refused to apply
it and reported source drift rather than counting a phantom kill. The anchor was
re-pointed.

## Handoff note for the lander

`notice-waiver-repetition.py` is on `install.sh`'s hash list
(`engine/scripts/hooks/install.sh:493`) and the `.sha256` sidecars are
gitignored. **Re-run `install.sh` after merging**, or the probe's hash layer goes
red on a file that is correct.

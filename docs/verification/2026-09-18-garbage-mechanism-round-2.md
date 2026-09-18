# The garbage mechanism, round 2 — deny-by-default, a garbage alarm, and a pid that is not a liveness test

**Date:** 2026-09-18
**Agent:** zach-opus-garbage2 (Infrastructure Engineer)
**Branch:** `cc/zach-opus-garbage2`
**Base:** richos main `47b79358`
**Closes:** the defeats in `docs/verification/2026-09-18-garbage-mechanism-attacked.md`
(frank-opus-garbage1), escalation `esc-20260918T091550Z-8d175065`
**Ruling:** CEO §54 — *"ROCK-SOLID, UNBREAKABLE, UNDEFEATABLE mechanisms that always guarantees
that garbage like this will be always cleaned up afterwards. Or if the clean-up fails or impossible
for some reason, then Rich must get a MASSIVE ALERT about it and get on with manually deleting the
garbage if it fails to be deleted automatically."*

Every number below is a command's output taken on this machine. Where something could not be
established it says so. Every fixture was built under this session's own scratchpad with a sandbox
`TMPDIR`, a sandbox `CLAUDE_CONFIG_DIR` and a sandbox config file; the real `$TMPDIR`, the real
ledger, the real state files and the two launchd jobs were never written. §10 shows the teardown.

---

## 1. Fix 3(a) — a VERIFICATION, not a change. D5 is already closed on main.

Frank's D5 is the one defeat that runs the wrong way: the allocator arm deleting a tree a live
process is reading. `zach-opus-testinst1` closed it at `00bb72c2` before this pass started, so the
job here was to re-run the reproduction against main and only touch the wall if it failed.

**It did not fail.** Frank's fixture, in shape byte for byte — a directory under the allocator root
named for a dead owner pid (99999998), with a live `tail -f` holding a file open inside it:

```
=== D5 REPRODUCTION, re-run against main 47b79358 ===
fixture:  .../tmp/richos-scratch/99999998-frank-openheld-a   (owner pid 99999998, dead)
holder :  tail -f .../99999998-frank-openheld-a/held.lock  (pid 26689, alive)
lsof sees it: 26689

--- scratch-reaper.sh --dry-run --verbose ---
KEEP              2.0 MB  .../richos-scratch/99999998-frank-openheld-a
                          why: pid 99999998 is ended, but a LIVE process holds a file open
                               inside this tree — the allocation being over does not make a
                               tree something is reading garbage

--- scratch-reaper.sh --apply ---
verdict: decided deletable=0 reclaimable=0 B kept=1 undecidable=0
applied: deleted=0 freed=0 B

RESULT: KEPT — the tree a live process is reading survived --apply
holder pid 26689 still running
```

**The positive control, in the same run** — because every assertion above also passes against an arm
that has simply stopped deleting anything:

```
--- POSITIVE CONTROL: holder killed, same tree, --apply again ---
  why: pid 99999998 is ENDED (owner of 'unrecorded', from the directory name) and nothing
       has touched this for 0 min; its TTL was 360 min
verdict: decided deletable=1 reclaimable=2.0 MB kept=0 undecidable=0
applied: deleted=1 freed=2.0 MB
CONTROL OK: with the holder gone the same allocation IS deleted
```

The wall lives at `scripts/lib/scratch-reaper.py:914-952` and its regression case is S19/S19b/S19c in
`scripts/scratch-reaper.test.sh`. Nothing in this pass changes it. The reproduction script is not
committed: it is thirty lines that build a fixture the suite already builds, and S19 is the durable
form of it.

**Also re-derived from `00bb72c2`, because the D5 fix rested on it:** `holder()` asks `lsof +D` for a
directory rather than `lsof -t -- <path>`. The old form asked who had the directory NODE open and
answered "nobody" about a tree a live process was writing into — the same defect one level down, in
the arm that exists to protect a live agent workspace. Confirmed present at `scratch-reaper.py:1320-1324`.

---

## 2. Fix 1 — deny-by-default over `$TMPDIR` and `/private/tmp` (D1, D2)

### 2.1 The census BEFORE, re-derived rather than quoted

Frank's D1 was re-measured here before anything was built on it, with the config's own two
pattern lists:

```
root: /var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T
direct children: 60,942
covered by a declared pattern :  4,172 entries, 0.08 GB
INVISIBLE to every arm        : 56,770 entries, 1.95 GB

root: /private/tmp
direct children: 764   (of which 97 are root-owned)
swept by any arm before today: 1  (claude-501, by its own arm)
```

Frank measured 52,409 / 1.90 GB the same morning; the machine has run for four more hours since.
**The number that is not a byte count is the one that decides the design:**

```
$ grep -rln 'owned-wake-native' /Users/alex/ab/richos/richos    -> (no matches)
```

The largest invisible family — `richos-owned-wake-native-*`, 42 direct children, 198 MB, oldest
9.1 days — **has no creator anywhere in the tree**. An allowlist can only contain names somebody
read off a creator, so the enumeration cannot converge and every future family arrives invisible in
exactly the same way. That is the whole argument for inverting it, and it is not about the 1.95 GB.

Two other things the census established that the brief did not say:

- **`work-host-*` (85 children) is the app's own, from `richos-core/src/work_host.rs`** — a live
  instance of D4 (the app's 61 `temp_dir()` sites), and the only reason it is not garbage on this
  disk today is that it is younger than the age floor.
- **Almost everything invisible is OURS, not other people's.** The foreign share is 2,831 of 60,943
  under `$TMPDIR` and 8 of 764 under `/private/tmp`. That asymmetry is what makes a keep-list short.

### 2.2 What was built

`scan_unknown` (`scripts/lib/scratch-reaper.py`) decides every direct child of `$TMPDIR` and of each
`SCRATCH_SHARED_TMP_ROOTS` entry that no other arm claims. **The deletion proof is not the age.** It
is the one `scan_orphan` already uses on loose files in a claude scratch root: the newest mtime in
the tree predates the start of EVERY running session process, so no running session can have written
it and none can write it again. Four conditions sit on top and each can only make the arm refuse:
owned by this uid; past `SCRATCH_UNKNOWN_AGE_HOURS`; nothing holds a file open inside it; all four
walls.

**The arm runs LAST and is the only one allowed to be cut short.** It is the expensive one — it
walks every child of two whole roots rather than the few a glob picks out — so a `--notice` run that
exhausts its budget loses this arm's numbers instead of the whole pass, and says how many entries it
did not reach.

### 2.3 Two things the brief prescribed that the measurement changed

**(a) The legacy pattern list is NOT redundant and has NOT been deleted.** Frank's Fix 1 says the
families "become redundant under deny-by-default and can be deleted from the config". They do not:
they are the FAST LANE. A legacy family is swept at two hours because the 105 GB directory reached
that size inside one run; this arm's floor is measured in days. Removing the list would trade a
two-hour reclaim for a three-day one on exactly the family that filled the disk. What changes is the
list's JOB — it is no longer the coverage, it is a fast lane on top of coverage that no longer
depends on it, so it can now shrink to nothing without losing anything.

**(b) `SCRATCH_UNKNOWN_GIT_IS_FIXTURE` was written as 0 and the measurement changed it to 1.** With
wall 2 standing in full the arm returned:

```
TOTAL INDETERMINATE   327 entries   288,360,636 bytes    — and ALL 327 are wall 2
   other-<pid>-wt  93     richos-owned-wake-native  49    census-git/-gitnr  4
   detect-nonnative-worktree 1   guard-sealed-test 1   engine-status 1   ... 177 families
```

Not one is a checkout; every one is a harness building a throwaway repository, and the largest
family's creator no longer exists to be fixed. 327 permanently undecidable entries mean exit 3 for
ever, which is the unclearable-noise failure that already settled the same question for the legacy
families. Wall 3 is untouched and is what protects a real checkout — proven by S21j/S21k and by the
plan itself (§2.4).

### 2.4 The census AFTER — the shipped code, dry run, on the real disk

```
$ scripts/scratch-reaper.sh --json          (11.6 s, full pass, no budget)

class                action            count          bytes
claude-orphan        DELETE                1             64
claude-orphan        INDETERMINATE         1           2176
claude-orphan        KEEP                278      114006688
claude-session       KEEP                  1              0
nightly-log          KEEP                  3         577536
nightly-release      KEEP                  3      306869056
tmp-foreign          KEEP               2934     1125454451
tmp-legacy           KEEP               3669       81404907
tmp-unknown          DELETE            12945      325069357
tmp-unknown          INDETERMINATE        23      164580800
tmp-unknown          KEEP              41646      494449888

TOTAL DELETE            12946      325069421  (0.33 GB)
TOTAL INDETERMINATE        24      164582976  (0.16 GB)
TOTAL KEEP              48534     2122762526  (2.12 GB)
```

**Before: 56,770 entries and 1.95 GB that no arm considered, reported as nothing at all. After:
every one of them carries a verdict and a reason.**

- **12,945 entries / 0.33 GB are collectable** where the count and the bytes were both zero.
- **41,646 are KEPT and the reasons are the proofs**: 34,874 "touched after the earliest running
  session process started" (one session has been up since Wed Sep 16 23:31:27 UTC, so nothing from
  the last day and a half is a candidate), the rest inside the 72 h floor.
- **2,934 / 1.13 GB are FOREIGN** — counted and named rather than skipped. The largest is
  `com.microsoft.VSCode.ShipIt.V5TnjgtN` at 942 MB, which nothing on this machine will ever collect
  and which is now at least *visible*. That is the number Fix 2 puts in front of Rich.
- **The two structural walls fired on the real disk**, which is where the evidence for them lives
  because the hermetic suite cannot create another user's file: `uid-kept entries: 94` (every
  root-owned `tmp-mount-*` in `/private/tmp`) and `symlink-kept: 1` (`/private/tmp/sage-sb`).
- **24 INDETERMINATE, and 23 of them are wall 3** — `richos-owned-wake-native-*/workspace` rows that
  are still in the worktree ledger pointing at nine-day-old temp fixtures. **This is wall 3 working,
  and it names a real second-order problem:** stale ledger rows make dead fixture garbage permanently
  undecidable. Pruning them is the ledger's business, not the reaper's, and Fix 2 is what makes the
  0.16 GB visible so somebody does it.

### 2.5 A defect this pass found on the way, and it was in the primitive underneath

`lstart_epoch` converted `ps -o lstart=` (taken under `TZ=UTC0`) with
`mktime(strptime(text)) - time.timezone`. `time.timezone` is the zone's **standard** offset and does
not move for daylight saving, so **in DST every process start was reported one hour early**:

```
timezone 0   altzone -3600   daylight 1   tm_isdst 1
ps lstart (TZ=UTC0): Fri Sep 18 10:13:15 2026
shipped lstart_epoch -> 1789722795
correct  (timegm)    -> 1789726395    (== time.time() to the second)
error                -> -3600
```

It failed in the safe direction — an hour-early start means "nothing running can own this" is
answered *no* more often, so trees were KEPT that could have been swept — which is why it survived:
an hour of lost coverage every run, in the one primitive the claude-orphan rule and the new arm both
rest on, reported by nothing. Fixed to `calendar.timegm`, which is right in every zone and season
because the string is already UTC.

**It was found by a test that asserts WHICH REASON a KEEP carries, not that the tree survived.** With
the wrong clock, S21n (the tree is still there) stayed green and S21o (kept *by the floor*) went red.
The same distinction retargeted M25. The visible consequence in the plan above is the
`claude-orphan DELETE 1` row — an hour of coverage that had been silently missing.

### 2.6 Tests

```
$ scripts/scratch-reaper.test.sh          73 passed, 0 failed
   S21  a $TMPDIR name NO declared pattern matches is swept (D1)
   S21a the reason says it was decided, not merely matched
   S21b CONTROL: with SCRATCH_TMP_DENY_BY_DEFAULT unset the same tree survives
   S21c and with the switch off it is not even MENTIONED — which is D1
   S21d a declared FOREIGN owner is kept, never deleted by us
   S21e CONTROL: the identical non-foreign sibling in the same run IS deleted
   S21f the foreign entry is COUNTED and named, not silently skipped
   S21g a tree touched AFTER a running session started is kept
   S21h the reason is the PROOF (the process table), not the mtime
   S21i a DECLARED SHARED temp root is swept too (D2 — /private/tmp)
   S21j wall 3 stands over the new arm — a REGISTERED workspace survives
   S21k and the refusal NAMES the registration
   S21l an undeclared tree a LIVE process is reading is kept
   S21m CONTROL: with the holder gone the same tree IS deleted
   S21n nothing running can own it, but the declared floor still keeps it
   S21o and the reason is the floor, not the process table
   S21p CONTROL: the same tree past the floor IS deleted

$ scripts/scratch-reaper.mutation.sh      all 30 properties proven load-bearing
   M24.deny-by-default-off         -> S21   red      M27.unknown-open-handle-ignored -> S21l red
   M25.session-proof-removed       -> S21h  red      M28.shared-root-not-swept       -> S21i red
   M26.foreign-keeplist-ignored    -> S21d  red      M29.unknown-floor-ignored       -> S21n red
   M30.lstart-dst-offset           -> S21o  red

$ scripts/hooks/session-start-scratch.test.sh   9 passed, 0 failed
```

Two of the S21 cases failed on first run and **the suite was wrong both times, not the reaper**:
creating a file inside a directory updates that directory's mtime, so a fixture built as "backdate
the tree, then add a lock file" leaves the candidate stamped *now* — and the arm correctly kept it,
saying a running session might own it. That is the only way round worth having, and `backdate()`
exists so the next fixture cannot make the same mistake.

**Not covered by the hermetic suite, and said here rather than left implied:** the uid wall cannot be
exercised without creating a file owned by another user. Its evidence is the real-disk dry run in
§2.4 — 94 root-owned entries kept, each naming the uid — and inspection of the branch.

### 2.7 One more defect, in the wiring rather than the logic

`scratch-reaper.sh` exported its config keys by NAME, in seven `export` lines. The new keys were
declared in `orchestration.config`, read by `config_from_env`, and **arrived empty** — so the whole
arm was silently off and the first full-disk run finished in 1.3 s looking exactly like a clean
machine. Both halves looked right and nothing anywhere said the two had never met; this is the same
shape as the `SCRATCH_DOCKER_UNTIL` export Frank noted in passing.

The list of names was the defect, so the list is gone: every `SCRATCH_*` / `APP_TEST_INSTANCE_*` /
`APP_INSTANCE_*` variable that sourcing actually set is exported, enumerated with `compgen -v`. A key
can no longer be declared and missed, and nobody has to remember anything.

### 2.8 The cost, and what it did to the SessionStart budget

```
full pass, every arm, no budget            11.6 s   (60,942 + 764 children)
every arm EXCEPT the deny-by-default one    1.3 s
```

The notice's budget was 8 s, chosen as six times the old 1.3 s. A twelve-second session start is a
hook somebody deletes, so the budget is now **5 s** and the expensive arm absorbs the cut: it runs
last, what it does not reach is counted, and Fix 2 says so out loud. The complete pass is the
scheduled job's, four times a day, with no budget at all. Verified: `--notice --deadline 8` returned
at 8.05 s having decided the cheap arms and printed no "UNKNOWN" banner.

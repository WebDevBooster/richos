# Garbage is always cleaned up, or Rich gets a massive alert — measured on this Mac

**Date:** 2026-09-18
**Agent:** zach-opus-garbage1
**Branch:** `cc/zach-opus-garbage1`
**Ruling:** CEO, `ceo-decisions` §54 and addenda 1–3

Every number here is a command's output, taken on this machine. Where I could not
establish something, it says so rather than rounding to a conclusion.

---

## 1. The premise in the brief was false, and it changed the design

The brief said **"Nothing covers `$TMPDIR`."** It does.

`scripts/scratch-reaper.sh`, `scripts/lib/scratch-reaper.py` (39 KB),
`scratch-reaper.test.sh` (21 KB) and `scratch-reaper.mutation.sh` landed on
**2026-09-17 09:45** as commit `c832af25` — roughly **thirteen hours before** the
22:39 sandbox that left 105 GB. Its launchd agent was installed *and loaded*:

```
$ ls ~/Library/LaunchAgents | grep richos
com.richos.ci-surface-watch.plist
com.richos.scratch-reaper.plist          <- 17 Sep 09:58

$ launchctl list | grep scratch-reaper
-	0	com.richos.scratch-reaper
```

and its SessionStart hook was registered in **both** surfaces
(`hooks/hooks.json:72`, `.claude/settings.local.json:99`).

**So the mechanism was not missing. It ran, and it did not see the garbage.**

### The root cause, one config line

`orchestration.config:645` declared:

```
SCRATCH_TMP_PATTERNS="richos-*-workspace richos-work-*"
```

and `scratch-reaper.py:583-585` `continue`s past any `$TMPDIR` entry matching
neither glob. `root-mutation.*` matches neither.

**Evidence that this is the cause and not a theory:**

```
$ grep -c 'root-mutation' ~/.claude/state/scratch-reaper.log
0                       # zero, across every run that has ever happened

$ grep 'verdict:' ~/.claude/state/scratch-reaper.log | tail -3
2026-09-17T15:40:06Z verdict: deleted=8  freed_human=146.0 MB undecidable=0 failures=0
2026-09-17T21:40:17Z verdict: deleted=8  freed_human=292.0 MB undecidable=0 failures=0
2026-09-18T03:40:06Z verdict: deleted=1  freed_human=156.0 KB undecidable=0 failures=0
```

The 21:40 run was *before* the sandbox was written; the 03:40 run was **five
hours after it**, and freed 156 KB. The 105 GB directory was never a candidate.

That measurement is also why the fix is not "add `root-mutation.*` to the list":
an allowlist can only ever contain the names somebody thought of, and the
directory that filled the disk was named by a bare `mktemp` in a file nobody was
thinking about. Its own config comment, written twelve hours before the incident,
said the list was *"a live no-op today, and is declared anyway because the day a
harness is killed mid-run is the day it stops being one."* That day was the same
day.

### A second false number in the brief

> "296 engine files call `mktemp`"

```
$ grep -rl mktemp scripts scripts/lib scripts/hooks mega-lander | wc -l
296
$ grep -rl mktemp scripts scripts/lib scripts/hooks mega-lander | sort -u | wc -l
171
```

The brief's own command double-counts: `scripts` already contains `scripts/lib`
and `scripts/hooks`. The real figure is **171 files / 341 occurrences**.

Raised as `esc-20260918T070415Z-605bffc0` (state: proceeding) before building.

---

## 2. What the recursion was, and what I could not establish

The sandbox held **105.3 GB** in four mutants:

| mutant | size |
|---|---|
| mutant-1 | 13.0 GB |
| mutant-2 | 26.2 GB |
| mutant-3 | 52.8 GB |
| mutant-4 | 13.2 GB |

**13.0 → 26.2 → 52.8 is exact doubling, and that is the arithmetic signature of a
self-copy:** each mutant came out twice the size of the one before, which happens
when the copy *source* contains the sandbox, so mutant-2 copies the engine plus
mutant-1, mutant-3 copies the engine plus both.

**I could NOT reproduce the path arithmetic that put the sandbox inside the
source.** The deletion log showed a `$TMPDIR`-shaped path nested inside mutant-3,
so something built a destination out of an absolute `$TMPDIR`; nothing in the tree
does that today, and the incident is not reproducible from the current source. I
checked and eliminated: the engine root holds no `$TMPDIR`-shaped directory and
only two relative symlinks (`.claude/state/*-latest.snapshot`); no engine file
performs substring arithmetic on `$TMPDIR`
(`grep -rn 'TMPDIR#\|TMPDIR%\|TMPDIR//'` → nothing);
`scripts/lib/sandbox-completeness.sh:164` does reassign `TMPDIR` but inside a
`$( )` subshell that cannot leak to its parent.

**The guards therefore do not depend on knowing which concatenation it was.** They
check the invariant from the destination's side, where it is checkable without a
theory: is the destination inside the source, is the source itself scratch, has the
root already blown its ceiling. A guard built on a guessed premise makes the guess
permanent and gives it authority.

---

## 3. The sweep, run on this Mac

### Before

```
$ ls -1 "$TMPDIR" | wc -l
87991
$ du -sk "$TMPDIR"
3984568         # 3.80 GB  (the 105 GB had already been deleted by hand)
$ df -k /System/Volumes/Data | awk 'NR==2{print $4}'
192246088       # 183.4 GB free
```

### After

```
$ ls -1 "$TMPDIR" | wc -l
51227
$ df -k /System/Volumes/Data | awk 'NR==2{printf "%.1f GB\n", $4/1024/1024}'
184.2 GB
```

| | before | after | delta |
|---|---|---|---|
| `$TMPDIR` entries | 87,991 | 51,227 | **−36,764** |
| Data volume free | 183.4 GB | 184.2 GB | **+0.8 GB** |

The first `--apply` run's own report:

```
{"ok":false,"swept":37141,"freed_bytes":1794184094,"freed_human":"1.7 GB",
 "undecidable":0,"failures":5,...}
```

**The entry count matters as much as the bytes.** 88,829 entries was itself the
unusable condition — it is what made a full `du` of `$TMPDIR` take minutes and a
per-entry `lsof` impossible.

### Current watchdog reading

```
$ scripts/disk-watchdog.sh --status
ok     /System/Volumes/Data        184.2 GB free of  460.4 GB ( 40.0%)  floor 60 GB
ok     /Volumes/E1TB               863.5 GB free of  953.7 GB ( 90.5%)  floor 124 GB
ALERT  the launchd timer is NOT installed
```

Both volumes are clear of every threshold. **E1TB's floor of 124 GB is the scaled
arithmetic working:** 60 GB × 953.7/460.4 = 124.3. The third line is correct and
is the subject of §6.

---

## 4. Three defects found by RUNNING it, not by reading it

### 4.1 The reaper became too slow to finish

Widening the coverage made `lsof` run per candidate across 87,330 entries. The
first dry run produced **no output at all** before it was killed at 120 s — **with
exit 144, the same signal that killed the harness that left the 105 GB.**

A reaper too slow to finish gets removed from the session-start path, and then
nothing sweeps anything. Fixed by reading the open-file table **once** for the
whole machine and reducing it to first-path-components under `$TMPDIR`, so one
process answers for thousands of paths. **17.8 s** for 87,330 entries.

### 4.2 2,800 entries permanently undecidable

```
INDETERMINATE reasons: 2800  wall 2: this tree contains a .git ...
```

All 2,800 were harness fixtures building throwaway repositories —
`richos-provision-git/-fresh/-ignore/-valid/-install-home` and nine siblings at
~249 each, `ws-spec-*` at 52, `byref.*` — **0.61 GB of test scaffolding.**

Leaving them undecidable is *not* the cautious choice: undecidable exits 3, exit 3
becomes the MASSIVE ALERT, and an alert firing on 2,800 fixtures every six hours
is switched off within a day — after which the next 105 GB arrives with nobody
watching. Wall 2 is **narrowed**, declared, and only for names matching a declared
legacy family, only for direct children of `$TMPDIR`, only after the age floor and
the open-handle check pass. **Wall 3 is untouched** and it is what was ever
protecting a real checkout — asserted by S14c, with M14 proving that assertion
load-bearing.

Plan afterwards: **37,142 entries, 1.68 GB, 0 undecidable, exit 0.**

### 4.3 The worst one: a failed deletion hid itself

The first real sweep freed 1.7 GB with **5 failures**. The next run reported
`ok:true, failures:0` — **with all five directories still on disk.**

The trees came back as *"touched 1 min ago, inside the 2 h legacy floor"* and were
**KEPT**. Not failed, not undecidable. Kept, silently, for two hours.

**The three things I observed, kept separate from the mechanism I infer from
them**, because the distinction matters for anyone re-checking this:

1. The five paths were logged `FAILED` at `2026-09-18T07:40:05Z` — an act, in the
   reaper's own log.
2. Immediately afterwards their **directories** carried fresh mtimes while the
   **files inside them** were days old:
   ```
   $ ls -lOa .../ws-fourteen.9dIpXK/entity/.claude/worktrees/.parked-agent-ak1.../
   drwxr-xr-x@ 23 alex staff -  736 18 Sep 08:40 .      <- directory, today
   -rw-r--r--@  1 alex staff -  130 13 Sep 09:41 .git   <- contents, five days old
   ```
3. The next run then reported:
   ```
   $ scripts/scratch-reaper.sh --verbose | grep -A1 ws-fourteen.9dIpXK
   KEEP              1.7 MB  /private/var/folders/.../T/ws-fourteen.9dIpXK
                         why: touched 1 min ago, inside the 2 h legacy floor
   ```

**The inference — and it is an inference, not a measurement:** `shutil.rmtree`
deletes children before removing their parent, so a run that aborted partway
through would leave exactly this signature (parent directories modified today,
surviving contents untouched since the fixture was created). I did not instrument
the deletion to prove that ordering, and the `--verbose` output above establishes
only that the tree *was kept for a recent mtime* — not what set the mtime.

**What does not depend on the inference:** whichever wrote the mtime, the
observable outcome is that five paths logged as FAILED were reported as KEEP on the
next run and the run reported `failures=0` while all five were still on disk. That
is the defect, and the durable-failure record fixes it regardless of which process
touched the directory.

**The reaper's own failure made its next attempt impossible and erased the
evidence.** Under the CEO's rule that is the worst available outcome: garbage that
*cannot* be removed produces *no* alert.

Failures are now durable in `~/.claude/state/scratch-failures.json`, reconsidered
every run regardless of age, and dropped from the books the moment the path is
gone so the alert can clear.

### The five, diagnosed rather than guessed

Both `shutil.rmtree` **and** `/bin/rm -rf` failed with EPERM:

```
$ /bin/rm -rf .../ws-fourteen.9dIpXK
rm: .../.parked-agent-ak1.../pinned.txt: Operation not permitted

$ ls -lO .../pinned.txt
-rw-r--r--@ 1 alex staff uchg 15 13 Sep 09:41 .../pinned.txt
$ stat -f 'flags=0x%Xf' .../pinned.txt
flags=0x2
```

One file, `chflags uchg` (`UF_IMMUTABLE`), mode 644, owned by the invoking user,
left by a harness that tests pinned files. Modes and that flag are now cleared on
a single retry, **bounded** to the four machine-made scratch classes and never to
a session's scratchpad or the nightly, and every clearing is logged:

```
$ grep 'uchg flag' ~/.claude/state/scratch-reaper.log | tail -1
... note=removed on the second attempt after making the tree writable and
    clearing 1 uchg flag(s); first attempt: [Errno 1] Operation not permitted: ...
```

Afterwards: all five reclaimed, the failure file gone, `ok:true, failures:0`
**truthfully**.

### 4.4 A wiring bug in the watchdog

The watchdog initially read **none** of its declarations: `orchestration.config`
was sourced into shell variables and never exported, so the python child saw
nothing — and it *looked* correct, because the fallback for
`DISK_PRIMARY_VOLUME` is the same string the config declares. What gave it away
was `/Volumes/E1TB` silently missing, since an unread extra-volume list is
indistinguishable from an unmounted volume.

**A default that happens to match the declaration hides broken wiring.** Case W1
therefore asserts with a deliberately absurd `4242` GB threshold — a test using
the real numbers would have passed against a program reading none of them.

---

## 5. Docker — verified, including where the CEO's expectation would not have held

```
$ docker system df
Images          38  15  31.7GB   19.46GB (61%)
Build Cache    209   0  16.71GB  8.509GB
$ du -sh /Volumes/E1TB/vm/docker/DockerDesktop
 33G
```

Both figures match the addendum exactly, and the data root is confirmed on the
**external SSD**, off Macintosh HD.

**The finding I reported before implementing:** `docker image prune -f` without
`-a` removes **dangling only**, and this machine has **4** dangling images
(~1.7 GB) — not 19.46 GB. The other ~17.8 GB is unused-but-**tagged**:

```
$ docker images -f dangling=true -q | wc -l
4
```

I implemented dangling-only as instructed and reported the gap rather than
silently widening to `-a`. The CEO then ruled for the stricter standing rule, so
the sweep is now three staged prunes with a 30-day filter. **Containers before
images**, because a stopped container pins its image — asserted by S16d, with M18
proving it (reversing the order turns S16d red).

---

## 6. What is NOT done, and it is the one thing that needs a hand

**The launchd timers are not installed on this machine, and cannot be from here.**

`--install` refuses to schedule from a worktree by design, and W16 asserts that
refusal: the plist bakes in an absolute path, an agent worktree is deleted at land
time, and from that moment the job fires on time, every time, and executes
nothing.

So the watchdog's own alert currently and correctly reads:

```
MASSIVE ALERT — THE DISK WATCHDOG IS NOT INSTALLED
```

`scripts/hooks/install.sh` now arms **both** jobs, so this resolves itself when
this branch lands and `install.sh` re-runs from the main checkout. Until then
nothing is watching free space on a 15-minute timer — the six-hourly reaper timer
that already exists is unaffected and still running.

---

## 7. Test tails

```
scratch.test.sh                      14 passed, 0 failed
mutation-harness-guards.test.sh      12 passed, 0 failed
scratch-reaper.test.sh               50 passed, 0 failed
scratch-reaper.mutation.sh           === mutation: all 20 properties proven load-bearing ===
disk-watchdog.test.sh                30 passed, 0 failed
notice-disk-alert.test.sh            12 passed, 0 failed
scratch-allocation-lint.test.sh      16 passed, 0 failed
install-retire-reconciler.test.sh    === install-retire-reconciler: all 5 passed ===
session-start-scratch.test.sh         9 passed, 0 failed
root-contract.mutation.sh            === all 11 fixes proven load-bearing ===
ceo-todos.mutation.sh                ✓ 12/12 mutants killed
guard-worktree-removal.mutation.sh   === all 26 mutants proven load-bearing ===
guard-worktree-isolation.mutation.sh === 26 proven load-bearing, 0 unproven ===
mega-lander/tests/app.test.py        Ran 29 tests — OK
mega-lander/tests/workspaces.test.py Ran 82 tests — OK
```

**The brief's nine defeat tests, and where each one is:**

| the brief asked for | where it is |
|---|---|
| `kill -9` mid-harness → reaped by the next sweep | **G8**, a real SIGKILL to a real `bash -c` child, then the shipped sweeper |
| a sealed/finished agent's scratch → reaped | S12 (dead owner), S13 (released row) |
| a session crash: ledger rows with a dead pid → reaped | S12, S12d (ledger deleted entirely) |
| disk nearly full → alert at turn end AND session start | W3 (lowered threshold), D2 (session start), D3/D4 (turn end) |
| an unregistered directory under the root → reaped | S12c |
| a nested self-copy → refused BEFORE the copy | **G1**, with G5 asserting the refusal explains itself |
| a deletion that fails → alert names it and Rich's manual path | S17, W12/W12b, and it fired for real on five paths |
| the `launchd` agent runs with no session | W15, under `env -i` with an empty environment |
| a mutation harness for the sweeper itself | M11 and M13 gut the dead-pid check; both turn the suite red |

**Two of those tests found defects while being written**, which is the only reason
they are worth having: G1 was passing *for the wrong reason* (an unresolvable-path
branch, so containment never ran), and G8's first version used `( ... ) &` — where
`$$` is the script's pid, not the subshell's — so the suite itself owned the row
and the sweeper was right to keep it. The attribution is correct and is now
documented in `scratch.sh`; the test was wrong.

Two of those mutants earned their keep **during** this change rather than after:

- **M4** refused to apply when wall 2's anchor moved, reporting *"MUTATION TARGET
  ABSENT — the source has drifted"* instead of silently scoring PROVEN against a
  line that no longer existed.
- **M16** exposed S16 asserting on **stdout** when the failures count only ever
  reaches the **log** — a test checking a channel the evidence does not travel on.

---

## 7b. The contract-integrity probe, diffed rather than waved off

Running the probe from a worktree reported **26 broken layers**. The tempting
reading is "that is the usual worktree penalty" — so it was diffed against the
unmodified main checkout instead.

```
main checkout:   1 layer(s) broken
  ✗ Q. registry content hash mismatch — live file differs from manifest
       (pre-existing, unrelated to this work; install.sh regenerates it)

this worktree:  26 layer(s) broken
  25 x "manifest missing or unreadable" / "unhashed"   <- .sha256 sidecars are
                                                          gitignored and never
                                                          exist in a worktree
   1 x REAL, and mine:
  ✗ R. hook(s) do NOT source the root-resolution contract: notice-disk-alert.
       A hook that resolves its root any other way has silently gone back to
       trusting its own on-disk location.
```

**That one was a genuine defect in my new hook** and it would have been invisible
inside the noise. Fixed by carrying the canonical bootstrap block verbatim — Layer
R compares it byte-for-byte from the `# --- ROOT RESOLUTION ---` marker, so a
hand-written equivalent is a failure by design. The first attempt at the fix still
failed as `notice-disk-alert(no-bootstrap)` because it lacked that marker.

After the fix:

```
this worktree:  25 layer(s) broken — every one "manifest missing" / "unhashed"
                ZERO non-sidecar failures
```

**`install.sh` must re-run from the main checkout after this lands** — that
regenerates the sidecars and the `hooks.json` manifest hash this branch changes,
and it is also what arms the two launchd timers.

## 8. The lint ships with a baseline, and why that is honest

The first run found 51 unallocated `mktemp -d` sites. Migrating all 51 would have
been a blind edit across the whole engine; shipping a check that is **red** on the
day it lands means a check that is **waived** on the day it lands — the
`g11`/`g12`/`g13` pattern this project recorded three instances of in one day.

So: the four harnesses that **copy a tree** per mutant — the class that actually
produced 105 GB — were **migrated** (and all three of their mutation harnesses
still prove every property). The remaining 45 are held by a declared baseline that
may only ever go down, and every one of them is **already swept today** by the
reaper's legacy families; what they lack is the deny-by-default protection that
needs no name.

Proven with a positive probe rather than asserted:

```
# with one new bare mktemp -d added:
scratch-allocation-lint: 46 unallocated ... the declared baseline is 45.
  1 MORE THAN WHEN THE BASELINE WAS SET.                       -> exit 1
# probe removed:                                               -> exit 0
```

# A test instance of the app is garbage, and it is collected — measured on this Mac

**Date:** 2026-09-18
**Agent:** zach-opus-testinst1
**Branch:** `cc/zach-opus-testinst1`
**Ruling:** CEO, `ceo-decisions` §54 and addendum 4

> **§54 addendum 4 (CEO, 2026-09-18, verbatim):** *"Ray had left the test app window open. Test app
> windows must always close/quit when testing is finished. Same hygiene as with any other garbage."*

Every command below was run on this machine. Where something could not be established it says so
rather than rounding to a conclusion.

---

## 1. The brief prescribed a mechanism that does not exist on this OS

The brief said to read the launch environment from the process — *"the launch env via `ps eww` if
permitted"* — and test whether `HOME` lies under a scratch root. **It is never permitted here.**

Measured against a `sleep` child of the invoking shell: same uid, no sandbox, a direct child.

```
$ ps eww -o command= -p 82969      ->  sleep 300
$ ps -E  -o command= -p 90491      ->  sleep 300
$ sw_vers                          ->  macOS 15.6 (24G84)
```

argv, and **no environment at all**. Not truncated, not permission-denied: macOS no longer exposes
another process's environment through `ps`. A first attempt appeared to find `HOME=` in the output
of `ps -E` against my own shell — those matches were **my own grep pattern echoed back in argv**,
which is worth recording because it is exactly how this would have been mis-measured.

So `HOME` is not a readable property of a running process on this machine, and a design resting on
it would have shipped a collector that silently collected nothing.

**What is readable without root:**

```
$ lsof -a -p 69033 -d cwd,txt -Fn
p69033
fcwd
n/Users/alex/ab/femcboost/.claude/worktrees/agent-a94952b3135184f96
ftxt
n/bin/sleep
```

Absolute working directory and absolute executable, regardless of argv. That, plus the process's
open files — which is where a scratch `HOME` actually becomes visible, because an app told
`HOME=<scratch>` opens its state under `<scratch>` and those paths are absolute in `lsof` whether or
not anything can read the variable.

Raised as `esc-20260918T085142Z-9986192d` (state: proceeding) before building.

## 2. Three more of the brief's premises, checked

**`richos-qa-*` is in no engine allowlist.**

```
$ grep -rn "richos-qa" --include=*.sh --include=*.py --include=*.config --include=*.json .
(nothing)
```

It does not need to be. The candidate-.7 instance lived in
`/private/tmp/claude-501/<slug>/<uuid>/scratchpad/richos-qa-cand7` — a subdirectory of a **session
scratchpad**, already covered by `SCRATCH_CLAUDE_ROOTS` as a prefix. Adding it as a `$TMPDIR` glob
would have been a second definition of a path the first one already held.

**The brief's never-touch list does not exist, and the app that does was unnamed.**

```
$ ls -d /Applications/RichOS.app     -> no such directory
$ ls -d ~/myrichos-nightly-*         -> no such directory
$ ls -d ~/Applications/RichOS.app    -> /Users/alex/Applications/RichOS.app     <- the installed app
$ ls -d ~/.richos-nightly            -> /Users/alex/.richos-nightly
```

Both paths named as "never touch" were absent, and the app actually installed sat at a path the
brief did not mention. **This cost nothing only because the protect-list is not the safety
mechanism** — see §3. Had it been, the one app on this machine worth protecting would have had no
protection at all.

**The process name and the bundle id cannot tell a test instance from the CEO's app.** The shipped
binary is *also* named `richos-tauri` (`RichOS.app/Contents/MacOS/richos-tauri`;
`tauri.conf.json` sets `productName: RichOS`, `identifier: com.richos.app`), and the .7 walk
recorded its argv as **relative**:

```
$ pgrep -fl richos-tauri
98757 ./RichOS.app/Contents/MacOS/richos-tauri
```

Name, identifier and argv are shared, and none of the three locates the binary. **This is why the
quit is addressed by pid** through System Events (`whose unix id is <pid>`) and never
`tell application id "com.richos.app" to quit`, which addresses whichever instance the window
server has registered — on this machine, his.

## 3. Deny by default is the safety mechanism

Nothing is quit for failing to appear on a list. A process is collected only when it is
**positively** shown to be rooted under a declared scratch root; anything unplaceable — an unknown
binary, unreadable open files, the installed app, an instance on the operator's real home — is left
alone by construction.

`classify` returns three states, never two. Scratch evidence **and** real-home evidence together is
`INDETERMINATE` and is **left running**, because collapsing that into a guess is how a cleanup
mechanism quits the wrong window once and is switched off for ever.

**One definition, not two.** `scripts/lib/appinstances.py` derives its root set from the reaper's
own `SCRATCH_*` keys rather than restating them. A10 proves this by declaring a new `$TMPDIR` family
to the **reaper's** key and watching the collector follow with no edit of its own.

## 4. The defect the tests found: the executable is not evidence

The first version counted every open path equally, and **three cases failed as one defect**: a
stand-in whose binary sat in a scratch sandbox but whose state was the operator's real app-support
directory came out `INDETERMINATE`; a binary in a scratch sandbox writing to an undeclared `/tmp`
file came out `COLLECT`; and the derivation test could not tell a declared family from an undeclared
one, because the executable matched either way.

**The executable's location says which BUILD is running. It never says whose instance it is.**
`~/Applications/RichOS.app` launched against a scratch home is a test instance; a scratch-built
binary serving the operator's real home is his. `lsof`'s fd column is now read (`-F pfn`) and image
handles (`txt`, `mem`, `rtd`) are excluded from the evidence.

## 5. Two defects in my own test harness, which are the point

**The fixture was a shell script.** `bash` keeps the script it is running open on **numeric fd 255**,
so the fixture's own path appeared as ordinary open data and every instance looked as though its
data lived wherever its executable did. The real app is a Mach-O binary whose image appears only
under `txt`. *A fixture carrying a signal the real subject does not have tests the fixture.* It is
now compiled.

**The suite hung for 300 s and printed nothing.** `launch()` backgrounded the app inside `$( )`, and
a command substitution blocks until every writer closes the pipe — i.e. until the app exits. Fixed
with `>/dev/null 2>&1`.

**And then the harness became the garbage.** The 300 s timeout killed it, `trap EXIT` does not
survive that, and **two** fixture processes outlived their test. This is not a footnote:

- pid `60433` is the live specimen **Frank independently ranked as D6** in his attack pass.
- pid `81095` was found by the coordinator two hours later under `~/.cache/appinstances-test-60397`.

Both came from the same killed run. The fixture now carries **its own hard deadline** so it ends by
itself when the harness cannot end it, and teardown runs `kill -9` (one variant traps TERM on
purpose) from the EXIT trap, including for paths outside the sandbox.

**Three things this taught that were not in the brief:**

1. **`~/.cache` is outside every root the reaper sweeps** and outside the collector's root set. A
   fixture executable there would never be cleaned up by anything.
2. **What saved pid 81095 was that its STATE was under a swept root even after I deleted the
   directory** — `lsof` still reports the path for an open fd, so the evidence outlived the tree.
   Had the fixture kept its state under `~/.cache` too, my own deny-by-default rule would have
   classified it `LEAVE` and it would have been invisible to the thing built to find it.
3. **A stray fixture does not just occupy disk — it poisons every other agent's liveness check.**
   `pgrep -fl richos-tauri` answered yes for everyone, and a teammate lost a minute proving the
   process was not his. That is the real damage, and neither Frank nor I had weighed it.

**Both were collected by the shipped collector rather than by hand**, which made them the best
end-to-end evidence in this record:

```
$ python3 scripts/lib/appinstances.py --apply
scratch roots: 2 directory prefix(es) + 40 $TMPDIR name family(ies)
COLLECTED    pid 81095   ended on SIGTERM after declining to quit
verdict: collected=1 survivors=0 undecided=0 left=0

$ pgrep -fl richos-tauri
(nothing)
```

The polite quit failed because that variant traps TERM/INT, and it ended on the escalation — the
`A3` path, proven against a real orphan rather than a fixture.

## 6. Performance, because a slow collector is an unwired collector

The first version globbed the `$TMPDIR` families into a flat prefix list:

```
derive roots: 1.110s (1586 roots)
classify 3 procs x 3000 paths: 1.073s
```

The reaper had already recorded this exact lesson — widening its coverage made it do an `lsof` per
candidate, its first dry run produced no output before being killed at 120 s, and its own comment
says *"a reaper too slow to finish is a reaper that gets removed from the session-start path, and
then nothing sweeps anything."* The same reduction is used here: `$TMPDIR` families stay **patterns**
matched against a path's first component, with no filesystem walk.

```
derive: 0.0008s  2 directory prefix(es) + 40 $TMPDIR name family(ies)
classify 3x3000: 0.0002s
```

2.18 s → 0.001 s, and it stops growing with the size of `$TMPDIR`.

## 7. The two collection points

**The land step** (`mega-lander/workspaces.py`). `stop_processes` already ran at every land and would
never have caught this: it matches on cwd or on a workspace path in argv, and `gui-launch.sh` starts
the app `cd /` under `env -i` while the .7 instance's argv named no absolute path. Both tests miss
it — which is how it survived its own land.

Scoped to the landing agent's **own workspaces** (`include_declared=False`). Sweeping every declared
root here would quit a **live peer agent's** instance mid-test: a new defect wearing this fix's
clothes. A survivor never blocks the workspace deletion — a window that will not close is no reason
to keep a landed worktree on disk.

**The sweep** (`scripts/lib/scratch-reaper.py`), in two places: `apply()` quits instances rooted in
paths it is about to delete, **before the first `rmtree`** (without this, the claude-roots arm — which
has no open-handle check by design — deletes a dead session's scratchpad while the app runs on it,
leaving an orphan window on a `HOME` that no longer exists); and a held directory is no longer
immortal.

**The alert.** A surviving instance is durable in `~/.claude/state/app-instance-failures.json` and
named in the same MASSIVE ALERT block with the literal `kill -9 <pid>` Rich runs. **A separate file
from `scratch-failures.json`, and that is not duplication:** that file keys by path and resolves a
row when the path stops existing, so a pid key would resolve on the very next read and clear the
alert while the window was still on his screen. Rows here resolve when the **process** is gone — so
his manual kill clears it without running anything.

## 8. Two data-loss defects found on the way, one of them not mine to find

**D5 — the allocator arm trusted a pid alone.** Frank's attack record named it; I reproduced it
before changing a line. It was the only arm that went from "the owning pid is dead" straight to
DELETE without consulting the open-file table — both `$TMPDIR` arms already did.

```
$ bash scripts/scratch-reaper.sh --dry-run --verbose
DELETE            2.0 MB  .../richos-scratch/99999997-zach-d5-repro
       why: pid 99999997 is ENDED (owner of 'unrecorded', from the directory name)
            and nothing has touched this for 374961 min; its TTL was 360 min
```

…with a live `tail -f` reading inside it, and the reason never mentions a holder because nothing had
looked. **That is destroying work, not collecting garbage.** After the fix, same fixture, same live
holder:

```
KEEP              2.0 MB  .../richos-scratch/99999997-zach-d5-repro
       why: pid 99999997 is ended, but a LIVE process holds a file open inside
            this tree — the allocation being over does not make a tree something
            is reading garbage
```

…and with the holder killed, the same tree is deleted again (the control — without it this is
indistinguishable from an arm that has stopped deleting anything).

**The second defect, found because the first fix did not work.** `holder()` used
`lsof -t -- <path>`, which asks who has **that node** open. For a directory that is almost never the
question:

```
$ lsof -t -- .../holdertest           -> (nothing)
$ lsof +D .../holdertest -t           -> 94085
$ lsof -t -- .../holdertest/f.lock    -> 94085
```

So the wall was present, consulted, **and given a false answer**. Both callers believed it —
including the `tmp-workspace` arm, whose whole job is to protect a live agent workspace. A timeout
now returns `None` (INDETERMINATE, keep) and never `''` (proven unheld), because a slow answer must
not read as an absence of holders.

**§54 addendum 4 closes the gap the first wall opens.** A stray app instance holding its own scratch
made that tree immortal — `KEEP`, every run, for ever. Observed for real: the fixture of §5 was doing
exactly this. Now a holder that is **positively** a collectable test instance is quit and the tree
removed; any other holder, or a mixed set, still means KEEP.

## 9. Test tails

```
scripts/lib/appinstances.test.sh      17 passed, 0 failed
scripts/scratch-reaper.test.sh        56 passed, 0 failed
scripts/scratch-reaper.mutation.sh    === all 23 properties proven load-bearing ===
scripts/disk-watchdog.test.sh         30 passed, 0 failed
scripts/hooks/notice-disk-alert.test.sh  12 passed, 0 failed
mega-lander/tests/workspaces.test.py  Ran 82 tests — OK
```

**The defeat cases the brief asked for, and where each one is:**

| the brief asked for | where it is |
|---|---|
| an instance left running under a scratch HOME after a land | **A1**, and proven twice against REAL orphans (pids 60433, 81095) |
| an instance that ignores quit | **A3** (traps TERM/INT; ends on the escalation, and says which step ended it) |
| an instance under the real HOME — must be left alone | **A2**, with its positive control **in the same run** |
| a failed collection alerts rather than being dropped | **A4** + the watchdog block; **S20c** proves the act is logged |
| the reaper quits an instance before removing its HOME | **S20**, **S20b** — the tree goes AND the pid is verified gone |
| a tree with a non-test holder is never deleted | **S19**, **S19b** (the reason names the holder), **S19c** (the control) |

**Three mutants added, all proven load-bearing** — and **M22 earned its keep while being written.**
Targeted at S19 it failed as *"red, but not here"*: S19 stays **green** under it, because S19's KEEP
comes from the cached whole-machine snapshot, which never calls `holder()`. What actually depends on
`holder()` telling the truth is the test-instance override. The two walls are independent, and only
S20 is evidence about that line. A mutant asserted against the wrong case would have recorded a
relationship that is not there.

Two test corrections, both the same mistake — **a case reading the wrong channel**: S19b read
`--apply`'s stdout, where a KEEP entry does not appear at all, and S20c read stdout for a line that
goes to the log. This suite's own M16 caught that once before.

## 10. The optional lint — my answer is NO

The brief asked whether a lint refusing a brief line that tells an agent to leave an app running is
worth its false-positive class. **It is not, and it should not be built.**

- **Its true-positive set is one sentence that has already been withdrawn.** The offending line —
  *"leave the app in the state step 4 ends in"* — was Rich's, it was withdrawn by name in addendum 4,
  and the addendum already requires every QA and engineering brief to carry the opposite line.
- **It is a blocking guard over PROSE with a large false-positive class**, which is the exact
  `g11`/`g12`/`g13` pattern this project recorded three instances of in a single day. A brief that
  legitimately says *"leave the window open so Kai can photograph the same frame"* would be refused,
  the fix on the day would be to waive it, and habitual waiving is how a guard dies.
- **It would fire on this very record**, which quotes the withdrawn sentence in order to explain it —
  the same way the dialect guard's own documentation problem bit `A9` in §9.
- **And it is the weakest available enforcement of the rule.** The mechanism this task built does not
  care what any brief says: an instance left running is collected at the land and at the sweep, and
  if it cannot be collected Rich is told. **Enforcement at the artifact beats enforcement at the
  prose**, and the prose half is already covered by a required line in the briefs.

## 11. What install.sh must do, and the probe diff

`scripts/hooks/install.sh` **must re-run from the main checkout after this lands.** No hook was added
or removed, but files under `scripts/` changed, so the registry content hash and the `.sha256`
sidecars this branch touches need regenerating.

Diffed rather than waved off, because "that is the usual worktree penalty" is a claim and not a
measurement:

```
main checkout (/Users/alex/ab/richos/richos/engine):
  28 green, 0 broken, 0 could not run            -> PASS

this worktree:
  25 layer(s) broken
  $ grep "✗" probe-wt.txt | grep -v "manifest missing or unreadable" | grep -v "unhashed"
  (nothing)
```

**All 25 are the gitignored-sidecar class and not one is a real failure of mine** — the sidecars do
not exist in a worktree and never can. The check that matters is the filtered grep above returning
empty, not the count.

## 12. What is NOT covered, and it is a real gap

**An instance under the CURRENTLY LIVE session's scratchpad, launched for an agent that has since
landed, is collected by neither arm.** The land step will not take it (correctly — it is scoped to
the agent's own workspaces, because sweeping declared roots at a land would quit a live peer's
instance), and the reaper will not take it while the owning session is alive.

**This is the candidate-.7 shape exactly.** That instance lived under Rich's own live session's
scratchpad.

The reason it cannot be closed here is that **the scratch ledger records a `path`, `label`, `pid`,
`ppid` and `session` — and never an agent name** (`scripts/lib/scratch.sh:_scratch_record`), so at
land time there is no durable attribution from an agent to the scratch directory its test instance
is running on. I did not invent one: fuzzy-matching an agent name against a directory name
(`ray-opus-cand7walk` against `richos-qa-cand7`) would be a guess, and a guess in this mechanism
quits a colleague's window.

**What actually covers it today** is addendum 4's first clause — *"whoever launched or was handed it
quits it before reporting, verifies the process is gone, and says so in the handoff"* — plus the
reaper collecting it once the session ends. **What would close it mechanically** is a label on the
allocation: if a QA launcher allocated its scratch through `scratch_new <agent-name>`, the ledger row
would carry the attribution and the land step could scope to it without guessing. That is a change
to how instances are LAUNCHED, in the app and QA tooling, not to how they are collected, and it is
outside this task's files.

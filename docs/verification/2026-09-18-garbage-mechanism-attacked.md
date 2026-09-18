# The garbage mechanism, attacked — what survives with no alert

**Date:** 2026-09-18
**Agent:** frank-opus-garbage1 (Expert Advisor / Devil's Advocate)
**Branch:** `cc/frank-opus-garbage1`
**Attacked:** richos main `e1af0f99` (Zach's land), on this Mac, with both launchd jobs armed
**Ruling under attack:** CEO §54 — *"ROCK-SOLID, UNBREAKABLE, UNDEFEATABLE mechanisms that always
guarantees that garbage like this will be always cleaned up afterwards. Or if the clean-up fails or
impossible for some reason, then Rich must get a MASSIVE ALERT about it"*

Every number below is a command's output taken on this machine at HEAD. Where I could not establish
something it says so. I built throwaway garbage under my own session scratchpad, never under `~`,
never in a repository, and §10 shows it deleted.

---

## The verdict in one paragraph

**The mechanism is not defeatable in the sense of being tricked — it is defeated by NOT BEING
ASKED.** Its alarm is a disk-space alarm and a delete-failure alarm. It has no garbage alarm. So
garbage that no arm looks at produces neither a cleanup nor an alert, and that is the state of this
Mac right now: **~53 GiB of identifiable garbage that nothing on this machine will ever collect and
nothing will ever mention**, while the sweeper reports `deletable=0 ... undecidable=0` and exits 0,
the session-start notice prints nothing, and the turn-end notice prints nothing. The four highest
ranked defeats below are not hypotheses; they are measurements of today.

One defeat runs the other way and is worse than garbage: the allocator arm will **delete a directory
out from under a running process**, which I did on purpose, and the shape that triggers it is on this
machine at this moment.

---

## Ranked — likelihood on this Mac in a normal week, not cleverness

| # | attack | verdict | size / evidence today | likelihood |
|---|---|---|---|---|
| **D1** | `$TMPDIR` is still an ALLOWLIST: a name outside every pattern is skipped, not kept | **DEFEATED** | **52,409 of 53,593 entries (97.8%), 1.90 GB**; 43,130 entries / 679 MB of it RichOS-named | **certain — true right now** |
| **D2** | `/private/tmp` outside `claude-<uid>` is swept by nothing | **DEFEATED** | **25.77 GiB**, 396 `richos-*` entries, biggest single **18.99 GiB** (2 days old) | **certain — true right now** |
| **D3** | workspace/evidence roots under `~/ab` are in no ledger and no root list | **DEFEATED** | **25.42 GiB** (`richos-rechecks` 17.01, `richos-password-free-workspaces` 8.41) + 2 stale `codex-*` worktrees | **certain — one per campaign** |
| **D4** | the app has no mechanism at all (addendum 2) | **DEFEATED** | **61 runtime `temp_dir()` sites, 0 allocator calls**; 101 `richos-voice-*` dirs created today | **certain** |
| **D5** | the allocator arm deletes a tree with a LIVE process holding files open inside it | **DEFEATED (data loss, not garbage)** | proven: tree removed under live pid 76454; the same shape is live now as pid 60433, ppid 1 | **high this week** |
| **D6** | a detached test app instance survives its test (addendum 4) | **DEFEATED** | pid 60433 `richos-tauri`, reparented to launchd, nothing collects it | **high — happening now** |
| **D7** | the drop alarm has no divisor: it subtracts against a baseline of any age | **ALERTED, falsely** | a 10-hour-old baseline printed `DROPPED 30.0 GB since the last reading` | **high — the laptop sleeps** |
| **D8** | the drop threshold's stated justification is not supported by the record it cites | **premise unproven** | 105 GB across a ≥5 h window ≈ 21 GB/h ≈ 5.3 GB/tick vs. the 20 GB/tick threshold | n/a (a claim, not a hole) |
| **D9** | `CLAUDE_CONFIG_DIR` silences every failed-deletion alert (reaper honors it, watchdog does not) | **DEFEATED** | reaper wrote the failure under `$CLAUDE_CONFIG_DIR/state/`, watchdog `--alert` exit 0, silent | medium |
| **D10** | a failed deletion is absent from the reaper's exit code and stdout | **DEFEATED (single channel)** | `applied: deleted=0 freed=0 B` + `EXIT=0` with the path still on disk | medium |
| **D11** | a name-derived live pid makes garbage immortal | **DEFEATED** | `1-frank-immortal-b` → `KEEP ... pid 1 is ALIVE`, forever, no alert | medium (pid reuse) |
| **D12** | `undecidable` is in no alert channel | **DEFEATED below 1 GiB** | exit 3 goes to a launchd log; the watchdog reads only the failures file | medium |
| **D13** | the alert's classification undercounts our own garbage and names the wrong directories | **ALERTED, misattributed** | alert said `8.9 GB` ours and listed `~/ab`, `E1TB/vm`, `~/.claude`; never `/private/tmp` | certain when it fires |
| **D14** | Docker: a running container is immortal by design; volumes have no prune stage | **DEFEATED (small)** | 2 × `sleep infinity` containers 8 days old pinning 0.86 GB; 21 dangling volumes / 402 MB | medium |
| **D15** | `/Volumes/E1TB` is swept by nothing, including its own `tmp/` | **DEFEATED (latent)** | 36.03 GiB `caches/`; floor 124 GB with 863 GB free, so no alert for months | low today |
| **D16** | the allocation lint is wired nowhere — the ratchet has no ratchet | **DEFEATED** | 0 registrations in `hooks.json`/probe/runners; 177 `mktemp` files vs 11 allocator sourcers | certain |
| **D17** | the recursion guard covers the library copy path only | **partial** | 6 of 43 `*.mutation.sh` call `mutation_copy_engine`; `ceo-todos.mutation.sh` copies with its own `cp -R` | low |

**HELD, and they are real wins:** the durable-failure record and its age-floor bypass (H1, with the
partial-`rmtree` mtime reset reproduced directly rather than inferred); the failure alert's content
when the paths agree (H2); symlinks unlinked and never followed (H3); deny-by-default INSIDE the
allocator root (H4); the `lsof` wall on both `$TMPDIR` arms (H5); a live session's scratchpad kept
and not even measured (H6); the refusal to schedule from a worktree (H7); "not installed" being
itself an alert (H8); a stopped Docker daemon skipped silently (H9).

---

## 1. Attack 1 — make garbage the reaper cannot see

### 1.1 The census: the allowlist is still an allowlist (D1)

`scan_tmp()` `continue`s past any `$TMPDIR` entry matching neither `SCRATCH_TMP_PATTERNS` nor
`SCRATCH_LEGACY_TMP_PATTERNS` (`scripts/lib/scratch-reaper.py:952-956`). The fix for the 105 GB was
to lengthen the second list. The structure that let it through is unchanged.

Counted with the config's own two pattern lists:

```
TMPDIR: /private/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T
total entries under TMPDIR: 53593
covered by a pattern     : 1183
INVISIBLE to scan_tmp    : 52409
INVISIBLE total bytes    : 1.90 GB (1903266964 bytes)
```

Top invisible families, by bytes, with the oldest member's age in days:

```
com.microsoft.VSCode.ShipIt                          1      941.9 MB      2.7 d
richos-owned-wake-native                            49      216.1 MB      9.1 d
.com.openai.codex                                 1964      142.6 MB      9.0 d
richos-ecs-assessment                                1       62.2 MB      5.0 d
richos-setup-streaming                             206       39.1 MB      9.1 d
richos-xsurface                                      6       34.9 MB      8.2 d
prove-one.XXXXXX                                     2       21.9 MB      0.5 d
richos-r7-install                                    4       14.6 MB      8.8 d
engine-status.XXXXXX                                 1        9.2 MB      8.3 d

RichOS-made invisible families: 30740 families, 43130 entries, 679.5 MB
```

**Two things in that table matter more than the byte count.**

First, `richos-owned-wake-native-*` — 49 directories, 216 MB, 9 days old — **was on this disk when
the legacy list was written and is not in it.** The list contains `richos-native-*`; `fnmatch` does
not match `richos-owned-wake-native-…` against it. The enumeration was incomplete against the very
disk it was derived from.

Second, **the creator of those 49 directories no longer exists in the tree**:

```
$ grep -rln 'owned-wake-native' /Users/alex/ab/richos/richos    -> (no matches)
$ grep -rln 'owned-wake-native' /Users/alex/ab/richos/docs      -> 10 result files
```

**No file in the tree today creates that name** — the only matches are result files under
`docs/verification/owned-outcome/`, which is what that feasibility work produced. I cannot establish
from a `grep` who created the 49 directories or when the creator stopped existing; what the grep does
establish is that **the creator is not in the tree to be enumerated**. **An allowlist of names can
only contain names somebody reads off a creator, and a creator that is no longer in the tree cannot
be read.** That is not a gap to be patched with more names; it is the reason the approach cannot
converge.

Measured from the shipped script at HEAD — its plan mentions none of it:

```
$ scripts/scratch-reaper.sh --verbose | tail -1
verdict: decided deletable=0 reclaimable=0 B kept=1611 undecidable=0        (exit 0)

$ for f in richos-owned-wake-native richos-ecs-assessment richos-corpus \
           richos-setup prove-one node-compile-cache com.microsoft.VSCode; do
      grep -c "$f" plan.txt; done
0 0 0 0 0 0 0
```

`kept=1611` of 53,593: the invisible entries are not even counted as kept, so **no number in the
verdict line can be used to notice the gap.**

A controlled repeat, in a sandbox `$TMPDIR`, with three shapes the brief asked for — an unmatched
directory name, the shape a bare `mktemp -d` with no template produces, and a loose FILE:

```
C_unmatched         .../tmp/frank-attack-unmatched-c        (5 MB)
C2_mktemp_default   .../tmp/tmp.FrankAtk9                   (3 MB)
C3_loose_file       .../tmp/frank-attack-loose-file-c3      (2 MB)
```

All three backdated 30 days. None appears anywhere in the plan, as DELETE, KEEP or INDETERMINATE.
The legacy-family control in the same run (`root-mutation.FRANKAT.deadbeef`) was correctly planned
for deletion — so the arm was working and simply never looked at the other three.

### 1.2 `/private/tmp` outside the claude root: 25.77 GiB nobody sweeps (D2)

`SCRATCH_CLAUDE_ROOTS="/private/tmp/claude-%u /tmp/claude-%u"` — the two claude roots and nothing
else in `/private/tmp`.

```
$ du -sk /private/tmp            ->  34.71 GiB
$ du -sk /private/tmp/claude-501 ->   8.94 GiB          (swept)
                                     25.77 GiB          (swept by nothing)
$ ls -1d /private/tmp/richos-* | wc -l
396
$ du -sk /private/tmp/* | sort -rn | head -4
19.0 GiB  /private/tmp/richos-fixes-20260916      (16 Sep 14:51, no .git — logs and JSON)
 0.6 GiB  /private/tmp/richos-dotnet-8.0.424
 0.45 GiB /private/tmp/richos-1.2.0-candidate-sep16-g     (five sibling copies)
 0.35 GiB /private/tmp/richos-signed-plumbing-boot.Qdl0DA (five siblings)
```

**A single 19 GiB directory of two-day-old evidence, named `richos-*`, on the volume the watchdog
guards, and no arm of the mechanism has an opinion about it.** It is 18% of the 105 GB incident in
one directory, and unlike the incident nothing will ever remove it.

### 1.3 The other temp roots

```
$ du -sh /private/var/folders/mx/.../C     1.0G     (the user cache root, sibling of T — not swept)
$ du -sh ~/Library/Caches                 4.5G     (not swept; watchdog attribution only)
$ du -sh /private/var/tmp                 743M     (not swept)
$ du -sk /Volumes/E1TB/* | sort -rn
  36.03 GiB  /Volumes/E1TB/caches
  22.16 GiB  /Volumes/E1TB/vm
  11.31 GiB  /Volumes/E1TB/home
   0.00 GiB  /Volumes/E1TB/tmp          <- a temp root on the SSD, swept by nothing
$ grep -n 'SCRATCH_.*Volumes' orchestration.config   -> no SCRATCH_ declaration covers any /Volumes path
```

`~/Library/Caches` and `$TMPDIR/../C` are arguably other people's software. `/Volumes/E1TB/tmp` and
`/Volumes/E1TB/caches` are described as ours by the config's own addendum-3 comment ("cargo targets
and Playwright caches now live there") — I did not measure what created the 36.03 GiB, so read the
ownership as *unverified* and the size as measured. Either way **the scaled floor on that volume is
124 GB against 863 GB free, so there is no alert path either** — it is unswept and unwatched in practice for months at a time.

### 1.4 Unregistered workspace roots under `~/ab` (D3)

```
$ du -sk ...
  17.01 GiB  /Users/alex/ab/richos-rechecks              (deep-20260916, followup-20260916)
   8.41 GiB  /Users/alex/ab/richos-password-free-workspaces   (a whole extra checkout, 10 Sep)
   0.20 GiB  /Users/alex/ab/richos-wt/codex-fix-contrast-surface-coverage   (16 Sep)
   0.18 GiB  /Users/alex/ab/richos-wt/codex-owned-outcome-prd               (9 Sep)

$ grep -c 'codex-fix-contrast-surface-coverage\|codex-owned-outcome-prd' ~/.claude/state/worktree-ledger.jsonl
0
$ grep -c 'richos-rechecks\|password-free' ~/.claude/state/worktree-ledger.jsonl
0
```

**Not in the ledger, so the worktree reaper will never see them; not under a declared scratch root,
so the scratch reaper will never see them.** `~/ab` is precisely the directory the watchdog's alert
names as the biggest consumer (§4.1) — so on the day the disk gets low, the alert points at 71.9 GB
of `~/ab` without distinguishing the 25.42 GiB that no ledger row claims from the working
repositories. (Whether those piles are still wanted is not something a ledger query can answer —
which is exactly why an unregistered pile has no mechanism: nothing knows who to ask.)

### 1.5 A killed sandbox, and "undecidable forever"

I did not re-run Zach's `kill -9` case (G8 covers it and it passes). The material point is upstream
of it: a `SIGKILL`ed harness is reaped **only if its sandbox was allocated through `scripts/lib/scratch.sh`**.

```
$ grep -rl 'mktemp' scripts mega-lander | sort -u | wc -l        177
$ grep -rl 'lib/scratch.sh' scripts mega-lander | sort -u | wc -l  11
   of which: scratch.sh itself, scratch-reaper.py, the lint, the lint's test,
             mutation-harness.sh, mutation-harness-guards.test.sh, and 5 harnesses
```

**Adoption is five harnesses.** Everything else that gets killed lands outside the deny-by-default
root, where §1.1 applies.

"Undecidable forever" (D12): there is no permanent-undecidable pile today (`undecidable=0`), but the
channel is missing rather than quiet. `main()` returns 3 for undecidable — into
`~/.claude/state/scratch-reaper-launchd.log`, which nobody reads — and the watchdog's alert reads
**only** `scratch-failures.json` (`disk-watchdog.py:288-294`). The session-start notice mentions an
undecidable pile only above `SCRATCH_NOTICE_BYTES` (1 GiB). So under 1 GiB of permanently
undecidable garbage is invisible on every channel, and "undecidable is a failure, never a footnote"
holds in the reaper's own report and nowhere a person looks.

---

## 2. Attack 2 — make a failed deletion silent

### 2.1 The mode/flag retry holds; the parent's mode defeats it

I could not defeat `_make_writable` from inside the tree: it clears directory modes and `uchg`
recursively. So I moved one level out — the allocator root's own mode, which the retry never widens
because it widens the tree it was handed:

```
$ python3 setup_failure.py
staged .../richos-scratch/99999995-frank-unremovable-d2
allocator root mode now 0o500

$ scratch-reaper.sh --apply
DELETE  1.0 MB  .../99999995-frank-unremovable-d2
verdict: decided deletable=1 reclaimable=1.0 MB kept=1 undecidable=0
applied: deleted=0 freed=0 B log=.../reaper.log
EXIT=0
```

**Three findings from those four lines.**

1. **`EXIT=0`** (D10). A failed deletion is not in the exit code. `main()` ends
   `return 3 if undecidable else 0`; `failures` is never consulted. launchd sees green.
2. **stdout says `applied: deleted=0 freed=0 B`** — byte-identical in shape to a run with nothing to
   do. The word FAILED exists only inside the log file.
3. The durable record **works**, and it is the one thing standing between this and silence:

```
$ cat failures.json
{ ".../99999995-frank-unremovable-d2": {
   "attempts": 1,
   "error": "[Errno 13] Permission denied: '.../99999995-frank-unremovable-d2'",
   "first": "2026-09-18T09:04:35Z", "last": "2026-09-18T09:04:35Z" } }
```

### 2.2 Zach's inferred mtime reset, reproduced directly (H1)

Zach recorded the partial-`rmtree` mtime mechanism as *"an inference, not a measurement"*. The second
`--apply` against the same tree measured it:

```
why: pid 99999995 is ENDED ... and nothing has touched this for 0 min
```

The tree was 30 days old when staged. The first failed attempt deleted the child `payload` and then
could not `rmdir` the parent, which reset the directory's mtime to now — **exactly the signature he
described** — and the standing-failure path retried it regardless of age, which is the fix working.
That part is HELD and now has a measurement behind it rather than an inference.

### 2.3 One environment variable silences every failure alert (D9)

`failures_path()` in the reaper honors `CLAUDE_CONFIG_DIR`
(`scratch-reaper.py:473-476`). The watchdog's reader does not
(`disk-watchdog.py:283-285`: `expand(env("SCRATCH_FAILURES_STATE", "~/.claude/state/scratch-failures.json"))`).
`SCRATCH_FAILURES_STATE` is declared in **no** config file, so nothing reconciles them.

```
$ CLAUDE_CONFIG_DIR=.../cfg scratch-reaper.sh --apply | tail -1
applied: deleted=0 freed=0 B log=.../cfg/state/scratch-reaper.log      EXIT=0
$ ls .../cfg/state/
scratch-failures.json  scratch-reaper-state.json  scratch-reaper.log

$ CLAUDE_CONFIG_DIR=.../cfg disk-watchdog.sh --alert
EXIT=0            # nothing printed. No alert.
```

For contrast, with the paths agreed, the alert is good — it names the path, the first sighting, the
attempt count and the error, and tells Rich to delete it by hand:

```
  1 GARBAGE PATH(S) COULD NOT BE DELETED. The CEO's rule:
  if the clean-up fails, Rich deletes it BY HAND.
    .../99999995-frank-unremovable-d2
      first seen 2026-09-18T09:04:35Z, 1 attempt(s), [Errno 13] Permission denied: ...
```

`CLAUDE_CONFIG_DIR` is not set in this session (`echo "[${CLAUDE_CONFIG_DIR:-unset}]"` → `[unset]`),
but it is a live knob the engine's own suites export (`scripts/run-all-tests.test.sh:43`). One
exported variable in an operator's shell profile turns the MASSIVE ALERT off with no sign that it is
off. Cost to close: one `env()` lookup, plus declaring `SCRATCH_FAILURES_STATE` once.

### 2.4 A directory that reappears after removal

Not a silent-failure defeat: the reaper deletes it, the zombie child recreates it, and the next run
sees a fresh young directory and KEEPs it for the age floor — each run reporting success while the
pile returns. There is no repeat-offender memory (the failures file drops a path the moment it is
gone, which is right for failures and wrong for recurrences). I rank this below D1–D4 because a
recreating child is rarer than the four certainties, but it is the mechanism by which a fixed leak
looks fixed forever.

### 2.5 A symlink into a real repository (H3)

Held, and cleanly. A symlink in the allocator root aimed at my own worktree:

```
DELETE  0 B  .../richos-scratch/99999996-frank-symlink-f
        why: a symlink in the allocator root, which the allocator never creates
```

`apply()` uses `os.unlink` for links (`scratch-reaper.py:1352-1355`) and `_make_writable` returns
early on links. The target was untouched: `/Users/alex/ab/richos-wt/frank-opus-garbage1` is intact.

---

## 3. Attack 3 — make the app leave garbage (addendum 2)

**Addendum 2 says the app must clean up its garbage "no matter what". The app has no mechanism to
fail at.**

```
$ grep -rn 'temp_dir()' --include='*.rs' richos/app/crates | wc -l         151
$ grep -rn 'temp_dir()' --include='*.rs' richos/app/crates | grep -c '/src/'  61
$ grep -rln 'richos-scratch\|scratch_alloc\|SCRATCH_ROOT' --include='*.rs' richos/app
(no matches)
```

**Zero app-side use of the allocator.** Runtime sites include
`richos-voice/src/controller.rs:319` (`scratch_dir: std::env::temp_dir().join("richos-voice")`) and
`richos-voice/src/stt.rs:365` (`richos-voice-calibration`). Neither name matches any declared
pattern, so §1.1 applies to all of it. On disk today:

```
$ ls -1d $TMPDIR/richos-voice* | wc -l          101
$ du -sk $TMPDIR/richos-voice* | awk ...        0.1 MB in 101 entries
   ... timestamps 18 Sep 07:08 through 09:47 — created today
```

Small in bytes, permanent in count, and **the entry count was itself the unusable condition** in the
incident (88,829 entries made a `du` take minutes and a per-entry `lsof` impossible). `TempDir` from
the `tempfile` crate removes on `Drop`, and `Drop` does not run on `SIGKILL`, on force-quit, or on
an abort — which is the precise "no matter what" the addendum names.

The "what" the app does not survive, listed plainly: **SIGKILL, force-quit, panic-abort, and being
killed mid-land** — in all four cases whatever it left under `temp_dir()` is outside the allocator
root and outside the allowlist, i.e. permanent.

---

## 4. Attack 4 — defeat the watchdog

### 4.1 Forced alert: what it says on the day it matters (D13)

Fixture config, absolute floor raised so the alert must fire, and the CEO's two notification
thresholds set to 0 so **no notification was ever posted to him** during this test:

```
$ DISK_WATCHDOG_CONFIG=.../config-forcealert disk-watchdog.sh --check
  MASSIVE ALERT — DISK SPACE
  /System/Volumes/Data — 182.5 GB FREE of 460.4 GB (39.6%): below the declared 99999 GB floor
  BIGGEST MEASURED CONSUMERS:
    71.9 GB    /Users/alex/ab
    22.2 GB    /Volumes/E1TB/vm
    10.3 GB    /Users/alex/.claude
  CLASSIFICATION: other
EXIT=1
```

`DISK_CONSUMER_CANDIDATES` contains `$TMPDIR ~/.claude ~/ab ~/.richos-nightly ~/Library/Caches
~/Library/Developer ~/.cargo ~/.npm ~/Library/Containers /Volumes/E1TB/vm` — **`/private/tmp` is not
in it.** So the 25.77 GiB pile of §1.2, larger than the second and third entries on that list, cannot
appear in the alert at all. And `richos_garbage_bytes()` counts only the allocator root and the
claude roots by deliberate design (`disk-watchdog.py:100-116`), so **the classification sees roughly
a quarter of our own garbage**: 8.9 GB counted against ~27 GiB of RichOS-named garbage measured in
§1.1 and §1.2. The alert that is supposed to distinguish "our defect" from "a video export" is
computed from two of the at least five places our garbage lives.

### 4.2 The drop alarm has no divisor (D7)

`drop_bytes = old_free - free` against whatever the previous reading was, with no elapsed-time term
(`disk-watchdog.py:267-281`). A baseline 10 hours old — a closed laptop, a wake from sleep, an
upgrade window, a job unloaded and reloaded:

```
$ python3 mkstate.py 10 30      # baseline 10.0 h old, 30 GB above current free
$ DISK_WATCHDOG_CONFIG=.../config-drop disk-watchdog.sh --check
  MASSIVE ALERT — DISK SPACE
  /System/Volumes/Data — 181.5 GB FREE of 460.4 GB (39.4%): DROPPED 30.0 GB since the last reading
  CLASSIFICATION: RichOS garbage (DEFECT)
  RichOS's own scratch is 8.9 GB of this. ...
EXIT=1
```

**3 GB/hour is a normal working day on this machine and it produced a MASSIVE ALERT calling it our
defect.** There is a staleness guard, but it only applies to `--alert` mode and only above ten
intervals (`disk-watchdog.py:424-433`), and it changes nothing about the arithmetic. This is the
false-positive engine that ends with the alert being ignored — the same failure Zach narrowed wall 2
to avoid, arriving through the other door.

### 4.3 The threshold's justification is not supported by the record it cites (D8)

`orchestration.config` says of `DISK_DROP_ALERT_GB="20"`: *"THIS IS THE THRESHOLD THAT WOULD HAVE
CAUGHT 2026-09-17, and the absolute one would not have in time."* The record it rests on establishes
the sandbox was created at 22:39 and the reaper's next run was 03:40 — **a window of at least five
hours for 105 GB, which is ~21 GB/hour, or ~5.3 GB per 15-minute tick, roughly a quarter of the
threshold.** If the four copies instead ran back-to-back at local-disk speed the rate would be far
above it. **Neither reading is measured anywhere**, so the claim is unproven in both directions; what
IS established is that the absolute 60 GB floor would have fired, because free space reached 49 GB.
The threshold may still be the right number — but it is not the number that caught the incident, and
a rationale that says otherwise will be trusted the next time somebody tunes it.

### 4.4 The rest of attack 4

- **Both timers are armed** (`launchctl list | grep richos` → `com.richos.scratch-reaper`,
  `com.richos.disk-watchdog`; plists dated 18 Sep 09:42), and readings are current:
  `08:42:57Z`, `08:46:38Z` — the 15-minute cadence is real.
- **Config wiring is fixed**: `--status` shows both volumes including `/Volumes/E1TB` with the
  scaled 124 GB floor, which is the symptom Zach used to find the missing `export`.
- **An absent volume** is skipped silently by design; I did not unmount the SSD to prove it.
- **When the CEO is not logged in**, the code comment claims `osascript` *"needs no app and no
  session"*. A `gui/<uid>` launchd agent does not run at all without a GUI session, so in the
  logged-out case nothing fires and nothing is queued; the notification arrives after the next
  login. The failure is handled (`NOTIFY-FAILED ... osascript would not post` is logged), so this is
  a doc overclaim, not a hole.
- **95% vs 99% full**: the thresholds are absolute GB, so on this 460 GB volume the CEO's first
  notification lands at 89.1% used and the urgent one at 94.6%. There is no percentage path, which
  is correct for this machine and would misbehave on a much larger volume — the scaling only applies
  to extra volumes.

---

## 5. Attack 5 — Docker

```
$ docker system df
Images        13   6  19.29GB  16.25GB (84%)
Containers     6   6   1.394GB      0B (0%)
Local Volumes 25   4  523.1MB  402.2MB (76%)
Build Cache  209   0  16.71GB  13.14GB

$ docker ps -a --filter status=exited --format ...      (empty — no stopped containers)
$ docker ps --format '{{.Names}} | {{.Image}} | up {{.RunningFor}} | {{.Command}}'
rl55 | richos-linux:git-latest | up 8 days ago | "sleep infinity"
rlx  | richos-linux:24.04      | up 8 days ago | "sleep infinity"
buzz-prod-relay-1 / postgres-1 / redis-1 / minio-1   (8 weeks, healthy — real services)

$ docker volume ls -qf dangling=true | wc -l            21
```

- **A running container is immortal by design.** The code says so as a virtue: *"`container prune`
  only ever considers STOPPED containers. A running one is not a candidate at any age."* `rl55` and
  `rlx` are `sleep infinity` shells from 8 days ago, pinning `richos-linux:git-latest` (514 MB) and
  `richos-linux:24.04` (349 MB) so `image prune -a` can never reclaim them. Nothing alerts on a
  `sleep infinity` container older than N days. **DEFEATED, small, and certain to recur** — that is
  how dev containers are used.
- **The younger-than-30-days pin is real but unexercised today**: there are no exited containers, so
  I could not measure it. The mechanism is sound: a container that exited 29 days ago would survive
  stage 1 and pin its image through stage 2, for up to a month, silently.
- **No volume prune stage.** 402.2 MB of unreferenced volumes across 21 volumes, with no arm that
  will ever consider them. The ruling named containers, images and build cache, so this is a gap
  against "always cleaned up" rather than against his words.
- **The staged prunes reclaim nothing on today's machine and will not for weeks**: every image is
  4–14 days old (`richos-ci:amd64` 4 days, `richos-linuxci:*` 11 days), and the build cache is
  16.71 GB against a 20 GB `--keep-storage` floor. The log lines
  (`DELETED docker bytes=0 class=docker-image-prune`) are honest about that, but they inflate
  `deleted` by 3 per run for no reclaimed bytes, which makes the verdict line's `deleted=` count
  less useful than it looks (`deleted=3 freed=0 B` at 08:50).

---

## 6. Attack 6 — the test-instance rule (addendum 4)

**Confirmed, live, while I was writing this.** The reason it is ranked D5/D6 rather than noted as a
pending brief is that the live shape also triggers a deletion defect:

```
$ pgrep -fl 'richos-tauri'
60433 /bin/bash /private/var/folders/.../T/richos-scratch/60397-appinstances-test-5ojuznm7/bundle/richos-tauri

$ ps -p 60433 -o pid,ppid,command
60433     1 /bin/bash .../bundle/richos-tauri          <- PPID 1: already detached to launchd
$ ps -p 60397 -o pid,command
60397 bash scripts/lib/appinstances.test.sh            <- the owner, still alive
```

1. **Nothing collects pid 60433 when its test ends.** There is no process arm anywhere in the
   mechanism — the reaper reaps directories, and `detect-nonnative-worktree.sh` reports orphan PIDs
   only for removed worktree paths. Addendum 4 is unmet today. Zach's `zach-opus-testinst1` is
   working on it; this confirms the gap and its shape.
2. **Worse: when 60397 exits, the reaper will delete the tree out from under the still-running
   60433.** `scan_scratch_root` decides liveness from the ledger pid or the pid in the name and
   **never consults the open-file snapshot** — unlike both `$TMPDIR` arms, which do. I proved the
   consequence rather than arguing it:

```
   fixture:  .../richos-scratch/99999998-frank-openheld-a   (owner pid 99999998, dead)
   holder :  tail -f .../99999998-frank-openheld-a/payload  (pid 76454, alive)
   lsof sees it: ['76454']

   $ scratch-reaper.sh --apply
   DELETE  2.0 MB  .../99999998-frank-openheld-a
           why: pid 99999998 is ENDED (owner of 'unrecorded', from the directory name) ...
   applied: deleted=5 freed=6.0 MB

   $ ls .../richos-scratch/
   1-frank-immortal-b          <- the only survivor
   $ ps -o pid,command -p 76454
   76454 tail -f .../99999998-frank-openheld-a/payload      <- still running, file gone
```

**The arm deleted the directory a live process was reading and kept the one directory that can never
be deleted.** That inversion is the single most important finding after D1–D4, because it is not
garbage that survives — it is running work that does not.

### The immortal keep, in the same run (D11)

```
KEEP  2.0 MB  .../richos-scratch/1-frank-immortal-b
      why: pid 1 is ALIVE (owner of 'unrecorded', from the directory name)
           — a live owner is kept whatever its TTL says
```

`pid_from_name()` takes the digits before the first `-`; `pid_alive()` returns True on
`PermissionError`, which is what pid 1 gives. A directory whose name begins with a long-lived pid is
kept forever, at any size, with no alert and no TTL escape. macOS recycles pids at 99998, so a
week-old name colliding with a live pid is not exotic — and the failure is silent by construction,
because a KEEP is the reaper working as designed.

---

## 7. The lint that would have stopped the next family is wired nowhere (D16)

```
$ grep -rn 'scratch-allocation-lint' --include='*.json' --include='*.sh' --include='*.yml' \
       --include='*.py' --include='*.md' .
docs/verification/2026-09-18-garbage-always-cleaned-up.md:362   (the record)
docs/verification/2026-09-18-garbage-always-cleaned-up.md:460   (the record)
```

Not in `hooks/hooks.json`, not in `.claude/settings.local.json`, not in the contract-integrity probe,
not in any test runner. Its own header says *"the allocator only helps for the code that USES it, and
the next `mktemp -d` somebody writes is outside it again"* — and nothing runs it, so the declared
baseline of 45 can only be checked by somebody who remembers to. CI is paused by CEO ruling, so CI is
not the answer; a PostToolUse notice or a probe layer is.

Its two declared holes also aim away from the garbage that is actually here: **test files are exempt
by default**, and every family in §1.1 (`richos-corpus-*` at 266 each, `richos-setup-*` at 206 each,
`containers-test-registry` at 1,469, `gate-mut` at 1,299) is harness scaffolding. The record's claim
that the remaining 45 sites are *"already swept today by the reaper's legacy families"* is the claim
§1.1 contradicts: those families are on disk, 9–10 days old, and matched by nothing.

## 7b. The recursion guard covers one copy path of seven (D17)

```
$ grep -rln 'mut_refuse_recursive_copy' scripts        -> mutation-harness.sh, its own test
$ grep -rln 'mutation_copy_engine' scripts mega-lander | wc -l      6
$ find . -name '*.mutation.sh' | wc -l                              43
$ harnesses with their own cp -R/rsync and no mutation_copy_engine:
  scripts/hooks/ceo-todos.mutation.sh
```

The containment and ceiling refusals live inside `mutation_copy_engine`
(`mutation-harness.sh:380-381`), which is the right place — but they are reached only by the six
harnesses that call it. `ceo-todos.mutation.sh` copies a tree with its own `cp -R` and is outside
both refusals (its sandbox does sit in the allocator root, so it is at least reapable). The invariant
is enforced per-caller, not per-copy.

---

## 8. What the CEO's rule actually requires, and where the shape falls short

His sentence has two halves and the mechanism implements one of them well:

- *"always cleaned up afterwards"* — implemented for the allocator root, the claude session roots,
  five migrated harnesses, the declared legacy families and Docker. **Not implemented for anything
  else, and "anything else" is 97.8% of `$TMPDIR` entries, all of `/private/tmp` outside one
  directory, all of `~/ab`, all of `/Volumes`, and the entire app.**
- *"or Rich must get a MASSIVE ALERT about it"* — implemented for **free space** and for **failed
  deletions**. There is **no alert for garbage that no arm considered**, which means the uncleaned
  case produces neither cleanup nor alert. Both halves of the rule are satisfied simultaneously only
  for the paths the mechanism already sweeps.

That is why I rank D1–D4 above every clever trick: the mechanism is not defeated by an adversary, it
is defeated by scope, and its own reports read green while ~53 GiB sits there.

---

## 9. The three fixes that close the most likely defeats

### Fix 1 — invert `$TMPDIR` and `/private/tmp` to deny-by-default, with a KEEP-list of foreign owners

Closes **D1, D2** (and shrinks D16's blast radius). The reaper already contains the correct shape —
`scan_scratch_root` is deny-by-default and the comment explains why: *"it never asks what the
directory is called."* Apply that shape one level up. Every direct child of `$TMPDIR` and of
`/private/tmp` is a candidate when it is past the age floor, held open by nothing, not a registered
workspace, not inside a never-touch path, and **not matched by a short declared list of FOREIGN
owners** (`com.apple.*`, `.com.openai.codex*`, `com.microsoft.*`, `node-compile-cache`,
`BlobRegistryFiles`, …). The asymmetry is the whole argument: a keep-list names other people's
software, is short, and stops growing; an allowlist names ours, is unbounded, and must be extended
by whoever remembers. Measured coverage gain on today's disk: **52,409 entries / 1.90 GB plus
25.77 GiB**. Keep the legacy families as they are — under deny-by-default they become redundant and
can be deleted from the config, which is the migration ramp emptying as designed.

### Fix 2 — make the reaper report what it did NOT consider, and put that number in the alert

Closes the missing half of the ruling, and would have replaced this entire report with one line.
Add `skipped=N skipped_bytes=B` to the verdict line, publish it in `scratch-reaper-state.json`, and
have the session-start notice and the turn-end disk notice say it above the same declared threshold —
plus `undecidable` at any size, since `SCRATCH_NOTICE_BYTES` currently hides up to 1 GiB of it. The
sentence *"1.90 GB in 52,409 entries under `$TMPDIR` was not considered by any arm"* is cheap to
compute (the scan already lists the directory) and it is the only kind of alert that survives the
next unforeseen name. While in there: declare `SCRATCH_FAILURES_STATE` in `orchestration.config` and
make the watchdog honor `CLAUDE_CONFIG_DIR` (**D9**), and let a non-zero failure count reach the
reaper's exit code (**D10**).

### Fix 3 — one wall on the allocator arm, one floor on the pid, one divisor in the watchdog

- **(a) Consult the open-file snapshot in `scan_scratch_root` before deleting** (**D5, D6**). It is
  already cached and already used by both `$TMPDIR` arms; the allocator arm is the only one that
  trusts a pid alone, and it is the arm the app's own test instances live under. This is data loss,
  not garbage, and the shape is on the machine today.
- **(b) Treat a name-derived pid as attribution, not liveness** (**D11**): require the ledger row to
  agree, or treat a pid below a declared floor (or one whose process start time precedes the
  directory's creation) as unattributed rather than alive. An immortal KEEP must be impossible,
  because it is silent by design.
- **(c) Divide the drop by elapsed time** (**D7, D8**): alert on GB/hour against a declared rate,
  and refuse to compute a rate at all across a gap longer than a declared number of intervals —
  reporting the gap instead. Then correct the rationale in `orchestration.config` to say what the
  record supports: the absolute floor is what would have fired on 2026-09-17; the rate alarm's job
  is the faster incident nobody has measured yet.

**Not in the three, but cheap and worth doing in the same pass:** add `docker volume prune
--filter until=…` as a fourth stage; age-alert on a running container whose image is a declared
throwaway (`sleep infinity` at 8 days); register `scratch-allocation-lint.sh` somewhere that runs;
and give `~/ab`'s campaign roots (`richos-rechecks`, `richos-*-workspaces`) either a ledger row at
creation or a declared retention, since they are the biggest single pile after the repositories and
the alert already points at their parent.

---

## 10. The garbage I made, and it is gone

Everything was created under this session's own scratchpad (`.../scratchpad/frank-gsb`) with a
sandbox `TMPDIR`; nothing was written to the real `$TMPDIR`, to `/private/tmp`, to `~`, or to any
repository. The two launchd jobs were never touched.

```
$ python3 teardown.py
killed holder pid 76454
sandbox present after removal: False
frank-attack       leftovers: none
frank-immortal     leftovers: none
frank-openheld     leftovers: none
frank-nopid        leftovers: none
frank-locked       leftovers: none
frank-unremovable  leftovers: none
frank-symlink      leftovers: none
FRANKAT            leftovers: none
FrankAtk           leftovers: none
/Users/alex/.claude/state/scratch-failures.json exists: False
```

The last line matters: the real machine's failure record is still absent, so nothing I did left a
standing alert behind. The one mode I tightened (the sandbox allocator root, `0o500`) was reopened
before removal. The sandbox `richos-scratch` fixtures that the reaper deleted during the `--apply`
runs were my own fixtures, inside my own sandbox `TMPDIR`.

**Read-mostly discipline:** I ran `--apply` twice, both times with `TMPDIR`,
`SCRATCH_REAPER_LOG`, `SCRATCH_REAPER_STATE` and `SCRATCH_FAILURES_STATE` redirected into the
sandbox, so no real state file and no real garbage was altered by this attack. The watchdog runs
that alerted used fixture configs with the CEO's notification thresholds set to 0, so **no macOS
notification was ever posted to him.**

---

## 11. Brief claims I re-derived, and what I found

| the brief said | what I found |
|---|---|
| addendum 3: 30 days, 20 GB build cache | **Correct**, sourced: `SCRATCH_DOCKER_UNTIL="720h"`, `SCRATCH_DOCKER_KEEP_STORAGE="20GB"` (`orchestration.config:875-877`). The brief's provenance note said nothing in scope sourced it; the config does. |
| the implementation prunes dangling images only | **Stale.** It ships `image prune -a -f --filter until=720h` — the stricter rule the CEO chose after Zach reported the gap. |
| 105 GB, four mutants, exact doubling | **Consistent with the record**; I did not re-measure a deleted directory and make no claim about it. |
| Zach "could not reproduce the path arithmetic" | **Correct, and the guards do not depend on it.** I also reproduced the mtime-reset mechanism he could only infer (§2.2). |
| "95% vs 99%" | Not in the config; the thresholds are absolute GB (60/50/25) and there is no percentage path (§4.4). |
| the launchd jobs are armed | **Verified**: both listed, plists 18 Sep 09:42, readings current to the 15-minute cadence. |
| "a Zach brief exists for test instances; confirm and rank" | **Confirmed live** (pid 60433, ppid 1) and ranked D6 — with the D5 deletion defect attached to the same shape. |

# Why a blocking guard, registered on both surfaces, was silent on the exact case it was written for

- date: 2026-09-14
- author: zach-opus-silent1
- subject: `engine/scripts/hooks/guard-hook-registration-commits.sh`
- verdict: **the guard was never invoked.** Its logic is correct. The host never
  loaded it, because it was registered into a session that had already been
  running for eight hours.

Every number below carries the command that produced it.

---

## 1. The cause, in one sentence

**The host reads the plugin hook table once, at OS-process start. The guard
landed at 08:10 into a session whose process started at 23:59:44 the previous
night, so it was absent from that session's hook table for the whole of its
remaining twenty-two hours — including at 20:25, when that session's subagent
made the exact commit the guard exists to refuse.**

```
$ ps -eo pid,lstart,command | grep '[c]laude'
75476 Sun 13 Sep 23:59:44 2026     claude --dangerously-skip-permissions

$ stat -f 'birth=%SB' -t '%Y-%m-%d %H:%M:%S' \
    ~/.claude/projects/-Users-alex-ab-femcboost/b7d89f44-e47a-4f64-a551-b41bd8468250.jsonl
birth=2026-09-14 00:00:29

$ git log -1 --format='%h %ci %s' c730240e     # the registration
c730240e 2026-09-14 08:10:13 +0100 The new guard pays its own five places, ...

$ git log -1 --format='%h %ci %s' c495a7b9     # the commit it should have refused
c495a7b9 2026-09-14 20:25:04 +0100 The scope check refuses the spawn, ...
```

`08:10` is **8 h 10 min after** the process started. This is the documented
rule — "hooks are snapshotted per session" — meeting a case nobody had costed:

> **A GUARD CANNOT PROTECT THE SESSION THAT LANDS IT.** It ships, it is
> registered, it is correct, and it is inert for exactly as long as the session
> that wrote it keeps running. Here that was another fourteen hours.

---

## 2. The reproduction

Run inside `/Users/alex/ab/richos-wt/zach-opus-silent1` (branch
`cc/zach-opus-silent1`), tree at `8a7ca1fa`.

**Control — the tree owes nothing before the probe:**

```
$ bash engine/scripts/hook-registration-completeness.sh --root . --baseline HEAD
exit=0      # COMPLETE: every derived inventory names every subject.
```

**Arrange — register a hook in `hooks.json` and nowhere else,** the condition
the guard blocks. (Probe hook `zzz-probe-silent1.sh`, reverted afterward.)

```
$ bash engine/scripts/hook-registration-completeness.sh --root . --baseline HEAD
exit=1
  subjects   : zzz-probe-silent1.sh
  4 places owing.
```

The same shape the lead measured against `c495a7b9^`.

**Act — commit it through the Bash tool, the way an agent does:**

```
$ git -C /Users/alex/ab/richos-wt/zach-opus-silent1 commit -m "REPRO PROBE: ..."
[cc/zach-opus-silent1 07dbcac4] REPRO PROBE: register a hook in hooks.json only
 2 files changed, 11 insertions(+), 1 deletion(-)
```

**Accepted, in complete silence.** No refusal, no stderr, no notice — and via
`git -C`, the form even the pre-2026-09-01 hand-copied resolution handled, so
no jurisdiction subtlety is involved.

**Control — the same payload, handed to the guard directly:**

```
$ bash /Users/alex/ab/richos/engine/scripts/hooks/guard-hook-registration-commits.sh \
      < payload.json ; echo "exit=$?"
exit=2
=== HOOK REGISTRATION COMPLETENESS: REFUSING THIS commit ===
  repository : /Users/alex/ab/richos-wt/zach-opus-silent1
  ...
  4 places owing.
```

**The guard refuses. The host simply never asked it.** That pair is the whole
diagnosis: the defect is not in the guard, it is in whether the guard is loaded.

---

## 3. Hypotheses tested and refuted

The brief offered four. All four are wrong, and two are worth recording because
they are expensive to re-derive.

**(a) Stale plugin cache — REFUTED, despite looking overwhelming.**
`~/.claude/plugins/installed_plugins.json` pins the plugin to a *copy*:

```
"installPath": "/Users/alex/.claude/plugins/cache/richos-local/richos-engine/1.0.0",
"gitCommitSha": "a279a587f167d388f1e106b46597445cc8cc663c"   # 2026-09-08
```

That copy neither contains the guard nor registers it, and its `PreToolUse[Bash]`
chain differs from the repository's by **exactly the one entry**:

```
CACHE 12 [... guard-ci-red-lands.sh, shell-evidence.sh]
REPO  13 [... guard-hook-registration-commits.sh, guard-ci-red-lands.sh, shell-evidence.sh]
```

It is a perfect-looking answer and it is false. `workspace-lifecycle.sh` is
registered in the repository's `hooks.json` and is **absent from the cache
entirely** — yet it wrote records for this very agent today:

```
$ ls ~/.claude/state/workspaces/agents/
b7d89f44-e47a-4f64-a551-b41bd8468250--zach-opus-silent1.json     (14 Sep 22:30)
```

A hook that is not in the cache cannot run from the cache. **The repository is
the live plugin root; the cache is vestigial.** This also independently confirms
`zach-opus-landgate1`'s refutation in `esc-20260914T211915Z-aca67745`, by a
different route.

**(b) `richos_git_anchor` resolves the wrong repository — REFUTED.** The direct
run in §2 resolved `/Users/alex/ab/richos-wt/zach-opus-silent1` correctly from a
payload whose `cwd` is the femcboost worktree.

**(c) The classifier misses the command form — REFUTED.** Same run: the
classifier returned `commit` and the guard reached its refusal.

**(d) Exit 2 overridden, or one of eleven `exit 0` paths — REFUTED.** It exits 2
on this payload. No path was taken because the script was never executed.

**The fifth cause is §1**, and the positive/negative evidence is symmetric:

| hook | registered | vs process start 2026-09-13 23:59:44 | observed |
|---|---|---|---|
| `workspace-lifecycle.sh` | 2026-09-11 10:44 | before | **fires** (records above) |
| `guard-ci-turn-gate.sh` | 2026-09-13 21:52 | before | **fires** (`~/.claude/state/ci-turn-gate/sessions/b7d89f44-….json`) |
| `guard-hook-registration-commits.sh` | 2026-09-14 08:10 | **after** | **silent** (§2) |
| `guard-brief-scope.sh` | 2026-09-14 20:25 | **after** | silent |

Registration timestamps from `git log -S'<script>' -- engine/hooks/hooks.json`.

---

## 4. Is this specific to this guard? No. It is all of them.

This is the half the lead asked to be weighed highest, and the answer is total.

```
$ python3 engine/scripts/check-census.py --engine-root engine --format json
   -> 72 checks: CONTROL 37, INSTRUMENT (person) 27, INSTRUMENT (author) 2, RECORD 6
```

Cross-referencing those 37 CONTROLs against the registration surface:

```
CONTROLs total:                                     37
CONTROLs registered on the FROZEN plugin surface:   37
CONTROLs not on it:                                 []
```

**Thirty-seven of thirty-seven.** Not one CONTROL is exempt. Every blocking
guard in this engine is inert, from the moment it lands, for the entire
remaining life of every session already running — and sessions here run for
more than a day (this one: `23:59:44` to `22:30`+, still alive).

Five hooks landed after this session booted. The engine's own notice names all
five:

```
$ cat /Users/alex/ab/femcboost/.claude/state/hook-staleness-b7d89f44.announced
NEW-SCRIPT	guard-brief-scope.sh
NEW-SCRIPT	guard-hook-registration-commits.sh
NEW-SCRIPT	handoff-facts-annotate.sh
NEW-SCRIPT	notice-claim-capability.sh
NEW-SCRIPT	notice-protected-ref-moves.sh
```

Six commits touched `engine/hooks/hooks.json` after the session booted
(`git log --since='2026-09-13 23:59:44' -- engine/hooks/hooks.json`). This is
not a rare alignment; it is most days.

---

## 5. The second defect: the record that made the lead believe otherwise

The brief's premise — the guard was "present in the booting session's hook set"
— rested on `enforcing-hooks-b7d89f44.snapshot`. That file is not what its name
claims.

```
$ head -2 /Users/alex/ab/femcboost/.claude/state/enforcing-hooks-b7d89f44.snapshot
# session=b7d89f44-… generated=2026-09-14T19:10:17Z … rows=75
```

**A "session start" baseline stamped `2026-09-14T19:10:17Z` for a process that
started `2026-09-13 22:59:44Z` — twenty hours and ten minutes late.**

`snapshot-enforcing-hooks.sh` ran `mv -f "$TMP_PATH" "$SNAP_PATH"` on every
`SessionStart`. But `SessionStart` is not one event: the host fires it again on
`/clear` and on every compaction, **in the same process**, where the loaded hook
table has not moved at all. So a compaction rewrote the baseline from the
current contents of `hooks.json`.

**The overwrite forgives.** Every mid-session guard becomes part of the new
baseline, `notice-hook-staleness.sh` then compares equal, and it reports no
drift for the rest of a session in which those guards still enforce nothing.
That is why the warning appeared once and then stopped, and why the artifact
read as proof of the opposite of the truth.

### The notice fired, correctly, and the assistant could not hear it

`notice-hook-staleness.sh` detected this and named the guard. Its message is
excellent — "ENFORCING NOTHING RIGHT NOW", "TO ARM THEM: RESTART THIS SESSION",
"THIS IS YOURS TO DO". It emitted on `{"systemMessage"}` alone.

By the engine's own measured channel table (in that file's header, taken
2026-09-14): on `Stop`, `systemMessage` reaches the **person** and
`additionalContext` reaches the **model**. So the orchestrator never received
it, went on reasoning that its guards were live, and twelve hours later wrote
that belief into a brief as an established premise.

"Who can perform the remedy" and "who needs to know the fact" are different
questions. The original header conflated them.

---

## 6. What was changed — no new guard, two repaired

Per the standing constraint (no new guard without deleting one): **no hook
script was created.** Three existing files changed; the diff adds no file.

```
 engine/scripts/hooks/hook-staleness.test.sh      | 96 ++++++++++++++++
 engine/scripts/hooks/notice-hook-staleness.sh    | 62 +++++++++---
 engine/scripts/hooks/snapshot-enforcing-hooks.sh | 55 ++++++++++
```

1. **`snapshot-enforcing-hooks.sh` — the baseline is write-once per OS process.**
   `SessionStart` carries a `source`. `startup` and `resume` are new processes,
   so the host really did re-read the table and the baseline must refresh.
   `clear` and `compact` are the same process, so the baseline must not move.
   An unknown or absent source keeps the old behavior, because "I could not
   check" must never be produced by a fix for "I checked the wrong thing".

2. **`notice-hook-staleness.sh` — the fact goes to both audiences.** The
   `systemMessage` is unchanged; `additionalContext` is added so the assistant
   can learn its guards are off. The request still names the operator.

### The reproduction fails before and passes after

```
pre-change  (git checkout HEAD -- the two hooks, new cases only):
  FAIL  12   source=clear preserves the baseline    (rows 76->77; guard leaked in)
  FAIL  12   source=compact preserves the baseline  (rows 76->77; guard leaked in)
  FAIL  12b  inert guard survives compaction        (said: <nothing>)
  PASS  12c  source=startup DOES refresh            <- control, passes both ways
  PASS  12c  source=resume DOES refresh             <- control, passes both ways
  FAIL  13   notice reaches both audiences          (MISSING:additionalContext…)
  hook-staleness: 30 passed, 4 FAILED

post-change:
  hook-staleness: 34/34 cases pass
```

Case **12b** is the one that matters: on current code the notice says
**nothing** about an inert guard once a compaction has happened. That is the
observed silence, reproduced in a sandbox.

Neighboring suites, unchanged and green:

```
engine/scripts/hooks/engine-status.test.sh          18/18
engine/scripts/hooks/stop-hook-visibility.test.sh   42/42
engine/scripts/hooks/session-start-stdin.test.sh    13/13
engine/scripts/hook-registration-completeness.sh --root . --baseline HEAD   exit=0
```

---

## 7. What this does NOT fix, and the structural answer

**Be clear about the limit: the repair above makes the inertness VISIBLE and
keeps it visible. It does not make a landed guard fire.** Nothing inside a
session can; only a restart re-reads the table. Detection is all a hook can
offer, which is precisely why the structural answer matters more.

**Removing the circumstance is possible, and the engine has already half-built
it.** Every guard is registered on two surfaces, and the second one hot-reloads:

> `hooks/hooks.json` ............ FROZEN at session start.
> `.claude/settings.local.json` . HOT-RELOADS mid-session.
> — measured in `snapshot-enforcing-hooks.sh`'s header; asserted by
> `hook-staleness.test.sh` case 8b.

The silent guard **is** on that second surface:

```
$ grep -c 'guard-hook-registration-commits' engine/.claude/settings.local.json
1
```

So why did it not hot-reload? **Because that file is
`engine/.claude/settings.local.json` — it governs sessions whose project
directory is `/Users/alex/ab/richos/engine`, and all the work happens in
sessions rooted at `/Users/alex/ab/femcboost`.** The hot-reloading half of the
dual registration is out of scope for every session that does anything.

That is the circumstance to remove, and it resolves one of two ways — both
above my seat, both cheap to state:

- **Make the second surface count.** Register the engine's guards in the
  settings file the governing session actually reads. A landed guard would then
  be live immediately, with no restart, and this entire failure class ends.
- **Or admit it is inert and stop paying for it.** Today every new hook must be
  added to `engine/.claude/settings.local.json` — it is inventory #1 in the
  completeness predicate, and one of the "four places owing" that took `main`
  red. If that surface protects no real session, the engine is charging every
  hook author for a registration that does nothing.

**One of those two is true and they cannot both be. Either way the answer is
subtraction, not another guard.** I did not build either, because the choice is
a design decision and `sage-opus-vdesign1` is concurrently redesigning this
layer with a mandate to make it small. If that work lands, §6 is deletable and
should be deleted; §1–§5 and §7 are the durable part.

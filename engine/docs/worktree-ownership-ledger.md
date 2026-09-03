# The worktree ownership ledger — RichOS owns the record, not the harness's lock

```
~/.claude/state/worktree-ledger.jsonl        (RICHOS_WORKTREE_LEDGER overrides)
```

One JSON object per line, appended, never rewritten. It lives outside every
repository and outside every session team directory, because it has to outlive
both — that is its entire job.

## 2026-09-03: ownership is exact path only, and removal is a transaction

Everything below about judging an owner's liveness is now REPORTING. No sweep
removes a worktree on a liveness verdict any more; removal belongs to the
transaction lifecycle in `docs/worktree-lifecycle-transactions.md`:
a `prepared` record at creation, a spawn-intent bound to the platform's agent
id, a sealed manifest, a compare-and-set terminal claim at the first
SubagentStop or WorktreeRemove, and a persistent reconciler. In this ledger:

- `prepared` (new) is the authoritative creation-time record
  `create-teammate-worktree.sh` writes — exact repo, path, branch, session id —
  and `prepared_records()` filters on every key exactly.
- `registrations()` matches by EXACT worktree path or not at all. Teammate
  names, branch names and transcript joins are reported in the reason line and
  never returned to a destructive caller (`match_names` is a reporting flag).
- `bound_members(session_id, agent_id)` delegates to the sealed transaction
  and has no fallback.
- `append()` fsyncs.

## Why this exists

A hand-rolled worktree (cross-repository work, `richos-wt/<name>`) takes no git
lock, so it carries no evidence about its own owner. To judge it, the reaper
read the owner's NATIVE isolation-worktree lock in the session's repository.
That native worktree is deleted at land time. From that moment the hand-rolled
tree was *permanently* undecidable — correctly so, because doctrine forbids
inferring death from absence.

**Cleaning up one repository destroyed the only evidence that could ever clean
up another.** Four fixes (one repository to many, one path shape to git truth,
session-start-only to an agent-finish trigger, a guard tightening) were each
correct and each forward-only, while the evidence they needed had already been
destroyed behind them. Measured on 2026-09-02: 29 worktrees in `richos`, 29
`owner-undecidable`, with the blind line *"no session transcript found for
entity '/Users/alex/ab/richos'"* — a project directory that holds zero
transcripts and always will, because no session ever starts there.

The full account, with the command or `file:line` behind every claim, is
`richos-hq/wiki/worktree-lifecycle.md`.

## What is recorded, and by whom

| Record | Written by | Carries |
|---|---|---|
| `registered` | `scripts/hooks/detect-nonnative-worktree.sh` (PostToolUse[Agent], beside the `spawned-names.log` append) | teammate, agent id (from the async-launch acknowledgement), session id, **session pid + `ps` start time** (from the native lock line, else `CLAUDE_PID`), the native worktree path and branch; a `cwd` spawn's hand-rolled path with its repository and branch; every `cross-repo-worktree: <path>` prompt line |
| `registered` | `scripts/create-teammate-worktree.sh` | the same, for a cross-repository worktree it created and seeded, keyed by exact path |
| `terminated` | `scripts/reap-stale-worktrees.sh` (gate 1 and on removal), `scripts/remove-agent-worktree.sh`, `worktree-ledger.py judge-batch` | a POSITIVE, WITNESSED termination: the native worktree observed registered-and-unlocked or stale-locked by a dead pid, or removed after that verdict. Once per agent id. **Never** a verdict that rested on absence. |
| `finished` | `teammate-idle-handoff.sh`, `task-completed-handoff.sh`, `worker-ended-handoff.sh` | an ADVISORY per-agent signal (TeammateIdle / TaskCompleted / SubagentStop) keyed to agent id and worktree path |

`finished` is not death. An idle teammate can be resumed by a message
(`guard-resume-isolation.sh` permits exactly that for an active teammate), a
completed task is task-grain, and SubagentStop fires at the end of every turn
(measured: 337 of them for six agents). They are printed beside the verdict and
never decide.

## The judgment

`scripts/lib/worktree-ledger.py judge` / `judge-batch` — the ONE
implementation; the inventory imports it and never paraphrases it. The owner
of a hand-rolled worktree is resolved from the ledger by EXACT worktree path
and by nothing else (a tree with no path record is UNRESOLVED; the name and
transcript fallbacks were removed on 2026-09-03). Then, per registration:

```
witnessed termination on record ................ NOT-ALIVE
native isolation worktree LOCKED, pid running ... ALIVE
native registered and unlocked / stale-locked ... NOT-ALIVE — observed now, and
                                                  WRITTEN so the land cannot
                                                  destroy it
native ABSENT, session pid+start provably gone .. NOT-ALIVE — the process every
                                                  agent of that session ran
                                                  inside no longer exists
native ABSENT, no pid on record, but the session
  is over by EXHAUSTION (below) ................. NOT-ALIVE
native ABSENT, session pid still running ........ INDETERMINATE, naming the pid
no session identity, native absent .............. INDETERMINATE
no registration and no transcript join .......... UNRESOLVED
```

Several registrations can match one name (the reuse guard is per-session;
names recur across sessions): one ALIVE wins over everything, otherwise any
INDETERMINATE wins, otherwise all NOT-ALIVE. **INDETERMINATE and UNRESOLVED are
never collapsed. Absence is never a termination signal.**

### Session identity = pid + start time, never pid alone

The harness's lock line names the host session's pid, identical for every
agent of the session (`agent-liveness.py` measured it). A pid can be reused,
so a bare `kill -0` is not identity: the ledger records `ps -o lstart=` at
registration and compares the same field later. Same pid + same start = the
same process; anything else = that process is gone.

### Session death by exhaustion — owners the ledger never saw

A spawn that predates the ledger has no pid on record. What exists is its
session id (the transcript's file name) and the transcript's last-write time.
The session that made that write was a running `claude` process at that
moment. So:

1. enumerate every running `claude` process (`ps -axo`; `pgrep` cannot see
   them on this machine — measured), with its start time;
2. self-check: the process this code runs inside (`CLAUDE_PID`) must appear in
   that enumeration, or the enumeration is not trusted → INDETERMINATE;
3. keep the processes that started BEFORE the transcript's last write — only
   those could have made it;
4. account for each through the harness's own live-session registry,
   `~/.claude/sessions/<pid>.json` (pid, sessionId, startedAt; written at
   start, removed at exit): a row naming a DIFFERENT session id whose
   `startedAt` matches the process start rules that process out; a row naming
   THIS session id means the session is alive; a process with no row is
   unaccounted for and keeps the answer INDETERMINATE;
5. nothing left that could be the session → the session is over.

This is evidence about what IS running, positively enumerated and fully
accounted for — the same class as "the lock's pid is dead" — not an inference
from quiet. Every step that cannot complete fails toward INDETERMINATE.

### The transcript index

`~/.claude/projects/*/*.jsonl`, every file, joined name → (agent id, session
id, last write). Measured: ~150 files in 0.7 s. The reaper used to read
`ls -1t | head -1` under the swept repository's slug — the wrong key by
construction.

## The reaper's verdict — the line that cannot read as routine

```
=== summary (MODE): reaped=N skipped=N errors=N residue=N orphan-processes=N branches-swept=N branches-skipped=N ===
=== coverage (MODE): ... hand-rolled=N undecidable=N unresolved=N indeterminate=N ===
=== verdict: CLEAN | PENDING — indeterminate=N ... | FAIL — unresolved=N ... ===
```

`unresolved>0` is a **FAIL, exit 3**: a hand-rolled worktree with NO
ownership record can never be judged by this tool; it is the "unbound
RichOS-created worktrees" figure of the definition of done, reported and never
acted on. `indeterminate>0` is **PENDING, exit 0**. The session-start wrapper
runs this inventory in DRY-RUN only and puts the verdict FIRST in what it
announces; the agent-finish wrapper was retired on 2026-09-03.

## Orphan branches

A pass over `refs/heads/` of every reap-eligible repository sweeps
teammate-shaped orphans — `worktree-*`, `<role>-<model>-<identifier>`, or a
branch the ledger registered for that repository — only when the branch is not
the current branch, has no registered worktree, is a merge-base ancestor of
HEAD, and is referenced by no live process. `-d` only, never `-D`; an unmerged
orphan is `SKIP-BRANCH <name> unmerged(+N)` and stays.

## Cross-repository worktrees — created by RichOS, refused otherwise

Native `isolation: "worktree"` roots at the SESSION's repository, and the
Agent tool's `cwd` is "mutually exclusive with `isolation: worktree`". So
cross-repository work runs in a hand-rolled worktree — one RichOS creates:

```
scripts/create-teammate-worktree.sh <repo> <teammate-name> [--dir p] [--base ref]
```

creates `<main>-wt/<name>` on branch `<name>` from HEAD, seeds every
gitignored file matching `.worktreeinclude` (the same contract native
isolation honors), and registers the tree by exact path with the session id
(from `~/.claude/sessions/<pid>.json`), pid and start time. It prints the two
spawn shapes:

```
cwd: "<path>"                    (no isolation)
cross-repo-worktree: <path>      (a prompt line, with isolation:"worktree")
```

`guard-worktree-isolation.sh` clause 4 refuses everything else: a `cwd` that
is not the top level of a linked worktree with a ledger registration; `cwd`
together with isolation; a `cross-repo-worktree:` line naming an unregistered
path; and a prompt that instructs the teammate to run `git worktree add` (the
audited escape hatch is a `hand-roll-ack: <reason>` line, logged to
`.claude/state/hand-roll-acks.log`). Without the ledger library a cwd/marker
spawn is refused — an unverifiable registration is not one.

## What can STILL reach an unjudgeable state — named, not discovered later

- **A worktree whose spawn was never registered and whose name appears in no
  transcript** (spawned before this landed in a session whose transcript is
  gone; or named unlike its teammate; or created by another tool — the Codex
  worktree in `richos`). It is `owner-unresolved` and the run is a FAIL until
  an operator clears it. The verdict line exists so this is never routine.
- **A transcript-only owner while an UNACCOUNTED `claude` process predates its
  session's last write** — a session started without a registry row, or a
  `claude` binary not named `claude`. INDETERMINATE, naming the pid, until that
  process ends.
- **A registered owner whose session is alive and whose native worktree was
  removed by a route that wrote no witness** (a raw `git worktree remove`,
  which `guard-worktree-removal.sh` already refuses; the harness's own
  auto-clean of an unchanged tree). INDETERMINATE until that session ends;
  then decidable by pid identity. Nothing stays unjudgeable past the session.
- **Operator-owned worktrees** (`/private/tmp/ci-base`, a Codex checkout) are
  not teammate-shaped and are reported, never mutated, and never a FAIL.

## Test affordances (never set in a real session)

`RICHOS_WORKTREE_LEDGER` / `REAP_WORKTREE_LEDGER` (the ledger),
`RICHOS_SESSIONS_DIR` (the session registry), `RICHOS_CLAUDE_PROCESSES`
(`"pid:epoch ..."` or `none`, the process table), `RICHOS_PROJECTS_DIR` /
`REAP_PROJECTS_DIR` (the transcripts). Every sandbox run pins all four; a sweep
WRITES, and a test that writes the operator's real record is a test with side
effects. Under `REAP_WORKTREES_ROOT` the two wrappers pin them inside the
sandbox automatically.

Suites: `scripts/lib/worktree-ledger.test.sh` (24), `scripts/reap-stale-worktrees.test.sh`
(28), `scripts/create-teammate-worktree.test.sh` (16), plus the extended
guard, detector, lifecycle, removal and wrapper suites. Every verdict-shaped
case is two-sided, and every suite was turned red by a source mutation before
it was trusted.

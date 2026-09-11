# Workspace spec: implementation record, 2026-09-11

**The only reference:** `docs/plans/worktree-spec-2026-09-11.md` (sha256 prefix `b3fd6cd33b8c1135`),
committed untouched as the first commit of this branch (`02a7ff38`). Implemented by zach-opus-spec2
on branch `cc/zach-opus-spec2`, base `dcabcbd9`. No earlier workspace design was consulted or cited.

## The mechanism, in one paragraph

There is one registry, `engine/scripts/lib/workspaces.py`. It lives outside every repository and
session, at `$RICHOS_WORKSPACES_DIR`, else `$CLAUDE_CONFIG_DIR/state/workspaces`, else
`~/.claude/state/workspaces`. Three things write it: the two events the page names (a spawn is
registered, and work is landed or discarded), and the platform's own signals, which
`engine/scripts/hooks/workspace-lifecycle.sh` records on six events. Four things read it:

- the point-5 gate at the turn end (`engine/scripts/hooks/guard-workspace-gate.sh`);
- the point-5 gate at new work (the registration step inside `guard-worktree-isolation.sh`);
- the lock-out (`guard-sealed-worktree.sh`);
- the resume guard.

`engine/scripts/workspaces.sh` is the one command Rich runs: `status`, `land`, `discard`, `pause`,
`resume`, `stop`, `wait` and `retry`. Land and discard, and their automatic retry, are the only
code in the engine that deletes a workspace or an agent's branch.

## The thirteen points

A test exists for each point, named after it (`test_point_NN_…`). All of them run in temporary
repositories, with HOME, CLAUDE_CONFIG_DIR and the registry redirected, and with a session
process owned by the suite.

Every point's test has a mutant in `engine/scripts/lib/workspaces.mutation.sh` that is proven to
make it fail. Run all of them with `bash engine/scripts/lib/workspaces.mutation.sh`: 20 mutants,
all proven.

**How to prove one point:** `python3 -B engine/scripts/lib/workspaces.test.py PointNN_<Class>`.
The table gives each class.

**The whole suite:** `bash engine/scripts/lib/workspaces.test.sh`. It runs 37 tests, then the
mutants.

**The end-to-end demonstration:** `bash engine/scripts/workspaces-e2e.test.sh`. It runs 39 checks
through the real hooks:

| Check | What it demonstrates |
|---|---|
| E1 | spawn, register, commit, finish, land, gone |
| E2 | the same agent's work, discarded |
| E3 | a cross-repository agent with two workspaces |
| E4 | a session that ends mid-work, handled by the next session |
| E5 | nothing left behind in either repository |

The core commit for every point is `e81cec14`. Wiring (`898c750c`, `c993c98d`) and the end-to-end
demonstration (`17acc9f0`) serve every point. The table lists only the commits specific to each
point.

| Point | Test class (tests) | Commits beyond the core |
|---|---|---|
| 1. non-native workspaces are `cc/` | `Point01_CcNaming` (2) | `da88b6a2` (a cc/ workspace is registered before it exists), `6e0731d5` (a raw `git worktree add` is refused) |
| 2. `codex/` is never touched | `Point02_Codex` (1) | `6e0731d5`, `91989a7c` (the guard refuses `codex/` operations with no override) |
| 3. two events; no registration means no spawn; `claude --worktree` is not allowed | `Point03_TwoEvents` (3) | `da88b6a2`, `6e0731d5`, `d1495ff2` |
| 4. landed means the workspace and the branch are deleted automatically | `Point04_LandedMeansDeleted` (1) | `898c750c` (the Stop gate lands merged work on its own) |
| 5. the guarantee | `Point05_Guarantee` (7) | `898c750c`, `da88b6a2` (the new-work gate), `cb0260bf` and `09502a4b` (the gate says so when it cannot run or cannot read the turn) |
| 6. native workspaces get the same treatment | `Point06_Native` (2) | `19ad436c` (the lifecycle hook reads its payload with a bounded read) |
| 7. landed or discarded; the CEO's work needs his word; continuation | `Point07_LandedOrDiscarded` (4) | `da88b6a2` (`continues:` and `ceo-ordered:` prompt lines) |
| 8. nothing uncommitted is landed | `Point08_NothingUncommitted` (2) | none |
| 9. a finished agent never writes again; processes are stopped first | `Point09_NeverWritesAgain` (3) | `6181f608`, `e17479d8`, `0d37f3ef`, `4b04ca3c` (the resume guard refuses a finished agent with no escape hatch) |
| 10. all of an agent's workspaces go together | `Point10_AllTogether` (2) | none |
| 11. finished versus paused | `Point11_Finished` (5) | `0d37f3ef`, `4b04ca3c` |
| 12. an agent cannot outlive its session | `Point12_Sessions` (4) | `d1495ff2` (no borrowed session identity) |
| 13. a failed deletion is retried | `Point13_Retry` (1) | none |

The integrity probe proves the same properties on the live engine, in its Layers Q, Q6 and S
(`dbc238f5`, `e22f2937`, `44d1243b`). Its functional canary is sandboxed. It runs spawn, commit
and finish, then checks the agent is locked out and the turn is held. It then merges the work,
and the agent is landed with its workspace and branch gone. The integrity suite's sections `Q`
and `Qscope` mutate the registry, and each mutation shows the canary noticing:

- a gate that lets every turn end;
- a land that deletes nothing;
- a finished agent that is not locked out;
- a broken registration step;
- each retired deleter wired back.

Run them one section at a time:
`bash engine/scripts/hooks/contract-integrity.test.sh --only Q` and `--only Qscope`.

## Old deleters, and what became of each

Every one of these came off the deletion path. Where one was a file, it is deleted, together with
its tests and its mutation harness (`ca4ba9f8`, plus `83680156` for the last one). Where it was
wiring, the wiring is gone, and the probe's Layer Q fails if any of it is wired back.

| Deleter | Fate |
|---|---|
| The nightly `com.richos.worktree-reconciler` (launchd) and `reconcile-terminal-worktrees.py` | The code is deleted, and so is `install-reconciler-schedule.test.sh`. `install.sh` now unloads the job and deletes its plist, and the install fails if it cannot (`ee51d4c2`, proven in a sandbox by `install-retire-reconciler.test.sh`, `64de51a4`). Probe Layer Q7 fails while the job is still loaded under the operator's own launchd. **On this machine the job is still loaded today.** It stays loaded until `install.sh` runs from a main checkout that contains this branch. |
| The daily lane, `daily-workspace-cleanup.py` and `cleanup-schedule.py` | Deleted. |
| The reaper's execute path, `reap-stale-worktrees.sh` | Deleted. |
| The session-start pass, `session-start-reap-worktrees.sh` (SessionStart) | Deleted and unwired. `workspace-lifecycle.sh` holds that SessionStart slot now, and it deletes only what the page deletes. |
| The in-event reclaim, `terminalize-agent-worktrees.sh` (SubagentStop and WorktreeRemove) | Deleted and unwired. WorktreeRemove is no longer registered. |
| The transaction store, `worktree-transactions.py`, and its start-fact writer `record-subagent-start.sh` | Deleted. The registry replaces them. Code that read the store now reads the registry: the TaskCompleted delivery check (`6387b2b0`) and the finish-row completion (`b9d78a4b`). The ownership ledger's lookups now say the evidence is gone (`e2af5d3a`). |
| Adoption, `worktree-adoption.py` | Deleted. Its config keys are gone (`a60209e0`). |
| The retirement and removal helpers: `workspace-retire.py` (and its two review copies), `remove-agent-worktree.sh`, `discard-workspace-backlog.py` | Deleted. The removal guard names `workspaces.sh land\|discard` as the only way (`6e0731d5`). |
| The terminal-branch cleanup, and its shadows: `terminal-branch-cleanup.py`, `terminal-branch-shadow.py`, `terminal-recovery-shadow.py`, `workspace-recovery-metadata.py` | Deleted. |
| Managed and legacy workspaces: `managed-workspace-*.py`, `install-managed-workspace-broker.py`, and the thirteen `legacy-workspace-*.py` | Deleted. **The root LaunchDaemon `com.richos.managed-workspace-broker` is still installed on this machine**, running a released copy under `/Library/Application Support/RichOS/workspace-broker/`. No engine client can reach it any more, but removing it needs an administrator. This is raised as an escalation. |
| The land-disposition demand: `land-disposition.py`, `land-disposition.sh`, `notice-land-disposition.sh` (Stop), and `land-disposition-measure.py` | Deleted and unwired. `guard-workspace-gate.sh` is the page's point-5 gate in the same Stop slot. |
| The cleanup routing contract and its schedule: `cleanup-routing-contract.py`, `cleanup-routing.signature`, `restart-after-terminal-measure.py` | Deleted. |
| The native shell sparsifier, `shell-worktree-sparse.py` | Deleted (`83680156`). Its only caller was the removed transaction seal, and the page has no step that alters a live workspace's checkout. |
| The detector's residue auto-reap and journal (`detect-nonnative-worktree.sh`) | Removed (`0d37f3ef`). It reports residue and orphaned processes, and deletes nothing. |
| The removal guard's `worktree-remove-ack:` override | Narrowed (`6e0731d5`, `91989a7c`). Everything the spec's events own is refused with no override: an agent's workspace (`cc/`, `worktree-*`, `.claude/worktrees/agent-*`), `codex/`, a raw `git worktree add`, `git worktree prune` and `claude --worktree`. The ack still exempts only the removal of a linked worktree that is not the system's. |
| **Also found, and kept** | `demo.sh` Beat 7 removes its own sample worktree inside the throwaway temporary repository it builds and deletes on exit. It touches no real workspace. femcboost's `scripts/preflight.sh` advises running `git worktree prune`, and two permission allowlists name it (`femcboost/.claude/settings.local.json` and a MyRichOS seed `settings.json`). The worktree guard refuses that command regardless. These are outside this branch's repository and are recorded here, not changed. |

In total, 154 files were deleted under `engine/scripts`, plus 25 operating docs under
`engine/docs` (`e7c9394d`). The frozen verification records stand, and are exempted from the
citation check in `.richos/publication-completeness`.

No removal broke a guard the CEO asked for, so nothing had to stop. The lock-out stays in
`guard-sealed-worktree.sh`, rewritten to read the page's finished and paused (`6181f608`). The
resume guard's refusal of a finished agent stays, and now reads the registry. The spawn guard's
earlier refusal of `run_in_background: false` for a file-capable spawn also stays. A synchronous
spawn's agent id arrives only after its run has ended.

## Where the page had to be read

Each item below gives the sentence, then the reading chosen. None of them infers whether an agent
is alive.

1. *"A `cc/` or native workspace with no registration, and any branch an agent created, counts as
   finished work of an ended session and is handled under point 5."* (point 3)

   - At session start and at every turn end, the session's repository and every repository the
     registry has seen are scanned. Every `cc/` and native workspace (and every such branch) that
     has no registration becomes a record of finished work. New work reads the records already
     made.
   - It is landed on its own if it is already in main and clean. Otherwise it is pending.
   - A workspace that git registered less than 120 seconds ago is skipped. Its own spawn is still
     writing the registration: points 3 and 6 register a workspace *at* its spawn (PreToolUse,
     SubagentStart and PostToolUse), and those can arrive after git creates it. The age is read
     from git's own admin file (`commondir`), and it says nothing about liveness.
   - A registration that arrives later withdraws the record.

2. *"any branch an agent created"* (point 3) and *"every workspace and branch it has"* (point 10).
   The branches an agent created are read from git, not guessed from names: a branch counts when
   the workspace's HEAD reflog moved to it at the moment that branch's own reflog says it was
   created. `codex/` is never included.

3. *"Landed means the workspace AND the branch are deleted — automatically"* (point 4).

   - Landed is proved from git: every branch tip, and every workspace HEAD, is an ancestor of the
     main checkout's HEAD.
   - It is checked automatically, with no command, at every turn end, at session start, and
     whenever new work is spawned.
   - *"An agent that produced nothing counts as landed"* (point 7) falls out of the same test: a
     workspace whose HEAD is already in main has produced nothing.

4. *"answering the CEO or obeying his stop order (the reply names the pending work, which is
   handled right after)"* (point 5). The turn may end when it began with the CEO's own message and
   the last message names every pending item.

5. *"work whose only purpose is getting the pending work landed"* (point 5) and *"a new agent
   continues from its branch"* (point 7).

   - The spawn names what it lands, with a prompt line `lands-pending: <name>` or
     `continues: <name>`. Only such a spawn is allowed while work is pending.
   - With `continues:`, the old agent's workspaces are deleted when the new agent starts, and its
     branches go when the new agent's work lands.

6. *"waiting on something he has already started to get it landed, or waiting on something
   outside his reach"* (point 5).

   - Rich records these with `workspaces.sh wait <agent> --started '…'` or
     `--outside '…' --todo '<CEO TODO ref>'`.
   - A running agent spawned with `lands-pending:` or `continues:` counts as started.
   - A discard that needs the CEO's word is recorded with `--ceo '<the question>' --todo '…'`.
     That item blocks nothing else.
   - New work stays blocked for every item except the CEO-discard one.

7. *"Rich records every pause when he sends it"* and *"A pause names what ends it"* (point 11).

   - A pause is a SendMessage line `pause-until: <what ends it>`, or `workspaces.sh pause`.
   - A later message to that agent resumes it.
   - An empty `pause-until:` is pending work under point 5.
   - An end of run recorded after a pause is still a pause, unless the agent handed in its work
     or was stopped.

8. *"the platform's own end-of-run signal"* (point 11). The end-of-run signals are:

   - SubagentStop;
   - a successful TaskStop (PostToolUse[TaskStop]), recorded as *stopped*.

   TaskCompleted is recorded as *handed in*, which the page's hole-7 sentence needs. TeammateIdle
   is not an end: idle is not ended.

9. *"A session has ended when it recorded its end or when its process no longer exists on this
   machine ... (The record carries more than a process number, since those get reused.)"*
   (point 12).

   - The session records its process number and that process's start time. The start time is
     read with `ps -o lstart=` under `LC_ALL=C TZ=UTC0`.
   - A session has ended when it recorded SessionEnd, when the process is gone, or when the number
     now belongs to a process with a different start time.
   - The session process is the platform's `sessions/<pid>.json` whose sessionId matches, else the
     ancestor named `claude`. A sessionId mismatch yields no identity.
   - A registration that cannot read its session's identity is refused, so the spawn does not
     happen. This is point 3's *"If registration fails, the spawn does not happen"*.

10. *"While two sessions run at once, each handles only the agents it started."* (point 12)

    - A session handles its own agents, and the agents of sessions that have ended.
    - The first session to handle an ended session's agent claims it.
    - An unregistered workspace belongs to an ended session.

11. *"Work the CEO ordered is never discarded without his word."* (point 7)

    - Work is marked CEO-ordered by a spawn prompt line `ceo-ordered: <his words>`.
    - Discarding it needs `--ceo-word '<his words>'`.
    - Any other discard must say why it was not his order (`--not-ceo-ordered '<why>'`).
    - Every discard records its reason and every branch tip it deleted.

12. *"A workspace with uncommitted or ignored files it needs is not landed"* (point 8).

    - Any uncommitted entry blocks the land.
    - An ignored entry blocks it too, when the main checkout lacks it or has different bytes.
      Rich can then commit it, discard, or state `--ignored-not-needed '<why>'`.

13. *"every process it started is stopped before its workspaces are deleted"* (point 9).

    - The operating system does not say which agent started a process. So these are stopped: the
      processes whose working directory is inside the agent's workspaces, or whose arguments name
      them. They get SIGTERM, then SIGKILL after a grace period.
    - This process, its ancestors and every `claude` process are never stopped.
    - A survivor fails the deletion, and point 13 retries it.

14. *"The CEO hears about it only if it keeps failing."* (point 13)

    - Retries back off from 60 seconds, doubling each time, up to one hour.
    - After five failed attempts, the turn-end gate prints a `TELL THE CEO` line that names the
      failure.

15. *"Nobody starts a session in its own workspace ... it is not allowed."* (point 3)

    - A session that starts inside a worktree is recorded as not allowed. The lock-out then
      refuses that session's every tool except read-only ones.
    - The worktree guard refuses `claude --worktree` and `claude -w` in Bash.

16. *"registered when the agent is spawned"* for native workspaces (point 6).

    - The spawn's name is registered at PreToolUse[Agent].
    - The native workspace is added by the exact path the platform starts the agent in
      (SubagentStart), and by the agent id in the Agent result (PostToolUse). Either may arrive
      first.

## Line counts

The command, run from the repository root:

```sh
bash linecount.sh "$PWD" dcabcbd9 HEAD
```

`linecount.sh` is the following script, verbatim:

```sh
#!/usr/bin/env bash
set -euo pipefail
R="$1"; B="$2"; H="$3"; cd "$R"
deleted="$(git diff --no-renames --name-only --diff-filter=D "$B" "$H" -- engine/scripts)"
count_at() { local rev="$1" kind="$2"; shift 2; local n=0 f
  for f in "$@"; do
    case "$f" in *.test.sh|*.test.py|*.mutation.sh|*.acceptance.test.sh) [ "$kind" = test ] || continue ;;
                 *) [ "$kind" = prod ] || continue ;; esac
    n=$(( n + $(git show "$rev:$f" | wc -l) )); done; printf '%s' "$n"; }
set -- $deleted
echo "BEFORE $# files: prod $(count_at "$B" prod "$@") test $(count_at "$B" test "$@")"
set -- engine/scripts/lib/workspaces.py engine/scripts/workspaces.sh engine/scripts/hooks/workspace-lifecycle.sh \
       engine/scripts/hooks/guard-workspace-gate.sh engine/scripts/lib/workspaces.test.py engine/scripts/lib/workspaces.test.sh \
       engine/scripts/lib/workspaces.mutation.sh engine/scripts/workspaces-e2e.test.sh engine/scripts/hooks/install-retire-reconciler.test.sh
echo "AFTER: prod $(count_at "$H" prod "$@") test $(count_at "$H" test "$@")"
```

Its output, at `febbdc3e`:

| | Production lines | Test lines |
|---|---|---|
| **Before**: the 154 files deleted under `engine/scripts`, measured at `dcabcbd9` | 27,356 | 20,336 |
| **After**: the page's deletion path, measured at `HEAD` | 2,337 | 1,139 |

The 25 operating docs deleted from `engine/docs` held a further 2,316 lines.

The four production files after:

| File | Lines |
|---|---|
| `workspaces.py` | 2,063 |
| `workspaces.sh` | 32 |
| `workspace-lifecycle.sh` | 85 |
| `guard-workspace-gate.sh` | 157 |

The brief's "~11,800 lines" was a figure it did not derive. The count above is every deleted
production file, with its tests counted separately.

## What the suites prove, and what they do not

Each suite below was run on this branch, and each exited 0. The integrity suite is the one
exception: each section was run separately with `--only <section>`, and each returned 3, which is
green for a scoped run.

- **The registry:** 37 tests and 20 mutants.
- **End to end:** 39 checks.
- **Every other engine suite that names the removed machinery.** Each was updated, and each was
  rerun after the last change it depends on.
- **A parallel sweep of all 93 other engine suites.** Two of them overran the parallel time limit.
  Run alone, `row-currency` passed in 154 seconds and `verify-agent-prompt` in 98 seconds.
- **The integrity suite:** all 24 sections, run one at a time. **Its full pass was not run**, as
  the brief required. A land needs that pass.

Neither suite ever wrote to the operator's registry. Every suite in the sweep also ran with a
leak trap: the registry variable pointed at a scratch directory, so any suite that did not
sandbox the registry would have written there.

That trap caught one real defect. The probe's BR9, MT and Q canaries inherited the registry
location from their environment. If one of them had inherited the real registry, the Q canary's
Stop gate would have scanned that registry's real repositories, and landed in them. All three now
pin a registry inside their own sandbox (`e22f2937`).

## Before this is installed

1. **The first session on the new engine applies point 3 to everything already on disk.** It
   scans the session's own repository, plus every repository the registry has seen. Any `cc/` or
   native workspace with no registration that is older than two minutes counts as finished work of
   an ended session.

   - The session lands on its own every such workspace that is already in main and clean.
   - It holds new work until the rest are landed or discarded.
   - **A workspace of an agent still running in an old-engine session is indistinguishable from
     one left behind.** A freshly created one with no commits yet counts as landed, and would be
     deleted.

   So the branch must be landed, and `install.sh` run, only while no other session and no agent is
   running.

2. **`install.sh` must run from the main checkout after the land.** That run unloads the nightly
   reconciler still loaded on this machine. Until then, probe Layer Q7 fails, correctly.

3. **Removing the root broker daemon needs an administrator.** It is
   `/Library/LaunchDaemons/com.richos.managed-workspace-broker.plist`.

4. **The land reporters still use the ownership ledger's wording.** They are
   `land-completeness.py` and `land-residue-gate.py`, and they only announce. They name
   `workspaces.sh` as the way to clear residue. They were not rebuilt, as the brief said not to
   repair the old machinery.

5. **Tests polluted the operator's registry twice earlier in this work.** Fifty test registrations
   were removed, then five more. The events showed only test sessions and nothing destructive.
   Each suite now pins its own registry and session process, and the record canary watches the
   registry. The registry does not exist on this machine now: `~/.claude/state/workspaces` is
   absent.
